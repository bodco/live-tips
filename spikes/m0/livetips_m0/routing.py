"""AI routes (Pacenote 0.8.2): which way each job reaches Claude, and the automatic switch.

Available routes:
- "api": the Claude API key (Settings > AI), billed per token, the fastest.
- "code": the PM's Claude account through Claude Code (`claude -p`), from the plan's limits, no key.
- "local": Ollama on this Mac for preparation and after-call jobs.
- "openai": OpenAI API key, GPT-5.4 mini for tips and after-call jobs; no automatic provider switch.
- "agy": 0.9.3 (owner): the Gemini account through Antigravity CLI, for the preparation and after the call only
  (20-30 s a request). Also a plan B for those jobs when no Gemini key is set.
- "gemini": Gemini API key (paid tier), a Gemini model per job. 0.9.3 (owner, 04.11): it is also the opt-in plan B
  (LT_GEMINI_FALLBACK=1): when the chosen way is out (no credit, plan limit, bad key) the job goes to Gemini.

Three jobs: "prep" (the app runs Claude Code itself; here only the route state is shared), "tips" (during the
call) and "after" (summary, follow-up email, call memory, rehearsal, the judge).

Auto-switch (on by default): when the chosen route is out (API: no credit or a bad key, or the app's own
monthly limit; Claude Code: the plan limit, signed out, not installed), the work goes to the other route. The
out route is checked again before the next job (during a call: in the background, every 2 minutes), and the
job goes back to it as soon as it answers. The app, the tips engine and the one-off jobs share the state in one
small file (state/ai-routes.json), so Settings > AI can show it.

0.10.0 (AI chain, owner 12.11; rules/ai.yaml > chain): with a chain from the app (LT_AI_CHAIN, sidecar ai.chain) every
job, whatever AI it chose, goes down one chain on an outage: the chosen AI, then the connected AIs in the PM's order,
the model on this Mac last (never for tips, nor agy). The out AI is marked until its reset time when the error names
one (else checked again every 15 minutes) and every switch is a line in state/ai-switches.jsonl. Without a chain (an
older app) the rules above apply unchanged.
"""
import argparse
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Callable, Dict, Optional

from .providers import AnthropicProvider, Completion, Provider, gist_closed, user_text

ROUTES = ("api", "code", "local", "openai", "codex", "gemini", "agy")   # 0.8.5: "local" = a model on this Mac (rules/ai.yaml)
JOBS = ("prep", "tips", "after")
# 0.10.0 (AI chain, owner 12.11): an AI out without a known reset time is checked again every 15 minutes
PROBE_EVERY_S = 900
# 0.10.0 (AI chain, owner 12.11): one fallback chain for every job (LiveTipsCore/AIChain.swift, rules/ai.yaml > chain):
# the job's AI first, then the connected AIs in the PM's order; tips never on the model on this Mac or the Gemini
# account; the model on this Mac always the last step.
CHAIN_DEFAULT = ("code", "codex", "api", "openai", "gemini", "agy", "local")
PING_MODEL = {"codex": "codex/default", "openai": "gpt-6-luna", "gemini": "gemini-3.5-flash-lite", "agy": "gemini-3.8-flash-low", "api": "claude-haiku-5-5", "code": "haiku", "local": os.environ.get("LT_LOCAL_MODEL", "gemma4:26b")}


def other(route: str) -> str:
    return route if route in ("openai", "codex", "gemini", "agy") else "code" if route == "api" else "api"


