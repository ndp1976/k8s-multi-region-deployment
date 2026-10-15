"""Unit tests for web-app-a. No network or cluster needed.

Run from this directory:  python -m pytest -v
"""
import json
import logging
from unittest import mock

import pytest
import requests

import app as app_module

SECRET = "s3cret"
AUTH = {"Authorization": SECRET}


@pytest.fixture(autouse=True)
def _config(monkeypatch):
    monkeypatch.setattr(app_module, "API_SECRET", SECRET)
    monkeypatch.setattr(app_module, "WEB_APP_B_URL", "http://web-app-b.test:8080")
    monkeypatch.setattr(app_module, "SPIKE_SECONDS", 20)


@pytest.fixture
def client():
    return app_module.app.test_client()


def _response(status, body=None, text=None):
    """Build a real requests.Response so raise_for_status()/json() behave."""
    resp = requests.Response()
    resp.status_code = status
    resp._content = (json.dumps(body) if text is None else text).encode()
    return resp


# ---------------------------------------------------------------------------
# /status
# ---------------------------------------------------------------------------
class TestStatus:
    def test_ok_without_auth(self, client):
        resp = client.get("/status")
        assert resp.status_code == 200
        assert resp.get_json() == {"app": app_module.APP_NAME, "env": app_module.APP_ENV, "status": "ok"}


# ---------------------------------------------------------------------------
# auth_required
# ---------------------------------------------------------------------------
class TestAuth:
    @pytest.mark.parametrize("path,method", [("/message", "get"), ("/spike", "post")])
    def test_missing_header_is_401(self, client, path, method):
        resp = getattr(client, method)(path)
        assert resp.status_code == 401
        assert resp.get_json() == {"error": "invalid credentials"}

    @pytest.mark.parametrize("header", ["wrong", "s3cre", "s3cret ", "S3CRET", f"Bearer {SECRET}"])
    def test_wrong_value_is_401(self, client, header):
        resp = client.get("/message", headers={"Authorization": header})
        assert resp.status_code == 401

    @pytest.mark.parametrize("secret", ["", None])
    def test_unset_secret_fails_closed(self, client, monkeypatch, secret):
        monkeypatch.setattr(app_module, "API_SECRET", secret or "")
        # An empty header must NOT match an empty secret.
        for headers in ({}, {"Authorization": ""}, AUTH):
            resp = client.get("/message", headers=headers)
            assert resp.status_code == 503
            assert "not configured" in resp.get_json()["error"]

    def test_status_is_not_protected_when_secret_unset(self, client, monkeypatch):
        monkeypatch.setattr(app_module, "API_SECRET", "")
        assert client.get("/status").status_code == 200

    def test_non_ascii_header_does_not_crash(self, client):
        resp = client.get("/message", headers={"Authorization": "pässwörd"})
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# /message
# ---------------------------------------------------------------------------
class TestMessage:
    def test_success_forwards_request_to_web_app_b(self, client):
        upstream = _response(200, {"key": "k1", "value": "v", "found": True})
        with mock.patch.object(app_module.requests, "get", return_value=upstream) as get:
            resp = client.get("/message?key=k1", headers=AUTH)

        assert resp.status_code == 200
        assert resp.get_json() == {"key": "k1", "value": "v", "found": True}
        get.assert_called_once_with(
            "http://web-app-b.test:8080/get",
            params={"key": "k1"},
            headers={"Authorization": SECRET},
            timeout=5,
        )

    def test_key_defaults_to_greeting(self, client):
        upstream = _response(200, {"found": True})
        with mock.patch.object(app_module.requests, "get", return_value=upstream) as get:
            client.get("/message", headers=AUTH)
        assert get.call_args.kwargs["params"] == {"key": "greeting"}

    def test_missing_key_passes_404_through(self, client):
        body = {"key": "nope", "value": None, "found": False}
        with mock.patch.object(app_module.requests, "get", return_value=_response(404, body)):
            resp = client.get("/message?key=nope", headers=AUTH)
        assert resp.status_code == 404
        assert resp.get_json() == body

    def test_non_json_404_becomes_502(self, client):
        upstream = _response(404, text="route not found")
        with mock.patch.object(app_module.requests, "get", return_value=upstream):
            resp = client.get("/message", headers=AUTH)
        assert resp.status_code == 502
        assert "error" in resp.get_json()

    @pytest.mark.parametrize("status", [400, 500, 503])
    def test_other_upstream_errors_become_502(self, client, status):
        upstream = _response(status, {"error": "boom"})
        with mock.patch.object(app_module.requests, "get", return_value=upstream):
            resp = client.get("/message", headers=AUTH)
        assert resp.status_code == 502

    @pytest.mark.parametrize(
        "exc",
        [requests.exceptions.ConnectTimeout("t"), requests.exceptions.ConnectionError("c")],
    )
    def test_network_errors_become_502(self, client, exc):
        with mock.patch.object(app_module.requests, "get", side_effect=exc):
            resp = client.get("/message", headers=AUTH)
        assert resp.status_code == 502
        assert resp.get_json()["error"]

    def test_upstream_not_called_when_unauthenticated(self, client):
        with mock.patch.object(app_module.requests, "get") as get:
            client.get("/message", headers={"Authorization": "wrong"})
        get.assert_not_called()


