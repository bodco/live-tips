"""tools/replay_local.py: the recorder's local layer replayed on a written transcript, with a fake embedder."""
import json
import re
import zlib

import numpy as np

import replay_local as R

DIM = 256


def fake_embed(texts):
    """Bag of word stems hashed into DIM buckets: shared words give a high cosine, nothing else does."""
    out = np.zeros((len(texts), DIM), dtype=np.float32)
    for i, t in enumerate(texts):
        for w in re.findall(r"\w{3,}", t.lower()):
            out[i, zlib.crc32(w[:5].encode()) % DIM] += 1.0
        out[i, 0] += 0.05
    return out


MD = """# Live transcript: Weekly sync

- Project: demo
- Start: 2026-11-04 10:00:00
- Languages: Me = en, allowed = en
- Channels: Me = microphone, Other side = system audio

--- call started 10:00:00 ---
[10:00:05] Me (en): Hi Emily, thanks for joining today.
[10:00:10] Other side [S1] (en): Quick one, what is the admin audit logs estimate now?
[10:00:20] Other side [S1] (en): The admin audit logs are blocking our release review.
[10:00:30] Other side [S1] (en): Admin audit logs again, the release review waits for them.
[10:00:40] Other side [S1] (en): Could you also add export to the scope?
[10:01:00] Other side [S1] (en): Could you also add a second export to the scope?
[10:02:00] Other side [S1] (en): The payment form ships in sprint four for us.
[10:02:15] Other side [S1] (en): So the payment form ships in sprint four then.
[10:07:00] Other side [S1] (en): Could you also add one more export to the scope?
"""

FACTS = [{"id": "AUTH-1", "title": "Admin audit logs", "text": "estimate 16 h, In Progress, Mike",
          "keywords": ["admin", "audit", "logs"], "source": "Jira"},
         {"id": "PAY-2", "title": "Step 3: payments", "text": "the payment form ships in sprint 4",
          "keywords": ["payment", "form"], "source": "Jira"}]
CARDS = [{"id": "cr", "triggers": ["could you also"], "on": "them", "level": "red",
          "gist": "Scope change: log it as a CR", "cooldown_s": 300}]


