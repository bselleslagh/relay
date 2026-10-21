from __future__ import annotations

from datetime import date

import pytest
from fastmcp import Client
from fastmcp.exceptions import ToolError

from relay_hub.config import Settings
from relay_hub.mcp_server import build_mcp
from relay_hub.store import Store
from relay_hub.summaries import daily_summary, data_types, key, raw_samples, resolve, sleep_nights, workouts

from .conftest import upload

STEPS = "HKQuantityTypeIdentifierStepCount"
HEART = "HKQuantityTypeIdentifierHeartRate"
SLEEP = "HKCategoryTypeIdentifierSleepAnalysis"


def uid(number: int) -> str:
    return f"00000000-0000-4000-8000-{number:012d}"


def quantity(number: int, type_id: str, value: float, unit: str, start: str, end: str | None = None, **extra) -> dict:
    return {
        "uuid": uid(number),
        "type": type_id,
        "value": value,
        "unit": unit,
        "start": start,
        "end": end or start,
        "time_zone": "Europe/Brussels",
        "source": {"name": "Apple Watch", "bundle_id": "com.apple.health", "device": "Watch"},
    } | extra


def stage(number: int, label: str, start: str, end: str, source: str = "Apple Watch") -> dict:
    values = {"in_bed": 0, "asleep": 1, "awake": 2, "core": 3, "deep": 4, "rem": 5}
    return {
        "uuid": uid(number),
        "type": SLEEP,
        "value": values[label],
        "label": label,
        "start": start,
        "end": end,
        "time_zone": "Europe/Brussels",
        "source": {"name": source},
    }


def test_type_keys_and_lookup(store: Store) -> None:
    assert key("HKQuantityTypeIdentifierHeartRateVariabilitySDNN") == "heart_rate_variability_sdnn"
    assert key("HKQuantityTypeIdentifierVO2Max") == "vo2_max"
    assert key("HKCategoryTypeIdentifierSleepAnalysis") == "sleep_analysis"
    assert key("HKWorkoutTypeIdentifier") == "workouts"
    assert key("HKCorrelationTypeIdentifierFood") == "food"
    for name in ("step_count", STEPS, "Step Count", " STEP_COUNT "):
        assert resolve(store, name)["id"] == STEPS
    assert resolve(store, "nope") is None


def test_registry_validates_types_units_and_kinds(store: Store, device_id: str) -> None:
    counts, batch = upload(
        store,
        device_id,
        {
            "batch_id": "b",
            "quantities": [
                quantity(1, STEPS, 1200, "count", "2026-10-21T08:00:00Z", "2026-10-21T08:30:00Z"),
                quantity(2, STEPS, 1200, "steps", "2026-10-21T08:00:00Z"),
                quantity(3, SLEEP, 1, "count", "2026-10-21T08:00:00Z"),
                quantity(4, "HKQuantityTypeIdentifierUnknown", 1, "count", "2026-10-21T08:00:00Z"),
                quantity(
                    5, "HKQuantityTypeIdentifierBodyMass", 82.4, "kg", "2026-10-21T06:00:00Z", metadata={"k": "v"}
                ),
            ],
            "daily": [{"type": SLEEP, "date": "2026-10-21", "sum": 1}],
        },
    )
    assert counts["quantities"] == 2 and counts["rejected"] == 4
    reasons = [item["reason"] for item in batch.rejected]
    assert "count" in reasons[0] and "not a registered quantity type" in reasons[1] and "not a registered" in reasons[2]
    assert [item["collection"] for item in batch.rejected] == ["quantities", "quantities", "quantities", "daily"]


def test_deletions_reach_every_record_kind(store: Store, device_id: str) -> None:
    upload(
        store,
        device_id,
        {
            "batch_id": "b",
            "quantities": [quantity(1, HEART, 61, "count/min", "2026-10-21T06:00:00Z")],
            "categories": [stage(2, "core", "2026-10-20T22:00:00Z", "2026-10-21T05:00:00Z")],
            "workouts": [
                {
                    "uuid": uid(3),
                    "activity": "running",
                    "start": "2026-10-21T17:00:00Z",
                    "end": "2026-10-21T17:30:00Z",
                    "duration_s": 1800,
                }
            ],
        },
    )
    assert {item["key"] for item in data_types(store)} == {"heart_rate", "sleep_analysis", "workouts"}
    counts, _ = upload(store, device_id, {"batch_id": "d", "deleted": [uid(1), uid(2), uid(3), uid(99)]})
    assert counts["deleted"] == 3
    assert counts["deleted_days"] == {HEART: ["2026-10-21"]}, "The app recomputes statistics for these days"
    assert data_types(store) == []


