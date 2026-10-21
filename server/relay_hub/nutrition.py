"""Nutrition views over uploaded Apple Health data: daily intake totals and a food log."""

from __future__ import annotations

import json
from collections import defaultdict
from collections.abc import Sequence
from datetime import date, datetime, timedelta
from typing import Any

from .ingest import offset_zone
from .nutrients import BY_IDENTIFIER, NUTRIENTS
from .store import Store

UNITS = {nutrient.key: nutrient.unit for nutrient in NUTRIENTS}
IDENTIFIERS = tuple(BY_IDENTIFIER)


def days(start: date, end: date) -> list[date]:
    return [start + timedelta(days=offset) for offset in range((end - start).days + 1)]


def samples(store: Store, start: date, end: date) -> list[Any]:
    """Live dietary samples on the given local days."""
    placeholders = ",".join("?" * len(IDENTIFIERS))
    return store.query(
        "SELECT * FROM samples WHERE deleted_at IS NULL AND local_date BETWEEN ? AND ?"  # noqa: S608
        f" AND type IN ({placeholders}) ORDER BY start_at",
        [start.isoformat(), end.isoformat(), *IDENTIFIERS],
    )


def food_entries(store: Store, start: date, end: date) -> list[Any]:
    return store.query(
        "SELECT * FROM food_entries WHERE deleted_at IS NULL AND local_date BETWEEN ? AND ? ORDER BY start_at",
        [start.isoformat(), end.isoformat()],
    )


def _rounded(values: dict[str, float]) -> dict[str, float]:
    # Keep the catalog order so responses read the same every time.
    return {nutrient.key: round(values[nutrient.key], 1) for nutrient in NUTRIENTS if nutrient.key in values}


def _key(sample: Any) -> str:
    return BY_IDENTIFIER[sample["type"]].key


def daily_totals(rows: Sequence[Any], start: date, end: date) -> list[dict[str, Any]]:
    """Sum every live sample per local day. Days without samples are listed as empty, not zero."""
    sums: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    counts: dict[str, int] = defaultdict(int)
    for sample in rows:
        sums[sample["local_date"]][_key(sample)] += sample["value"]
        counts[sample["local_date"]] += 1
    return [
        {"date": day.isoformat(), "samples": counts[day.isoformat()], "nutrients": _rounded(sums[day.isoformat()])}
        for day in days(start, end)
    ]


def local_time(start_at: str, utc_offset: str) -> str:
    return datetime.fromisoformat(start_at).astimezone(offset_zone(utc_offset)).isoformat(timespec="minutes")


def _source(row: Any) -> str | None:
    return row["source_name"] or row["source_bundle_id"]


def food_log(rows: Sequence[Any], entries: Sequence[Any], limit: int) -> list[dict[str, Any]]:
    """Group samples into what was eaten: HealthKit food entries first, then loose samples."""
    by_uuid = {sample["uuid"]: sample for sample in rows}
    claimed: set[str] = set()
    log: list[tuple[str, dict[str, Any]]] = []

    def entry(first: Any, members: Sequence[Any], meta: Any) -> tuple[str, dict[str, Any]]:
        totals: dict[str, float] = defaultdict(float)
        for member in members:
            totals[_key(member)] += member["value"]
        return first["start_at"], {
            "time": local_time(first["start_at"], first["utc_offset"]),
            "name": meta["food_name"],
            "meal_type": meta["meal_type"],
            "source": _source(meta),
            "relay_entry_id": meta["write_id"],
            "nutrients": _rounded(totals),
        }

    for food in entries:
        members = [by_uuid[value] for value in json.loads(food["sample_uuids"]) if value in by_uuid]
        claimed.update(member["uuid"] for member in members)
        log.append(entry(food, members, food))
    groups: dict[tuple[Any, ...], list[Any]] = defaultdict(list)
    for sample in rows:
        if sample["uuid"] not in claimed:
            key = (sample["start_at"], sample["source_bundle_id"], sample["food_name"], sample["write_id"])
            groups[key].append(sample)
    for members in groups.values():
        log.append(entry(members[0], members, members[0]))
    log.sort(key=lambda item: item[0], reverse=True)
    return [item for _, item in log[:limit]]
