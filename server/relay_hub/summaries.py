"""Read models for MCP tools: available data types, HealthKit daily statistics, raw samples, sleep and workouts."""

from __future__ import annotations

import re
from collections import defaultdict
from datetime import date, datetime, timedelta
from typing import Any

from .ingest import offset_zone
from .nutrition import days
from .store import Store

SLEEP = "HKCategoryTypeIdentifierSleepAnalysis"
ASLEEP = ("asleep", "core", "deep", "rem")
PREFIX = re.compile(r"^HK(Quantity|Category|Correlation|Workout)TypeIdentifier")
SESSION_GAP = timedelta(hours=1)


def key(type_id: str) -> str:
    """HKQuantityTypeIdentifierHeartRateVariabilitySDNN -> heart_rate_variability_sdnn."""
    name = PREFIX.sub("", type_id) or "workouts"
    name = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).lower()


def resolve(store: Store, name: str) -> dict[str, Any] | None:
    """Accept a HealthKit identifier, a snake_case key or a title."""
    wanted = name.strip().lower()
    for entry in store.types().values():
        if wanted in (entry["id"].lower(), key(entry["id"]), entry["title"].lower()):
            return entry
    return None


def _local(moment: str, utc_offset: str) -> datetime:
    return datetime.fromisoformat(moment).astimezone(offset_zone(utc_offset))


def _minutes(local_time: datetime) -> str:
    return local_time.isoformat(timespec="minutes")


def _round(value: float | None, digits: int = 2) -> float | None:
    return None if value is None else round(value, digits)


def data_types(store: Store) -> list[dict[str, Any]]:
    stats: dict[str, dict[str, Any]] = {}
    for table, column in (("samples", "type"), ("categories", "type")):
        for row in store.query(
            f"SELECT {column} AS type, COUNT(*) AS n, MIN(start_at) AS first, MAX(end_at) AS last"  # noqa: S608
            f" FROM {table} WHERE deleted_at IS NULL GROUP BY {column}"
        ):
            stats[row["type"]] = {"records": row["n"], "first_at": row["first"], "last_at": row["last"]}
    for type_id, table in (
        ("HKWorkoutTypeIdentifier", "workouts"),
        ("HKCorrelationTypeIdentifierFood", "food_entries"),
    ):
        row = store.query(
            f"SELECT COUNT(*) AS n, MIN(start_at) AS first, MAX(end_at) AS last FROM {table}"  # noqa: S608
            " WHERE deleted_at IS NULL"
        )[0]
        if row["n"]:
            stats[type_id] = {"records": row["n"], "first_at": row["first"], "last_at": row["last"]}
    latest = {
        row["type"]: row["day"] for row in store.query("SELECT type, MAX(date) AS day FROM daily_stats GROUP BY type")
    }
    listed = []
    for entry in store.types().values():
        if entry["id"] not in stats:
            continue
        listed.append(
            {
                "id": entry["id"],
                "key": key(entry["id"]),
                "title": entry["title"],
                "group": entry["group_name"],
                "unit": entry["unit"],
                "aggregation": entry["aggregation"],
                **stats[entry["id"]],
                "daily_stats_through": latest.get(entry["id"]),
            }
        )
    return sorted(listed, key=lambda item: (item["group"], item["title"]))


def daily_summary(store: Store, start: date, end: date, type_ids: list[str] | None) -> list[dict[str, Any]]:
    """HealthKit's own daily statistics: sums for cumulative types, average/min/max for the rest."""
    query, parameters = "SELECT * FROM daily_stats WHERE date BETWEEN ? AND ?", [start.isoformat(), end.isoformat()]
    if type_ids is not None:
        query += f" AND type IN ({','.join('?' * len(type_ids))})"  # placeholders only
        parameters.extend(type_ids)
    by_day: dict[str, dict[str, Any]] = defaultdict(dict)
    for row in store.query(query, parameters):
        if row["sum"] is not None:
            value: dict[str, Any] = {"sum": _round(row["sum"])}
        else:
            value = {"average": _round(row["average"]), "min": _round(row["minimum"]), "max": _round(row["maximum"])}
        by_day[row["date"]][key(row["type"])] = value
    return [
        {"date": day.isoformat(), "values": dict(sorted(by_day[day.isoformat()].items()))} for day in days(start, end)
    ]


def raw_samples(
    store: Store, entry: dict[str, Any], start: date, end: date, limit: int
) -> tuple[list[dict[str, Any]], bool]:
    table = "categories" if entry["kind"] == "category" else "samples"
    rows = store.query(
        f"SELECT * FROM {table} WHERE deleted_at IS NULL AND type = ? AND local_date BETWEEN ? AND ?"  # noqa: S608
        " ORDER BY start_at DESC LIMIT ?",
        [entry["id"], start.isoformat(), end.isoformat(), limit + 1],
    )
    samples = []
    for row in rows[:limit]:
        item: dict[str, Any] = {"start": _minutes(_local(row["start_at"], row["utc_offset"]))}
        if row["end_at"] != row["start_at"]:
            item["end"] = _minutes(_local(row["end_at"], row["utc_offset"]))
        item["value"] = row["value"]
        if table == "categories" and row["label"]:
            item["label"] = row["label"]
        item["source"] = row["source_name"] or row["source_bundle_id"]
        samples.append(item)
    return samples, len(rows) > limit


