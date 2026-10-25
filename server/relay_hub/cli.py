"""Command line: run the server and manage paired iPhones."""

from __future__ import annotations

import argparse
import secrets
import sys

from .config import ConfigError, Settings
from .store import Store


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="relay-hub", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("serve", help="Run the MCP endpoint and the Relay device API")
    pair = commands.add_parser("pair-device", help="Create a one-time code to pair the Relay app")
    pair.add_argument("--name", default="iPhone", help="Label for the paired device")
    devices = commands.add_parser("devices", help="List paired devices")
    devices.add_argument("--all", action="store_true", help="Include revoked devices")
    revoke = commands.add_parser("revoke-device", help="Revoke a paired device's token")
    revoke.add_argument("device_id")
    commands.add_parser("generate-token", help="Print a random token for RELAY_HUB_MCP_TOKEN")
    args = parser.parse_args(argv)

    if args.command == "generate-token":
        print(secrets.token_hex(32))
        return 0
    try:
        settings = Settings.from_env(require_mcp_token=args.command == "serve")
    except ConfigError as error:
        print(f"relay-hub: {error}", file=sys.stderr)
        return 2
    store = Store(settings.database)

    if args.command == "serve":
        import uvicorn

        from .app import create_app

        uvicorn.run(create_app(settings, store), host=settings.host, port=settings.port, server_header=False)
    elif args.command == "pair-device":
        code, expires = store.create_pairing_code(args.name, settings.pairing_minutes)
        print(f"Pairing code: {code[:4]}-{code[4:]}")
        print(f"Valid until {expires.astimezone(settings.zone):%Y-%m-%d %H:%M %Z}. It works once.")
    elif args.command == "devices":
        for device in store.list_devices(include_revoked=args.all):
            state = "revoked" if device["revoked_at"] else f"last seen {device['last_seen_at'] or 'never'}"
            print(f"{device['id']}  {device['name']}  ({state})")
    elif args.command == "revoke-device":
        if not store.revoke_device(args.device_id):
            print("relay-hub: no active device with that id", file=sys.stderr)
            return 1
        print("Revoked. That iPhone must pair again.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
