# Validation

The existing test suite covers HTTPS-only server addresses, invitation validation, receipt decoding, retry behavior, token refresh, protected checkpoints, account isolation, history rescans, HealthKit unit conversions and invalid numeric values. UI tests cover onboarding, navigation and accessibility text sizes.

Test API responses are synthetic URLProtocol fixtures and are never sent to a real server. Test results, device logs, screenshots and health-data snapshots are intentionally excluded from this repository.

## Latest verification

The public configuration built successfully and passed all 33 tests on iPhone 17 Pro Simulator with Xcode 27: 29 unit/integration tests and four UI tests. Tests used the example bundle identifier and did not contact a real health server.

## Relay Hub

`server/tests` (51 pytest tests) covers pairing codes (single use, expiry, rate limit, hashed storage), token separation between MCP clients and devices, the optional tailnet identity allowlist, every write-queue transition including a cancellation that races a write, idempotency keys, nutrition validation per item, local-day totals, deletions, the food log and all MCP tools. `RelayTests/HubTests.swift` covers meal-to-HealthKit mapping and sync metadata, upload units and traceability, the client's pairing and token handling, checkpoint ordering, and catalog parity with the server.

An end-to-end run in the simulator used a local HTTPS hub and a throwaway certificate authority trusted only by that simulator. It verified the following: a meal queued through MCP was paired, permitted through the Health sheet and saved as one food correlation with five nutrients. It was acknowledged with its HealthKit UUIDs and uploaded back with its entry ID, name, meal type and +02:00 offset. Forcing the entry back to pending produced no duplicate. Cancelling it through MCP removed the correlation and its samples from HealthKit, and the deletions reached the hub's totals. A second run after review fixes confirmed the UTC offset upload and the caught-up sync time. Background delivery and Tailscale Serve still need checking on a physical iPhone.

## Public configuration

The app starts without a server address. Demo mode uses an example domain and synthetic counts. Signing settings are local overrides; background-task identifiers and the Keychain service follow the configured app bundle identifier.

## Device verification

Simulator tests do not establish reliable background delivery on a physical iPhone. Validate pairing, selected HealthKit permissions, upload processing, locked-device recovery, Wi-Fi-only behavior and network reconnection against your own server. HTTP 202 proves queue acceptance, not completed ingestion.
