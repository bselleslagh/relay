from __future__ import annotations

import sqlite3

import pytest

from relay_hub.store import (
    PAIRING_FAILURE_LIMIT,
    AckResult,
    ConflictError,
    NotFoundError,
    RateLimitedError,
    Store,
    WriteStatus,
)

MEAL = {"consumed_at": "2026-10-21T12:00:00+02:00", "nutrients": {"energy_kcal": 500.0}}


def queue(store: Store, key: str | None = None, fingerprint: str = "a") -> dict:
    entry, _ = store.create_write(kind="meal", data=MEAL, summary="Meal", fingerprint=fingerprint, idempotency_key=key)
    return entry


def device(store: Store) -> str:
    code, _ = store.create_pairing_code("iPhone", 10)
    return store.redeem_pairing_code(code, "Ben's iPhone")["device_id"]


def pull(store: Store, device_id: str, kinds: tuple[str, ...] = ("meal",)) -> list[dict]:
    return store.pull_writes(device_id=device_id, kinds=kinds, write_access={"meal": "authorized"}, app_version="1.1")


def test_pairing_code_works_once_and_only_its_hash_is_stored(store: Store) -> None:
    code, _ = store.create_pairing_code("iPhone", 10)
    paired = store.redeem_pairing_code(f"{code[:4].lower()}-{code[4:]}", "Ben's iPhone")
    assert paired["name"] == "Ben's iPhone"
    assert store.authenticate_device(paired["token"])["id"] == paired["device_id"]
    with pytest.raises(NotFoundError):
        store.redeem_pairing_code(code, None)
    connection = sqlite3.connect(store.path)
    dump = "\n".join(connection.iterdump())
    connection.close()
    assert code not in dump and paired["token"] not in dump


def test_expired_code_is_rejected(store: Store, clock) -> None:
    code, _ = store.create_pairing_code("iPhone", 10)
    clock.advance(minutes=11)
    with pytest.raises(NotFoundError):
        store.redeem_pairing_code(code, None)


def test_repeated_wrong_codes_revoke_open_codes_without_locking_out_new_ones(store: Store) -> None:
    code, _ = store.create_pairing_code("iPhone", 30)
    for _ in range(PAIRING_FAILURE_LIMIT - 1):
        with pytest.raises(NotFoundError):
            store.redeem_pairing_code("AAAAAAAA", None)
    with pytest.raises(RateLimitedError):
        store.redeem_pairing_code("AAAAAAAA", None)
    with pytest.raises(NotFoundError):
        store.redeem_pairing_code(code, None)
    fresh, _ = store.create_pairing_code("iPhone", 10)
    assert store.redeem_pairing_code(fresh, None)["token"].startswith("rh_")


def test_revoked_device_cannot_authenticate(store: Store) -> None:
    code, _ = store.create_pairing_code("iPhone", 10)
    paired = store.redeem_pairing_code(code, None)
    assert store.revoke_device(paired["device_id"])
    assert store.authenticate_device(paired["token"]) is None
    assert store.list_devices() == []


def test_write_is_delivered_written_and_acknowledged_idempotently(store: Store) -> None:
    device_id = device(store)
    entry = queue(store)
    [delivered] = pull(store, device_id)
    assert delivered == {
        "id": entry["id"],
        "kind": "meal",
        "action": "write",
        "revision": 1,
        "created_at": entry["created_at"],
        "data": MEAL,
    }
    assert store.get_write(entry["id"])["delivered_at"] is not None
    for _ in range(2):
        written = store.ack_write(
            write_id=entry["id"], device_id=device_id, result=AckResult.written, healthkit_ids=["HK-1"]
        )
    assert written["status"] == WriteStatus.written and written["healthkit_ids"] == ["HK-1"]
    assert pull(store, device_id) == []


def test_cancel_before_delivery_never_reaches_the_phone(store: Store) -> None:
    device_id = device(store)
    entry = queue(store)
    cancelled, message = store.cancel_write(entry["id"])
    assert cancelled["status"] == WriteStatus.cancelled and "never written" in message
    assert pull(store, device_id) == []
    with pytest.raises(ConflictError):
        store.ack_write(write_id=entry["id"], device_id=device_id, result=AckResult.written)


