"""Validation of nutrition uploaded from Apple Health, and the summaries a model reads back."""

from __future__ import annotations

import json
import math
import re
from collections import defaultdict
from collections.abc import Sequence
from datetime import date, datetime, timedelta, timezone
from typing import Annotated, Any
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import AwareDatetime, BaseModel, BeforeValidator, ConfigDict, Field, ValidationError

from .meals import offset_text
from .nutrients import BY_IDENTIFIER, NUTRIENTS
from .store import MealRow, SampleRow, iso

MAX_SAMPLES = 2_000
MAX_MEALS = 500
MAX_DELETED = 2_000
OFFSET = re.compile(r"^([+-])(\d{2}):(\d{2})$")


def _clipped(limit: int) -> BeforeValidator:
    """Shorten over-long optional metadata instead of rejecting the sample and losing its value."""
    return BeforeValidator(lambda value: value[:limit] if isinstance(value, str) else value)


def _offset_or_none(value: Any) -> Any:
    return value if isinstance(value, str) and OFFSET.match(value) else None


Text = Annotated[str | None, _clipped(200)]
Label = Annotated[str | None, _clipped(64)]
Offset = Annotated[str | None, BeforeValidator(_offset_or_none)]


class SourceIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    name: Text = None
    bundle_id: Text = None


class SampleIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    uuid: UUID
    type: str = Field(max_length=100)
    value: float
    unit: str = Field(max_length=20)
    start: AwareDatetime
    end: AwareDatetime
    time_zone: Label = None
    utc_offset: Offset = None
    source: SourceIn | None = None
    food_name: Text = None
    meal_type: Label = None
    write_id: UUID | None = None


class MealIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    uuid: UUID
    start: AwareDatetime
    end: AwareDatetime
    time_zone: Label = None
    utc_offset: Offset = None
    source: SourceIn | None = None
    food_name: Text = None
    meal_type: Label = None
    write_id: UUID | None = None
    sample_uuids: list[UUID] = Field(default_factory=list, max_length=200)


class InvalidBatchError(ValueError):
    pass


def offset_zone(text: str) -> timezone:
    sign, hours, minutes = OFFSET.match(text).groups()
    delta = timedelta(hours=int(hours), minutes=int(minutes))
    return timezone(-delta if sign == "-" else delta)


def _local(moment: datetime, time_zone: str | None, utc_offset: str | None, fallback: ZoneInfo) -> datetime:
    """Local time from the sample's IANA zone, else its UTC offset, else the hub's zone."""
    if time_zone:
        try:
            return moment.astimezone(ZoneInfo(time_zone))
        except (ZoneInfoNotFoundError, ValueError):
            pass
    if utc_offset:
        return moment.astimezone(offset_zone(utc_offset))
    return moment.astimezone(fallback)


def parse_batch(
    body: Any, fallback: ZoneInfo
) -> tuple[str, list[SampleRow], list[MealRow], list[str], list[dict[str, Any]]]:
    """Validate each item separately so one bad record cannot block the rest of a HealthKit page."""
    if not isinstance(body, dict):
        raise InvalidBatchError("Expected a JSON object")
    batch_id = body.get("batch_id")
    if not isinstance(batch_id, str) or not 0 < len(batch_id) <= 64:
        raise InvalidBatchError("batch_id must be a string of at most 64 characters")
    collections = {key: body.get(key, []) for key in ("samples", "meals", "deleted")}
    if not all(isinstance(value, list) for value in collections.values()):
        raise InvalidBatchError("samples, meals and deleted must be arrays")
    limits = {"samples": MAX_SAMPLES, "meals": MAX_MEALS, "deleted": MAX_DELETED}
    for key, limit in limits.items():
        if len(collections[key]) > limit:
            raise InvalidBatchError(f"At most {limit} {key} per batch")
    rejected: list[dict[str, Any]] = []
    samples: list[SampleRow] = []
    for index, item in enumerate(collections["samples"]):
        try:
            sample = SampleIn.model_validate(item)
            samples.append(_sample_row(sample, fallback))
        except (ValidationError, ValueError) as error:
            rejected.append({"collection": "samples", "index": index, "reason": _reason(error)})
    meals: list[MealRow] = []
    for index, item in enumerate(collections["meals"]):
        try:
            meal = MealIn.model_validate(item)
            meals.append(_meal_row(meal, fallback))
        except (ValidationError, ValueError) as error:
            rejected.append({"collection": "meals", "index": index, "reason": _reason(error)})
    deleted: list[str] = []
    for index, item in enumerate(collections["deleted"]):
        try:
            deleted.append(str(UUID(str(item))))
        except ValueError:
            rejected.append({"collection": "deleted", "index": index, "reason": "not a UUID"})
    return batch_id, samples, meals, deleted, rejected


def _reason(error: Exception) -> str:
    if isinstance(error, ValidationError):
        first = error.errors()[0]
        return f"{'.'.join(str(part) for part in first['loc'])}: {first['msg']}"
    return str(error)


