"""OpenAI Responses API for live tips and after-call jobs. No tools or saved responses."""
import json
import time
import urllib.error
import urllib.request

from .providers import Completion, Provider, take_piece, user_text

MODEL = "gpt-5.4-mini"


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


def apply_usage(c, usage):
    c.cache_read = int((usage.get("input_tokens_details") or {}).get("cached_tokens") or 0)
    c.input_tokens = max(0, int(usage.get("input_tokens") or 0) - c.cache_read)
    c.output_tokens = int(usage.get("output_tokens") or 0)


class OpenAIProvider(Provider):
    """One supported model keeps the cost guard accurate even when callers pass Claude model IDs."""
    name = "openai"

    def __init__(self, key, timeout=120.0):
        self.key = key
        self.timeout = timeout

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        c = Completion(model=MODEL, route="openai", t_start=time.monotonic())
        if not self.key:
            c.error = "OpenAI: no API key"
            c.t_done = time.monotonic()
            return c
        body = {"model": MODEL, "instructions": "\n\n".join(b["text"] for b in system),
                "input": user_text(user), "max_output_tokens": max(16, int(max_tokens)),
                "reasoning": {"effort": "none"}, "stream": True, "store": False}
        req = urllib.request.Request("https://api.openai.com/v1/responses", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + self.key})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as response:
                self._stream(c, response, on_text)
        except urllib.error.HTTPError as err:
            # Do not log response bodies: they may echo the prompt or credentials.
            c.error = "OpenAI: HTTP " + str(err.code)
        except Exception as err:  # noqa: BLE001  return a completion on transport/callback failure
            c.error = "OpenAI: " + type(err).__name__
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
