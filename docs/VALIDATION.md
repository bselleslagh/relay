# Validation

The iOS suite covers:

- HTTPS-only hub addresses, pairing-code validation and the Relay Hub client: health check, pairing, token handling, type registration, uploads, the write queue, revocation and refusal messages.
- Protected checkpoints isolated by hub and device, removal of earlier-version checkpoints, and tolerant decoding.
- History windows and rescans, the anchor and statistics-day commit order, and deletion-only batches.
- The generated catalog (units, aggregation styles, percentages), type registration, quantity, category and dietary payloads, invalid numeric values, the meal-to-HealthKit mapping and error classification.

UI tests cover onboarding, navigation, meal logging and accessibility text sizes.

Test API responses are synthetic URLProtocol fixtures and are never sent to a real server. Test results, device logs and health-data snapshots are intentionally excluded from this repository.

## Latest verification

The public configuration built without warnings and passed all 35 iOS tests on iPhone 17 Pro Simulator with Xcode 27: 31 unit/integration tests and four UI tests. Tests used the example bundle identifier and did not contact a real server.

`server/tests` passed all 62 pytest tests. They cover:

- pairing codes (single use, expiry, revocation after repeated guesses, hashed storage) and token separation between MCP clients and devices;
- the optional tailnet identity allowlist and type registration;
- validation of every upload collection, including registered units, local days from time zones or offsets, and trimmed metadata;
- deletions across record kinds (with the days they affect, so the app refreshes those statistics) and daily statistics;
- data types, raw samples, sleep sessions with naps, overlapping sources and union-based minutes, workouts, nutrition totals and the food log;
- migration of a preview database that keeps pairing and the write queue;
- every write-queue transition, including a cancellation that races a write, and all MCP tools.

## End-to-end runs

Simulator runs used a local HTTPS Relay Hub and a throwaway certificate authority trusted only by that simulator. Temporary seeding code, which is not in the repository, wrote steps, heart rate, weight, sleep stages and a workout to the simulator's Health store.

Relay paired, requested access in one Health sheet, registered 128 types and uploaded everything:

- Through MCP, `get_daily_summary` returned HealthKit's step totals (7,500 and 2,000), heart rate average/min/max and active energy.
- `get_sleep` returned the night dated by wake-up day, with stages. `get_workouts` returned a 45-minute run with 450 kcal and 7.5 km. `get_samples` returned the weight.
- Deleting a step sample in Apple Health removed it on the hub, and the day's total dropped to 1,200 after the next sync.
- A meal logged with `log_meal` was saved to Apple Health as one food entry with five nutrients and acknowledged with its HealthKit IDs. It came back as a food entry whose samples carry the queue entry ID.
- Earlier runs showed that re-delivery creates no duplicate, and that cancelling a written meal removes it from Apple Health and from the hub's totals.

A final run after the second review repeated pairing, the permission sheet and a full sync against a fresh hub with the final code. Blood pressure types reported "authorization not determined" on the iOS 27 simulator even after allowing all types. Relay now lists such types as not shared instead of treating them as sync failures.

## Public configuration

The app starts without a server address. Demo mode uses an example domain and synthetic counts. Signing settings are local overrides; background-task identifiers and the Keychain service follow the configured app bundle identifier.

## Device verification

Simulator tests do not establish reliable background delivery on a physical iPhone. Validate pairing, HealthKit permissions, the first import, locked-device recovery, Wi-Fi-only behavior and network reconnection against your own Relay Hub behind Tailscale Serve.
