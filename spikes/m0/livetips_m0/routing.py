"""AI routes (Pacenote 0.8.2): which way each job reaches Claude, and the automatic switch.

Two routes:
- "api": the Claude API key (Settings > AI), billed per token, the fastest.
- "code": the PM's Claude account through Claude Code (`claude -p`), from the plan's limits, no key.

Three jobs: "prep" (the app runs Claude Code itself; here only the route state is shared), "tips" (during the
call) and "after" (summary, follow-up email, call memory, rehearsal, the judge).

Auto-switch (on by default): when the chosen route is out (API: no credit or a bad key, or the app's own
monthly limit; Claude Code: the plan limit, signed out, not installed), the work goes to the other route. The
out route is checked again before the next job (during a call: in the background, every 2 minutes), and the
job goes back to it as soon as it answers. The app, the tips engine and the one-off jobs share the state in one
small file (state/ai-routes.json), so Settings > AI can show it.
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

ROUTES = ("api", "code")
JOBS = ("prep", "tips", "after")
PROBE_EVERY_S = 120
PING_MODEL = {"api": "claude-haiku-5-5", "code": "haiku"}


def other(route: str) -> str:
    return "code" if route == "api" else "api"


def default_state_path() -> str:
    return os.environ.get("LT_AI_STATE") or os.path.expanduser(
        "~/Library/Application Support/LiveTips/state/ai-routes.json")


def find_claude_cli(hint: str = "") -> Optional[str]:
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


def out_reason(route: str, err: Optional[str]) -> Optional[str]:
    """Why a route is out (worth switching), or None for a passing error (timeout, overload: hedging helps)."""
    if not err:
        return None
    e = err.lower()
    if "noroute" in e or "not installed" in e:
        return "missing"
    if "no api key" in e:
        return "no_key"
    if "credit balance" in e or "billing" in e or "insufficient" in e:
        return "credit"
    if route == "api":
        if "authentication" in e or "x-api-key" in e or "permissiondenied" in e:
            return "auth"
        return None
    if "limit" in e:                      # "usage limit reached", "5-hour limit", "weekly limit"
        return "limit"
    if "login" in e or "logged in" in e or "oauth" in e or "authentication" in e or "invalid api key" in e:
        return "auth"
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
            tmp.write_text(json.dumps(d, indent=1), encoding="utf-8")
            os.replace(tmp, self.path)
        except Exception:  # noqa: BLE001  the state is a hint, never a reason to fail a job
            pass

    def is_down(self, route: str) -> bool:
        return bool((self.read().get(route) or {}).get("down"))

    def due(self, route: str, every_s: float) -> bool:
        return time.time() - float((self.read().get(route) or {}).get("checked") or 0) >= every_s

    def mark_down(self, route: str, reason: str) -> None:
        with self.lock:
            d = self.read()
            cur = d.get(route) or {}
            now = time.time()
            d[route] = {"down": True, "reason": reason, "since": cur.get("since") if cur.get("down") else now,
                        "checked": now}
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
        sp = None
        try:
            fd, sp = tempfile.mkstemp(prefix="sys-", suffix=".txt", dir=self.cwd)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("\n\n".join(b["text"] for b in system) or "Answer briefly.")
            args = [self.cli, "-p", "--model", alias, "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--system-prompt-file", sp, "--tools", "", "--setting-sources", "",
                    "--strict-mcp-config", "--no-session-persistence"]
            env = {k: v for k, v in os.environ.items()
                   if k not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API", "ANTHROPIC_CUSTOM_HEADERS")}
            p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, cwd=self.cwd, env=env)
            timer = threading.Timer(self.timeout, p.kill)
            timer.start()
            try:
                p.stdin.write(user_text(user))
                p.stdin.close()
                result = None
                for line in p.stdout:
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        continue
                    t = ev.get("type")
                    if t == "stream_event":
                        e = ev.get("event") or {}
                        d = e.get("delta") or {}
                        if e.get("type") == "content_block_delta" and d.get("type") == "text_delta":
                            if c.t_first_token is None:
                                c.t_first_token = time.monotonic()
                            c.text += d.get("text", "")
                            if c.t_gist is None and gist_closed(c.text):
                                c.t_gist = time.monotonic()
                            if on_text:
                                on_text(c.text)
                    elif t == "result":
                        result = ev
                err = p.stderr.read()
                p.wait()
            finally:
                timer.cancel()
            c.t_done = time.monotonic()
            if result:
                u = result.get("usage") or {}
                c.input_tokens = u.get("input_tokens", 0) or 0
                c.cache_read = u.get("cache_read_input_tokens", 0) or 0
                c.output_tokens = u.get("output_tokens", 0) or 0
                c.equiv_usd = result.get("total_cost_usd")
                if not c.text and isinstance(result.get("result"), str):
                    c.text = result["result"]
                if result.get("is_error") or result.get("subtype") not in (None, "success"):
                    c.error = "ClaudeCode: " + str(result.get("result") or result.get("subtype"))[:200]
            elif p.returncode != 0 or not c.text:
                c.error = "ClaudeCode: exit {} {}".format(p.returncode, (err or "").strip()[-200:])
        except Exception as e:  # noqa: BLE001
            c.t_done = time.monotonic()
            c.error = "ClaudeCode: {}: {}".format(type(e).__name__, str(e)[:200])
        finally:
            if sp:
                try:
                    os.remove(sp)
                except OSError:
                    pass
        return c


class RoutedProvider(Provider):
    """One job's provider: the chosen route, and with auto-switch the other route when the chosen one is out."""
    name = "routed"

    def __init__(self, job: str, preferred: str, legs: Dict[str, Optional[Provider]], auto: bool = True,
                 state: Optional[RouteState] = None, probe_every: float = PROBE_EVERY_S, background: bool = False,
                 api_blocked: Optional[Callable[[], bool]] = None):
        self.job = job
        self.preferred = preferred if preferred in ROUTES else "api"
        self.legs = dict(legs)
        self.auto = auto
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

    def usable(self, route: str) -> bool:
        if self.legs.get(route) is None:
            return False
        return not (route == "api" and self.api_blocked and self.api_blocked())

    def can_run_without_api(self) -> bool:
        """True when the app's own API limit does not stop this job (it goes, or may go, through Claude Code)."""
        if self.legs.get("code") is None:
            return False
        return self.preferred == "code" or self.auto

    def pick(self) -> str:
        p = self.preferred
        if not self.auto:
            return p
        o = other(p)
        if self.usable(p) and not self.state.is_down(p):
            return p
        if self.usable(p) and self.state.due(p, self.probe_every):
            if self.background:
                self._probe_async(p)
            elif self.probe(p):
                return p
        if self.usable(o) and not self.state.is_down(o):
            return o
        return p if self.usable(p) else o

    def probe(self, route: str) -> bool:
        """A one-word request on the route: it answers, so the job may go back to it."""
        leg = self.legs.get(route)
        if leg is None:
            return False
        self.state.touch(route)
        c = leg.complete(model=PING_MODEL[route], system=[{"text": "Reply with OK."}], user="OK?", max_tokens=5,
                         cache_ttl=None, extra=None)
        if c.error:
            self.state.mark_down(route, out_reason(route, c.error) or "error")
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
        if leg is None:
            c = Completion(model=kw.get("model", ""), t_start=time.monotonic(), t_done=time.monotonic(),
                           error="NoRoute: " + ("no API key" if route == "api" else "Claude Code is not installed"))
        else:
            if route != "api":
                kw = dict(kw, extra=None)
            c = leg.complete(**kw)
        c.route = route
        self.last_route = route
        return c

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        kw = dict(model=model, system=system, user=user, max_tokens=max_tokens, cache_ttl=cache_ttl,
                  on_text=on_text, extra=extra)
        r = self.pick()
        c = self._run(r, **kw)
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
        return c


