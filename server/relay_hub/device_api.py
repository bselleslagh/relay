"""HTTP API for the Relay iPhone app: pairing, the write queue and nutrition uploads."""

from __future__ import annotations

import json
from collections.abc import Awaitable, Callable
from typing import Any

from fastmcp import FastMCP
from starlette.concurrency import run_in_threadpool
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.types import ASGIApp, Receive, Scope, Send

from . import nutrition
from .config import Settings
from .store import AckResult, ConflictError, NotFoundError, RateLimitedError, Store

MAX_BODY_BYTES = 4 * 1024 * 1024
SUPPORTED_KINDS = frozenset({"meal"})

Handler = Callable[[Request, dict[str, Any]], Awaitable[Response]]


def error(status: int, message: str, **headers: str) -> JSONResponse:
    return JSONResponse({"error": message}, status_code=status, headers=headers or None)


async def read_json(request: Request) -> Any:
    length = request.headers.get("content-length", "")
    if length.isdigit() and int(length) > MAX_BODY_BYTES:
        raise ValueError("Request body is too large")
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > MAX_BODY_BYTES:
            raise ValueError("Request body is too large")
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise ValueError("Request body must be JSON") from exc


class TailnetIdentity:
    """Optionally require a Tailscale Serve identity. Serve strips client-supplied copies of this header."""

    def __init__(self, app: ASGIApp, logins: frozenset[str]) -> None:
        self.app = app
        self.logins = logins

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and scope["path"] != "/healthz":
            headers = {key.decode().lower(): value.decode() for key, value in scope["headers"]}
            if headers.get("tailscale-user-login", "").lower() not in self.logins:
                await error(403, "This Relay Hub only accepts requests from allowed tailnet users.")(
                    scope, receive, send
                )
                return
        await self.app(scope, receive, send)


def register_device_routes(mcp: FastMCP, store: Store, settings: Settings) -> None:
    def authenticated(handler: Handler) -> Callable[[Request], Awaitable[Response]]:
        async def endpoint(request: Request) -> Response:
            scheme, _, token = request.headers.get("authorization", "").partition(" ")
            device = await run_in_threadpool(store.authenticate_device, token.strip()) if scheme == "Bearer" else None
            if device is None:
                return error(401, "Pair this iPhone again.", **{"WWW-Authenticate": "Bearer"})
            try:
                return await handler(request, device)
            except ValueError as exc:
                return error(400, str(exc))

        return endpoint

    @mcp.custom_route("/healthz", methods=["GET"], include_in_schema=False)
    async def healthz(request: Request) -> Response:
        return JSONResponse({"status": "ok"})

    @mcp.custom_route("/v1/pair", methods=["POST"])
    async def pair(request: Request) -> Response:
        try:
            body = await read_json(request)
        except ValueError as exc:
            return error(400, str(exc))
        code = body.get("code") if isinstance(body, dict) else None
        name = body.get("device_name") if isinstance(body, dict) else None
        if not isinstance(code, str) or (name is not None and not isinstance(name, str)):
            return error(400, "Send a pairing code.")
        try:
            device = await run_in_threadpool(store.redeem_pairing_code, code, name)
        except RateLimitedError as exc:
            return error(429, str(exc))
        except NotFoundError as exc:
            return error(403, str(exc))
        return JSONResponse(device | {"time_zone": settings.timezone}, status_code=201)

    async def device_status(request: Request, device: dict[str, Any]) -> Response:
        counts = await run_in_threadpool(store.queue_counts)
        return JSONResponse(
            {
                "device_id": device["id"],
                "name": device["name"],
                "time_zone": settings.timezone,
                "server_time": store.now().isoformat(timespec="seconds"),
                "actionable_writes": counts.get("pending", 0) + counts.get("delete_requested", 0),
            }
        )

    async def pull(request: Request, device: dict[str, Any]) -> Response:
        body = await read_json(request)
        if not isinstance(body, dict):
            raise ValueError("Expected a JSON object")
        kinds = body.get("kinds", [])
        if not isinstance(kinds, list) or not all(isinstance(kind, str) for kind in kinds):
            raise ValueError("kinds must be an array of strings")
        app_version = body.get("app_version")
        writes = await run_in_threadpool(
            lambda: store.pull_writes(
                device_id=device["id"],
                kinds=sorted(SUPPORTED_KINDS.intersection(kinds)),
                write_access=body.get("write_access"),
                app_version=app_version if isinstance(app_version, str) else None,
            )
        )
        return JSONResponse({"writes": writes})

    async def ack(request: Request, device: dict[str, Any]) -> Response:
        body = await read_json(request)
        if not isinstance(body, dict):
            raise ValueError("Expected a JSON object")
        try:
            result = AckResult(body.get("result"))
        except ValueError as exc:
            raise ValueError("result must be written, failed or deleted") from exc
        ids = body.get("healthkit_ids") or []
        message = body.get("error")
        if not isinstance(ids, list) or not all(isinstance(value, str) for value in ids) or len(ids) > 50:
            raise ValueError("healthkit_ids must be an array of at most 50 strings")
        if message is not None and not isinstance(message, str):
            raise ValueError("error must be a string")
        try:
            entry = await run_in_threadpool(
                lambda: store.ack_write(
                    write_id=request.path_params["write_id"],
                    device_id=device["id"],
                    result=result,
                    healthkit_ids=ids,
                    error=message[:500] if message else None,
                )
            )
        except NotFoundError as exc:
            return error(404, str(exc))
        except ConflictError as exc:
            return error(409, str(exc))
        return JSONResponse({"id": entry["id"], "status": entry["status"]})

    async def upload(request: Request, device: dict[str, Any]) -> Response:
        body = await read_json(request)
        try:
            batch_id, samples, meals, deleted, rejected = nutrition.parse_batch(body, settings.zone)
        except nutrition.InvalidBatchError as exc:
            return error(422, str(exc))
        accepted = await run_in_threadpool(
            lambda: store.ingest_nutrition(
                device_id=device["id"],
                batch_id=batch_id,
                samples=samples,
                meals=meals,
                deleted=deleted,
                rejected=len(rejected),
                complete=body.get("complete") is True,
            )
        )
        return JSONResponse({"batch_id": batch_id, "accepted": accepted, "rejected": rejected})

    mcp.custom_route("/v1/device", methods=["GET"])(authenticated(device_status))
    mcp.custom_route("/v1/writes/pull", methods=["POST"])(authenticated(pull))
    mcp.custom_route("/v1/writes/{write_id}/ack", methods=["POST"])(authenticated(ack))
    mcp.custom_route("/v1/nutrition", methods=["POST"])(authenticated(upload))
