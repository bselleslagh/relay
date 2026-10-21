"""Validation for meals queued by a model before Relay writes them to Apple Health."""

from __future__ import annotations

import math
from datetime import datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from .nutrients import BY_KEY, MEAL_TYPES, WRITABLE_KEYS

MAX_FUTURE = timedelta(minutes=15)
# Relay's shortest import window is 30 days, so older entries might never be uploaded back.
MAX_PAST = timedelta(days=30)
NAME_LENGTH = 120
LIMITS = {
    "energy_kcal": 10_000,
    "protein_g": 1_000,
    "carbohydrates_g": 1_000,
    "fat_g": 1_000,
    "fiber_g": 200,
    "sugar_g": 1_000,
}


class InvalidMealError(ValueError):
    pass


def parse_time(value: str | None, zone: ZoneInfo, now: datetime) -> tuple[datetime, str | None]:
    """Return an aware time and, when known, the IANA zone that produced its offset."""
    if value is None or not value.strip():
        return now.astimezone(zone), zone.key
    try:
        moment = datetime.fromisoformat(value.strip())
    except ValueError as error:
        raise InvalidMealError("consumed_at must be ISO 8601, for example 2026-10-21T12:30:00+02:00") from error
    if moment.tzinfo is None:
        return moment.replace(tzinfo=zone), zone.key
    # An explicit offset that matches the hub's zone at that instant is that zone; otherwise keep only the offset.
    local = moment.astimezone(zone)
    return moment, zone.key if local.utcoffset() == moment.utcoffset() else None


def offset_text(moment: datetime) -> str:
    seconds = int(moment.utcoffset().total_seconds()) if moment.utcoffset() else 0
    sign = "-" if seconds < 0 else "+"
    return f"{sign}{abs(seconds) // 3600:02d}:{abs(seconds) % 3600 // 60:02d}"


def build_meal(
    *,
    nutrients: dict[str, float | None],
    consumed_at: str | None,
    name: str | None,
    meal_type: str | None,
    zone: ZoneInfo,
    now: datetime,
) -> tuple[dict[str, Any], list[str]]:
    """Validate a meal and return its queued data plus non-blocking plausibility warnings."""
    moment, zone_name = parse_time(consumed_at, zone, now)
    if moment > now + MAX_FUTURE:
        raise InvalidMealError("consumed_at is in the future. Log meals after they are eaten.")
    if moment < now - MAX_PAST:
        raise InvalidMealError("consumed_at is more than 30 days ago.")
    values: dict[str, float] = {}
    for key, value in nutrients.items():
        if key not in WRITABLE_KEYS:
            raise InvalidMealError(f"{key} cannot be written to Apple Health")
        if value is None:
            continue
        if not math.isfinite(value) or value < 0 or value > LIMITS[key]:
            raise InvalidMealError(f"{key} must be between 0 and {LIMITS[key]} {BY_KEY[key].unit}")
        values[key] = round(float(value), 2)
    if "energy_kcal" not in values:
        raise InvalidMealError("energy_kcal is required")
    title = (name or "").strip() or None
    if title and len(title) > NAME_LENGTH:
        raise InvalidMealError(f"name must be at most {NAME_LENGTH} characters")
    if meal_type is not None and meal_type not in MEAL_TYPES:
        raise InvalidMealError(f"meal_type must be one of {', '.join(MEAL_TYPES)}")
    data = {
        "consumed_at": moment.isoformat(timespec="seconds"),
        "utc_offset": offset_text(moment),
        "time_zone": zone_name,
        "name": title,
        "meal_type": meal_type,
        "nutrients": values,
    }
    return data, warnings(values)


def warnings(values: dict[str, float]) -> list[str]:
    notes: list[str] = []
    energy = values["energy_kcal"]
    macros = 4 * values.get("protein_g", 0) + 4 * values.get("carbohydrates_g", 0) + 9 * values.get("fat_g", 0)
    if abs(macros - energy) > max(100, 0.35 * energy):
        notes.append(
            f"energy_kcal ({energy:g}) differs from the macro estimate 4P+4C+9F ({macros:.0f} kcal). "
            "Double-check the values; cancel_entry and log again if they are wrong."
        )
    if values.get("sugar_g", 0) > values.get("carbohydrates_g", math.inf):
        notes.append("sugar_g is greater than carbohydrates_g.")
    return notes


def summary(data: dict[str, Any]) -> str:
    nutrients = data["nutrients"]
    label = data.get("name") or (data.get("meal_type") or "meal").capitalize()
    parts = [label, f"{nutrients['energy_kcal']:g} kcal"]
    for key, short in (("protein_g", "P"), ("carbohydrates_g", "C"), ("fat_g", "F")):
        if key in nutrients:
            parts.append(f"{short} {nutrients[key]:g} g")
    return " · ".join(parts)
