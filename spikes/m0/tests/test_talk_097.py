"""0.9.7 (owner, 11.11): the talk module (references/talk.md) reaches the packed ways' talk prompt, the deck's speaker
notes reach the talk, and a folder-only preparation passes more than 3 speech documents."""
import json

from livetips_m0 import codexprep, localprep, prepcontext as pc
from test_prepcontext_097 import Provider, project, req


def test_the_talk_module_is_in_the_slides_prompt(tmp_path):
    root = project(tmp_path)
    refs = tmp_path / "skill" / "references"
    refs.mkdir(parents=True)
    (refs / "sweep.md").write_text("rules")
    (refs / "talk.md").write_text("# talk\nNever describe the slide: no 'this slide shows'.")
    deck = tmp_path / "prep.deck.json"
    deck.write_text(json.dumps({"slides": [{"n": 1, "title": "Intro", "text": "Hi", "notes": "Say the 216 calls"}]}))
    talk = json.dumps({"slides": [{"n": 1, "title": "Intro", "who": "me", "sec": 30, "body": [{"k": "p", "t": "Hi all."}]}]})
    r = req(tmp_path, root, deck=str(deck), deck_lines="slides 1: who me", base=str(tmp_path / "prep"),
            skill=str(tmp_path / "skill"), languages=["en"], folders=[])
    run = codexprep.Preparation(r, Provider(talk))
    run.run()
    last = run.provider.calls[-1]
    assert "references/talk.md" in last["system"][0]["text"] and "this slide shows" in last["system"][0]["text"]
    assert "first person" in last["system"][0]["text"]
    assert "Speaker notes: Say the 216 calls" in last["user"]


def test_no_talk_module_keeps_the_prompt_valid(tmp_path):
    assert localprep.talk_rules(str(tmp_path)) == "" and localprep.talk_rules("") == ""


def test_the_real_talk_module_exists():
    import os
    p = os.path.join(os.path.dirname(__file__), "..", "..", "..", "skill", "references", "talk.md")
    t = open(p, encoding="utf-8").read()
    assert "first person" in t.lower() and "never describe the slide" in t.lower()   # long dashes: test_anonymization_clean


def test_deck_text_carries_the_notes(tmp_path):
    d = tmp_path / "d.json"
    d.write_text(json.dumps({"slides": [{"n": 1, "title": "A", "text": "x"}, {"n": 2, "title": "B", "text": "y", "notes": "z"}]}))
    t = pc.deck_text(str(d))
    assert "Slide 1: A\nx" in t and "Slide 2: B\ny\nSpeaker notes: z" in t and t.count("Speaker notes") == 1


def test_a_folder_only_talk_takes_up_to_eight_speech_documents(tmp_path):
    run = codexprep.Preparation.__new__(codexprep.Preparation)
    files = []
    for i in range(10):
        f = tmp_path / f"speech-part{i}.md"
        f.write_text(f"part {i}")
        files.append({"path": str(f), "kind": "folder_file", "status": "full"})
    deck = tmp_path / "deck.json"
    deck.write_text(json.dumps({"slides": [{"n": 1, "title": "A", "text": "x"}]}))
    run.request = {"deck": str(deck), "deck_lines": ""}
    run.manifest = files
    m = run.slides_material("brief")
    assert m.count("## Speech document:") == codexprep.Preparation.SLIDES_DOCS == 8