def spend_ledger(job: str, route: str, c, state_path) -> None:
    """0.8.5 (owner: what each stage costs through the API): one line per model request in
    <state>/spend-ledger.jsonl; the app adds the preparation (job "prep"). Never the prompt or the reply."""
    try:
        from .cost import cost_usd
        g = lambda k: int(getattr(c, k, 0) or 0)  # noqa: E731
        usd = cost_usd(c.model, g("input_tokens"), g("cache_write_5m"), g("cache_write_1h"), g("cache_read"), g("output_tokens")) \
            if route in ("api", "openai", "gemini") else (0.0 if route == "local" else getattr(c, "equiv_usd", None))
        row = {"at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "job": os.environ.get("LT_AI_STAGE") or job, "route": route,
               "model": c.model, "input": g("input_tokens"), "output": g("output_tokens"), "cache_read": g("cache_read"),
               "cache_write": g("cache_write_5m") + g("cache_write_1h"), "usd": round(usd, 6) if usd is not None else None,
               "error": bool(getattr(c, "error", None))}
        p = Path(state_path).with_name("spend-ledger.jsonl")
        with open(p, "a", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")
    except Exception:  # noqa: BLE001  the ledger never breaks a request
        pass


def default_state_path() -> str:
    return os.environ.get("LT_AI_STATE") or os.path.expanduser(
        "~/Library/Application Support/LiveTips/state/ai-routes.json")


def find_claude_cli(hint: Optional[str] = None) -> Optional[str]:
    """The `claude` command line tool (Claude Code), where its installers put it."""
    home = os.path.expanduser("~")
    for p in [hint, os.environ.get("LT_CLAUDE_CLI", ""), home + "/.local/bin/claude", home + "/.claude/local/claude",
              "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]:
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which("claude")


def cc_model(model: str) -> str:
    """Claude Code takes the family alias (always the newest of the family)."""
    m = (model or "").lower()
    for fam in ("haiku", "sonnet", "opus"):
        if fam in m:
            return fam
    return model or "sonnet"


def chain_allowed(route: str, job: str) -> bool:
    """0.10.0 (AI chain): live tips never run on the model on this Mac (19-59 s) or the Gemini account (20-30 s)."""
    return not (job == "tips" and route in ("local", "agy"))


def chain_order(job: str, chosen: str, chain, connected, auto: bool = True) -> list:
    """The order a job tries its AIs (same as AIChain.order in Swift): the chosen one first, then the connected AIs
    of `chain` (the enabled routes in the PM's order), the model on this Mac last."""
    out = [chosen]
    if not auto:
        return out
    local = False
    seen = set(out)
    for r in chain or ():
        if r in seen or r not in ROUTES or r not in connected or not chain_allowed(r, job):
            continue
        seen.add(r)
        if r == "local":
            local = True
        else:
            out.append(r)
    if local:
        out.append("local")
    return out


def chain_from(value) -> Optional[list]:
    """LT_AI_CHAIN (a JSON list) or sidecar-config ai.chain; None when the app did not send one (older app)."""
    if value is None or value == "":
        return None
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return None
    return [str(r) for r in value if str(r) in ROUTES] if isinstance(value, (list, tuple)) else None


_UNIT_S = {"d": 86400, "h": 3600, "m": 60}


def reset_time(text: Optional[str], now: Optional[float] = None) -> Optional[float]:
    """0.10.0 (AI chain): the reset time an error names (same rules as AIOut.resetTime in Swift): "try again at
    12:48 PM", "resets 9am", "resets at 15:30", "try again in 2 hours 5 minutes", "resets_at": 1793731185. The next
    such local clock time after now; None when there is none."""
    import re
    import datetime as _dt
    t = (text or "").lower()
    if not t:
        return None
    now = time.time() if now is None else now
    m = re.search(r'resets?_?at"?\s*[:=]\s*(\d{9,11})', t) or re.search(r"limit reached\|(\d{9,11})", t)
    if m:
        return float(m.group(1))
    m = re.search(r"(?:try again|resets?|available again)\s+in\s+((?:\d+\s*(?:days?|d|hours?|hrs?|h|minutes?|mins?|m)\b[\s,]*(?:and\s+)?)+)", t)
    if m:
        secs = sum(int(n) * _UNIT_S[u[0]] for n, u in re.findall(r"(\d+)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m)\b", m.group(1)))
        if secs:
            return now + secs
    m = re.search(r"(?:try again at|resets? at|resets|reset|available again at)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?", t)
    if not m or (m.group(2) is None and m.group(3) is None):
        return None
    h, mi, ap = int(m.group(1)), int(m.group(2) or 0), m.group(3) or ""
    if ap.startswith("p") and h < 12:
        h += 12
    if ap.startswith("a") and h == 12:
        h = 0
    if h > 23 or mi > 59:
        return None
    base = _dt.datetime.fromtimestamp(now)
    d = base.replace(hour=h, minute=mi, second=0, microsecond=0)
    if d.timestamp() <= now:
        d = d + _dt.timedelta(days=1)
    return d.timestamp()


def account_usage_claude(ev: dict, now: Optional[float] = None) -> Optional[dict]:
    """0.10.0 (AI chain): a Claude Code stream-json rate_limit_event as {"at", "limited", "windows": [{"name",
    "used_percent", "resets_at"}]} (same as AIAccountUsage.fromClaude in Swift)."""
    if not isinstance(ev, dict) or ev.get("type") != "rate_limit_event":
        return None
    info = ev.get("rate_limit_info") or {}
    ws = []
    uw = info.get("unifiedWindows")
    if isinstance(uw, dict):
        for k in ("five_hour", "seven_day"):
            w = uw.get(k) or {}
            if isinstance(w, dict) and w.get("utilization") is not None:
                ws.append({"name": k, "used_percent": round(float(w["utilization"]) * 100, 1), "resets_at": w.get("resetsAt")})
    elif info.get("utilization") is not None:
        ws.append({"name": info.get("rateLimitType") or "five_hour", "used_percent": round(float(info["utilization"]) * 100, 1),
                   "resets_at": info.get("resetsAt")})
    if not ws:
        return None
    out = {"at": time.time() if now is None else now, "limited": info.get("status") == "rejected", "windows": ws}
    if out["limited"]:                     # 0.10.0 (status fix): the limit holds until the account's reset time
        resets = [w["resets_at"] for w in ws if w.get("resets_at")]
        until = info.get("resetsAt") or (max(resets) if resets else None)
        if until:
            out["until"] = until
    return out


def account_usage_codex(rl: dict, now: Optional[float] = None) -> Optional[dict]:
    """0.10.0 (AI chain): a Codex rate_limits object (primary / secondary: used_percent, window_minutes, resets_at)."""
    if not isinstance(rl, dict):
        return None
    ws = []
    for k in ("primary", "secondary"):
        w = rl.get(k)
        if isinstance(w, dict) and w.get("used_percent") is not None:
            mins = int(w.get("window_minutes") or 0)
            ws.append({"name": "five_hour" if mins == 300 else "seven_day" if mins == 10080 else "%dm" % mins,
                       "used_percent": float(w["used_percent"]), "resets_at": w.get("resets_at")})
    if not ws:
        return None
    out = {"at": time.time() if now is None else now, "limited": False, "windows": ws}
    reached = rl.get("rate_limit_reached_type")
    full = [w for w in ws if w["used_percent"] >= 100]
    if reached is None and not full:
        return out
    # 0.10.0 (status fix, same as AIAccountUsage.fromCodex): limit reached until the window at 100% resets, else the
    # one the account names (primary = 5 hours, secondary = the week), else the later reset
    r = str(reached or "").lower()
    named = [w for w in ws if (w["name"] == "five_hour" and "primary" in r) or (w["name"] == "seven_day" and "secondary" in r)]
    pick = [w["resets_at"] for w in (full or named or ws) if w.get("resets_at")]
    out["limited"] = True
    if pick:
        out["until"] = max(pick)
    return out


def accounts_path(state_path=None) -> Path:
    return Path(state_path or default_state_path()).with_name("ai-accounts.json")


def note_account_usage(route: str, usage: Optional[dict], state_path=None) -> None:
    """The latest usage an account reported, per account, in state/ai-accounts.json (read by the app's AI status).
    Numbers only: never a key, a token or any text of the request."""
    if not usage:
        return
    p = accounts_path(state_path)
    try:
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
            d = d if isinstance(d, dict) else {}
        except Exception:  # noqa: BLE001
            d = {}
        d[route] = usage
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp{}".format(os.getpid()))
        tmp.write_text(json.dumps(d), encoding="utf-8")
        os.replace(tmp, p)
    except Exception:  # noqa: BLE001  a hint for the UI, never a reason to fail a request
        pass


def note_switch(job: str, from_route: str, to_route: str, reason: str, state_path=None) -> None:
    """0.10.0 (AI chain): never silent. One line per switch in state/ai-switches.jsonl; the app shows the recent ones
    (Home, the tips window) and notifies the PM about a job that switched outside a call."""
    try:
        p = Path(state_path or default_state_path()).with_name("ai-switches.jsonl")
        with open(p, "a", encoding="utf-8") as f:
            f.write(json.dumps({"at": time.time(), "job": os.environ.get("LT_AI_STAGE") or job, "from": from_route,
                                "to": to_route, "reason": reason}) + "\n")
    except Exception:  # noqa: BLE001
        pass


# Why a route is out, by the words of its error. (route or None for both, reason, words); first match wins.
OUT_REASONS = [
    ("codex", "auth", ("not logged in",)),
    ("codex", "limit", ("usage limit", "hit your limit", "purchase more credits")),
    ("openai", "auth", ("http 401", "http 403")),
    ("openai", "credit", ("insufficient_quota", "billing_hard_limit", "exceeded your current quota")),
    # 0.9.3: Gemini: 401 a bad key, 403 no permission, 402 prepay credit gone, 429 quota_exceeded the day's quota,
    # 400 failed_precondition billing off. A plain 429 (rate_limit_exceeded) is a passing error: not listed.
    ("agy", "auth", ("not signed in",)),
    ("agy", "limit", ("usage limit",)),
    ("gemini", "auth", ("http 401", "http 403")),
    ("gemini", "credit", ("http 402", "quota_exceeded", "failed_precondition")),
    (None, "no_key", ("no api key",)),
    (None, "missing", ("noroute", "not installed")),
    (None, "credit", ("credit balance", "billing", "insufficient", "out of credits")),
    ("api", "auth", ("authentication", "x-api-key", "permissiondenied")),
    ("code", "limit", ("limit",)),            # "usage limit reached", "5-hour limit", "weekly limit"
    ("code", "auth", ("login", "logged in", "oauth", "authentication", "invalid api key")),
]


def out_reason(route: str, err: Optional[str]) -> Optional[str]:
    """Why a route is out (worth switching), or None for a passing error (timeout, overload: hedging helps)."""
    e = (err or "").lower()
    for only, reason, words in OUT_REASONS:
        if e and only in (None, route) and any(w in e for w in words):
            return reason
    return None


class RouteState:
    """The shared state file: {"api": {"down": bool, "reason", "since", "checked"}, "code": {...}}."""

    def __init__(self, path: Optional[str] = None):
        self.path = Path(path or default_state_path())
        self.lock = threading.Lock()

    def read(self) -> dict:
        try:
            d = json.loads(self.path.read_text(encoding="utf-8"))
            return d if isinstance(d, dict) else {}
        except Exception:  # noqa: BLE001  missing or half-written: nothing is down
            return {}

    def _write(self, d: dict) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp{}".format(os.getpid()))
            tmp.write_text(json.dumps(d), encoding="utf-8")
            os.replace(tmp, self.path)
        except Exception:  # noqa: BLE001  the state is a hint, never a reason to fail a job
            pass

    def is_down(self, route: str) -> bool:
        return bool((self.read().get(route) or {}).get("down"))

    def due(self, route: str, every_s: float) -> bool:
        """0.10.0 (AI chain): an AI out until a known reset time is due at that time; otherwise `every_s` after the
        last check."""
        cur = self.read().get(route) or {}
        if cur.get("down") and cur.get("until"):
            return time.time() >= float(cur["until"])
        checked = cur.get("checked")
        return checked is None or time.time() - float(checked) >= every_s

    def mark_down(self, route: str, reason: str, until: Optional[float] = None) -> None:
        with self.lock:
            d = self.read()
            cur = d.get(route) or {}
            now = time.time()
            d[route] = {"down": True, "reason": reason, "since": cur.get("since") if cur.get("down") else now,
                        "checked": now}
            if until and until > now:
                d[route]["until"] = float(until)        # 0.10.0 (AI chain): out until the limit resets
            self._write(d)

    def mark_up(self, route: str) -> None:
        with self.lock:
            d = self.read()
            if (d.get(route) or {}).get("down"):
                d[route] = {"down": False, "back_at": time.time()}
                self._write(d)

    def touch(self, route: str) -> None:
        with self.lock:
            d = self.read()
            cur = d.get(route) or {}
            cur["checked"] = time.time()
            d[route] = cur
            self._write(d)


HIDDEN_ENV = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API", "ANTHROPIC_CUSTOM_HEADERS", "OPENAI_API_KEY",
              "GEMINI_API_KEY", "GOOGLE_API_KEY")


def cc_args(cli: str, alias: str, system_file: str) -> list:
    """`claude -p` with no tools, no settings, no MCP servers and no saved session, streaming its events."""
    return [cli, "-p", "--model", alias, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--system-prompt-file", system_file, "--tools", "", "--setting-sources", "", "--strict-mcp-config",
            "--no-session-persistence"]


def cc_env(environ) -> dict:
    """The child's environment without any API key: Claude Code then uses the PM's own sign-in."""
    return {k: v for k, v in environ.items() if k not in HIDDEN_ENV}


def text_delta(ev: dict) -> Optional[str]:
    """The text a stream event adds to the answer, or None for any other event."""
    e = ev.get("event") or {} if ev.get("type") == "stream_event" else {}
    d = e.get("delta") or {} if e.get("type") == "content_block_delta" else {}
    return d.get("text", "") if d.get("type") == "text_delta" else None


def cc_stream_result(stdout: str):
    """0.10.0 (status fix): the output of `claude -p --output-format stream-json --verbose` (or the older single
    `--output-format json` object): (the final result event or {}, the account's rate_limit_event as usage or None).
    Every Claude Code run of the app (prep checker, the call's lookup) passes its account report through this."""
    result, usage = {}, None
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        if ev.get("type") == "rate_limit_event":
            usage = account_usage_claude(ev) or usage
        elif ev.get("type") == "result" or "result" in ev and "type" not in ev:
            result = ev
    if not result:
        try:
            whole = json.loads(stdout or "{}")
            result = whole if isinstance(whole, dict) else {}
        except ValueError:
            result = {}
    return result, usage


def cc_event(c: Completion, line: str, on_text=None) -> Optional[dict]:
    """Applies one stream-json line to the completion; returns the final "result" event when this is it."""
    try:
        ev = json.loads(line)
    except ValueError:
        return None
    if ev.get("type") == "result":
        return ev
    if ev.get("type") == "rate_limit_event":           # 0.10.0 (AI chain): the account's own limit report
        c.account_usage = account_usage_claude(ev) or c.account_usage
        return None
    piece = text_delta(ev)
    if piece is None:
        return None
    if c.t_first_token is None:
        c.t_first_token = time.monotonic()
    c.text += piece
    if c.t_gist is None and gist_closed(c.text):
        c.t_gist = time.monotonic()
    if on_text:
        on_text(c.text)
    return None


def cc_finish(c: Completion, result: Optional[dict], returncode: int, stderr: str) -> Completion:
    """Usage and errors from the final event (or from the exit code when there was none)."""
    c.t_done = time.monotonic()
    if result:
        _cc_usage(c, result)
        c.error = _cc_result_error(result)
    elif returncode != 0 or not c.text:
        c.error = "ClaudeCode: exit {} {}".format(returncode, (stderr or "").strip()[-200:])
    return c


def _cc_usage(c: Completion, result: dict) -> None:
    u = result.get("usage") or {}
    c.input_tokens = u.get("input_tokens") or 0
    c.cache_read = u.get("cache_read_input_tokens") or 0
    c.output_tokens = u.get("output_tokens") or 0
    c.equiv_usd = result.get("total_cost_usd")
    if not c.text and isinstance(result.get("result"), str):
        c.text = result["result"]


def _cc_result_error(result: dict) -> Optional[str]:
    if result.get("is_error") or result.get("subtype") not in (None, "success"):
        return "ClaudeCode: " + str(result.get("result") or result.get("subtype"))[:200]
    return None


class ClaudeCodeProvider(Provider):
    """One completion through Claude Code (`claude -p`) on the PM's Claude account.

    No tools, no settings, no MCP servers, no saved session: a plain answer to one prompt. The system prompt
    goes through a file, the request through stdin. Slower than the API (a few seconds to start, no control of
    prompt caching or of the answer length), so it is the second choice for live tips. The model name says
    "claude-code/<alias>": no API price, so nothing goes into the API spending ledger.
    """
    name = "claude_code"

    def __init__(self, cli: str, timeout: float = 90.0):
        self.cli = cli
        self.timeout = timeout
        self.cwd = tempfile.mkdtemp(prefix="pacenote-cc-")     # an empty folder: no project files, no CLAUDE.md

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        alias = cc_model(model)
        c = Completion(model="claude-code/" + alias, t_start=time.monotonic())
        c.route = "code"
        fd, sp = tempfile.mkstemp(prefix="sys-", suffix=".txt", dir=self.cwd)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("\n\n".join(b["text"] for b in system) or "Answer briefly.")
            return self._run(c, cc_args(self.cli, alias, sp), user_text(user), on_text)
        except Exception as e:  # noqa: BLE001  a missing tool or a broken pipe is an error of this request
            c.t_done = time.monotonic()
            c.error = "ClaudeCode: {}: {}".format(type(e).__name__, str(e)[:200])
            return c
        finally:
            os.remove(sp)

    def _run(self, c: Completion, args: list, prompt: str, on_text) -> Completion:
        p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, cwd=self.cwd, env=cc_env(os.environ))
        timer = threading.Timer(self.timeout, p.kill)
        timer.start()
        try:
            p.stdin.write(prompt)
            p.stdin.close()
            result = None
            for line in p.stdout:
                result = cc_event(c, line, on_text) or result
            err = p.stderr.read()
            p.wait()
        finally:
            timer.cancel()
        return cc_finish(c, result, p.returncode, err)