def _sample_row(sample: SampleIn, fallback: ZoneInfo) -> SampleRow:
    nutrient = BY_IDENTIFIER.get(sample.type)
    if nutrient is None:
        raise ValueError(f"type: unsupported {sample.type}")
    if sample.unit != nutrient.unit:
        raise ValueError(f"unit: {nutrient.key} must be sent in {nutrient.unit}")
    if not math.isfinite(sample.value) or sample.value < 0:
        raise ValueError("value: must be a finite, non-negative number")
    if sample.end < sample.start:
        raise ValueError("end: before start")
    local = _local(sample.start, sample.time_zone, sample.utc_offset, fallback)
    return SampleRow(
        uuid=str(sample.uuid),
        nutrient=nutrient.key,
        value=sample.value,
        start_at=iso(sample.start),
        end_at=iso(sample.end),
        utc_offset=offset_text(local),
        local_date=local.date().isoformat(),
        source_name=sample.source.name if sample.source else None,
        source_bundle_id=sample.source.bundle_id if sample.source else None,
        food_name=(sample.food_name or "").strip() or None,
        meal_type=sample.meal_type,
        write_id=str(sample.write_id) if sample.write_id else None,
    )


def _meal_row(meal: MealIn, fallback: ZoneInfo) -> MealRow:
    if meal.end < meal.start:
        raise ValueError("end: before start")
    local = _local(meal.start, meal.time_zone, meal.utc_offset, fallback)
    return MealRow(
        uuid=str(meal.uuid),
        start_at=iso(meal.start),
        end_at=iso(meal.end),
        utc_offset=offset_text(local),
        local_date=local.date().isoformat(),
        food_name=(meal.food_name or "").strip() or None,
        meal_type=meal.meal_type,
        write_id=str(meal.write_id) if meal.write_id else None,
        source_name=meal.source.name if meal.source else None,
        source_bundle_id=meal.source.bundle_id if meal.source else None,
        sample_uuids=tuple(str(value) for value in meal.sample_uuids),
    )


def days(start: date, end: date) -> list[date]:
    return [start + timedelta(days=offset) for offset in range((end - start).days + 1)]


def _rounded(values: dict[str, float]) -> dict[str, float]:
    # Keep the catalog order so responses read the same every time.
    return {nutrient.key: round(values[nutrient.key], 1) for nutrient in NUTRIENTS if nutrient.key in values}


def daily_totals(samples: Sequence[Any], start: date, end: date) -> list[dict[str, Any]]:
    """Sum every non-deleted sample per local day. Days without samples are listed as empty, not zero."""
    sums: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    counts: dict[str, int] = defaultdict(int)
    for sample in samples:
        sums[sample["local_date"]][sample["nutrient"]] += sample["value"]
        counts[sample["local_date"]] += 1
    return [
        {"date": day.isoformat(), "samples": counts[day.isoformat()], "nutrients": _rounded(sums[day.isoformat()])}
        for day in days(start, end)
    ]


def _local_time(start_at: str, utc_offset: str) -> str:
    return datetime.fromisoformat(start_at).astimezone(offset_zone(utc_offset)).isoformat(timespec="minutes")


def _source(row: Any) -> str | None:
    return row["source_name"] or row["source_bundle_id"]


def food_log(samples: Sequence[Any], meals: Sequence[Any], limit: int) -> list[dict[str, Any]]:
    """Group samples into what was eaten: HealthKit food correlations first, then loose entries."""
    by_uuid = {sample["uuid"]: sample for sample in samples}
    claimed: set[str] = set()
    entries: list[tuple[str, dict[str, Any]]] = []
    for meal in meals:
        members = [by_uuid[value] for value in json.loads(meal["sample_uuids"]) if value in by_uuid]
        claimed.update(member["uuid"] for member in members)
        totals: dict[str, float] = defaultdict(float)
        for member in members:
            totals[member["nutrient"]] += member["value"]
        entries.append(
            (
                meal["start_at"],
                {
                    "time": _local_time(meal["start_at"], meal["utc_offset"]),
                    "name": meal["food_name"],
                    "meal_type": meal["meal_type"],
                    "source": _source(meal),
                    "relay_entry_id": meal["write_id"],
                    "nutrients": _rounded(totals),
                },
            )
        )
    groups: dict[tuple[Any, ...], list[Any]] = defaultdict(list)
    for sample in samples:
        if sample["uuid"] not in claimed:
            key = (sample["start_at"], sample["source_bundle_id"], sample["food_name"], sample["write_id"])
            groups[key].append(sample)
    for members in groups.values():
        first = members[0]
        totals = defaultdict(float)
        for member in members:
            totals[member["nutrient"]] += member["value"]
        entries.append(
            (
                first["start_at"],
                {
                    "time": _local_time(first["start_at"], first["utc_offset"]),
                    "name": first["food_name"],
                    "meal_type": first["meal_type"],
                    "source": _source(first),
                    "relay_entry_id": first["write_id"],
                    "nutrients": _rounded(totals),
                },
            )
        )
    entries.sort(key=lambda item: item[0], reverse=True)
    return [entry for _, entry in entries[:limit]]


UNITS = {nutrient.key: nutrient.unit for nutrient in NUTRIENTS}
