import json

import pytest

from livetips_m0 import codexprep
from livetips_m0.providers import Completion


class Provider:
    def __init__(self, facts='[{"id":"F1","title":"Date","text":"Friday"}]', error=None):
        self.responses = ["# Live Brief\n\n## Your speech\n\n## Facts\nFriday", "## Your speech\nWe ship Friday.",
                          '[{"id":"C1","gist":"Friday"}]', facts]
        self.error = error
        self.calls = []

    def complete(self, **call_request):
        self.calls.append(call_request)
        return Completion(text=self.responses.pop(0), input_tokens=100, cache_read=20, output_tokens=30, error=self.error)


@pytest.fixture
def call_request(tmp_path):
    skill = tmp_path / "skill"
    (skill / "references").mkdir(parents=True)
    (skill / "references/sweep.md").write_text("Use facts only")
    return {"title": "Review", "when": "2026-11-03 12:00", "base": str(tmp_path / "prep"), "skill": str(skill),
            "root": str(tmp_path), "live": str(tmp_path), "languages": ["en"], "context": "We ship Friday",
            "use_project_folder": False}


def test_preparation_uses_pack_and_writes_only_results(call_request):
    provider = Provider()
    run = codexprep.Preparation(call_request, provider)
    sources = run.run()
    assert len(provider.calls) == 4
    assert "We ship Friday" in provider.calls[0]["user"]
    assert all(call["model"] == "codex/default" for call in provider.calls)
    assert run.tokens == {"input": 480, "output": 120}
    from pathlib import Path
    assert "We ship Friday" in Path(call_request["base"] + ".brief.md").read_text()
    assert json.loads(Path(call_request["base"] + ".facts.json").read_text())[0]["id"] == "F1"


@pytest.mark.parametrize("provider", [Provider(facts="[]"), Provider(error="Codex: usage limit reached")])
def test_failed_preparation_keeps_previous_files(call_request, provider):
    from pathlib import Path
    brief = Path(call_request["base"] + ".brief.md")
    brief.write_text("previous")
    with pytest.raises(RuntimeError):
        codexprep.Preparation(call_request, provider).run()
    assert brief.read_text() == "previous"


def test_missing_cli_reports_an_actionable_error(call_request, monkeypatch, tmp_path, capsys):
    path = tmp_path / "call_request.json"
    path.write_text(json.dumps(call_request))
    monkeypatch.setattr(codexprep, "find_codex_cli", lambda: None)
    assert codexprep.main(["--request", str(path)]) == 1
    assert "not installed" in json.loads(capsys.readouterr().out)["error"]


@pytest.mark.parametrize("language", ["en", ""])
def test_brief_and_call_languages(call_request, language):
    call_request["brief_lang"] = language
    call_request["languages"] = [language] if language else []
    provider = Provider()
    codexprep.Preparation(call_request, provider).contents()
    expected = "English" if language else "Ukrainian"
    assert "else in " + expected + ";" in provider.calls[0]["system"][0]["text"]
    assert expected in provider.calls[0]["user"]


@pytest.mark.parametrize("error", [None, "Codex: usage limit reached"])
def test_cli_reports_success_and_failure(call_request, monkeypatch, tmp_path, capsys, error):
    path = tmp_path / "request.json"
    path.write_text(json.dumps(call_request))
    ticks = iter([100.0, 103.0])
    monkeypatch.setattr(codexprep.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(codexprep, "find_codex_cli", lambda: "fake-codex")
    monkeypatch.setattr(codexprep, "CodexProvider", lambda *a, **kw: Provider(error=error))
    assert codexprep.main(["--request", str(path)]) == (1 if error else 0)
    result = json.loads(capsys.readouterr().out.splitlines()[-1])
    assert result["ok"] == (error is None)
    assert result["duration_s"] == 3
    if error:
        assert result["error"] == error
    else:
        assert result["tokens"] == {"input": 480, "output": 120}


def test_empty_model_reply_is_an_error(call_request):
    provider = Provider()
    provider.responses[0] = "  "
    with pytest.raises(RuntimeError, match="empty brief"):
        codexprep.Preparation(call_request, provider).run()
