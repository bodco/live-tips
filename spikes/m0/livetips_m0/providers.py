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
from dataclasses import dataclass
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
    route: str = "api"            # 0.8.2: "api" (the key) or "code" (Claude Code on the PM's account)
    equiv_usd: Optional[float] = None   # Claude Code: what the request would cost on the API (not billed to the key)
    switched_from: Optional[str] = None # auto-switch: the route that was out
    usd: Optional[float] = None   # what the engine counted against the budget (set by Engine._bill)

    def ms(self, t):
        return None if t is None else round((t - self.t_start) * 1000)


def user_text(user) -> str:
    """The request as one text. 0.8.3: `user` is a string or a list of blocks {"text", "cache"?}; providers
    without prompt caching read the blocks in order."""
    return user if isinstance(user, str) else "".join(b["text"] for b in user)


def user_content(user):
    """The Messages API content of the request: blocks with "cache" ("5m" or "1h") get a cache breakpoint."""
    if isinstance(user, str):
        return user
    out = []
    for b in user:
        blk = {"type": "text", "text": b["text"]}
        if b.get("cache"):
            blk["cache_control"] = {"type": "ephemeral", "ttl": b["cache"]}
        out.append(blk)
    return out


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


def take_piece(c: "Completion", piece: str, on_text) -> None:
    """One streamed piece of text: first-token and gist times, then the caller sees the buffer."""
    if c.t_first_token is None:
        c.t_first_token = time.monotonic()
    c.text += piece
    if c.t_gist is None and gist_closed(c.text):
        c.t_gist = time.monotonic()
    if on_text:
        on_text(c.text)


def failed(c: "Completion", e: Exception) -> None:
    c.t_done = time.monotonic()
    c.error = "{}: {}".format(type(e).__name__, str(e)[:200])


def system_blocks(system: List[dict], cache_ttl: Optional[str]) -> List[dict]:
    """Messages API system blocks; blocks marked "cache" get a breakpoint with the request's TTL."""
    blocks = []
    for b in system:
        blk = {"type": "text", "text": b["text"]}
        if b.get("cache") and cache_ttl:
            blk["cache_control"] = {"type": "ephemeral", "ttl": cache_ttl}
        blocks.append(blk)
    return blocks


def read_usage(c: "Completion", u, cache_ttl: Optional[str]) -> None:
    """Token counts of a finished message; cache writes split by TTL (old SDKs report one total)."""
    c.input_tokens = u.input_tokens or 0
    c.output_tokens = u.output_tokens or 0
    c.cache_read = getattr(u, "cache_read_input_tokens", 0) or 0
    cc = getattr(u, "cache_creation", None)
    if cc is not None:
        c.cache_write_5m = getattr(cc, "ephemeral_5m_input_tokens", 0) or 0
        c.cache_write_1h = getattr(cc, "ephemeral_1h_input_tokens", 0) or 0
        return
    w = getattr(u, "cache_creation_input_tokens", 0) or 0
    if cache_ttl == "1h":
        c.cache_write_1h = w
    else:
        c.cache_write_5m = w


def sse_chunks(lines):
    """JSON chunks of an OpenAI-style server-sent event stream."""
    for raw in lines:
        line = raw.decode("utf-8", "replace").strip()
        if line.startswith("data:") and line != "data: [DONE]":
            yield json.loads(line[5:])


