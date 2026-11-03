"""ChatGPT account completions through the official Codex CLI, without copying its credentials."""
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


def exec_args(cli):
    # An empty working directory and ignored user config prevent loading project tools/MCP or personal prompts.
    args = [cli, "exec", "--json", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check",
            "--sandbox", "read-only", "--color", "never", "-c", AUTH]
    for value in ['approval_policy="never"', 'web_search="disabled"', "project_doc_max_bytes=0",
                  "features.shell_tool=false", "features.multi_agent=false", "features.plugins=false",
                  "features.apps=false", "features.hooks=false", "features.memories=false",
                  "features.view_image=false", "analytics.enabled=false"]:
        args += ["-c", value]
    return args + ["-"]


def failure_reason(message):
    text = str(message).lower()
    if any(word in text for word in ("limit", "quota", "credits")):
        return "Codex: usage limit reached"
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


def apply_event(completion, event, on_text):
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

    def __init__(self, cli, timeout=300.0):
        self.cli = cli
        self.timeout = timeout

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        completion = Completion(model=MODEL, route="codex", t_start=time.monotonic())
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
        completion.t_done = time.monotonic()
        return completion

    def _run(self, completion, cwd, prompt, on_text):
        # Drain stdout as events arrive. A timer also covers a blocked stdin write or a stalled CLI.
        with subprocess.Popen(exec_args(self.cli), cwd=cwd, env=account_env(os.environ), text=True,
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
                    apply_event(completion, json.loads(line), on_text)
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