class RoutedProvider(Provider):
    """One job's provider: the chosen route, and with auto-switch the other route when the chosen one is out."""
    name = "routed"

    def __init__(self, job: str, preferred: str, legs: Dict[str, Optional[Provider]], auto: bool = True,
                 state: Optional[RouteState] = None, probe_every: float = PROBE_EVERY_S, background: bool = False,
                 api_blocked: Optional[Callable[[], bool]] = None, gemini_fallback: bool = False, caps=None,
                 chain: Optional[list] = None):
        self.job = job
        # 0.10.0 (AI chain, owner 12.11): the enabled AIs in the PM's order (LT_AI_CHAIN, sidecar ai.chain). None: an
        # older app, the switching rules of 0.9.x below. With a chain every chosen AI may switch, on its own outage.
        self.chain = list(chain) if chain is not None else None
        self.chain_auto = bool(auto)
        self.caps = caps          # 0.9.6 (owner): cost.ProviderCaps, a monthly limit per provider; None = no limits
        self.preferred = preferred if preferred in ROUTES else "api"
        self.legs = dict(legs)
        self.gemini_fb = gemini_fallback
        self.auto = auto and self.preferred not in ("openai", "codex", "gemini", "agy")
        self.state = state or RouteState()
        self.probe_every = probe_every
        self.background = background
        self.api_blocked = api_blocked
        self.last_route: Optional[str] = None
        self._probing = set()
        self._plock = threading.Lock()

    def wrap(self, route: str, fn: Callable[[Provider], Provider]) -> None:
        if self.legs.get(route) is not None:
            self.legs[route] = fn(self.legs[route])

    def describe(self, model: str) -> dict:
        """The chosen route and the model it runs for `model` (auto-switch may change the route on an outage:
        run.json keeps what each request really used next to this)."""
        r = self.preferred
        leg = self.legs.get(r)
        if r in ("openai", "gemini", "agy"):
            m = leg.describe(model)["model"] if leg is not None else None
        elif r == "code":
            m = cc_model(model)
        elif r == "local":
            m = os.environ.get("LT_LOCAL_MODEL", "gemma4:26b")
        elif r == "codex":
            m = "codex/default"
        else:
            m = model
        return {"route": r, "model": m, "available": leg is not None}

    def capped(self, route: str) -> bool:
        """0.9.6: the provider of this API way reached its monthly limit (Settings > AI > Spending limits)."""
        return bool(self.caps is not None and self.caps.capped_route(route))

    def usable(self, route: str) -> bool:
        if self.legs.get(route) is None or self.capped(route):
            return False
        return not (route in ("api", "openai", "gemini") and self.api_blocked and self.api_blocked())

    def can_run_without_api(self) -> bool:
        """True when the app's own API limit does not stop this job (it goes, or may go, through Claude Code)."""
        if self.preferred in ("codex", "agy"):
            return self.legs.get(self.preferred) is not None
        if self.preferred in ("openai", "gemini") or self.legs.get("code") is None:
            return False
        return self.preferred == "code" or self.auto

    def order(self) -> list:
        """0.10.0 (AI chain): the AIs this job tries, in order (the chosen one first)."""
        connected = {r for r, leg in self.legs.items() if leg is not None}
        return chain_order("tips" if self.background else self.job, self.preferred, self.chain or (), connected,
                           self.chain_auto)

    def _try_now(self, route: str) -> bool:
        """An AI of the chain worth a request now: usable, and not out (or out with its check due)."""
        return self.usable(route) and (not self.state.is_down(route) or self.state.due(route, self.probe_every))

    def _pick_chain(self) -> str:
        order = self.order()
        p = order[0]
        if self._ready(p) or self._recheck(p):
            return p
        for r in order[1:]:
            if self._ready(r):
                return r
        for r in order[1:]:
            if self._try_now(r):
                return r
        return p if self.usable(p) else next((r for r in order if self.usable(r)), p)

    def _complete_chain(self, kw) -> Completion:
        """0.10.0 (AI chain): the job's AI, and on an outage (a limit, no credit, a bad key, signed out; never a plain
        rate limit or a timeout) the next AI of the chain, until one answers. The out AI is marked until its reset
        time when the error names one (else checked again in 15 minutes); every switch is written down."""
        order = self.order()
        tried = []
        r = self._pick_chain()
        while True:
            c = self._run(r, **kw)
            tried.append(r)
            reason = out_reason(r, c.error)
            if not reason:
                if not c.error:
                    self.state.mark_up(r)
                    if r != self.preferred:
                        c.switched_from = self.preferred
                return c
            self.state.mark_down(r, reason, c.reset_at or reset_time(c.error))
            nxt = next((x for x in order if x not in tried and self._try_now(x)), None)
            if nxt is None:
                return c
            note_switch(self.job, r, nxt, reason, self.state.path)
            r = nxt

    def pick(self) -> str:
        """The chosen route while it answers; with auto-switch the other one while it is out."""
        if self.chain is not None:
            return self._pick_chain()
        p, o = self.preferred, other(self.preferred)
        if self.gemini_fallback():
            # 0.9.3 (owner): plan B. The chosen way while it answers (an out way is checked again as before), then the
            # other Claude way when auto-switch is on, then Gemini while it answers.
            if self._ready(p) or self._recheck(p):
                return p
            if self.auto and o != p and self._ready(o):
                return o
            for b in self._plan_b():
                if self._ready(b):
                    return b
            return p if self.usable(p) else o
        if not self.auto or self._ready(p) or self._recheck(p):
            return p
        if self._ready(o):
            return o
        return p if self.usable(p) else o

    def _ready(self, route: str) -> bool:
        return self.usable(route) and not self.state.is_down(route)

    def _recheck(self, route: str) -> bool:
        """An out route due for a check: in the background during a call (this request goes the other way),
        before the job otherwise (it goes back right away when it answers)."""
        if not (self.usable(route) and self.state.due(route, self.probe_every)):
            return False
        if self.background:
            self._probe_async(route)
            return False
        return self.probe(route)

    def probe(self, route: str) -> bool:
        """A one-word request on the route: it answers, so the job may go back to it."""
        leg = self.legs.get(route)
        if leg is None:
            self.state.mark_down(route, "no_key" if route in ("api", "openai") else "missing")
            return False
        self.state.touch(route)
        c = leg.complete(model=PING_MODEL[route], system=[{"text": "Reply with OK."}], user="OK?", max_tokens=5,
                         cache_ttl=None, extra=None)
        note_account_usage(route, c.account_usage, self.state.path)
        if c.error:
            self.state.mark_down(route, out_reason(route, c.error) or "error", c.reset_at or reset_time(c.error))
            return False
        self.state.mark_up(route)
        return True

    def _probe_async(self, route: str) -> None:
        with self._plock:
            if route in self._probing:
                return
            self._probing.add(route)

        def run():
            try:
                self.probe(route)
            finally:
                with self._plock:
                    self._probing.discard(route)
        threading.Thread(target=run, daemon=True).start()

    def _run(self, route, **kw) -> Completion:
        leg = self.legs.get(route)
        if leg is not None and self.capped(route):          # 0.9.6: never past a provider's monthly limit
            from .cost import ROUTE_PROVIDER
            c = Completion(model=kw.get("model", ""), t_start=time.monotonic(), t_done=time.monotonic(),
                           error="Limit: the monthly limit for {} is reached (Settings > AI)".format(
                               {"claude": "Claude", "openai": "OpenAI", "gemini": "Gemini"}[ROUTE_PROVIDER[route]]))
            c.route = route
            self.last_route = route
            return c
        if leg is None:
            missing = {"api": "no API key", "openai": "no API key", "gemini": "no API key",
                       "agy": "Antigravity CLI is not installed",
                       "codex": "Codex CLI is not installed"}
            c = Completion(model=kw.get("model", ""), t_start=time.monotonic(), t_done=time.monotonic(),
                           error="NoRoute: " + missing.get(route, "Claude Code is not installed"))
        else:
            if route != "api":
                kw = dict(kw, extra=None)
            if route == "local":
                kw = dict(kw, model=os.environ.get("LT_LOCAL_MODEL", "gemma4:26b"))   # the Claude model name means nothing here
            c = leg.complete(**kw)
        c.route = route
        self.last_route = route
        if leg is not None:
            spend_ledger(self.job, route, c, self.state.path)
            note_account_usage(route, getattr(c, "account_usage", None), self.state.path)   # 0.10.0 (AI chain)
        return c

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        kw = dict(model=model, system=system, user=user, max_tokens=max_tokens, cache_ttl=cache_ttl,
                  on_text=on_text, extra=extra)
        if self.chain is not None:
            return self._complete_chain(kw)
        r = self.pick()
        c = self._run(r, **kw)
        if r in self._plan_b() and not c.error:
            c.switched_from = self.preferred            # plan B: the chosen way was out, Gemini answered
        reason = out_reason(r, c.error)
        if not reason:
            if not c.error:
                self.state.mark_up(r)
            return c
        self.state.mark_down(r, reason)
        o = other(r)
        if self.auto and self.usable(o) and not self.state.is_down(o):
            c2 = self._run(o, **kw)
            r2 = out_reason(o, c2.error)
            if r2:
                self.state.mark_down(o, r2)
            if not c2.error:
                c2.switched_from = r
                return c2
        # 0.8.5 (owner, rules/ai.yaml > fallback): neither Claude way answers, so the model on this Mac takes the job
        # (the preparation and after-the-call jobs only; never the tips during a call)
        return self._fallback(r, c, kw)

    def _fallback(self, route, completion, kw):
        for b in self._plan_b():
            if b == route or not self.usable(b) or self.state.is_down(b):
                continue
            g = self._run(b, **kw)
            why = out_reason(b, g.error)
            if why:
                self.state.mark_down(b, why)
            if not g.error:
                g.switched_from = route
                return g
        if self.local_fallback() and route != "local" and self.preferred not in ("local", "openai", "codex", "gemini", "agy"):
            local = self._run("local", **kw)
            if not local.error:
                local.switched_from = route
                return local
        return completion

    def gemini_fallback(self) -> bool:
        """0.9.3 (owner, opt-in in Settings > AI): Gemini takes the job when the chosen way is out. Off by default:
        the text of the call goes to one more company only when the PM turned this on."""
        return bool(self._plan_b())

    def _plan_b(self) -> list:
        """The plan B ways in order: the Gemini API key, then the Gemini account (never during a call: 20-30 s a
        request). None when the PM chose a Gemini way: a chosen Gemini never switches."""
        if not self.gemini_fb or self.preferred in ("gemini", "agy"):
            return []
        return [r for r in ("gemini", "agy") if self.legs.get(r) is not None and not (r == "agy" and self.background)]

    def local_fallback(self) -> bool:
        return os.environ.get("LT_LOCAL_FALLBACK") == "1" and self.legs.get("local") is not None and not self.background