def test_daily_statistics_are_upserted_and_summarised(store: Store, device_id: str) -> None:
    daily = [
        {"type": STEPS, "date": "2026-10-20", "sum": 8000, "time_zone": "Europe/Brussels"},
        {"type": STEPS, "date": "2026-10-21", "sum": 4000},
        {"type": HEART, "date": "2026-10-21", "average": 64.123, "minimum": 48, "maximum": 151},
    ]
    upload(store, device_id, {"batch_id": "b", "daily": daily})
    upload(store, device_id, {"batch_id": "c", "daily": [{"type": STEPS, "date": "2026-10-21", "sum": 9500}]})
    days = daily_summary(store, date(2026, 10, 20), date(2026, 10, 22), None)
    assert days == [
        {"date": "2026-10-20", "values": {"step_count": {"sum": 8000.0}}},
        {
            "date": "2026-10-21",
            "values": {"heart_rate": {"average": 64.12, "min": 48.0, "max": 151.0}, "step_count": {"sum": 9500.0}},
        },
        {"date": "2026-10-22", "values": {}},
    ]
    assert daily_summary(store, date(2026, 10, 21), date(2026, 10, 21), [HEART])[0]["values"].keys() == {"heart_rate"}
    # A day whose samples were all deleted comes back empty.
    upload(store, device_id, {"batch_id": "e", "daily": [{"type": STEPS, "date": "2026-10-20"}]})
    assert daily_summary(store, date(2026, 10, 20), date(2026, 10, 20), None)[0]["values"] == {}


def test_data_types_and_raw_samples(store: Store, device_id: str) -> None:
    readings = [quantity(index, HEART, 60 + index, "count/min", f"2026-10-21T0{index}:00:00Z") for index in range(1, 6)]
    upload(
        store,
        device_id,
        {"batch_id": "b", "quantities": readings, "daily": [{"type": HEART, "date": "2026-10-21", "average": 62}]},
    )
    [listed] = data_types(store)
    assert listed["key"] == "heart_rate" and listed["records"] == 5 and listed["unit"] == "count/min"
    assert listed["daily_stats_through"] == "2026-10-21" and listed["group"] == "vitals"
    samples, truncated = raw_samples(store, resolve(store, "heart_rate"), date(2026, 10, 21), date(2026, 10, 21), 3)
    assert truncated and [sample["value"] for sample in samples] == [65, 64, 63]
    assert samples[0] == {"start": "2026-10-21T07:00+02:00", "value": 65, "source": "Apple Watch"}


def test_sleep_nights_pick_one_source_and_date_by_wake_up(store: Store, device_id: str) -> None:
    upload(
        store,
        device_id,
        {
            "batch_id": "b",
            "categories": [
                # Watch: Monday night into Tuesday (local +02:00), with stages.
                stage(1, "in_bed", "2026-10-19T21:00:00Z", "2026-10-20T05:00:00Z"),
                stage(2, "core", "2026-10-19T21:30:00Z", "2026-10-20T01:30:00Z"),
                stage(3, "deep", "2026-10-20T01:30:00Z", "2026-10-20T02:30:00Z"),
                stage(4, "rem", "2026-10-20T02:30:00Z", "2026-10-20T04:30:00Z"),
                stage(5, "awake", "2026-10-20T04:30:00Z", "2026-10-20T04:45:00Z"),
                # An app that writes an overall "asleep" sample next to stages must not be counted twice.
                stage(8, "asleep", "2026-10-19T21:30:00Z", "2026-10-20T04:30:00Z"),
                # iPhone overlaps with a coarse in-bed estimate; it must not be added on top.
                stage(6, "in_bed", "2026-10-19T20:30:00Z", "2026-10-20T05:15:00Z", source="iPhone"),
                # Tuesday afternoon nap counts for Tuesday.
                stage(7, "asleep", "2026-10-20T13:00:00Z", "2026-10-20T13:30:00Z"),
            ],
        },
    )
    nights = sleep_nights(store, date(2026, 10, 20), date(2026, 10, 21))
    assert nights == [
        {
            "date": "2026-10-20",
            "source": "Apple Watch",
            "bedtime": "2026-10-19T23:00+02:00",
            "wake_time": "2026-10-20T07:00+02:00",
            "asleep_min": 420,
            "in_bed_min": 480,
            "awake_min": 15,
            "stages_min": {"core": 240, "deep": 60, "rem": 120, "asleep": 420},
            "naps": [{"start": "2026-10-20T15:00+02:00", "end": "2026-10-20T15:30+02:00", "asleep_min": 30}],
            "other_sources": ["iPhone"],
        }
    ]