def _env_api_leg(timeout: float) -> Optional[Provider]:
    key = os.environ.get("CLAUDE_API", "")
    if not key:
        return None
    return AnthropicProvider(key, timeout=timeout, workspace_id=os.environ.get("CLAUDE_WORKSPACE", ""))


def provider_from_env(job: Optional[str] = None, timeout: float = 120.0) -> Provider:
    """For a one-off job started by the app: LT_AI_ROUTE (api | code), LT_AI_AUTO (1 | 0), LT_AI_STATE,
    LT_CLAUDE_CLI; the key in CLAUDE_API. Without LT_AI_ROUTE: the API key as before 0.8.2."""
    job = job or os.environ.get("LT_AI_JOB", "after")
    route = os.environ.get("LT_AI_ROUTE", "")
    if not route:
        return _env_api_leg(timeout) or RoutedProvider(job, "api", {"api": None, "code": None}, auto=False)
    cli = find_claude_cli()
    legs = {"api": _env_api_leg(timeout), "code": ClaudeCodeProvider(cli, timeout=max(timeout, 300.0)) if cli else None}
    return RoutedProvider(job, route, legs, auto=os.environ.get("LT_AI_AUTO", "1") == "1", state=RouteState())


def provider_from_cfg(cfg: dict, secret_loader: Callable[[str], str], job: Optional[str] = None) -> Provider:
    """For the tips engine and the judge: cfg["ai"] = {"routes": {job: route}, "auto": bool, "state": path,
    "claude_cli": path}, written by the app into sidecar-config.json."""
    ai = cfg.get("ai") or {}
    job = job or ai.get("job", "tips")
    route = os.environ.get("LT_AI_ROUTE") or (ai.get("routes") or {}).get(job) or "api"   # the env wins (a one-off run)
    try:
        key = secret_loader(cfg.get("api_key_env", "CLAUDE_API"))
    except KeyError:
        key = ""
    ws = cfg.get("workspace_id", "")
    if not ws and cfg.get("workspace_id_env"):
        try:
            ws = secret_loader(cfg["workspace_id_env"])
        except KeyError:
            ws = ""
    cli = find_claude_cli(ai.get("claude_cli") or cfg.get("claude_cli") or "")
    timeout = 60.0 if job == "tips" else 300.0
    legs = {"api": AnthropicProvider(key, workspace_id=ws) if key else None,
            "code": ClaudeCodeProvider(cli, timeout=timeout) if cli else None}
    return RoutedProvider(job, route, legs, auto=bool(ai.get("auto", True)), state=RouteState(ai.get("state")),
                          background=(job == "tips"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Pacenote AI routes: check a route, show or change the shared state")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pg = sub.add_parser("ping")
    pg.add_argument("--route", choices=ROUTES, required=True)
    sub.add_parser("status")
    mk = sub.add_parser("mark")
    mk.add_argument("--route", choices=ROUTES, required=True)
    mk.add_argument("--down", default="")
    mk.add_argument("--up", action="store_true")
    a = ap.parse_args(argv)
    st = RouteState()
    if a.cmd == "status":
        print(json.dumps(st.read()))
        return 0
    if a.cmd == "mark":
        st.mark_up(a.route) if a.up else st.mark_down(a.route, a.down or "error")
        print(json.dumps({"ok": True}))
        return 0
    cli = find_claude_cli()
    legs = {"api": _env_api_leg(30.0), "code": ClaudeCodeProvider(cli, timeout=60.0) if cli else None}
    rp = RoutedProvider("ping", a.route, legs, auto=False, state=st)
    ok = rp.probe(a.route)
    print(json.dumps({"ok": ok, "route": a.route, "state": st.read().get(a.route) or {}}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
