"""SQLite persistence for paired devices, the Apple Health write queue and uploaded nutrition."""

from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
import uuid
from collections.abc import Callable, Iterable, Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from enum import StrEnum
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
SCHEMA = """
CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    last_pull_at TEXT,
    last_upload_at TEXT,
    app_version TEXT,
    write_access TEXT,
    revoked_at TEXT
);
CREATE TABLE pairing_codes (
    code_hash TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT,
    device_id TEXT
);
CREATE TABLE pairing_failures (at TEXT NOT NULL);
CREATE TABLE writes (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    data TEXT NOT NULL,
    summary TEXT NOT NULL,
    idempotency_key TEXT UNIQUE,
    fingerprint TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    delivered_at TEXT,
    completed_at TEXT,
    device_id TEXT,
    error TEXT,
    healthkit_ids TEXT
);
CREATE INDEX writes_by_status ON writes (status, created_at);
CREATE TABLE nutrition_samples (
    uuid TEXT PRIMARY KEY,
    nutrient TEXT NOT NULL,
    value REAL NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    utc_offset TEXT NOT NULL,
    local_date TEXT NOT NULL,
    source_name TEXT,
    source_bundle_id TEXT,
    food_name TEXT,
    meal_type TEXT,
    write_id TEXT,
    device_id TEXT NOT NULL,
    received_at TEXT NOT NULL,
    deleted_at TEXT
);
CREATE INDEX nutrition_samples_by_day ON nutrition_samples (local_date, nutrient);
CREATE TABLE nutrition_meals (
    uuid TEXT PRIMARY KEY,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    utc_offset TEXT NOT NULL,
    local_date TEXT NOT NULL,
    food_name TEXT,
    meal_type TEXT,
    write_id TEXT,
    source_name TEXT,
    source_bundle_id TEXT,
    sample_uuids TEXT NOT NULL,
    device_id TEXT NOT NULL,
    received_at TEXT NOT NULL,
    deleted_at TEXT
);
CREATE INDEX nutrition_meals_by_day ON nutrition_meals (local_date);
CREATE TABLE nutrition_uploads (
    batch_id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    received_at TEXT NOT NULL,
    samples INTEGER NOT NULL,
    meals INTEGER NOT NULL,
    deleted INTEGER NOT NULL,
    rejected INTEGER NOT NULL
);
"""

CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 8
PAIRING_FAILURE_LIMIT = 10
PAIRING_FAILURE_WINDOW = timedelta(minutes=15)


class WriteStatus(StrEnum):
    pending = "pending"
    written = "written"
    failed = "failed"
    cancelled = "cancelled"
    delete_requested = "delete_requested"
    deleted = "deleted"


class AckResult(StrEnum):
    written = "written"
    failed = "failed"
    deleted = "deleted"


# Entries the iPhone still has to act on: write them, or remove what it wrote.
ACTIONABLE = (WriteStatus.pending, WriteStatus.delete_requested)

# (current status, device result) -> new status. Repeated acknowledgements are idempotent.
TRANSITIONS: dict[tuple[WriteStatus, AckResult], WriteStatus] = {
    (WriteStatus.pending, AckResult.written): WriteStatus.written,
    (WriteStatus.pending, AckResult.failed): WriteStatus.failed,
    (WriteStatus.failed, AckResult.written): WriteStatus.written,
    (WriteStatus.failed, AckResult.failed): WriteStatus.failed,
    (WriteStatus.written, AckResult.written): WriteStatus.written,
    # A cancellation that raced a write wins; the device removes the samples on its next pull.
    (WriteStatus.delete_requested, AckResult.written): WriteStatus.delete_requested,
    (WriteStatus.delete_requested, AckResult.failed): WriteStatus.delete_requested,
    (WriteStatus.delete_requested, AckResult.deleted): WriteStatus.deleted,
    (WriteStatus.deleted, AckResult.deleted): WriteStatus.deleted,
}


class NotFoundError(LookupError):
    pass


class ConflictError(ValueError):
    pass


class RateLimitedError(RuntimeError):
    pass


def utcnow() -> datetime:
    return datetime.now(UTC)


def iso(moment: datetime) -> str:
    """Fixed-width UTC timestamps, so lexical order is chronological order."""
    return moment.astimezone(UTC).isoformat(timespec="milliseconds")


