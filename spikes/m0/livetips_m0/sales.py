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


CARD_TYPES = ("answer", "competitor", "price")
# S1: battlecard and price-limit lines of a card (rules/sales.yaml > answer_cards > fields)
CARD_FIELDS = {"they win:": "they_win", "we win:": "we_win", "trap:": "trap", "limit:": "limit"}


def parse_cards(text: str) -> List[dict]:
    """answer-cards.md: "## question or topic", the answer below, optional "Tags:" and "Use when:" lines.
    S1: optional "Type: answer|competitor|price", battlecard lines "They win:", "We win:", "Trap:" and a price
    "Limit:". A card without Type but with "Tags: competitor" is a competitor card (older files keep working)."""
    cards, cur = [], None
    for ln in (text or "").splitlines():
        if ln.startswith("## "):
            if cur:
                cards.append(cur)
            cur = {"title": ln[3:].strip(), "answer": [], "tags": [], "use_when": "", "type": "",
                   "they_win": "", "we_win": "", "trap": "", "limit": ""}
        elif cur is not None:
            low = ln.strip().lower()
            field = next((f for pre, f in CARD_FIELDS.items() if low.startswith(pre)), None)
            if low.startswith("tags:"):
                cur["tags"] = [t.strip().lower() for t in ln.split(":", 1)[1].split(",") if t.strip()]
            elif low.startswith("use when:"):
                cur["use_when"] = ln.split(":", 1)[1].strip()
            elif low.startswith("type:"):
                t = ln.split(":", 1)[1].strip().lower()
                cur["type"] = t if t in CARD_TYPES else ""
            elif field:
                cur[field] = ln.split(":", 1)[1].strip()
            elif ln.strip():
                cur["answer"].append(ln.strip())
    if cur:
        cards.append(cur)
    for c in cards:
        c["answer"] = " ".join(c["answer"])
        if not c["type"]:
            c["type"] = "competitor" if "competitor" in c["tags"] else ("price" if c["limit"] else "answer")
    return cards


def card_text(c: dict, lang: str = "en") -> str:
    """S1: a card in one line for the model and the tips: the answer plus its battlecard or limit lines."""
    uk = lang == "uk"
    parts = [c.get("answer") or ""]
    for f, en, ua in (("we_win", "We win", "Ми сильніші"), ("they_win", "They win", "Вони сильніші"),
                      ("trap", "Ask", "Спитайте"), ("limit", "Limit", "Межа")):
        if c.get(f):
            parts.append((ua if uk else en) + ": " + c[f])
    return " ".join(p for p in parts if p).strip()


def price_limits(cards: List[dict]) -> List[dict]:
    """S1: the price cards with a Limit line (rules/sales.yaml > tips > price_limit)."""
    return [c for c in cards or [] if c.get("type") == "price" and c.get("limit")]


def crm_stage(brief_path) -> str:
    """S1: the deal stage of the CRM snapshot next to the brief (<base>.brief.md -> <base>.crm.md, "- Stage:")."""
    if not brief_path:
        return ""
    p = Path(str(brief_path))
    name = p.name
    p = p.with_name((name[: -len(".brief.md")] if name.endswith(".brief.md") else p.stem) + ".crm.md")
    try:
        for ln in p.read_text(encoding="utf-8").splitlines():
            if ln.strip().lower().startswith("- stage:"):
                return ln.split(":", 1)[1].strip()
    except OSError:
        pass
    return ""


