from livetips_m0.fact_quality import measures, threshold_audit


def row(call, score, cosine):
    return {"call": call, "judge": {"score": score}, "tip": {"sem": cosine}}


def test_holdout_cannot_choose_threshold_and_judge_cannot_promote():
    rows = [row("2026-11-02-daily", 4, .56), row("2026-11-02-interview", 1, .58),
            row("2026-11-03-standup", 4, .63)]
    audit = threshold_audit(rows, "2026-11-03")
    assert audit["candidate"] == .55
    assert not audit["ready_for_production"]
    assert audit["grid"][2]["train"]["good_lost"] == 1
    assert set(audit["train_calls"]).isdisjoint(audit["holdout_calls"])


def test_human_override_missing_labels_and_nonsemantic():
    rows = [row("2026-11-02-daily", 1, .56), row("2026-11-03-daily", 4, .57)]
    for r in rows:
        r["human"] = {"useful": True}
    rows += [{"call": "2026-11-03-other", "tip": {}, "judge": {"score": 4}}]
    audit = threshold_audit(rows, "2026-11-03")
    assert audit["passes_labeled_sample"]
    assert not audit["ready_for_production"]
    assert audit["excluded_nonsemantic_or_unmatched"] == 1
    assert measures([row("c", None, .56)], .55)["good_retention"] is None


def test_recorded_corpus_requires_unambiguous_fact_match(tmp_path):
    import json
    from livetips_m0.fact_quality import recorded_corpus
    stem = tmp_path / "2026-11-02-daily"
    tips = [{"kind": "fact", "gist": "📌 Limit", "src": "10:00:00", "sem": .56},
            {"kind": "fact", "gist": "📌 Duplicate", "src": "10:00:00", "sem": .60}]
    tips.append(tips[-1])
    stem.with_suffix(".tips.jsonl").write_text("\n".join(map(json.dumps, tips)))
    folder = tmp_path / (stem.name + ".judge")
    folder.mkdir()
    judges = [{"gist": "📌 Limit", "src_s": 36000, "score": 4},
              {"gist": "📌 Duplicate", "src_s": 36000, "score": 2},
              {"gist": "Ordinary hint", "src_s": 36000, "score": 3}]
    (folder / "judge.jsonl").write_text("\n".join(map(json.dumps, judges)))
    rows = recorded_corpus([stem])
    assert len(rows) == 2
    assert rows[0]["tip"]["sem"] == .56
    assert rows[1]["tip"] == {}


def test_empty_or_holdout_only_data_cannot_choose_threshold():
    for rows in ([], [row("2026-11-03-daily", 4, .61)]):
        audit = threshold_audit(rows, "2026-11-03")
        assert audit["candidate"] is None
        assert not audit["passes_labeled_sample"]


def test_cli_reports_without_modifying_corpus(tmp_path, monkeypatch, capsys):
    import json
    from livetips_m0.fact_quality import main
    path = tmp_path / "corpus.json"
    path.write_text("[]")
    monkeypatch.setattr("sys.argv", ["audit", "--corpus", str(path), "--holdout-date", "2026-11-03"])
    main()
    assert json.loads(capsys.readouterr().out)["semantic_rows"] == 0
    assert path.read_text() == "[]"