CODE_TIMEOUT = {True: 60.0, False: 300.0}    # during the call / any other job


def make_legs(key: str, workspace: str, cli: Optional[str], api_timeout: float, code_timeout: float,
              openai_model: Optional[str] = None, gemini_model: Optional[str] = None,
              agy_model: Optional[str] = None) -> dict:
    """Claude, OpenAI and local providers; a missing key or CLI leaves that route unavailable."""
    from .providers import OllamaProvider
    from .codex_provider import CodexProvider, find_codex_cli
    from .openai_provider import OpenAIProvider, MODEL as OPENAI_DEFAULT
    from .gemini_provider import GeminiProvider, MODEL as GEMINI_DEFAULT
    from .agy_provider import AgyProvider, find_agy_cli, MODEL as AGY_DEFAULT
    agy = find_agy_cli()
    openai_key = os.environ.get("OPENAI_API_KEY", "")
    gemini_key = os.environ.get("GEMINI_API_KEY", "")
    codex = find_codex_cli()
    return {"codex": CodexProvider(codex, timeout=code_timeout) if codex else None,
            "openai": OpenAIProvider(openai_key, timeout=api_timeout, model=openai_model or OPENAI_DEFAULT) if openai_key else None,
            "agy": AgyProvider(agy, timeout=max(code_timeout, 300.0), model=agy_model or AGY_DEFAULT) if agy else None,
            "gemini": GeminiProvider(gemini_key, timeout=api_timeout, model=gemini_model or GEMINI_DEFAULT) if gemini_key else None,
            "api": AnthropicProvider(key, timeout=api_timeout, workspace_id=workspace) if key else None,
            "code": ClaudeCodeProvider(cli, timeout=code_timeout) if cli else None,
            # 0.8.5 (rules/ai.yaml > routes.local): a model on this Mac, only when the PM chose it for the job
            "local": OllamaProvider(os.environ.get("LT_OLLAMA_URL", "http://127.0.0.1:11434"))}


