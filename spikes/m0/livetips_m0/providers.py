"""LLM providers behind one small interface.

A provider streams one completion and reports timings and token usage. The app never depends
on a vendor SDK directly, so a local model (OpenAI-compatible server such as llama.cpp or
Ollama) or another vendor can be plugged in.
"""
import json
import queue
import threading
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
    hedge: Optional[str] = None   # None: one request; "primary" / "hedge": a second request ran, this one won

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
                 cache_ttl: Optional[str], on_text: Optional[Callable[[str], None]] = None,
                 extra: Optional[dict] = None) -> Completion:
        raise NotImplementedError


class AnthropicProvider(Provider):
    """Claude Messages API with streaming and prompt caching.

    `system` is a list of text blocks; blocks with "cache": True get a cache breakpoint
    (max 4 per request). `cache_ttl` is "5m" or "1h".
    """
    name = "anthropic"

    def __init__(self, api_key: str, timeout: float = 30.0, workspace_id: str = ""):
        import anthropic  # imported lazily so tests run without the SDK
        # Keys not scoped to a workspace must name one in the anthropic-workspace-id header.
        headers = {"anthropic-workspace-id": workspace_id} if workspace_id else None
        self.client = anthropic.Anthropic(api_key=api_key, timeout=timeout, max_retries=1, default_headers=headers)

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        blocks = []
        for b in system:
            blk = {"type": "text", "text": b["text"]}
            if b.get("cache") and cache_ttl:
                blk["cache_control"] = {"type": "ephemeral", "ttl": cache_ttl}
            blocks.append(blk)
        c = Completion(model=model, t_start=time.monotonic())
        try:
            with self.client.messages.stream(
                model=model, max_tokens=max_tokens, system=blocks,  # no temperature: deprecated on current models
                messages=[{"role": "user", "content": user}], **(extra or {}),
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

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
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

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        c = Completion(model=model, t_start=time.monotonic())
        self.calls.append({"model": model, "user": user})
        time.sleep(self.ttft)
        c.t_first_token = time.monotonic()
        c.text = self.responder(model, user)
        if on_text:
            on_text(c.text)
        if gist_closed(c.text):
            c.t_gist = time.monotonic()
        time.sleep(max(0.0, self.total - self.ttft))
        c.t_done = time.monotonic()
        c.input_tokens = 100
        c.output_tokens = len(c.text) // 4
        return c


class HedgedProvider(Provider):
    """M2: hedged requests against slow answers. When the first request shows no token after
    `after_s[model]` seconds, or fails fast (overload, network), a second identical request starts and
    the first good answer wins. The other request finishes in the background; it is billed, so its
    usage goes to `on_extra(completion)`. At most two requests per call."""
    name = "hedged"

    def __init__(self, inner: Provider, after_s: dict, default_after: Optional[float] = None,
                 on_extra: Optional[Callable[[Completion], None]] = None):
        self.inner = inner
        self.after_s = after_s
        self.default_after = default_after
        self.on_extra = on_extra
        self.stats = {"calls": 0, "hedged": 0, "hedge_won": 0}

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        after = self.after_s.get(model, self.default_after)
        self.stats["calls"] += 1
        if not after or after <= 0:
            return self.inner.complete(model=model, system=system, user=user, max_tokens=max_tokens,
                                       cache_ttl=cache_ttl, on_text=on_text, extra=extra)
        results: "queue.Queue" = queue.Queue()
        first_token = threading.Event()
        owner = {"tag": None}
        olock = threading.Lock()

        def run(tag):
            def seen(text):
                first_token.set()
                # Only the request that streamed first feeds the caller (a streamed gist on screen).
                with olock:
                    if owner["tag"] is None:
                        owner["tag"] = tag
                    mine = owner["tag"] == tag
                if mine and on_text:
                    on_text(text)
            try:
                c = self.inner.complete(model=model, system=system, user=user, max_tokens=max_tokens,
                                        cache_ttl=cache_ttl, on_text=seen, extra=extra)
            except Exception as e:  # noqa: BLE001  never leave the waiter hanging
                c = Completion(model=model, t_start=time.monotonic(), t_done=time.monotonic(),
                               error="{}: {}".format(type(e).__name__, str(e)[:200]))
            if c.t_first_token is not None:
                first_token.set()
            results.put((tag, c))

        def launch(tag):
            threading.Thread(target=run, args=(tag,), daemon=True).start()

        launch("primary")
        pending, hedged = 1, False
        try:
            tag, c = results.get(timeout=after)
            pending -= 1
            if not c.error:
                return c
            launch("hedge")                     # failed fast: one more try right away
            pending, hedged = 1, True
        except queue.Empty:
            if not first_token.is_set():
                launch("hedge")
                pending, hedged = 2, True
        if hedged:
            self.stats["hedged"] += 1
        winner, last = None, None
        while pending:
            tag, c = results.get()
            pending -= 1
            if not c.error:
                winner = c
                if hedged:
                    c.hedge = tag
                    if tag == "hedge":
                        self.stats["hedge_won"] += 1
                break
            last = c
        if pending and self.on_extra:
            def drain():
                for _ in range(pending):
                    _, rest = results.get()
                    try:
                        self.on_extra(rest)
                    except Exception:  # noqa: BLE001
                        pass
            threading.Thread(target=drain, daemon=True).start()
        return winner or last


def make_provider(cfg: dict, secret_loader: Callable[[str], str]) -> Provider:
    kind = cfg.get("provider", "anthropic")
    if kind == "anthropic":
        ws = cfg.get("workspace_id", "")
        if not ws and cfg.get("workspace_id_env"):
            try:
                ws = secret_loader(cfg["workspace_id_env"])
            except KeyError:
                ws = ""
        return AnthropicProvider(secret_loader(cfg.get("api_key_env", "CLAUDE_API")), workspace_id=ws)
    if kind == "openai_compat":
        key_env = cfg.get("api_key_env")
        return OpenAICompatProvider(cfg["base_url"], secret_loader(key_env) if key_env else "")
    raise ValueError("unknown provider: " + kind)
