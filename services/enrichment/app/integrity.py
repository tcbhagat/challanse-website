import json
from typing import Any

import google.auth
import httpx
from google.auth.exceptions import GoogleAuthError
from google.auth.transport.requests import Request as GoogleAuthRequest

from .config import Settings


PLAY_INTEGRITY_SCOPE = "https://www.googleapis.com/auth/playintegrity"
PACKAGE_NAME = "com.constrovet.challanse"


def _credentials(settings: Settings):
    info = json.loads(settings.play_integrity_credentials_json)
    credentials, _ = google.auth.load_credentials_from_dict(info, scopes=[PLAY_INTEGRITY_SCOPE])
    credentials.refresh(GoogleAuthRequest())
    return credentials


def _trusted(payload: dict[str, Any], expected_request_hash: str) -> bool:
    request = payload.get("requestDetails", {})
    app = payload.get("appIntegrity", {})
    device = payload.get("deviceIntegrity", {})
    account = payload.get("accountDetails", {})
    verdicts = set(device.get("deviceRecognitionVerdict", []))
    return (
        request.get("requestHash") == expected_request_hash
        and request.get("requestPackageName") == PACKAGE_NAME
        and app.get("appRecognitionVerdict") == "PLAY_RECOGNIZED"
        and "MEETS_BASIC_INTEGRITY" in verdicts
        and account.get("appLicensingVerdict") == "LICENSED"
    )


def assess_play_integrity(settings: Settings, token: str, expected_request_hash: str) -> str:
    if settings.play_integrity_provider == "disabled":
        return "UNAVAILABLE"
    if not token:
        return "MISSING"
    try:
        credentials = _credentials(settings)
        response = httpx.post(
            f"https://playintegrity.googleapis.com/v1/{PACKAGE_NAME}:decodeIntegrityToken",
            headers={"Authorization": f"Bearer {credentials.token}", "Content-Type": "application/json"},
            json={"integrity_token": token},
            timeout=3.0,
        )
        response.raise_for_status()
        payload = response.json().get("tokenPayloadExternal", {})
        return "TRUSTED" if _trusted(payload, expected_request_hash) else "RISK"
    except (ValueError, TypeError, KeyError, json.JSONDecodeError, GoogleAuthError, httpx.HTTPError):
        return "UNAVAILABLE"