def _secret(loader: Callable[[str], str], name: str) -> str:
    try:
        return loader(name) if name else ""
    except KeyError:
        return ""


def provider_from_env(job: Optional[str] = None, timeout: float = 120.0) -> Provider:
    """For a one-off job started by the app: LT_AI_ROUTE (api | code), LT_AI_AUTO (1 | 0), LT_AI_STATE,
    LT_CLAUDE_CLI; the key in CLAUDE_API. Without LT_AI_ROUTE: the API key only, as before 0.8.2."""
    env = os.environ
    route = env.get("LT_AI_ROUTE", "")
    cli = find_claude_cli() if route else None
    from .openai_provider import job_model
    from .gemini_provider import job_model as gemini_job_model
    from .agy_provider import job_model as agy_job_model
    j = job or env.get("LT_AI_JOB", "after")
    legs = make_legs(env.get("CLAUDE_API", ""), env.get("CLAUDE_WORKSPACE", ""), cli, timeout, max(timeout, 300.0),
                     openai_model=job_model(j, env.get("LT_OPENAI_MODEL")),
                     gemini_model=gemini_job_model(j, env.get("LT_GEMINI_MODEL")),
                     agy_model=agy_job_model(j, env.get("LT_AGY_MODEL")))
    from .cost import ProviderCaps
    return RoutedProvider(j, route, legs, caps=ProviderCaps.from_cfg({}),
                          auto=bool(route) and env.get("LT_AI_AUTO", "1") == "1", state=RouteState(),
                          gemini_fallback=bool(route) and env.get("LT_GEMINI_FALLBACK") == "1",
                          chain=chain_from(env.get("LT_AI_CHAIN")) if route else None)