def take_chunk(c: "Completion", ch: dict, on_text) -> None:
    for choice in ch.get("choices") or []:
        piece = (choice.get("delta") or {}).get("content") or ""
        if piece:
            take_piece(c, piece, on_text)
    if ch.get("usage"):
        c.input_tokens = ch["usage"].get("prompt_tokens", 0)
        c.output_tokens = ch["usage"].get("completion_tokens", 0)


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

    # 0.8.5 (owner: "Write draft" failed with 400): models differ in how thinking is turned off. Sonnet 5.5 refuses
    # "disabled" and asks for "between_tools"; Haiku 5.5 refuses "between_tools". On such a 400 the request goes once
    # more with the other form, and the model keeps that form for the rest of the session.
    thinking_form: dict = {}          # model -> "disabled" | "between_tools"
    no_disabled: set = set()          # kept for older callers and tests

    @staticmethod
    def _thinking_as(extra, form: Optional[str]):
        """form: "disabled", "between_tools" or "adaptive_low" (Opus 5.5 takes only adaptive thinking, at low effort)."""
        if not extra or not form:
            return extra
        def fix(d):
            t = d.get("thinking") if isinstance(d, dict) else None
            if isinstance(t, dict) and t.get("type") in ("disabled", "between_tools", "adaptive"):
                if form == "adaptive_low":
                    d = dict(d, thinking={"type": "adaptive"}, output_config={"effort": "low"})
                else:
                    d = {k: v for k, v in d.items() if k != "output_config"}
                    d["thinking"] = {"type": form}
            return d
        out = fix(dict(extra))
        if isinstance(out.get("extra_body"), dict):
            out["extra_body"] = fix(out["extra_body"])
        return out

    @staticmethod
    def _thinking_off(extra, use_between: bool):
        return AnthropicProvider._thinking_as(extra, "between_tools" if use_between else None)

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        form = self.thinking_form.get(model) or ("between_tools" if model in self.no_disabled else None)
        c = self._complete(model=model, system=system, user=user, max_tokens=max_tokens, cache_ttl=cache_ttl, on_text=on_text,
                           extra=self._thinking_as(extra, form))
        tried = {form}
        for _ in range(2):
            err = str(c.error or "")
            if not (c.error and c.text == "" and "thinking" in err):
                break
            if "adaptive" in err:
                other = "adaptive_low"
            elif "between_tools" in err and "not supported" in err:
                other = "disabled"
            elif "between_tools" in err:
                other = "between_tools"
            else:
                break
            if other in tried:
                break
            tried.add(other)
            AnthropicProvider.thinking_form[model] = other
            if other == "between_tools":
                AnthropicProvider.no_disabled.add(model)
            c = self._complete(model=model, system=system, user=user, max_tokens=max_tokens, cache_ttl=cache_ttl,
                               on_text=on_text, extra=self._thinking_as(extra, other))
        return c

    def _complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        c = Completion(model=model, t_start=time.monotonic())
        try:
            with self.client.messages.stream(
                model=model, max_tokens=max_tokens, system=system_blocks(system, cache_ttl),  # no temperature: deprecated
                messages=[{"role": "user", "content": user_content(user)}], **(extra or {}),
            ) as stream:
                for ev in stream:
                    if ev.type == "content_block_delta" and getattr(ev.delta, "type", "") == "text_delta":
                        take_piece(c, ev.delta.text, on_text)
                msg = stream.get_final_message()
            c.t_done = time.monotonic()
            read_usage(c, msg.usage, cache_ttl)
            c.stop_reason = msg.stop_reason
        except Exception as e:  # network, rate limit, overload: the caller degrades to local only
            failed(c, e)
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
        c = Completion(model=model, t_start=time.monotonic())
        try:
            with urllib.request.urlopen(self._request(model, system, user, max_tokens), timeout=self.timeout) as r:
                for ch in sse_chunks(r):
                    take_chunk(c, ch, on_text)
            c.t_done = time.monotonic()
        except Exception as e:
            failed(c, e)
        return c

    def _request(self, model, system, user, max_tokens) -> urllib.request.Request:
        body = {
            "model": model, "max_tokens": max_tokens, "temperature": 0, "stream": True,
            "stream_options": {"include_usage": True},
            "messages": [{"role": "system", "content": "\n\n".join(b["text"] for b in system)},
                         {"role": "user", "content": user_text(user)}],
        }
        return urllib.request.Request(self.base_url + "/v1/chat/completions", data=json.dumps(body).encode(),
                                      headers={"Content-Type": "application/json",
                                               **({"Authorization": "Bearer " + self.api_key} if self.api_key else {})})


