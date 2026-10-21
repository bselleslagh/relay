# Relay Hub

Relay Hub is the self-hosted server for the Relay iPhone app. It stores the Apple Health data Relay uploads, serves it to your AI assistant over MCP, and queues meals the assistant logs so Relay can write them back to Apple Health. The assistant never touches your iPhone or Apple Health directly.

```text
AI assistant ──MCP──▶ Relay Hub ◀──upload health data / pull and acknowledge writes── Relay (iPhone) ◀──▶ Apple Health
                    (SQLite: samples, sleep, workouts, daily statistics, write queue)
```

- **Reading:** Relay uploads every HealthKit quantity type, sleep stages, mindful sessions, stand hours, heart rate notifications, workouts and food entries. It also sends HealthKit's own daily statistics, which merge overlapping sources such as iPhone and Apple Watch, so totals are not double-counted. Deletions in Apple Health are mirrored.
- **Writing:** the assistant calls `log_meal`. On its next sync, Relay saves the meal to Apple Health as one food entry, acknowledges it, and uploads it back with the rest of your nutrition.

## Run it

You need Docker with Compose on an always-on machine in your tailnet.

```sh
cd server
cp .env.example .env
openssl rand -hex 32          # paste as RELAY_HUB_MCP_TOKEN in .env
chmod 600 .env
docker compose up -d --build
curl http://127.0.0.1:8787/healthz   # {"status":"ok"}
```

Compose publishes the port on `127.0.0.1` only. Expose it to your tailnet over HTTPS with Tailscale Serve. Relay only connects over HTTPS, and Serve provides the `*.ts.net` certificate:

```sh
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8787
tailscale serve status
```

Your hub address is then `https://<machine>.<tailnet>.ts.net:8443`. Use Serve, not Funnel: the hub is meant for your tailnet only. HTTPS certificates must be enabled for the tailnet.

Data lives in the `relay-hub-data` volume (`/data/relay-hub.sqlite3`). Back it up like any SQLite file, for example `docker compose exec relay-hub python -c "import sqlite3; sqlite3.connect('/data/relay-hub.sqlite3').backup(sqlite3.connect('/data/backup.sqlite3'))"`.

### Settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `RELAY_HUB_MCP_TOKEN` or `RELAY_HUB_MCP_TOKEN_FILE` | required | Bearer token for MCP clients, at least 32 characters. |
| `RELAY_HUB_TIMEZONE` | `UTC` | IANA zone for "today" and for records without a time zone of their own. |
| `RELAY_HUB_TAILSCALE_LOGINS` | empty | Optional comma-separated allowlist of Tailscale Serve identities, e.g. `you@github`. When set, every request except `/healthz` must arrive through Serve from one of these users. Serve strips client-supplied copies of the header. Requests from the host itself or from tagged devices are then refused. |
| `RELAY_HUB_PAIRING_MINUTES` | `10` | Lifetime of a pairing code. |
| `RELAY_HUB_PUBLISH_PORT` | `8787` | Host port bound on `127.0.0.1` by `compose.yaml`. |

## Pair the iPhone

```sh
docker compose exec relay-hub relay-hub pair-device --name "My iPhone"
```

This prints a one-time code such as `K7QM-2XRD`. In Relay, tap **Connect your Relay Hub**, enter your hub address and the code, then choose Health access.

- The code works once and expires after 10 minutes. After 10 wrong codes within 15 minutes, every open code is revoked. Create a new one; it works immediately.
- The iPhone receives its own device token. Only its SHA-256 hash is stored on the hub. The MCP token never goes on the phone.
- List or revoke devices: `relay-hub devices`, `relay-hub revoke-device <id>`.

The first sync imports the last 30 days. Choose the last year or all history under **Settings → History** in Relay.

## Connect an AI assistant

The MCP endpoint is `https://<machine>.<tailnet>.ts.net:8443/mcp` (streamable HTTP, stateless, JSON responses). The machine running the assistant must be on your tailnet. An agent running on the hub host itself can use `http://127.0.0.1:8787/mcp`. Send the token as `Authorization: Bearer <RELAY_HUB_MCP_TOKEN>`. Keep it in your client's secret configuration, never in a repository.

Claude Code:

```sh
claude mcp add --transport http relay-hub https://<machine>.<tailnet>.ts.net:8443/mcp \
  --header "Authorization: Bearer $RELAY_HUB_MCP_TOKEN"
```

JSON configuration (Claude Code `.mcp.json` expands `${VAR}` from the environment):

