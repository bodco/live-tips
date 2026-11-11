"""0.9.7 (owner, case of 11.11): the preparation's context by priority, compressed instead of cut, and a manifest."""
import json
import os

from livetips_m0 import codexprep, localprep, prepcontext as pc
from livetips_m0.providers import Completion


def project(tmp_path):
    root = tmp_path / "proj"
    for d in ("_notion/meetings", "_notion/_archived/tasks", "reports", "live", ".livetips-index"):
        (root / d).mkdir(parents=True)
    for day in range(1, 31):              # 30 old meetings first in the alphabet, the two that matter last
        (root / f"_notion/meetings/2026-10-{day:02d} Weekly.md").write_text(f"# Weekly {day}\n" + "old notes. " * 800)
    (root / "_notion/meetings/2026-11-10 Pricing review.md").write_text("# Pricing review\nThe pricing decision is due.")
    (root / "_notion/meetings/2026-11-11 Pricing deck sync.md").write_text("# Pricing deck sync\nSlide 12 changed.")
    (root / "_notion/_archived/tasks/2026-11-11 old.md").write_text("archived")
    (root / ".livetips-index/x.md").write_text("index")
    (root / "live/2026-11-10-1200-pricing.app.md").write_text("transcript")
    (root / "reports/speech-v2.md").write_text("# old speech")
    (root / "reports/speech-v3.md").write_text("# new speech")
    (root / "AGENTS.md").write_text("agents " * 100)
    return root


def req(tmp_path, root, **kw):
    r = {"title": "Pricing deck review", "context": "Present the pricing deck", "root": str(root), "live": str(tmp_path / "nolive"),
         "use_project_folder": True, "folders": [str(root)], "files": [], "today": "2026-11-11", "call_type": "auto"}
    r.update(kw)
    return r


def test_the_folder_is_ranked_by_date_and_match_not_by_the_alphabet(tmp_path):
    root = project(tmp_path)
    pack, used, man, s = pc.build(req(tmp_path, root, pack_chars=30_000))
    taken = [m.get("path") for m in man if m.get("status") in ("full", "compressed")]
    assert taken.index(str(root / "_notion/meetings/2026-11-11 Pricing deck sync.md")) < 3
    assert str(root / "_notion/meetings/2026-11-10 Pricing review.md") in taken
    assert any(m.get("status") == "skipped_budget" for m in man)          # the old weeklies did not all fit
    assert "speech-v2" not in pack and "new speech" in pack                # only the newest version


def test_archived_hidden_and_generated_files_are_excluded_and_counted(tmp_path):
    root = project(tmp_path)
    _, _, man, s = pc.build(req(tmp_path, root))
    reasons = {m["reason"]: m["count"] for m in man if m.get("kind") == "excluded"}
    assert reasons.get("archived") == 1 and reasons.get("hidden") == 1 and reasons.get("generated call file") == 1
    assert reasons.get("older version") == 1
    assert s["counts"]["excluded"] >= 4


def test_a_file_the_pm_added_is_whole_or_visibly_compressed(tmp_path):
    root = project(tmp_path)
    big = root / "reports" / "speech-big.md"
    big.write_text("".join(f"## Slide {i}\n" + ("Слово " * 400) + "\n" for i in range(1, 32)))   # Cyrillic, ~75K chars
    pack, _, man, s = pc.build(req(tmp_path, root, files=[str(big)], folders=[]))
    assert "## Slide 31" in pack                                            # fits the local budget: whole
    pack, _, man, s = pc.build(req(tmp_path, root, files=[str(big)], folders=[], pack_chars=60_000))
    m = next(x for x in man if x.get("path") == str(big))
    assert m["status"] == "compressed" and m["taken"] < m["chars"]
    assert "## Slide 31" in pack and "[Compressed by Pacenote" in pack     # every section kept, the mark is visible
    assert any(w["kind"] == "pinned_compressed" for w in s["warnings"])
    assert "compressed" in pc.summary_line(s, "en") and "стиснуто" in pc.summary_line(s, "uk")


def test_pinned_sources_come_before_the_folder_and_the_config_is_never_crowded_out(tmp_path):
    root = project(tmp_path)
    cfg = tmp_path / "config.md"
    cfg.write_text("# Config\nbrief in English")
    _, used, man, _ = pc.build(req(tmp_path, root, config=str(cfg), pack_chars=25_000))
    assert used[0] == "Call context written by the PM"
    assert any(m.get("kind") == "config" and m["status"] == "full" for m in man)


def test_the_deck_is_pinned_and_reported(tmp_path):
    root = project(tmp_path)
    deck = tmp_path / "prep.deck.json"
    deck.write_text(json.dumps({"slides": [{"n": 1, "title": "Prices", "text": "Plan A 10 USD"}]}))
    pack, _, man, s = pc.build(req(tmp_path, root, deck=str(deck), deck_lines="slides 1: who me"))
    assert "Slide 1: Prices" in pack and s["deck_used"] is True
    _, _, _, s = pc.build(req(tmp_path, root, call_type="presentation"))
    assert s["deck_used"] is False and any(w["kind"] == "deck_missing" for w in s["warnings"])


