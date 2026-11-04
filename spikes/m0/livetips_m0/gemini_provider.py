"""Gemini API for live tips and after-call jobs (0.9.3). The classic streamGenerateContent endpoint: stateless, so no
stored interactions, no saved responses, no cached-content objects, no tools and no files. The key goes in the
x-goog-api-key header (never in the URL, which logs keep). Only the paid tier is supported on purpose: Google uses
free-tier content to improve its products and not paid-tier content (ai.google.dev/gemini-api/docs/pricing,
checked 2026-11-04). Caching is implicit: a stable prefix of 4,096 tokens or more is read back at the cache rate
with no write charge, so the engine's "cache" marks are not sent."""
import json
import time
import urllib.error
import urllib.request

from .openai_provider import LONGER, LONGER_MAX, settle
from .providers import Completion, Provider, take_piece, user_text

MODEL = "gemini-3.5-flash-lite"      # the default when no job model is set (fast and cheap, like Haiku and Luna)
# Per job when Settings > AI does not say otherwise: tips like Haiku, preparation and after the call like Sonnet.
JOB_DEFAULTS = {"tips": "gemini-3.5-flash-lite", "after": "gemini-3.8-flash", "prep": "gemini-3.8-flash"}
URL = "https://generativelanguage.googleapis.com/v1beta/models/{}:streamGenerateContent?alt=sse"
# maxOutputTokens counts the thinking too, and these models cannot stop thinking: the engine's limits are for the answer,
# so a level gets room on top (only the tokens used are billed). Without it a 60-token classify could end in MAX_TOKENS
# with no answer at all. To be checked on the first real runs (tools/provider_bench.py: stop MAX_TOKENS, retried).
THINKING_ROOM = {"minimal": 128, "low": 512}


def thinking_level(model):
    """The lowest thinking level a model accepts: Flash-Lite has "minimal"; Flash and Argon start at "low"
    (ai.google.dev/gemini-api/docs/thinking, checked 2026-11-04). Thinking cannot be switched off for them."""
    return "minimal" if "flash-lite" in (model or "").lower() else "low"


def job_model(job=None, chosen=None):
    """The Gemini model for a job: the PM's choice (Settings > AI), else the job default."""
    m = (chosen or "").strip()
    return m if m.startswith("gemini-") else JOB_DEFAULTS.get(job or "", MODEL)


def api_error(err):
    """A short, safe reason from a Gemini error body: only the status and a string code, never the message (it may
    echo the prompt). For example "RESOURCE_EXHAUSTED" or "quota_exceeded"."""
    try:
        e = json.loads(err.read().decode("utf-8", "replace")).get("error", {}) or {}
    except Exception:  # noqa: BLE001
        return ""
    return " ".join(str(e[k]) for k in ("status", "code") if isinstance(e.get(k), str) and 0 < len(e[k]) <= 40)


def chunk_error(chunk):
    e = chunk.get("error") or {}
    why = " ".join(str(e[k]) for k in ("status", "code") if isinstance(e.get(k), str) and 0 < len(e[k]) <= 40)
    return "Gemini: " + (why or "stream error")


def apply_chunk(c, chunk, on_text):
    """One streamed chunk: text (thought parts skipped), the finish reason and a block. Returns the usage it carries."""
    if chunk.get("error"):
        c.error = chunk_error(chunk)
        return None
    block = (chunk.get("promptFeedback") or {}).get("blockReason")
    if block:
        c.error = "Gemini: blocked " + str(block)[:30]
    for cand in chunk.get("candidates") or []:
        for part in (cand.get("content") or {}).get("parts") or []:
            if part.get("thought"):
                continue
            if part.get("text"):
                take_piece(c, part["text"], on_text)
        if cand.get("finishReason"):
            c.stop_reason = str(cand["finishReason"])
    return chunk.get("usageMetadata") or None


