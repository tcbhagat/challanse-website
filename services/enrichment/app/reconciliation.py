import csv
import hashlib
from dataclasses import dataclass
from io import StringIO
from uuid import uuid4

from psycopg.rows import dict_row

from .schemas import VerifiedReviewEvent
from .tenancy import tenant_connection


@dataclass(frozen=True)
class PurchaseOrderRow:
    po_number: str
    material_code: str
    quantity: float
    unit: str


def normalize_unit(value: str) -> str:
    aliases = {"BAGS": "BAG", "BAG": "BAG", "TONNES": "MT", "TONNE": "MT", "TON": "MT", "MTS": "MT"}
    normalized = value.strip().upper()
    return aliases.get(normalized, normalized)


def parse_tally_csv(content: str) -> list[PurchaseOrderRow]:
    reader = csv.DictReader(StringIO(content))
    required = {"po_number", "material_code", "quantity", "unit"}
    if not reader.fieldnames or not required.issubset(reader.fieldnames):
        raise ValueError("invalid_tally_schema")
    rows: list[PurchaseOrderRow] = []
    for raw in reader:
        row = PurchaseOrderRow(
            po_number=str(raw["po_number"]).strip().upper(),
            material_code=str(raw["material_code"]).strip().upper(),
            quantity=float(raw["quantity"]),
            unit=normalize_unit(str(raw["unit"])),
        )
        if not row.po_number or not row.material_code or not row.unit or row.quantity < 0:
            raise ValueError("invalid_tally_row")
        rows.append(row)
    if not rows:
        raise ValueError("empty_tally_import")
    identities = {(row.po_number, row.material_code, row.unit) for row in rows}
    if len(identities) != len(rows):
        raise ValueError("duplicate_tally_row")
    return rows


def delta_rows(received: dict[tuple[str, str, str], float], purchase_orders: list[PurchaseOrderRow]) -> list[dict[str, object]]:
    return [
        {
            "po_number": row.po_number,
            "material_code": row.material_code,
            "unit": row.unit,
            "po_quantity": row.quantity,
            "site_received": received.get((row.po_number, row.material_code, row.unit), 0.0),
            "is_over": received.get((row.po_number, row.material_code, row.unit), 0.0) > row.quantity,
        }
        for row in purchase_orders
    ]


def import_tally_csv(database_url: str, organization_id: str, site_id: str, imported_by: str, content: str) -> tuple[str, bool, int]:
    rows = parse_tally_csv(content)
    checksum = hashlib.sha256(content.replace("\r\n", "\n").encode("utf-8")).hexdigest()
    import_id = uuid4()
    with tenant_connection(database_url, organization_id) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT id FROM tally_imports WHERE site_id = %s AND checksum = %s", (site_id, checksum))
            existing = cursor.fetchone()
            if existing:
                return str(existing[0]), True, len(rows)
            cursor.execute(
                "INSERT INTO tally_imports (id, organization_id, site_id, checksum, imported_by) VALUES (%s, %s, %s, %s, %s)",
                (import_id, organization_id, site_id, checksum, imported_by),
            )
            cursor.executemany(
                """
                INSERT INTO tally_import_rows (id, organization_id, import_id, site_id, po_number, material_code, quantity, unit)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                [(uuid4(), organization_id, import_id, site_id, row.po_number, row.material_code, row.quantity, row.unit) for row in rows],
            )
        connection.commit()
    return str(import_id), False, len(rows)


def record_verified_review(database_url: str, event: VerifiedReviewEvent) -> None:
    with tenant_connection(database_url, event.organization_id) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO verified_receipts (
                  receipt_id, organization_id, site_id, po_number, material_code, verified_quantity, unit,
                  reviewer_id, review_version, reviewed_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s::timestamptz)
                ON CONFLICT (receipt_id) DO UPDATE SET
                  po_number = excluded.po_number, material_code = excluded.material_code,
                  verified_quantity = excluded.verified_quantity, unit = excluded.unit,
                  reviewer_id = excluded.reviewer_id, review_version = excluded.review_version,
                  reviewed_at = excluded.reviewed_at, updated_at = NOW()
                WHERE verified_receipts.review_version < excluded.review_version
                """,
                (
                    event.receipt_id, event.organization_id, event.site_id, event.po_number.upper(), event.material_code.upper(),
                    event.verified_quantity, normalize_unit(event.unit), event.reviewer_id,
                    event.review_version, event.reviewed_at_iso8601,
                ),
            )
        connection.commit()


def reconciliation_for_site(database_url: str, organization_id: str, site_id: str) -> list[dict[str, object]]:
    with tenant_connection(database_url, organization_id, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT DISTINCT ON (r.po_number, r.material_code, r.unit)
                  r.po_number, r.material_code, r.quantity, r.unit
                FROM tally_import_rows r JOIN tally_imports i ON i.id = r.import_id
                WHERE r.site_id = %s
                ORDER BY r.po_number, r.material_code, r.unit, i.imported_at DESC
                """,
                (site_id,),
            )
            po_rows = [PurchaseOrderRow(str(row["po_number"]), str(row["material_code"]), float(row["quantity"]), str(row["unit"])) for row in cursor.fetchall()]
            cursor.execute(
                """
                SELECT po_number, material_code, unit, SUM(verified_quantity) AS received
                FROM verified_receipts WHERE site_id = %s GROUP BY po_number, material_code, unit
                """,
                (site_id,),
            )
            received = {(str(row["po_number"]), str(row["material_code"]), str(row["unit"])): float(row["received"]) for row in cursor.fetchall()}
    return delta_rows(received, po_rows)


def digest_history_for_site(database_url: str, organization_id: str, site_id: str) -> list[dict[str, object]]:
    with tenant_connection(database_url, organization_id, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT id, manager_id, period_start, period_end, receipt_count, failed_count, provider_status, created_at
                FROM notification_digests WHERE site_id = %s ORDER BY period_end DESC LIMIT 100
                """,
                (site_id,),
            )
            return [dict(row) for row in cursor.fetchall()]


def enrichment_status_for_site(database_url: str, organization_id: str, site_id: str, receipt_id: str | None = None) -> list[dict[str, object]]:
    with tenant_connection(database_url, organization_id, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT r.receipt_id, r.status AS enrichment_status, s.stage, s.status AS retry_status,
                       s.attempts, s.last_error_code, s.updated_at
                FROM enrichment_receipts r
                LEFT JOIN workflow_stages s ON s.receipt_id = r.receipt_id
                WHERE r.site_id = %s AND (%s::uuid IS NULL OR r.receipt_id = %s::uuid)
                ORDER BY r.created_at DESC, s.stage ASC LIMIT 500
                """,
                (site_id, receipt_id, receipt_id),
            )
            return [dict(row) for row in cursor.fetchall()]


def set_site_manager(database_url: str, organization_id: str, site_id: str, manager_id: str, active: bool) -> None:
    with tenant_connection(database_url, organization_id) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO site_managers (organization_id, site_id, manager_id, active) VALUES (%s, %s, %s, %s)
                ON CONFLICT (site_id, manager_id) DO UPDATE SET active = excluded.active
                """,
                (organization_id, site_id, manager_id, active),
            )
        connection.commit()