def hash_secret(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def normalize_code(code: str) -> str:
    return "".join(character for character in code.upper() if character not in " -")


@dataclass(frozen=True)
class SampleRow:
    uuid: str
    nutrient: str
    value: float
    start_at: str
    end_at: str
    utc_offset: str
    local_date: str
    source_name: str | None
    source_bundle_id: str | None
    food_name: str | None
    meal_type: str | None
    write_id: str | None


@dataclass(frozen=True)
class MealRow:
    uuid: str
    start_at: str
    end_at: str
    utc_offset: str
    local_date: str
    food_name: str | None
    meal_type: str | None
    write_id: str | None
    source_name: str | None
    source_bundle_id: str | None
    sample_uuids: tuple[str, ...]


class Store:
    def __init__(self, path: Path, now: Callable[[], datetime] = utcnow) -> None:
        self.path = path
        self.now = now
        path.parent.mkdir(parents=True, exist_ok=True)
        self._migrate()

    @contextmanager
    def _connect(self, *, write: bool = False) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        connection.row_factory = sqlite3.Row
        try:
            if write:
                connection.execute("BEGIN IMMEDIATE")
            try:
                yield connection
            except BaseException:
                if write:
                    connection.execute("ROLLBACK")
                raise
            if write:
                connection.execute("COMMIT")
        finally:
            connection.close()

    def _migrate(self) -> None:
        with self._connect() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version > SCHEMA_VERSION:
                raise RuntimeError(f"Database schema {version} is newer than this Relay Hub ({SCHEMA_VERSION})")
            if version == 0:
                connection.executescript(f"BEGIN; {SCHEMA} PRAGMA user_version = {SCHEMA_VERSION}; COMMIT;")

    # Devices and pairing

    def create_pairing_code(self, name: str, minutes: int) -> tuple[str, datetime]:
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
        now = self.now()
        expires = now + timedelta(minutes=minutes)
        with self._connect(write=True) as connection:
            connection.execute(
                "INSERT INTO pairing_codes (code_hash, name, created_at, expires_at) VALUES (?, ?, ?, ?)",
                (hash_secret(code), name, iso(now), iso(expires)),
            )
        return code, expires

    def redeem_pairing_code(self, code: str, device_name: str | None) -> dict[str, str]:
        """Exchange a one-time code for a device token. Only the token's hash is stored."""
        now = self.now()
        window = iso(now - PAIRING_FAILURE_WINDOW)
        token = "rh_" + secrets.token_urlsafe(32)
        device_id = str(uuid.uuid4())
        revoked = False
        with self._connect(write=True) as connection:
            connection.execute("DELETE FROM pairing_failures WHERE at < ?", (window,))
            row = connection.execute(
                "SELECT * FROM pairing_codes WHERE code_hash = ?", (hash_secret(normalize_code(code)),)
            ).fetchone()
            valid = row is not None and row["used_at"] is None and row["expires_at"] > iso(now)
            if valid:
                name = (device_name or "").strip()[:80] or row["name"]
                connection.execute(
                    "INSERT INTO devices (id, name, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?)",
                    (device_id, name, hash_secret(token), iso(now), iso(now)),
                )
                connection.execute(
                    "UPDATE pairing_codes SET used_at = ?, device_id = ? WHERE code_hash = ?",
                    (iso(now), device_id, row["code_hash"]),
                )
            else:
                # Committed with the transaction so failed guesses count even though we reject them.
                connection.execute("INSERT INTO pairing_failures (at) VALUES (?)", (iso(now),))
                failures = connection.execute("SELECT COUNT(*) FROM pairing_failures").fetchone()[0]
                if failures >= PAIRING_FAILURE_LIMIT:
                    # Bound guesses per code without locking out the owner: open codes die, new ones work at once.
                    connection.execute(
                        "UPDATE pairing_codes SET expires_at = ? WHERE used_at IS NULL AND expires_at > ?",
                        (iso(now), iso(now)),
                    )
                    connection.execute("DELETE FROM pairing_failures")
                    revoked = True
        if revoked:
            raise RateLimitedError("Too many invalid pairing codes. Open codes were revoked; create a new one.")
        if not valid:
            raise NotFoundError("This pairing code is invalid, expired or already used.")
        return {"device_id": device_id, "token": token, "name": name}

    def authenticate_device(self, token: str) -> dict[str, Any] | None:
        with self._connect(write=True) as connection:
            row = connection.execute(
                "SELECT * FROM devices WHERE token_hash = ? AND revoked_at IS NULL", (hash_secret(token),)
            ).fetchone()
            if row is None:
                return None
            connection.execute("UPDATE devices SET last_seen_at = ? WHERE id = ?", (iso(self.now()), row["id"]))
            return dict(row)

    def list_devices(self, *, include_revoked: bool = False) -> list[dict[str, Any]]:
        where = "" if include_revoked else " WHERE revoked_at IS NULL"
        with self._connect() as connection:
            rows = connection.execute(f"SELECT * FROM devices{where} ORDER BY created_at").fetchall()  # noqa: S608
        devices = []
        for row in rows:
            # sqlite3.Row iterates over values, so keys() is required here.
            device = {key: row[key] for key in row.keys() if key != "token_hash"}  # noqa: SIM118
            device["write_access"] = json.loads(row["write_access"]) if row["write_access"] else None
            devices.append(device)
        return devices

    def revoke_device(self, device_id: str) -> bool:
        with self._connect(write=True) as connection:
            cursor = connection.execute(
                "UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL", (iso(self.now()), device_id)
            )
            return cursor.rowcount == 1

    # Apple Health write queue

    def create_write(
        self, *, kind: str, data: dict[str, Any], summary: str, fingerprint: str, idempotency_key: str | None
    ) -> tuple[dict[str, Any], bool]:
        """Queue an entry. Retrying with the same idempotency key returns the original entry."""
        now = iso(self.now())
        with self._connect(write=True) as connection:
            if idempotency_key:
                row = connection.execute(
                    "SELECT * FROM writes WHERE idempotency_key = ?", (idempotency_key,)
                ).fetchone()
                if row is not None:
                    if row["fingerprint"] != fingerprint or row["kind"] != kind:
                        raise ConflictError("idempotency_key was already used for a different entry")
                    return self._entry(row), False
            write_id = str(uuid.uuid4())
            connection.execute(
                "INSERT INTO writes (id, kind, status, data, summary, idempotency_key, fingerprint, created_at,"
                " updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    write_id,
                    kind,
                    WriteStatus.pending,
                    json.dumps(data),
                    summary,
                    idempotency_key,
                    fingerprint,
                    now,
                    now,
                ),
            )
            row = connection.execute("SELECT * FROM writes WHERE id = ?", (write_id,)).fetchone()
            return self._entry(row), True

    def get_write(self, write_id: str) -> dict[str, Any]:
        with self._connect() as connection:
            row = connection.execute("SELECT * FROM writes WHERE id = ?", (write_id,)).fetchone()
        if row is None:
            raise NotFoundError(f"No entry with id {write_id}")
        return self._entry(row)

    def list_writes(self, *, statuses: Iterable[str] | None = None, limit: int = 50) -> list[dict[str, Any]]:
        query, parameters = "SELECT * FROM writes", []
        if statuses is not None:
            wanted = list(statuses)
            query += f" WHERE status IN ({','.join('?' * len(wanted))})"  # placeholders only
            parameters.extend(wanted)
        query += " ORDER BY created_at DESC, rowid DESC LIMIT ?"
        with self._connect() as connection:
            rows = connection.execute(query, [*parameters, limit]).fetchall()
        return [self._entry(row) for row in rows]

    def queue_counts(self) -> dict[str, int]:
        with self._connect() as connection:
            rows = connection.execute("SELECT status, COUNT(*) FROM writes GROUP BY status").fetchall()
        return {status: count for status, count in rows}

    def pull_writes(
        self, *, device_id: str, kinds: Sequence[str], write_access: Any, app_version: str | None, limit: int = 200
    ) -> list[dict[str, Any]]:
        """Return entries the device must act on, removals first, then oldest first, and mark them delivered."""
        now = iso(self.now())
        with self._connect(write=True) as connection:
            connection.execute(
                "UPDATE devices SET last_pull_at = ?, app_version = ?, write_access = ? WHERE id = ?",
                (now, app_version, json.dumps(write_access) if write_access is not None else None, device_id),
            )
            if not kinds:
                return []
            rows = connection.execute(
                # Only placeholders are interpolated.
                f"SELECT * FROM writes WHERE status IN (?, ?) AND kind IN ({','.join('?' * len(kinds))})"  # noqa: S608
                " ORDER BY status = ? DESC, created_at, rowid LIMIT ?",
                [*ACTIONABLE, *kinds, WriteStatus.delete_requested, limit],
            ).fetchall()
            connection.executemany(
                "UPDATE writes SET delivered_at = ? WHERE id = ? AND delivered_at IS NULL",
                [(now, row["id"]) for row in rows],
            )
        return [self._device_entry(row) for row in rows]

    def ack_write(
        self,
        *,
        write_id: str,
        device_id: str,
        result: AckResult,
        healthkit_ids: Sequence[str] = (),
        error: str | None = None,
    ) -> dict[str, Any]:
        now = iso(self.now())
        with self._connect(write=True) as connection:
            row = connection.execute("SELECT * FROM writes WHERE id = ?", (write_id,)).fetchone()
            if row is None:
                raise NotFoundError(f"No entry with id {write_id}")
            current = WriteStatus(row["status"])
            target = TRANSITIONS.get((current, result))
            if target is None:
                raise ConflictError(f"Cannot record {result} for an entry that is {current}")
            if target != current:
                completed = now if target in (WriteStatus.written, WriteStatus.failed, WriteStatus.deleted) else None
                ids = json.dumps(list(healthkit_ids)) if result == AckResult.written else row["healthkit_ids"]
                connection.execute(
                    "UPDATE writes SET status = ?, updated_at = ?, completed_at = COALESCE(?, completed_at),"
                    " device_id = ?, error = ?, healthkit_ids = ? WHERE id = ?",
                    (target, now, completed, device_id, error if target == WriteStatus.failed else None, ids, write_id),
                )
            elif result == AckResult.written and current == WriteStatus.delete_requested and healthkit_ids:
                connection.execute(
                    "UPDATE writes SET healthkit_ids = ?, device_id = ? WHERE id = ?",
                    (json.dumps(list(healthkit_ids)), device_id, write_id),
                )
            row = connection.execute("SELECT * FROM writes WHERE id = ?", (write_id,)).fetchone()
        return self._entry(row)

    def cancel_write(self, write_id: str) -> tuple[dict[str, Any], str]:
        """Cancel an entry, or ask the iPhone to remove it from Apple Health if it may already be there."""
        now = iso(self.now())
        with self._connect(write=True) as connection:
            row = connection.execute("SELECT * FROM writes WHERE id = ?", (write_id,)).fetchone()
            if row is None:
                raise NotFoundError(f"No entry with id {write_id}")
            status = WriteStatus(row["status"])
            if status == WriteStatus.pending and row["delivered_at"] is None:
                target, message = WriteStatus.cancelled, "Cancelled. It was never written to Apple Health."
            elif status in (WriteStatus.pending, WriteStatus.written, WriteStatus.failed):
                target = WriteStatus.delete_requested
                message = "Relay will remove it from Apple Health on its next sync."
            else:
                target, message = status, f"Nothing to do: the entry is already {status}."
            if target != status:
                connection.execute("UPDATE writes SET status = ?, updated_at = ? WHERE id = ?", (target, now, write_id))
            row = connection.execute("SELECT * FROM writes WHERE id = ?", (write_id,)).fetchone()
        return self._entry(row), message

    @staticmethod
    def _entry(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "kind": row["kind"],
            "status": row["status"],
            "summary": row["summary"],
            "data": json.loads(row["data"]),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "delivered_at": row["delivered_at"],
            "completed_at": row["completed_at"],
            "error": row["error"],
            "healthkit_ids": json.loads(row["healthkit_ids"]) if row["healthkit_ids"] else [],
        }

    @staticmethod
    def _device_entry(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "kind": row["kind"],
            "action": "delete" if row["status"] == WriteStatus.delete_requested else "write",
            "revision": row["revision"],
            "created_at": row["created_at"],
            "data": json.loads(row["data"]),
        }

    # Nutrition uploaded from Apple Health

    def ingest_nutrition(
        self,
        *,
        device_id: str,
        batch_id: str,
        samples: Sequence[SampleRow],
        meals: Sequence[MealRow],
        deleted: Sequence[str],
        rejected: int,
        complete: bool = False,
    ) -> dict[str, int]:
        """Upsert by HealthKit UUID, so a resent batch changes nothing.

        `complete` means the device has read every nutrition type to the end, so the data is current.
        """
        now = iso(self.now())
        with self._connect(write=True) as connection:
            connection.executemany(
                "INSERT INTO nutrition_samples (uuid, nutrient, value, start_at, end_at, utc_offset, local_date,"
                " source_name, source_bundle_id, food_name, meal_type, write_id, device_id, received_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                " ON CONFLICT (uuid) DO UPDATE SET nutrient = excluded.nutrient, value = excluded.value,"
                " start_at = excluded.start_at, end_at = excluded.end_at, utc_offset = excluded.utc_offset,"
                " local_date = excluded.local_date, source_name = excluded.source_name,"
                " source_bundle_id = excluded.source_bundle_id, food_name = excluded.food_name,"
                " meal_type = excluded.meal_type, write_id = excluded.write_id, device_id = excluded.device_id,"
                " received_at = excluded.received_at, deleted_at = NULL",
                [
                    (
                        s.uuid,
                        s.nutrient,
                        s.value,
                        s.start_at,
                        s.end_at,
                        s.utc_offset,
                        s.local_date,
                        s.source_name,
                        s.source_bundle_id,
                        s.food_name,
                        s.meal_type,
                        s.write_id,
                        device_id,
                        now,
                    )
                    for s in samples
                ],
            )
            connection.executemany(
                "INSERT INTO nutrition_meals (uuid, start_at, end_at, utc_offset, local_date, food_name, meal_type,"
                " write_id, source_name, source_bundle_id, sample_uuids, device_id, received_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                " ON CONFLICT (uuid) DO UPDATE SET start_at = excluded.start_at, end_at = excluded.end_at,"
                " utc_offset = excluded.utc_offset, local_date = excluded.local_date,"
                " food_name = excluded.food_name, meal_type = excluded.meal_type, write_id = excluded.write_id,"
                " source_name = excluded.source_name, source_bundle_id = excluded.source_bundle_id,"
                " sample_uuids = excluded.sample_uuids, device_id = excluded.device_id,"
                " received_at = excluded.received_at, deleted_at = NULL",
                [
                    (
                        m.uuid,
                        m.start_at,
                        m.end_at,
                        m.utc_offset,
                        m.local_date,
                        m.food_name,
                        m.meal_type,
                        m.write_id,
                        m.source_name,
                        m.source_bundle_id,
                        json.dumps(list(m.sample_uuids)),
                        device_id,
                        now,
                    )
                    for m in meals
                ],
            )
            removed = 0
            for table in ("nutrition_samples", "nutrition_meals"):
                for start in range(0, len(deleted), 500):
                    chunk = list(deleted[start : start + 500])
                    cursor = connection.execute(
                        f"UPDATE {table} SET deleted_at = ? WHERE deleted_at IS NULL"  # noqa: S608
                        f" AND uuid IN ({','.join('?' * len(chunk))})",
                        [now, *chunk],
                    )
                    removed += cursor.rowcount
            if samples or meals or deleted or rejected:
                connection.execute(
                    "INSERT OR REPLACE INTO nutrition_uploads (batch_id, device_id, received_at, samples, meals,"
                    " deleted, rejected) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (batch_id, device_id, now, len(samples), len(meals), len(deleted), rejected),
                )
            if complete:
                connection.execute("UPDATE devices SET last_upload_at = ? WHERE id = ?", (now, device_id))
        return {"samples": len(samples), "meals": len(meals), "deleted": removed}

    def nutrition_samples(self, start: date, end: date) -> list[sqlite3.Row]:
        with self._connect() as connection:
            return connection.execute(
                "SELECT * FROM nutrition_samples WHERE deleted_at IS NULL AND local_date BETWEEN ? AND ?"
                " ORDER BY start_at",
                (start.isoformat(), end.isoformat()),
            ).fetchall()

    def nutrition_meals(self, start: date, end: date) -> list[sqlite3.Row]:
        with self._connect() as connection:
            return connection.execute(
                "SELECT * FROM nutrition_meals WHERE deleted_at IS NULL AND local_date BETWEEN ? AND ?"
                " ORDER BY start_at",
                (start.isoformat(), end.isoformat()),
            ).fetchall()

    def uploaded_write_ids(self, write_ids: Sequence[str]) -> set[str]:
        """Queue entries whose Apple Health samples Relay has already uploaded."""
        if not write_ids:
            return set()
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT DISTINCT write_id FROM nutrition_samples WHERE deleted_at IS NULL"  # noqa: S608
                f" AND write_id IN ({','.join('?' * len(write_ids))})",
                list(write_ids),
            ).fetchall()
        return {row[0] for row in rows}

    def last_nutrition_upload(self) -> str | None:
        """When a paired device last finished reading all nutrition, even if nothing had changed."""
        with self._connect() as connection:
            return connection.execute("SELECT MAX(last_upload_at) FROM devices WHERE revoked_at IS NULL").fetchone()[0]