def apply_usage(c, usage):
    """Adds: a request asked again is billed for both answers. promptTokenCount includes the cached part; thinking
    tokens are billed as output (candidatesTokenCount leaves them out), so they go into output_tokens too."""
    cached = int(usage.get("cachedContentTokenCount") or 0)
    thoughts = int(usage.get("thoughtsTokenCount") or 0)
    c.cache_read += cached
    c.input_tokens += max(0, int(usage.get("promptTokenCount") or 0) - cached)
    c.output_tokens += int(usage.get("candidatesTokenCount") or 0) + thoughts
    c.reasoning_tokens += thoughts


def finish(c):
    """Turns the finish reason into the state the engine knows: STOP is an answer, MAX_TOKENS is cut, the rest fail."""
    reason = c.stop_reason
    if c.error:
        return
    if reason == "MAX_TOKENS":
        c.incomplete = "max_output_tokens"
        c.error = "Gemini: MAX_TOKENS"
    elif reason is None:
        c.error = "Gemini: incomplete or empty stream"
    elif reason != "STOP":
        c.error = "Gemini: " + reason[:30]
    elif not c.text:
        c.error = "Gemini: empty answer"


class GeminiProvider(Provider):
    """One supported model per job keeps the cost guard accurate even when callers pass Claude model IDs."""
    name = "gemini"

    def __init__(self, key, timeout=120.0, model=MODEL):
        self.key = key
        self.timeout = timeout
        self.model = model or MODEL

    def describe(self, model):
        return {"route": "gemini", "model": model if isinstance(model, str) and model.startswith("gemini-") else self.model}

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        # callers pass Claude model ids (classify, tip, analysis); this provider always uses the job's Gemini model
        use = model if isinstance(model, str) and model.startswith("gemini-") else self.model
        c = Completion(model=use, route="gemini", t_start=time.monotonic())
        if not self.key:
            c.error = "Gemini: no API key"
            c.t_done = time.monotonic()
            return c
        level = thinking_level(use)
        body = {"systemInstruction": {"parts": [{"text": "\n\n".join(b["text"] for b in system)}]},
                "contents": [{"role": "user", "parts": [{"text": user_text(user)}]}],
                "generationConfig": {"maxOutputTokens": max(16, int(max_tokens)) + THINKING_ROOM.get(level, 0),
                                     "thinkingConfig": {"thinkingLevel": level}}}
        thinking_retried = False
        while True:
            req = urllib.request.Request(URL.format(use), data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json", "x-goog-api-key": self.key})
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as response:
                    self._stream(c, response, on_text)
            except urllib.error.HTTPError as err:
                # Never the message or the body: they may echo the prompt or credentials; status and code only.
                why = api_error(err)
                c.error = "Gemini: HTTP " + str(err.code) + (" (" + why + ")" if why else "")
                # a model that does not know the thinking setting: once more without it
                if not thinking_retried and err.code == 400 and "thinkingConfig" in body["generationConfig"]:
                    thinking_retried = True
                    del body["generationConfig"]["thinkingConfig"]
                    c.error = None
                    continue
                break
            except Exception as err:  # noqa: BLE001  return a completion on transport/callback failure
                c.error = "Gemini: " + type(err).__name__
                break
            if settle(c) and c.retried is None:
                c.retried = "longer"
                cfg = body["generationConfig"]
                cfg["maxOutputTokens"] = min(LONGER_MAX, cfg["maxOutputTokens"] * LONGER)
                c.text, c.error, c.stop_reason, c.incomplete = "", None, None, None
                continue
            break
        c.t_done = time.monotonic()
        return c

    @staticmethod
    def _stream(c, response, on_text):
        usage = None
        for raw in response:
            line = raw.decode("utf-8").strip()
            if line.startswith("data: ") and line != "data: [DONE]":
                usage = apply_chunk(c, json.loads(line[6:]), on_text) or usage     # usage is cumulative: keep the last
        if usage:
            apply_usage(c, usage)
        finish(c)
