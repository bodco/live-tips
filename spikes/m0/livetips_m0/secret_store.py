"""Secret loading for the spike. The app uses the macOS Keychain; the spike reads an env var or a
dotenv-style secrets file at runtime. Values are never printed or logged."""
import os
import re
from pathlib import Path
from typing import Optional


def load_secret(name: str, secrets_file: Optional[str] = None) -> str:
    v = os.environ.get(name)
    if v:
        return v.strip()
    if secrets_file:
        p = Path(os.path.expanduser(secrets_file))
        if p.exists():
            for raw in p.read_text(encoding="utf-8").splitlines():
                m = re.match(r"\s*(?:export\s+)?" + re.escape(name) + r"\s*=\s*(.*)$", raw)
                if m:
                    return m.group(1).strip().strip('"').strip("'")
    raise KeyError("secret {} not found (env or secrets file)".format(name))


def masked(v: str) -> str:
    return "..." + v[-4:] if v and len(v) > 8 else "(set)"
