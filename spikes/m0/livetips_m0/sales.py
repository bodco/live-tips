"""Sales mode (Pacenote 0.8.7, rules/sales.yaml): the qualification tracker of the call picture, the sales tips
(objection, qualify, pain, next_step, competitor, signal), answer cards and the after-call summary (<stem>.sales.json).
Off unless the call's cfg has sales.enabled."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Dict, List, Optional

ORDER = {"unknown": 0, "partial": 1, "known": 2}


def words(s: str) -> set:
    return {w for w in re.findall(r"[\w']+", (s or "").lower()) if len(w) > 2}


def parse_cards(text: str) -> List[dict]:
    """answer-cards.md: "## question or topic", the answer below, optional "Tags:" and "Use when:" lines."""
    cards, cur = [], None
    for ln in (text or "").splitlines():
        if ln.startswith("## "):
            if cur:
                cards.append(cur)
            cur = {"title": ln[3:].strip(), "answer": [], "tags": [], "use_when": ""}
        elif cur is not None:
            low = ln.strip().lower()
            if low.startswith("tags:"):
                cur["tags"] = [t.strip().lower() for t in ln.split(":", 1)[1].split(",") if t.strip()]
            elif low.startswith("use when:"):
                cur["use_when"] = ln.split(":", 1)[1].strip()
            elif ln.strip():
                cur["answer"].append(ln.strip())
    if cur:
        cards.append(cur)
    for c in cards:
        c["answer"] = " ".join(c["answer"])
    return cards


def load_cards(root: str) -> List[dict]:
    p = Path(root or ".") / "pacenote" / "answer-cards.md"
    try:
        return parse_cards(p.read_text(encoding="utf-8"))
    except OSError:
        return []


def best_card(text: str, cards: List[dict], min_share: float = 0.34) -> Optional[dict]:
    """The card whose title, tags and use-when share the most words with the text (at least a third of its words)."""
    w = words(text)
    best, score = None, 0.0
    for c in cards:
        cw = words(c["title"] + " " + " ".join(c["tags"]) + " " + c["use_when"])
        if not cw:
            continue
        sc = len(w & cw) / len(cw)
        if sc > score:
            best, score = c, sc
    return best if score >= min_share else None


def ranked_cards(text: str, cards: List[dict], k: int = 3, min_share: float = 0.2) -> List[dict]:
    """0.8.7 (H4.5): the cards that match the text best (title, tags, use-when and answer words), best first."""
    w = words(text)
    scored = []
    for i, c in enumerate(cards or []):
        head = words(c["title"] + " " + " ".join(c["tags"]) + " " + c["use_when"])
        body = words(c.get("answer", ""))
        if not head and not body:
            continue
        sc = len(w & head) / max(1, len(head)) + 0.5 * len(w & body) / max(1, len(body | w))
        if sc >= min_share:
            scored.append((-sc, i, c))
    return [c for _, _, c in sorted(scored, key=lambda x: (x[0], x[1]))[:k]]


def cards_block(text: str, cards: List[dict]) -> str:
    """0.8.7 (H4.5, rules/sales.yaml > ask_order): answer cards go before the brief and the project memory."""
    hits = ranked_cards(text, cards)
    if not hits:
        return ""
    return ("ANSWER CARDS (sales mode: look here FIRST, then the brief and the project memory; when a card answers, "
            "use its answer and say it comes from the card):\n" +
            "\n".join("- " + c["title"] + ": " + c["answer"] for c in hits) + "\n\n")


def observed_seller(meta: Optional[dict]) -> bool:
    """0.8.7 (H2, rules/sales.yaml > coach): the PM watches someone else sell (interview observer, coach call mentor)."""
    meta = meta or {}
    role = meta.get("hiring_role") or meta.get("coach_role") or ""
    return (meta.get("call_type") == "interview" and role == "observer") or \
        (meta.get("call_type") == "coach" and role == "mentor")


class SalesTracker:
    def __init__(self, rules: dict, method: str = "", lang: str = "uk", cards: Optional[List[dict]] = None,
                 planned_s: float = 1800.0):
        self.rules = rules or {}
        methods = self.rules.get("methods") or {}
        self.method = method if method in methods else self.rules.get("default_method", "general")
        self.spec = methods.get(self.method) or {"criteria": []}
        self.lang = "en" if lang == "en" else "uk"
        self.cards = cards or []
        self.planned_s = max(300.0, float(planned_s or 1800))
        self.deal: Dict[str, dict] = {c["key"]: {"criterion": c["key"], "state": "unknown", "what": "", "quote": "", "t": ""}
                                      for c in self.spec.get("criteria", [])}
        self.objections: List[dict] = []
        self.next_step: dict = {}
        self.signals: List[dict] = []
        self.pm_fixed: Dict[str, dict] = {}
        self.fired: set = set()
        self.observed = False        # 0.8.7 (H2): tips address the seller the PM watches (rules/sales.yaml > coach)

    # ---- the call picture
    def criteria_text(self) -> str:
        return "\n".join("{} | {} | {}".format(c["key"], c["name"]["en"], c["explain"]["en"]) for c in self.spec.get("criteria", []))

    def extra(self) -> tuple:
        cp = self.rules.get("call_picture") or {}
        return cp.get("key", ""), cp.get("rule", "") + "\nQUALIFICATION CRITERIA (" + self.method + "; key | name | meaning):\n" + self.criteria_text()

    def update(self, sit: dict) -> None:
        for d in sit.get("deal") or []:
            k = str(d.get("criterion") or "")
            if k not in self.deal or k in self.pm_fixed:
                continue
            st = d.get("state") if d.get("state") in ORDER else "unknown"
            if ORDER[st] >= ORDER[self.deal[k]["state"]]:
                self.deal[k] = {"criterion": k, "state": st, "what": str(d.get("what") or "")[:160],
                                "quote": str(d.get("quote") or "")[:200], "t": str(d.get("t") or "")}
        for o in sit.get("objections") or []:
            if o.get("what") and not any(words(o["what"]) and len(words(o["what"]) & words(x["what"])) * 2 >= len(words(o["what"])) for x in self.objections):
                self.objections.append({"what": str(o["what"])[:160], "answer": str(o.get("answer") or "")[:200], "t": str(o.get("t") or "")})
        if (sit.get("next_step") or {}).get("what"):
            self.next_step = {k: str(v or "") for k, v in sit["next_step"].items() if k in ("what", "due", "owner")}
        for s in sit.get("signals") or []:
            if s.get("what") and s["what"] not in [x["what"] for x in self.signals]:
                self.signals.append({"what": str(s["what"])[:160], "t": str(s.get("t") or "")})

    def fix(self, key: str, state: str, what: str = "") -> None:
        """The PM's click in the Deal tab wins over the model (rules/learning.yaml > deal_edit)."""
        if key in self.deal and state in ORDER:
            self.deal[key] = dict(self.deal[key], state=state, what=what or self.deal[key]["what"])
            self.pm_fixed[key] = self.deal[key]

    def known(self) -> int:
        return sum(1 for d in self.deal.values() if d["state"] == "known")

    def item(self) -> dict:
        """The Deal tab's data for the tips window."""
        crit = []
        for c in self.spec.get("criteria", []):
            d = self.deal.get(c["key"], {})
            crit.append(dict(d, key=c["key"], name=c["name"].get(self.lang) or c["name"]["en"]))
        return {"kind": "deal", "method": self.method, "method_name": (self.spec.get("name") or {}).get(self.lang, self.method),
                "chip": bool(self.spec.get("chip")), "known": self.known(), "total": len(crit), "criteria": crit,
                "objections": self.objections, "next_step": self.next_step, "signals": self.signals}

    # ---- tips (rules/sales.yaml > tips); each fires once
    def _tip(self, kind: str, key: str, gist: str, phrase: str, t: str) -> Optional[dict]:
        uid = "sales-" + kind + "-" + key
        if uid in self.fired:
            return None
        self.fired.add(uid)
        tip = {"kind": "tip", "sales": kind, "uid": uid, "level": "orange", "gist": gist, "phrase": phrase, "src": t,
               "label": kind}
        if self.observed:
            pre = (self.rules.get("coach_prefix") or {}).get(self.lang) or ("Продавцю: " if self.lang == "uk" else "Seller: ")
            tip.update(gist=pre + gist, to="seller")
        return tip

    def tips(self, sit: dict, elapsed_s: float, recent_text: str = "") -> List[dict]:
        uk = self.lang == "uk"
        out: List[Optional[dict]] = []
        for o in self.objections:
            c = best_card(o["what"], self.cards)
            ans = (c or {}).get("answer") or o.get("answer") or ""
            out.append(self._tip("objection", o["what"][:40], o["what"], ans, o.get("t", "")))
        left = self.planned_s - elapsed_s
        if elapsed_s >= 0.4 * self.planned_s or left <= 600:
            for c in self.spec.get("criteria", []):
                if self.deal.get(c["key"], {}).get("state") == "unknown" and c["key"] != "next_step":
                    q = (c.get("ask") or {}).get(self.lang) or (c.get("ask") or {}).get("en") or [""]
                    name = c["name"].get(self.lang) or c["name"]["en"]
                    out.append(self._tip("qualify", c["key"], ("Ще не зʼясовано: " if uk else "Not clear yet: ") + name, q[0], ""))
                    break        # one qualify tip at a time
        pain = self.deal.get("pain") or self.deal.get("identify_pain")
        if pain and pain["state"] == "partial":
            out.append(self._tip("pain", "pain", ("Біль без масштабу: " if uk else "Pain without its size: ") + pain["what"],
                                 "Що буде, якщо нічого не змінювати?" if uk else "What happens if nothing changes?", pain["t"]))
        if left <= 300 and not (self.next_step.get("what") and self.next_step.get("due")):
            out.append(self._tip("next_step", "end", "Немає наступного кроку з датою" if uk else "No next step with a date yet",
                                 "Запропонуйте конкретний крок і дату зараз." if uk else "Propose a concrete step and a date now.", ""))
        for s in self.signals:
            out.append(self._tip("signal", s["what"][:40], s["what"], "Закріпіть: запропонуйте наступний крок зараз." if uk
                                 else "Lock it in: propose the next step now.", s.get("t", "")))
        for c in self.cards:
            if "competitor" in c["tags"] and words(c["title"]) & words(recent_text):
                out.append(self._tip("competitor", c["title"][:40], c["title"], c["answer"], ""))
        return [x for x in out if x]

    # ---- after the call (rules/sales.yaml > after_call)
    def summary(self, pm_share: Optional[float] = None, open_questions: int = 0) -> dict:
        return {"method": self.method, "criteria": list(self.deal.values()), "objections": self.objections,
                "next_step": self.next_step, "signals": self.signals,
                "scorecard": {"known": self.known(), "total": len(self.deal), "pm_talk_share": pm_share,
                              "open_questions": open_questions, "next_step_with_date": bool(self.next_step.get("due"))}}

    def write(self, path: Path, **kw) -> None:
        path.write_text(json.dumps(self.summary(**kw), ensure_ascii=False, indent=1), encoding="utf-8")