def match_stage(rules: dict, crm_name: str) -> str:
    """S1: a generic stage key (rules/sales.yaml > stages) for a CRM stage name, or "" when none matches."""
    low = re.sub(r"[\s_-]+", "", (crm_name or "").lower())
    if not low:
        return ""
    for key, st in (rules.get("stages") or {}).items():
        if any(str(w).lower() in low for w in st.get("words") or []):
            return key
    return ""


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
            "\n".join("- " + c["title"] + ": " + card_text(c) for c in hits) + "\n\n")


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
        self.judge = "seller" if self.spec.get("judge") == "seller" else "client"     # S1
        self.lang = "en" if lang == "en" else "uk"
        self.cards = cards or []
        self.planned_s = max(300.0, float(planned_s or 1800))
        self.deal: Dict[str, dict] = {c["key"]: {"criterion": c["key"], "state": "unknown", "what": "", "quote": "", "t": ""}
                                      for c in self.spec.get("criteria", [])}
        self.objections: List[dict] = []
        self.next_step: dict = {}
        self.signals: List[dict] = []
        # S1 (rules/sales.yaml > call_picture): the deal blocks beyond qualification
        self.competitors: List[dict] = []
        self.price_talk: List[dict] = []
        self.limit_breach: List[dict] = []
        self.stakeholders: List[dict] = []
        self.mutual_plan: List[dict] = []
        self.stage = ""            # the generic stage key (rules/sales.yaml > stages), "" when unknown
        self.stage_crm = ""        # the CRM's own stage name
        self.pm_fixed: Dict[str, dict] = {}
        self.fired: set = set()
        self.observed = False        # 0.8.7 (H2): tips address the seller the PM watches (rules/sales.yaml > coach)

    # ---- the call picture
    def criteria_text(self) -> str:
        return "\n".join("{} | {} | {}".format(c["key"], c["name"]["en"], c["explain"]["en"]) for c in self.spec.get("criteria", []))

    def set_stage(self, crm_name: str) -> None:
        """S1: the CRM's deal stage; its generic stage sets the focus (which criteria are asked first)."""
        self.stage_crm = str(crm_name or "")[:60]
        self.stage = match_stage(self.rules, self.stage_crm)

    def focus(self) -> List[str]:
        return list(((self.rules.get("stages") or {}).get(self.stage) or {}).get("focus") or [])

    def extra(self) -> tuple:
        cp = self.rules.get("call_picture") or {}
        key, rule = cp.get("key", ""), cp.get("rule", "")
        if self.judge == "seller":        # S1: an approach (Challenger) tracks what the seller does
            rule += "\n" + cp.get("judge_seller", "")
        rule += "\nQUALIFICATION CRITERIA (" + self.method + "; key | name | meaning):\n" + self.criteria_text()
        lim = price_limits(self.cards)
        if lim and cp.get("key_limits"):  # S1: price limits only from cards with Type price
            key += ", " + cp["key_limits"]
            rule += "\n" + cp.get("rule_limits", "") + "\nPRICE LIMITS:\n" + \
                "\n".join("- " + c["title"] + ": " + c["limit"] for c in lim[:8])
        return key, rule

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
        self._update_blocks(sit)

    def _update_blocks(self, sit: dict) -> None:
        """S1: competitors, prices, limit breaches, stakeholders and the mutual action plan; kept across steps."""
        for c in sit.get("competitors") or []:
            name = str(c.get("name") or "").strip()[:60]
            if name and not any(x["name"].lower() == name.lower() for x in self.competitors):
                self.competitors.append({"name": name, "what": str(c.get("what") or "")[:160], "t": str(c.get("t") or "")})
        for pt in sit.get("price_talk") or []:
            what = str(pt.get("what") or "").strip()[:160]
            if what and what not in [x["what"] for x in self.price_talk]:
                self.price_talk.append({"who": "us" if pt.get("who") == "us" else "them", "what": what, "t": str(pt.get("t") or "")})
        for b in sit.get("limit_breach") or []:
            what = str(b.get("what") or "").strip()[:160]
            if what and price_limits(self.cards) and what not in [x["what"] for x in self.limit_breach]:
                self.limit_breach.append({"what": what, "limit": str(b.get("limit") or "")[:160], "t": str(b.get("t") or "")})
        roles = ("decider", "champion", "blocker", "influencer", "user", "unknown")
        stances = ("for", "neutral", "against", "unknown")
        for p in sit.get("stakeholders") or []:
            name = str(p.get("name") or "").strip()[:60]
            if not name:
                continue
            role = p.get("role") if p.get("role") in roles else "unknown"
            stance = p.get("stance") if p.get("stance") in stances else "unknown"
            cur = next((x for x in self.stakeholders if x["name"].lower() == name.lower()), None)
            if cur is None:
                self.stakeholders.append({"name": name, "role": role, "stance": stance,
                                          "quote": str(p.get("quote") or "")[:200], "t": str(p.get("t") or "")})
                continue
            if role != "unknown":          # a known role or stance is never forgotten by a later "unknown"
                cur["role"] = role
            if stance != "unknown":
                cur["stance"] = stance
            if p.get("quote"):
                cur.update(quote=str(p["quote"])[:200], t=str(p.get("t") or cur["t"]))
        for m in sit.get("mutual_plan") or []:
            step = str(m.get("step") or "").strip()[:160]
            if not step:
                continue
            cur = next((x for x in self.mutual_plan if words(x["step"]) and
                        len(words(x["step"]) & words(step)) * 2 >= len(words(step))), None)
            row = {"step": step, "owner": str(m.get("owner") or "")[:40], "due": str(m.get("due") or "")[:30]}
            if cur is None:
                self.mutual_plan.append(row)
            else:
                cur.update({k: v for k, v in row.items() if v})
        self.mutual_plan = self.mutual_plan[:12]
        self.stakeholders = self.stakeholders[:12]

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
                "objections": self.objections, "next_step": self.next_step, "signals": self.signals,
                **self._blocks()}

    def _blocks(self) -> dict:
        """S1: the deal blocks for the Deal tab and the summary; the stage only when the CRM has one."""
        st = (self.rules.get("stages") or {}).get(self.stage) or {}
        return {"competitors": self.competitors, "price_talk": self.price_talk, "limit_breach": self.limit_breach,
                "stakeholders": self.stakeholders, "mutual_plan": self.mutual_plan, "stage": self.stage,
                "stage_crm": self.stage_crm, "stage_name": (st.get("name") or {}).get(self.lang, "")}

    # ---- tips (rules/sales.yaml > tips); each fires once
    def _tip(self, kind: str, key: str, gist: str, phrase: str, t: str, level: str = "orange") -> Optional[dict]:
        uid = "sales-" + kind + "-" + key
        if uid in self.fired:
            return None
        self.fired.add(uid)
        tip = {"kind": "tip", "sales": kind, "uid": uid, "level": level, "gist": gist, "phrase": phrase, "src": t,
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
            focus = self.focus()          # S1: the stage's criteria are asked first, then the method's order
            crit = sorted(self.spec.get("criteria", []), key=lambda c: focus.index(c["key"]) if c["key"] in focus else len(focus))
            for c in crit:
                if self.deal.get(c["key"], {}).get("state") == "unknown" and c["key"] != "next_step":
                    q = (c.get("ask") or {}).get(self.lang) or (c.get("ask") or {}).get("en") or [""]
                    name = c["name"].get(self.lang) or c["name"]["en"]
                    if self.judge == "seller":      # S1: Challenger, a step of the seller not done yet
                        head = "Ще не зроблено: " if uk else "Not done yet: "
                    else:
                        head = "Ще не зʼясовано: " if uk else "Not clear yet: "
                    out.append(self._tip("qualify", c["key"], head + name, q[0], ""))
                    break        # one qualify tip at a time
        # S1: the pain criterion of each method (SPIN problem, Sandler surface problem)
        pain = next((self.deal[k] for k in ("pain", "identify_pain", "problem", "surface_problem") if k in self.deal), None)
        if pain and pain["state"] == "partial":
            out.append(self._tip("pain", "pain", ("Біль без масштабу: " if uk else "Pain without its size: ") + pain["what"],
                                 "Що буде, якщо нічого не змінювати?" if uk else "What happens if nothing changes?", pain["t"]))
        if left <= 300 and not (self.next_step.get("what") and self.next_step.get("due")):
            out.append(self._tip("next_step", "end", "Немає наступного кроку з датою" if uk else "No next step with a date yet",
                                 "Запропонуйте конкретний крок і дату зараз." if uk else "Propose a concrete step and a date now.", ""))
        for s in self.signals:
            out.append(self._tip("signal", s["what"][:40], s["what"], "Закріпіть: запропонуйте наступний крок зараз." if uk
                                 else "Lock it in: propose the next step now.", s.get("t", "")))
        named = recent_text + " " + " ".join(x["name"] + " " + x["what"] for x in self.competitors)
        for c in self.cards:
            if c.get("type") == "competitor" and words(c["title"]) & words(named):
                out.append(self._tip("competitor", c["title"][:40], c["title"], card_text(c, self.lang), ""))
        out += self._block_tips(elapsed_s)
        return [x for x in out if x]

    def _block_tips(self, elapsed_s: float) -> List[Optional[dict]]:
        """S1 (rules/sales.yaml > tips): price_limit (red) and stakeholder."""
        uk = self.lang == "uk"
        out: List[Optional[dict]] = []
        lim = price_limits(self.cards)
        for b in self.limit_breach:
            c = next((x for x in lim if b["limit"] and (words(x["limit"]) & words(b["limit"]) or words(x["title"]) & words(b["limit"]))),
                     lim[0] if lim else None)
            limit = (c or {}).get("limit") or b["limit"]
            phrase = ("Уточню, що ми можемо зробити, і повернуся з точною пропозицією." if uk else
                      "Let me check what we can do and come back with an exact offer.")
            if c and c.get("answer"):
                phrase = c["answer"]
            out.append(self._tip("price_limit", b["what"][:40], ("Понад межу: " if uk else "Over the limit: ") + limit,
                                 phrase, b.get("t", ""), level="red"))
        if elapsed_s >= 0.4 * self.planned_s and not any(p["role"] == "decider" for p in self.stakeholders) \
                and not any(self.deal.get(k, {}).get("state") == "known" for k in ("authority", "economic_buyer", "decision")):
            out.append(self._tip("stakeholder", "decider", "Невідомо, хто вирішує" if uk else "Not known who decides",
                                 "Хто ще, крім вас, погоджуватиме це рішення?" if uk else
                                 "Who else besides you will sign off on this?", ""))
        for p in self.stakeholders:
            if p["role"] == "blocker" or p["stance"] == "against":
                out.append(self._tip("stakeholder", "blocker-" + p["name"][:30],
                                     ("Проти: " if uk else "Against: ") + p["name"] + (": " + p["quote"] if p["quote"] else ""),
                                     ("Що {} має побачити, щоб погодитися?" if uk else
                                      "What would {} need to see to be comfortable with this?").format(p["name"]), p.get("t", "")))
        return out

    # ---- after the call (rules/sales.yaml > after_call)
    def summary(self, pm_share: Optional[float] = None, open_questions: int = 0) -> dict:
        return {"method": self.method, "criteria": list(self.deal.values()), "objections": self.objections,
                "next_step": self.next_step, "signals": self.signals, **self._blocks(),
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
        kind = m.get("kind") or "qualification"
        out.append({"key": key, "name": pick(m.get("name")), "desc": pick(m.get("desc")), "chip": bool(m.get("chip")),
                    "kind": kind, "kind_name": pick((s.get("kinds") or {}).get(kind)) or kind,
                    "judge": "seller" if m.get("judge") == "seller" else "client",
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
