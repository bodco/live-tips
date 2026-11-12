"""0.10.0 (Meeting Sheet, phase 3): building and refreshing a sheet on every AI route.

  build(req)   -> the sheet: sources checked (sources.py), sized (size.py), the model asked with one contract
                  (prompt.py) in the mode the user chose (one pass | passes + merge | summaries of the biggest
                  sources first; never automatic), facts merged, conflicts marked, readiness applied, files written.
  refresh(req) -> the same against the existing sheet: new / changed / gone facts (diff), the user's edits kept
                  (merge.protect_edits), a new version.

Routes: packed (local, codex = ChatGPT account, openai, gemini, agy) get the sources inline through the providers the
old preparation used; the Claude routes (code = Claude Code on the plan, api = the same with the key) run `claude -p`
with Read/Grep/Glob over the sources only and WebFetch only to the sources' hosts; the manifest is what it opened.
Progress goes to stdout as JSON lines {"progress", "stage", "source_id"?, "pass"?}; the last line {"done": true, ...}.
One source failing never stops the rest; it is named in the report.

Files (base = <project>/live/prep-<yyyy-MM-dd-HHmm>-<slug>): <base>.sheet.json, <base>.sheet.v<N>.json,
<base>.sheet.md, <base>.sheet.sources.json (the report), <base>.sheet.request.json, and the live files of derive.py.
"""
import copy
import datetime as _dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple
from urllib.parse import urlparse

from . import SCHEMA
from . import merge as M
from . import presets as P
from . import prompt as PR
from . import readiness as R
from . import readers
from . import schema as S
from . import size as Z
from . import sources as SRC
from . import standup as SU

PACKED = ("local", "codex", "openai", "gemini", "agy", "fake")
CLAUDE = ("code", "api")
OUT_TOKENS = 16000
# 0.10.0 (bench 12.11): blocks of attributes, where one label has one value; only there two values are a conflict
CONFLICT_BLOCKS = {"company", "contact", "tech_stack", "project_context", "qualification", "interview_candidate",
                   "signals", "header", "fit"}


def say(**kw) -> None:
    print(json.dumps(kw, ensure_ascii=False), flush=True)


def now_iso() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def norm(s: str) -> str:
    return re.sub(r"[\W_]+", " ", (s or "").lower(), flags=re.U).strip()


def fact_key(block_type: str, f: dict) -> str:
    """The identity of a fact across builds: its block and label; a fact without a label by its text."""
    lab = norm(f.get("label") or "")
    if lab and block_type != "questions":
        v = f.get("value") or {}
        if v.get("key"):
            return f"{block_type}|key|{v['key']}"
        return f"{block_type}|{lab}"
    return f"{block_type}|t|{norm(f.get('text'))[:80]}"


def fact_id(block_type: str, key: str, n: int = 0) -> str:
    h = hashlib.sha1(key.encode("utf-8")).hexdigest()[:8]
    return f"f-{block_type}-{h}" + (f"-{n}" if n else "")


# ---------------------------------------------------------------- the model

class Asker:
    """One way to a model. ask() returns the answer text; tokens and money add up. Tests pass a responder."""

    def __init__(self, route: str, req: dict, responder: Optional[Callable[[str, str], str]] = None):
        self.route = Z.route_key(route)
        self.chosen = self.route
        self.req = req
        self.responder = responder
        self.tokens = {"input": 0, "output": 0}
        self.usd = 0.0
        self.model = req.get("model") or ""
        self.provider = None
        self.calls = 0
        # 0.10.0 (AI chain, owner 12.11): the next AIs of the chain (the app sends the connected, enabled ones in the
        # PM's order) and the switches made during this build (shown in the build views and the report)
        self.chain = [Z.route_key(r) for r in (req.get("chain") or []) if r and Z.route_key(r) != self.route]
        self.tried = [self.route]
        self.switches: List[dict] = []
        self.on_switch: Optional[Callable[[dict], None]] = None

    def _model_for(self, r: str) -> str:
        """The chosen route's model from the request; another AI of the chain its own (Settings > AI), else its default."""
        return (self.req.get("model") or "") if r == self.chosen else ((self.req.get("models") or {}).get(r) or "")

    def _state(self):
        st = os.environ.get("LT_AI_STATE")
        if not st:
            return None
        from ..routing import RouteState
        return RouteState(st)

    def can_run(self, r: str) -> bool:
        """The AI can be tried at all (its tool installed, its key given to this build)."""
        if r == "code":
            return bool(find_claude(self.req.get("claude")))
        if r == "api":
            return bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("CLAUDE_API"))
        if r == "codex":
            from ..codex_provider import find_codex_cli
            return bool(find_codex_cli())
        if r == "openai":
            return bool(os.environ.get("OPENAI_API_KEY"))
        if r == "gemini":
            return bool(os.environ.get("GEMINI_API_KEY"))
        if r == "agy":
            from ..agy_provider import find_agy_cli
            return bool(find_agy_cli())
        return r == "local"

    def switch(self, error: str, reason: str) -> Optional[str]:
        """0.10.0 (AI chain): the AI is out (a limit, no credit, a bad key, signed out): mark it until its reset time
        and go on with the next AI of the chain. None when there is none left."""
        st = self._state()
        if st is not None:
            from ..routing import reset_time
            st.mark_down(self.route, reason, reset_time(error))
        st_ok = None
        for r in self.chain:
            if r in self.tried:
                continue
            if st is not None and st.is_down(r) and not st.due(r, 900):
                continue
            if self.can_run(r):
                st_ok = r
                break
        if not st_ok:
            return None
        rec = {"from": self.route, "to": st_ok, "reason": reason, "error": str(error)[:160]}
        self.route = st_ok
        self.tried.append(st_ok)
        self.provider = None
        self.model = self._model_for(st_ok)
        self.switches.append(rec)
        if st is not None:
            from ..routing import note_switch
            note_switch("prep", rec["from"], st_ok, reason, st.path)
        if self.on_switch:
            self.on_switch(rec)
        return st_ok

    def _provider(self):
        if self.provider is not None:
            return self.provider
        r, req = self.route, self.req
        t = float(req.get("timeout") or 900)
        m = self._model_for(r)
        if r == "code":               # 0.10.0 (AI chain): a packed pass on the Claude account (no tools)
            from ..routing import ClaudeCodeProvider
            cli = find_claude(req.get("claude"))
            if not cli:
                raise RuntimeError("Claude Code is not installed")
            self.model = m or "sonnet"
            self.provider = ClaudeCodeProvider(cli, timeout=t)
        elif r == "api":              # 0.10.0 (AI chain): a packed pass on the Claude API key
            from ..providers import AnthropicProvider
            key = os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("CLAUDE_API") or ""
            if not key:
                raise RuntimeError("No API key: add it in Settings > AI > Claude")
            self.model = m if m.startswith("claude-") else "claude-sonnet-5-5"
            self.provider = AnthropicProvider(key, timeout=t, workspace_id=os.environ.get("CLAUDE_WORKSPACE", ""))
        elif r == "codex":
            from ..codex_provider import CodexProvider, MODEL, find_codex_cli
            cli = find_codex_cli()
            if not cli:
                raise RuntimeError("Codex CLI is not installed")
            self.model = MODEL
            self.provider = CodexProvider(cli, timeout=t)
        elif r == "openai":
            from ..openai_provider import OpenAIProvider, job_model
            key = os.environ.get("OPENAI_API_KEY", "")
            if not key:
                raise RuntimeError("No OpenAI API key: add it in Settings > AI > ChatGPT")
            self.model = job_model("prep", m)
            self.provider = OpenAIProvider(key, timeout=t, model=self.model)
        elif r == "gemini":
            from ..gemini_provider import GeminiProvider, job_model
            key = os.environ.get("GEMINI_API_KEY", "")
            if not key:
                raise RuntimeError("No Gemini API key: add it in Settings > AI > Gemini")
            self.model = job_model("prep", m)
            self.provider = GeminiProvider(key, timeout=t, model=self.model)
        elif r == "agy":
            from ..agy_provider import AgyProvider, find_agy_cli, job_model
            cli = find_agy_cli()
            if not cli:
                raise RuntimeError("Antigravity CLI is not installed: see Settings > AI > Gemini")
            self.model = job_model("prep", m)
            self.provider = AgyProvider(cli, timeout=t, model=self.model)
        elif r == "local":
            from ..providers import OllamaProvider
            self.model = m or "gemma4:26b"
            self.provider = OllamaProvider(req.get("url") or "http://127.0.0.1:11434", num_ctx=65536, timeout=max(t, 1800))
        else:
            raise RuntimeError(f"no packed provider for route {r}")
        return self.provider

    def ask(self, system: str, user: str, max_tokens: int = OUT_TOKENS) -> str:
        self.calls += 1
        if self.responder is not None:
            return self.responder(system, user)
        from ..routing import out_reason, note_account_usage
        while True:
            try:
                prov = self._provider()
            except RuntimeError as e:          # not installed, no key: the next AI of the chain, when there is one
                if self.route != self.chosen or self.chain:
                    if self.switch(str(e), "missing"):
                        continue
                raise
            res = prov.complete(model=self.model, system=[{"text": system}], user=user, max_tokens=max_tokens, cache_ttl=None)
            self.tokens["input"] += int(res.input_tokens or 0) + int(res.cache_read or 0)
            self.tokens["output"] += int(res.output_tokens or 0)
            try:
                from ..cost import cost_usd
                self.usd += cost_usd(res.model or self.model, res.input_tokens, res.cache_write_5m, res.cache_write_1h,
                                     res.cache_read, res.output_tokens) or 0.0
            except Exception:  # noqa: BLE001
                pass
            st = self._state()
            if st is not None:
                note_account_usage(self.route, getattr(res, "account_usage", None), st.path)
            if res.error:
                # 0.10.0 (AI chain): an outage (not a plain rate limit or a timeout) moves this pass to the next AI
                why = out_reason(self.route, res.error)
                if why and self.switch(res.error, why):
                    continue
                raise RuntimeError(str(res.error)[:300])
            if not (res.text or "").strip():
                raise RuntimeError("the model returned an empty answer")
            if st is not None:
                st.mark_up(self.route)
            return res.text


