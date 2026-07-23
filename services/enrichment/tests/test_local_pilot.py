from collections import namedtuple
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.config import Settings
from app.local_health import probe_ollama
from app.local_acceptance import ACCEPTANCE_ORGANIZATION_ID, ACCEPTANCE_SITE_ID
from app.local_diagnostics import LocalDiagnosticError, explain_safe_code
from app.local_fixtures import generate_local_fixtures
from app.local_ocr import normalize_text, run_local_ocr, validate_normalized
from app.local_storage import local_uploads_paused
from app.object_store import object_encryption_headers
from app.providers import run_ocr
from app.local_auth import login_page, parse_login_form
from app.local_test_runs import LocalTestRunError, _validated_artifact_directory
from app.main import _require_local_operator


class OllamaTagsResponse:
    def __init__(self, model_names: list[str]) -> None:
        self.model_names = model_names

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict[str, list[dict[str, str]]]:
        return {"models": [{"name": name} for name in self.model_names]}


class OllamaTagsClient:
    def __init__(self, model_names: list[str]) -> None:
        self.model_names = model_names

    def get(self, _url: str, **_kwargs) -> OllamaTagsResponse:
        return OllamaTagsResponse(self.model_names)


def test_ollama_health_requires_the_configured_model() -> None:
    settings = Settings(OLLAMA_MODEL="qwen2.5:7b")
    assert probe_ollama(settings, OllamaTagsClient(["qwen2.5:7b"])) is True
    assert probe_ollama(settings, OllamaTagsClient(["llama3.2:3b"])) is False


def test_acceptance_uses_an_isolated_tenant() -> None:
    assert str(ACCEPTANCE_ORGANIZATION_ID).endswith("0002")
    assert str(ACCEPTANCE_SITE_ID).endswith("0002")


def test_local_object_store_omits_cloud_kms_headers() -> None:
    settings = Settings(OBJECT_STORE_SSE_MODE="none")
    assert object_encryption_headers(settings, "tenant/site/receipt.webp", {"organization-id": "tenant"}) == {}


def test_production_object_store_keeps_kms_context() -> None:
    settings = Settings(KMS_KEY_ARN="arn:aws:kms:ap-south-1:111122223333:key/test")
    headers = object_encryption_headers(
        settings,
        "tenant/site/receipt.webp",
        {"organization-id": "tenant", "site-id": "site"},
    )
    assert headers["ServerSideEncryption"] == "aws:kms"
    assert headers["SSEKMSKeyId"] == settings.kms_key_arn
    assert "SSEKMSEncryptionContext" in headers


def test_normalizer_rejects_untraceable_values() -> None:
    normalized, warnings = validate_normalized(
        {
            "vendor": "Invented Vendor",
            "challan_number": "CH-1001",
            "material": "OPC Cement",
            "quantity": 250,
            "unit": "BAG",
        },
        "CH-1001 OPC Cement 25 BAG",
    )
    assert normalized == {
        "vendor": None,
        "challan_number": "CH-1001",
        "material": "OPC Cement",
        "quantity": None,
        "unit": "BAG",
    }
    assert warnings == ["vendor_untraceable", "quantity_untraceable"]


def test_ollama_receives_only_ocr_text_and_schema() -> None:
    class Response:
        def raise_for_status(self) -> None:
            return None

        def json(self):
            return {
                "model": "qwen2.5:7b",
                "response": '{"vendor":"Vendor One","challan_number":"CH-9","material":"Steel","quantity":12,"unit":"KG"}',
            }

    class Client:
        def post(self, url, **kwargs):
            assert url.endswith("/api/generate")
            assert "image" not in kwargs["json"]
            assert kwargs["json"]["format"]["additionalProperties"] is False
            assert "Vendor One CH-9 Steel 12 KG" in kwargs["json"]["prompt"]
            return Response()

    normalized, model, warnings = normalize_text(
        Settings(OLLAMA_MODEL="qwen2.5:7b"),
        "Vendor One CH-9 Steel 12 KG",
        Client(),
    )
    assert normalized["quantity"] == 12.0
    assert model == "qwen2.5:7b"
    assert warnings == []


def test_ollama_failure_preserves_ocr_and_forces_review(monkeypatch) -> None:
    from app import local_ocr

    monkeypatch.setattr(local_ocr, "extract_text", lambda *_args: ("Vendor One CH-9 Steel 12 KG", 91.0, "tesseract 5"))

    class Client:
        def post(self, *_args, **_kwargs):
            raise TimeoutError("synthetic timeout")

    result = run_local_ocr(Settings(), b"png", Client())
    assert result.raw_text == "Vendor One CH-9 Steel 12 KG"
    assert result.confidence == 59.0
    assert result.normalized["vendor"] is None
    assert result.warnings == ["ollama_TimeoutError"]


def test_provider_marks_local_invalid_normalization_for_review(monkeypatch) -> None:
    from app import local_ocr

    monkeypatch.setattr(local_ocr, "extract_text", lambda *_args: ("CH-9 Steel 12 KG", 88.0, "tesseract 5"))

    class Response:
        def raise_for_status(self) -> None:
            return None

        def json(self):
            return {"model": "qwen2.5:7b", "response": '{"vendor":"Invented"}'}

    class Client:
        def post(self, *_args, **_kwargs):
            return Response()

    result = run_ocr(Settings(OCR_PROVIDER="local"), b"png", Client())
    assert result.confidence == 59.0
    assert result.raw_json["warnings"] == ["normalization_schema_invalid"]


