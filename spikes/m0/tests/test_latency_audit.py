from livetips_m0.latency_audit import elapsed, summarize


def test_stages_midnight_and_missing_audio_are_not_conflated():
    rows = [{"seg_end": 86399, "written": 0, "available_at": 1, "shown_at": 2, "emit_at": 11, "tip_start": 1},
            {"shown_at": 100, "emit_at": 110, "e2e_shown_s": 3500}]
    report = summarize(rows)
    assert report["missing_audio_end"] == 1
    assert report["stages"]["audio_to_first_gist"]["p50_s"] == 3
    assert report["stages"]["audio_to_final"]["p50_s"] == 12
    assert report["stages"]["audio_to_final"]["n"] == 1
    assert elapsed(1, 2) is None
    assert elapsed(0, 0) == 0
    assert report["ui_paint"] == "not measured"