```json
{
  "mcpServers": {
    "relay-hub": {
      "type": "http",
      "url": "https://<machine>.<tailnet>.ts.net:8443/mcp",
      "headers": { "Authorization": "Bearer ${RELAY_HUB_MCP_TOKEN}" }
    }
  }
}
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.relay-hub]
url = "https://<machine>.<tailnet>.ts.net:8443/mcp"
bearer_token_env_var = "RELAY_HUB_MCP_TOKEN"
```

### Reading tools

Types can be named by HealthKit identifier, by key (`step_count`, `heart_rate_variability_sdnn`) or by title. Date ranges are local days in `RELAY_HUB_TIMEZONE`, at most 92 days per call. Every response includes `synced_at`: when Relay last finished reading all of Apple Health.

| Tool | What it does |
| --- | --- |
| `list_data_types` | Every type with data: key, title, group, unit, aggregation, record count, first and last record, and how far daily statistics reach. |
| `get_daily_summary` | HealthKit daily statistics per day: `sum` for cumulative types (steps, active energy, distance…), `average`/`min`/`max` for the rest (heart rate, weight…). Default: every type over the last 7 days. |
| `get_samples` | Raw readings for one type, newest first, with local time and source. Up to 5,000 per call, with a `truncated` flag. |
| `get_sleep` | One summary per night, dated by wake-up day: bedtime, wake time, minutes asleep, in bed, awake and per stage, plus naps. Overlapping samples are never counted twice. When iPhone and Apple Watch overlap, the source with most recorded sleep is reported, the other is named, and time in bed can come from the other source. |
| `get_workouts` | Workouts newest first: activity, duration, active energy, distance and heart rate. Optional activity filter. |
| `get_nutrition_totals` | Daily totals per nutrient. `not_in_totals_yet` lists meals that are queued, or saved but not uploaded back yet; `removal_pending` lists cancelled meals still counted. |
| `list_food_log` | What was eaten, newest first: food entries with nutrients, source app and Relay entry IDs. |
| `get_sync_status` | When each paired iPhone last pulled and uploaded, its write permission, and queue counts. |

### Meal logging tools

| Tool | What it does |
| --- | --- |
| `log_meal` | Queue a meal: `energy_kcal`, `protein_g`, `carbohydrates_g`, `fat_g` (required); `consumed_at` (ISO 8601 with offset, default now, at most 30 days back), `name`, `meal_type` (breakfast, lunch, dinner, snack), `fiber_g`, `sugar_g`, `idempotency_key` (optional). Returns the entry and plausibility warnings, such as energy that does not match 4P+4C+9F. |
| `list_pending` | Entries Relay still has to act on: writes, plus removals after a cancellation. |
| `list_recent` | Recent entries with their Apple Health status, optionally filtered by status. |
| `cancel_entry` | Cancels an entry that never reached the phone. If Relay may already have saved it, Relay removes it from Apple Health on its next sync. |

Entry statuses: `pending` → `written`, or `failed` with an error. Relay reports `failed` only for problems that would recur, such as an invalid value; anything transient stays `pending` and is retried. `cancel_entry` produces `cancelled` before delivery. After delivery, and for failed entries, it produces `delete_requested` → `deleted`, so Relay verifies that nothing is left in Apple Health. A cancellation that races an in-flight write wins: Relay removes the samples on the next round. Removals are delivered before new writes.

Nutrient keys include their unit: `energy_kcal`, `protein_g`, `carbohydrates_g`, `fat_g`, `fiber_g`, `sugar_g` (these six are writable), plus `saturated_fat_g`, `sodium_mg`, `cholesterol_mg`, `caffeine_mg` and `water_ml`. Other dietary types (vitamins, minerals) are available through `get_daily_summary` and `get_samples`.

## How Relay writes to Apple Health

Each meal becomes one `HKCorrelationTypeIdentifierFood` entry with one quantity sample per nutrient, all at `consumed_at`. Every object carries:

- `RelayWriteID`: the queue entry ID, so samples trace back to the entry. It is also uploaded back as `write_id`.
- `HKMetadataKeySyncIdentifier` (`relay-hub.<id>` and `relay-hub.<id>.<nutrient>`) with `HKMetadataKeySyncVersion`, so a repeated save replaces instead of duplicating.
- `HKMetadataKeyFoodType` (name), `RelayMealType`, `HKMetadataKeyTimeZone` and `HKMetadataKeyWasUserEntered`.

