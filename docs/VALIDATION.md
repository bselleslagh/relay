# Validation

The existing test suite covers HTTPS-only server addresses, invitation validation, receipt decoding, retry behavior, token refresh, protected checkpoints, account isolation, history rescans, HealthKit unit conversions and invalid numeric values. UI tests cover onboarding, navigation and accessibility text sizes.

Test API responses are synthetic URLProtocol fixtures and are never sent to a real server. Test results, device logs, screenshots and health-data snapshots are intentionally excluded from this repository.

## Latest verification

The public configuration built successfully and passed all 22 tests: 19 unit/integration tests and three UI tests on iPhone 17 Pro Simulator with iOS 26.5. Tests used the example bundle identifier and did not contact a real health server.

## Public configuration

The app starts without a server address. Demo mode uses an example domain and synthetic counts. Signing settings are local overrides; background-task identifiers and the Keychain service follow the configured app bundle identifier.

## Device verification

Simulator tests do not establish reliable background delivery on a physical iPhone. Validate pairing, selected HealthKit permissions, upload processing, locked-device recovery, Wi-Fi-only behavior and network reconnection against your own server. HTTP 202 proves queue acceptance, not completed ingestion.
