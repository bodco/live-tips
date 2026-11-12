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
        self.req = req
        self.responder = responder
        self.tokens = {"input": 0, "output": 0}
        self.usd = 0.0
        self.model = req.get("model") or ""
        self.provider = None
        self.calls = 0

    def _provider(self):
        if self.provider is not None:
            return self.provider
        r, req = self.route, self.req
        t = float(req.get("timeout") or 900)
        if r == "codex":
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
            self.model = job_model("prep", req.get("model"))
            self.provider = OpenAIProvider(key, timeout=t, model=self.model)
        elif r == "gemini":
            from ..gemini_provider import GeminiProvider, job_model
            key = os.environ.get("GEMINI_API_KEY", "")
            if not key:
                raise RuntimeError("No Gemini API key: add it in Settings > AI > Gemini")
            self.model = job_model("prep", req.get("model"))
            self.provider = GeminiProvider(key, timeout=t, model=self.model)
        elif r == "agy":
            from ..agy_provider import AgyProvider, find_agy_cli, job_model
            cli = find_agy_cli()
            if not cli:
                raise RuntimeError("Antigravity CLI is not installed: see Settings > AI > Gemini")
            self.model = job_model("prep", req.get("model"))
            self.provider = AgyProvider(cli, timeout=t, model=self.model)
        elif r == "local":
            from ..providers import OllamaProvider
            self.model = req.get("model") or "gemma4:26b"
            self.provider = OllamaProvider(req.get("url") or "http://127.0.0.1:11434", num_ctx=65536, timeout=max(t, 1800))
        else:
            raise RuntimeError(f"no packed provider for route {r}")
        return self.provider

    def ask(self, system: str, user: str, max_tokens: int = OUT_TOKENS) -> str:
        self.calls += 1
        if self.responder is not None:
            return self.responder(system, user)
        prov = self._provider()
        res = prov.complete(model=self.model, system=[{"text": system}], user=user, max_tokens=max_tokens, cache_ttl=None)
        self.tokens["input"] += int(res.input_tokens or 0) + int(res.cache_read or 0)
        self.tokens["output"] += int(res.output_tokens or 0)
        try:
            from ..cost import cost_usd
            self.usd += cost_usd(res.model or self.model, res.input_tokens, res.cache_write_5m, res.cache_write_1h,
                                 res.cache_read, res.output_tokens) or 0.0
        except Exception:  # noqa: BLE001
            pass
        if res.error:
            raise RuntimeError(str(res.error)[:300])
        if not (res.text or "").strip():
            raise RuntimeError("the model returned an empty answer")
        return res.text