def _call(tmp_path, timing=True):
    md = tmp_path / "call.md"
    md.write_text(MD, encoding="utf-8")
    (tmp_path / "call.facts.json").write_text(json.dumps(FACTS), encoding="utf-8")
    (tmp_path / "call.cards.json").write_text(json.dumps(CARDS), encoding="utf-8")
    if timing:
        rows = []
        for m in re.finditer(r"^\[(\d\d:\d\d:\d\d)\] (Me|Other side \[S1\]) ", MD, re.M):
            h, mi, s = map(int, m.group(1).split(":"))
            rows.append({"t": m.group(1), "ch": "me" if m.group(2) == "Me" else "them",
                         "written": f"{h:02d}:{mi:02d}:{s + 5:02d}.500"})
        (tmp_path / "call.md.timing.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    return md


def _cfg(**kw):
    cfg = R.build_cfg(None, [])
    cfg.update(semantic_fact_min=0.45, semantic_margin=0.1, semantic_card_min=0.95, name_aliases=["Bohdan"])
    cfg.update(kw)
    return cfg


def test_parse_and_order(tmp_path):
    md = _call(tmp_path)
    lines = R.load_lines(md, tmp_path / "call.md.timing.jsonl")
    assert [x.ch for x in lines[:2]] == ["me", "them"]
    assert lines[1].written - lines[1].t == 5.5
    assert all(a.written <= b.written for a, b in zip(lines, lines[1:]))
    no_timing = R.load_lines(md, None)
    assert no_timing[1].written - no_timing[1].t == 1.0


def test_replay_shows_keyword_card_with_replay_clock_cooldown(tmp_path):
    md = _call(tmp_path)
    lines = R.load_lines(md, tmp_path / "call.md.timing.jsonl")
    out = tmp_path / "out"
    paths = R.run(lines, tmp_path / "call.facts.json", tmp_path / "call.cards.json", _cfg(), None, out, "call",
                  semantic=False)
    cards = [x for x in R.shows(paths["tips"], {}) if x["kind"] == "card"]
    # 10:00:40 fires, 10:01:00 is inside the 300 s cooldown, 10:07:00 is past it: the clock is the call's, not the wall's
    assert [(c["key"], c["src"]) for c in cards] == [("cr", "10:00:40"), ("cr", "10:07:00")]
    assert cards[0]["at"] == "10:00:45" and cards[0]["path"] == "keyword"


def test_semantic_fact_gate_and_reasons(tmp_path):
    md = _call(tmp_path)
    lines = R.load_lines(md, tmp_path / "call.md.timing.jsonl")
    client = R.ReplayClient(fake_embed, cache_path=tmp_path / "out" / "v.npz")
    paths = R.run(lines, tmp_path / "call.facts.json", tmp_path / "call.cards.json", _cfg(semantic_fact_min=0.99, semantic_window_min=0.99),
                  client, tmp_path / "out", "call")
    assert R.shows(paths["tips"], {}) == [x for x in R.shows(paths["tips"], {}) if x["path"] == "keyword"]
    client2 = R.ReplayClient(fake_embed, cache_path=tmp_path / "out" / "v.npz")
    assert client2.vc and client2.calls == 0          # vectors were saved: a rerun embeds nothing new
    paths = R.run(lines, tmp_path / "call.facts.json", tmp_path / "call.cards.json", _cfg(), client2, tmp_path / "out", "call")
    facts = [x for x in R.shows(paths["tips"], R._title_ids(tmp_path / "call.facts.json")) if x["kind"] == "fact"]
    # the question names the fact: the keyword path shows it first, the semantic path then finds it claimed
    assert [(f["key"], f["src"], f["path"]) for f in facts] == [("AUTH-1", "10:00:10", "keyword"),
                                                                 ("PAY-2", "10:02:15", "semantic")]
    log = [json.loads(x) for x in paths["semantic"].read_text(encoding="utf-8").splitlines() if x.strip()]
    why = {(r["t"], r["id"]): r["why"] for r in log if r.get("kind") == "fact" and "id" in r}
    assert why[("10:00:10", "AUTH-1")] == "cooldown (or keyword hit)"
    assert why[("10:02:00", "PAY-2")] == "not a question, topic not held"      # a statement, the topic not yet held
    assert why[("10:02:15", "PAY-2")] is None                                 # the second line on it: held, shown
    assert R.rejections(paths["semantic"])[("fact", "not a question, topic not held")] >= 1


def test_question_items_and_report(tmp_path):
    md = _call(tmp_path)
    lines = R.load_lines(md, tmp_path / "call.md.timing.jsonl")
    paths = R.run(lines, tmp_path / "call.facts.json", tmp_path / "call.cards.json", _cfg(), None, tmp_path / "o", "call",
                  semantic=False)
    rep = R.shows(paths["tips"], {})
    assert any(x["kind"] == "question" and x["src"] == "10:00:10" for x in rep)
    live = [dict(rep[0]), {"kind": "fact", "key": "PAY-2", "src": "10:00:20", "at": "10:00:25", "path": "semantic",
                           "sem": 0.6, "gist": "x"}]
    cmp = R.compare(live, rep)
    assert len(cmp["matched"]) == 1 and cmp["only_live"][0]["key"] == "PAY-2" and len(cmp["only_replay"]) == len(rep) - 1
    text, summ = R.report("call", rep, R.rejections(paths["semantic"]), cmp, R.rejections(paths["semantic"]), {"lines": 9})
    assert "## Live vs replay" in text and summ["live"]["matched"] == 1 and chr(0x2014) not in text


def test_fact_keys_titles_with_colon():
    ids = {"Step 3: payments": "PAY-2", "Step 3": "S3"}
    assert R.fact_keys(["Step 3: payments: the form ships", "Step 3: other"], "", ids) == "PAY-2,S3"
    assert R.fact_keys([], "📌 Step 3: payments", ids) == "PAY-2"


def test_main_end_to_end(tmp_path, capsys, monkeypatch):
    md = _call(tmp_path)
    (tmp_path / "call.tips.jsonl").write_text(json.dumps({"kind": "card", "card": "cr", "t": "10:00:40", "src": "10:00:40",
                                                          "at": "10:00:45", "gist": "Scope"}) + "\n", encoding="utf-8")
    monkeypatch.setattr(R, "make_client", lambda a, cfg, p: R.ReplayClient(fake_embed, cache_path=p))
    assert R.main(["--md", str(md), "--out", str(tmp_path / "o"), "--compare", "--set", "semantic_card_min=0.95"]) == 0
    out = capsys.readouterr().out
    assert "replay_local: 9 lines" in out and "matched 1" in out
    summ = json.loads((tmp_path / "o" / "call.local-summary.json").read_text(encoding="utf-8"))
    assert summ["meta"]["timing"] is True and summ["live"]["matched"] == 1


# 0.9.2 (audit 04.11, item 3): the topic window, the PM's own words, a fact once per call by topic

WIN_MD = """# Live transcript: Weekly sync

- Start: 2026-11-04 10:00:00
- Channels: Me = microphone, Other side = system audio

[10:00:00] Other side [S1] (en): We looked again at the vendor contract terms yesterday.
[10:00:09] Other side [S1] (en): The renewal clause and the termination notice worry legal.
[10:00:18] Other side [S1] (en): Ninety days notice seems long for a vendor contract renewal.
[10:00:27] Other side [S1] (en): So the contract renewal terms need another look from legal.
[10:00:40] Me (en): The payment form ships in sprint four, Emily.
[10:00:50] Other side [S1] (en): Right, the payment form ships in sprint four then.
[10:00:59] Other side [S1] (en): Good that the payment form ships in sprint four.
[10:05:00] Other side [S1] (en): Back to the vendor contract renewal clause and the notice.
[10:05:09] Other side [S1] (en): The vendor contract renewal notice of ninety days again.
"""

WIN_FACTS = [{"id": "VEN-1", "title": "Vendor contract", "text": "renewal clause, ninety days termination notice",
              "keywords": ["vendor", "contract", "renewal", "notice"]},
             {"id": "PAY-2", "title": "Payment form", "text": "the payment form ships in sprint four",
              "keywords": ["payment", "form", "sprint"]}]


def _win_call(tmp_path):
    md = tmp_path / "w.md"
    md.write_text(WIN_MD, encoding="utf-8")
    (tmp_path / "w.facts.json").write_text(json.dumps(WIN_FACTS), encoding="utf-8")
    return md


def _win_log(tmp_path, **kw):
    md = _win_call(tmp_path)
    lines = R.load_lines(md, None)
    # line-level matching off (a high fact_min), the window decides
    kw.setdefault("semantic_window_min", 0.3)
    cfg = _cfg(semantic_fact_min=kw.pop("fact_min", 0.95), semantic_window_margin=0.1, **kw)
    paths = R.run(lines, tmp_path / "w.facts.json", None, cfg, R.ReplayClient(fake_embed), tmp_path / "o", "w")
    log = [json.loads(x) for x in paths["semantic"].read_text(encoding="utf-8").splitlines() if x.strip()]
    return R.shows(paths["tips"], R._title_ids(tmp_path / "w.facts.json")), log


def test_two_windows_in_a_row_hold_the_topic(tmp_path):
    rep, log = _win_log(tmp_path, semantic_window_strong=9.0)
    facts = [(x["key"], x["src"]) for x in rep if x["kind"] == "fact"]
    # 10:00:00 has no window yet (1 line), 10:00:09 is the first window above the bar, 10:00:18 the second: shown
    assert facts[0] == ("VEN-1", "10:00:18")
    first = next(r for r in log if r.get("id") == "VEN-1" and r.get("shown"))
    assert first["held"] is True and first["win"] is not None


def test_one_strong_window_is_enough(tmp_path):
    rep, _ = _win_log(tmp_path, semantic_window_strong=0.1)
    assert [(x["key"], x["src"]) for x in rep if x["kind"] == "fact"][0] == ("VEN-1", "10:00:09")


def test_what_the_pm_just_said_is_not_shown_and_a_fact_comes_once(tmp_path):
    rep, log = _win_log(tmp_path, fact_min=0.5, semantic_window_strong=0.1)
    why = [(r["t"], r["id"], r["why"]) for r in log if r.get("kind") == "fact" and r.get("id")]
    assert ("10:00:50", "PAY-2", "said by the PM") in why            # the PM said it at 10:00:40
    assert all(k != "PAY-2" for k, _ in [(x["key"], x["src"]) for x in rep if x["kind"] == "fact"])
    assert any(t >= "10:05:00" and i == "VEN-1" and w == "shown before" for t, i, w in why)
    assert [x["key"] for x in rep if x["kind"] == "fact"].count("VEN-1") == 1


def test_window_on_another_topic_blocks_a_two_line_match(tmp_path):
    """04.11, 13:21: two lines matched Fireflies credits while the last minute was about HubSpot."""
    md = tmp_path / "w.md"
    long = "vendor contract renewal clause termination notice legal review vendor contract renewal notice period"
    md.write_text("- Start: 2026-11-04 10:00:00\n- Channels: Me = microphone, Other side = system audio\n\n"
                  + "".join(f"[10:00:{s:02d}] Other side (en): {long}\n" for s in (0, 8, 16))
                  + "[10:00:24] Other side (en): payment form sprint\n[10:00:30] Other side (en): payment form sprint\n",
                  encoding="utf-8")
    (tmp_path / "w.facts.json").write_text(json.dumps(WIN_FACTS[1:]), encoding="utf-8")
    cfg = _cfg(semantic_fact_min=0.5, semantic_margin=0.05, semantic_window_min=0.99, semantic_window_strong=9.0)
    paths = R.run(R.load_lines(md, None), tmp_path / "w.facts.json", None, cfg, R.ReplayClient(fake_embed), tmp_path / "o", "w")
    log = [json.loads(x) for x in paths["semantic"].read_text(encoding="utf-8").splitlines() if x.strip()]
    assert [(r["t"], r["why"]) for r in log if r.get("id") == "PAY-2" and r.get("why") != "below threshold"] == \
        [("10:00:24", "not a question, topic not held"), ("10:00:30", "window on another topic")]
