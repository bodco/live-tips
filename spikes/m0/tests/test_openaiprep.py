import json
from pathlib import Path

from livetips_m0 import openaiprep
from test_codexprep import Provider, call_request  # noqa: F401  (fixture)


def test_openai_preparation_writes_the_same_files(call_request):  # noqa: F811
    provider = Provider()
    run = openaiprep.OpenAIPreparation(call_request, provider)
    run.run()
    assert len(provider.calls) == 4
    brief = Path(call_request["base"] + ".brief.md").read_text()
    assert "OpenAI API" in brief or "We ship Friday" in brief
    assert json.loads(Path(call_request["base"] + ".cards.json").read_text())[0]["id"] == "C1"


def test_missing_key_reports_an_actionable_error(call_request, monkeypatch, tmp_path, capsys):  # noqa: F811
    path = tmp_path / "call_request.json"
    path.write_text(json.dumps(call_request))
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    assert openaiprep.main(["--request", str(path)]) == 1
    assert "OpenAI API key" in json.loads(capsys.readouterr().out)["error"]