def find_claude(hint: Optional[str] = None) -> Optional[str]:
    home = os.path.expanduser("~")
    for p in (hint, os.environ.get("LT_CLAUDE_CLI"), shutil.which("claude"), home + "/.local/bin/claude",
              home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


# ---------------------------------------------------------------- web pages (packed routes)

PAGE_MAX_BYTES = 3_000_000


def robots_allowed(url: str, timeout: float = 10.0) -> bool:
    """0.10.0 (Meeting Sheet, hardening): robots.txt with a timeout (RobotFileParser.read() has none: a silent host
    hung the build). Unreachable or slow: allowed (the page itself decides); 401/403: not allowed."""
    import urllib.error
    import urllib.robotparser as RP
    u = urlparse(url)
    rp = RP.RobotFileParser(f"{u.scheme}://{u.netloc}/robots.txt")
    try:
        rq = urllib.request.Request(rp.url, headers={"User-Agent": "Pacenote (meeting sheet; one page the user linked)"})
        with urllib.request.urlopen(rq, timeout=timeout) as r:
            from .web import read_capped
            raw, _cut = read_capped(r, 500_000, timeout)
        rp.parse(raw.decode("utf-8", "replace").splitlines())
    except urllib.error.HTTPError as e:
        return e.code not in (401, 403)
    except Exception:  # noqa: BLE001
        return True
    return rp.can_fetch("Pacenote", url)


def fetch_page(url: str, timeout: float = 20.0) -> Tuple[str, Optional[str], int]:
    """One page, the user's own link, read once. robots.txt is honoured (with a timeout) until the browser module
    (phase 6) takes this over through sources.web_allowed. 0.10.0 (hardening): the whole read has `timeout` s, and
    the third value is the bytes read when the page was cut at PAGE_MAX_BYTES (0 = whole page)."""
    allowed = SRC.web_allowed(url)
    if allowed is None:
        allowed = robots_allowed(url)
    if not allowed:
        return "", "the site's robots.txt does not allow automatic reading", 0
    try:
        from .web import read_capped
        rq = urllib.request.Request(url, headers={"User-Agent": "Pacenote (meeting sheet; one page the user linked)"})
        with urllib.request.urlopen(rq, timeout=timeout) as r:
            ctype = r.headers.get("Content-Type", "")
            raw, cut = read_capped(r, PAGE_MAX_BYTES, timeout * 2)
        if "html" not in ctype and "text" not in ctype:
            return "", f"not a web page ({ctype.split(';')[0] or 'unknown type'})", 0
        text = readers.html_text(raw.decode("utf-8", "replace"))
        return text, None if text.strip() else "the page has no text", (len(raw) if cut else 0)
    except Exception as e:  # noqa: BLE001
        return "", f"cannot open the page: {type(e).__name__}", 0


def digest_text(req: dict) -> str:
    lt = req.get("lt")
    root = (req.get("project") or {}).get("root") or req.get("root")
    if not lt or not root:
        return ""
    try:
        r = subprocess.run(list(lt) + ["digest", os.path.expanduser(root), "--days", "14", "--max-chars", "8000"],
                           capture_output=True, text=True, timeout=90)
        return r.stdout
    except Exception:  # noqa: BLE001
        return ""


# ---------------------------------------------------------------- facts

def facts_from(answer: dict, blocks: List[dict], source_ids: set, checked_at: str, pass_n: int = 0) -> Dict[str, List[dict]]:
    """The model's facts per block type, cleaned: unknown blocks and source ids dropped, a "found" fact without a
    known source becomes needs_check (never shown as sourced when it is not)."""
    want = {b["type"] for b in blocks if b["type"] not in PR.SKIP_BLOCKS}
    out: Dict[str, List[dict]] = {}
    for t, facts in ((answer or {}).get("blocks") or {}).items():
        if t not in want or not isinstance(facts, list):
            continue
        for f in facts:
            if not isinstance(f, dict) or not str(f.get("text") or "").strip():
                continue
            ids = [x for x in (f.get("source_ids") or []) if isinstance(x, str) and x in source_ids]
            st = f.get("status") if f.get("status") in ("found", "needs_check", "not_found") else "found"
            if st == "found" and not ids:
                st = "needs_check"
            loc = f.get("locator") if isinstance(f.get("locator"), dict) else {}
            loc = {k: v for k, v in loc.items() if k in ("quote", "line", "page", "url", "slide", "cell") and v not in (None, "", [])}
            for k in ("line", "page", "slide"):
                if k in loc:
                    try:
                        loc[k] = int(loc[k])
                    except (TypeError, ValueError):
                        loc.pop(k)
            g = {"label": str(f.get("label") or "").strip(), "text": str(f["text"]).strip(), "source_ids": ids,
                 "locator": loc, "checked_at": checked_at, "status": st, "origin": "model"}
            if not g["label"]:
                g.pop("label")
            kw = [str(k).strip().lower() for k in (f.get("keywords") or []) if str(k).strip()]
            if kw:
                g["keywords"] = kw[:6]
            v = f.get("value") if isinstance(f.get("value"), dict) else {}
            v = {k: v[k] for k in ("key", "level", "owner", "due") if v.get(k)}
            if v.get("level") and v["level"] not in ("green", "yellow", "red", "unknown"):
                v.pop("level")
            if v:
                g["value"] = v
            if _date(f.get("as_of")):
                g["as_of"] = str(f["as_of"])[:10]        # 0.10.0 (round 2): the date the source says this was true
            if pass_n:
                g["pass"] = pass_n
            out.setdefault(t, []).append(g)
    return out


def merge_passes(parts: List[Dict[str, List[dict]]]) -> Dict[str, List[dict]]:
    """Facts of several passes in one sheet: the same fact (same block, label and text) once with the sources of
    both; a not_found replaced by a found of another pass; the rest kept (conflicts are marked after)."""
    out: Dict[str, List[dict]] = {}
    for part in parts:
        for t, facts in part.items():
            cur = out.setdefault(t, [])
            for f in facts:
                same = next((x for x in cur if norm(x.get("label", "")) == norm(f.get("label", ""))
                             and norm(x["text"]) == norm(f["text"])), None)
                if same:
                    same["source_ids"] = list(dict.fromkeys(same["source_ids"] + f["source_ids"]))
                    continue
                if f["status"] != "not_found":
                    k = fact_key(t, f)
                    cur[:] = [x for x in cur if not (x["status"] == "not_found" and fact_key(t, x) == k)]
                elif any(fact_key(t, x) == fact_key(t, f) and x["status"] != "not_found" for x in cur):
                    continue
                elif any(x["status"] == "not_found" and fact_key(t, x) == fact_key(t, f) for x in cur):
                    continue
                cur.append(f)
    return out


def _date(s: Optional[str]) -> Optional[_dt.date]:
    try:
        return _dt.date.fromisoformat(str(s)[:10]) if s else None
    except ValueError:
        return None


# 0.10.0 (Meeting Sheet, round 2): newer wins. A changed decision ("moves production to November 19") or a dated
# status ("as of November 3") beats the value an older note still holds; "conflict" only when the dates are equal or
# unknown. The older fact stays as "stale" with conflict_with and superseded_by pointing to the newer one ("was X").
_MONTHS = {m: i + 1 for i, m in enumerate(("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"))}
_UK_MONTHS = {"січ": 1, "лют": 2, "берез": 3, "квіт": 4, "трав": 5, "черв": 6, "лип": 7, "серп": 8, "верес": 9,
              "жовт": 10, "листопад": 11, "груд": 12}
_D_ISO = r"(\d{4}-\d{2}-\d{2})"
_D_EN = r"((?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?|\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*(?:\s+\d{4})?)"
_D_UK = r"(\d{1,2}\s+(?:січ|лют|берез|квіт|трав|черв|лип|серп|верес|жовт|листопад|груд)\w*(?:\s+\d{4})?|\d{1,2}\.\d{1,2}(?:\.\d{4})?)"
_D_ANY = "(?:" + "|".join((_D_ISO, _D_EN, _D_UK)) + ")"
_ASOF_BEFORE = re.compile(r"(?:\bas of|\bas at|\bsnapshot of|\bstatus of|\bupdated(?: on)?|\bdated|\bsigned(?: on)?|\bdecided(?: on)?|"
                          r"\bagreed(?: on)?|^on|^\W*on|станом на|від|оновлено)\s+" + _D_ANY, re.I | re.U)
_ASOF_AFTER = re.compile(_D_ANY + r"(?:,?\s+\d{1,2}:\d{2})?\s+(?:decision|snapshot|current state|status|update|register|"
                         r"note|notes|call|meeting|plan|рішення|статус|стан|нотатк|дзвін|зустріч)", re.I | re.U)
CHANGE_CUE = re.compile(r"\b(?:mov(?:e|es|ed|ing)|chang(?:e|es|ed|ing)|replac(?:e|es|ed|ing)|postpon\w*|push(?:es|ed)?\s+(?:back|to)|"
                        r"reschedul\w*|instead of|no longer|amend\w*|revis\w*|supersed\w*|overrid\w*|shift(?:s|ed)?\s+to|"
                        r"now (?:is|set|planned|scheduled))\b|перенес|змінен|змінил|замість|тепер|поправк|переглянут", re.I | re.U)
OLD_CUE = re.compile(r"\b(?:still\s+(?:list|has|have|say|show|hold|record|use|read|state|mention|name|give|put|carr|keep|point)\w*|older|outdated|originally|original|previous(?:ly)?|earlier version|old (?:plan|version|value|date))\b|"
                     r"досі|раніше|старий|старіш|попередн|початков|первісн", re.I | re.U)


def parse_day(text: str, year: Optional[int] = None) -> Optional[_dt.date]:
    """One date as written in a fact: 2026-11-04, November 4, Nov 4 2026, 4 November, 4 листопада, 04.11.2026."""
    t = (text or "").strip().lower().rstrip(".,")
    y = year or _dt.date.today().year
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", t):
            return _dt.date.fromisoformat(t)
        m = re.fullmatch(r"(\d{1,2})\.(\d{1,2})(?:\.(\d{4}))?", t)
        if m:
            return _dt.date(int(m.group(3) or y), int(m.group(2)), int(m.group(1)))
        m = re.fullmatch(r"([a-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?", t)
        if m and m.group(1)[:3] in _MONTHS:
            return _dt.date(int(m.group(3) or y), _MONTHS[m.group(1)[:3]], int(m.group(2)))
        m = re.fullmatch(r"(\d{1,2})\s+(\w+?)(?:\s+(\d{4}))?", t, re.U)
        if m:
            w = m.group(2)
            mon = _MONTHS.get(w[:3]) if w[:3] in _MONTHS else next((v for k, v in _UK_MONTHS.items() if w.startswith(k)), None)
            if mon:
                return _dt.date(int(m.group(3) or y), mon, int(m.group(1)))
    except ValueError:
        return None
    return None


def fact_as_of(f: dict, year: Optional[int] = None) -> Optional[_dt.date]:
    """The date a fact was true or decided: the model's as_of, else a dated status in its text or quote."""
    d = _date(f.get("as_of"))
    if d:
        return d
    for t in (f.get("text") or "", (f.get("locator") or {}).get("quote") or ""):
        for rx in (_ASOF_BEFORE, _ASOF_AFTER):
            m = rx.search(t)
            if m:
                d = parse_day(next(g for g in m.groups() if g), year)
                if d:
                    return d
    return None


def _source_day(f: dict, sources: Dict[str, dict]) -> Optional[_dt.date]:
    ds = [_date(sources.get(i, {}).get("modified_at")) for i in f.get("source_ids") or []]
    ds = [d for d in ds if d]
    return max(ds) if ds else None


def _newest_unique(fs: List[dict], day) -> Optional[List[dict]]:
    """The facts with the newest date when every fact has a date and the newest is newer than the rest; else None."""
    ds = [(day(f), f) for f in fs]
    if not all(d for d, _ in ds):
        return None
    top = max(d for d, _ in ds)
    win = [f for d, f in ds if d == top]
    return win if len(win) < len(fs) else None


def pick_newer(fs: List[dict], sources: Dict[str, dict], year: Optional[int] = None) -> Optional[List[dict]]:
    """Which facts of a disagreeing group win (newer), or None for a real conflict (dates equal or unknown)."""
    asof = {id(f): fact_as_of(f, year) for f in fs}
    # 1. a value a note itself calls old ("the config still lists ...", "the older plan") loses to the others
    old = [f for f in fs if OLD_CUE.search(f.get("text") or "")]
    live = [f for f in fs if f not in old] if old and len(old) < len(fs) else list(fs)
    # 2. a changed decision beats the value it changed, unless that value is dated later than the change
    chg = [f for f in live if CHANGE_CUE.search(f.get("text") or "")]
    if chg and len(chg) < len(live):
        rest = [f for f in live if f not in chg]
        latest_chg = max((asof[id(f)] for f in chg if asof[id(f)]), default=None)
        if not any(asof[id(f)] and (latest_chg is None or asof[id(f)] > latest_chg) for f in rest):
            return chg
    if len({norm(f["text"]) for f in live}) < 2:
        return live if len(live) < len(fs) else None
    # 3. dates: the facts' own dates when they have them, else the sources' dates (file name or modified)
    if any(asof[id(f)] for f in live):
        win = _newest_unique(live, lambda f: asof[id(f)])
    else:
        win = _newest_unique(live, lambda f: _source_day(f, sources))
    if win:
        return win
    return live if len(live) < len(fs) else None


def mark_conflicts(facts: Dict[str, List[dict]], sources: Dict[str, dict], stale_months: int = 6,
                   year: Optional[int] = None) -> int:
    """Same attribute (block + label, or criterion key), different values from different sources: both facts stay.
    The newer one (pick_newer) is found and the older ones stale, linked by conflict_with and superseded_by after the
    ids are assigned; when nothing says which is newer, all are "conflict". Returns the number of conflict groups.
    stale_months is kept for the callers: a newer fact wins at any age now (round 2)."""
    groups = 0
    for t, lst in facts.items():
        if t not in CONFLICT_BLOCKS:
            continue                 # list blocks (agenda, questions, outcomes, history...) hold many items per label
        by: Dict[str, List[dict]] = {}
        for f in lst:
            if f["status"] == "not_found" or not f.get("label") and not (f.get("value") or {}).get("key"):
                continue
            if not f.get("source_ids"):
                continue             # 0.10.0 (round 2): a fact without a known source is needs_check, never a side of a conflict
            by.setdefault(fact_key(t, f), []).append(f)
        for k, fs in by.items():
            vals = {norm(f["text"]) for f in fs}
            srcs = {tuple(sorted(f["source_ids"])) for f in fs}
            if len(fs) < 2 or len(vals) < 2 or len(srcs) < 2:
                continue
            win = pick_newer(fs, sources, year)
            if win:
                wvals = {norm(f["text"]) for f in win}
                for f in win:
                    f["status"] = "conflict" if len(win) > 1 and len(wvals) > 1 else "found"
                for f in fs:
                    if f not in win:
                        f["status"] = "stale"
                        f["_newer"] = win
                if len(win) > 1 and len(wvals) > 1:
                    groups += 1
                continue
            groups += 1
            for f in fs:
                f["status"] = "conflict"
    return groups


def assign_ids(facts: Dict[str, List[dict]]) -> None:
    for t, lst in facts.items():
        seen: Dict[str, int] = {}
        for f in lst:
            k = fact_key(t, f)
            n = seen.get(k, 0)
            seen[k] = n + 1
            f["id"] = fact_id(t, k + ("|" + norm(f["text"])[:60] if n else ""), 0) if not n else fact_id(t, k, n)
    # conflict partners
    for t, lst in facts.items():
        by: Dict[str, List[dict]] = {}
        for f in lst:
            if f["status"] == "conflict":
                by.setdefault(fact_key(t, f), []).append(f)
        for fs in by.values():
            for f in fs:
                f["conflict_with"] = [x["id"] for x in fs if x is not f]
        for f in lst:
            if f["status"] == "conflict" and not f.get("conflict_with"):
                f["status"] = "needs_check"
    # 0.10.0 (Meeting Sheet, round 2): an older value points to the newer one ("was X" in the UI)
    for lst in facts.values():
        for f in lst:
            newer = f.pop("_newer", None)
            if newer:
                f["conflict_with"] = [x["id"] for x in newer]
                f["superseded_by"] = newer[0]["id"]


def header_facts(req: dict, src_id: str, checked_at: str) -> List[dict]:
    m = req.get("meeting") or {}
    p = req.get("participants") or {}
    out = []
    def add(label, text):
        if text:
            out.append({"id": "f-header-" + norm(label).replace(" ", "-"), "label": label, "text": text,
                        "source_ids": [src_id], "locator": {}, "checked_at": checked_at, "status": "found", "origin": "model"})
    when = m.get("start", "")
    if m.get("end"):
        when += " - " + m["end"][11:16] if len(m["end"]) > 15 else ""
    add("When", (when + (f" ({m['tz']})" if m.get("tz") else "")).strip())
    add("Where", m.get("where", ""))
    add("Our side", ", ".join(x.get("name", "") + (f" ({x['role']})" if x.get("role") else "") for x in p.get("ours") or []))
    add("Their side", ", ".join(x.get("name", "") + (f" ({x['role']})" if x.get("role") else "")
                                 + (f", {x['company']}" if x.get("company") else "") for x in p.get("theirs") or []))
    add("Meeting type", req.get("call_type", ""))
    add("Goal", req.get("goal", ""))
    return out


def gap_facts(facts: Dict[str, List[dict]], blocks: List[dict], checked_at: str) -> List[dict]:
    title = {b["type"]: b.get("title", b["type"]) for b in blocks}
    out = []
    for t, lst in facts.items():
        for f in lst:
            if f.get("superseded_by"):
                continue                  # 0.10.0 (round 2): replaced by a newer value, not a gap
            what = {"conflict": "Sources disagree", "not_found": "Not found", "stale": "Old"}.get(f["status"])
            if not what or t == "questions":
                continue
            out.append({"id": "f-gap-" + f["id"][2:], "label": f"{what}: {title.get(t, t)}",
                        "text": (f.get("label") + ": " if f.get("label") else "") + f["text"], "source_ids": [],
                        "locator": {}, "checked_at": checked_at, "status": "needs_check", "origin": "readiness",
                        "about": f["id"]})
    return out


# ---------------------------------------------------------------- the Claude routes

def claude_files(sources: List[dict], texts: Dict[str, str], cache_dir: str) -> Dict[str, str]:
    """What Claude opens: the original file when Read handles it (text, pdf), else a text copy of what the reader
    got (pptx, xlsx, docx, Google and Notion copies) in a cache folder next to the sheet."""
    files = {}
    for s in sources:
        if s.get("access") != "ok" or s["id"] not in texts:
            continue
        p = s.get("copy") or s.get("path")
        if not p:
            continue
        p = os.path.expanduser(p)
        if p.lower().endswith((".md", ".txt", ".csv", ".pdf", ".json", ".yaml", ".yml")):
            files[s["id"]] = p
        else:
            os.makedirs(cache_dir, exist_ok=True)
            out = os.path.join(cache_dir, f"{s['id']}.txt")
            Path(out).write_text(texts[s["id"]], encoding="utf-8")
            files[s["id"]] = out
    return files


def run_claude(req: dict, prompt: str, files: Dict[str, str], hosts: List[str], emit, sources: List[dict]) -> Tuple[str, dict]:
    """claude -p with least privilege: Read/Grep/Glob, the source folders added, WebFetch only to the sources'
    hosts, everything else denied. Returns (final text, meta {read, cost_usd, turns, model})."""
    claude = find_claude(req.get("claude"))
    if not claude:
        raise RuntimeError("Claude Code is not installed")
    route = Z.route_key(req.get("route") or "code")
    dirs = sorted({os.path.dirname(p) for p in files.values()})
    allowed = ["Read", "Grep", "Glob"] + [f"WebFetch(domain:{h})" for h in hosts]
    denied = ["Bash", "Write", "Edit", "NotebookEdit", "Task", "WebSearch"] + ([] if hosts else ["WebFetch"])
    args = [claude, "-p", prompt, "--model", req.get("model") or "sonnet", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "default", "--allowedTools", ",".join(allowed), "--disallowedTools", ",".join(denied),
            "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
    for d in dirs:
        args += ["--add-dir", d]
    if route == "api" and req.get("max_budget_usd"):
        args += ["--max-budget-usd", "%.2f" % float(req["max_budget_usd"])]
    env = dict(os.environ)
    if route != "api":                       # the account pays, never a key that happens to be in the environment
        env.pop("ANTHROPIC_API_KEY", None)
        env.pop("ANTHROPIC_CUSTOM_HEADERS", None)
    cwd = tempfile.mkdtemp(prefix="pacenote-sheet-")
    by_path = {v: k for k, v in files.items()}
    meta = {"read": [], "fetched": [], "turns": 0, "cost_usd": None, "model": req.get("model") or "sonnet"}
    final = ""
    # 0.10.0 (Meeting Sheet, hardening): its own process group, so the watchdog stops claude and anything it started
    p = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         start_new_session=True)
    deadline = time.time() + float(req.get("timeout") or 1500)
    n_src = max(1, len(files))
    # 0.10.0 (Meeting Sheet, hardening): a watchdog, so `claude -p` that prints nothing (signed out, a hung tool, no
    # network) cannot hold the build forever: no output for `inactivity_s` (default 240 s) or past the deadline stops
    # it with a clear error in the report.
    quiet_s = float(req.get("inactivity_s") or 240)
    last = [time.time()]
    why: List[str] = []

    def watchdog():
        while p.poll() is None:
            now = time.time()
            if now - last[0] > quiet_s:
                why.append("Claude Code stopped answering: no output for %d s, the build was stopped" % int(quiet_s))
            elif now > deadline:
                why.append("Claude Code took too long (over %d s), the build was stopped" % int(float(req.get("timeout") or 1500)))
            if why:
                try:
                    import signal
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    try:
                        p.kill()
                    except OSError:
                        pass
                return
            time.sleep(min(1.0, quiet_s / 4))
    threading.Thread(target=watchdog, name="pacenote-claude-watchdog", daemon=True).start()
    for line in p.stdout:
        last[0] = time.time()
        if time.time() > deadline:
            p.kill()
            raise RuntimeError("Claude Code took too long")
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "rate_limit_event" and route != "api" and os.environ.get("LT_AI_STATE"):   # 0.10.0 (AI chain)
            from ..routing import account_usage_claude, note_account_usage
            note_account_usage("code", account_usage_claude(ev), os.environ["LT_AI_STATE"])
        if ev.get("type") == "assistant":
            for c in (ev.get("message") or {}).get("content") or []:
                if c.get("type") == "tool_use":
                    inp = c.get("input") or {}
                    if c.get("name") == "Read" and inp.get("file_path"):
                        fp = inp["file_path"]
                        meta["read"].append(fp)
                        sid = by_path.get(fp)
                        emit(progress=round(0.15 + 0.6 * min(1.0, len(set(meta["read"])) / n_src), 3),
                             stage="reading", source_id=sid, file=os.path.basename(fp))
                    elif c.get("name") == "WebFetch" and inp.get("url"):
                        meta["fetched"].append(inp["url"])
                        emit(progress=0.6, stage="reading", url=inp["url"])
                elif c.get("type") == "text" and c.get("text"):
                    final = c["text"]
        elif ev.get("type") == "result":
            meta["turns"] = ev.get("num_turns") or 0
            meta["cost_usd"] = ev.get("total_cost_usd")
            if ev.get("is_error"):
                raise RuntimeError(str(ev.get("result") or "Claude Code failed")[:300])
            final = ev.get("result") or final
            u = ev.get("usage") or {}
            meta["tokens"] = {"input": int(u.get("input_tokens") or 0) + int(u.get("cache_read_input_tokens") or 0)
                              + int(u.get("cache_creation_input_tokens") or 0), "output": int(u.get("output_tokens") or 0)}
    err = p.stderr.read() if p.stderr else ""
    p.wait()
    shutil.rmtree(cwd, ignore_errors=True)
    if why:
        raise RuntimeError(why[0])
    if p.returncode != 0 and not final:
        raise RuntimeError(("Claude Code: " + err.strip().splitlines()[-1]) if err.strip() else f"Claude Code exited {p.returncode}")
    return final, meta


# ---------------------------------------------------------------- the build

def base_of(req: dict) -> str:
    if req.get("base"):
        return os.path.expanduser(req["base"])
    root = os.path.expanduser((req.get("project") or {}).get("root") or req.get("root") or ".")
    m = req.get("meeting") or {}
    start = (m.get("start") or now_iso())[:16].replace("T", "-").replace(":", "")
    slug = re.sub(r"[^a-z0-9]+", "-", (m.get("title") or "meeting").lower()).strip("-") or "meeting"
    return os.path.join(root, "live", f"prep-{start}-{slug}")


def _write_json(path: str, obj) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    tmp.replace(p)


def next_version(base: str) -> int:
    n = 0
    d, stem = os.path.split(base)
    try:
        for name in os.listdir(d or "."):
            m = re.match(re.escape(stem) + r"\.sheet\.v(\d+)\.json$", name)
            if m:
                n = max(n, int(m.group(1)))
    except OSError:
        pass
    return n + 1


NUM = re.compile(r"\d[\d.,:/-]*")


def similar(a: str, b: str) -> bool:
    """The same statement in other words: the same numbers and dates, and most of the words shared."""
    if sorted(NUM.findall(a or "")) != sorted(NUM.findall(b or "")):
        return False
    wa, wb = set(norm(a).split()), set(norm(b).split())
    if not wa or not wb:
        return wa == wb
    return len(wa & wb) / len(wa | wb) >= 0.5


def diff(old: dict, new: dict) -> dict:
    """new / changed / gone by fact identity (block + label, or text; a relabelled fact with similar text is the
    same fact); a reworded fact with the same numbers is not "changed". Readiness facts and edits are not compared."""
    def index(sheet):
        out = {}
        for b in sheet.get("blocks") or []:
            for f in b.get("facts") or []:
                if f.get("origin") in ("readiness",) or M.is_protected(f):
                    continue
                out[fact_key(b["type"], f)] = (b["type"], f)
        return out
    a, b = index(old), index(new)
    # a fact the model relabelled: same block, similar text -> the same fact
    left = {k: v for k, v in a.items() if k not in b}
    for k, (t, f) in list(b.items()):
        if k in a:
            continue
        hit = next((ok for ok, (ot, of) in left.items() if ot == t and similar(of.get("text", ""), f.get("text", ""))), None)
        if hit:
            a[k] = left.pop(hit)
            a.pop(hit, None)
    res = {"new": [], "changed": [], "gone": [], "gone_facts": []}
    for k, (t, f) in b.items():
        if k not in a:
            res["new"].append(f["id"])
            f["diff"] = "new"
        elif a[k][1].get("status") != f.get("status") or not similar(a[k][1].get("text", ""), f.get("text", "")):
            res["changed"].append(f["id"])
            f["diff"] = "changed"
            f["was"] = a[k][1].get("text")
        else:
            f.pop("diff", None)
    for k, (t, f) in a.items():
        if k not in b:
            res["gone"].append(f["id"])
            res["gone_facts"].append({"id": f["id"], "block": t, "label": f.get("label", ""), "text": f.get("text", "")})
    return res


class Control:
    """0.10.0 (Meeting Sheet, round 2): Retry / Skip from the build screen (S5). The app writes a small JSON file
    (request "control": path) {"actions": [{"action": "retry" | "skip", "source_id": "s3"}, ...]} and only appends;
    the build reads it between sources and before every pass and handles each action once. No file: nothing."""

    def __init__(self, path: Optional[str]):
        self.path = os.path.expanduser(path) if path else None
        self.seen = 0

    def poll(self) -> List[dict]:
        if not self.path:
            return []
        try:
            acts = json.loads(Path(self.path).read_text(encoding="utf-8")).get("actions") or []
        except (OSError, ValueError, AttributeError):
            return []
        new = [a for a in acts[self.seen:] if isinstance(a, dict) and a.get("action") in ("retry", "skip") and a.get("source_id")]
        self.seen = len(acts)
        return new


def _wanted(b: dict, only: set) -> bool:
    return not only or b.get("id") in only or b.get("type") in only


def build(req: dict, refresh: bool = False, emit=say, responder: Optional[Callable[[str, str], str]] = None) -> dict:
    t0 = time.time()
    rules = P.load_rules()
    route = Z.route_key(req.get("route") or "codex")
    req = dict(req, route=route)
    lang = req.get("language") or "en"
    call_langs = req.get("languages") or [lang]
    sett = R.settings_of(rules, req.get("settings"))
    stale_months = int(sett.get("stale_months") or 6)
    base = base_of(req)
    checked = now_iso()
    old = None
    if refresh:
        try:
            old = json.loads(Path(base + ".sheet.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            old = None
    emit(progress=0.02, stage="sources")
    notes: List[str] = []
    if old:
        req["_previous_labels"] = PR.previous_labels(old)
    # the sheet skeleton: the preset's blocks (or the request's own list)
    meeting = dict(req.get("meeting") or {})
    meeting.setdefault("start", now_iso())
    try:
        sheet = P.new_sheet(rules, req.get("preset") or (old or {}).get("preset") or "blank", meeting,
                            copy.deepcopy(req.get("participants")), lang, route, req.get("project"), req.get("mode"),
                            req.get("goal"), req.get("call_type", ""), req.get("audience", ""), req.get("app_root"),
                            sheet_id=(old or {}).get("id") or req.get("id"))
    except KeyError as e:
        return {"error": str(e).strip("'\""), "code": 3}
    if req.get("blocks"):
        lib = rules.get("blocks") or {}
        keep = {b["type"]: b for b in sheet["blocks"]}
        bl = []
        for i, t in enumerate(req["blocks"]):
            d = t if isinstance(t, dict) else {"type": t}
            t = d.get("type")
            if t not in lib:
                continue
            b = keep.get(t) or {"id": f"b-{t}", "type": t, "title": lib[t].get("title", t), "visible": True,
                                "only_if_data": bool(lib[t].get("only_if_data")), "facts": [], "edited_by_user": False}
            b["order"] = i
            # 0.10.0 (Meeting Sheet, round 2): the wizard's eye (visible), "Only if there is data", title and method
            if "visible" in d:
                b["visible"] = bool(d["visible"])
            if "only_if_data" in d:
                b["only_if_data"] = bool(d["only_if_data"])
            if d.get("title"):
                b["title"] = str(d["title"])
            if t == "qualification" and d.get("method"):
                b["method"] = str(d["method"])
            bl.append(b)
        sheet["blocks"] = bl
    for b in sheet["blocks"]:
        if b["type"] == "qualification" and req.get("method"):
            b["method"] = req["method"]
    if old:
        sheet["versions"] = list(old.get("versions") or [])
    # 0.10.0 (Meeting Sheet, round 2): options.blocks = regenerate only these blocks (ids or types), the rest and the
    # edits stay as they were; options.find_again = a gap or fact id searched once more (its block only, a pointed
    # note to the model). Both need the previous sheet; a first build always builds every visible block.
    opts = req.get("options") if isinstance(req.get("options"), dict) else {}
    only = {str(x) for x in (opts.get("blocks") or []) if x} if old else set()
    find_note = ""
    if old and opts.get("find_again"):
        fa = opts["find_again"] if isinstance(opts["find_again"], list) else [opts["find_again"]]
        gaps = {g.get("id"): g for g in (old.get("readiness") or {}).get("gaps") or []}
        ofacts = {f.get("id"): (b, f) for b in old.get("blocks") or [] for f in b.get("facts") or []}
        lines = []
        for x in fa:
            g = gaps.get(x) or {}
            fid = g.get("fact") or (x if x in ofacts else None)
            ob, of = ofacts.get(fid, (None, None))
            bid = g.get("block") or (ob or {}).get("id")
            if bid:
                only.add(bid)
            what = g.get("text") or ""
            if of:
                what += (" | now: " if what else "") + ((of.get("label") + ": ") if of.get("label") else "") + (of.get("text") or "")
            if what:
                lines.append("- " + what)
        if lines:
            find_note = ("\n\n## Find again (the person asked to look once more)\n" + "\n".join(lines) +
                         "\nSearch every source for exactly this. When a source says it, write it as found with a quote; "
                         "when two sources disagree, write both with their as_of; only when no source says it, not_found.")
            notes.append("Find again: " + "; ".join(l[2:] for l in lines)[:300])
    if only:
        notes.append("Rebuilt only: " + ", ".join(sorted(only)) + "; the other blocks kept as they were.")
    ask_blocks = [b for b in sheet["blocks"] if b.get("visible", True) and _wanted(b, only)]
    control = Control(req.get("control"))
    wait_s = float(req.get("control_wait_s") or 0)
    # the sources: the invitation header first, then what the user ticked
    raw = [{"id": "s-meeting", "type": "text", "title": "Meeting invitation", "text": PR.header_text(req), "role": "invite"}]
    raw += list(req.get("sources") or [])
    ctx = (req.get("context") or "").strip()
    if ctx and not any(s.get("role") == "context" for s in raw):
        raw.append({"id": "s-context", "type": "text", "title": "Call context", "text": ctx, "role": "context"})
    for s in raw:
        if s.get("type") == "digest" and not s.get("text") and not s.get("path"):
            s["text"] = digest_text(req)
    # 0.10.0 (Meeting Sheet, fix 2026-11-12, owner): every build (Quick, Expert, Up next, also when the series memory
    # or the wizard lists sources) reads the series, the Tracker, the project state and the digest; a Tracker the
    # request already carries is replaced by today's. auto_sources: false in the request turns this off (tests).
    tracker, auto_n = None, {}
    if req.get("auto_sources", True):
        have = {os.path.realpath(os.path.expanduser(s.get("path") or "")) for s in raw if s.get("path")}
        try:
            autos = SRC.auto_sources(req)
        except Exception as e:  # noqa: BLE001
            autos = []
            notes.append(f"Auto sources failed: {type(e).__name__}")
        for c in autos:
            if c.get("path") and os.path.realpath(os.path.expanduser(c["path"])) in have:
                continue
            if c["type"] == "tracker":
                tracker = c.pop("_tracker", None)
                raw = [s for s in raw if s.get("type") != "tracker"]
                c["id"] = "s-tracker"
            if c["type"] == "digest" and c.get("cmd"):
                if any(s.get("type") == "digest" and str(s.get("title") or "").startswith("Digest of") for s in raw):
                    continue                     # the wizard ticked the digest: filled above, once
                c["text"] = digest_text(req)
                if not c["text"].strip():
                    continue
            if c.get("path"):
                have.add(os.path.realpath(os.path.expanduser(c["path"])))
            auto_n[c["type"]] = auto_n.get(c["type"], 0) + 1
            raw.append({k: v for k, v in c.items() if k not in ("suggested", "score", "kind", "cmd")})
        if auto_n:
            notes.append("Sources added by Pacenote: " + ", ".join(f"{k} {v}" for k, v in sorted(auto_n.items())) + ".")
    # 0.10.0 (bridge until the wizard): Prepare without the wizard also picks the best matching folder files
    if req.get("auto_pick"):
        have = {os.path.expanduser(s.get("path") or "") for s in raw if s.get("path")}
        try:
            cands = [c for c in SRC.candidates(req, int(req.get("auto_pick") or 12) + 20)["candidates"]
                     if c["type"] == "folder_file" or not req.get("auto_sources", True)]
        except Exception:  # noqa: BLE001
            cands = []
        n_folder = 0
        for c in cands:
            c.pop("_tracker", None)
            if c.get("path") and os.path.expanduser(c["path"]) in have:
                continue
            if c["type"] == "folder_file":
                if not c.get("suggested") and (c.get("why") == ["rest of the folder"] or n_folder >= int(req["auto_pick"])):
                    continue
                n_folder += 1
            if c["type"] == "digest" and c.get("cmd"):
                c["text"] = digest_text(req)
                if not c["text"].strip():
                    continue
            raw.append({k: v for k, v in c.items() if k not in ("suggested", "score", "kind", "cmd")})
        notes.append("Sources picked by the app (Prepare without the wizard): the series, the project state and "
                     f"the {n_folder} best matching folder files.")
    if req.get("route_switch"):
        sw = req["route_switch"]
        notes.append(f"Route switched from {sw.get('from')} to {sw.get('to')}: {sw.get('reason', '')} (nobody was there to ask).")
    srcs = SRC.normalize(raw)
    texts: Dict[str, str] = {}
    windows = Z.load_windows()
    report_rows = []
    by_sid = {s["id"]: s for s in srcs}
    raw_text = {s["id"]: s.get("text") for s in srcs if s.get("text")}
    skipped_by_user: set = set()

    def check_one(s: dict, i: int) -> None:
        if raw_text.get(s["id"]) and not s.get("text"):
            s["text"] = raw_text[s["id"]]
        SRC.check(s, req, texts, route, windows)
        if s.get("fetch") and route in PACKED and route != "fake":
            emit(progress=0.03 + 0.07 * i / max(1, len(srcs)), stage="reading", source_id=s["id"])
            text, why, cut = fetch_page(s["uri"])
            if cut:
                s["cut"] = {"read_bytes": cut, "limit_bytes": PAGE_MAX_BYTES}
            if text:
                texts[s["id"]] = text
                s["chars"] = len(text)
                s["size_tokens"] = Z.estimate(text, route, windows)
                s.pop("estimated", None)
                s["checked_at"] = checked
            else:
                s["access"] = "denied"
                s["access_reason"] = why
                s["fix_action"] = "open_in_browser"

    def handle_control() -> int:
        """Retry / Skip actions written by the app since the last look; returns how many were handled."""
        acts = control.poll()
        for a in acts:
            s = by_sid.get(str(a["source_id"]))
            if s is None:
                continue
            if a["action"] == "skip":
                skipped_by_user.add(s["id"])
                emit(stage="sources", source_id=s["id"], skipped=True)
            else:
                skipped_by_user.discard(s["id"])
                texts.pop(s["id"], None)
                for k in ("access", "access_reason", "fix_action", "fix_actions"):
                    s.pop(k, None)
                check_one(s, srcs.index(s))
                emit(stage="sources", source_id=s["id"], access=s.get("access"), retried=True)
        return len(acts)

    for i, s in enumerate(srcs):
        handle_control()
        if s["id"] in skipped_by_user:
            continue
        check_one(s, i)
        emit(progress=round(0.03 + 0.07 * (i + 1) / max(1, len(srcs)), 3), stage="sources", source_id=s["id"],
             access=s.get("access"))
    # someone is watching (S5): a source that failed waits a little for Retry or Skip, then the build goes on
    def failed_waiting() -> List[dict]:
        return [s for s in srcs if s["id"] not in skipped_by_user and s.get("access") in ("denied", "unsupported")
                and s.get("type") not in ("linkedin",) and not s.get("auto")]
    if wait_s > 0 and control.path and failed_waiting():
        emit(progress=0.1, stage="sources", waiting=[s["id"] for s in failed_waiting()], wait_s=int(wait_s))
        until = time.time() + wait_s
        while time.time() < until and failed_waiting():
            if not handle_control():
                time.sleep(0.5)
    handle_control()
    for sid in skipped_by_user:
        s = by_sid[sid]
        s["access"] = s.get("access") or "ok"
        s["used"] = "skipped"
        s["reason"] = "skipped by you"
    # 0.10.0 (Meeting Sheet, folders): each folder gives its recent files (folder_file, parent = the folder) within the
    # size budget; the folder itself has no text and is never "skipped" for it
    srcs = SRC.expand_folders(srcs, texts, req, route, windows)
    by_sid.update({s["id"]: s for s in srcs})
    for s in srcs:
        for k in ("text",):
            s.pop(k, None)                     # the texts live in the files, not in the sheet
        s.pop("role", None)
    usable = [s for s in srcs if s.get("access") == "ok" and (s["id"] in texts or s.get("fetch"))
              and s["id"] not in skipped_by_user]
    for s in srcs:
        if s not in usable and not (s.get("type") == "folder" and s.get("access") == "ok" and s["id"] not in skipped_by_user):
            s["used"] = "skipped"
            s["reason"] = "skipped by you" if s["id"] in skipped_by_user else (s.get("access_reason") or "no text")
    # the size and the plan the user chose
    plan_mode = req.get("plan") or "one"
    sr = Z.report(srcs, route, req.get("model") or None, windows, plan_mode)
    emit(progress=0.11, stage="size", state=sr["state"], total_tokens=sr["total_tokens"], per_pass=sr["per_pass"])
    if sr["state"] == "too_much" and plan_mode == "one":
        if req.get("on_too_much") == "passes":
            plan_mode = "passes"
            sr = Z.report(srcs, route, req.get("model") or None, windows, plan_mode)
            notes.append("The sources did not fit one pass and nobody was there to choose: built in passes and merged.")
        else:
            return {"error": "too_much", "code": 4, "size_report": sr,
                    "message": "The sources do not fit one pass of this model. Choose passes or summaries first."}
    lib = rules.get("blocks") or {}
    crit = {m: (rules.get("sales_methods") or {}).get(m, {}).get("criteria") or [] for m in (rules.get("sales_methods") or {})}
    blocks_text = PR.block_lines(ask_blocks, lib, crit, req.get("focus"), lang) + find_note
    system = PR.system(lang, call_langs)
    asker = Asker(route, req, responder)

    def switched(rec: dict) -> None:
        # 0.10.0 (AI chain): never silent: a progress line for the build views and a note in the report
        emit(progress=0.13, stage="switch", **{"from": rec["from"], "to": rec["to"], "reason": rec["reason"]})
        notes.append(f"Switched from {rec['from']} to {rec['to']}: {rec['reason']} ({rec['error']}).")
    asker.on_switch = switched
    meta: dict = {}
    parts: List[Dict[str, List[dict]]] = []
    src_ids = {s["id"] for s in srcs}
    failures = []
    use_claude = route in CLAUDE and responder is None
    if use_claude:
        emit(progress=0.13, stage="model", route=route)
        files = claude_files(usable, texts, os.path.join(os.path.dirname(base), ".sheet-cache", os.path.basename(base)))
        hosts = sorted({urlparse(s["uri"]).hostname for s in usable if s.get("fetch") and s.get("uri")} - {None})
        prompt = PR.agent_prompt(req, blocks_text, usable, files, texts, lang, call_langs)
        try:
            text, meta = run_claude(req, prompt, files, hosts, emit, usable)
        except Exception as e:  # noqa: BLE001
            # 0.10.0 (AI chain): Claude is out (a limit, signed out, no credit): the build goes on, packed, on the next AI
            from ..routing import out_reason
            why = out_reason(route, str(e))
            if not (why and asker.switch(str(e), why)):
                return {"error": str(e)[:300], "code": 5, "route": route, "out": why}
            use_claude = False
            text, meta = "", {}
    if use_claude:
        ans = PR.as_json(text)
        if not ans:
            return {"error": "Claude returned no sheet JSON", "code": 5, "route": route}
        parts.append(facts_from(ans, ask_blocks, src_ids, checked))
        opened = set(meta.get("read") or [])
        for s in usable:
            f = files.get(s["id"])
            if f:
                s["used"] = "full" if f in opened else "not_used"
                if f not in opened:
                    s["reason"] = "Claude did not open it"
            elif s.get("fetch"):
                s["used"] = "full" if s.get("uri") in (meta.get("fetched") or []) else "not_used"
            else:
                s["used"] = "full"
        if ans.get("goal") and not sheet.get("goal"):
            sheet["goal"] = ans["goal"]
        asker.model = meta.get("model") or asker.model
        asker.tokens = meta.get("tokens") or asker.tokens
        asker.usd = meta.get("cost_usd") or 0.0
    else:
        if asker.route != route:
            # 0.10.0 (AI chain): switched before any pass: the size and the plan of the AI that builds now. Web pages
            # that only Claude would have fetched have no text here and are named as skipped.
            for s in usable:
                if s["id"] not in texts and s.get("fetch"):
                    s["used"] = "skipped"
                    s["reason"] = "the page was for Claude to read; the build switched to " + asker.route
            usable = [s for s in usable if s["id"] in texts]
            sr = Z.report(srcs, asker.route, None, windows, plan_mode)
            if sr["state"] == "too_much" and plan_mode == "one":
                plan_mode = "passes"
                sr = Z.report(srcs, asker.route, None, windows, plan_mode)
                notes.append("The sources did not fit one pass of " + asker.route + " after the switch: built in passes and merged.")
        # summaries first (compress): the biggest sources are summarized one by one, each named in the report
        if plan_mode == "compress":
            ids = (sr.get("plan") or {}).get("summarize") or []
            for k, sid in enumerate(ids):
                s = next(x for x in srcs if x["id"] == sid)
                emit(progress=round(0.13 + 0.3 * k / max(1, len(ids)), 3), stage="summarize", source_id=sid)
                try:
                    words = 900
                    summary = asker.ask(PR.SUMMARY_SYS.format(WORDS=words), PR.source_block(s, texts[sid]), 4000)
                    texts[sid] = summary.strip()
                    s["used"] = "summarized"
                except Exception as e:  # noqa: BLE001
                    s["used"] = "skipped"
                    s["reason"] = f"the summary failed: {str(e)[:120]}"
                    failures.append({"source_id": sid, "error": str(e)[:200]})
            passes = [[s for s in usable if s.get("used") != "skipped"]]
        elif plan_mode == "passes":
            plan = (sr.get("plan") or {}).get("passes") or []
            byid = {s["id"]: s for s in usable}
            passes = [[byid[i] for i in p["source_ids"] if i in byid] for p in plan] or [usable]
        else:
            passes = [usable]
        lo, hi = (0.45, 0.9) if plan_mode == "compress" else (0.13, 0.9)
        for n, group in enumerate(passes, 1):
            if handle_control() and skipped_by_user:
                group = [s for s in group if s["id"] not in skipped_by_user]
                for sid in skipped_by_user:
                    by_sid[sid]["used"] = "skipped"
                    by_sid[sid]["reason"] = "skipped by you"
                if not group:
                    continue
            emit(progress=round(lo + (hi - lo) * (n - 1) / len(passes), 3), stage="model", **{"pass": n, "passes": len(passes)})
            note = (f"## This is pass {n} of {len(passes)}: only part of the sources are here; fill what they say, "
                    f"not_found for the rest") if len(passes) > 1 else ""
            # a source bigger than one pass is read in parts (never cut silently)
            per = sr.get("per_pass") or 10**9
            chunks = [group]
            if len(group) == 1 and int(group[0].get("size_tokens") or 0) > per:
                s = group[0]
                t = texts.get(s["id"], "")
                k = max(2, -(-int(s["size_tokens"]) // per))
                step = -(-len(t) // k)
                chunks = []
                for j in range(k):
                    piece = dict(s)
                    texts[f"{s['id']}#{j}"] = t[j * step:(j + 1) * step]
                    piece["id"] = s["id"]
                    chunks.append([(piece, f"{s['id']}#{j}")])
                s["used"] = "full"
                s["reason"] = f"read in {k} parts"
            for chunk in chunks:
                if chunk and isinstance(chunk[0], tuple):
                    user = PR.user_packed(req, blocks_text, [c[0] for c in chunk], {c[0]["id"]: texts[c[1]] for c in chunk}, note)
                else:
                    user = PR.user_packed(req, blocks_text, chunk, texts, note)
                try:
                    ans = PR.as_json(asker.ask(system, user, OUT_TOKENS))
                    if not ans:
                        raise RuntimeError("the model returned no sheet JSON")
                    parts.append(facts_from(ans, ask_blocks, src_ids, checked, n if len(passes) > 1 else 0))
                    if ans.get("goal") and not sheet.get("goal"):
                        sheet["goal"] = ans["goal"]
                    for s in (chunk if not (chunk and isinstance(chunk[0], tuple)) else [c[0] for c in chunk]):
                        if s.get("used") not in ("summarized",) and not s.get("reason", "").startswith("read in"):
                            s["used"] = "full"
                        if len(passes) > 1:
                            s["pass"] = n
                except Exception as e:  # noqa: BLE001  one pass failing does not stop the others
                    failures.append({"pass": n, "error": str(e)[:200]})
                    for s in (chunk if not (chunk and isinstance(chunk[0], tuple)) else [c[0] for c in chunk]):
                        s["used"] = "skipped"
                        s["reason"] = "the pass failed: " + str(e)[:120]
            emit(progress=round(lo + (hi - lo) * n / len(passes), 3), stage="model", **{"pass": n, "passes": len(passes), "done": False})
        if not parts:
            return {"error": failures[0]["error"] if failures else "nothing was built", "code": 5, "route": route,
                    "failures": failures}
    emit(progress=0.92, stage="merge")
    facts = merge_passes(parts)
    # 0.10.0 (Meeting Sheet, fix 2026-11-12, owner): a stand-up is the PM's own update; no meta lines about the sources
    if SU.has_blocks(ask_blocks):
        wanted = {b["type"] for b in ask_blocks}
        n_meta = SU.guard(facts, lang, checked, wanted)
        n_tr = SU.fill_from_tracker(facts, tracker, "s-tracker" if any(s["id"] == "s-tracker" for s in srcs) else None,
                                    lang, checked, wanted)
        if n_meta:
            notes.append(f"Stand-up: {n_meta} line(s) about the sources instead of the work were dropped.")
        if n_tr:
            notes.append(f"Stand-up: {n_tr} line(s) taken from the Tracker.")
    srcmap = {s["id"]: s for s in srcs}
    try:
        year = int(str((req.get("meeting") or {}).get("start") or req.get("today") or "")[:4])
    except ValueError:
        year = None
    conflicts = mark_conflicts(facts, srcmap, stale_months, year)
    assign_ids(facts)
    for f in sum(facts.values(), []):
        if f.get("superseded_by") is None:
            f.pop("superseded_by", None)
    old_blocks = {}
    for ob in (old or {}).get("blocks") or []:
        old_blocks.setdefault(ob.get("id"), ob)
        old_blocks.setdefault(ob.get("type"), ob)
    for b in sheet["blocks"]:
        t = b["type"]
        if t == "header":
            b["facts"] = header_facts(req, "s-meeting", checked)
        elif t == "gaps":
            b["facts"] = []
        elif b in ask_blocks:
            b["facts"] = facts.get(t, [])
        else:
            # 0.10.0 (round 2): a block not rebuilt (options.blocks) or hidden keeps what it had
            ob = old_blocks.get(b.get("id")) or old_blocks.get(t)
            b["facts"] = copy.deepcopy((ob or {}).get("facts") or [])
        if b.get("only_if_data") and b in ask_blocks and t not in ("header", "gaps"):
            if not any(f.get("status") != "not_found" for f in b["facts"]):
                b["facts"] = []           # "Only if there is data": an empty block stays empty and is not shown
    allf = {b["type"]: b["facts"] for b in sheet["blocks"] if b["type"] not in ("header", "gaps")}
    gb = next((b for b in sheet["blocks"] if b["type"] == "gaps"), None)
    if gb is not None:
        gb["facts"] = gap_facts(allf, sheet["blocks"], checked)
    if old:
        # a fact kept from the previous sheet may cite a source this request no longer lists: keep that source
        have = {s["id"] for s in srcs}
        cited = {i for b in sheet["blocks"] for f in b.get("facts") or [] for i in f.get("source_ids") or []}
        for os_ in old.get("sources") or []:
            if os_.get("id") in cited - have:
                srcs.append(dict(os_, used=os_.get("used") or "full"))
                have.add(os_["id"])
    for s in srcs:                       # 0.10.0 (Meeting Sheet, hardening): a cut page is never reported as whole
        cut = s.get("cut")
        if isinstance(cut, dict) and s.get("used") in ("full", "truncated", None):
            s["used"] = "truncated"
            s["reason"] = "the page is longer than %d KB: only the first %d KB were read" % (
                int(cut.get("limit_bytes") or 0) // 1000, int(cut.get("read_bytes") or 0) // 1000)
    sheet["sources"] = srcs
    if tracker and SU.has_blocks(sheet["blocks"]):
        from . import tracker as TR
        sheet["tracker"] = TR.for_sheet(tracker)    # the live window's fallback for the My update card
    sr = Z.report(srcs, asker.route, (req.get("model") or None) if asker.route == route else None, windows, plan_mode)
    sheet["size_report"] = {k: sr[k] for k in ("route", "model", "window", "reserve", "total_tokens", "state", "plan")}
    sheet["route"] = asker.route
    if asker.switches:
        sheet["route_switches"] = asker.switches        # 0.10.0 (AI chain): the report names every switch
    sheet["built_at"] = old.get("built_at") if old else checked
    if old:
        sheet["refreshed_at"] = checked
        protected = M.protect_edits(old, sheet)
        d = diff(old, protected)
        sheet = protected
        sheet["gone_facts"] = d.pop("gone_facts")      # the schema's diff.gone holds ids; the texts for the UI here
        sheet["diff"] = d
        sheet["readiness"] = dict(old.get("readiness") or {})
        sheet["readiness"]["dropped"] = (old.get("readiness") or {}).get("dropped") or []
    n = next_version(base)
    sheet.setdefault("versions", []).append({"n": n, "built_at": checked, "route": asker.route, "model": asker.model or "",
                                             "note": "refresh" if old else ("first build" if n == 1 else "rebuild")})
    R.apply(sheet, rules, req.get("today"), req.get("settings") or {}, req.get("app_root"))
    for b in sheet["blocks"]:
        for f in b.get("facts") or []:
            f.pop("pass", None) if not f.get("pass") else None
    errs = S.validate(sheet, P.method_names(rules))
    if errs:
        return {"error": "the built sheet is invalid", "errors": errs[:20], "code": 1}
    emit(progress=0.96, stage="write")
    rep = report(sheet, failures, notes, asker, meta, time.time() - t0)
    _write_json(base + f".sheet.v{n}.json", sheet)
    _write_json(base + ".sheet.json", sheet)
    _write_json(base + ".sheet.sources.json", rep)
    _write_json(base + ".sheet.request.json", {k: v for k, v in req.items() if k not in ("fake_answers", "_previous_labels")})
    from . import derive as D
    Path(base + ".sheet.md").write_text(D.render_md(sheet), encoding="utf-8")
    written = D.derive(sheet, base)
    res = {"done": True, "sheet": base + ".sheet.json", "version": n, "readiness": sheet["readiness"]["state"],
           "facts": sum(len(b.get("facts") or []) for b in sheet["blocks"]), "conflicts": conflicts,
           "route": asker.route, "model": asker.model or "", "tokens": asker.tokens, "cost_usd": round(asker.usd or 0, 4),
           "duration_s": int(time.time() - t0), "failures": failures, "derived": written, "notes": notes,
           "switches": asker.switches}
    if old:
        res["diff"] = {k: len(v) for k, v in (sheet.get("diff") or {}).items()}
    return res


def report(sheet: dict, failures: List[dict], notes: List[str], asker: Asker, meta: dict, seconds: float) -> dict:
    """<base>.sheet.sources.json: what each source gave (used, why not, facts citing it), the passes, failures."""
    cites: Dict[str, int] = {}
    for b in sheet.get("blocks") or []:
        for f in b.get("facts") or []:
            for i in f.get("source_ids") or []:
                cites[i] = cites.get(i, 0) + 1
    rows = []
    for s in sheet.get("sources") or []:
        rows.append({k: s.get(k) for k in ("id", "n", "type", "title", "path", "uri", "access", "access_reason",
                                           "fix_action", "used", "reason", "pass", "size_tokens", "chars",
                                           "parent", "folder") if s.get(k) is not None}
                    | {"facts": cites.get(s["id"], 0)})
    st = {}
    for s in sheet.get("sources") or []:
        st[s.get("used", "")] = st.get(s.get("used", ""), 0) + 1
    # 0.10.0 (Meeting Sheet, folders): each folder with its counts (files taken for the preparation, searchable later)
    folders = [{"id": s["id"], "title": s.get("title"), "path": s.get("path"), **(s.get("folder") or {}),
                "line": s.get("reason") or "", "files": [c["id"] for c in sheet.get("sources") or [] if c.get("parent") == s["id"]]}
               for s in sheet.get("sources") or [] if s.get("type") == "folder"]
    return {"schema": "pacenote.sheet.sources/1", "sheet": sheet.get("id"), "built": now_iso(), "folders": folders,
            "route": sheet.get("route"), "model": asker.model, "size_report": sheet.get("size_report"),
            "counts": st, "sources": rows, "failures": failures, "notes": notes,
            "claude": {"read": meta.get("read"), "fetched": meta.get("fetched"), "turns": meta.get("turns")} if meta else None,
            "tokens": asker.tokens, "cost_usd": round(asker.usd or 0, 4), "duration_s": int(seconds)}
