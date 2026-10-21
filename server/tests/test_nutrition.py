from __future__ import annotations

from datetime import date

import pytest

from relay_hub.ingest import InvalidBatchError, parse_batch
from relay_hub.nutrition import daily_totals, food_entries, food_log, samples
from relay_hub.store import Store

from .conftest import BRUSSELS, upload

ENERGY = "HKQuantityTypeIdentifierDietaryEnergyConsumed"
PROTEIN = "HKQuantityTypeIdentifierDietaryProtein"


def sample(uuid: str, kind: str = ENERGY, value: float = 500, unit: str = "kcal", **extra) -> dict:
    return {
        "uuid": uuid,
        "type": kind,
        "value": value,
        "unit": unit,
        "start": "2026-10-21T10:00:00Z",
        "end": "2026-10-21T10:00:00Z",
        "time_zone": "Europe/Brussels",
        "source": {"name": "Relay", "bundle_id": "com.example.relay"},
    } | extra


def uid(number: int) -> str:
    return f"00000000-0000-4000-8000-{number:012d}"


def test_invalid_items_are_reported_without_blocking_the_rest(store: Store) -> None:
    batch = {
        "batch_id": "b1",
        "quantities": [
            sample(uid(1)),
            sample(uid(2), unit="cal"),
            sample(uid(3), kind="HKQuantityTypeIdentifierBloodGlucose", unit="mg/dL"),
            sample("not-a-uuid"),
            sample(uid(4), value=-1),
        ],
        "meals": [{"uuid": uid(9), "start": "2026-10-21T10:00:00Z", "end": "2026-10-21T09:00:00Z"}],
        "deleted": [uid(5), "nope"],
    }
    parsed = parse_batch(batch, BRUSSELS, store.types())
    assert parsed.batch_id == "b1" and [row["uuid"] for row in parsed.records["quantities"]] == [uid(1), uid(4)]
    assert parsed.records["meals"] == [] and parsed.deleted == [uid(5)]
    assert [(item["collection"], item["index"]) for item in parsed.rejected] == [
        ("quantities", 1),
        ("quantities", 2),
        ("quantities", 3),
        ("meals", 0),
        ("deleted", 1),
    ]
    assert "kcal" in parsed.rejected[0]["reason"] and "not a registered" in parsed.rejected[1]["reason"]


@pytest.mark.parametrize(
    "body",
    [
        [],
        {"quantities": []},
        {"batch_id": "x" * 65},
        {"batch_id": "b", "quantities": {}},
        {"batch_id": "b", "deleted": ["x"] * 2001},
    ],
)
def test_malformed_envelopes_are_refused(body, store: Store) -> None:
    with pytest.raises(InvalidBatchError):
        parse_batch(body, BRUSSELS, store.types())


def test_local_day_follows_the_sample_time_zone_then_its_offset(store: Store) -> None:
    late = sample(uid(1), start="2026-10-21T22:30:00Z", end="2026-10-21T22:30:00Z")
    without_zone = late | {"uuid": uid(2), "time_zone": None}
    new_york = late | {"uuid": uid(3), "time_zone": "America/New_York"}
    # HealthKit stores offset-only zones as "GMT-0400", which is not an IANA name; Relay also sends the offset.
    offset_only = late | {"uuid": uid(4), "time_zone": "GMT-0400", "utc_offset": "-04:00"}
    garbled = late | {"uuid": uid(5), "time_zone": None, "utc_offset": "4 hours"}
    rows = parse_batch(
        {"batch_id": "b", "quantities": [late, without_zone, new_york, offset_only, garbled]}, BRUSSELS, store.types()
    ).records["quantities"]
    assert [(row["local_date"], row["utc_offset"]) for row in rows] == [
        ("2026-10-22", "+02:00"),
        ("2026-10-22", "+02:00"),
        ("2026-10-21", "-04:00"),
        ("2026-10-21", "-04:00"),
        ("2026-10-22", "+02:00"),
    ]