def test_cancel_racing_a_write_removes_it_from_apple_health(store: Store) -> None:
    device_id = device(store)
    entry = queue(store)
    pull(store, device_id)
    assert store.cancel_write(entry["id"])[0]["status"] == WriteStatus.delete_requested
    # The phone finishes the write it already started; the cancellation still wins.
    raced = store.ack_write(write_id=entry["id"], device_id=device_id, result=AckResult.written, healthkit_ids=["HK"])
    assert raced["status"] == WriteStatus.delete_requested
    [removal] = pull(store, device_id)
    assert removal["action"] == "delete"
    done = store.ack_write(write_id=entry["id"], device_id=device_id, result=AckResult.deleted)
    assert done["status"] == WriteStatus.deleted and done["completed_at"]
    assert store.cancel_write(entry["id"])[0]["status"] == WriteStatus.deleted


def test_cancelling_a_failed_write_still_verifies_removal(store: Store) -> None:
    device_id = device(store)
    entry = queue(store)
    pull(store, device_id)
    failed = store.ack_write(write_id=entry["id"], device_id=device_id, result=AckResult.failed, error="Invalid")
    assert failed["status"] == WriteStatus.failed and failed["error"] == "Invalid"
    # A failure report can follow a save whose earlier ack was lost, so the phone checks Apple Health.
    assert store.cancel_write(entry["id"])[0]["status"] == WriteStatus.delete_requested
    assert [write["action"] for write in pull(store, device_id)] == ["delete"]


def test_invalid_acknowledgements_are_rejected(store: Store) -> None:
    device_id = device(store)
    entry = queue(store)
    with pytest.raises(ConflictError):
        store.ack_write(write_id=entry["id"], device_id=device_id, result=AckResult.deleted)
    with pytest.raises(NotFoundError):
        store.ack_write(write_id="missing", device_id=device_id, result=AckResult.written)


def test_idempotency_key_returns_the_original_entry(store: Store) -> None:
    first = queue(store, key="lunch-1")
    again, created = store.create_write(
        kind="meal", data=MEAL, summary="Meal", fingerprint="a", idempotency_key="lunch-1"
    )
    assert again["id"] == first["id"] and not created
    with pytest.raises(ConflictError):
        queue(store, key="lunch-1", fingerprint="different")
    assert len(store.list_writes()) == 1


def test_removals_are_delivered_before_older_writes(store: Store) -> None:
    device_id = device(store)
    older = queue(store, key="a")
    newer = queue(store, key="b", fingerprint="b")
    pull(store, device_id)
    store.cancel_write(newer["id"])
    assert [(write["id"], write["action"]) for write in pull(store, device_id)] == [
        (newer["id"], "delete"),
        (older["id"], "write"),
    ]


def test_pull_only_returns_kinds_the_app_supports(store: Store) -> None:
    device_id = device(store)
    queue(store)
    assert pull(store, device_id, kinds=()) == []
    assert pull(store, device_id, kinds=("workout",)) == []
    assert len(pull(store, device_id)) == 1
    assert store.list_devices()[0]["write_access"] == {"meal": "authorized"}


def test_preview_database_keeps_pairing_and_gains_health_tables(tmp_path) -> None:
    path = tmp_path / "preview.sqlite3"
    connection = sqlite3.connect(path)
    from relay_hub.store import SCHEMA

    connection.executescript(f"{SCHEMA} CREATE TABLE nutrition_samples (uuid TEXT); PRAGMA user_version = 1;")
    connection.execute("INSERT INTO devices (id, name, token_hash, created_at) VALUES ('d', 'iPhone', 'h', 'now')")
    connection.commit()
    connection.close()
    store = Store(path)
    assert [device["id"] for device in store.list_devices()] == ["d"]
    assert store.types() == {}
    assert not store.query("SELECT name FROM sqlite_master WHERE name = 'nutrition_samples'")


def test_database_from_a_newer_version_is_refused(store: Store) -> None:
    connection = sqlite3.connect(store.path)
    connection.execute("PRAGMA user_version = 99")
    connection.close()
    with pytest.raises(RuntimeError):
        Store(store.path)
