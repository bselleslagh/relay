"""MCP tools: read the Apple Health data Relay uploaded, and queue Apple Health writes."""

from __future__ import annotations

import hashlib
import hmac
import json
from datetime import date, datetime, timedelta
from typing import Annotated, Any, Literal

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from fastmcp.server.auth import AccessToken, TokenVerifier
from mcp.types import ToolAnnotations
from pydantic import Field

from . import meals, nutrition, summaries
from .config import Settings
from .store import ACTIONABLE, ConflictError, NotFoundError, Store, WriteStatus

STATUS_MEANING = {
    WriteStatus.pending: "Queued. Relay has not written it to Apple Health yet.",
    WriteStatus.written: "Saved in Apple Health by Relay.",
    WriteStatus.failed: "Relay could not save it to Apple Health. See error.",
    WriteStatus.cancelled: "Cancelled before it reached Apple Health.",
    WriteStatus.delete_requested: "Relay will remove it from Apple Health on its next sync.",
    WriteStatus.deleted: "Removed from Apple Health.",
}
MAX_RANGE_DAYS = 92

INSTRUCTIONS = """\
Relay Hub holds the user's Apple Health data, uploaded by the Relay iPhone app, and lets you log meals back into
Apple Health.

Reading: start with list_data_types to see what exists and how fresh it is. get_daily_summary returns HealthKit's own
daily statistics: sums for cumulative types such as steps and active energy, average/min/max for the rest. They merge
overlapping sources such as iPhone and Apple Watch, so prefer them over adding raw samples yourself. get_samples
returns raw readings (for example weight, heart rate variability or blood pressure). get_sleep summarises each night
and get_workouts lists workouts. get_nutrition_totals and list_food_log cover food and drink. Check synced_at (when
Relay last finished uploading) before you call data current, keep units, and distinguish missing data from zero.

Writing: log_meal queues an entry. Relay saves it to Apple Health on its next sync, usually within minutes while the
app is open; otherwise when iOS grants background time. Use one log_meal call per meal or portion, with totals for
the whole portion. Confirm uncertain portions with the user instead of guessing. Give consumed_at in the user's local
time with its UTC offset. After a timeout or error, call list_recent before logging again, or reuse the same
idempotency_key, so nothing is logged twice. To correct an entry, cancel_entry it and log a new one. Entries Relay has
not yet saved and uploaded are listed in get_nutrition_totals as not_in_totals_yet.
"""


class StaticTokenVerifier(TokenVerifier):
    """A single bearer token for the MCP client, compared in constant time."""

    def __init__(self, token: str) -> None:
        super().__init__()
        self._token = token.encode()

    async def verify_token(self, token: str) -> AccessToken | None:
        if hmac.compare_digest(token.encode(), self._token):
            return AccessToken(token="mcp-client", client_id="mcp-client", scopes=[])  # noqa: S106
        return None


def present(entry: dict[str, Any]) -> dict[str, Any]:
    data = entry["data"]
    shown: dict[str, Any] = {
        "id": entry["id"],
        "kind": entry["kind"],
        "status": entry["status"],
        "status_meaning": STATUS_MEANING[WriteStatus(entry["status"])],
        "summary": entry["summary"],
        "created_at": entry["created_at"],
    }
    if entry["kind"] == "meal":
        shown |= {
            "consumed_at": data["consumed_at"],
            "name": data.get("name"),
            "meal_type": data.get("meal_type"),
            "nutrients": data["nutrients"],
        }
    if entry["completed_at"]:
        shown["completed_at"] = entry["completed_at"]
    if entry["error"]:
        shown["error"] = entry["error"]
    return shown