def test_read_text_keeps_its_cut_mark_inside_the_cap(tmp_path):
    p = tmp_path / "a.md"
    p.write_text("x" * 5000)
    t = localprep.read_text(str(p), 1000)
    assert len(t) <= 1000 and "cut by Pacenote at 1000 of 5000" in t


def test_the_claude_ways_get_the_same_manifest_marked_read(tmp_path):
    root = project(tmp_path)
    f = root / "reports" / "speech-v3.md"
    man, s = pc.mark_read(req(tmp_path, root, files=[str(f)]), ["2026-11-11 Pricing deck sync.md"])
    st = {os.path.basename(m["path"]): m["status"] for m in man if m.get("path")}
    assert st["2026-11-11 Pricing deck sync.md"] == "read" and st["speech-v3.md"] == "not_read"
    assert any(w["kind"] == "pinned_not_read" for w in s["warnings"])


def test_with_line_puts_the_context_under_the_title():
    b = pc.with_line("# Live Brief: X\n\n## 1. Checklist\n", "Preparation context: 3 in full, deck: used.")
    assert b.splitlines()[0] == "# Live Brief: X" and b.splitlines()[2].startswith("> Preparation context")


class Provider:
    def __init__(self, slides):
        self.responses = ["# Live Brief\n\n## Facts\nFriday", "## 6. My update\nWe ship Friday.",
                          '[{"id":"C1","gist":"Friday"}]', '[{"id":"F1","title":"Date","text":"Friday"}]', slides]
        self.calls = []

    def complete(self, **kw):
        self.calls.append(kw)
        return Completion(text=self.responses.pop(0), input_tokens=10, cache_read=0, output_tokens=5, error=None)


def test_packed_ways_write_the_talk_of_a_deck_with_the_colleagues_text(tmp_path):
    root = project(tmp_path)
    skill = tmp_path / "skill" / "references"
    skill.mkdir(parents=True)
    (skill / "sweep.md").write_text("rules")
    deck = tmp_path / "prep.deck.json"
    deck.write_text(json.dumps({"slides": [{"n": 1, "title": "Intro", "text": "Hi"}, {"n": 2, "title": "Prices", "text": "10"}]}))
    talk = json.dumps({"slides": [{"n": 1, "title": "Intro", "who": "other", "speaker": "Emily", "sec": 60,
                                   "body": [{"k": "p", "t": "Emily opens."}]},
                                  {"n": 2, "title": "Prices", "who": "me", "sec": 60, "body": [{"k": "p", "t": "Ten."}]}],
                       "talk_min": 2, "qa_min": 0})
    r = req(tmp_path, root, deck=str(deck), deck_lines="slides 1: who other, speaker Emily; slides 2: who me",
            base=str(tmp_path / "prep"), skill=str(tmp_path / "skill"), languages=["en"], folders=[])
    run = codexprep.Preparation(r, Provider(talk))
    run.run()
    out = json.loads((tmp_path / "prep.slides.json").read_text())
    assert out["slides"][0]["who"] == "other" and out["slides"][0]["body"][0]["t"] == "Emily opens."
    assert "colleague's (\"other\") slides too" in run.provider.calls[-1]["system"][0]["text"]
    ctx = json.loads((tmp_path / "prep.context.json").read_text())
    assert ctx["summary"]["deck_used"] is True
    assert "deck: used" in (tmp_path / "prep.brief.md").read_text()


def test_no_deck_means_no_slides_pass(tmp_path):
    root = project(tmp_path)
    skill = tmp_path / "skill" / "references"
    skill.mkdir(parents=True)
    (skill / "sweep.md").write_text("rules")
    p = Provider("")
    r = req(tmp_path, root, base=str(tmp_path / "prep"), skill=str(tmp_path / "skill"), languages=["en"], folders=[])
    codexprep.Preparation(r, p).run()
    assert len(p.calls) == 4 and not (tmp_path / "prep.slides.json").exists()


def test_a_long_deck_is_written_ten_slides_a_pass(tmp_path):
    root = project(tmp_path)
    skill = tmp_path / "skill" / "references"
    skill.mkdir(parents=True)
    (skill / "sweep.md").write_text("rules")
    deck = tmp_path / "prep.deck.json"
    deck.write_text(json.dumps({"slides": [{"n": i, "title": f"S{i}", "text": "t"} for i in range(1, 26)]}))
    def part(a, b):
        return json.dumps({"slides": [{"n": i, "title": f"S{i}", "who": "me", "sec": 60, "body": [{"k": "p", "t": "x"}]}
                                      for i in range(a, b + 1)], "talk_min": 25, "qa_min": 0})
    p = Provider(part(1, 10))
    p.responses += [part(11, 20), part(21, 25)]
    r = req(tmp_path, root, deck=str(deck), deck_lines="slides 1-25: who me", base=str(tmp_path / "prep"),
            skill=str(tmp_path / "skill"), languages=["en"], folders=[])
    codexprep.Preparation(r, p).run()
    out = json.loads((tmp_path / "prep.slides.json").read_text())
    assert [s["n"] for s in out["slides"]] == list(range(1, 26)) and out["talk_min"] == 25
    assert len(p.calls) == 7 and "slides 21-25" in p.calls[-1]["user"]
