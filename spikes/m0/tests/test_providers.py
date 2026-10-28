"""AnthropicProvider and OpenAICompatProvider with fake transports: streaming, usage, errors."""
import json
import types

import pytest

from livetips_m0 import providers as P

S = types.SimpleNamespace


class Stream:
    def __init__(self, events, usage, stop="end_turn", boom=None):
        self.events, self.usage, self.stop, self.boom = events, usage, stop, boom

    def __enter__(self):
        if self.boom:
            raise self.boom
        return self

    def __exit__(self, *a):
        return False

    def __iter__(self):
        return iter(self.events)

    def get_final_message(self):
        return S(usage=self.usage, stop_reason=self.stop)


def delta(text, kind="text_delta"):
    return S(type="content_block_delta", delta=S(type=kind, text=text))


def anthropic(stream):
    p = P.AnthropicProvider.__new__(P.AnthropicProvider)
    p.client = S(messages=S(stream=lambda **kw: stream))
    return p


def test_anthropic_streams_text_and_reads_split_cache_usage():
    usage = S(input_tokens=10, output_tokens=5, cache_read_input_tokens=7,
              cache_creation=S(ephemeral_5m_input_tokens=3, ephemeral_1h_input_tokens=4))
    seen = []
    ev = [S(type="message_start"), delta('{"gist": "Hi'), delta("x", kind="other"), delta('", "level": "red"}')]
    c = anthropic(Stream(ev, usage)).complete(model="m", system=[{"text": "s"}], user="u", max_tokens=5,
                                              cache_ttl=None, on_text=seen.append)
    assert c.text == '{"gist": "Hi", "level": "red"}' and seen == ['{"gist": "Hi', c.text]
    assert c.t_first_token is not None and c.t_gist is not None and c.t_done is not None
    assert (c.input_tokens, c.output_tokens, c.cache_read, c.cache_write_5m, c.cache_write_1h) == (10, 5, 7, 3, 4)
    assert c.stop_reason == "end_turn" and c.error is None


@pytest.mark.parametrize("ttl,expect", [("1h", (0, 9)), ("5m", (9, 0)), (None, (9, 0))])
def test_anthropic_old_style_cache_usage_goes_by_ttl(ttl, expect):
    usage = S(input_tokens=None, output_tokens=None, cache_creation_input_tokens=9)
    c = anthropic(Stream([], usage)).complete(model="m", system=[], user="u", max_tokens=5, cache_ttl=ttl)
    assert (c.cache_write_5m, c.cache_write_1h) == expect and c.input_tokens == 0 and c.output_tokens == 0
    assert c.text == "" and c.t_first_token is None


def test_anthropic_error_is_a_completion():
    c = anthropic(Stream([], None, boom=RuntimeError("overloaded"))).complete(
        model="m", system=[], user="u", max_tokens=5, cache_ttl=None)
    assert c.error == "RuntimeError: overloaded" and c.t_done is not None


class Resp:
    def __init__(self, lines):
        self.lines = [l.encode() for l in lines]

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def __iter__(self):
        return iter(self.lines)


def test_openai_compat_stream(monkeypatch):
    sent = {}

    def urlopen(req, timeout):
        sent["url"], sent["body"], sent["headers"], sent["timeout"] = req.full_url, json.loads(req.data), dict(req.headers), timeout
        chunk = lambda content: "data: " + json.dumps({"choices": [{"delta": {"content": content}}]})  # noqa: E731
        return Resp([": ping", chunk('{"gist": "'), chunk(""), json.dumps({"x": 1}), chunk('ok"}'),
                     "data: " + json.dumps({"choices": [], "usage": {"prompt_tokens": 11, "completion_tokens": 3}}), "data: [DONE]"])
    monkeypatch.setattr(P.urllib.request, "urlopen", urlopen)
    seen = []
    p = P.OpenAICompatProvider("http://h/", api_key="k", timeout=9)
    c = p.complete(model="m", system=[{"text": "a"}, {"text": "b"}], user=[{"text": "U1"}, {"text": "U2"}],
                   max_tokens=7, cache_ttl="1h", on_text=seen.append)
    assert sent["url"] == "http://h/v1/chat/completions" and sent["timeout"] == 9
    assert sent["headers"]["Authorization"] == "Bearer k"
    assert sent["body"]["messages"][0]["content"] == "a\n\nb" and sent["body"]["max_tokens"] == 7
    assert c.text == '{"gist": "ok"}' and seen == ['{"gist": "', c.text] and c.t_gist is not None
    assert (c.input_tokens, c.output_tokens, c.error) == (11, 3, None)


