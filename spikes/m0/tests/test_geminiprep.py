import json
from pathlib import Path

from livetips_m0 import geminiprep
from test_codexprep import Provider, call_request  # noqa: F401  (fixture)


def test_gemini_preparation_writes_the_same_files(call_request):  # noqa: F811
    provider = Provider()
    run = geminiprep.GeminiPreparation(call_request, provider)
    run.run()
    assert len(provider.calls) == 4
    brief = Path(call_request["base"] + ".brief.md").read_text()
    assert "Gemini API" in brief or "We ship Friday" in brief
    assert json.loads(Path(call_request["base"] + ".cards.json").read_text())[0]["id"] == "C1"


def test_missing_key_reports_an_actionable_error(call_request, monkeypatch, tmp_path, capsys):  # noqa: F811
    path = tmp_path / "call_request.json"
    path.write_text(json.dumps(call_request))
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    assert geminiprep.main(["--request", str(path)]) == 1
    assert "Gemini API key" in json.loads(capsys.readouterr().out)["error"]


def test_a_preparation_counts_what_its_passes_cost(call_request):  # noqa: F811
    import pytest
    from livetips_m0.providers import Completion

    class Priced(Provider):
        def complete(self, **kw):
            c = super().complete(**kw)
            c.model = "gemini-3.8-flash"
            return c

    run = geminiprep.GeminiPreparation(call_request, Priced())
    run.run()
    # 4 passes x (100 input + 20 cached + 30 output) at $0.75 / $0.075 / $3.75 per 1M (price on 2026-11-04)
    from livetips_m0.cost import price_for
    p = price_for("gemini-3.8-flash")
    assert run.usd == pytest.approx(4 * (100 * p[0] + 20 * p[3] + 30 * p[4]) / 1e6)
    assert isinstance(Completion(), Completion)
