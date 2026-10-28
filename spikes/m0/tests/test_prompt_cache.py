"""0.8.3: the older part of the call is a cached prefix of the request (prompt caching).

The request starts with what does not change between calls: the system blocks (rules, brief, facts; cached
for 1 h), then the earlier lines of the call, cut at a fixed 2-minute boundary (cached for 5 min), then what
changes every time: the state, the live transcript and the task.
"""
import types

from livetips_m0.engine import context_windows
from livetips_m0.prompt import PromptBuilder
from livetips_m0.providers import AnthropicProvider, FakeProvider, user_text
from livetips_m0.rules import Rules


def L(t_s, text="x"):
    return types.SimpleNamespace(t_s=t_s, text=text)


def test_earlier_window_is_the_same_for_every_line_in_one_bucket():
    lines = [L(t) for t in range(0, 1200, 10)]
    a_earlier, a_tail = context_windows(lines, end=845, span=240, bucket=120)
    b_earlier, b_tail = context_windows(lines, end=900, span=240, bucket=120)
    assert [l.t_s for l in a_earlier] == [l.t_s for l in b_earlier]
    assert a_earlier and a_tail and b_tail


def test_earlier_and_tail_cover_the_window_without_gap_or_overlap():
    lines = [L(t) for t in range(0, 1200, 10)]
    earlier, tail = context_windows(lines, end=845, span=240, bucket=120)
    ts = [l.t_s for l in earlier] + [l.t_s for l in tail]
    assert ts == sorted(set(ts))
    assert ts[-1] == 840 and tail[0].t_s == earlier[-1].t_s + 10
    assert 845 - tail[0].t_s <= 90 + 120          # the live part is at most 90 s plus one bucket
    assert all(l.t_s <= 845 for l in tail)


def test_early_in_the_call_there_is_no_earlier_window():
    lines = [L(t) for t in range(0, 60, 10)]
    earlier, tail = context_windows(lines, end=50, span=240, bucket=120)
    assert earlier == [] and [l.t_s for l in tail] == [0, 10, 20, 30, 40, 50]


def _pb():
    return PromptBuilder(Rules(), {"title": "t", "tips_lang": "en", "langs": ["en"]})


def test_user_message_puts_the_earlier_lines_first_as_a_cached_block():
    u = _pb().user("tip", "your_turn", ["[10:00:00] Other: now"], {"now": "10:00:00"}, ["[09:55:00] Other: before"])
    assert isinstance(u, list) and len(u) == 2
    assert u[0]["cache"] == "5m" and "before" in u[0]["text"] and "STATE" not in u[0]["text"]
    assert "STATE" in u[1]["text"] and "now" in u[1]["text"] and "before" not in u[1]["text"]


def test_user_message_without_earlier_lines_is_plain_text():
    u = _pb().user("classify", "", ["[10:00:00] Other: hi"], {"now": "10:00:00"}, [])
    assert isinstance(u, str) and "hi" in u


def test_other_providers_read_the_blocks_as_one_text():
    seen = {}
    fp = FakeProvider(lambda m, u: seen.setdefault("u", u) or "{}")
    fp.complete(model="m", system=[], user=[{"text": "A", "cache": "5m"}, {"text": "B"}], max_tokens=5, cache_ttl=None)
    assert seen["u"] == "AB" and user_text("plain") == "plain"


class _Stream:
    def __init__(self, sink, kw):
        sink.update(kw)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def __iter__(self):
        return iter(())

    def get_final_message(self):
        u = types.SimpleNamespace(input_tokens=1, output_tokens=1, cache_read_input_tokens=0, cache_creation=None,
                                  cache_creation_input_tokens=0)
        return types.SimpleNamespace(usage=u, stop_reason="end_turn")


def test_anthropic_request_marks_the_earlier_block_for_the_cache():
    sink = {}
    p = AnthropicProvider.__new__(AnthropicProvider)
    p.client = types.SimpleNamespace(messages=types.SimpleNamespace(stream=lambda **kw: _Stream(sink, kw)))
    c = p.complete(model="m", system=[{"text": "rules", "cache": True}],
                   user=[{"text": "EARLIER", "cache": "5m"}, {"text": "NOW"}], max_tokens=5, cache_ttl="1h")
    assert not c.error
    content = sink["messages"][0]["content"]
    assert content[0] == {"type": "text", "text": "EARLIER", "cache_control": {"type": "ephemeral", "ttl": "5m"}}
    assert content[1] == {"type": "text", "text": "NOW"}
    assert sink["system"][0]["cache_control"] == {"type": "ephemeral", "ttl": "1h"}