# ---------------------------------------------------------------------------
# /spike  (threading.Thread is mocked so no CPU is actually burned)
# ---------------------------------------------------------------------------
class TestSpike:
    @pytest.fixture
    def thread(self):
        with mock.patch.object(app_module.threading, "Thread") as thread_cls:
            yield thread_cls

    def _duration(self, thread_cls):
        return thread_cls.call_args.kwargs["args"][0]

    def test_uses_requested_seconds(self, client, thread):
        resp = client.post("/spike", json={"seconds": 30}, headers=AUTH)
        assert resp.status_code == 200
        assert resp.get_json() == {
            "message": "CPU spike started for 30 seconds",
            "triggered_by": "api-secret",
        }
        assert self._duration(thread) == 30
        thread.return_value.start.assert_called_once()
        assert thread.call_args.kwargs["daemon"] is True

    def test_defaults_to_spike_seconds_without_body(self, client, thread):
        client.post("/spike", headers=AUTH)
        assert self._duration(thread) == 20

    def test_defaults_when_seconds_missing_from_json(self, client, thread):
        client.post("/spike", json={}, headers=AUTH)
        assert self._duration(thread) == 20

    @pytest.mark.parametrize("requested,expected", [(500, 120), (120, 120), (0, 1), (-5, 1), (1, 1)])
    def test_duration_is_clamped(self, client, thread, requested, expected):
        client.post("/spike", json={"seconds": requested}, headers=AUTH)
        assert self._duration(thread) == expected

    def test_no_thread_started_when_unauthenticated(self, client, thread):
        resp = client.post("/spike", json={"seconds": 5}, headers={"Authorization": "wrong"})
        assert resp.status_code == 401
        thread.assert_not_called()


# ---------------------------------------------------------------------------
# audit logging
# ---------------------------------------------------------------------------
class TestAuditLog:
    def _records(self, caplog):
        return [json.loads(r.getMessage()) for r in caplog.records if r.name == "audit"]

    def test_anonymous_request(self, client, caplog):
        caplog.set_level(logging.INFO, logger="audit")
        client.get("/status")
        (record,) = self._records(caplog)
        assert record["audit"] is True
        assert record["app"] == app_module.APP_NAME
        assert record["method"] == "GET"
        assert record["path"] == "/status"
        assert record["status"] == 200
        assert record["subject"] == "anonymous"
        assert record["duration_ms"] >= 0
        assert record["timestamp"].endswith("Z")

    def test_rejected_request_is_anonymous(self, client, caplog):
        caplog.set_level(logging.INFO, logger="audit")
        client.get("/message", headers={"Authorization": "wrong"})
        (record,) = self._records(caplog)
        assert record["status"] == 401
        assert record["subject"] == "anonymous"

    def test_authenticated_request_records_subject(self, client, caplog):
        caplog.set_level(logging.INFO, logger="audit")
        with mock.patch.object(app_module.threading, "Thread"):
            client.post("/spike", headers=AUTH)
        (record,) = self._records(caplog)
        assert record["subject"] == "api-secret"

    def test_secret_is_never_logged(self, client, caplog):
        caplog.set_level(logging.INFO, logger="audit")
        client.get("/message", headers=AUTH)
        assert SECRET not in caplog.text
