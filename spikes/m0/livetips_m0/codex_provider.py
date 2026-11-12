"""ChatGPT account completions through the official Codex CLI, without copying its credentials.

0.10.0 (status fix, 12.11): `codex exec --json` prints no rate limits, but Codex writes them (rate_limits: primary =
5 hours, secondary = the week, used_percent, resets_at, rate_limit_reached_type) into the session log of the run,
~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl. So the run is not --ephemeral: Pacenote takes the
thread id from `thread.started`, reads only the last rate_limits object of that run's log after the run (also after a
failed one), then removes that one file, by its id, like the agy cleanup (agy_provider.forget). Nothing else in
~/.codex is touched. LT_CODEX_EPHEMERAL=1 brings back --ephemeral (no log, no usage numbers)."""
import glob
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time

from .providers import Completion, Provider, take_piece, user_text

AUTH = 'forced_login_method="chatgpt"'
MODEL = "codex/default"
HIDDEN_ENV = {"OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "OPENAI_ORG_ID",
              "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_API", "NOTION_TOKEN"}


def account_env(environ):
    return {key: value for key, value in environ.items() if key not in HIDDEN_ENV}


def find_codex_cli(hint=None):
    home = os.path.expanduser("~")
    candidates = [hint, os.environ.get("LT_CODEX_CLI"), shutil.which("codex"),
                  home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                  "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                  "/Applications/Codex.app/Contents/Resources/codex"]
    return next((p for p in candidates if p and os.path.isfile(p) and os.access(p, os.X_OK)), None)


def signed_in(cli, cwd, timeout):
    result = subprocess.run([cli, "-c", AUTH, "login", "status"], cwd=cwd, env=account_env(os.environ),
                            capture_output=True, text=True, timeout=min(timeout, 15))
    text = (result.stdout + result.stderr).lower()
    return result.returncode == 0 and "logged in using chatgpt" in text


def ephemeral_mode():
    # 2026-11-12 (owner review): --ephemeral by default until it is verified that a kept session leaves no call text in
    # ~/.codex (state and history databases); LT_CODEX_EPHEMERAL=0 keeps the session log for the usage numbers.
    return os.environ.get("LT_CODEX_EPHEMERAL", "") != "0"


def exec_args(cli, ephemeral=None):
    # An empty working directory and ignored user config prevent loading project tools/MCP or personal prompts.
    # 0.10.0 (status fix): not --ephemeral, so the run's session log carries the account's rate limits (read, then
    # removed by id); --ignore-user-config and the -c overrides work the same either way.
    eph = ephemeral_mode() if ephemeral is None else ephemeral
    args = [cli, "exec", "--json"] + (["--ephemeral"] if eph else []) + ["--ignore-user-config", "--skip-git-repo-check",
            "--sandbox", "read-only", "--color", "never", "-c", AUTH]
    for value in ['approval_policy="never"', 'web_search="disabled"', "project_doc_max_bytes=0",
                  "features.shell_tool=false", "features.multi_agent=false", "features.plugins=false",
                  "features.apps=false", "features.hooks=false", "features.memories=false",
                  "features.view_image=false", "analytics.enabled=false"]:
        args += ["-c", value]
    return args + ["-"]


def _reset_phrase(text):
    """0.10.0 (AI chain): only the reset part of a limit message ("try again at 12:48 PM", "try again in 2 days 3
    hours"), never the rest (links, account details)."""
    import re
    m = re.search(r"(try again (?:at \d{1,2}(?::\d{2})?\s*(?:am|pm)?|in (?:\d+\s*[a-z]+[\s,]*(?:and\s+)?)+)|resets? (?:at )?\d{1,2}(?::\d{2})?\s*(?:am|pm)?)", text)
    return m.group(1).strip(" ,.") if m else ""


def failure_reason(message):
    text = str(message).lower()
    if any(word in text for word in ("limit", "quota", "credits")):
        phrase = _reset_phrase(text)
        return "Codex: usage limit reached" + (" (%s)" % phrase if phrase else "")
    if any(word in text for word in ("login", "logged in", "auth", "sign in", "401")):
        return "Codex: not logged in with ChatGPT"
    return "Codex: request failed"


def apply_message(completion, item, on_text):
    if item.get("type") != "agent_message":
        return
    text = item.get("text") or ""
    if text and text != completion.text and text.startswith(completion.text):
        take_piece(completion, text[len(completion.text):], on_text)


def apply_usage(completion, usage):
    completion.cache_read = int(usage.get("cached_input_tokens") or 0)
    completion.input_tokens = max(0, int(usage.get("input_tokens") or 0) - completion.cache_read)
    completion.output_tokens = int(usage.get("output_tokens") or 0)


def find_rate_limits(obj, depth=0):
    """0.10.0 (AI chain): a `rate_limits` object anywhere in a Codex event (its session logs carry one in token_count
    events; `codex exec --json` 0.167 printed none in the check of 2026-11-12), else None."""
    if depth > 4:
        return None
    if isinstance(obj, dict):
        rl = obj.get("rate_limits")
        if isinstance(rl, dict):
            return rl
        for v in obj.values():
            found = find_rate_limits(v, depth + 1)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj[:20]:
            found = find_rate_limits(v, depth + 1)
            if found is not None:
                return found
    return None


def codex_home():
    return os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")


def _safe_id(thread_id):
    tid = str(thread_id or "")
    return tid if tid and len(tid) <= 80 and all(ch.isalnum() or ch == "-" for ch in tid) else ""


def rollout_files(thread_id, home=None):
    """The session log(s) of one run: sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl, nothing else (an id that
    is not letters, digits and dashes matches nothing)."""
    tid = _safe_id(thread_id)
    if not tid:
        return []
    root = os.path.realpath(os.path.join(home or codex_home(), "sessions"))
    out = []
    for p in glob.glob(os.path.join(root, "*", "*", "*", "rollout-*-" + tid + ".jsonl")):
        name = os.path.basename(p)
        if name.startswith("rollout-") and name.endswith("-" + tid + ".jsonl") and os.path.realpath(p).startswith(root + os.sep) \
                and os.path.isfile(p) and not os.path.islink(p):
            out.append(p)
    return out


def rollout_rate_limits(path):
    """The last rate_limits object of a session log that has numbers (primary or secondary), else None. Only lines
    that name rate_limits are parsed; nothing else of the file is kept."""
    last = None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"rate_limits"' not in line:
                    continue
                try:
                    rl = find_rate_limits(json.loads(line))
                except ValueError:
                    continue
                if isinstance(rl, dict) and (isinstance(rl.get("primary"), dict) or isinstance(rl.get("secondary"), dict)):
                    last = rl
    except OSError:
        return None
    return last


def forget(thread_id, home=None):
    """Removes the session log of the run Pacenote made (its id only; never another file). Returns how many."""
    gone = 0
    for p in rollout_files(thread_id, home):
        try:
            os.unlink(p)
            gone += 1
        except OSError:
            pass
    return gone


def run_usage(completion, thread_id, home=None, now=None):
    """After a run (also a failed one): the account's limits from the run's own session log, then the log is removed.
    A limit error with no numbers still says when it resets ("try again at 12:48 PM")."""
    from .routing import account_usage_codex, reset_time
    rl = None
    for p in rollout_files(thread_id, home):
        rl = rollout_rate_limits(p) or rl
    forget(thread_id, home)
    now = time.time() if now is None else now
    usage = account_usage_codex(rl, now=now) if rl else completion.account_usage
    err = str(completion.error or "")
    if "usage limit" in err.lower():
        usage = dict(usage or {"at": now, "windows": []})
        # the account's own reset time when its log had one, else the error's ("try again at 12:48 PM")
        until = usage.get("until") or completion.reset_at or reset_time(err, now=now)
        usage["limited"] = True
        if until:
            usage["until"] = until
        completion.reset_at = completion.reset_at or until
    if usage:
        completion.account_usage = usage
        if os.environ.get("LT_AI_STATE"):      # every run the app starts (also codexprep), not only the routed ones
            from .routing import note_account_usage
            note_account_usage("codex", usage, os.environ["LT_AI_STATE"])
    return usage


def apply_event(completion, event, on_text):
    rl = find_rate_limits(event)
    if rl is not None:
        from .routing import account_usage_codex
        completion.account_usage = account_usage_codex(rl) or completion.account_usage
    kind = event.get("type")
    if kind in ("item.updated", "item.completed"):
        apply_message(completion, event.get("item") or {}, on_text)
    elif kind == "turn.completed":
        apply_usage(completion, event.get("usage") or {})
        completion.stop_reason = kind
    elif kind in ("error", "turn.failed"):
        completion.error = failure_reason(event.get("error") or event.get("message"))


class CodexProvider(Provider):
    name = "codex"

    def __init__(self, cli, timeout=300.0, home=None):
        self.cli = cli
        self.timeout = timeout
        self.home = home              # CODEX_HOME for tests; None = the real one
        self.ephemeral = None         # None: LT_CODEX_EPHEMERAL decides (--ephemeral by default); the usage probe: False

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        completion = Completion(model=MODEL, route="codex", t_start=time.monotonic())
        self._thread = None
        try:
            with tempfile.TemporaryDirectory(prefix="pacenote-codex-") as cwd:
                if not signed_in(self.cli, cwd, self.timeout):
                    completion.error = "Codex: not logged in with ChatGPT"
                else:
                    prompt = "\n\n".join(b["text"] for b in system) + "\n\n" + user_text(user)
                    prompt += "\n\nReturn only the requested answer. Do not use tools. Keep within about %d output tokens." % max_tokens
                    self._run(completion, cwd, prompt, on_text)
        except subprocess.TimeoutExpired:
            completion.error = "Codex: request timed out"
        except Exception as error:  # noqa: BLE001  never expose stderr, credentials or call text
            completion.error = "Codex: " + type(error).__name__
        finally:
            if self._thread:
                try:
                    run_usage(completion, self._thread, self.home)
                except Exception:  # noqa: BLE001  a hint for the status, never a reason to fail a request
                    pass
        completion.t_done = time.monotonic()
        return completion

    def _run(self, completion, cwd, prompt, on_text):
        # Drain stdout as events arrive. A timer also covers a blocked stdin write or a stalled CLI.
        with subprocess.Popen(exec_args(self.cli, self.ephemeral), cwd=cwd, env=account_env(os.environ), text=True,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
            timed_out = threading.Event()

            def expire():
                timed_out.set()
                process.kill()

            timer = threading.Timer(self.timeout, expire)
            timer.start()
            try:
                process.stdin.write(prompt)
                process.stdin.close()
                for line in process.stdout:
                    event = json.loads(line)
                    if event.get("type") == "thread.started" and event.get("thread_id"):
                        self._thread = str(event["thread_id"])        # the run's session log, read and removed after
                    apply_event(completion, event, on_text)
                process.wait()
            finally:
                timer.cancel()
                if process.poll() is None:
                    process.kill()
                    process.wait()
            if timed_out.is_set():
                raise subprocess.TimeoutExpired(self.cli, self.timeout)
            if process.returncode or completion.stop_reason != "turn.completed" or not completion.text:
                completion.error = completion.error or "Codex: incomplete response"
