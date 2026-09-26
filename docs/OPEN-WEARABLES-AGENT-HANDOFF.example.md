# Query your Open Wearables server with an agent

Run the official [Open Wearables MCP adapter](https://github.com/the-momentum/open-wearables/tree/main/mcp) on a host that can reach your server over HTTPS. The adapter is a local stdio process that calls the remote REST API; the API URL is not an HTTP MCP endpoint.

For the adapter version matching Open Wearables 0.9.0:

```sh
git clone https://github.com/the-momentum/open-wearables.git open-wearables-agent
git -C open-wearables-agent checkout ff8527a52ad8a96cd1ebe8c19344295c934ae9dc
uv sync --frozen --project open-wearables-agent/mcp
```

Configure your MCP client with your own values, keeping credentials in secret configuration:

```json
{
  "mcpServers": {
    "open-wearables": {
      "command": "uv",
      "args": ["run", "--frozen", "--directory", "/ABSOLUTE/PATH/open-wearables-agent/mcp", "start"],
      "env": {
        "OPEN_WEARABLES_API_URL": "https://health.example.com",
        "OPEN_WEARABLES_API_KEY": "YOUR_API_KEY",
        "LOG_LEVEL": "WARNING"
      }
    }
  }
}
```

Keep the server's port if needed and do not append `/api/v1` to the base URL. For direct REST requests, send the `X-Open-Wearables-API-Key` header.

List tools, use `get_users` to identify your account, then request a small date range with `get_activity_summary`, `get_sleep_summary`, `get_workout_events` or `get_timeseries`. Use only your selected user ID. The adapter also exposes `get_menstrual_cycles` if the server has that data.

Preserve units and timezone, distinguish missing data from zero, and check freshness and pagination. This pinned adapter fetches one page for activity, sleep and workouts; time-series queries cap at 10,000 samples and expose truncation. Split large ranges and avoid double-counting overlapping sources.

General API keys in this server version are not restricted to read-only or a single user. The MCP tools expose queries, but the credential has broader access. Never commit it or write it into reports.
