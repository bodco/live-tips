from livetips_m0 import wrapup_notion as W


def test_transcript_blocks_lines_and_markers():
    text = "# Live transcript: Weekly sync\n\n[10:00:01] Mike (en): Hello there\n--- pause 10:05 ---\nplain note\n"
    b = W.transcript_blocks(text)
    assert b[0]["type"] == "heading_2"
    line = b[1]["paragraph"]["rich_text"]
    assert line[0]["text"]["content"] == "10:00:01 Mike: " and line[0]["annotations"]["bold"]
    assert line[1]["text"]["content"] == "Hello there"
    assert b[2]["paragraph"]["rich_text"][0]["annotations"]["italic"]
    assert b[3]["type"] == "paragraph"


def test_transcript_page_chunks(monkeypatch):
    calls = []

    def fake(method, path, body=None):
        calls.append((method, path, len((body or {}).get("children", []))))
        return {"id": "p1"}
    monkeypatch.setattr(W, "notion", fake)
    text = "\n".join("[10:00:%02d] Emily (en): line %d" % (i % 60, i) for i in range(200))
    W.transcript_page("parent", "Transcript", text)
    assert calls[0] == ("POST", "/pages", 90)
    assert sum(c[2] for c in calls) == 200