Before saving, Relay looks for an existing entry with the same `RelayWriteID` and acknowledges that one instead. A crash between saving and acknowledging therefore never creates a duplicate. Relay requests write access only for the six writable types. If access is missing, entries stay `pending` and `get_sync_status` shows the reported access.

## Device API

Used by the Relay app. All routes except `/healthz` and `/v1/pair` need `Authorization: Bearer <device token>`.

| Route | Body | Response |
| --- | --- | --- |
| `GET /healthz` | | `{"status": "ok"}` |
| `POST /v1/pair` | `{"code", "device_name"}` | `201 {"device_id", "token", "name", "time_zone"}`; `403` invalid code; `429` too many wrong codes |
| `GET /v1/device` | | `{"device_id", "name", "time_zone", "server_time", "actionable_writes"}` |
| `POST /v1/types` | `{"types": [{"id", "kind", "title", "group", "unit", "aggregation"}]}` | `{"registered", "rejected"}` |
| `POST /v1/health` | `{"batch_id", "quantities", "categories", "workouts", "meals", "deleted", "daily", "complete"}`, at most 8 MiB | `{"batch_id", "accepted": {...}, "rejected": [{"collection", "index", "reason"}], "deleted_days": {type: [day]}}` |
| `POST /v1/writes/pull` | `{"kinds": ["meal"], "write_access": {"meal": "authorized"}, "app_version"}` | `{"writes": [{"id", "kind", "action": "write"\|"delete", "revision", "created_at", "data"}]}`, removals first, then oldest first, at most 200 |
| `POST /v1/writes/{id}/ack` | `{"result": "written"\|"failed"\|"deleted", "healthkit_ids", "error"}` | `{"id", "status"}`; `409` for an impossible transition |

Relay registers its types before uploading. A quantity must use its registered unit; anything else is rejected rather than stored with a wrong meaning.

Every uploaded record shares `uuid`, `start`, `end`, `time_zone`, `utc_offset` and `source` (`name`, `bundle_id`, `device`). On top of that:

| Collection | Extra fields |
| --- | --- |
| `quantities` | `type`, `value`, `unit`, `metadata`, and for food `food_name`, `meal_type` and `write_id`. |
| `categories` | `type`, `value`, `label` (for example `rem` or `stood`), `metadata`. |
| `workouts` | `activity`, `duration_s`, `energy_kcal`, `distance_m`, `avg_heart_rate`/`min_heart_rate`/`max_heart_rate`, `events`. |
| `meals` | HealthKit food correlations: `food_name`, `meal_type`, `write_id` and their `sample_uuids`. |
| `daily` | `{"type", "date", "time_zone", "sum" \| "average", "minimum", "maximum"}`. A day sent with no values removes that day's statistic. |

Validation and storage:

- Records are validated one by one, so one bad record cannot block a page. Over-long names and metadata are shortened rather than rejected.
- Uploads are upserts by HealthKit UUID, so resending is harmless. Deleted UUIDs are hidden from every view, and `deleted_days` tells the app which days' statistics to recompute.
- A batch the hub refuses outright (HTTP 400/413/422) is skipped by the app and shown as an issue, so it cannot block other data. The app keeps pages small enough that this should not happen: 500 records, 50 workouts, at most 200 events per workout.
- Relay sends `"complete": true` once every type has been read to the end. That sets the device's sync time.
- Local days use the record's IANA time zone, else its UTC offset, else `RELAY_HUB_TIMEZONE`.

## Known limitations

- **One iPhone.** Pair a single device. Pulls are not claimed per device, so two paired devices could both save the same meal.
- **Reinstalling or re-pairing** starts a new import. Records deleted from Apple Health while Relay was disconnected stay on the hub.
- **The Tailscale allowlist** only adds protection when nothing but Tailscale Serve can reach the port. Other processes on the host could send the header themselves. Tokens are still required either way.
- **Delivery latency.** iOS decides when Relay runs in the background. Meals logged while Relay is closed may wait until the next background opportunity or until you open the app.
- **Not uploaded:** clinical records, medications, ECG waveforms, audiograms, reproductive health and symptoms, state of mind, workout routes and high-frequency workout series.

## Development

```sh
cd server
uv sync
uv run pytest
uv run ruff check . && uv run ruff format --check .
RELAY_HUB_MCP_TOKEN=$(openssl rand -hex 32) RELAY_HUB_DATABASE=./dev.sqlite3 uv run relay-hub serve
```

The tests use temporary SQLite files, the in-memory FastMCP client and Starlette's test client. They never contact a network service. `RelayTests/HubTests.swift` checks that the app's nutrient catalog matches `relay_hub/nutrients.py`.
