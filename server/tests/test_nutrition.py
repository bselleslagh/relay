from __future__ import annotations

from datetime import date
from zoneinfo import ZoneInfo

import pytest

from relay_hub.nutrition import InvalidBatchError, daily_totals, food_log, parse_batch
from relay_hub.store import Store

BRUSSELS = ZoneInfo("Europe/Brussels")
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


def test_invalid_items_are_reported_without_blocking_the_rest() -> None:
    batch = {
        "batch_id": "b1",
        "samples": [
            sample(uid(1)),
            sample(uid(2), unit="cal"),
            sample(uid(3), kind="HKQuantityTypeIdentifierStepCount", unit="count"),
            sample("not-a-uuid"),
            sample(uid(4), value=-1),
        ],
        "meals": [{"uuid": uid(9), "start": "2026-10-21T10:00:00Z", "end": "2026-10-21T09:00:00Z"}],
        "deleted": [uid(5), "nope"],
    }
    batch_id, samples, meals, deleted, rejected = parse_batch(batch, BRUSSELS)
    assert batch_id == "b1" and [row.uuid for row in samples] == [uid(1)] and meals == [] and deleted == [uid(5)]
    assert [(item["collection"], item["index"]) for item in rejected] == [
        ("samples", 1),
        ("samples", 2),
        ("samples", 3),
        ("samples", 4),
        ("meals", 0),
        ("deleted", 1),
    ]
    assert "kcal" in rejected[0]["reason"] and "unsupported" in rejected[1]["reason"]


@pytest.mark.parametrize(
    "body",
    [
        [],
        {"samples": []},
        {"batch_id": "x" * 65},
        {"batch_id": "b", "samples": {}},
        {"batch_id": "b", "deleted": ["x"] * 2001},
    ],
)
def test_malformed_envelopes_are_refused(body) -> None:
    with pytest.raises(InvalidBatchError):
        parse_batch(body, BRUSSELS)


def test_local_day_follows_the_sample_time_zone_then_its_offset() -> None:
    late = sample(uid(1), start="2026-10-21T22:30:00Z", end="2026-10-21T22:30:00Z")
    without_zone = late | {"uuid": uid(2), "time_zone": None}
    new_york = late | {"uuid": uid(3), "time_zone": "America/New_York"}
    # HealthKit stores offset-only zones as "GMT-0400", which is not an IANA name; Relay also sends the offset.
    offset_only = late | {"uuid": uid(4), "time_zone": "GMT-0400", "utc_offset": "-04:00"}
    garbled = late | {"uuid": uid(5), "time_zone": None, "utc_offset": "4 hours"}
    _, rows, *_ = parse_batch(
        {"batch_id": "b", "samples": [late, without_zone, new_york, offset_only, garbled]}, BRUSSELS
    )
    assert [(row.local_date, row.utc_offset) for row in rows] == [
        ("2026-10-22", "+02:00"),
        ("2026-10-22", "+02:00"),
        ("2026-10-21", "-04:00"),
        ("2026-10-21", "-04:00"),
        ("2026-10-22", "+02:00"),
    ]


def test_over_long_metadata_is_shortened_not_rejected() -> None:
    noisy = sample(uid(1), food_name="🇧🇪" * 200, meal_type="x" * 100, time_zone="Z" * 100, source={"name": "n" * 500})
    _, rows, _, _, rejected = parse_batch({"batch_id": "b", "samples": [noisy]}, BRUSSELS)
    assert rejected == []
    assert len(rows[0].food_name) == 200 and len(rows[0].meal_type) == 64 and len(rows[0].source_name) == 200


def ingest(store: Store, body: dict) -> dict:
    batch_id, samples, meals, deleted, rejected = parse_batch(body, BRUSSELS)
    return store.ingest_nutrition(
        device_id="d", batch_id=batch_id, samples=samples, meals=meals, deleted=deleted, rejected=len(rejected)
    )


def test_totals_sum_each_local_day_skip_deletions_and_ignore_resent_batches(store: Store) -> None:
    body = {
        "batch_id": "b1",
        "samples": [sample(uid(1), value=520), sample(uid(2), value=610), sample(uid(3), PROTEIN, 42, "g")],
    }
    ingest(store, body)
    ingest(store, body)
    start, end = date(2026, 10, 20), date(2026, 10, 21)
    totals = daily_totals(store.nutrition_samples(start, end), start, end)
    assert totals == [
        {"date": "2026-10-20", "samples": 0, "nutrients": {}},
        {"date": "2026-10-21", "samples": 3, "nutrients": {"energy_kcal": 1130.0, "protein_g": 42.0}},
    ]
    assert ingest(store, {"batch_id": "b2", "deleted": [uid(2)]})["deleted"] == 1
    totals = daily_totals(store.nutrition_samples(start, end), start, end)
    assert totals[1]["nutrients"]["energy_kcal"] == 520.0


def test_sync_time_moves_only_when_a_device_reports_it_is_caught_up(store: Store) -> None:
    code, _ = store.create_pairing_code("iPhone", 10)
    device_id = store.redeem_pairing_code(code, None)["device_id"]
    store.ingest_nutrition(device_id=device_id, batch_id="b", samples=[], meals=[], deleted=[], rejected=0)
    assert store.last_nutrition_upload() is None
    store.ingest_nutrition(
        device_id=device_id, batch_id="c", samples=[], meals=[], deleted=[], rejected=0, complete=True
    )
    assert store.last_nutrition_upload() is not None


def test_food_log_groups_correlations_and_loose_entries(store: Store) -> None:
    write_id = "11111111-1111-4111-8111-111111111111"
    ingest(
        store,
        {
            "batch_id": "b1",
            "samples": [
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
    entries = food_log(store.nutrition_samples(day, day), store.nutrition_meals(day, day), 10)
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
    assert len(food_log(store.nutrition_samples(day, day), store.nutrition_meals(day, day), 1)) == 1