def test_watch_stages_borrow_time_in_bed_from_an_overlapping_iphone(store: Store, device_id: str) -> None:
    upload(
        store,
        device_id,
        {
            "batch_id": "b",
            "categories": [
                stage(1, "core", "2026-10-19T21:30:00Z", "2026-10-20T04:30:00Z"),
                stage(2, "in_bed", "2026-10-19T21:00:00Z", "2026-10-20T05:00:00Z", source="iPhone"),
            ],
        },
    )
    [night] = sleep_nights(store, date(2026, 10, 20), date(2026, 10, 20))
    assert night["source"] == "Apple Watch" and night["asleep_min"] == 420 and night["in_bed_min"] == 480


def test_workouts_are_listed_newest_first_with_filters(store: Store, device_id: str) -> None:
    def workout(number: int, activity: str, start: str, **stats) -> dict:
        return {
            "uuid": uid(number),
            "activity": activity,
            "start": start,
            "end": start.replace("T17", "T18"),
            "duration_s": 3600,
            "time_zone": "Europe/Brussels",
            "source": {"name": "Apple Watch"},
        } | stats

    upload(
        store,
        device_id,
        {
            "batch_id": "b",
            "workouts": [
                workout(
                    1, "running", "2026-10-20T17:00:00Z", energy_kcal=612.4, distance_m=10234, avg_heart_rate=151.2
                ),
                workout(2, "cycling", "2026-10-21T17:00:00Z", events=[{"type": 1}]),
            ],
        },
    )
    listed = workouts(store, date(2026, 10, 1), date(2026, 10, 21), None, 10)
    assert [item["activity"] for item in listed] == ["cycling", "running"]
    assert listed[1] | {} == {
        "start": "2026-10-20T19:00+02:00",
        "end": "2026-10-20T20:00+02:00",
        "activity": "running",
        "duration_min": 60.0,
        "energy_kcal": 612.0,
        "distance_km": 10.23,
        "avg_heart_rate": 151.0,
        "max_heart_rate": None,
        "source": "Apple Watch",
    }
    assert [item["activity"] for item in workouts(store, date(2026, 10, 1), date(2026, 10, 21), "Running", 10)] == [
        "running"
    ]


async def test_read_tools(store: Store, settings: Settings, device_id: str) -> None:
    upload(
        store,
        device_id,
        {
            "batch_id": "b",
            "quantities": [quantity(1, "HKQuantityTypeIdentifierBodyMass", 82.4, "kg", "2026-10-21T06:00:00Z")],
            "daily": [{"type": STEPS, "date": "2026-10-21", "sum": 9500}],
            "complete": True,
        },
    )
    mcp = build_mcp(store, settings)
    async with Client(mcp) as client:

        async def call(tool: str, **arguments) -> dict:
            return (await client.call_tool(tool, arguments)).structured_content

        listed = await call("list_data_types")
        assert [item["key"] for item in listed["types"]] == ["body_mass"] and listed["synced_at"]
        summary = await call("get_daily_summary", types=["step_count"], start_date="2026-10-21")
        assert summary["days"] == [{"date": "2026-10-21", "values": {"step_count": {"sum": 9500.0}}}]
        assert summary["units"] == {"step_count": "count"}
        weights = await call("get_samples", type="body_mass")
        assert weights["unit"] == "kg" and weights["samples"][0]["value"] == 82.4 and not weights["truncated"]
        assert (await call("get_sleep"))["nights"] == []
        assert (await call("get_workouts"))["workouts"] == []
        with pytest.raises(ToolError, match="list_data_types"):
            await call("get_samples", type="blood_unicorns")
