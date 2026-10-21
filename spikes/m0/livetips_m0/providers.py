"""LLM providers behind one small interface.

A provider streams one completion and reports timings and token usage. The app never depends
on a vendor SDK directly, so a local model (OpenAI-compatible server such as llama.cpp or
Ollama) or another vendor can be plugged in.
"""
import json
import time
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, List, Optional


@dataclass
class Completion:
    text: str = ""
    model: str = ""
    t_start: float = 0.0          # monotonic
    t_first_token: Optional[float] = None
    t_gist: Optional[float] = None
    t_done: Optional[float] = None
    input_tokens: int = 0
    cache_read: int = 0
    cache_write_5m: int = 0
    cache_write_1h: int = 0
    output_tokens: int = 0
    error: Optional[str] = None
    stop_reason: Optional[str] = None

    def ms(self, t):
        return None if t is None else round((t - self.t_start) * 1000)


def gist_closed(buf: str) -> bool:
    """True once the JSON value of "gist" is complete in a streaming buffer."""
    i = buf.find('"gist"')
    if i < 0:
        return False
    j = buf.find('"', buf.find(":", i) + 1)
    if j < 0:
        return False
    k = j + 1
    while k < len(buf):
        if buf[k] == "\\":
            k += 2
            continue
        if buf[k] == '"':
            return True
        k += 1
    return False


class Provider:
    name = "base"

    def complete(self, *, model: str, system: List[dict], user: str, max_tokens: int,
                 cache_ttl: Optional[str], on_text: Optional[Callable[[str], None]] = None) -> Completion:
        raise NotImplementedError


class AnthropicProvider(Provider):
    """Claude Messages API with streaming and prompt caching.

    `system` is a list of text blocks; blocks with "cache": True get a cache breakpoint
    (max 4 per request). `cache_ttl` is "5m" or "1h".
    """
    name = "anthropic"

    def __init__(self, api_key: str, timeout: float = 30.0):
        import anthropic  # imported lazily so tests run without the SDK
        self.client = anthropic.Anthropic(api_key=api_key, timeout=timeout, max_retries=1)

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None):
        blocks = []
        for b in system:
            blk = {"type": "text", "text": b["text"]}
            if b.get("cache") and cache_ttl:
                blk["cache_control"] = {"type": "ephemeral", "ttl": cache_ttl}
            blocks.append(blk)
        c = Completion(model=model, t_start=time.monotonic())
        try:
            with self.client.messages.stream(
                model=model, max_tokens=max_tokens, temperature=0, system=blocks,
                messages=[{"role": "user", "content": user}],
            ) as stream:
                for ev in stream:
                    if ev.type == "content_block_delta" and getattr(ev.delta, "type", "") == "text_delta":
                        if c.t_first_token is None:
                            c.t_first_token = time.monotonic()
                        c.text += ev.delta.text
                        if c.t_gist is None and gist_closed(c.text):
                            c.t_gist = time.monotonic()
                        if on_text:
                            on_text(c.text)
                msg = stream.get_final_message()
            c.t_done = time.monotonic()
            u = msg.usage
            c.input_tokens = u.input_tokens or 0
            c.cache_read = getattr(u, "cache_read_input_tokens", 0) or 0
            cc = getattr(u, "cache_creation", None)
            if cc is not None:
                c.cache_write_5m = getattr(cc, "ephemeral_5m_input_tokens", 0) or 0
                c.cache_write_1h = getattr(cc, "ephemeral_1h_input_tokens", 0) or 0
            else:
                w = getattr(u, "cache_creation_input_tokens", 0) or 0
                if cache_ttl == "1h":
                    c.cache_write_1h = w
                else:
                    c.cache_write_5m = w
            c.output_tokens = u.output_tokens or 0
            c.stop_reason = msg.stop_reason
        except Exception as e:  # network, rate limit, overload: the caller degrades to local only
            c.t_done = time.monotonic()
            c.error = "{}: {}".format(type(e).__name__, str(e)[:200])
        return c


class OpenAICompatProvider(Provider):
    """Any OpenAI-compatible /v1/chat/completions endpoint (llama.cpp server, Ollama, vLLM).
    No prompt caching control; usage is taken from the final chunk when the server sends it.
    Status in M0: implemented, not measured."""
    name = "openai_compat"

    def __init__(self, base_url: str, api_key: str = "", timeout: float = 60.0):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None):
        body = {
            "model": model, "max_tokens": max_tokens, "temperature": 0, "stream": True,
            "stream_options": {"include_usage": True},
            "messages": [{"role": "system", "content": "\n\n".join(b["text"] for b in system)},
                         {"role": "user", "content": user}],
        }
        req = urllib.request.Request(self.base_url + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json",
                                              **({"Authorization": "Bearer " + self.api_key} if self.api_key else {})})
        c = Completion(model=model, t_start=time.monotonic())
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                for raw in r:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:") or line == "data: [DONE]":
                        continue
                    ch = json.loads(line[5:])
                    for choice in ch.get("choices") or []:
                        piece = (choice.get("delta") or {}).get("content") or ""
                        if piece:
                            if c.t_first_token is None:
                                c.t_first_token = time.monotonic()
                            c.text += piece
                            if c.t_gist is None and gist_closed(c.text):
                                c.t_gist = time.monotonic()
                            if on_text:
                                on_text(c.text)
                    if ch.get("usage"):
                        c.input_tokens = ch["usage"].get("prompt_tokens", 0)
                        c.output_tokens = ch["usage"].get("completion_tokens", 0)
            c.t_done = time.monotonic()
        except Exception as e:
            c.t_done = time.monotonic()
            c.error = "{}: {}".format(type(e).__name__, str(e)[:200])
        return c


class FakeProvider(Provider):
    """Deterministic provider for tests and dry runs."""
    name = "fake"

    def __init__(self, responder: Callable[[str, str], str], ttft: float = 0.0, total: float = 0.0):
        self.responder = responder
        self.ttft = ttft
        self.total = total
        self.calls = []

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None):
        c = Completion(model=model, t_start=time.monotonic())
        self.calls.append({"model": model, "user": user})
        time.sleep(self.ttft)
        c.t_first_token = time.monotonic()
        c.text = self.responder(model, user)
        if gist_closed(c.text):
            c.t_gist = time.monotonic()
        time.sleep(max(0.0, self.total - self.ttft))
        c.t_done = time.monotonic()
        c.input_tokens = 100
        c.output_tokens = len(c.text) // 4
        return c


def make_provider(cfg: dict, secret_loader: Callable[[str], str]) -> Provider:
    kind = cfg.get("provider", "anthropic")
    if kind == "anthropic":
        return AnthropicProvider(secret_loader(cfg.get("api_key_env", "CLAUDE_API")))
    if kind == "openai_compat":
        key_env = cfg.get("api_key_env")
        return OpenAICompatProvider(cfg["base_url"], secret_loader(key_env) if key_env else "")
    raise ValueError("unknown provider: " + kind)
