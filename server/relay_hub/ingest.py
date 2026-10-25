"""Validation of health data uploaded by Relay. Records are checked one by one, so one bad record
cannot block the rest of a HealthKit page."""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Annotated, Any, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import AwareDatetime, BaseModel, BeforeValidator, ConfigDict, Field, ValidationError

from .meals import offset_text
from .store import iso

LIMITS = {"quantities": 2_000, "categories": 2_000, "workouts": 500, "meals": 500, "deleted": 2_000, "daily": 2_000}
OFFSET = re.compile(r"^([+-])(\d{2}):(\d{2})$")
METADATA_LIMIT = 4_000


def _clipped(limit: int) -> BeforeValidator:
    """Shorten over-long optional text instead of rejecting the record and losing its value."""
    return BeforeValidator(lambda value: value[:limit] if isinstance(value, str) else value)


def _offset_or_none(value: Any) -> Any:
    return value if isinstance(value, str) and OFFSET.match(value) else None


def _small_metadata(value: Any) -> Any:
    """Keep string metadata that fits; drop it entirely rather than reject the sample."""
    if not isinstance(value, dict):
        return None
    clean = {str(key)[:100]: str(item)[:500] for key, item in value.items()}
    return clean if len(json.dumps(clean)) <= METADATA_LIMIT else None


Text = Annotated[str | None, _clipped(200)]
Label = Annotated[str | None, _clipped(64)]
Offset = Annotated[str | None, BeforeValidator(_offset_or_none)]
Metadata = Annotated[dict[str, str] | None, BeforeValidator(_small_metadata)]
TypeID = Annotated[str, Field(max_length=100, pattern=r"^HK[A-Za-z0-9]+$")]


class SourceIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    name: Text = None
    bundle_id: Text = None
    device: Text = None


class RecordIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    uuid: UUID
    start: AwareDatetime
    end: AwareDatetime
    time_zone: Label = None
    utc_offset: Offset = None
    source: SourceIn | None = None


class QuantityIn(RecordIn):
    type: TypeID
    value: float
    unit: str = Field(max_length=32)
    food_name: Text = None
    meal_type: Label = None
    write_id: UUID | None = None
    metadata: Metadata = None


class CategoryIn(RecordIn):
    type: TypeID
    value: int
    label: Label = None
    metadata: Metadata = None


class WorkoutIn(RecordIn):
    activity: Annotated[str, _clipped(64)]
    duration_s: float
    energy_kcal: float | None = None
    distance_m: float | None = None
    avg_heart_rate: float | None = None
    min_heart_rate: float | None = None
    max_heart_rate: float | None = None
    metadata: Metadata = None
    # Long event lists are cut rather than costing the whole workout.
    events: Annotated[
        list[dict[str, Any]] | None, BeforeValidator(lambda value: value[:1_000] if isinstance(value, list) else value)
    ] = None


class MealIn(RecordIn):
    food_name: Text = None
    meal_type: Label = None
    write_id: UUID | None = None
    sample_uuids: list[UUID] = Field(default_factory=list, max_length=200)


class DailyIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    type: TypeID
    date: date
    time_zone: Label = None
    sum: float | None = None
    average: float | None = None
    minimum: float | None = None
    maximum: float | None = None


class TypeIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: TypeID
    kind: Literal["quantity", "category", "workout", "correlation"]
    title: Annotated[str, _clipped(100)]
    group: Annotated[str, _clipped(40)]
    unit: str | None = Field(None, max_length=32)
    aggregation: Literal["cumulative", "discrete"] | None = None


class InvalidBatchError(ValueError):
    pass


@dataclass
class Batch:
    batch_id: str
    records: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    deleted: list[str] = field(default_factory=list)
    daily: list[dict[str, Any]] = field(default_factory=list)
    rejected: list[dict[str, Any]] = field(default_factory=list)
    complete: bool = False


def offset_zone(text: str) -> timezone:
    sign, hours, minutes = OFFSET.match(text).groups()
    delta = timedelta(hours=int(hours), minutes=int(minutes))
    return timezone(-delta if sign == "-" else delta)


def local(moment: datetime, time_zone: str | None, utc_offset: str | None, fallback: ZoneInfo) -> datetime:
    """Local time from the record's IANA zone, else its UTC offset, else the hub's zone."""
    if time_zone:
        try:
            return moment.astimezone(ZoneInfo(time_zone))
        except (ZoneInfoNotFoundError, ValueError):
            pass
    if utc_offset:
        return moment.astimezone(offset_zone(utc_offset))
    return moment.astimezone(fallback)


def parse_types(body: Any) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    entries = body.get("types") if isinstance(body, dict) else None
    if not isinstance(entries, list) or len(entries) > 500:
        raise InvalidBatchError("types must be an array of at most 500 entries")
    types, rejected = [], []
    for index, item in enumerate(entries):
        try:
            types.append(TypeIn.model_validate(item).model_dump())
        except ValidationError as error:
            rejected.append({"collection": "types", "index": index, "reason": _reason(error)})
    return types, rejected


