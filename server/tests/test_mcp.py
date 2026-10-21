from __future__ import annotations

from zoneinfo import ZoneInfo

import pytest
from fastmcp import Client
from fastmcp.exceptions import ToolError

from relay_hub.config import Settings
from relay_hub.mcp_server import build_mcp
from relay_hub.nutrition import parse_batch
from relay_hub.store import AckResult, Store

LUNCH = {"energy_kcal": 610, "protein_g": 42, "carbohydrates_g": 12, "fat_g": 44}


@pytest.fixture
def mcp(store: Store, settings: Settings):
    return build_mcp(store, settings)


async def call(mcp, tool: str, **arguments) -> dict:
    async with Client(mcp) as client:
        return (await client.call_tool(tool, arguments)).structured_content


async def test_log_meal_queues_a_pending_entry(mcp) -> None:
    result = await call(mcp, "log_meal", **LUNCH, name="Chicken salad", meal_type="lunch")
    entry = result["entry"]
    assert result["created"] and "warnings" not in result
    assert entry["status"] == "pending" and entry["consumed_at"] == "2026-10-21T12:30:00+02:00"
    assert entry["nutrients"] == LUNCH and entry["summary"].startswith("Chicken salad · 610 kcal")
    pending = await call(mcp, "list_pending")
    assert pending["count"] == 1 and pending["entries"][0]["id"] == entry["id"]


async def test_log_meal_validates_and_warns(mcp) -> None:
    with pytest.raises(ToolError, match="future"):
        await call(mcp, "log_meal", **LUNCH, consumed_at="2026-10-22T12:00:00+02:00")
    with pytest.raises(ToolError):
        await call(mcp, "log_meal", **LUNCH, meal_type="brunch")
    result = await call(mcp, "log_meal", **(LUNCH | {"energy_kcal": 2000}))
    assert "macro estimate" in result["warnings"][0]


async def test_retries_with_an_idempotency_key_do_not_duplicate(mcp, store: Store) -> None:
    first = await call(mcp, "log_meal", **LUNCH, idempotency_key="lunch-2026-10-21")
    again = await call(mcp, "log_meal", **LUNCH, idempotency_key="lunch-2026-10-21")
    assert again["entry"]["id"] == first["entry"]["id"] and not again["created"]
    with pytest.raises(ToolError, match="idempotency_key"):
        await call(mcp, "log_meal", **(LUNCH | {"fat_g": 10}), idempotency_key="lunch-2026-10-21")
    assert len(store.list_writes()) == 1


async def test_cancel_and_recent_history(mcp, store: Store) -> None:
    queued = (await call(mcp, "log_meal", **LUNCH))["entry"]
    cancelled = await call(mcp, "cancel_entry", entry_id=queued["id"])
    assert cancelled["entry"]["status"] == "cancelled"
    with pytest.raises(ToolError, match="No entry"):
        await call(mcp, "cancel_entry", entry_id="missing")
    recent = await call(mcp, "list_recent", limit=5)
    assert [entry["status"] for entry in recent["entries"]] == ["cancelled"]
    assert (await call(mcp, "list_recent", status="written"))["entries"] == []


async def test_totals_include_uploaded_health_data_and_list_queued_entries(mcp, store: Store) -> None:
    code, _ = store.create_pairing_code("iPhone", 10)
    device_id = store.redeem_pairing_code(code, None)["device_id"]
    queued = (await call(mcp, "log_meal", **LUNCH, name="Soup"))["entry"]
    sample = {
        "uuid": "00000000-0000-4000-8000-000000000001",
        "type": "HKQuantityTypeIdentifierDietaryEnergyConsumed",
        "value": 350,
        "unit": "kcal",
        "start": "2026-10-21T06:00:00Z",
        "end": "2026-10-21T06:00:00Z",
        "food_name": "Oatmeal",
    }
    batch_id, samples, meals, deleted, _ = parse_batch(
        {"batch_id": "b", "samples": [sample]}, ZoneInfo("Europe/Brussels")
    )
    store.ingest_nutrition(
        device_id=device_id, batch_id=batch_id, samples=samples, meals=meals, deleted=deleted, rejected=0, complete=True
    )
    totals = await call(mcp, "get_nutrition_totals", start_date="2026-10-21")
    assert totals["days"] == [{"date": "2026-10-21", "samples": 1, "nutrients": {"energy_kcal": 350.0}}]
    assert [entry["id"] for entry in totals["not_in_totals_yet"]] == [queued["id"]]
    assert totals["removal_pending"] == []
    assert totals["units"]["energy_kcal"] == "kcal" and totals["nutrition_synced_at"]
    log = await call(mcp, "list_food_log")
    assert log["entries"][0]["name"] == "Oatmeal"
    week = await call(mcp, "get_nutrition_totals")
    assert len(week["days"]) == 7 and week["days"][-1]["date"] == "2026-10-21"
    with pytest.raises(ToolError, match="92 days"):
        await call(mcp, "get_nutrition_totals", start_date="2026-01-01")


async def test_totals_flag_written_entries_until_their_samples_arrive_and_pending_removals(mcp, store: Store) -> None:
    code, _ = store.create_pairing_code("iPhone", 10)
    device_id = store.redeem_pairing_code(code, None)["device_id"]
    entry = (await call(mcp, "log_meal", **LUNCH, name="Soup"))["entry"]
    store.pull_writes(device_id=device_id, kinds=["meal"], write_access=None, app_version=None)
    store.ack_write(write_id=entry["id"], device_id=device_id, result=AckResult.written, healthkit_ids=["A"])
    totals = await call(mcp, "get_nutrition_totals", start_date="2026-10-21")
    assert [item["status"] for item in totals["not_in_totals_yet"]] == ["written"]
    sample = {
        "uuid": "00000000-0000-4000-8000-000000000002",
        "type": "HKQuantityTypeIdentifierDietaryEnergyConsumed",
        "value": 610,
        "unit": "kcal",
        "start": "2026-10-21T10:30:00Z",
        "end": "2026-10-21T10:30:00Z",
        "write_id": entry["id"],
    }
    batch_id, samples, meals, deleted, _ = parse_batch({"batch_id": "b", "samples": [sample]}, ZoneInfo("UTC"))
    store.ingest_nutrition(
        device_id=device_id, batch_id=batch_id, samples=samples, meals=meals, deleted=deleted, rejected=0
    )
    totals = await call(mcp, "get_nutrition_totals", start_date="2026-10-21")
    assert totals["not_in_totals_yet"] == [] and totals["days"][0]["nutrients"]["energy_kcal"] == 610.0
    await call(mcp, "cancel_entry", entry_id=entry["id"])
    totals = await call(mcp, "get_nutrition_totals", start_date="2026-10-21")
    assert [item["id"] for item in totals["removal_pending"]] == [entry["id"]]


async def test_sync_status_reports_devices_and_queue(mcp, store: Store) -> None:
    code, _ = store.create_pairing_code("iPhone", 10)
    device_id = store.redeem_pairing_code(code, "Ben's iPhone")["device_id"]
    entry = (await call(mcp, "log_meal", **LUNCH))["entry"]
    store.pull_writes(device_id=device_id, kinds=["meal"], write_access={"meal": "authorized"}, app_version="1.1")
    store.ack_write(write_id=entry["id"], device_id=device_id, result=AckResult.written)
    status = await call(mcp, "get_sync_status")
    assert status["queue"] == {"written": 1}
    assert status["devices"][0]["name"] == "Ben's iPhone"
    assert status["devices"][0]["write_access"] == {"meal": "authorized"}
    assert status["server_time"].startswith("2026-10-21T12:30:00")
