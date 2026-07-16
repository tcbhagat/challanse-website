from contextlib import contextmanager
import hashlib
import hmac
import os
from collections.abc import Mapping
from typing import Iterator

import psycopg
from psycopg import Connection


def set_tenant_context(connection: Connection, organization_id: str) -> None:
    secret = os.getenv("TENANT_CONTEXT_HMAC_KEY", "")
    if not secret:
        raise RuntimeError("tenant_context_hmac_key_unconfigured")
    try:
        secret_bytes = bytes.fromhex(secret)
    except ValueError as error:
        raise RuntimeError("tenant_context_hmac_key_invalid") from error
    if len(secret_bytes) < 32:
        raise RuntimeError("tenant_context_hmac_key_invalid")
    row = connection.execute(
        "SELECT pg_backend_pid() AS backend_pid, txid_current() AS transaction_id"
    ).fetchone()
    if isinstance(row, Mapping):
        backend_pid = row["backend_pid"]
        transaction_id = row["transaction_id"]
    else:
        backend_pid, transaction_id = row
    message = f"{organization_id}:{backend_pid}:{transaction_id}".encode()
    signature = hmac.new(secret_bytes, message, hashlib.sha256).hexdigest()
    connection.execute("SELECT challanse_set_tenant_context(%s::uuid, %s)", (organization_id, signature))


@contextmanager
def tenant_connection(database_url: str, organization_id: str, **kwargs) -> Iterator[Connection]:
    with psycopg.connect(database_url, **kwargs) as connection:
        set_tenant_context(connection, organization_id)
        yield connection


@contextmanager
def system_connection(database_url: str, **kwargs) -> Iterator[Connection]:
    system_database_url = os.getenv("SYSTEM_DATABASE_URL", "") or database_url
    with psycopg.connect(system_database_url, **kwargs) as connection:
        yield connection
