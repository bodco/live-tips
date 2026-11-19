"""Theme pass stage 3 (2026-11-19): a tip reads as key / detail / source. The engine writes detail (was why) and
source (the model's own, else the sources of the facts it used); old items with why and note still validate."""
import json
from types import SimpleNamespace

import jsonschema

from livetips_m0.engine import request_item, tip_detail, tip_item, tip_source
from livetips_m0.prompt import PromptBuilder, TIP_TASK
from livetips_m0.rules import Rules

LINE = SimpleNamespace(t="13:24:50")


def test_tip_item_detail_and_source():
    obj = {"gist": "Production release: Tue, Nov 24", "level": "orange", "topic": "release date",
           "detail": "After the Nov 23 review", "source": "Release plan · Nov 14", "phrase": "It goes live on Tuesday."}
    it = tip_item(obj, "u1", LINE, "direct_question", 805.0, late=False)
    assert it["detail"] == "After the Nov 23 review"
    assert it["source"] == "Release plan · Nov 14"
    assert "why" not in it and "note" not in it


def test_old_model_output_still_reads():
    obj = {"gist": "Pilot: 5 users", "level": "info", "topic": "pilot", "why": "Names by Friday.", "note": "kickoff, 21.10"}
    it = tip_item(obj, "u2", LINE, "add_fact", 805.0, late=False)
    assert it["detail"] == "Names by Friday."
    assert it["note"] == "kickoff, 21.10"          # the windows still read note as the source
    assert "source" not in it
    assert tip_detail({"detail": "", "why": "x"}) == "x"


def test_source_from_fact_ids(tmp_path):
    facts = tmp_path / "facts.json"
    facts.write_text(json.dumps([{"id": "F1", "title": "Release", "text": "Tue, Nov 24", "source": "Release plan · Nov 14"},
                                 {"id": "F2", "title": "Pilot", "text": "5 users", "source": "Status report · Nov 14"},
                                 {"id": "F3", "title": "QA", "text": "first week", "source": "Release plan · Nov 14"}]))
    pb = PromptBuilder(Rules(), {"tips_lang": "en", "langs": ["en"]}, facts_path=facts)
    assert pb.fact_sources(["F1", "fact:F3", "F2"]) == "Release plan · Nov 14; Status report · Nov 14"
    assert pb.fact_sources(["nope"]) == ""
    obj = {"gist": "Release Tue", "level": "red", "topic": "release", "fact_ids": ["F2"]}
    assert tip_item(obj, "u3", LINE, "direct_question", 1.0, late=False, sources=pb.fact_sources)["source"] == "Status report · Nov 14"
    # the model's own source wins over the facts
    assert tip_source(dict(obj, source="Sources: Brief · Nov 18"), pb.fact_sources) == "Brief · Nov 18"


def test_request_item_carries_detail_and_source():
    it = request_item({"gist": "Five users", "detail": "From the client", "source": "Kick-off notes · Oct 21"},
                      "ask", "pilot users?", "13:00:00", 10.0)
    assert (it["detail"], it["source"], it["q"]) == ("From the client", "Kick-off notes · Oct 21", "pilot users?")


def test_schemas_take_both_formats():
    r = Rules()
    window = jsonschema.Draft202012Validator(r.tip_schema)
    model = jsonschema.Draft202012Validator(r.model_tip_schema)
    new = {"gist": "🟠 Release Tue", "level": "orange", "topic": "release", "detail": "After review", "source": "Plan · Nov 14"}
    old = {"gist": "🟠 Release Tue", "level": "orange", "topic": "release", "why": "After review", "note": "plan, 14.11"}
    assert not list(model.iter_errors(new)) and not list(model.iter_errors(old))
    assert not list(window.iter_errors(dict(new, kind="tip", src="13:00:00")))
    assert not list(window.iter_errors(dict(old, kind="tip", src="13:00:00")))
    assert list(window.iter_errors({"kind": "tip", "gist": "x", "level": "red", "src": "13:00:00", "source": "y" * 200}))


def test_prompt_asks_for_detail_and_source():
    assert '"detail":' in TIP_TASK and '"source":' in TIP_TASK and '"why":' not in TIP_TASK
    assert "{detail_words}" in TIP_TASK
    pb = PromptBuilder(Rules(), {"tips_lang": "en", "langs": ["en"]})
    assert pb.fmt["detail_words"] == Rules().diet["limits"]["detail_words_max"]
    TIP_TASK.format(event="x", **pb.fmt)