def test_local_uploads_pause_at_ninety_percent(monkeypatch, tmp_path) -> None:
    DiskUsage = namedtuple("usage", "total used free")
    monkeypatch.setattr("app.local_storage.shutil.disk_usage", lambda _path: DiskUsage(1000, 900, 100))
    settings = Settings(SYNTHETIC_MODE=True, LOCAL_DATA_ROOT=str(tmp_path), LOCAL_STORAGE_LIMIT_BYTES=1000)
    assert local_uploads_paused(settings) is True


def test_production_configuration_rejects_local_providers() -> None:
    settings = Settings(ENVIRONMENT="production", OCR_PROVIDER="local", EVENT_QUEUE_PROVIDER="postgres")
    errors = settings.production_errors()
    assert "EVENT_QUEUE_PROVIDER_must_be_sqs" in errors
    assert "OCR_PROVIDER_must_be_textract" in errors


def test_local_login_form_does_not_allow_open_redirect() -> None:
    page = login_page(next_path="//attacker.example")
    assert 'value="/"' in page
    assert "attacker.example" not in page


def test_local_login_form_parsing_is_bounded_and_explicit() -> None:
    assert parse_login_form(b"email=a%40example.com&password=long-password&second_factor=123456&next=%2Freview") == (
        "a@example.com", "long-password", "123456", "/review"
    )


def test_local_fixtures_are_deterministic_and_synthetic(tmp_path) -> None:
    first = generate_local_fixtures(tmp_path)
    first_hashes = {path.name: path.read_bytes() for path in tmp_path.iterdir()}
    second = generate_local_fixtures(tmp_path)
    assert first == second
    assert first_hashes == {path.name: path.read_bytes() for path in tmp_path.iterdir()}
    assert len(first) == 5
    assert all(item["synthetic"] is True for item in first)
    assert (tmp_path / "synthetic-tally-malformed.csv").read_text().startswith("purchase_order,item,qty")
    assert "PO-SYN-OVER" in (tmp_path / "synthetic-tally-over-po.csv").read_text()


def test_local_diagnostics_reject_unapproved_or_nonlocal_requests() -> None:
    with pytest.raises(LocalDiagnosticError, match="diagnostic_code_not_allowed"):
        explain_safe_code(Settings(ENVIRONMENT="local-pilot", SYNTHETIC_MODE=True), "show_database_password")
    with pytest.raises(LocalDiagnosticError, match="local_diagnostics_unavailable"):
        explain_safe_code(Settings(ENVIRONMENT="production", SYNTHETIC_MODE=False), "queue_stalled")


def test_local_diagnostic_falls_back_without_exposing_runtime_data(monkeypatch) -> None:
    monkeypatch.setattr("app.local_diagnostics.httpx.post", lambda *_args, **_kwargs: (_ for _ in ()).throw(TimeoutError()))
    result = explain_safe_code(Settings(ENVIRONMENT="local-pilot", SYNTHETIC_MODE=True), "queue_stalled")
    assert result["modelAvailable"] is False
    assert result["advisory"] == ""
    assert "credential" not in str(result).lower()


def test_local_operator_requires_synthetic_org_admin() -> None:
    settings = Settings(ENVIRONMENT="local-pilot", SYNTHETIC_MODE=True)
    _require_local_operator(SimpleNamespace(role="ORG_ADMIN"), settings)
    with pytest.raises(HTTPException) as reviewer_error:
        _require_local_operator(SimpleNamespace(role="REVIEWER"), settings)
    assert reviewer_error.value.status_code == 403
    with pytest.raises(HTTPException) as production_error:
        _require_local_operator(
            SimpleNamespace(role="ORG_ADMIN"),
            Settings(ENVIRONMENT="production", SYNTHETIC_MODE=False),
        )
    assert production_error.value.status_code == 404


def test_local_test_artifacts_cannot_escape_encrypted_export_root(tmp_path) -> None:
    settings = Settings(
        ENVIRONMENT="local-pilot",
        SYNTHETIC_MODE=True,
        LOCAL_DATA_ROOT=str(tmp_path / "encrypted"),
    )
    allowed = tmp_path / "encrypted" / "exports" / "test-runs" / "run-1"
    allowed.mkdir(parents=True)
    assert _validated_artifact_directory(settings, str(allowed)) == allowed.resolve()
    with pytest.raises(LocalTestRunError, match="local_test_artifact_path_invalid"):
        _validated_artifact_directory(settings, str(tmp_path / "outside"))


def test_raw_migrations_do_not_require_runtime_database_roles() -> None:
    migration_root = Path(__file__).resolve().parents[1] / "migrations"
    combined = "\n".join(path.read_text(encoding="utf-8") for path in sorted(migration_root.glob("*.sql")))
    assert "challanse_app" not in combined
    assert "challanse_system" not in combined
