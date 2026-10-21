from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from relay_hub.app import create_app
from relay_hub.config import Settings
from relay_hub.store import Store

MCP_TOKEN = "m" * 40


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
    return Store(settings.database, now=clock)


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
