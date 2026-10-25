from __future__ import annotations

from datetime import UTC, datetime
from zoneinfo import ZoneInfo

import pytest

from relay_hub.meals import InvalidMealError, build_meal, summary

NOW = datetime(2026, 10, 21, 10, 30, tzinfo=UTC)
BRUSSELS = ZoneInfo("Europe/Brussels")
MACROS = {"energy_kcal": 610, "protein_g": 42, "carbohydrates_g": 12, "fat_g": 44, "fiber_g": None, "sugar_g": None}


def meal(**overrides):
    arguments = {"nutrients": MACROS, "consumed_at": None, "name": None, "meal_type": None} | overrides
    return build_meal(zone=BRUSSELS, now=NOW, **arguments)


def test_defaults_to_now_in_the_hub_time_zone_and_drops_missing_nutrients() -> None:
    data, warnings = meal(name="  Chicken salad ", meal_type="lunch")
    assert data == {
        "consumed_at": "2026-10-21T12:30:00+02:00",
        "utc_offset": "+02:00",
        "time_zone": "Europe/Brussels",
        "name": "Chicken salad",
        "meal_type": "lunch",
        "nutrients": {"energy_kcal": 610, "protein_g": 42, "carbohydrates_g": 12, "fat_g": 44},
    }
    assert warnings == []


def test_time_zone_is_kept_only_when_the_offset_matches() -> None:
    assert meal(consumed_at="2026-10-21T08:00:00")[0]["consumed_at"] == "2026-10-21T08:00:00+02:00"
    assert meal(consumed_at="2026-10-21T08:00:00+02:00")[0]["time_zone"] == "Europe/Brussels"
    travelling = meal(consumed_at="2026-10-21T03:00:00-04:00")[0]
    assert travelling["time_zone"] is None and travelling["utc_offset"] == "-04:00"


@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        ({"consumed_at": "yesterday"}, "ISO 8601"),
        ({"consumed_at": "2026-10-21T13:00:00+02:00"}, "future"),
        ({"consumed_at": "2026-09-20T12:00:00+02:00"}, "30 days"),
        ({"nutrients": MACROS | {"protein_g": -1}}, "protein_g"),
        ({"nutrients": MACROS | {"energy_kcal": float("nan")}}, "energy_kcal"),
        ({"nutrients": MACROS | {"energy_kcal": None}}, "energy_kcal is required"),
        ({"nutrients": MACROS | {"sodium_mg": 10}}, "cannot be written"),
        ({"name": "x" * 121}, "120"),
        ({"meal_type": "brunch"}, "meal_type"),
    ],
)
def test_invalid_meals_are_rejected(overrides: dict, message: str) -> None:
    with pytest.raises(InvalidMealError, match=message):
        meal(**overrides)


def test_implausible_values_produce_warnings_not_errors() -> None:
    data, warnings = meal(nutrients=MACROS | {"energy_kcal": 1500, "sugar_g": 20})
    assert data["nutrients"]["energy_kcal"] == 1500
    assert any("macro estimate" in warning for warning in warnings)
    assert any("sugar_g" in warning for warning in warnings)


def test_summary_is_readable() -> None:
    assert summary(meal(name="Chicken salad")[0]) == "Chicken salad · 610 kcal · P 42 g · C 12 g · F 44 g"
    assert summary(meal(meal_type="snack")[0]).startswith("Snack · 610 kcal")