def build_mcp(store: Store, settings: Settings, *, auth: bool = True) -> FastMCP:
    mcp = FastMCP(
        "relay-hub",
        instructions=INSTRUCTIONS,
        auth=StaticTokenVerifier(settings.mcp_token) if auth else None,
        mask_error_details=True,
    )

    def today() -> date:
        return store.now().astimezone(settings.zone).date()

    def date_range(start: date | None, end: date | None, default_days: int) -> tuple[date, date]:
        end = end or today()
        start = start or end - timedelta(days=default_days - 1)
        if start > end:
            raise ToolError("start_date must be on or before end_date")
        if (end - start).days >= MAX_RANGE_DAYS:
            raise ToolError(f"Request at most {MAX_RANGE_DAYS} days at a time")
        return start, end

    @mcp.tool(annotations=ToolAnnotations(title="Log a meal", destructiveHint=False, openWorldHint=False))
    def log_meal(
        energy_kcal: Annotated[float, Field(description="Energy for the whole portion, in kilocalories (kcal).")],
        protein_g: Annotated[float, Field(description="Protein in grams.")],
        carbohydrates_g: Annotated[float, Field(description="Total carbohydrates in grams.")],
        fat_g: Annotated[float, Field(description="Total fat in grams.")],
        consumed_at: Annotated[
            str | None,
            Field(
                description="When it was eaten, ISO 8601 with UTC offset, e.g. 2026-10-21T12:30:00+02:00. "
                "Without an offset the hub's time zone is used. Defaults to now."
            ),
        ] = None,
        name: Annotated[str | None, Field(description="Short food or meal name, e.g. 'Chicken salad'.")] = None,
        meal_type: Literal["breakfast", "lunch", "dinner", "snack"] | None = None,
        fiber_g: Annotated[float | None, Field(description="Dietary fiber in grams.")] = None,
        sugar_g: Annotated[float | None, Field(description="Sugars in grams.")] = None,
        idempotency_key: Annotated[
            str | None,
            Field(max_length=128, description="Optional key. Retrying with the same key never logs twice."),
        ] = None,
    ) -> dict[str, Any]:
        """Queue a meal for Apple Health. Relay writes it as one food entry with these nutrients on its next sync."""
        values = {
            "energy_kcal": energy_kcal,
            "protein_g": protein_g,
            "carbohydrates_g": carbohydrates_g,
            "fat_g": fat_g,
            "fiber_g": fiber_g,
            "sugar_g": sugar_g,
        }
        try:
            data, notes = meals.build_meal(
                nutrients=values,
                consumed_at=consumed_at,
                name=name,
                meal_type=meal_type,
                zone=settings.zone,
                now=store.now(),
            )
        except meals.InvalidMealError as error:
            raise ToolError(str(error)) from error
        request = {"values": values, "consumed_at": consumed_at, "name": name, "meal_type": meal_type}
        fingerprint = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        try:
            entry, created = store.create_write(
                kind="meal",
                data=data,
                summary=meals.summary(data),
                fingerprint=fingerprint,
                idempotency_key=idempotency_key,
            )
        except ConflictError as error:
            raise ToolError(str(error)) from error
        result: dict[str, Any] = {"entry": present(entry), "created": created}
        if notes:
            result["warnings"] = notes
        return result

    @mcp.tool(annotations=ToolAnnotations(title="List pending entries", readOnlyHint=True, openWorldHint=False))
    def list_pending() -> dict[str, Any]:
        """Entries Relay has not finished: queued writes and removals it still has to make in Apple Health."""
        entries = store.list_writes(statuses=ACTIONABLE, limit=200)
        return {"count": len(entries), "entries": [present(entry) for entry in reversed(entries)]}

    @mcp.tool(annotations=ToolAnnotations(title="List recent entries", readOnlyHint=True, openWorldHint=False))
    def list_recent(
        limit: Annotated[int, Field(ge=1, le=100)] = 20,
        status: Literal["pending", "written", "failed", "cancelled", "delete_requested", "deleted"] | None = None,
    ) -> dict[str, Any]:
        """Entries created through this hub, newest first, with their Apple Health status."""
        entries = store.list_writes(statuses=[status] if status else None, limit=limit)
        return {"entries": [present(entry) for entry in entries]}

    @mcp.tool(
        annotations=ToolAnnotations(
            title="Cancel an entry", destructiveHint=True, idempotentHint=True, openWorldHint=False
        )
    )
    def cancel_entry(
        entry_id: Annotated[str, Field(description="The id returned by log_meal or list_recent.")],
    ) -> dict:
        """Cancel a queued entry. If Relay may already have saved it, Relay removes it from Apple Health instead."""
        try:
            entry, message = store.cancel_write(entry_id.strip())
        except NotFoundError as error:
            raise ToolError(str(error)) from error
        return {"entry": present(entry), "message": message}

    @mcp.tool(annotations=ToolAnnotations(title="Daily nutrition totals", readOnlyHint=True, openWorldHint=False))
    def get_nutrition_totals(
        start_date: Annotated[
            date | None, Field(description="First local day, YYYY-MM-DD. Default: 6 days ago.")
        ] = None,
        end_date: Annotated[date | None, Field(description="Last local day, YYYY-MM-DD. Default: today.")] = None,
    ) -> dict[str, Any]:
        """Daily intake totals from Apple Health nutrition uploaded by Relay, plus entries not reflected yet."""
        start, end = date_range(start_date, end_date, 7)
        statuses = [WriteStatus.pending, WriteStatus.written, WriteStatus.delete_requested]
        entries = [
            entry
            for entry in store.list_writes(statuses=statuses, limit=500)
            if entry["kind"] == "meal" and start <= datetime.fromisoformat(entry["data"]["consumed_at"]).date() <= end
        ]
        ids = [entry["id"] for entry in entries]
        # Ever uploaded: a meal later deleted in Apple Health must not be suggested as missing.
        ever, live = store.uploaded_write_ids(ids, live=False), store.uploaded_write_ids(ids)
        return {
            "time_zone": settings.timezone,
            "units": nutrition.UNITS,
            "synced_at": store.last_upload(),
            "days": nutrition.daily_totals(nutrition.samples(store, start, end), start, end),
            # Queued, or saved to Apple Health but not uploaded back yet: add these for an up-to-the-minute estimate.
            "not_in_totals_yet": [
                present(entry)
                for entry in entries
                if entry["status"] != WriteStatus.delete_requested and entry["id"] not in ever
            ],
            # Cancelled after delivery: still counted until Relay removes them and uploads the deletion.
            "removal_pending": [
                present(entry)
                for entry in entries
                if entry["status"] == WriteStatus.delete_requested and entry["id"] in live
            ],
        }

    @mcp.tool(annotations=ToolAnnotations(title="Food log", readOnlyHint=True, openWorldHint=False))
    def list_food_log(
        start_date: Annotated[date | None, Field(description="First local day, YYYY-MM-DD. Default: today.")] = None,
        end_date: Annotated[date | None, Field(description="Last local day, YYYY-MM-DD. Default: today.")] = None,
        limit: Annotated[int, Field(ge=1, le=200)] = 50,
    ) -> dict[str, Any]:
        """What was eaten, newest first: Apple Health food entries with their nutrients and source app."""
        end = end_date or today()
        start, end = date_range(start_date or end, end, 1)
        entries = nutrition.food_log(
            nutrition.samples(store, start, end), nutrition.food_entries(store, start, end), limit
        )
        return {"units": nutrition.UNITS, "synced_at": store.last_upload(), "entries": entries}

    @mcp.tool(annotations=ToolAnnotations(title="Sync status", readOnlyHint=True, openWorldHint=False))
    def get_sync_status() -> dict[str, Any]:
        """When each paired iPhone last synced, whether it may write meals to Apple Health, and queue counts."""
        devices = [
            {
                "name": device["name"],
                "last_pull_at": device["last_pull_at"],
                "synced_at": device["last_upload_at"],
                "write_access": device["write_access"],
                "app_version": device["app_version"],
            }
            for device in store.list_devices()
        ]
        return {
            "server_time": store.now().astimezone(settings.zone).isoformat(timespec="seconds"),
            "time_zone": settings.timezone,
            "devices": devices,
            "queue": store.queue_counts(),
            "synced_at": store.last_upload(),
        }

    def resolve(name: str) -> dict[str, Any]:
        entry = summaries.resolve(store, name)
        if entry is None:
            raise ToolError(f"Unknown data type {name!r}. Call list_data_types for the available types.")
        return entry

    @mcp.tool(annotations=ToolAnnotations(title="Available data types", readOnlyHint=True, openWorldHint=False))
    def list_data_types() -> dict[str, Any]:
        """Every Apple Health type with uploaded data: key, unit, record count, first and last record, and freshness."""
        return {"time_zone": settings.timezone, "synced_at": store.last_upload(), "types": summaries.data_types(store)}

    @mcp.tool(annotations=ToolAnnotations(title="Daily summary", readOnlyHint=True, openWorldHint=False))
    def get_daily_summary(
        types: Annotated[
            list[str] | None,
            Field(
                description="Type keys or identifiers from list_data_types, e.g. ['step_count', 'resting_heart_rate']. "
                "Default: every type with daily statistics."
            ),
        ] = None,
        start_date: Annotated[
            date | None, Field(description="First local day, YYYY-MM-DD. Default: 6 days ago.")
        ] = None,
        end_date: Annotated[date | None, Field(description="Last local day, YYYY-MM-DD. Default: today.")] = None,
    ) -> dict[str, Any]:
        """HealthKit daily statistics per day: sum for cumulative types, average/min/max for others."""
        start, end = date_range(start_date, end_date, 7)
        entries = [resolve(name) for name in types] if types else None
        type_ids = [entry["id"] for entry in entries] if entries is not None else None
        units = {summaries.key(entry["id"]): entry["unit"] for entry in store.types().values() if entry["unit"]}
        days = summaries.daily_summary(store, start, end, type_ids)
        present_keys = {name for day in days for name in day["values"]}
        return {
            "time_zone": settings.timezone,
            "synced_at": store.last_upload(),
            "units": {name: unit for name, unit in sorted(units.items()) if name in present_keys},
            "days": days,
        }

    @mcp.tool(annotations=ToolAnnotations(title="Raw samples", readOnlyHint=True, openWorldHint=False))
    def get_samples(
        type: Annotated[str, Field(description="Type key or identifier from list_data_types, e.g. 'body_mass'.")],
        start_date: Annotated[
            date | None, Field(description="First local day, YYYY-MM-DD. Default: 6 days ago.")
        ] = None,
        end_date: Annotated[date | None, Field(description="Last local day, YYYY-MM-DD. Default: today.")] = None,
        limit: Annotated[int, Field(ge=1, le=5_000)] = 500,
    ) -> dict[str, Any]:
        """Raw readings for one type, newest first, in local time with their source app or device."""
        entry = resolve(type)
        if entry["kind"] in ("workout", "correlation"):
            raise ToolError("Use get_workouts for workouts and list_food_log for food entries.")
        start, end = date_range(start_date, end_date, 7)
        samples, truncated = summaries.raw_samples(store, entry, start, end, limit)
        return {
            "type": summaries.key(entry["id"]),
            "unit": entry["unit"],
            "samples": samples,
            "truncated": truncated,
            "synced_at": store.last_upload(),
        }

    @mcp.tool(annotations=ToolAnnotations(title="Sleep", readOnlyHint=True, openWorldHint=False))
    def get_sleep(
        start_date: Annotated[
            date | None, Field(description="First night (wake-up day), YYYY-MM-DD. Default: 6 days ago.")
        ] = None,
        end_date: Annotated[
            date | None, Field(description="Last night (wake-up day), YYYY-MM-DD. Default: today.")
        ] = None,
    ) -> dict[str, Any]:
        """One summary per night: bedtime, wake time, minutes asleep, in bed, awake and per sleep stage."""
        start, end = date_range(start_date, end_date, 7)
        return {"synced_at": store.last_upload(), "nights": summaries.sleep_nights(store, start, end)}

    @mcp.tool(annotations=ToolAnnotations(title="Workouts", readOnlyHint=True, openWorldHint=False))
    def get_workouts(
        start_date: Annotated[
            date | None, Field(description="First local day, YYYY-MM-DD. Default: 29 days ago.")
        ] = None,
        end_date: Annotated[date | None, Field(description="Last local day, YYYY-MM-DD. Default: today.")] = None,
        activity: Annotated[
            str | None, Field(description="Optional activity filter, e.g. 'running' or 'cycling'.")
        ] = None,
        limit: Annotated[int, Field(ge=1, le=500)] = 100,
    ) -> dict[str, Any]:
        """Workouts newest first, with duration, energy, distance and heart rate."""
        start, end = date_range(start_date, end_date, 30)
        return {"synced_at": store.last_upload(), "workouts": summaries.workouts(store, start, end, activity, limit)}

    return mcp
