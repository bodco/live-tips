"""2026-11-10 (owner, MinuteDesk KT #2): the model decides whether the project is searched and for what ("search"),
from the moment and the PM's intent; no rule on the PM's words."""
import time

from livetips_m0 import context
from test_engine import _meeting_engine


def _ask(tmp_path, monkeypatch, answer):
    proj = tmp_path / "proj"
    proj.mkdir()
    monkeypatch.setattr(context, "index_snippets", lambda *a, **k: [])

    class Prep:
        def complete(self, **kw):
            from livetips_m0.providers import Completion
            c = Completion(model=kw["model"])
            c.text = answer
            return c
    eng, _ = _meeting_engine(tmp_path, lambda m, u: '{"queries": ["x"]}' if "Question:" in u else '{"skip": true}',
                             project_root=str(proj), lt_cmd=["lt"], ai={"routes": {"prep": "openai", "tips": "openai"}},
                             deep_lookup=True)
    eng._prepp = Prep()
    started = []
    eng._start_deep = lambda q, kind: started.append((q, kind))
    eng.on_request("ask", "давай мені по К2")
    end = time.monotonic() + 5
    while time.monotonic() < end and any(not f.done() for f in eng.futures):
        time.sleep(0.01)
    return started


def test_answered_with_a_search_digs_quietly(tmp_path, monkeypatch):
    started = _ask(tmp_path, monkeypatch, '{"gist": "KT #2: functions and docs", "answered": true, "level": "info", '
                   '"topic": "kt", "search": "questions about app functionality for KT #2, QA findings"}')
    assert started == [("давай мені по К2 | questions about app functionality for KT #2, QA findings", "quiet")]


def test_answered_without_a_search_does_not_dig(tmp_path, monkeypatch):
    assert _ask(tmp_path, monkeypatch, '{"gist": "Tuesday", "answered": true, "level": "info", "topic": "x"}') == []


def test_unanswered_digs_with_the_model_query(tmp_path, monkeypatch):
    started = _ask(tmp_path, monkeypatch, '{"gist": "?", "answered": false, "level": "info", "topic": "x", "search": "KT checklist"}')
    assert started == [("давай мені по К2 | KT checklist", "ask")]
