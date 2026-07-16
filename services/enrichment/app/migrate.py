from pathlib import Path

import psycopg

from .config import get_settings


def run_migrations() -> None:
    settings = get_settings()
    if not settings.database_url:
        raise RuntimeError("database_url_unconfigured")
    migration_dir = Path(__file__).resolve().parent.parent / "migrations"
    with psycopg.connect(settings.database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())")
            for path in sorted(migration_dir.glob("*.sql")):
                cursor.execute("SELECT 1 FROM schema_migrations WHERE version = %s", (path.name,))
                if cursor.fetchone():
                    continue
                cursor.execute(path.read_text(encoding="utf-8"))
                cursor.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (path.name,))
        connection.commit()


if __name__ == "__main__":
    run_migrations()
