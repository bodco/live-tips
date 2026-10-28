"""The mirror end to end against a fake Notion, pinned as a golden file tree (before the ub-mode split).
UPDATE_GOLDEN=1 rewrites the snapshot."""
import json
import os
import re
from pathlib import Path

import pytest

import mirror
from fake_notion import World, dashed

GOLDEN = Path(__file__).parent / "golden" / "mirror.json"
VOLATILE = [(re.compile(r"^mirrored: .*$", re.M), "mirrored: X"), (re.compile(r"^mirror_last_run: .*$", re.M), "mirror_last_run: X"),
            (re.compile(r"^- (last_run_utc|last_run_local|duration_s): .*$", re.M), r"- \1: X")]


def setup(tmp_path, monkeypatch, world):
    work = tmp_path / "work"
    (work / "Internal Delivery Playbook").mkdir(parents=True)       # an existing project folder is reused
    (work / "Internal Delivery Playbook" / "_notion" / "tasks").mkdir(parents=True)
    (work / "Internal Delivery Playbook" / "_notion" / "tasks" / "stray.md").write_text("orphan")
    conf = tmp_path / "conf"
    conf.mkdir()
    cfg = json.loads((Path(__file__).parents[1] / "mirror.config.example.json").read_text())
    cfg.update(work_root=str(work), secrets_file="", configs_dir=str(tmp_path / "none"), projects_ds="pds",
               databases={"meetings": "mds", "tasks": "tds", "reports": "rds", "broken": "missing"})
    cfgp = conf / "mirror.config.json"
    cfgp.write_text(json.dumps(cfg))
    for name, val in (("CONFIG_PATH", str(cfgp)), ("STATE_DIR", str(conf / "state")), ("LOG_DIR", str(conf / "logs")),
                      ("STATE_PATH", str(conf / "state" / "state.json")), ("LOCK_PATH", str(conf / "state" / "mirror.lock")),
                      ("LOG_PATH", str(conf / "logs" / "mirror.log"))):
        monkeypatch.setattr(mirror, name, val)
    monkeypatch.setenv("NOTION_TOKEN", "test-token")
    monkeypatch.setattr(mirror.Notion, "req", lambda self, m, p, body=None, version=None: (
        setattr(self, "calls", self.calls + 1), world.answer(m, p, body, version))[1])
    return work, conf


def run(monkeypatch, *args):
    monkeypatch.setattr(mirror.sys, "argv", ["mirror.py"] + list(args))
    return mirror.main()


HEX_ID = re.compile(r"[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}")


def ids(text: str) -> str:
    """Synthetic page ids as <id N>, so the snapshot holds no id-shaped strings."""
    return HEX_ID.sub(lambda m: "<id %d>" % int(m.group(0).replace("-", ""), 16), text)


def tree(root: Path, conf: Path):
    out = {}
    for base in (root, conf / "state"):
        for d, _dirs, files in os.walk(base):
            for fn in sorted(files):
                p = Path(d) / fn
                if fn == "mirror.lock":
                    continue
                text = p.read_text(encoding="utf-8")
                if fn == "state.json":
                    st = json.loads(text)
                    for k in ("last_run", "last_full"):
                        st[k] = "X" if st.get(k) else st.get(k)
                    text = json.dumps(st, indent=1, sort_keys=True, ensure_ascii=False)
                for rx, rep in VOLATILE:
                    text = rx.sub(rep, text)
                out[ids(str(p.relative_to(root.parent)))] = ids(text.replace(str(root.parent), "<tmp>"))
    return out


def scenario(tmp_path, monkeypatch):
    world = World()
    work, conf = setup(tmp_path, monkeypatch, world)
    snaps = {}
    snaps["1_first_run_rc"] = run(monkeypatch)                      # no state: a full run
    snaps["1_first_run"] = tree(work, conf)
    # Incremental: the meeting changed, the users list fails, a task's markdown falls back to blocks.
    ids = world.ids
    world.ds["mds"][0]["last_edited_time"] = "2099-01-01T00:00:00.000Z"
    world.md[dashed(ids["M1"])] = "Edited agenda"
    world.ds["tds"][0]["last_edited_time"] = "2099-01-01T00:00:00.000Z"
    world.md_errors[dashed(ids["T1"])] = 404
    world.blocks[dashed(ids["T1"])] = [
        {"id": dashed(ids["B1"]), "type": "heading_2", "heading_2": {"rich_text": [{"plain_text": "Steps"}]}, "has_children": True},
        {"type": "to_do", "to_do": {"rich_text": [{"plain_text": "first"}], "checked": True}},
        {"type": "code", "code": {"rich_text": [{"plain_text": "x = 1"}], "language": "python"}},
        {"type": "divider", "divider": {}}, {"type": "child_database", "child_database": {"title": "DB"}},
        {"type": "image", "image": {"caption": [], "external": {"url": "https://img"}}},
        {"type": "table_row", "table_row": {"cells": [[{"plain_text": "a"}], [{"plain_text": "b"}]]}},
        {"type": "unsupported_x", "unsupported_x": {"rich_text": [{"plain_text": "other"}]}}]
    world.blocks[dashed(ids["B1"])] = [{"type": "bulleted_list_item", "bulleted_list_item": {"rich_text": [{"plain_text": "nested"}]}}]
    world.users_error = 403
    snaps["2_incremental_rc"] = run(monkeypatch)
    snaps["2_incremental"] = tree(work, conf)
    # Full: a task disappeared (archived), the current state page is gone (an error, PARTIAL).
    world.ds["tds"] = [r for r in world.ds["tds"] if r["id"] != dashed(ids["T2"])]
    del world.pages[dashed(ids["CS1"])]
    snaps["3_full_rc"] = run(monkeypatch, "--full")
    snaps["3_full"] = tree(work, conf)
    snaps["4_transcripts_rc"] = run(monkeypatch, "--transcripts")
    snaps["4_transcripts"] = tree(work, conf)
    snaps["calls"] = len(world.calls)
    return snaps


def test_mirror_golden(tmp_path, monkeypatch):
    got = scenario(tmp_path, monkeypatch)
    if os.environ.get("UPDATE_GOLDEN") or not GOLDEN.exists():
        GOLDEN.parent.mkdir(exist_ok=True)
        GOLDEN.write_text(json.dumps(got, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
        pytest.skip("golden written")
    want = json.loads(GOLDEN.read_text(encoding="utf-8"))
    assert got == want


def test_status_and_no_config(tmp_path, monkeypatch, capsys):
    world = World()
    work, conf = setup(tmp_path, monkeypatch, world)
    assert run(monkeypatch, "--status") == 0 and "no status yet" in capsys.readouterr().out
    run(monkeypatch)
    capsys.readouterr()
    assert run(monkeypatch, "--status") == 0 and "# Notion mirror status" in capsys.readouterr().out
    monkeypatch.setattr(mirror, "CONFIG_PATH", str(tmp_path / "missing.json"))
    with pytest.raises(SystemExit):
        run(monkeypatch)
