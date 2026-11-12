"""0.10.0: the Tracker source (no file) is checked by collecting the open items; .jsonl files are readable text."""
import os, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from livetips_m0.sheet import sources as S, readers, tracker as TR


def test_tracker_without_path_is_ok(monkeypatch):
    tr = {"on_me": [{"text": "Send the estimate"}], "waiting": [], "folders": 1}
    monkeypatch.setattr(TR, "collect", lambda req, today: tr)
    monkeypatch.setattr(TR, "text", lambda t: "On me: Send the estimate")
    monkeypatch.setattr(TR, "title", lambda t: "Tracker: 1 on me, 0 waiting on others")
    texts = {}
    s = S.check({"id": "s-tracker", "type": "tracker", "title": "Tracker"}, {}, texts, "claude", {})
    assert s["access"] == "ok" and "Send the estimate" in texts["s-tracker"]


def test_tracker_empty_is_pending_not_unsupported(monkeypatch):
    monkeypatch.setattr(TR, "collect", lambda req, today: {"on_me": [], "waiting": [], "folders": 0})
    s = S.check({"id": "s-tracker", "type": "tracker"}, {}, {}, "claude", {})
    assert s["access"] == "pending" and "unknown source type" not in s.get("access_reason", "")


def test_jsonl_is_read():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "log.jsonl")
        open(p, "w").write('{"a": 1}\n{"b": 2}\n')
        r = readers.read(p)
        assert not r.get("error") and '"b": 2' in r["text"]
        assert readers.is_supported(p) if hasattr(readers, "is_supported") else True
