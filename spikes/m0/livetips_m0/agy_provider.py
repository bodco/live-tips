"""Gemini account completions through Google's Antigravity CLI (`agy`), without touching its credentials (0.9.3).

For the preparation and the after-the-call jobs only: a request takes 20-30 s however small (the agent's own start
and system prompt, measured 2026-11-05), too slow for tips during a call. Every request runs in an empty temporary
folder (agy reads files in its working folder without asking), with --sandbox, no slash commands, no API key in the
environment (so the signed-in Google account pays, never a key) and the prompt on stdin. Reading outside the folder,
writing and shell commands are denied in print mode; a denied action with no answer is an error. agy keeps every
conversation under ~/.gemini/antigravity-cli (brain/<id>, annotations/<id>.pbtxt): Pacenote removes the folder and the
file of the conversation it made, and only those. Errors name the kind only, never stderr or the call text."""
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from .providers import Completion, Provider, take_piece, user_text

MODEL = "gemini-3.8-flash-medium"          # the default of both jobs; `agy models` lists what the account has
JOB_DEFAULTS = {"prep": MODEL, "after": MODEL}
HIDDEN_ENV = {"GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_APPLICATION_CREDENTIALS",
              "GOOGLE_CLOUD_PROJECT", "GOOGLE_GEMINI_BASE_URL", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
              "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_API", "NOTION_TOKEN"}
STATE_DIR = Path(os.path.expanduser("~/.gemini/antigravity-cli"))


def account_env(environ):
    return {key: value for key, value in environ.items() if key not in HIDDEN_ENV}


def find_agy_cli(hint=None):
    home = os.path.expanduser("~")
    candidates = [hint, os.environ.get("LT_AGY_CLI"), shutil.which("agy"), home + "/.local/bin/agy",
                  "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
    return next((p for p in candidates if p and os.path.isfile(p) and os.access(p, os.X_OK)), None)


def job_model(job=None, chosen=None):
    """The account model of a job: the PM's choice (Settings > AI), else the default. A Gemini API id (gemini-3.8-flash)
    is not an agy id (gemini-3.8-flash-medium): only an id with an effort suffix is taken as chosen."""
    m = (chosen or "").strip()
    return m if m.endswith(("-low", "-medium", "-high")) else JOB_DEFAULTS.get(job or "", MODEL)


def exec_args(cli, model, timeout):
    return [cli, "--output-format", "json", "--sandbox", "--disable-slash-commands", "--model", model,
            "--print-timeout", "%ds" % int(timeout)]


def failure_reason(text):
    t = (text or "").lower()
    if any(w in t for w in ("quota", "limit", "credits", "exhausted")):
        return "Gemini account: usage limit reached"
    if any(w in t for w in ("authentication required", "not signed", "sign in", "login", "oauth", "unauthenticated")):
        return "Gemini account: not signed in"
    return "Gemini account: request failed"


def apply_result(completion, envelope, on_text):
    """The json envelope of one print-mode run: status, response, usage, denied_actions."""
    text = envelope.get("response") or ""
    if text:
        take_piece(completion, text, on_text)
    usage = envelope.get("usage") or {}
    completion.cache_read = int(usage.get("cache_read_tokens") or 0)
    completion.input_tokens = int(usage.get("input_tokens") or 0)
    thoughts = int(usage.get("thinking_tokens") or 0)
    completion.output_tokens = int(usage.get("output_tokens") or 0) + thoughts
    completion.reasoning_tokens = thoughts
    completion.stop_reason = str(envelope.get("status") or "")
    if completion.stop_reason != "SUCCESS":
        completion.error = failure_reason(completion.stop_reason)
    elif not text.strip():
        denied = envelope.get("denied_actions") or []
        completion.error = "Gemini account: a tool was denied" if denied else "Gemini account: empty answer"


def forget(conversation_id, state_dir=None):
    """Removes agy's own copy of the conversation Pacenote made (its id only; a path outside the folder is refused)."""
    cid = str(conversation_id or "")
    if not cid or not all(ch.isalnum() or ch == "-" for ch in cid):
        return False
    root = Path(state_dir) if state_dir else STATE_DIR
    gone = False
    for p in (root / "brain" / cid, root / "annotations" / (cid + ".pbtxt")):
        try:
            if p.is_dir():
                shutil.rmtree(p)
                gone = True
            elif p.is_file():
                p.unlink()
                gone = True
        except OSError:
            pass
    return gone


class AgyProvider(Provider):
    """The Gemini account. Model ids are agy's (gemini-3.8-flash-medium); a Claude or API id means the job's model."""
    name = "agy"

    def __init__(self, cli, timeout=300.0, model=MODEL, state_dir=None):
        self.cli = cli
        self.timeout = timeout
        self.model = model or MODEL
        self.state_dir = state_dir

    def describe(self, model):
        return {"route": "agy", "model": "agy/" + self.model}

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        use = model if isinstance(model, str) and model.endswith(("-low", "-medium", "-high")) else self.model
        completion = Completion(model="agy/" + use, route="agy", t_start=time.monotonic())
        if not self.cli:
            completion.error = "Gemini account: Antigravity CLI is not installed"
            completion.t_done = time.monotonic()
            return completion
        prompt = "\n\n".join(b["text"] for b in system) + "\n\n" + user_text(user)
        prompt += "\n\nReturn only the requested answer. Do not use tools. Keep within about %d output tokens." % max_tokens
        envelope = {}
        try:
            with tempfile.TemporaryDirectory(prefix="pacenote-agy-") as cwd:
                p = subprocess.run(exec_args(self.cli, use, self.timeout), cwd=cwd, env=account_env(os.environ),
                                   input=prompt, capture_output=True, text=True, timeout=self.timeout + 15)
            try:
                envelope = json.loads(p.stdout or "{}")
            except ValueError:
                envelope = {}
            if isinstance(envelope, dict) and envelope.get("status"):
                apply_result(completion, envelope, on_text)
            else:
                completion.error = failure_reason(p.stderr if p.returncode else "")
        except subprocess.TimeoutExpired:
            completion.error = "Gemini account: request timed out"
        except Exception as error:  # noqa: BLE001  never expose stderr, credentials or call text
            completion.error = "Gemini account: " + type(error).__name__
        finally:
            if isinstance(envelope, dict) and envelope.get("conversation_id"):
                forget(envelope["conversation_id"], self.state_dir)
        completion.t_done = time.monotonic()
        return completion
