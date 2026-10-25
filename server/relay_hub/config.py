"""Runtime settings, read from environment variables. Secrets have no defaults."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

MIN_TOKEN_LENGTH = 32


class ConfigError(ValueError):
    pass


def _secret(name: str) -> str | None:
    """Read NAME, or the file named by NAME_FILE (Docker secrets)."""
    value = os.environ.get(name)
    path = os.environ.get(f"{name}_FILE")
    if value and path:
        raise ConfigError(f"Set either {name} or {name}_FILE, not both")
    if path:
        value = Path(path).read_text()
    return value.strip() if value else None


def zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError) as error:
        raise ConfigError(f"Unknown time zone {name!r}") from error


@dataclass(frozen=True)
class Settings:
    database: Path
    mcp_token: str
    timezone: str = "UTC"
    host: str = "127.0.0.1"
    port: int = 8787
    # Optional allowlist of Tailscale Serve identities (Tailscale-User-Login). Empty disables the check.
    tailscale_logins: frozenset[str] = field(default_factory=frozenset)
    pairing_minutes: int = 10

    @property
    def zone(self) -> ZoneInfo:
        return zone(self.timezone)

    @classmethod
    def from_env(cls, *, require_mcp_token: bool = True) -> Settings:
        token = _secret("RELAY_HUB_MCP_TOKEN") or ""
        if require_mcp_token and len(token) < MIN_TOKEN_LENGTH:
            raise ConfigError(
                f"RELAY_HUB_MCP_TOKEN must be at least {MIN_TOKEN_LENGTH} characters. "
                "Generate one with: openssl rand -hex 32"
            )
        timezone = os.environ.get("RELAY_HUB_TIMEZONE") or "UTC"
        zone(timezone)
        logins = os.environ.get("RELAY_HUB_TAILSCALE_LOGINS", "")
        return cls(
            database=Path(os.environ.get("RELAY_HUB_DATABASE", "relay-hub.sqlite3")),
            mcp_token=token,
            timezone=timezone,
            host=os.environ.get("RELAY_HUB_HOST", "127.0.0.1"),
            port=int(os.environ.get("RELAY_HUB_PORT", "8787")),
            tailscale_logins=frozenset(login.strip().lower() for login in logins.split(",") if login.strip()),
            pairing_minutes=int(os.environ.get("RELAY_HUB_PAIRING_MINUTES", "10")),
        )
