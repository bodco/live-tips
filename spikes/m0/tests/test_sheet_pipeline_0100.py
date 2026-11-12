"""0.10.0 (Meeting Sheet, phases 2-3, pipeline): links, access, readers, candidates, tokens, build on a fake model,
conflicts, passes, refresh with diff and edit protection, the report, and the live files read by the recorder.
Every fixture is invented and built here (Emily Parker, Mike Carter, Lumenfield, Northwind Studio, Orbit)."""
import json
import os
import sys
import zipfile
import zlib
from pathlib import Path

import pytest

from livetips_m0.sheet import build as B
from livetips_m0.sheet import derive as D
from livetips_m0.sheet import prompt as PR
from livetips_m0.sheet import readers as RD
from livetips_m0.sheet import schema as S
from livetips_m0.sheet import size as Z
from livetips_m0.sheet import sources as SRC
from livetips_m0.sheet import __main__ as CLI

REC = Path(__file__).resolve().parents[3] / "recorder" / "src"


# ---------------------------------------------------------------- fixtures built in the test

def make_pptx(path: Path, slides, hidden=(), order=None):
    """slides: [(title, body, notes)]; order: the show order as indexes (presentation.xml), hidden: indexes."""
    order = order or list(range(len(slides)))
    ns_p = 'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
    with zipfile.ZipFile(path, "w") as z:
        ids = "".join(f'<p:sldId id="{256 + k}" r:id="rId{i + 1}"/>' for k, i in enumerate(order))
        z.writestr("ppt/presentation.xml", f'<p:presentation {ns_p}><p:sldIdLst>{ids}</p:sldIdLst></p:presentation>')
        rels = "".join(f'<Relationship Id="rId{i + 1}" Type="slide" Target="slides/slide{i + 1}.xml"/>' for i in range(len(slides)))
        z.writestr("ppt/_rels/presentation.xml.rels", f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{rels}</Relationships>')
        for i, (title, body, notes) in enumerate(slides):
            show = ' show="0"' if i in hidden else ""
            z.writestr(f"ppt/slides/slide{i + 1}.xml",
                       f'<p:sld {ns_p}{show}><p:cSld><p:spTree>'
                       f'<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>{title}</a:t></a:r></a:p></p:txBody></p:sp>'
                       f'<p:sp><p:nvSpPr><p:nvPr/></p:nvSpPr><p:txBody><a:p><a:r><a:t>{body}</a:t></a:r></a:p></p:txBody></p:sp>'
                       f'</p:spTree></p:cSld></p:sld>')
            if notes:
                z.writestr(f"ppt/slides/_rels/slide{i + 1}.xml.rels",
                           f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdN" Type="notesSlide" Target="../notesSlides/notesSlide{i + 1}.xml"/></Relationships>')
                z.writestr(f"ppt/notesSlides/notesSlide{i + 1}.xml",
                           f'<p:notes {ns_p}><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>'
                           f'<p:txBody><a:p><a:r><a:t>{notes}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>')


def make_xlsx(path: Path):
    s = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("xl/workbook.xml", f'<workbook {s}><sheets><sheet name="Pipeline" sheetId="1" r:id="rId1"/>'
                                      f'<sheet name="Secret" sheetId="2" state="hidden" r:id="rId2"/></sheets></workbook>')
        z.writestr("xl/_rels/workbook.xml.rels", '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId1" Target="worksheets/sheet1.xml" Type="ws"/><Relationship Id="rId2" Target="worksheets/sheet2.xml" Type="ws"/></Relationships>')
        z.writestr("xl/sharedStrings.xml", f'<sst {s}><si><t>Account</t></si><si><t>Seats</t></si><si><t>Northwind Studio</t></si></sst>')
        z.writestr("xl/worksheets/sheet1.xml", f'<worksheet {s}><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
                                               f'<row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>42</v></c></row></sheetData></worksheet>')
        z.writestr("xl/worksheets/sheet2.xml", f'<worksheet {s}><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>hidden</t></is></c></row></sheetData></worksheet>')


def make_docx(path: Path):
    w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("word/document.xml", f'<w:document {w}><w:body>'
                   '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Orbit sync notes</w:t></w:r></w:p>'
                   '<w:p><w:r><w:t>Jake T. owns the release </w:t></w:r><w:r><w:t>on December 4.</w:t></w:r></w:p>'
                   '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Risk</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Late API keys</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
                   '</w:body></w:document>')


def make_pdf(path: Path, pages):
    """A minimal valid PDF with one Flate content stream per page (Helvetica text)."""
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", None, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    kids = []
    for text in pages:
        content = zlib.compress(("BT /F1 12 Tf 72 720 Td (" + text + ") Tj ET").encode("latin-1"))
        objs.append(b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(content) + content + b"\nendstream")
        cid = len(objs)
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {cid} 0 R /Resources << /Font << /F1 3 0 R >> >> >>")
        kids.append(len(objs))
    objs[1] = "<< /Type /Pages /Kids [%s] /Count %d >>" % (" ".join(f"{k} 0 R" for k in kids), len(kids))
    out = bytearray(b"%PDF-1.4\n")
    offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        body = o if isinstance(o, bytes) else o.encode("latin-1")
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    x = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for o in offs:
        out += f"{o:010d} 00000 n \n".encode()
    out += f"trailer << /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n".encode()
    path.write_bytes(bytes(out))


# ---------------------------------------------------------------- links and access

def test_link_types():
    t = ("see https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit and https://docs.google.com/spreadsheets/d/1SheetIdIdIdId/x, "
         "https://docs.google.com/presentation/d/1SlidesIdIdIdId/edit, https://drive.google.com/file/d/1FileIdIdIdIdId/view, "
         "https://drive.google.com/open?id=1OpenIdIdIdIdId, https://www.notion.so/Orbit-Plan-0123456789abcdef0123456789abcdef, "
         "https://www.linkedin.com/in/emily-parker-example/ and https://lumenfield.example/about.")
    got = [(c["type"], c.get("id", "")) for c in SRC.find_links(t)]
    assert got[:5] == [("gdoc", "1AbCdEfGhIjKlMnOp"), ("gsheet", "1SheetIdIdIdId"), ("gslides", "1SlidesIdIdIdId"),
                       ("drive_file", "1FileIdIdIdIdId"), ("drive_file", "1OpenIdIdIdIdId")]
    assert got[5] == ("notion", "0123456789abcdef0123456789abcdef")
    assert got[6][0] == "linkedin" and got[7] == ("web", "")
    assert SRC.find_links(t)[-1]["url"] == "https://lumenfield.example/about"      # the full stop is not part of it
    assert SRC.google_link("https://docs.google.com/document/d/short/edit") is None   # ids are 10+ characters


def test_move_suggestions_never_move_silently():
    ctx = "Read https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit first. Site: https://lumenfield.example"
    sug = SRC.move_suggestions(ctx, [{"type": "web", "uri": "https://lumenfield.example"}])
    assert [s["type"] for s in sug] == ["gdoc"] and sug[0]["action"] == "move_to_sources"
    assert "Move it to Sources" in sug[0]["text"]


def _check(src, req=None):
    s = SRC.normalize([src])[0]
    texts = {}
    SRC.check(s, req or {}, texts, "codex", Z.load_windows())
    return s, texts


def test_access_statuses(tmp_path):
    f = tmp_path / "notes.md"
    f.write_text("# Orbit\nJake T. owns the release.", encoding="utf-8")
    s, texts = _check({"path": str(f)})
    assert s["access"] == "ok" and s["size_tokens"] > 0 and texts[s["id"]].startswith("# Orbit")
    s, _ = _check({"path": str(tmp_path / "gone.md")})
    assert s["access"] == "denied" and s["fix_action"] == "retry"
    (tmp_path / "x.bin").write_bytes(b"\0\1")
    s, _ = _check({"path": str(tmp_path / "x.bin")})
    assert s["access"] == "unsupported"
    url = "https://drive.google.com/file/d/1FileIdIdIdIdId/view"
    s, _ = _check({"uri": url}, {"google": {"connected": True}})
    assert s["type"] == "drive_file" and s["access"] == "denied" and s["fix_action"] == "confirm_google"
    s, _ = _check({"uri": url}, {"google": {"connected": False}})
    assert s["access"] == "pending" and s["fix_action"] == "connect_google"
    copy = tmp_path / "google-doc.md"
    copy.write_text("Lumenfield plan: 120 people", encoding="utf-8")
    s, t = _check({"uri": "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit"},
                  {"google": {"connected": True, "copies": {"1AbCdEfGhIjKlMnOp": str(copy)}}})
    assert s["access"] == "ok" and "120 people" in t[s["id"]]
    s, _ = _check({"uri": "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit"},
                  {"google": {"connected": True, "status": {"1AbCdEfGhIjKlMnOp": "denied"}}})
    assert s["access"] == "denied" and s["fix_action"] == "confirm_google"
    s, _ = _check({"uri": "https://www.notion.so/Plan-0123456789abcdef0123456789abcdef"}, {"notion": {"connected": False}})
    assert s["access"] == "pending" and s["fix_action"] == "connect_notion"
    s, _ = _check({"uri": "https://www.linkedin.com/in/emily-parker-example/"})
    assert s["access"] == "pending" and s["fix_actions"] == ["save_as_pdf", "open_in_browser", "paste_text", "fill_by_hand"]
    s, _ = _check({"uri": "https://lumenfield.example/about"})
    assert s["access"] == "ok" and s["fetch"] and s["size_tokens"] > 0
    s, _ = _check({"type": "linkedin_manual", "text": ""})
    assert s["access"] == "pending" and s["fix_action"] == "fill_by_hand"


# ---------------------------------------------------------------- readers

def test_readers_office_and_pdf(tmp_path):
    p = tmp_path / "deck.pptx"
    make_pptx(p, [("Intro", "Lumenfield today", "Say hi to Emily"), ("Hidden", "draft", ""), ("Pricing", "Two plans", "")],
              hidden=(1,), order=[2, 0, 1])
    r = RD.read(str(p))
    assert [s["title"] for s in r["slides"]] == ["Pricing", "Intro"] and r["hidden_skipped"] == 1
    assert r["slides"][1]["notes"] == "Say hi to Emily" and "[slide 1] Pricing" in r["text"]
    x = tmp_path / "pipeline.xlsx"
    make_xlsx(x)
    r = RD.read(str(x))
    assert "[sheet Pipeline]" in r["text"] and "Northwind Studio\t\t42" in r["text"] and "hidden" not in r["text"]
    d = tmp_path / "notes.docx"
    make_docx(d)
    r = RD.read(str(d))
    assert r["text"].splitlines()[0] == "# Orbit sync notes" and "on December 4." in r["text"] and "Risk | Late API keys" in r["text"]
    f = tmp_path / "brief.pdf"
    make_pdf(f, ["Orbit renewal is due in March", "Budget approved by Sarah M"])
    r = RD.read(str(f))
    assert "Orbit renewal is due in March" in r["text"] and "[page 2]" in r["text"] and r["pages"] == 2
    assert RD.pdf_pages_simple(f.read_bytes()) == ["Orbit renewal is due in March", "Budget approved by Sarah M"]
    (tmp_path / "bad.docx").write_bytes(b"not a zip")
    assert "damaged" in RD.read(str(tmp_path / "bad.docx"))["error"]
    c = tmp_path / "t.csv"
    c.write_text("a,b\n1,2\n", encoding="utf-8")
    assert RD.read(str(c))["text"] == "a,b\n1,2\n"


# ---------------------------------------------------------------- tokens

def test_token_estimates_cyrillic_and_latin():
    w = Z.load_windows()
    en = "The team agreed to move the reporting release to December and asked about the budget. " * 50
    uk = "Команда погодилась перенести реліз звітності на грудень і запитала про бюджет. " * 50
    e_en, e_uk = Z.estimate(en, "codex", w), Z.estimate(uk, "codex", w)
    assert 0.18 < e_en / len(en) < 0.30            # about 4 characters a token in English
    assert e_uk / len(uk) > e_en / len(en) * 1.3     # Cyrillic takes more tokens per character
    assert Z.estimate(en, "code", w) > e_en          # Claude's tokenizer: more tokens for the same text
    assert Z.estimate("", "codex", w) == 0
    assert Z.route_info("plan", w)["route"] == "code" and Z.route_info("local", w)["window"] == 65536


def test_size_report_states_and_plans():
    w = Z.load_windows()
    small = [{"id": "s1", "n": 1, "type": "file", "access": "ok", "size_tokens": 5000, "title": "a"}]
    assert Z.report(small, "codex", windows=w)["state"] == "fits"
    big = [{"id": f"s{i}", "n": i, "type": "folder_file", "auto": True, "access": "ok", "size_tokens": 90000, "title": str(i)}
           for i in range(1, 8)]
    r = Z.report(big, "codex", windows=w)
    assert r["state"] == "too_much" and r["plan"] == {"mode": "one"} and {p["mode"] for p in r["plans"]} == {"passes", "compress"}
    passes = r["plans"][0]["passes"]
    assert all(p["tokens"] <= r["per_pass"] for p in passes) and sum(len(p["source_ids"]) for p in passes) == 7
    assert Z.report(big, "codex", windows=w, chosen="passes")["plan"]["mode"] == "passes"
    assert r["biggest"][0]["tokens"] == 90000 and len(r["biggest"]) == 5


# ---------------------------------------------------------------- candidates

def test_candidates_rank_with_why(tmp_path):
    root = tmp_path / "Orbit"
    (root / "notes").mkdir(parents=True)
    (root / "_archived").mkdir()
    (root / "live").mkdir()
    (root / "notes" / "emily-parker-call-notes.md").write_text("Emily Parker from Lumenfield asked about reporting", encoding="utf-8")
    (root / "notes" / "orbit-sync-agenda-v2.md").write_text("v2", encoding="utf-8")
    (root / "notes" / "orbit-sync-agenda-v3.md").write_text("v3", encoding="utf-8")
    (root / "notes" / "random.md").write_text("nothing relevant", encoding="utf-8")
    old = root / "notes" / "random.md"
    os.utime(old, (1_600_000_000, 1_600_000_000))
    (root / "_archived" / "old.md").write_text("old", encoding="utf-8")
    (root / "image.png").write_bytes(b"\x89PNG")
    req = {"project": {"root": str(root), "slug": "orbit"}, "meeting": {"title": "Orbit sync", "start": "2026-11-13T10:00:00"},
           "participants": {"theirs": [{"name": "Emily Parker", "company": "Lumenfield"}]}}
    out = SRC.candidates(req)
    files = [c for c in out["candidates"] if c["type"] == "folder_file"]
    names = [os.path.basename(c["path"]) for c in files]
    assert names[0] == "emily-parker-call-notes.md" and "same contact" in files[0]["why"]
    assert "orbit-sync-agenda-v3.md" in names and "orbit-sync-agenda-v2.md" not in names
    v3 = next(c for c in files if c["path"].endswith("v3.md"))
    assert "title match" in v3["why"] and "newer version" in v3["why"]
    assert names[-1] == "random.md" and files[-1]["why"] == ["rest of the folder"]
    assert not any(c["suggested"] for c in files)               # nothing ticked without the series
    assert out["excluded"].get("archived") == 1 and out["excluded"].get("not a document") == 1


# ---------------------------------------------------------------- build on a fake model

ANSWER = {
    "goal": "Agree on a discovery workshop",
    "blocks": {
        "overview": [{"label": "Who", "text": "Lumenfield sells lighting software; Emily Parker runs operations.",
                      "source_ids": ["s1"], "locator": {"quote": "lighting software"}, "status": "found",
                      "keywords": ["lighting software"]}],
        "company": [{"label": "Team size", "text": "About 120 employees", "source_ids": ["s1"], "locator": {"line": 2}},
                    {"label": "Team size", "text": "About 80 employees", "source_ids": ["s2"], "locator": {"quote": "80"}},
                    {"label": "Founded", "text": "2019", "source_ids": ["s9"]}],
        "contact": [{"label": "Role", "text": "VP Operations", "source_ids": ["s2"], "locator": {"quote": "VP Operations"},
                     "keywords": ["operations"]}],
        "qualification": [{"label": "Budget", "text": "Not stated", "source_ids": [], "status": "not_found",
                           "value": {"key": "budget", "level": "unknown"}},
                          {"label": "Need", "text": "Manual reports take two days a month", "source_ids": ["s1"],
                           "value": {"key": "need", "level": "green"}}],
        "questions": [{"text": "Who signs off on a workshop?", "source_ids": ["s1"], "keywords": ["sign off"]}],
        "agenda": [{"label": "Reporting pain", "text": "Walk through the monthly report", "source_ids": ["s1"],
                    "value": {"owner": "Mike Carter"}}],
        "nonsense": [{"text": "dropped"}],
    }}


def _project(tmp_path, n_files=2):
    root = tmp_path / "Lumenfield"
    (root / "live").mkdir(parents=True)
    a = root / "about.md"
    a.write_text("Lumenfield sells lighting software.\nOur team of 120 people.\n", encoding="utf-8")
    b = root / "profile.md"
    b.write_text("Emily Parker, VP Operations. Team page lists 80.\n", encoding="utf-8")
    return root, a, b


def _req(root, a, b, **kw):
    r = {"preset": "sales_intro", "route": "fake", "language": "en",
         "blocks": ["header", "overview", "company", "signals", "contact", "qualification", "agenda", "questions",
                    "best_outcome", "red_lines", "gaps"],
         "meeting": {"title": "Lumenfield intro", "start": "2026-11-13T16:00:00+02:00"},
         "participants": {"ours": [{"name": "Mike Carter"}], "theirs": [{"name": "Emily Parker", "company": "Lumenfield"}]},
         "project": {"slug": "lumenfield", "root": str(root)}, "today": "2026-11-12",
         "sources": [{"id": "s1", "path": str(a)}, {"id": "s2", "path": str(b)}],
         "base": str(root / "live" / "prep-2026-11-13-1600-lumenfield-intro")}
    r.update(kw)
    return r


def quiet(**kw):
    pass


def test_build_contract_conflicts_report_and_derive(tmp_path):
    root, a, b = _project(tmp_path)
    req = _req(root, a, b)
    seen = {}
    def responder(system, user):
        seen["system"], seen["user"] = system, user
        return "Here it is:\n```json\n" + json.dumps(ANSWER) + "\n```"
    lines = []
    res = B.build(req, emit=lambda **k: lines.append(k), responder=responder)
    assert res.get("done"), res
    assert "=== SOURCE s1 | file | about.md" in seen["user"] and "not_found" in seen["system"]
    assert lines[0]["stage"] == "sources" and any(x.get("stage") == "merge" for x in lines)
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    assert S.validate(sheet) == []
    comp = next(x for x in sheet["blocks"] if x["type"] == "company")["facts"]
    size = [f for f in comp if f["label"] == "Team size"]
    assert {f["status"] for f in size} == {"conflict"} and size[0]["conflict_with"] == [size[1]["id"]]
    founded = next(f for f in comp if f["label"] == "Founded")
    assert founded["status"] == "needs_check" and founded["source_ids"] == []       # unknown source s9 never shows as sourced
    hdr = next(x for x in sheet["blocks"] if x["type"] == "header")["facts"]
    assert any(f["label"] == "Their side" and "Emily Parker" in f["text"] for f in hdr)
    assert sheet["goal"] == "Agree on a discovery workshop" and res["conflicts"] == 1
    assert sheet["versions"][-1]["n"] == 1 and sheet["readiness"]["state"] in ("almost", "not_ready")
    qs = next(x for x in sheet["blocks"] if x["type"] == "questions")["facts"]
    assert any(f["id"] == "q-readiness-budget" for f in qs)                          # the readiness engine's budget question
    base = req["base"]
    for suffix in (".sheet.json", ".sheet.v1.json", ".sheet.md", ".sheet.sources.json", ".brief.md", ".cards.json",
                   ".facts.json", ".agenda.json"):
        assert Path(base + suffix).exists(), suffix
    rep = json.loads(Path(base + ".sheet.sources.json").read_text(encoding="utf-8"))
    row = {r["id"]: r for r in rep["sources"]}
    assert row["s1"]["used"] == "full" and row["s1"]["facts"] >= 3 and row["s-meeting"]["facts"] >= 1
    # the live files parse with the recorder's own parsers
    sys.path.insert(0, str(REC))
    import importlib
    tr = importlib.import_module("transcriber")
    cards = tr.parse_cards(json.loads(Path(base + ".cards.json").read_text(encoding="utf-8")))
    facts = tr.parse_facts(json.loads(Path(base + ".facts.json").read_text(encoding="utf-8")))
    assert cards and all(c["triggers"] for c in cards) and any(f["title"] == "Team size" for f in facts)
    from livetips_m0 import agenda as AG
    brief = Path(base + ".brief.md").read_text(encoding="utf-8")
    assert brief.startswith("# Live Brief: Emily Parker (prep, 2026-11-13 16:00, Meeting Sheet)")
    items = AG.full_items(brief)
    assert ("Reporting pain: Walk through the monthly report (lead: Mike Carter)", False) in items
    assert AG.IDENTITY.search(brief) and chr(0x2014) not in brief


def test_too_much_needs_a_choice_and_passes_merge(tmp_path, monkeypatch):
    root, a, b = _project(tmp_path)
    monkeypatch.setattr(Z, "per_pass", lambda info, windows: 40)      # every source is "big" for this test
    req = _req(root, a, b)
    res = B.build(req, emit=quiet, responder=lambda s, u: json.dumps(ANSWER))
    assert res["error"] == "too_much" and res["code"] == 4 and res["size_report"]["plans"]
    calls = []
    def responder(system, user):
        calls.append(user)
        if "SOURCE s1" in user:
            return json.dumps({"blocks": {"company": [{"label": "Team size", "text": "About 120 employees", "source_ids": ["s1"]}],
                                          "qualification": [{"label": "Budget", "text": "unknown", "status": "not_found",
                                                             "value": {"key": "budget", "level": "unknown"}}]}})
        return json.dumps({"blocks": {"company": [{"label": "Team size", "text": "About 120 employees", "source_ids": ["s2"]}],
                                      "qualification": [{"label": "Budget", "text": "$40k set aside", "source_ids": ["s2"],
                                                         "value": {"key": "budget", "level": "green"}}]}})
    res = B.build(dict(req, plan="passes"), emit=quiet, responder=responder)
    assert res.get("done"), res
    assert len(calls) >= 2 and all("pass" in c for c in calls)
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    comp = next(x for x in sheet["blocks"] if x["type"] == "company")["facts"]
    assert len(comp) == 1 and set(comp[0]["source_ids"]) == {"s1", "s2"}            # the same fact once, both sources
    qual = next(x for x in sheet["blocks"] if x["type"] == "qualification")["facts"]
    bud = [f for f in qual if (f.get("value") or {}).get("key") == "budget"]
    assert len(bud) == 1 and bud[0]["status"] == "found"                             # found beats not_found of another pass
    # queued without a person: the app may choose passes, and the report says so
    res = B.build(dict(req, on_too_much="passes"), emit=quiet, responder=responder)
    assert res.get("done") and res["notes"]


def test_stale_by_months_newer_wins():
    facts = {"company": [{"label": "Team size", "text": "120", "source_ids": ["a"], "status": "found"},
                         {"label": "Team size", "text": "80", "source_ids": ["b"], "status": "found"}]}
    srcs = {"a": {"modified_at": "2026-11-01"}, "b": {"modified_at": "2025-09-01"}}
    assert B.mark_conflicts(facts, srcs, 6) == 0
    assert [f["status"] for f in facts["company"]] == ["found", "stale"]


def test_one_pass_failing_is_reported_and_others_go_on(tmp_path, monkeypatch):
    root, a, b = _project(tmp_path)
    monkeypatch.setattr(Z, "per_pass", lambda info, windows: 40)
    def responder(system, user):
        if "SOURCE s2" in user:
            raise RuntimeError("Codex: request failed")
        return json.dumps(ANSWER)
    res = B.build(_req(root, a, b, plan="passes"), emit=quiet, responder=responder)
    assert res.get("done") and res["failures"] and "Codex" in res["failures"][0]["error"]
    rep = json.loads(Path(_req(root, a, b)["base"] + ".sheet.sources.json").read_text(encoding="utf-8"))
    assert next(r for r in rep["sources"] if r["id"] == "s2")["used"] == "skipped"


def test_compress_summarizes_biggest_first(tmp_path, monkeypatch):
    root, a, b = _project(tmp_path)
    monkeypatch.setattr(Z, "per_pass", lambda info, windows: 60)
    asked = []
    def responder(system, user):
        asked.append(system[:40])
        if system.startswith("Summarize"):
            return "short summary"
        return json.dumps(ANSWER)
    res = B.build(_req(root, a, b, plan="compress"), emit=quiet, responder=responder)
    assert res.get("done"), res
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    assert any(s.get("used") == "summarized" for s in sheet["sources"])
    assert asked[0].startswith("Summarize") and not asked[-1].startswith("Summarize")


def test_refresh_diff_and_edits_survive(tmp_path):
    root, a, b = _project(tmp_path)
    req = _req(root, a, b)
    assert B.build(req, emit=quiet, responder=lambda s, u: json.dumps(ANSWER)).get("done")
    path = Path(req["base"] + ".sheet.json")
    sheet = json.loads(path.read_text(encoding="utf-8"))
    contact = next(x for x in sheet["blocks"] if x["type"] == "contact")
    contact["facts"][0].update(text="VP Operations, reports to the CEO", status="edited")
    path.write_text(json.dumps(sheet), encoding="utf-8")
    second = json.loads(json.dumps(ANSWER))
    second["blocks"]["contact"] = [{"label": "Role", "text": "COO", "source_ids": ["s2"]}]
    second["blocks"]["overview"][0]["text"] = "Lumenfield sells lighting and HVAC software."
    second["blocks"]["agenda"] = []
    second["blocks"]["signals"] = [{"label": "Hiring", "text": "Hiring two analysts", "source_ids": ["s1"]}]
    res = B.build(req, refresh=True, emit=quiet, responder=lambda s, u: json.dumps(second))
    assert res.get("done") and res["version"] == 2, res
    new = json.loads(path.read_text(encoding="utf-8"))
    c = next(x for x in new["blocks"] if x["type"] == "contact")["facts"]
    assert c[0]["text"] == "VP Operations, reports to the CEO" and c[0]["status"] == "edited" and len(c) == 1
    d = new["diff"]
    assert len(d["new"]) == 1 and len(d["changed"]) == 1 and any(g["block"] == "agenda" for g in new["gone_facts"])
    ov = next(x for x in new["blocks"] if x["type"] == "overview")["facts"][0]
    assert ov["diff"] == "changed" and ov["was"].startswith("Lumenfield sells lighting software")
    assert new["refreshed_at"] and [v["n"] for v in new["versions"]] == [1, 2]
    assert Path(req["base"] + ".sheet.v2.json").exists() and S.validate(new) == []


def test_deck_source_gives_slides_json(tmp_path):
    root, a, b = _project(tmp_path)
    deck = tmp_path / "talk.pptx"
    make_pptx(deck, [("Why Orbit", "Three wins", ""), ("Roadmap", "Q1 plan", "")])
    req = _req(root, a, b)
    req["sources"].append({"id": "s3", "path": str(deck), "deck": {"owners": {"2": "Sarah M."}, "minutes": 10}})
    res = B.build(req, emit=quiet, responder=lambda s, u: json.dumps(ANSWER))
    assert res.get("done"), res
    sl = json.loads(Path(req["base"] + ".slides.json").read_text(encoding="utf-8"))
    sys.path.insert(0, str(REC))
    import importlib
    parsed = importlib.import_module("transcriber").parse_slides(sl)
    assert [x["who"] for x in parsed] == ["me", "other"] and parsed[1]["speaker"] == "Sarah M." and parsed[0]["sec"] == 300


def test_cli_sources_size_candidates_derive(tmp_path, capsys):
    root, a, b = _project(tmp_path)
    req = _req(root, a, b, context="Read https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit")
    rp = tmp_path / "req.json"
    rp.write_text(json.dumps(req), encoding="utf-8")
    assert CLI.main(["sources", "--request", str(rp)]) == 0
    o = json.loads(capsys.readouterr().out)
    assert [s["id"] for s in o["sources"]][:2] == ["s-context", "s1"] and o["suggestions"][0]["type"] == "gdoc"
    assert CLI.main(["size", "--request", str(rp)]) == 0
    o = json.loads(capsys.readouterr().out)
    assert o["state"] == "fits" and o["route"] == "fake"
    assert CLI.main(["candidates", "--request", str(rp)]) == 0
    o = json.loads(capsys.readouterr().out)
    assert not {os.path.basename(c.get("path", "")) for c in o["candidates"]} & {"about.md", "profile.md"}   # already sources
    B.build(req, emit=quiet, responder=lambda s, u: json.dumps(ANSWER))
    capsys.readouterr()
    assert CLI.main(["derive", "--sheet", req["base"] + ".sheet.json"]) == 0
    o = json.loads(capsys.readouterr().out)
    assert any(p.endswith(".brief.md") for p in o["written"])


def test_prompt_contract_and_json():
    assert PR.as_json('x {"locator": {}} y {"blocks": {}}')["blocks"] == {}
    s = PR.system("uk", ["uk", "en"])
    assert "Ukrainian" in s and "not_found" in s and chr(0x2014) not in s and chr(0x2014) not in PR.SUMMARY_SYS


def test_list_blocks_have_no_conflicts():
    """Bench 12.11: two "Outcome" items of best_outcome from two sources are two items, not a conflict."""
    facts = {"best_outcome": [{"label": "Outcome", "text": "Agree on the bundle", "source_ids": ["a"], "status": "found"},
                              {"label": "Outcome", "text": "Agree on the London rollout", "source_ids": ["b"], "status": "found"}],
             "contact": [{"label": "Role", "text": "VP Operations", "source_ids": ["a"], "status": "found"},
                         {"label": "Role", "text": "COO", "source_ids": ["b"], "status": "found"}]}
    assert B.mark_conflicts(facts, {}, 6) == 1
    assert [f["status"] for f in facts["best_outcome"]] == ["found", "found"]
    assert [f["status"] for f in facts["contact"]] == ["conflict", "conflict"]


def test_diff_ignores_rewording_and_relabelling():
    """Bench 12.11 (refresh on the ChatGPT account): the model reworded and relabelled facts; only real changes show."""
    def sheet(facts):
        return {"blocks": [{"type": "company", "facts": facts}]}
    old = sheet([{"id": "a", "label": "Seed funding", "text": "Website press notes report a $6M seed round in 2021.", "status": "found", "origin": "model"},
                 {"id": "b", "label": "Team size", "text": "About 120 employees", "status": "found", "origin": "model"}])
    new = sheet([{"id": "c", "label": "Funding", "text": "The press notes report a $6M seed round in 2021.", "status": "found", "origin": "model"},
                 {"id": "d", "label": "Team size", "text": "About 140 employees", "status": "found", "origin": "model"}])
    d = B.diff(old, new)
    assert d["new"] == [] and d["gone"] == [] and d["changed"] == ["d"]
    assert B.similar("Budget is $70k", "The budget is $70k") and not B.similar("Budget is $70k", "Budget is $50k")
    assert "Team size" in PR.previous_labels(old) and PR.previous_labels(None) == ""