class OllamaProvider(Provider):
    """0.8.5 (rules/ai.yaml > routes.local): a model on this Mac through Ollama's own /api/chat, so the context
    length can be set (the OpenAI-compatible endpoint keeps Ollama's small default). Free; usage from the last chunk."""
    name = "ollama"

    def __init__(self, base_url: str = "http://127.0.0.1:11434", num_ctx: int = 65536, timeout: float = 1800.0):
        self.base_url = base_url.rstrip("/")
        self.num_ctx = num_ctx
        self.timeout = timeout

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        c = Completion(model=model, t_start=time.monotonic())
        body = {"model": model, "stream": True, "keep_alive": "5m", "think": False,   # Gemma 4 thinks by default
                "options": {"num_ctx": self.num_ctx, "num_predict": max(256, int(max_tokens) * 2), "temperature": 0.2},
                "messages": [{"role": "system", "content": "\n\n".join(b["text"] for b in system)},
                             {"role": "user", "content": user_text(user)}]}
        req = urllib.request.Request(self.base_url + "/api/chat", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                for raw in r:
                    if not raw.strip():
                        continue
                    ev = json.loads(raw)
                    if ev.get("error"):
                        raise RuntimeError(ev["error"])
                    piece = (ev.get("message") or {}).get("content") or ""
                    if piece:
                        take_piece(c, piece, on_text)
                    if ev.get("done"):
                        c.input_tokens = int(ev.get("prompt_eval_count") or 0)
                        c.output_tokens = int(ev.get("eval_count") or 0)
            c.t_done = time.monotonic()
        except Exception as e:  # noqa: BLE001
            failed(c, e)
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
        user = user_text(user)
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
        args = dict(model=model, system=system, user=user, max_tokens=max_tokens, cache_ttl=cache_ttl, extra=extra)
        if not (after and after > 0):
            return self.inner.complete(on_text=on_text, **args)
        return self._race(_Race(self.inner, args, on_text), after)

    def _race(self, race: "_Race", after: float) -> Completion:
        race.launch("primary")
        early, pending, hedged = race.first(after)
        if early is not None:
            return early
        if hedged:
            self.stats["hedged"] += 1
        winner, last, pending = race.wait(pending)
        if winner is not None and hedged:
            self._tag(winner, race.winner_tag)
        if pending and self.on_extra:
            race.bill_later(pending, self.on_extra)
        return winner or last

    def _tag(self, winner: Completion, tag: str) -> None:
        winner.hedge = tag
        if tag == "hedge":
            self.stats["hedge_won"] += 1


class _Race:
    """Up to two identical requests; only the one that streamed first feeds the caller's on_text."""

    def __init__(self, inner: Provider, args: dict, on_text):
        self.inner, self.args, self.on_text = inner, args, on_text
        self.results: "queue.Queue" = queue.Queue()
        self.first_token = threading.Event()
        self.owner: Optional[str] = None
        self.olock = threading.Lock()
        self.winner_tag: Optional[str] = None

    def seen(self, tag: str, text: str) -> None:
        self.first_token.set()
        with self.olock:            # only the request that streamed first feeds the caller (a gist on screen)
            if self.owner is None:
                self.owner = tag
            mine = self.owner == tag
        if mine and self.on_text:
            self.on_text(text)

    def run(self, tag: str) -> None:
        try:
            c = self.inner.complete(on_text=lambda text: self.seen(tag, text), **self.args)
        except Exception as e:  # noqa: BLE001  never leave the waiter hanging
            c = Completion(model=self.args["model"], t_start=time.monotonic(), t_done=time.monotonic(),
                           error="{}: {}".format(type(e).__name__, str(e)[:200]))
        if c.t_first_token is not None:
            self.first_token.set()
        self.results.put((tag, c))

    def launch(self, tag: str) -> None:
        threading.Thread(target=self.run, args=(tag,), daemon=True).start()

    def first(self, after: float):
        """(an early good answer, or None; requests still running; whether a hedge started)."""
        try:
            _, c = self.results.get(timeout=after)
        except queue.Empty:
            if self.first_token.is_set():
                return None, 1, False
            self.launch("hedge")
            return None, 2, True
        if not c.error:
            return c, 0, False
        self.launch("hedge")                     # failed fast: one more try right away
        return None, 1, True

    def wait(self, pending: int):
        """The first good answer (or the last failure) and how many requests are still running."""
        last = None
        while pending:
            tag, c = self.results.get()
            pending -= 1
            if not c.error:
                self.winner_tag = tag
                return c, last, pending
            last = c
        return None, last, pending

    def bill_later(self, pending: int, on_extra) -> None:
        def drain():
            for _ in range(pending):
                _, rest = self.results.get()
                try:
                    on_extra(rest)
                except Exception:  # noqa: BLE001
                    pass
        threading.Thread(target=drain, daemon=True).start()


def make_provider(cfg: dict, secret_loader: Callable[[str], str], job: Optional[str] = None) -> Provider:
    if cfg.get("ai"):   # 0.8.2: the app's AI routes (the key or Claude Code, with auto-switch)
        from .routing import provider_from_cfg
        return provider_from_cfg(cfg, secret_loader, job)
    kind = cfg.get("provider", "anthropic")
    if kind == "anthropic":
        ws = cfg.get("workspace_id", "")
        if not ws and cfg.get("workspace_id_env"):
            try:
                ws = secret_loader(cfg["workspace_id_env"])
            except KeyError:
                ws = ""
        return AnthropicProvider(secret_loader(cfg.get("api_key_env", "CLAUDE_API")), workspace_id=ws)
    if kind == "ollama":   # 0.8.5: a model on this Mac (rules/ai.yaml > routes.local)
        return OllamaProvider(cfg.get("base_url", "http://127.0.0.1:11434"))
    if kind == "openai_compat":
        key_env = cfg.get("api_key_env")
        return OpenAICompatProvider(cfg["base_url"], secret_loader(key_env) if key_env else "")
    raise ValueError("unknown provider: " + kind)
