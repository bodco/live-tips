"""Local, model-free detection of trigger signals on one transcript line."""
import re
from dataclasses import dataclass, field
from typing import List

WORD = re.compile(r"[\w'ʼ’]+", re.UNICODE)


def _words(text):
    return [w.lower() for w in WORD.findall(text)]


def _has_phrase(text_l, words, cue):
    if " " in cue:
        return cue in text_l
    return any(w.startswith(cue) and (len(w) - len(cue) <= 4 or len(cue) >= 6) for w in words) if len(cue) > 3 \
        else cue in words


@dataclass
class Signals:
    question: bool = False
    second_person: bool = False
    name_mention: bool = False
    update_request: bool = False
    new_requirement: bool = False
    commitment: bool = False
    frustration: bool = False
    tags: List[str] = field(default_factory=list)

    @property
    def route(self):
        """'direct' (straight to tip), 'classify', or None."""
        if self.name_mention or self.new_requirement or self.commitment:
            return "direct"
        if self.question and self.second_person:
            return "direct"
        if self.question or self.frustration or self.update_request:
            return "classify"
        return None

    @property
    def trigger_hint(self):
        if self.commitment:
            return "pm_commitment"
        if self.new_requirement:
            return "new_requirement"
        if self.name_mention and (self.update_request or not self.question):
            return "your_turn"
        if self.question:
            return "direct_question"
        if self.frustration:
            return "frustration"
        return "none"


class Detector:
    def __init__(self, rules, name_aliases):
        self.q = rules.cues("question_words")
        self.you = rules.cues("second_person")
        self.upd = rules.cues("update_request")
        self.req = rules.cues("new_requirement")
        self.units = rules.cues("commitment_units")
        self.frus = rules.cues("frustration")
        self.aliases = [a.lower() for a in name_aliases if a]

    def _any(self, text_l, words, cues):
        return any(_has_phrase(text_l, words, c) for c in cues)

    def detect(self, line) -> Signals:
        text_l = line.text.lower()
        words = _words(line.text)
        s = Signals()
        if line.speaker == "them":
            s.question = "?" in line.text or (bool(words) and self._any(" ".join(words[:2]), words[:2], self.q))
            s.second_person = self._any(text_l, words, self.you)
            s.name_mention = any(w.startswith(a[:max(4, len(a) - 2)]) for a in self.aliases for w in words)
            s.update_request = self._any(text_l, words, self.upd)
            s.new_requirement = self._any(text_l, words, self.req)
            s.frustration = self._any(text_l, words, self.frus)
        else:
            has_number = bool(re.search(r"\d", line.text)) or self._any(text_l, words, ["один", "два", "три", "пʼять", "one", "two", "three", "five"])
            s.commitment = has_number and self._any(text_l, words, self.units)
        s.tags = [k for k, v in vars(s).items() if v is True]
        return s