def _union_minutes(intervals: list[tuple[datetime, datetime]]) -> float:
    """Length of the union of intervals, so overlapping samples are never counted twice."""
    total, current_start, current_end = 0.0, None, None
    for began, ended in sorted(intervals):
        if current_end is None or began > current_end:
            if current_end is not None:
                total += (current_end - current_start).total_seconds()
            current_start, current_end = began, ended
        else:
            current_end = max(current_end, ended)
    if current_end is not None:
        total += (current_end - current_start).total_seconds()
    return total / 60


def _minutes_for(session: dict[str, Any], *labels: str) -> float:
    return _union_minutes([(began, ended) for began, ended, label in session["samples"] if label in labels])


def _sleep_rank(session: dict[str, Any]) -> tuple[float, float]:
    return _minutes_for(session, *ASLEEP), _minutes_for(session, "in_bed")


def sleep_nights(store: Store, start: date, end: date) -> list[dict[str, Any]]:
    """One summary per night, dated by wake-up day.

    Each source's samples form sessions separated by gaps of more than an hour. The longest session on a day is
    the night; that source's other sessions are naps. Overlapping sources (an iPhone next to an Apple Watch) are
    never added together: the source with the most recorded sleep is reported and the others are named. Time in
    bed comes from an overlapping source when the reported one has none, as with Apple Watch stages and an iPhone
    bedtime schedule.
    """
    window_start = datetime.combine(start - timedelta(days=2), datetime.min.time()).isoformat()
    window_end = datetime.combine(end + timedelta(days=2), datetime.min.time()).isoformat()
    rows = store.query(
        "SELECT * FROM categories WHERE deleted_at IS NULL AND type = ? AND end_at BETWEEN ? AND ? ORDER BY start_at",
        [SLEEP, window_start, window_end],
    )
    sessions: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        began, ended = _local(row["start_at"], row["utc_offset"]), _local(row["end_at"], row["utc_offset"])
        source = row["source_name"] or row["source_bundle_id"] or "unknown"
        current = sessions[source][-1] if sessions[source] else None
        if current is None or began > current["end"] + SESSION_GAP:
            current = {"start": began, "end": ended, "samples": []}
            sessions[source].append(current)
        current["end"] = max(current["end"], ended)
        current["samples"].append((began, ended, row["label"] or "unknown"))
    by_day: dict[date, list[tuple[str, dict[str, Any]]]] = defaultdict(list)
    for source, items in sessions.items():
        for session in items:
            if start <= session["end"].date() <= end:
                by_day[session["end"].date()].append((source, session))
    nights = []
    for day, candidates in sorted(by_day.items()):
        source, main = max(candidates, key=lambda item: _sleep_rank(item[1]))
        in_bed = _minutes_for(main, "in_bed") or max(
            (
                _minutes_for(session, "in_bed")
                for name, session in candidates
                if name != source and session["start"] < main["end"] and session["end"] > main["start"]
            ),
            default=0,
        )
        naps = [
            {"start": _minutes(session["start"]), "end": _minutes(session["end"]), "asleep_min": round(asleep)}
            for name, session in candidates
            if name == source and session is not main and (asleep := _minutes_for(session, *ASLEEP)) > 0
        ]
        stages = {label: round(_minutes_for(main, label)) for label in ("core", "deep", "rem", "asleep")}
        nights.append(
            {
                "date": day.isoformat(),
                "source": source,
                "bedtime": _minutes(main["start"]),
                "wake_time": _minutes(main["end"]),
                "asleep_min": round(_minutes_for(main, *ASLEEP)),
                "in_bed_min": round(in_bed),
                "awake_min": round(_minutes_for(main, "awake")),
                "stages_min": {label: minutes for label, minutes in stages.items() if minutes},
                "naps": naps,
                "other_sources": sorted({name for name, _ in candidates if name != source}),
            }
        )
    return nights


def workouts(store: Store, start: date, end: date, activity: str | None, limit: int) -> list[dict[str, Any]]:
    query = "SELECT * FROM workouts WHERE deleted_at IS NULL AND local_date BETWEEN ? AND ?"
    parameters: list[Any] = [start.isoformat(), end.isoformat()]
    if activity:
        query += " AND activity = ?"
        parameters.append(activity.strip().lower())
    rows = store.query(query + " ORDER BY start_at DESC LIMIT ?", [*parameters, limit])
    return [
        {
            "start": _minutes(_local(row["start_at"], row["utc_offset"])),
            "end": _minutes(_local(row["end_at"], row["utc_offset"])),
            "activity": row["activity"],
            "duration_min": round(row["duration_s"] / 60, 1),
            "energy_kcal": _round(row["energy_kcal"], 0),
            "distance_km": _round(row["distance_m"] / 1000 if row["distance_m"] is not None else None, 2),
            "avg_heart_rate": _round(row["avg_heart_rate"], 0),
            "max_heart_rate": _round(row["max_heart_rate"], 0),
            "source": row["source_name"] or row["source_bundle_id"],
        }
        for row in rows
    ]