def test_openai_compat_error_and_no_key(monkeypatch):
    def urlopen(req, timeout):
        assert "Authorization" not in dict(req.headers)
        raise OSError("refused")
    monkeypatch.setattr(P.urllib.request, "urlopen", urlopen)
    c = P.OpenAICompatProvider("http://h").complete(model="m", system=[], user="u", max_tokens=1, cache_ttl=None)
    assert c.error == "OSError: refused" and c.t_done is not None


def test_make_provider(monkeypatch):
    class FakeA:
        def __init__(self, key, workspace_id=""):
            self.key, self.ws = key, workspace_id
    monkeypatch.setattr(P, "AnthropicProvider", FakeA)
    secrets = {"CLAUDE_API": "k1", "WS": "w1", "OK": "k2"}

    def load(name):
        return secrets[name]
    a = P.make_provider({}, load)
    assert (a.key, a.ws) == ("k1", "")
    assert P.make_provider({"workspace_id_env": "WS"}, load).ws == "w1"
    assert P.make_provider({"workspace_id_env": "NONE"}, load).ws == ""
    assert P.make_provider({"workspace_id": "w0", "workspace_id_env": "WS"}, load).ws == "w0"
    o = P.make_provider({"provider": "openai_compat", "base_url": "http://x", "api_key_env": "OK"}, load)
    assert o.api_key == "k2" and P.make_provider({"provider": "openai_compat", "base_url": "http://x"}, load).api_key == ""
    with pytest.raises(ValueError):
        P.make_provider({"provider": "nope"}, load)


class Scripted(P.Provider):
    """Each call takes the next script entry: (delay_s, text or None for an error, raise?)."""

    def __init__(self, script):
        self.script, self.n = list(script), 0

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        import time
        delay, text, boom = self.script[self.n]
        self.n += 1
        if boom:
            raise RuntimeError("boom")
        c = P.Completion(model=model, t_start=time.monotonic())
        if text is not None and on_text:
            on_text(text)
            c.t_first_token = time.monotonic()
        time.sleep(delay)
        c.t_done = time.monotonic()
        if text is None:
            c.error = "Err: x"
        else:
            c.text = text
        return c


def ask(hp, **kw):
    return hp.complete(model="m", system=[], user="u", max_tokens=1, cache_ttl=None, **kw)


def test_hedge_off_and_both_failing():
    assert ask(P.HedgedProvider(Scripted([(0, "a", False)]), {})).text == "a"
    assert ask(P.HedgedProvider(Scripted([(0, "a", False)]), {"m": 0})).text == "a"
    c = ask(P.HedgedProvider(Scripted([(0, None, False), (0, None, True)]), {"m": 1.0}))
    assert c.error == "RuntimeError: boom"


def test_a_streaming_first_request_is_not_hedged_and_feeds_the_caller():
    seen, extra = [], []
    hp = P.HedgedProvider(Scripted([(0.3, "first", False)]), {"m": 0.05}, on_extra=extra.append)
    c = ask(hp, on_text=seen.append)
    assert c.text == "first" and c.hedge is None and seen == ["first"] and hp.stats["hedged"] == 0


def test_only_the_first_streamer_feeds_the_caller():
    import time
    seen, extra = [], []
    hp = P.HedgedProvider(Scripted([(0.4, None, False), (0.0, "late", False)]), {"m": 0.05}, on_extra=extra.append)
    race = P._Race(hp.inner, {"model": "m"}, seen.append)
    race.seen("hedge", "x")
    race.seen("primary", "y")
    assert seen == ["x"]
    c = ask(hp, on_text=seen.append)
    assert c.text == "late" and c.hedge == "hedge" and hp.stats["hedge_won"] == 1
    time.sleep(0.5)
    assert [x.error for x in extra] == ["Err: x"]


def test_bill_later_survives_a_failing_callback():
    import time
    race = P._Race(None, {"model": "m"}, None)
    race.results.put(("hedge", P.Completion()))
    calls = []

    def bad(c):
        calls.append(c)
        raise RuntimeError("x")
    race.bill_later(1, bad)
    time.sleep(0.1)
    assert len(calls) == 1
