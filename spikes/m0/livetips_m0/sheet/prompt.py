"""0.10.0 (Meeting Sheet, phase 3): one prompt contract for every route.

The model gets the blocks of the preset (title and fields from rules/meeting-sheet.yaml), the meeting header and the
sources, each with its id. It answers one JSON object: facts per block, each with source_ids and a locator. Whatever
the sources do not say is "not_found", never invented. The packed routes get the sources inline; the Claude routes
get the same contract and read the files themselves (agent_prompt).
"""
import json
from typing import Dict, List, Optional

LANGS = {"uk": "Ukrainian", "en": "English", "es": "Spanish", "de": "German", "pl": "Polish", "ru": "Russian"}
SKIP_BLOCKS = ("header", "gaps")       # header: from the invitation (built by Pacenote); gaps: from conflicts and readiness

CONTRACT = """You build a Meeting Sheet: short, checkable facts for a person going into a meeting. Use ONLY the
sources given. Every fact names the sources it comes from by their ids (source_ids, e.g. ["s3"]) and a locator: a
short exact quote (at most 20 words, in the source's own language) and, when the source has them, the page
([page N] marks), the slide ([slide N] marks), the line, the URL of a subpage, or the cell of a sheet. When the
sources do not say something a block asks for, write ONE fact with "status": "not_found" and a text saying what is
missing; never guess, never fill from general knowledge. A fact the sources only hint at gets "status":
"needs_check". When two sources disagree on the same thing (a size, a date, a name, a price), write BOTH facts with
the SAME label, each with its own source; Pacenote marks the conflict. In list blocks (agenda, questions, best
outcome, action items, red lines, history) every item gets its own short label. Facts are short (one or two sentences) and
concrete: numbers, dates, names, who said what. Source ids belong in source_ids only, never in the text. Write the fact texts in {LANG}; quotes stay as written. No long dashes.

Answer with one JSON object and nothing else:
{{"blocks": {{"<block type>": [{{"label": "<short attribute, e.g. Team size>", "text": "<the fact>",
   "source_ids": ["s1"], "locator": {{"quote": "...", "page": 2, "slide": 3, "line": 14, "url": "...", "cell": "B4"}},
   "status": "found" | "needs_check" | "not_found",
   "keywords": ["2-4 lowercase phrases someone may say in the meeting about this, in {CALL_LANGS}"],
   "value": {{"key": "<criterion key, qualification only>", "level": "green|yellow|red|unknown",
             "owner": "<agenda and action items>", "due": "<YYYY-MM-DD when known>"}}}}]}},
 "goal": "<the meeting's goal when the sources state it, else empty>"}}
Leave out locator keys you do not have and "value" when it does not apply. Only the block types listed below."""


def block_lines(blocks: List[dict], lib: dict, criteria: Optional[Dict[str, List[dict]]] = None,
                focus: Optional[List[str]] = None, lang: str = "en") -> str:
    out = []
    for b in blocks:
        t = b["type"]
        if t in SKIP_BLOCKS or (t == "my_focus" and not focus):
            continue                   # my_focus without the user's fields (Settings > Meeting Sheet) stays empty
        fields = (lib.get(t) or {}).get("fields", "")
        line = f'- {t} ("{b.get("title", t)}"): {fields}'
        if t == "qualification":
            crit = (criteria or {}).get(b.get("method") or "bant") or []
            names = ", ".join(f'{c["key"]} ({(c.get("name") or {}).get("en", c["key"])})' for c in crit)
            line += (f'. Method {b.get("method") or "bant"}: exactly one fact per criterion, its latest state ({names}), with value.key = the '
                     f'criterion key and value.level; a criterion the sources say nothing about: status not_found, '
                     f'level unknown')
        if t == "my_focus" and focus:
            line += ". The user wants these first: " + "; ".join(focus)
        if t == "questions":
            line += ". Questions that close the gaps of the other blocks, phrased to ask"
        if t == "agenda":
            line += ". Each item with value.owner when known"
        out.append(line)
    return "\n".join(out)


def header_text(req: dict) -> str:
    m = req.get("meeting") or {}
    p = req.get("participants") or {}
    ours = ", ".join(x.get("name", "") + (f' ({x["role"]})' if x.get("role") else "") for x in p.get("ours") or [])
    theirs = ", ".join(x.get("name", "") + (f' ({x["role"]}' if x.get("role") else " (") + (f', {x["company"]}' if x.get("company") else "") + ")"
                       for x in p.get("theirs") or []).replace(" ()", "")
    lines = [f"Meeting: {m.get('title', '')}", f"When: {m.get('start', '')}" + (f" to {m['end']}" if m.get("end") else "")
             + (f" ({m['tz']})" if m.get("tz") else "")]
    if m.get("where"):
        lines.append(f"Where: {m['where']}")
    if ours:
        lines.append(f"Our side: {ours}")
    if theirs:
        lines.append(f"Their side: {theirs}")
    if req.get("goal"):
        lines.append(f"Goal: {req['goal']}")
    if req.get("call_type"):
        lines.append(f"Meeting type: {req['call_type']}")
    return "\n".join(lines)


