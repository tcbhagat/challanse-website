import base64
import json
import os
from typing import Any

import boto3
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .config import Settings


def _context(site_id: str, record_id: str, field: str) -> dict[str, str]:
    return {"service": "challanse-enrichment", "site_id": site_id, "record_id": record_id, "field": field}


def encrypt_json(settings: Settings, site_id: str, record_id: str, field: str, value: Any, kms_client=None) -> bytes:
    if not settings.kms_key_arn:
        raise RuntimeError("kms_key_arn_unconfigured")
    kms = kms_client or boto3.client("kms", region_name=settings.aws_region)
    context = _context(site_id, record_id, field)
    data_key = kms.generate_data_key(KeyId=settings.kms_key_arn, KeySpec="AES_256", EncryptionContext=context)
    plaintext_key = bytearray(data_key["Plaintext"])
    try:
        nonce = os.urandom(12)
        plaintext = json.dumps(value, separators=(",", ":")).encode("utf-8")
        aad = json.dumps(context, sort_keys=True).encode("utf-8")
        ciphertext = AESGCM(bytes(plaintext_key)).encrypt(nonce, plaintext, aad)
        return json.dumps({
            "v": 1,
            "key": base64.b64encode(data_key["CiphertextBlob"]).decode("ascii"),
            "nonce": base64.b64encode(nonce).decode("ascii"),
            "ciphertext": base64.b64encode(ciphertext).decode("ascii"),
        }, separators=(",", ":")).encode("utf-8")
    finally:
        for index in range(len(plaintext_key)):
            plaintext_key[index] = 0


def decrypt_json(settings: Settings, site_id: str, record_id: str, field: str, envelope_bytes: bytes, kms_client=None) -> Any:
    if not settings.kms_key_arn:
        raise RuntimeError("kms_key_arn_unconfigured")
    envelope = json.loads(envelope_bytes.decode("utf-8"))
    if envelope.get("v") != 1:
        raise ValueError("unsupported_encryption_envelope")
    context = _context(site_id, record_id, field)
    kms = kms_client or boto3.client("kms", region_name=settings.aws_region)
    response = kms.decrypt(
        KeyId=settings.kms_key_arn,
        CiphertextBlob=base64.b64decode(envelope["key"]),
        EncryptionContext=context,
    )
    plaintext_key = bytearray(response["Plaintext"])
    try:
        plaintext = AESGCM(bytes(plaintext_key)).decrypt(
            base64.b64decode(envelope["nonce"]),
            base64.b64decode(envelope["ciphertext"]),
            json.dumps(context, sort_keys=True).encode("utf-8"),
        )
        return json.loads(plaintext)
    finally:
        for index in range(len(plaintext_key)):
            plaintext_key[index] = 0