def parse_batch(body: Any, fallback: ZoneInfo, registry: dict[str, dict[str, Any]]) -> Batch:
    if not isinstance(body, dict):
        raise InvalidBatchError("Expected a JSON object")
    batch_id = body.get("batch_id")
    if not isinstance(batch_id, str) or not 0 < len(batch_id) <= 64:
        raise InvalidBatchError("batch_id must be a string of at most 64 characters")
    collections = {key: body.get(key, []) for key in LIMITS}
    for key, values in collections.items():
        if not isinstance(values, list):
            raise InvalidBatchError(f"{key} must be an array")
        if len(values) > LIMITS[key]:
            raise InvalidBatchError(f"At most {LIMITS[key]} {key} per batch")
    batch = Batch(batch_id=batch_id, complete=body.get("complete") is True)
    builders = {"quantities": _quantity, "categories": _category, "workouts": _workout, "meals": _meal}
    for key, build in builders.items():
        batch.records[key] = []
        for index, item in enumerate(collections[key]):
            try:
                batch.records[key].append(build(item, fallback, registry))
            except (ValidationError, ValueError) as error:
                batch.rejected.append({"collection": key, "index": index, "reason": _reason(error)})
    for index, item in enumerate(collections["deleted"]):
        try:
            batch.deleted.append(str(UUID(str(item))))
        except ValueError:
            batch.rejected.append({"collection": "deleted", "index": index, "reason": "not a UUID"})
    for index, item in enumerate(collections["daily"]):
        try:
            batch.daily.append(_daily(item, registry))
        except (ValidationError, ValueError) as error:
            batch.rejected.append({"collection": "daily", "index": index, "reason": _reason(error)})
    return batch


def _reason(error: Exception) -> str:
    if isinstance(error, ValidationError):
        first = error.errors()[0]
        return f"{'.'.join(str(part) for part in first['loc'])}: {first['msg']}"
    return str(error)


def _registered(type_id: str, kind: str, registry: dict[str, dict[str, Any]]) -> dict[str, Any]:
    entry = registry.get(type_id)
    if entry is None or entry["kind"] != kind:
        raise ValueError(f"type: {type_id} is not a registered {kind} type")
    return entry


def _common(record: RecordIn, fallback: ZoneInfo) -> dict[str, Any]:
    if record.end < record.start:
        raise ValueError("end: before start")
    moment = local(record.start, record.time_zone, record.utc_offset, fallback)
    source = record.source or SourceIn()
    return {
        "uuid": str(record.uuid),
        "start_at": iso(record.start),
        "end_at": iso(record.end),
        "utc_offset": offset_text(moment),
        "local_date": moment.date().isoformat(),
        "source_name": source.name,
        "source_bundle_id": source.bundle_id,
    }


def _metadata(value: dict[str, str] | None) -> str | None:
    return json.dumps(value, sort_keys=True) if value else None


def _quantity(item: Any, fallback: ZoneInfo, registry: dict[str, dict[str, Any]]) -> dict[str, Any]:
    sample = QuantityIn.model_validate(item)
    entry = _registered(sample.type, "quantity", registry)
    if sample.unit != entry["unit"]:
        raise ValueError(f"unit: {sample.type} must be sent in {entry['unit']}")
    if not math.isfinite(sample.value):
        raise ValueError("value: must be a finite number")
    return _common(sample, fallback) | {
        "type": sample.type,
        "value": sample.value,
        "unit": sample.unit,
        "device_name": sample.source.device if sample.source else None,
        "food_name": (sample.food_name or "").strip() or None,
        "meal_type": sample.meal_type,
        "write_id": str(sample.write_id) if sample.write_id else None,
        "metadata": _metadata(sample.metadata),
    }


def _category(item: Any, fallback: ZoneInfo, registry: dict[str, dict[str, Any]]) -> dict[str, Any]:
    sample = CategoryIn.model_validate(item)
    _registered(sample.type, "category", registry)
    return _common(sample, fallback) | {
        "type": sample.type,
        "value": sample.value,
        "label": sample.label,
        "device_name": sample.source.device if sample.source else None,
        "metadata": _metadata(sample.metadata),
    }


def _finite(value: float | None, name: str) -> float | None:
    if value is not None and not math.isfinite(value):
        raise ValueError(f"{name}: must be a finite number")
    return value


def _workout(item: Any, fallback: ZoneInfo, registry: dict[str, dict[str, Any]]) -> dict[str, Any]:
    workout = WorkoutIn.model_validate(item)
    if not math.isfinite(workout.duration_s) or workout.duration_s < 0:
        raise ValueError("duration_s: must be a finite, non-negative number")
    events = json.dumps(workout.events) if workout.events else None
    return _common(workout, fallback) | {
        "activity": workout.activity,
        "duration_s": workout.duration_s,
        "energy_kcal": _finite(workout.energy_kcal, "energy_kcal"),
        "distance_m": _finite(workout.distance_m, "distance_m"),
        "avg_heart_rate": _finite(workout.avg_heart_rate, "avg_heart_rate"),
        "min_heart_rate": _finite(workout.min_heart_rate, "min_heart_rate"),
        "max_heart_rate": _finite(workout.max_heart_rate, "max_heart_rate"),
        "device_name": workout.source.device if workout.source else None,
        "metadata": _metadata(workout.metadata),
        "events": events if events and len(events) <= 200_000 else None,
    }


def _meal(item: Any, fallback: ZoneInfo, registry: dict[str, dict[str, Any]]) -> dict[str, Any]:
    meal = MealIn.model_validate(item)
    return _common(meal, fallback) | {
        "food_name": (meal.food_name or "").strip() or None,
        "meal_type": meal.meal_type,
        "write_id": str(meal.write_id) if meal.write_id else None,
        "sample_uuids": json.dumps([str(value) for value in meal.sample_uuids]),
    }


def _daily(item: Any, registry: dict[str, dict[str, Any]]) -> dict[str, Any]:
    stat = DailyIn.model_validate(item)
    _registered(stat.type, "quantity", registry)
    return {
        "type": stat.type,
        "date": stat.date.isoformat(),
        "time_zone": stat.time_zone,
        **{name: _finite(getattr(stat, name), name) for name in ("sum", "average", "minimum", "maximum")},
    }
