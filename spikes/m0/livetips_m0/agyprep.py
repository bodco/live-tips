"""Prepare a call through the Gemini account (Antigravity CLI, 0.9.3, owner): the same context pack and passes as the
ChatGPT account route (codexprep). Pacenote reads and writes the files itself; agy runs in an empty folder."""
import argparse
import json
import os
import time
from pathlib import Path

from . import localprep as prep
from .agy_provider import AgyProvider, find_agy_cli, job_model
from .codexprep import Preparation


class AgyPreparation(Preparation):
    label = "Gemini account"
    head_route = "Gemini account through Antigravity CLI"
    route = "agy"      # 0.9.7: the pack budget (prepcontext.BUDGETS)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    request = json.loads(Path(parser.parse_args(argv).request).read_text(encoding="utf-8"))
    started = time.monotonic()
    model = job_model("prep", request.get("agy_model") or os.environ.get("LT_AGY_MODEL"))
    result = {"ok": False, "model": "agy/" + model, "tokens": {}, "sources": []}
    try:
        cli = find_agy_cli()
        if not cli:
            raise RuntimeError("Antigravity CLI is not installed: see Settings > AI > Gemini")
        preparation = AgyPreparation(request, AgyProvider(cli, timeout=300, model=model))
        result["sources"] = preparation.run()
        result["context_summary"] = preparation.summary      # the manifest is in <base>.context.json   # 0.9.7
        if preparation.slides_error:
            result["slides_error"] = preparation.slides_error
        result["tokens"] = preparation.tokens
        result["ok"] = True
    except Exception as error:  # noqa: BLE001  the app restores the previous files on failure
        result["error"] = str(error)[:200]
    result["duration_s"] = int(time.monotonic() - started)
    prep.say(**result)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
