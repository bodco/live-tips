// Pacenote telemetry endpoint (0.9.4, rules/usage.yaml > telemetry). Cloudflare Worker + D1 (binding DB).
// Accepts only what the app's usage log may hold: event names and small parameters, never free text.
// POST /v1/batch  {"schema":1,"install":"<uuid>","app_version","rules_version","ui_lang","routes":{...},
//                  "from":"YYYY-MM-DD","to":"YYYY-MM-DD","events":[{"d":"YYYY-MM-DD","e":"tip_rated","p":{...}}]}
// GET  /v1/health
const MAX_BYTES = 256 * 1024, MAX_EVENTS = 20000;
const NAME = /^[a-z][a-z0-9_]{0,39}$/, DAY = /^\d{4}-\d{2}-\d{2}$/, ID = /^[0-9a-f-]{8,40}$/i, SHORT = /^[\w.+:-]{0,40}$/;
const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

function cleanParams(p) {
  if (p == null) return {};
  if (typeof p !== "object" || Array.isArray(p)) return null;
  const out = {};
  for (const [k, v] of Object.entries(p)) {
    if (!NAME.test(k)) return null;
    if (typeof v === "string") { if (v.length > 80) return null; out[k] = v; }
    else if (typeof v === "number" && Number.isFinite(v)) out[k] = Math.round(v * 10) / 10;
    else if (typeof v === "boolean") out[k] = v;
    else return null;
  }
  return out;
}

export function validate(b) {
  if (!b || b.schema !== 1 || !ID.test(b.install || "")) return "bad header";
  for (const k of ["app_version", "rules_version", "ui_lang"]) if (b[k] != null && !SHORT.test(String(b[k]))) return "bad " + k;
  if (!DAY.test(b.from || "") || !DAY.test(b.to || "")) return "bad period";
  if (!Array.isArray(b.events) || b.events.length > MAX_EVENTS) return "bad events";
  const routes = {};
  for (const [k, v] of Object.entries(b.routes || {})) { if (!NAME.test(k) || !SHORT.test(String(v))) return "bad routes"; routes[k] = String(v); }
  const events = [];
  for (const x of b.events) {
    if (!x || !NAME.test(x.e || "") || !DAY.test(x.d || "")) return "bad event";
    const p = cleanParams(x.p);
    if (p === null) return "bad params";
    events.push({ d: x.d, e: x.e, p });
  }
  return { schema: 1, install: b.install, app_version: b.app_version || "", rules_version: b.rules_version || "",
           ui_lang: b.ui_lang || "", routes, from: b.from, to: b.to, events };
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === "/v1/health") return json({ ok: true });
    if (url.pathname !== "/v1/batch" || req.method !== "POST") return json({ error: "not found" }, 404);
    const text = await req.text();
    if (text.length > MAX_BYTES) return json({ error: "too large" }, 413);
    let body;
    try { body = JSON.parse(text); } catch { return json({ error: "bad json" }, 400); }
    const b = validate(body);
    if (typeof b === "string") return json({ error: b }, 400);
    const hour = new Date().toISOString().slice(0, 13) + ":00Z";
    const day = hour.slice(0, 10);
    const recent = await env.DB.prepare("SELECT COUNT(*) AS n FROM batches WHERE install = ? AND received_at >= ?")
      .bind(b.install, day).first();
    if (recent && recent.n >= 3) return json({ error: "enough for today" }, 429);
    const stmts = [env.DB.prepare("INSERT INTO batches (received_at, install, app_version, rules_version, ui_lang, period_from, period_to, events, payload) VALUES (?,?,?,?,?,?,?,?,?)")
      .bind(hour, b.install, b.app_version, b.rules_version, b.ui_lang, b.from, b.to, b.events.length, JSON.stringify(b))];
    const sums = new Map();
    for (const x of b.events) { const k = JSON.stringify([x.d, x.e, x.p]); sums.set(k, (sums.get(k) || 0) + 1); }
    for (const [k, n] of sums) {
      const [d, e, p] = JSON.parse(k);
      stmts.push(env.DB.prepare("INSERT INTO event_counts (day, event, params, app_version, n) VALUES (?,?,?,?,?) ON CONFLICT(day, event, params, app_version) DO UPDATE SET n = n + excluded.n")
        .bind(d, e, JSON.stringify(p), b.app_version, n));
    }
    for (let i = 0; i < stmts.length; i += 100) await env.DB.batch(stmts.slice(i, i + 100));
    return json({ ok: true, events: b.events.length });
  },
};
