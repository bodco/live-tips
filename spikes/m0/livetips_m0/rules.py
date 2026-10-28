"""Load the shared rules/ folder."""
import json
from pathlib import Path

import yaml

DEFAULT_RULES = Path(__file__).resolve().parents[3] / "rules"


class Rules:
    def __init__(self, root: Path = DEFAULT_RULES):
        self.root = Path(root)
        self.version = (self.root / "VERSION").read_text().strip()
        self.triggers = self._y("triggers.yaml")
        self.diet = self._y("diet.yaml")
        self.priorities = self._y("priorities.yaml")
        self.meeting = self._y("meeting.yaml")
        self.asr_filters = self._y("asr_filters.yaml")
        self.semantic = self._y("semantic.yaml")
        self.index = self._y("index.yaml")
        self.tip_schema = self._j("tip_schema.json")
        self.model_tip_schema = self._j("model_tip_schema.json")
        self.classify_schema = self._j("classify_schema.json")
        # Pacenote 0.8.5: the agenda and the commitments register (optional, so older rules folders still load).
        self.agenda = self._y("agenda.yaml") if (self.root / "agenda.yaml").exists() else {}
        self.commitments = self._y("commitments.yaml") if (self.root / "commitments.yaml").exists() else {}
        self.risks = self._y("risks.yaml") if (self.root / "risks.yaml").exists() else {}       # 0.8.6

    def _y(self, name):
        return yaml.safe_load((self.root / name).read_text(encoding="utf-8"))

    def _j(self, name):
        return json.loads((self.root / name).read_text(encoding="utf-8"))

    def cues(self, kind):
        """All languages of one cue list, lowercase."""
        out = []
        for words in (self.triggers.get("cues", {}).get(kind) or {}).values():
            out.extend(w.lower() for w in words)
        return out