def provider_from_cfg(cfg: dict, secret_loader: Callable[[str], str], job: Optional[str] = None,
                      env_route: bool = True) -> Provider:
    """For the tips engine and the judge: cfg["ai"] = {"routes": {job: route}, "auto": bool, "state": path,
    "claude_cli": path}, written by the app into sidecar-config.json. LT_AI_ROUTE wins (a one-off run)."""
    ai = cfg.get("ai") or {}
    job = job or ai.get("job", "tips")
    # env_route=False (2026-11-06): the tips engine builds the preparation's provider; LT_AI_ROUTE names the tips way
    route = (os.environ.get("LT_AI_ROUTE") if env_route else None) or (ai.get("routes") or {}).get(job)
    key = _secret(secret_loader, cfg.get("api_key_env", "CLAUDE_API"))
    ws = cfg.get("workspace_id") or _secret(secret_loader, cfg.get("workspace_id_env", ""))
    from .openai_provider import job_model
    from .gemini_provider import job_model as gemini_job_model
    from .agy_provider import job_model as agy_job_model
    legs = make_legs(key, ws, find_claude_cli(ai.get("claude_cli") or cfg.get("claude_cli")), 30.0, CODE_TIMEOUT[job == "tips"],
                     openai_model=job_model(job, (ai.get("openai_models") or {}).get(job)),
                     gemini_model=gemini_job_model(job, (ai.get("gemini_models") or {}).get(job)),
                     agy_model=agy_job_model(job, (ai.get("agy_models") or {}).get(job)))
    from .cost import ProviderCaps
    return RoutedProvider(job, route, legs, auto=bool(ai.get("auto", True)), state=RouteState(ai.get("state")),
                          background=(job == "tips"), caps=ProviderCaps.from_cfg(cfg),
                          gemini_fallback=bool(ai.get("gemini_fallback", False)) or os.environ.get("LT_GEMINI_FALLBACK") == "1",
                          chain=chain_from(ai.get("chain")) if "chain" in ai else chain_from(os.environ.get("LT_AI_CHAIN")))


def main(argv=None) -> int:
    """`ping --route api|code`: a one-word request on that way, its state updated (Settings > AI > Check now).
    `status`: the shared state."""
    ap = argparse.ArgumentParser(description="Pacenote AI routes: check a way to Claude, show the shared state")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ping").add_argument("--route", choices=ROUTES, required=True)
    sub.add_parser("status")
    a = ap.parse_args(argv)
    st = RouteState()
    if a.cmd == "ping":
        legs = make_legs(os.environ.get("CLAUDE_API", ""), os.environ.get("CLAUDE_WORKSPACE", ""), find_claude_cli(), 30.0, 60.0)
        RoutedProvider("ping", a.route, legs, auto=False, state=st).probe(a.route)
    print(json.dumps(st.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
