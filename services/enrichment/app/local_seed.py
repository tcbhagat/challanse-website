from uuid import NAMESPACE_URL, UUID, uuid5

from psycopg.rows import dict_row

from .bootstrap import BootstrapVendor, TenantBootstrap, bootstrap_tenant
from .config import get_settings
from .reconciliation import import_tally_csv
from .tenancy import system_connection
from .pilot_control import SYNTHETIC_ORGANIZATION_ID, current_pilot_mode


ORGANIZATION_ID = UUID("10000000-0000-4000-8000-000000000001")
SITE_ID = UUID("20000000-0000-4000-8000-000000000001")
PRIMARY_REVIEWER = "admin@constrovet.com"
SECOND_REVIEWER = "bhagat.taran@gmail.com"
TALLY_CSV = """po_number,material_code,quantity,unit
PO-SYN-001,CEMENT-OPC,100,BAG
PO-SYN-002,STEEL-TMT,500,KG
PO-SYN-003,SAND-M,20,TON
PO-SYN-004,BRICK-FLYASH,2000,NOS
"""


def _add_reviewer(settings, email: str, role: str) -> None:
    user_id = uuid5(NAMESPACE_URL, f"challanse-local-reviewer:{email}")
    identity_id = uuid5(NAMESPACE_URL, f"challanse-local-identity:{email}")
    with system_connection(settings.database_admin_url) as connection:
        connection.execute(
            """
            INSERT INTO users (id, email, display_name, active)
            VALUES (%s, %s, %s, TRUE)
            ON CONFLICT (id) DO UPDATE SET email = excluded.email, active = TRUE, updated_at = NOW()
            """,
            (user_id, email, email.split("@")[0]),
        )
        connection.execute(
            """
            INSERT INTO identity_links (id, user_id, issuer, subject, email)
            VALUES (%s, %s, 'https://local-pilot.challanse', %s, %s)
            ON CONFLICT (issuer, subject) DO UPDATE SET email = excluded.email
            """,
            (identity_id, user_id, f"local:{email}", email),
        )
        connection.execute(
            """
            INSERT INTO organization_memberships (organization_id, user_id, role, active)
            VALUES (%s, %s, %s, TRUE)
            ON CONFLICT (organization_id, user_id) DO UPDATE SET role = excluded.role, active = TRUE
            """,
            (ORGANIZATION_ID, user_id, role),
        )
        connection.execute(
            """
            INSERT INTO site_memberships (organization_id, site_id, user_id, role, active)
            VALUES (%s, %s, %s, %s, TRUE)
            ON CONFLICT (site_id, user_id) DO UPDATE SET role = excluded.role, active = TRUE
            """,
            (ORGANIZATION_ID, SITE_ID, user_id, role),
        )
        connection.commit()


def seed_local_pilot() -> dict[str, str]:
    settings = get_settings()
    if settings.environment != "local-pilot" or not settings.synthetic_mode:
        raise RuntimeError("local_seed_requires_synthetic_mode")
    if current_pilot_mode(settings) != "synthetic-demo":
        raise RuntimeError("controlled_client_pilot_seed_forbidden")
    with system_connection(settings.system_database_url, row_factory=dict_row) as connection:
        real_organization = connection.execute(
            "SELECT 1 FROM organizations WHERE id <> %s AND active LIMIT 1", (SYNTHETIC_ORGANIZATION_ID,)
        ).fetchone()
    if real_organization:
        raise RuntimeError("client_configuration_present_seed_forbidden")
    bootstrap_tenant(
        settings,
        TenantBootstrap(
            organization_id=ORGANIZATION_ID,
            organization_slug="synthetic-client",
            organization_name="Synthetic Client Test",
            site_id=SITE_ID,
            site_name="Synthetic Construction Site",
            allowed_wifi_ssids=["SYNTHETIC-SITE-WIFI"],
            reviewer_issuer="https://local-pilot.challanse",
            reviewer_subject=f"local:{PRIMARY_REVIEWER}",
            reviewer_email=PRIMARY_REVIEWER,
            reviewer_display_name="Synthetic Pilot Admin",
            vendors=[
                BootstrapVendor(id="vendor-cement", name="Synthetic Cement Co", initials="SC", color="#F59E0B"),
                BootstrapVendor(id="vendor-steel", name="Synthetic Steel Works", initials="SS", color="#0F766E"),
                BootstrapVendor(id="vendor-sand", name="Synthetic Sand Supply", initials="MS", color="#2563EB"),
                BootstrapVendor(id="vendor-brick", name="Synthetic Brick Yard", initials="FB", color="#DC2626"),
            ],
            confirmation=f"BOOTSTRAP {ORGANIZATION_ID}",
        ),
    )
    _add_reviewer(settings, SECOND_REVIEWER, "REVIEWER")
    import_tally_csv(
        settings.database_url,
        str(ORGANIZATION_ID),
        str(SITE_ID),
        PRIMARY_REVIEWER,
        TALLY_CSV,
    )
    with system_connection(settings.database_admin_url) as connection:
        connection.execute(
            "UPDATE organizations SET device_limit = 5, daily_receipt_limit = 50, storage_byte_limit = %s WHERE id = %s",
            (settings.local_storage_limit_bytes, ORGANIZATION_ID),
        )
        connection.execute(
            "UPDATE sites SET daily_receipt_limit = 50 WHERE id = %s AND organization_id = %s",
            (SITE_ID, ORGANIZATION_ID),
        )
        connection.commit()
    return {"organization_id": str(ORGANIZATION_ID), "site_id": str(SITE_ID)}


if __name__ == "__main__":
    result = seed_local_pilot()
    print(f"local_seed_completed organization_id={result['organization_id']} site_id={result['site_id']}")
