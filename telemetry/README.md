# Pacenote telemetry endpoint

Cloudflare Worker `pacenote-telemetry` with the D1 database `pacenote-telemetry` (binding `DB`), account of the author.
URL: `https://pacenote-telemetry.neymet-bogdan.workers.dev` (`/v1/batch`, `/v1/health`). The app sends a batch at most
once a week and only when "Help improve Pacenote" is on (Settings > General > Privacy, off by default).

What is accepted is checked here again (`worker.js > validate`): event names and small parameters of the local usage
log (`rules/usage.yaml`), days instead of times, one random install id per Mac (made when sharing is turned on, forgotten when it is off) to tell users apart. No IP address or
user agent is stored. `schema.sql` creates the tables. Deploy: `npx wrangler deploy` with `wrangler.toml`, or the
dashboard. Look at the data in the D1 console: `SELECT event, params, SUM(n) FROM event_counts GROUP BY 1, 2`.
