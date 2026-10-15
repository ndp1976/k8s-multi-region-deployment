"""Unit tests for web-app-b. No Redis server or cluster needed.

Run from this directory:  python -m pytest -v
(conftest.py sets the env vars app.py needs at import time.)
"""
import base64
import json
import logging
import shutil
import ssl
import subprocess
from unittest import mock

import pytest
import redis

import app as app_module


@pytest.fixture
def client():
    return app_module.app.test_client()


@pytest.fixture
def fake_redis(monkeypatch):
    """Replace the module-level Redis client so no connection is attempted."""
    fake = mock.MagicMock(spec=redis.Redis)
    monkeypatch.setattr(app_module, "r", fake)
    return fake


# ---------------------------------------------------------------------------
# /status
# ---------------------------------------------------------------------------
class TestStatus:
    def test_ok_when_redis_pings(self, client, fake_redis):
        fake_redis.ping.return_value = True
        resp = client.get("/status")
        assert resp.status_code == 200
        assert resp.get_json() == {"app": "web-app-b", "status": "ok", "redis_ping": True}

    def test_degraded_when_redis_errors(self, client, fake_redis):
        fake_redis.ping.side_effect = redis.ConnectionError("down")
        resp = client.get("/status")
        assert resp.status_code == 503
        body = resp.get_json()
        assert body["status"] == "degraded"
        assert "down" in body["error"]

    def test_degraded_on_timeout(self, client, fake_redis):
        fake_redis.ping.side_effect = redis.TimeoutError("slow")
        assert client.get("/status").status_code == 503


# ---------------------------------------------------------------------------
# /get
# ---------------------------------------------------------------------------
class TestGet:
    def test_found(self, client, fake_redis):
        fake_redis.get.return_value = "hello"
        resp = client.get("/get?key=greeting")
        assert resp.status_code == 200
        assert resp.get_json() == {"key": "greeting", "value": "hello", "found": True}
        fake_redis.get.assert_called_once_with("greeting")

    def test_not_found_is_404(self, client, fake_redis):
        fake_redis.get.return_value = None
        resp = client.get("/get?key=nope")
        assert resp.status_code == 404
        assert resp.get_json() == {"key": "nope", "value": None, "found": False}

    def test_empty_string_value_is_found(self, client, fake_redis):
        # An empty value is not the same as a missing key.
        fake_redis.get.return_value = ""
        resp = client.get("/get?key=empty")
        assert resp.status_code == 200
        assert resp.get_json()["found"] is True

    @pytest.mark.parametrize("url", ["/get", "/get?key="])
    def test_missing_key_param_is_400(self, client, fake_redis, url):
        resp = client.get(url)
        assert resp.status_code == 400
        assert "key" in resp.get_json()["error"]
        fake_redis.get.assert_not_called()

    def test_redis_error_is_503(self, client, fake_redis):
        fake_redis.get.side_effect = redis.ConnectionError("lost")
        resp = client.get("/get?key=k")
        assert resp.status_code == 503
        assert "lost" in resp.get_json()["error"]

    def test_no_auth_required(self, client, fake_redis):
        # Access control is Istio's job now; the app itself has no auth check.
        fake_redis.get.return_value = "v"
        assert client.get("/get?key=k").status_code == 200


# ---------------------------------------------------------------------------
# /set
# ---------------------------------------------------------------------------
class TestSet:
    def test_set_without_ttl(self, client, fake_redis):
        resp = client.post("/set", json={"key": "k", "value": "v"})
        assert resp.status_code == 200
        assert resp.get_json() == {"key": "k", "stored": True}
        fake_redis.set.assert_called_once_with("k", "v")
        fake_redis.setex.assert_not_called()

    def test_set_with_ttl_uses_setex(self, client, fake_redis):
        resp = client.post("/set", json={"key": "k", "value": "v", "ttl": 60})
        assert resp.status_code == 200
        fake_redis.setex.assert_called_once_with(name="k", time=60, value="v")
        fake_redis.set.assert_not_called()

    def test_ttl_string_is_coerced_to_int(self, client, fake_redis):
        client.post("/set", json={"key": "k", "value": "v", "ttl": "90"})
        fake_redis.setex.assert_called_once_with(name="k", time=90, value="v")

    @pytest.mark.parametrize("ttl", [0, None])
    def test_falsy_ttl_means_no_expiry(self, client, fake_redis, ttl):
        client.post("/set", json={"key": "k", "value": "v", "ttl": ttl})
        fake_redis.set.assert_called_once_with("k", "v")
        fake_redis.setex.assert_not_called()

    def test_falsy_but_present_value_is_stored(self, client, fake_redis):
        # Only a missing value (None) is rejected; "" is a valid value.
        resp = client.post("/set", json={"key": "k", "value": ""})
        assert resp.status_code == 200
        fake_redis.set.assert_called_once_with("k", "")

    @pytest.mark.parametrize(
        "body",
        [{}, {"key": "k"}, {"value": "v"}, {"key": "", "value": "v"}, {"key": "k", "value": None}],
    )
    def test_missing_fields_is_400(self, client, fake_redis, body):
        resp = client.post("/set", json=body)
        assert resp.status_code == 400
        fake_redis.set.assert_not_called()
        fake_redis.setex.assert_not_called()

    def test_invalid_json_is_400(self, client, fake_redis):
        resp = client.post("/set", data="not json", content_type="application/json")
        assert resp.status_code == 400
        fake_redis.set.assert_not_called()

    def test_redis_error_is_503(self, client, fake_redis):
        fake_redis.set.side_effect = redis.ConnectionError("lost")
        resp = client.post("/set", json={"key": "k", "value": "v"})
        assert resp.status_code == 503

    def test_get_is_not_allowed(self, client):
        assert client.get("/set").status_code == 405


