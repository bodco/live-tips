"""0.8.5 rehearsal (rules/rehearsal.yaml): questions with why and slide; scores keep the slide; no long dash."""
from livetips_m0 import rehearse


def test_questions_items_and_scores(monkeypatch, tmp_path):
    base = str(tmp_path / "prep")
    (tmp_path / "prep.brief.md").write_text("# Brief\nSSO risk")
    seen = {}

    def fake(system, user, model, max_tokens, provider):
        seen["system"] = system
        if "questions" in system and "coach" not in system:
            return {"questions": [{"q": "Does 2 days hold" + chr(0x2014) + "with our review?", "why": "SSO risk in the brief", "slide": "3"},
                                  "When is the export ready?", {"q": ""}]}, 0.01
        return {"answers": [{"score": 9, "feedback": "ok", "better": "It holds.", "slide": 3}], "overall": "Clear"}, 0.01

    monkeypatch.setattr(rehearse, "ask_json", fake)
    r = rehearse.questions(base, "en", who="Emily Clark")
    assert "Emily Clark" in seen["system"]
    assert r["items"][0] == {"q": "Does 2 days hold-with our review?", "why": "SSO risk in the brief", "slide": 3}
    assert r["items"][1]["slide"] is None and len(r["questions"]) == 2
    s = rehearse.score(base, [{"q": "Q", "a": "A"}, {"q": "Q2", "a": "", "slide": 5}])
    assert s["answers"][0]["score"] == 5 and s["answers"][0]["slide"] == 3 and s["answers"][1]["slide"] == 5