def find_claude(hint: Optional[str] = None) -> Optional[str]:
    home = os.path.expanduser("~")
    for p in (hint, os.environ.get("LT_CLAUDE_CLI"), shutil.which("claude"), home + "/.local/bin/claude",
              home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


# ---------------------------------------------------------------- web pages (packed routes)

def fetch_page(url: str, timeout: float = 20.0) -> Tuple[str, Optional[str]]:
    """One page, the user's own link, read once. robots.txt is honoured (urllib.robotparser) until the browser
    module (phase 6) takes this over through sources.web_allowed."""
    allowed = SRC.web_allowed(url)
    if allowed is None:
        try:
            import urllib.robotparser as RP
            u = urlparse(url)
            rp = RP.RobotFileParser(f"{u.scheme}://{u.netloc}/robots.txt")
            rp.read()
            allowed = rp.can_fetch("Pacenote", url)
        except Exception:  # noqa: BLE001  no robots.txt reachable: the page itself decides
            allowed = True
    if not allowed:
        return "", "the site's robots.txt does not allow automatic reading"
    try:
        rq = urllib.request.Request(url, headers={"User-Agent": "Pacenote (meeting sheet; one page the user linked)"})
        with urllib.request.urlopen(rq, timeout=timeout) as r:
            ctype = r.headers.get("Content-Type", "")
            raw = r.read(3_000_000)
        if "html" not in ctype and "text" not in ctype:
            return "", f"not a web page ({ctype.split(';')[0] or 'unknown type'})"
        text = readers.html_text(raw.decode("utf-8", "replace"))
        return text, None if text.strip() else "the page has no text"
    except Exception as e:  # noqa: BLE001
        return "", f"cannot open the page: {type(e).__name__}"


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


def mark_conflicts(facts: Dict[str, List[dict]], sources: Dict[str, dict], stale_months: int = 6) -> int:
    """Same attribute (block + label, or criterion key), different values from different sources: both facts stay.
    When both sources are dated and the older one is stale_months older, the newer wins (found) and the older is
    stale; otherwise both are "conflict" and point to each other. Returns the number of conflict groups."""
    groups = 0
    for t, lst in facts.items():
        if t not in CONFLICT_BLOCKS:
            continue                 # list blocks (agenda, questions, outcomes, history...) hold many items per label
        by: Dict[str, List[dict]] = {}
        for f in lst:
            if f["status"] == "not_found" or not f.get("label") and not (f.get("value") or {}).get("key"):
                continue
            by.setdefault(fact_key(t, f), []).append(f)
        for k, fs in by.items():
            vals = {norm(f["text"]) for f in fs}
            srcs = {tuple(sorted(f["source_ids"])) for f in fs}
            if len(fs) < 2 or len(vals) < 2 or len(srcs) < 2:
                continue
            def newest(f):
                ds = [_date(sources.get(i, {}).get("modified_at")) for i in f["source_ids"]]
                ds = [d for d in ds if d]
                return max(ds) if ds else None
            dated = [(newest(f), f) for f in fs]
            if all(d for d, _ in dated):
                dated.sort(key=lambda x: x[0], reverse=True)
                top = dated[0][0]
                old = [f for d, f in dated[1:] if R.months_before(top, stale_months) >= d]
                if old and len(old) == len(dated) - 1:
                    dated[0][1]["status"] = "found"
                    for f in old:
                        f["status"] = "stale"
                        f["superseded_by"] = dated[0][1].get("id")
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
    p = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.time() + float(req.get("timeout") or 1500)
    n_src = max(1, len(files))
    for line in p.stdout:
        if time.time() > deadline:
            p.kill()
            raise RuntimeError("Claude Code took too long")
        try:
            ev = json.loads(line)
        except ValueError:
            continue
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
            t = t if isinstance(t, str) else t.get("type")
            if t not in lib:
                continue
            b = keep.get(t) or {"id": f"b-{t}", "type": t, "title": lib[t].get("title", t), "visible": True,
                                "only_if_data": bool(lib[t].get("only_if_data")), "facts": [], "edited_by_user": False}
            b["order"] = i
            bl.append(b)
        sheet["blocks"] = bl
    for b in sheet["blocks"]:
        if b["type"] == "qualification" and req.get("method"):
            b["method"] = req["method"]
    if old:
        for k in ("blocks",):
            pass
        sheet["versions"] = list(old.get("versions") or [])
    # the sources: the invitation header first, then what the user ticked
    raw = [{"id": "s-meeting", "type": "text", "title": "Meeting invitation", "text": PR.header_text(req), "role": "invite"}]
    raw += list(req.get("sources") or [])
    ctx = (req.get("context") or "").strip()
    if ctx and not any(s.get("role") == "context" for s in raw):
        raw.append({"id": "s-context", "type": "text", "title": "Call context", "text": ctx, "role": "context"})
    for s in raw:
        if s.get("type") == "digest" and not s.get("text") and not s.get("path"):
            s["text"] = digest_text(req)
    # 0.10.0 (bridge until the wizard): Prepare without the wizard picks what the series says and the best matches
    if req.get("auto_pick"):
        have = {os.path.expanduser(s.get("path") or "") for s in raw if s.get("path")}
        try:
            cands = SRC.candidates(req, int(req.get("auto_pick") or 12) + 20)["candidates"]
        except Exception:  # noqa: BLE001
            cands = []
        n_folder = 0
        for c in cands:
            if c.get("path") and os.path.expanduser(c["path"]) in have:
                continue
            if c["type"] == "folder_file":
                if not c.get("suggested") and (c.get("why") == ["rest of the folder"] or n_folder >= int(req["auto_pick"])):
                    continue
                n_folder += 1
            if c["type"] == "digest":
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
    for i, s in enumerate(srcs):
        SRC.check(s, req, texts, route, windows)
        if s.get("fetch") and route in PACKED and route != "fake":
            emit(progress=0.03 + 0.07 * i / max(1, len(srcs)), stage="reading", source_id=s["id"])
            text, why = fetch_page(s["uri"])
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
        emit(progress=round(0.03 + 0.07 * (i + 1) / max(1, len(srcs)), 3), stage="sources", source_id=s["id"],
             access=s.get("access"))
    for s in srcs:
        for k in ("text",):
            s.pop(k, None)                     # the texts live in the files, not in the sheet
        s.pop("role", None)
    usable = [s for s in srcs if s.get("access") == "ok" and (s["id"] in texts or s.get("fetch"))]
    for s in srcs:
        if s not in usable:
            s["used"] = "skipped"
            s["reason"] = s.get("access_reason") or "no text"
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
    blocks_text = PR.block_lines(sheet["blocks"], lib, crit, req.get("focus"), lang)
    system = PR.system(lang, call_langs)
    asker = Asker(route, req, responder)
    meta: dict = {}
    parts: List[Dict[str, List[dict]]] = []
    src_ids = {s["id"] for s in srcs}
    failures = []
    if route in CLAUDE and responder is None:
        emit(progress=0.13, stage="model", route=route)
        files = claude_files(usable, texts, os.path.join(os.path.dirname(base), ".sheet-cache", os.path.basename(base)))
        hosts = sorted({urlparse(s["uri"]).hostname for s in usable if s.get("fetch") and s.get("uri")} - {None})
        prompt = PR.agent_prompt(req, blocks_text, usable, files, texts, lang, call_langs)
        try:
            text, meta = run_claude(req, prompt, files, hosts, emit, usable)
        except Exception as e:  # noqa: BLE001
            return {"error": str(e)[:300], "code": 5, "route": route}
        ans = PR.as_json(text)
        if not ans:
            return {"error": "Claude returned no sheet JSON", "code": 5, "route": route}
        parts.append(facts_from(ans, sheet["blocks"], src_ids, checked))
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
                    parts.append(facts_from(ans, sheet["blocks"], src_ids, checked, n if len(passes) > 1 else 0))
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
    srcmap = {s["id"]: s for s in srcs}
    conflicts = mark_conflicts(facts, srcmap, stale_months)
    assign_ids(facts)
    for f in sum(facts.values(), []):
        if f.get("superseded_by") is None:
            f.pop("superseded_by", None)
    for b in sheet["blocks"]:
        t = b["type"]
        if t == "header":
            b["facts"] = header_facts(req, "s-meeting", checked)
        elif t == "gaps":
            b["facts"] = []
        else:
            b["facts"] = facts.get(t, [])
    gb = next((b for b in sheet["blocks"] if b["type"] == "gaps"), None)
    if gb is not None:
        gb["facts"] = gap_facts(facts, sheet["blocks"], checked)
    sheet["sources"] = srcs
    sr = Z.report(srcs, route, req.get("model") or None, windows, plan_mode)
    sheet["size_report"] = {k: sr[k] for k in ("route", "model", "window", "reserve", "total_tokens", "state", "plan")}
    sheet["route"] = route
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
    sheet.setdefault("versions", []).append({"n": n, "built_at": checked, "route": route, "model": asker.model or "",
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
           "route": route, "model": asker.model or "", "tokens": asker.tokens, "cost_usd": round(asker.usd or 0, 4),
           "duration_s": int(time.time() - t0), "failures": failures, "derived": written, "notes": notes}
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
                                           "fix_action", "used", "reason", "pass", "size_tokens", "chars") if s.get(k) is not None}
                    | {"facts": cites.get(s["id"], 0)})
    st = {}
    for s in sheet.get("sources") or []:
        st[s.get("used", "")] = st.get(s.get("used", ""), 0) + 1
    return {"schema": "pacenote.sheet.sources/1", "sheet": sheet.get("id"), "built": now_iso(),
            "route": sheet.get("route"), "model": asker.model, "size_report": sheet.get("size_report"),
            "counts": st, "sources": rows, "failures": failures, "notes": notes,
            "claude": {"read": meta.get("read"), "fetched": meta.get("fetched"), "turns": meta.get("turns")} if meta else None,
            "tokens": asker.tokens, "cost_usd": round(asker.usd or 0, 4), "duration_s": int(seconds)}
