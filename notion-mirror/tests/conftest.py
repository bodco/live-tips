import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).absolute().parents[1]))   # notion-mirror/ (mirror.py)

import pytest  # noqa: E402

import mirror  # noqa: E402


@pytest.fixture(autouse=True)
def private_logs(tmp_path, monkeypatch):
    """The mirror logs next to its config; tests log into their temp folder instead."""
    monkeypatch.setattr(mirror, "LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setattr(mirror, "LOG_PATH", str(tmp_path / "logs" / "mirror.log"))
