"""ASGI application: MCP at /mcp, the Relay device API under /v1."""

from __future__ import annotations

from starlette.applications import Starlette
from starlette.middleware import Middleware

from .config import Settings
from .device_api import TailnetIdentity, register_device_routes
from .mcp_server import build_mcp
from .store import Store


def create_app(settings: Settings, store: Store | None = None) -> Starlette:
    store = store or Store(settings.database)
    mcp = build_mcp(store, settings)
    register_device_routes(mcp, store, settings)
    middleware = [Middleware(TailnetIdentity, logins=settings.tailscale_logins)] if settings.tailscale_logins else []
    # Stateless JSON responses: no long-lived SSE streams to keep alive through Tailscale Serve.
    return mcp.http_app(path="/mcp", middleware=middleware, stateless_http=True, json_response=True)
