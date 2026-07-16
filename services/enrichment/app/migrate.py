from pathlib import Path

import psycopg
from psycopg import sql

from .config import get_settings


def run_migrations() -> None:
    settings = get_settings()
    if not settings.database_admin_url or not settings.database_app_password or not settings.database_system_password or not settings.tenant_context_hmac_key:
        raise RuntimeError("database_migration_credentials_unconfigured")
    try:
        tenant_context_key = bytes.fromhex(settings.tenant_context_hmac_key)
    except ValueError as error:
        raise RuntimeError("tenant_context_hmac_key_invalid") from error
    if len(tenant_context_key) < 32:
        raise RuntimeError("tenant_context_hmac_key_invalid")
    migration_dir = Path(__file__).resolve().parent.parent / "migrations"
    with psycopg.connect(settings.database_admin_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())")
            for path in sorted(migration_dir.glob("*.sql")):
                cursor.execute("SELECT 1 FROM schema_migrations WHERE version = %s", (path.name,))
                if cursor.fetchone():
                    continue
                cursor.execute(path.read_text(encoding="utf-8"))
                cursor.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (path.name,))
            for role, password, bypass_rls in (
                ("challanse_app", settings.database_app_password, False),
                ("challanse_system", settings.database_system_password, True),
            ):
                cursor.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,))
                if cursor.fetchone():
                    cursor.execute(
                        sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {} {}").format(
                            sql.Identifier(role), sql.Literal(password),
                            sql.SQL("BYPASSRLS") if bypass_rls else sql.SQL("NOBYPASSRLS"),
                        )
                    )
                else:
                    cursor.execute(
                        sql.SQL("CREATE ROLE {} WITH LOGIN PASSWORD {} {}").format(
                            sql.Identifier(role), sql.Literal(password),
                            sql.SQL("BYPASSRLS") if bypass_rls else sql.SQL("NOBYPASSRLS"),
                        )
                    )
            cursor.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
            cursor.execute("GRANT USAGE ON SCHEMA public TO challanse_app, challanse_system")
            cursor.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO challanse_app, challanse_system")
            cursor.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO challanse_app, challanse_system")
            cursor.execute("REVOKE ALL ON TABLE users, identity_links, pilot_requests, schema_migrations FROM challanse_app")
            cursor.execute(
                """
                INSERT INTO tenant_context_secrets (singleton, secret)
                VALUES (TRUE, decode(%s, 'hex'))
                ON CONFLICT (singleton) DO UPDATE SET secret = excluded.secret, updated_at = NOW()
                """,
                (settings.tenant_context_hmac_key,),
            )
            cursor.execute("REVOKE ALL ON TABLE tenant_context_secrets, tenant_session_contexts FROM PUBLIC, challanse_app")
            cursor.execute("REVOKE ALL ON FUNCTION challanse_set_tenant_context(UUID, TEXT) FROM PUBLIC")
            cursor.execute("GRANT EXECUTE ON FUNCTION challanse_set_tenant_context(UUID, TEXT) TO challanse_app")
            cursor.execute("GRANT EXECUTE ON FUNCTION challanse_current_organization_id() TO challanse_app")
            cursor.execute("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO challanse_app, challanse_system")
            cursor.execute("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO challanse_app, challanse_system")
            cursor.execute("ALTER ROLE challanse_app SET row_security = on")
        connection.commit()


if __name__ == "__main__":
    run_migrations()
