import hashlib
import json
import os
from uuid import NAMESPACE_URL, UUID, uuid4, uuid5

from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from .config import get_settings
from .tenancy import system_connection


class BootstrapVendor(BaseModel):
    id: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9._-]+$")
    name: str = Field(min_length=2, max_length=160)
    initials: str = Field(min_length=1, max_length=3)
    color: str = Field(pattern=r"^#[0-9A-Fa-f]{6}$")


class TenantBootstrap(BaseModel):
    organization_id: UUID
    organization_slug: str = Field(min_length=2, max_length=80, pattern=r"^[a-z0-9-]+$")
    organization_name: str = Field(min_length=2, max_length=160)
    site_id: UUID
    site_name: str = Field(min_length=2, max_length=160)
    allowed_wifi_ssids: list[str] = Field(min_length=1, max_length=20)
    reviewer_issuer: str = Field(pattern=r"^https://", max_length=500)
    reviewer_subject: str = Field(min_length=1, max_length=500)
    reviewer_email: str = Field(pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$", max_length=254)
    reviewer_display_name: str = Field(min_length=1, max_length=160)
    vendors: list[BootstrapVendor] = Field(min_length=1, max_length=20)
    confirmation: str


def bootstrap_tenant(settings=None, payload: TenantBootstrap | None = None) -> dict[str, str]:
    settings = settings or get_settings()
    if settings.environment != "production" or not settings.database_admin_url:
        raise RuntimeError("tenant_bootstrap_requires_production_admin_database")
    payload = payload or TenantBootstrap.model_validate_json(os.environ.get("TENANT_BOOTSTRAP_JSON", "{}"))
    if payload.confirmation != f"BOOTSTRAP {payload.organization_id}":
        raise RuntimeError("tenant_bootstrap_confirmation_invalid")
    ssids = list(dict.fromkeys(value.strip() for value in payload.allowed_wifi_ssids if value.strip()))
    if len(ssids) != len(payload.allowed_wifi_ssids):
        raise RuntimeError("tenant_bootstrap_wifi_policy_invalid")

    with system_connection(settings.database_admin_url, row_factory=dict_row) as connection:
        organization = connection.execute(
            "SELECT id, slug FROM organizations WHERE id = %s OR slug = %s FOR UPDATE",
            (payload.organization_id, payload.organization_slug),
        ).fetchone()
        if organization and (
            UUID(str(organization["id"])) != payload.organization_id
            or str(organization["slug"]) != payload.organization_slug
        ):
            raise RuntimeError("tenant_bootstrap_organization_conflict")
        connection.execute(
            """
            INSERT INTO organizations (id, slug, name, device_limit, daily_receipt_limit, storage_byte_limit)
            VALUES (%s, %s, %s, 100, 1000, 5000000000)
            ON CONFLICT (id) DO UPDATE SET name = excluded.name, updated_at = NOW()
            """,
            (payload.organization_id, payload.organization_slug, payload.organization_name),
        )
        connection.execute(
            """
            INSERT INTO sites
              (id, organization_id, name, allowed_wifi_ssids, daily_receipt_limit, image_byte_limit)
            VALUES (%s, %s, %s, %s, 1000, 5000000)
            ON CONFLICT (organization_id, id) DO UPDATE SET
              name = excluded.name, allowed_wifi_ssids = excluded.allowed_wifi_ssids,
              configuration_version = sites.configuration_version + 1, active = TRUE, updated_at = NOW()
            """,
            (payload.site_id, payload.organization_id, payload.site_name, Jsonb(ssids)),
        )
        for display_order, vendor in enumerate(payload.vendors):
            connection.execute(
                """
                INSERT INTO vendors
                  (id, organization_id, site_id, name, initials, color, display_order, active)
                VALUES (%s, %s, %s, %s, %s, %s, %s, TRUE)
                ON CONFLICT (site_id, id) DO UPDATE SET
                  name = excluded.name, initials = excluded.initials, color = excluded.color,
                  display_order = excluded.display_order, active = TRUE
                """,
                (
                    vendor.id, payload.organization_id, payload.site_id, vendor.name,
                    vendor.initials.upper(), vendor.color.upper(), display_order,
                ),
            )
        identity = connection.execute(
            "SELECT user_id FROM identity_links WHERE issuer = %s AND subject = %s FOR UPDATE",
            (payload.reviewer_issuer, payload.reviewer_subject),
        ).fetchone()
        if identity:
            user_id = UUID(str(identity["user_id"]))
        else:
            user_id = uuid4()
            connection.execute(
                "INSERT INTO users (id, email, display_name) VALUES (%s, %s, %s)",
                (user_id, payload.reviewer_email.lower(), payload.reviewer_display_name),
            )
            connection.execute(
                """
                INSERT INTO identity_links (id, user_id, issuer, subject, email)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (uuid4(), user_id, payload.reviewer_issuer, payload.reviewer_subject, payload.reviewer_email.lower()),
            )
        connection.execute(
            "UPDATE users SET email = %s, display_name = %s, active = TRUE, updated_at = NOW() WHERE id = %s",
            (payload.reviewer_email.lower(), payload.reviewer_display_name, user_id),
        )
        connection.execute(
            """
            INSERT INTO organization_memberships (organization_id, user_id, role, active)
            VALUES (%s, %s, 'ORG_ADMIN', TRUE)
            ON CONFLICT (organization_id, user_id) DO UPDATE SET role = 'ORG_ADMIN', active = TRUE
            """,
            (payload.organization_id, user_id),
        )
        event_body = {"organizationId": str(payload.organization_id), "siteId": str(payload.site_id), "vendorCount": len(payload.vendors)}
        event_hash = hashlib.sha256(json.dumps(event_body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        connection.execute(
            """
            INSERT INTO audit_events
              (id, organization_id, site_id, event_type, actor_type, actor_id, event_json, source_class, event_hash)
            VALUES (%s, %s, %s, 'TENANT_BOOTSTRAPPED', 'SYSTEM', 'guarded-cli', %s, 'aws-ecs', %s)
            ON CONFLICT (id) DO NOTHING
            """,
            (
                uuid5(NAMESPACE_URL, f"challanse-bootstrap:{payload.organization_id}:{payload.site_id}"),
                payload.organization_id, payload.site_id, Jsonb(event_body), event_hash,
            ),
        )
        connection.commit()
    return {"organization_id": str(payload.organization_id), "site_id": str(payload.site_id)}


if __name__ == "__main__":
    result = bootstrap_tenant()
    print(f"tenant_bootstrap_completed organization_id={result['organization_id']} site_id={result['site_id']}")
