from __future__ import annotations

from dataclasses import replace

from starlette.testclient import TestClient

from relay_hub.app import create_app
from relay_hub.config import Settings
from relay_hub.store import Store

from .conftest import MCP_TOKEN, bearer

MCP_HEADERS = {"Accept": "application/json, text/event-stream"}
INITIALIZE = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}},
}


def test_health_check_needs_no_credentials(client: TestClient) -> None:
    assert client.get("/healthz").json() == {"status": "ok"}


def test_pairing_returns_a_device_token(client: TestClient, store: Store) -> None:
    code, _ = store.create_pairing_code("iPhone", 10)
    response = client.post("/v1/pair", json={"code": code, "device_name": "Ben's iPhone"})
    assert response.status_code == 201
    body = response.json()
    assert body["token"].startswith("rh_") and body["name"] == "Ben's iPhone"
    assert body["time_zone"] == "Europe/Brussels"
    assert client.post("/v1/pair", json={"code": code}).status_code == 403
    assert client.post("/v1/pair", content=b"{").status_code == 400
    assert client.post("/v1/pair", json={"code": 12}).status_code == 400


def test_device_routes_require_a_device_token(client: TestClient, device_token: str) -> None:
    for token in (None, "wrong", MCP_TOKEN):
        headers = bearer(token) if token else {}
        response = client.post("/v1/writes/pull", json={"kinds": ["meal"]}, headers=headers)
        assert response.status_code == 401 and response.headers["www-authenticate"] == "Bearer"
    status = client.get("/v1/device", headers=bearer(device_token)).json()
    assert status["name"] == "Test iPhone" and status["actionable_writes"] == 0


def test_pull_and_acknowledge_over_http(client: TestClient, store: Store, device_token: str) -> None:
    entry, _ = store.create_write(
        kind="meal", data={"nutrients": {}}, summary="M", fingerprint="f", idempotency_key=None
    )
    headers = bearer(device_token)
    pulled = client.post(
        "/v1/writes/pull",
        json={"kinds": ["meal", "future-kind"], "write_access": {"meal": "authorized"}, "app_version": "1.1"},
        headers=headers,
    ).json()
    assert [write["id"] for write in pulled["writes"]] == [entry["id"]]
    url = f"/v1/writes/{entry['id']}/ack"
    assert client.post(url, json={"result": "maybe"}, headers=headers).status_code == 400
    assert client.post(url, json={"result": "written", "healthkit_ids": "x"}, headers=headers).status_code == 400
    assert client.post(url, json={"result": "deleted"}, headers=headers).status_code == 409
    assert client.post("/v1/writes/nope/ack", json={"result": "written"}, headers=headers).status_code == 404
    done = client.post(url, json={"result": "written", "healthkit_ids": ["A", "B"]}, headers=headers)
    assert done.json() == {"id": entry["id"], "status": "written"}


def test_nutrition_upload_reports_accepted_and_rejected(client: TestClient, store: Store, device_token: str) -> None:
    sample = {
        "uuid": "00000000-0000-4000-8000-000000000001",
        "type": "HKQuantityTypeIdentifierDietaryEnergyConsumed",
        "value": 610,
        "unit": "kcal",
        "start": "2026-10-21T10:00:00Z",
        "end": "2026-10-21T10:00:00Z",
    }
    body = {"batch_id": "b1", "samples": [sample, sample | {"unit": "kJ"}], "meals": [], "deleted": []}
    response = client.post("/v1/nutrition", json=body, headers=bearer(device_token))
    assert response.status_code == 200
    assert response.json()["accepted"] == {"samples": 1, "meals": 0, "deleted": 0}
    assert len(response.json()["rejected"]) == 1
    assert client.post("/v1/nutrition", json={"samples": []}, headers=bearer(device_token)).status_code == 422
    caught_up = client.post("/v1/nutrition", json={"batch_id": "b2", "complete": True}, headers=bearer(device_token))
    assert caught_up.status_code == 200 and store.last_nutrition_upload() is not None
    huge = b'{"batch_id": "b", "pad": "' + b"x" * (4 * 1024 * 1024) + b'"}'
    assert client.post("/v1/nutrition", content=huge, headers=bearer(device_token)).status_code == 400


def test_mcp_endpoint_requires_the_mcp_token(client: TestClient, device_token: str) -> None:
    assert client.post("/mcp", json=INITIALIZE, headers=MCP_HEADERS).status_code == 401
    assert client.post("/mcp", json=INITIALIZE, headers=MCP_HEADERS | bearer(device_token)).status_code == 401
    response = client.post("/mcp", json=INITIALIZE, headers=MCP_HEADERS | bearer(MCP_TOKEN))
    assert response.status_code == 200
    assert response.json()["result"]["serverInfo"]["name"] == "relay-hub"
    listing = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
    tools = client.post("/mcp", json=listing, headers=MCP_HEADERS | bearer(MCP_TOKEN)).json()["result"]["tools"]
    assert {tool["name"] for tool in tools} == {
        "log_meal",
        "list_pending",
        "list_recent",
        "cancel_entry",
        "get_nutrition_totals",
        "list_food_log",
        "get_sync_status",
    }


def test_optional_tailnet_identity_allowlist(settings: Settings, store: Store, device_token: str) -> None:
    locked = replace(settings, tailscale_logins=frozenset({"ben@github"}))
    with TestClient(create_app(locked, store)) as client:
        assert client.get("/healthz").status_code == 200
        assert client.get("/v1/device", headers=bearer(device_token)).status_code == 403
        spoofed = bearer(device_token) | {"Tailscale-User-Login": "someone@github"}
        assert client.get("/v1/device", headers=spoofed).status_code == 403
        allowed = bearer(device_token) | {"Tailscale-User-Login": "Ben@GitHub"}
        assert client.get("/v1/device", headers=allowed).status_code == 200
        assert client.post("/mcp", json=INITIALIZE, headers=MCP_HEADERS | bearer(MCP_TOKEN)).status_code == 403
