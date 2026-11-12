"""0.10.0 (owner 12.11): a light usage probe of the PM's AI accounts, so the status icon shows numbers before the next
real job runs ("usage not reported" otherwise).

- Claude account: one tiny Claude Code run (`claude -p`, the smallest model, "Reply with OK", stream-json as the app's
  other runs, no tools, no settings, no MCP, no saved session, one turn). Its rate_limit_event is the account's report.
- ChatGPT account: one tiny `codex exec --json` WITHOUT --ephemeral (only here: real jobs stay --ephemeral), so the run's
  own session log carries rate_limits; the log is read and then removed by the run's thread id
  (codex_provider.run_usage). The prompt holds no call text, so the tiny session is harmless.

The report goes to state/ai-accounts.json (routing.note_account_usage), the tokens to state/spend-ledger.jsonl as
account usage (job "usage_probe", no price). The app decides when to probe (AIUsageProbe.swift: at launch after 60 s,
every 30 minutes with no call and no preparation, on the popover when the numbers are older than 10 minutes).
Prints one JSON line with numbers only: never a key, a token or any text."""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional

from . import routing
from .providers import Completion

PROMPT = "Reply with OK"
CLAUDE_MODEL = "haiku"          # the smallest family; Claude Code takes the alias
JOB = "usage_probe"


def claude_args(cli: str) -> list:
    """`claude -p` as the app's other runs (stream-json, --verbose), with no tools and one turn."""
    return [cli, "-p", "--model", CLAUDE_MODEL, "--output-format", "stream-json", "--verbose", "--tools", "",
            "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence", "--max-turns", "1"]


def ledger(route: str, model: str, input_tokens: int, output_tokens: int, cache_read: int, state_path,
           error: bool = False) -> None:
    """One line in <state>/spend-ledger.jsonl: account usage, no price (usd null)."""
    try:
        row = {"at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "job": JOB, "route": route, "model": model,
               "input": int(input_tokens or 0), "output": int(output_tokens or 0), "cache_read": int(cache_read or 0),
               "cache_write": 0, "usd": None, "error": bool(error)}
        p = Path(state_path).with_name("spend-ledger.jsonl")
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")
    except Exception:  # noqa: BLE001  the ledger never breaks a probe
        pass


def summary(account: str, usage: Optional[dict], tokens: dict, error: Optional[str] = None) -> dict:
    """Numbers only."""
    out = {"ok": bool(usage) and not error, "account": account, "tokens": tokens}
    if usage:
        out["limited"] = bool(usage.get("limited"))
        out["windows"] = [{"name": w.get("name"), "used_percent": w.get("used_percent"), "resets_at": w.get("resets_at")}
                          for w in usage.get("windows") or []]
        if usage.get("until"):
            out["until"] = usage["until"]
    if error:
        out["error"] = error
    return out


def probe_claude(cli: Optional[str], state_path, timeout: float = 90.0, run=subprocess.run) -> dict:
    if not cli:
        return summary("code", None, {}, "not_installed")
    with tempfile.TemporaryDirectory(prefix="pacenote-probe-") as cwd:     # an empty folder: no CLAUDE.md, no project
        try:
            r = run(claude_args(cli), input=PROMPT, capture_output=True, text=True, cwd=cwd,
                    env=routing.cc_env(os.environ), timeout=timeout)
        except subprocess.TimeoutExpired:
            return summary("code", None, {}, "timeout")
        except OSError as e:
            return summary("code", None, {}, type(e).__name__)
    result, usage = routing.cc_stream_result(r.stdout or "")
    u = (result or {}).get("usage") or {}
    tokens = {"input": int(u.get("input_tokens") or 0), "output": int(u.get("output_tokens") or 0),
              "cache_read": int(u.get("cache_read_input_tokens") or 0)}
    err = routing._cc_result_error(result) if result else ("exit %d" % r.returncode if r.returncode else "no_result")
    reason = routing.out_reason("code", err) if err else None
    if usage:
        routing.note_account_usage("code", usage, state_path)
    if result or usage:
        ledger("code", "claude-code/" + CLAUDE_MODEL, tokens["input"], tokens["output"], tokens["cache_read"], state_path,
               error=bool(err))
    return summary("code", usage, tokens, (reason or "error") if err and not usage else None)


def probe_codex(cli: Optional[str], state_path, timeout: float = 120.0, home: Optional[str] = None) -> dict:
    from .codex_provider import CodexProvider
    if not cli:
        return summary("codex", None, {}, "not_installed")
    p = CodexProvider(cli, timeout=timeout, home=home)
    p.ephemeral = False                 # only the probe keeps its session log (read, then removed by its thread id)
    c: Completion = p.complete(model="codex/default", system=[{"text": "Answer in one word."}], user=PROMPT,
                               max_tokens=16, cache_ttl=None)
    usage = c.account_usage
    tokens = {"input": int(c.input_tokens or 0), "output": int(c.output_tokens or 0), "cache_read": int(c.cache_read or 0)}
    if usage:
        routing.note_account_usage("codex", usage, state_path)
    signed_out = "not logged in" in str(c.error or "").lower()
    if not signed_out:
        ledger("codex", c.model or "codex/default", tokens["input"], tokens["output"], tokens["cache_read"], state_path,
               error=bool(c.error))
    err = None
    if c.error and not usage:
        err = "signed_out" if signed_out else (routing.out_reason("codex", c.error) or "error")
    return summary("codex", usage, tokens, err)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Pacenote: a light usage probe of the Claude and ChatGPT accounts")
    ap.add_argument("--account", choices=["code", "codex"], required=True)
    ap.add_argument("--state", default=None, help="state/ai-routes.json (default: LT_AI_STATE)")
    a = ap.parse_args(argv)
    state = a.state or routing.default_state_path()
    if a.account == "code":
        out = probe_claude(routing.find_claude_cli(), state)
    else:
        from .codex_provider import find_codex_cli
        out = probe_codex(find_codex_cli(), state)
    print(json.dumps(out))
    return 0 if out.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