def test_over_long_metadata_is_shortened_not_rejected(store: Store) -> None:
    noisy = sample(uid(1), food_name="🇧🇪" * 200, meal_type="x" * 100, time_zone="Z" * 100, source={"name": "n" * 500})
    parsed = parse_batch({"batch_id": "b", "quantities": [noisy]}, BRUSSELS, store.types())
    row = parsed.records["quantities"][0]
    assert parsed.rejected == []
    assert len(row["food_name"]) == 200 and len(row["meal_type"]) == 64 and len(row["source_name"]) == 200


def ingest(store: Store, body: dict) -> dict:
    return upload(store, "d", body)[0]


def test_totals_sum_each_local_day_skip_deletions_and_ignore_resent_batches(store: Store) -> None:
    body = {
        "batch_id": "b1",
        "quantities": [sample(uid(1), value=520), sample(uid(2), value=610), sample(uid(3), PROTEIN, 42, "g")],
    }
    ingest(store, body)
    ingest(store, body)
    start, end = date(2026, 10, 20), date(2026, 10, 21)
    totals = daily_totals(samples(store, start, end), start, end)
    assert totals == [
        {"date": "2026-10-20", "samples": 0, "nutrients": {}},
        {"date": "2026-10-21", "samples": 3, "nutrients": {"energy_kcal": 1130.0, "protein_g": 42.0}},
    ]
    assert ingest(store, {"batch_id": "b2", "deleted": [uid(2)]})["deleted"] == 1
    totals = daily_totals(samples(store, start, end), start, end)
    assert totals[1]["nutrients"]["energy_kcal"] == 520.0


def test_sync_time_moves_only_when_a_device_reports_it_is_caught_up(store: Store, device_id: str) -> None:
    upload(store, device_id, {"batch_id": "b"})
    assert store.last_upload() is None
    upload(store, device_id, {"batch_id": "c", "complete": True})
    assert store.last_upload() is not None


def test_food_log_groups_correlations_and_loose_entries(store: Store) -> None:
    write_id = "11111111-1111-4111-8111-111111111111"
    ingest(
        store,
        {
            "batch_id": "b1",
            "quantities": [
                sample(uid(1), value=610, food_name="Chicken salad", write_id=write_id),
                sample(uid(2), PROTEIN, 42, "g", food_name="Chicken salad", write_id=write_id),
                sample(uid(3), value=90, start="2026-10-21T07:00:00Z", end="2026-10-21T07:00:00Z", food_name="Banana"),
                sample(
                    uid(4),
                    PROTEIN,
                    1,
                    "g",
                    start="2026-10-21T07:00:00Z",
                    end="2026-10-21T07:00:00Z",
                    food_name="Banana",
                ),
            ],
            "meals": [
                {
                    "uuid": uid(10),
                    "start": "2026-10-21T10:00:00Z",
                    "end": "2026-10-21T10:00:00Z",
                    "time_zone": "Europe/Brussels",
                    "food_name": "Chicken salad",
                    "meal_type": "lunch",
                    "write_id": write_id,
                    "source": {"name": "Relay"},
                    "sample_uuids": [uid(1), uid(2)],
                }
            ],
        },
    )
    day = date(2026, 10, 21)
    entries = food_log(samples(store, day, day), food_entries(store, day, day), 10)
    assert entries == [
        {
            "time": "2026-10-21T12:00+02:00",
            "name": "Chicken salad",
            "meal_type": "lunch",
            "source": "Relay",
            "relay_entry_id": write_id,
            "nutrients": {"energy_kcal": 610.0, "protein_g": 42.0},
        },
        {
            "time": "2026-10-21T09:00+02:00",
            "name": "Banana",
            "meal_type": None,
            "source": "Relay",
            "relay_entry_id": None,
            "nutrients": {"energy_kcal": 90.0, "protein_g": 1.0},
        },
    ]
    assert len(food_log(samples(store, day, day), food_entries(store, day, day), 1)) == 1
