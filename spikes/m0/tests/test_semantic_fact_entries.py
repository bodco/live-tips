import json
from livetips_m0.semantic_eval import fact_entries


def test_actual_facts_replace_brief_proxy(tmp_path):
    facts, brief = tmp_path / 'call.facts.json', tmp_path / 'call.brief.md'
    brief.write_text('- This checklist question is long enough to be a proxy fact\n')
    facts.write_text(json.dumps({'facts': [{'id': 'f1', 'text': 'Actual sourced fact', 'status': 'unverified'}]}))
    assert fact_entries(facts, brief) == [{'id': 'f1', 'text': 'Actual sourced fact', 'title': '', 'status': 'unverified'}]
    facts.write_text('[]')
    assert fact_entries(facts, brief) == []
    facts.unlink()
    assert fact_entries(facts, brief)[0]['id'] == 'b0'