# ---------------------------------------------------------------------------
# _decode_cert
# ---------------------------------------------------------------------------
def _make_pem() -> bytes:
    if not shutil.which("openssl"):
        pytest.skip("openssl not available")
    return subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", "/dev/null", "-subj", "/CN=test", "-days", "1"],
        check=True, capture_output=True,
    ).stdout


@pytest.fixture(scope="module")
def pem() -> bytes:
    return _make_pem()


class TestDecodeCert:
    def test_raw_pem(self, pem):
        assert app_module._decode_cert(pem.decode()) == pem.strip()

    def test_base64(self, pem):
        assert app_module._decode_cert(base64.b64encode(pem).decode()) == pem

    def test_double_base64(self, pem):
        once = base64.b64encode(pem)
        assert app_module._decode_cert(base64.b64encode(once).decode()) == pem

    def test_surrounding_whitespace_is_stripped(self, pem):
        assert app_module._decode_cert("\n  " + base64.b64encode(pem).decode() + "\n") == pem

    def test_result_is_loadable_by_ssl(self, pem, tmp_path):
        cert = tmp_path / "ca.pem"
        cert.write_bytes(app_module._decode_cert(base64.b64encode(pem).decode()))
        ssl.create_default_context(cafile=str(cert))  # raises if not valid PEM

    @pytest.mark.parametrize("bad", ["MANAGED_BY_SECRETS_MANAGER", "abcd", "", "   ", "!!!not-base64!!!"])
    def test_invalid_input_raises_with_diagnostic(self, bad):
        with pytest.raises(ValueError, match="REDIS_CERT_B64 is not a PEM certificate"):
            app_module._decode_cert(bad)

    def test_error_message_does_not_leak_full_value(self):
        secret_like = "A" * 5 + "!" + "B" * 200
        with pytest.raises(ValueError) as exc:
            app_module._decode_cert(secret_like)
        assert secret_like not in str(exc.value)
        assert "length 206" in str(exc.value)

    def test_base64_of_non_pem_is_rejected(self):
        with pytest.raises(ValueError):
            app_module._decode_cert(base64.b64encode(b"just some text").decode())


# ---------------------------------------------------------------------------
# _build_redis_client
# ---------------------------------------------------------------------------
class TestBuildRedisClient:
    @pytest.fixture
    def redis_ctor(self, monkeypatch):
        ctor = mock.MagicMock()
        monkeypatch.setattr(app_module.redis, "Redis", ctor)
        return ctor

    def test_without_cert(self, monkeypatch, redis_ctor):
        monkeypatch.setattr(app_module, "REDIS_CERT_B64", "")
        monkeypatch.setattr(app_module, "REDIS_USERNAME", "svc-user")
        app_module._build_redis_client()

        kwargs = redis_ctor.call_args.kwargs
        assert kwargs["host"] == app_module.REDIS_HOST
        assert kwargs["port"] == app_module.REDIS_PORT
        assert kwargs["username"] == "svc-user"
        assert kwargs["password"] == app_module.REDIS_PASSWORD
        assert kwargs["ssl"] is True
        assert kwargs["ssl_ca_certs"] is None
        assert kwargs["decode_responses"] is True
        assert kwargs["socket_connect_timeout"] == 5

    def test_with_cert_writes_ca_file(self, monkeypatch, redis_ctor, pem):
        monkeypatch.setattr(app_module, "REDIS_CERT_B64", base64.b64encode(pem).decode())
        app_module._build_redis_client()

        ca_path = redis_ctor.call_args.kwargs["ssl_ca_certs"]
        assert ca_path and ca_path.endswith(".pem")
        with open(ca_path, "rb") as fh:
            assert fh.read() == pem

    def test_invalid_cert_fails_fast(self, monkeypatch, redis_ctor):
        monkeypatch.setattr(app_module, "REDIS_CERT_B64", "MANAGED_BY_SECRETS_MANAGER")
        with pytest.raises(ValueError):
            app_module._build_redis_client()
        redis_ctor.assert_not_called()


# ---------------------------------------------------------------------------
# audit logging
# ---------------------------------------------------------------------------
class TestAuditLog:
    def test_record_fields(self, client, fake_redis, caplog):
        fake_redis.ping.return_value = True
        caplog.set_level(logging.INFO, logger="audit")
        client.get("/status")

        (record,) = [json.loads(r.getMessage()) for r in caplog.records if r.name == "audit"]
        assert record["audit"] is True
        assert record["app"] == app_module.APP_NAME
        assert record["method"] == "GET"
        assert record["path"] == "/status"
        assert record["status"] == 200
        assert record["duration_ms"] >= 0
        assert record["timestamp"].endswith("Z")

    def test_no_subject_field_after_iam_removal(self, client, fake_redis, caplog):
        fake_redis.ping.return_value = True
        caplog.set_level(logging.INFO, logger="audit")
        client.get("/status")
        (record,) = [json.loads(r.getMessage()) for r in caplog.records if r.name == "audit"]
        assert "subject" not in record

    def test_values_are_not_logged(self, client, fake_redis, caplog):
        caplog.set_level(logging.INFO, logger="audit")
        client.post("/set", json={"key": "k", "value": "super-secret-value"})
        assert "super-secret-value" not in caplog.text
