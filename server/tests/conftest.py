from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest
from starlette.testclient import TestClient

from relay_hub.app import create_app
from relay_hub.config import Settings
from relay_hub.ingest import parse_batch
from relay_hub.nutrients import NUTRIENTS
from relay_hub.store import Store

MCP_TOKEN = "m" * 40
BRUSSELS = ZoneInfo("Europe/Brussels")


def kind(
    type_id: str, kind: str, title: str, group: str, unit: str | None = None, aggregation: str | None = None
) -> dict:
    return {"id": type_id, "kind": kind, "title": title, "group": group, "unit": unit, "aggregation": aggregation}


TYPES = [
    kind(nutrient.identifier, "quantity", nutrient.title, "nutrition", nutrient.unit, "cumulative")
    for nutrient in NUTRIENTS
] + [
    kind("HKQuantityTypeIdentifierStepCount", "quantity", "Step Count", "activity", "count", "cumulative"),
    kind("HKQuantityTypeIdentifierHeartRate", "quantity", "Heart Rate", "vitals", "count/min", "discrete"),
    kind("HKQuantityTypeIdentifierBodyMass", "quantity", "Body Mass", "body", "kg", "discrete"),
    kind("HKCategoryTypeIdentifierSleepAnalysis", "category", "Sleep stages", "sleep"),
    kind("HKWorkoutTypeIdentifier", "workout", "Workouts", "workouts"),
    kind("HKCorrelationTypeIdentifierFood", "correlation", "Food", "nutrition"),
]


def upload(store: Store, device_id: str, body: dict, zone: ZoneInfo = BRUSSELS):
    batch = parse_batch(body, zone, store.types())
    counts = store.ingest(
        device_id=device_id,
        batch_id=batch.batch_id,
        records=batch.records,
        deleted=batch.deleted,
        daily=batch.daily,
        rejected=len(batch.rejected),
        complete=batch.complete,
    )
    return counts, batch


class Clock:
    def __init__(self) -> None:
        self.current = datetime(2026, 10, 21, 10, 30, tzinfo=UTC)

    def __call__(self) -> datetime:
        return self.current

    def advance(self, **delta: float) -> None:
        self.current += timedelta(**delta)


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(database=tmp_path / "hub.sqlite3", mcp_token=MCP_TOKEN, timezone="Europe/Brussels")


@pytest.fixture
def store(settings: Settings, clock: Clock) -> Store:
    store = Store(settings.database, now=clock)
    store.register_types(TYPES)
    return store


@pytest.fixture
def device_id(store: Store) -> str:
    code, _ = store.create_pairing_code("Test iPhone", 10)
    return store.redeem_pairing_code(code, None)["device_id"]


@pytest.fixture
def client(settings: Settings, store: Store) -> Iterator[TestClient]:
    with TestClient(create_app(settings, store), base_url="http://127.0.0.1:8787") as test_client:
        yield test_client


@pytest.fixture
def device_token(store: Store) -> str:
    code, _ = store.create_pairing_code("Test iPhone", 10)
    return store.redeem_pairing_code(code, None)["token"]


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}
