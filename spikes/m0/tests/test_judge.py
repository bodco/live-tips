import json

from livetips_m0 import judge
from livetips_m0.providers import FakeProvider


def _ok(model, user):
    return json.dumps({"score": 4, "timely": True, "concrete": True, "reason": "fine"})


def _call(tmp_path, n_lines=40):
    md = tmp_path / "call.md"
    rows = ["# Live transcript: call", ""]
    for i in range(n_lines):
        rows.append("[10:{:02d}:{:02d}] {} (en): line {}".format(i // 60, i % 60 * 1, "Me" if i % 2 else "Other", i))
    md.write_text("\n".join(rows) + "\n", encoding="utf-8")
    cfg = tmp_path / "cfg.json"
    cfg.write_text(json.dumps({"me_label": "Me", "provider": "fake"}))
    return md, cfg


def _tip(i, **kw):
    t = "10:00:{:02d}".format(i % 60)
    d = {"engine": "app", "kind": "tip", "uid": "u{}".format(i), "src": t, "at": t, "gist": "g{}".format(i), "phrase": "p"}
    d.update(kw)
    return d


def _write(path, recs):
    path.write_text("\n".join(json.dumps(r) for r in recs) + "\n", encoding="utf-8")


def test_partial_and_retract_are_skipped(tmp_path):
    md, cfg = _call(tmp_path)
    tips = tmp_path / "app.tips.jsonl"
    _write(tips, [_tip(1), _tip(2, partial=True), _tip(3), {"engine": "app", "kind": "retract", "uid": "u3"},
                  {"engine": "app", "kind": "retract", "uid": "u9"}, _tip(4, kind="outline_pos")])
    prov = FakeProvider(_ok)
    s = judge.main(["--config", str(cfg), "--md", str(md), "--app-tips", str(tips)], provider=prov)
    assert len(prov.calls) == 1 and "g1" in prov.calls[0]["user"]
    assert s["app"]["n"] == 1 and s["app"]["mean"] == 4
    assert (tmp_path / "call.judge" / "judge.summary.json").exists()       # default --out


def test_quick_caps_at_25_and_uses_sonnet(tmp_path):
    md, cfg = _call(tmp_path, n_lines=60)
    tips = tmp_path / "app.tips.jsonl"
    _write(tips, [_tip(i) for i in range(60)])
    _write(tmp_path / "call.tips.jsonl", [_tip(i, engine="skill", uid="s{}".format(i)) for i in range(30)])
    prov = FakeProvider(_ok)
    s = judge.main(["--config", str(cfg), "--md", str(md), "--app-tips", str(tips), "--quick",
                    "--out", str(tmp_path / "j")], provider=prov)
    assert len(prov.calls) == 25
    assert {c["model"] for c in prov.calls} == {judge.QUICK_MODEL}
    assert s["app"]["n"] > 0 and s["skill"]["n"] > 0 and s["meta"]["judged"] == 25


def test_presentation_rubric_has_plan(tmp_path):
    slides = tmp_path / "slides.json"
    slides.write_text(json.dumps({"slides": [{"n": 1, "title": "Intro", "who": "me", "sec": 40},
                                             {"n": 2, "title": "Pricing", "who": "colleague", "sec": 90}]}))
    text = judge.system_prompt("presentation", judge.load_slides(slides))
    assert "1 | Intro | me | 40" in text and "2 | Pricing | colleague | 90" in text
    assert "Silence while the PM presents is correct" in text
    assert "role: Backend" in judge.system_prompt("interview", role="Backend")
    assert judge.system_prompt("auto") == judge.SYSTEM


def test_worst_reasons_in_summary():
    recs = [{"engine": "app", "score": s, "gist": "g", "reason": "r{}".format(s)} for s in (1, 2, 5, 3, 4)]
    s = judge.summarize(recs)
    assert s["app"]["worst"][0].startswith("1 ") and len(s["app"]["worst"]) == 3