def system(lang: str, call_langs: List[str]) -> str:
    return CONTRACT.format(LANG=LANGS.get(lang, lang), CALL_LANGS=", ".join(LANGS.get(c, c) for c in call_langs or [lang]))


def source_block(s: dict, text: str) -> str:
    head = f"=== SOURCE {s['id']} | {s.get('type')} | {s.get('title', '')}"
    if s.get("modified_at"):
        head += f" | dated {s['modified_at']}"
    if s.get("uri"):
        head += f" | {s['uri']}"
    if s.get("used") == "summarized":
        head += " | SUMMARY made by Pacenote of a bigger source"
    return head + " ===\n" + text.strip() + "\n"


def previous_labels(old: Optional[dict]) -> str:
    """Refresh: the labels of the sheet being refreshed, so the same fact keeps its label and the diff shows only
    what really changed."""
    if not old:
        return ""
    lines = []
    for b in old.get("blocks") or []:
        labs = [f.get("label") for f in b.get("facts") or [] if f.get("label") and f.get("origin") == "model"]
        if labs and b.get("type") not in SKIP_BLOCKS:
            lines.append(f"- {b['type']}: " + "; ".join(dict.fromkeys(labs)))
    if not lines:
        return ""
    return ("## Labels of the previous version of this sheet\nThis is a refresh. For a fact that is still true use the "
            "same label as before; a new fact gets a new label; leave out what the sources no longer say.\n" + "\n".join(lines))


def user_packed(req: dict, blocks_text: str, sources: List[dict], texts: Dict[str, str], pass_note: str = "") -> str:
    parts = ["## The meeting\n" + header_text(req), "## Blocks to fill (type: what it holds)\n" + blocks_text]
    if req.get("_previous_labels"):
        parts.append(req["_previous_labels"])
    if req.get("instructions"):
        parts.append("## The user's note for this meeting\n" + req["instructions"])
    if pass_note:
        parts.append(pass_note)
    parts.append("## Sources\n" + "\n".join(source_block(s, texts.get(s["id"], "")) for s in sources if texts.get(s["id"])))
    return "\n\n".join(parts)


SUMMARY_SYS = """Summarize this source for a Meeting Sheet so that no checkable fact is lost: keep every number,
date, name, decision, promise, price, problem and open question, with the [page N] / [slide N] marks they stand
under. Drop repetition and boilerplate. Write in the source's own language. At most {WORDS} words. Plain text."""


def agent_prompt(req: dict, blocks_text: str, sources: List[dict], files: Dict[str, str], texts: Dict[str, str],
                 lang: str, call_langs: List[str]) -> str:
    """The Claude routes: the same contract; Claude opens the files itself. files: id -> path to Read."""
    lines = []
    for s in sources:
        if s["id"] in files:
            lines.append(f"- {s['id']} ({s.get('type')}, {s.get('title', '')}" + (f", dated {s['modified_at']}" if s.get("modified_at") else "")
                         + f"): Read {files[s['id']]}")
        elif s.get("fetch") and s.get("uri"):
            lines.append(f"- {s['id']} (web page, {s.get('title', '')}): WebFetch {s['uri']} (this page only)")
    inline = [source_block(s, texts[s["id"]]) for s in sources if s["id"] not in files and texts.get(s["id"])]
    return (system(lang, call_langs) + "\n\n## The meeting\n" + header_text(req) + "\n\n## Blocks to fill\n" + blocks_text
            + ("\n\n## The user's note for this meeting\n" + req["instructions"] if req.get("instructions") else "")
            + ("\n\n" + req["_previous_labels"] if req.get("_previous_labels") else "")
            + "\n\n## Sources to open (read each one fully; read nothing else)\n" + ("\n".join(lines) or "(none)")
            + ("\n\n## Sources given here\n" + "\n".join(inline) if inline else "")
            + "\n\nDo not write any file. Your final message is the JSON object only.")


def as_json(text: str, want: str = "blocks") -> Optional[dict]:
    """The JSON object of a model answer (code fences and chatter around it allowed); the first object that has
    the key `want`, else the first object; None when there is none."""
    import re
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", (text or "").strip())
    dec = json.JSONDecoder()
    first = None
    i, tries = s.find("{"), 0
    while i >= 0 and tries < 40:
        tries += 1
        try:
            v, _ = dec.raw_decode(s[i:])
            if isinstance(v, dict):
                if want in v:
                    return v
                first = first or v
        except ValueError:
            pass
        i = s.find("{", i + 1)
    return first