def methods_json(rules, lang: str = "en") -> dict:
    """The methods for the app's pickers (Start call, Settings > Projects): names, descriptions and criteria."""
    s = rules.sales or {}
    pick = lambda d: (d or {}).get(lang) or (d or {}).get("en") or ""  # noqa: E731
    out = []
    for key, m in (s.get("methods") or {}).items():
        out.append({"key": key, "name": pick(m.get("name")), "desc": pick(m.get("desc")), "chip": bool(m.get("chip")),
                    "criteria": [{"key": c["key"], "name": pick(c.get("name")), "explain": pick(c.get("explain"))}
                                 for c in m.get("criteria") or []]})
    return {"ok": True, "default": s.get("default_method", "general"), "methods": out}


def main(argv=None) -> int:
    import argparse
    from .rules import Rules
    ap = argparse.ArgumentParser()
    ap.add_argument("--methods", action="store_true")
    ap.add_argument("--lang", default="en")
    ap.add_argument("--cards", default="", help="a project folder: list its answer cards")
    a = ap.parse_args(argv)
    if a.cards:
        cards = load_cards(a.cards)
        print(json.dumps({"ok": True, "count": len(cards), "titles": [c.get("title", "") for c in cards]}, ensure_ascii=False))
        return 0
    print(json.dumps(methods_json(Rules(), a.lang), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
