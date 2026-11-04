"""OpenAI Responses API for live tips and after-call jobs. No tools or saved responses."""
import json
import time
import urllib.error
import urllib.request

from .providers import Completion, Provider, take_piece, user_text

MODEL = "gpt-6-luna"                 # 0.9.0: the default when no job model is set (fast, like Haiku)
# Per job when Settings > AI does not say otherwise: tips like Haiku, preparation and after the call like Sonnet.
JOB_DEFAULTS = {"tips": "gpt-6-luna", "after": "gpt-6.1-sol", "prep": "gpt-6.1-sol"}


def effort_for(model):
    """0.9.1: the lowest reasoning effort a model accepts. The Sol and Astra models reject "none" (HTTP 400,
    reasoning.effort unsupported_value, checked 2026-11-04); Luna and Terra take it."""
    m = (model or "").lower()
    return "low" if ("-sol" in m or "-astra" in m) else "none"


def api_error(err):
    """A short, safe reason from an OpenAI error body: only the param and the code, never the message (it may echo
    the prompt). For example "reasoning.effort unsupported_value"."""
    try:
        e = json.loads(err.read().decode("utf-8", "replace")).get("error", {}) or {}
    except Exception:  # noqa: BLE001
        return ""
    parts = [str(e[k]) for k in ("param", "code") if isinstance(e.get(k), str) and len(e[k]) <= 60]
    return " ".join(parts)


def job_model(job=None, chosen=None):
    """The OpenAI model for a job: the PM's choice (Settings > AI), else the job default."""
    m = (chosen or "").strip()
    return m if m.startswith("gpt-") else JOB_DEFAULTS.get(job or "", MODEL)


def apply_event(c, event, on_text):
    """Consume text and terminal usage; incomplete/refused answers must never be accepted."""
    kind = event.get("type", "")
    if kind == "response.output_text.delta":
        take_piece(c, event.get("delta", ""), on_text)
    elif kind == "response.refusal.delta":
        c.error = "OpenAI: response refused"
    elif kind == "error":
        c.error = "OpenAI: " + str(event.get("code") or "stream error")
    elif kind in ("response.completed", "response.failed", "response.incomplete"):
        finish_event(c, event)


def finish_event(c, event):
    response = event.get("response") or {}
    apply_usage(c, response.get("usage") or {})
    c.stop_reason = event["type"]
    if c.stop_reason != "response.completed":
        code = (response.get("error") or {}).get("code") or c.stop_reason
        c.error = "OpenAI: " + str(code)
        c.incomplete = str((response.get("incomplete_details") or {}).get("reason") or "") or None


def apply_usage(c, usage):
    """Adds: a request asked again is billed for both answers."""
    cached = int((usage.get("input_tokens_details") or {}).get("cached_tokens") or 0)
    c.cache_read += cached
    c.input_tokens += max(0, int(usage.get("input_tokens") or 0) - cached)
    c.output_tokens += int(usage.get("output_tokens") or 0)
    c.reasoning_tokens += int((usage.get("output_tokens_details") or {}).get("reasoning_tokens") or 0)


# 0.9.2 (audit of a 04.11 call, rules/ai.yaml > openai): Luna closed the JSON and ran on (a second JSON, stray
# tokens in other scripts) until the output limit, so 14 of 98 classify and 3 of 24 tip answers came back
# "incomplete" and were thrown away (two early gists were retracted). A whole JSON object at the start is the
# answer; the rest is cut. Without one, the request is asked once more with a larger limit.
LONGER = 3                      # the output limit of the second request, times the first
LONGER_MAX = 2400


def json_prefix(text):
    """(the first complete JSON object at the start of `text`, the number of characters after it), or (None, 0)."""
    s = (text or "").lstrip()
    if not s.startswith("{"):
        return None, 0
    try:
        obj, end = json.JSONDecoder().raw_decode(s)
    except ValueError:
        return None, 0
    if not isinstance(obj, dict):
        return None, 0
    return s[:end], len(s[end:].strip())


def settle(c):
    """After a stream: keep a whole JSON answer cut by the output limit, note a tail after a complete one.
    True when the answer should be asked again with a larger limit."""
    head, tail = json_prefix(c.text)
    if c.error is None:
        c.tail = tail
        return False
    if c.incomplete != "max_output_tokens":
        return False
    if head is not None:
        c.text, c.tail, c.error = head, tail, None
        c.stop_reason = "json_prefix"
        return False
    return True


class OpenAIProvider(Provider):
    """One supported model keeps the cost guard accurate even when callers pass Claude model IDs."""
    name = "openai"

    def __init__(self, key, timeout=120.0, model=MODEL):
        self.key = key
        self.timeout = timeout
        self.model = model or MODEL

    def describe(self, model):
        return {"route": "openai", "model": model if isinstance(model, str) and model.startswith("gpt-") else self.model}

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        # callers pass Claude model ids (classify, tip, analysis); this provider always uses the job's OpenAI model
        use = model if isinstance(model, str) and model.startswith("gpt-") else self.model
        c = Completion(model=use, route="openai", t_start=time.monotonic())
        if not self.key:
            c.error = "OpenAI: no API key"
            c.t_done = time.monotonic()
            return c
        body = {"model": use, "instructions": "\n\n".join(b["text"] for b in system),
                "input": user_text(user), "max_output_tokens": max(16, int(max_tokens)),
                "reasoning": {"effort": effort_for(use)}, "stream": True, "store": False}
        effort_retried = False
        while True:
            req = urllib.request.Request("https://api.openai.com/v1/responses", data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json", "Authorization": "Bearer " + self.key})
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as response:
                    self._stream(c, response, on_text)
            except urllib.error.HTTPError as err:
                # Never the message or the body: they may echo the prompt or credentials; param and code only.
                why = api_error(err) if err.code == 400 else ""
                c.error = "OpenAI: HTTP " + str(err.code) + (" (" + why + ")" if why else "")
                # a newer model that rejects this effort: once more with "low"
                if not effort_retried and why.startswith("reasoning.effort") and body["reasoning"]["effort"] != "low":
                    effort_retried = True
                    body["reasoning"] = {"effort": "low"}
                    c.error = None
                    continue
                break
            except Exception as err:  # noqa: BLE001  return a completion on transport/callback failure
                c.error = "OpenAI: " + type(err).__name__
                break
            if settle(c) and c.retried is None:
                c.retried = "longer"
                body["max_output_tokens"] = min(LONGER_MAX, body["max_output_tokens"] * LONGER)
                c.text, c.error, c.stop_reason, c.incomplete = "", None, None, None
                continue
            break
        c.t_done = time.monotonic()
        return c

    @staticmethod
    def _stream(c, response, on_text):
        for raw in response:
            line = raw.decode("utf-8").strip()
            if line.startswith("data: ") and line != "data: [DONE]":
                apply_event(c, json.loads(line[6:]), on_text)
        if c.stop_reason != "response.completed" or not c.text:
            c.error = c.error or "OpenAI: incomplete or empty stream"
