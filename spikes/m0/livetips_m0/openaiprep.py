"""Prepare a call through the OpenAI API (0.9.0, owner): the same context pack and passes as the ChatGPT account
route (codexprep), asked through the streaming Responses API with the key from Settings > AI (OPENAI_API_KEY,
given to this process only). Pacenote reads and writes the files itself; the model gets no file or tool access."""
import argparse
import json
import os
import time
from pathlib import Path

from . import localprep as prep
from .codexprep import Preparation
from .openai_provider import MODEL, OpenAIProvider


class OpenAIPreparation(Preparation):
    label = "OpenAI"
    head_route = "OpenAI API"


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    request = json.loads(Path(parser.parse_args(argv).request).read_text(encoding="utf-8"))
    started = time.monotonic()
    result = {"ok": False, "model": MODEL, "tokens": {}, "sources": []}
    try:
        key = os.environ.get("OPENAI_API_KEY", "")
        if not key:
            raise RuntimeError("No OpenAI API key: add it in Settings > AI > ChatGPT")
        preparation = OpenAIPreparation(request, OpenAIProvider(key, timeout=300))
        result["sources"] = preparation.run()
        result["tokens"] = preparation.tokens
        result["ok"] = True
    except Exception as error:  # noqa: BLE001  the app restores the previous files on failure
        result["error"] = str(error)[:200]
    result["duration_s"] = int(time.monotonic() - started)
    prep.say(**result)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
