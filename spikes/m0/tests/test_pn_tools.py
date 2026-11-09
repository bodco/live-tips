"""0.9.6 Б2: the shared tools (pn_tools) and their stdio MCP server (pn_mcp) on a synthetic Orbit project."""
import io
import json
from pathlib import Path

from livetips_m0 import commitments as register
from livetips_m0 import pn_mcp, pn_tools

NOTES = """# Call notes: Orbit weekly
## Meeting notes
### TL;DR
The export is merged; the pilot starts November 10.
### Decisions
- [10:04:10] Export goes to production on Tuesday.
### Action items
- [10:06:29] **David Kim**: send the test accounts (due: Friday)
### Open questions
- [10:11:02] Data retention statement still needs legal approval.
## Summary
Export and pilot.
"""


def transcript(name, title, lines):
    return "# Live transcript: {}\n\n- Project: orbit\n- Start: {}\n\n{}\n".format(
        title, name[:10] + " 10:00:00", "\n".join(lines))


def orbit(tmp_path: Path) -> Path:
    root = tmp_path / "orbit"
    live = root / "live"
    live.mkdir(parents=True)
    # call 1 (oldest): only the transcript
    (live / "2026-10-29-1000-orbit-weekly.md").write_text(transcript("2026-10-29", "Orbit weekly", [
        "[10:00:01] Me (en): Morning, Emily.", "[10:00:09] Other [S1] (en): The export is late by a week.",
        "[10:00:20] Me (en): Mike will check the retry logic."]), encoding="utf-8")
    # call 2: the call picture in the tips file, its decision repeats in call 3
    c2 = live / "2026-11-02-1000-orbit-weekly.app.md"
    c2.write_text(transcript("2026-11-02", "Orbit weekly", ["[10:00:01] Me (en): Hi."]), encoding="utf-8")
    (live / "2026-11-02-1000-orbit-weekly.app.md.tips.jsonl").write_text(json.dumps({
        "kind": "situation", "decisions": ["Export goes to production on Tuesday", "Pilot uses the staging tenant"],
        "actions": [{"what": "Send the pilot plan", "due": "Nov 4"}],
        "theirs": [{"who": "Emily Carter", "what": "confirm the security review"}],
        "asks": [{"what": "Who signs the data retention statement?", "type": "question"}]}) + "\n", encoding="utf-8")
    # call 3 (newest): the meeting notes
    c3 = live / "2026-11-05-1000-orbit-weekly.md"
    c3.write_text(transcript("2026-11-05", "Orbit weekly", ["[10:00:01] Me (en): Hi all."]), encoding="utf-8")
    (live / "2026-11-05-1000-orbit-weekly.notes.md").write_text(NOTES, encoding="utf-8")
    # the register: one open, one done
    register.append(live, [
        {"op": "add", "id": "c-1", "text": "Send the pilot plan", "owner": "me", "call": c2.name, "created": "2026-11-02T10:30:00+02:00", "due": "Nov 4"},
        {"op": "add", "id": "c-2", "text": "Share the risk list", "owner": "me", "call": c3.name, "created": "2026-11-05T10:30:00+02:00", "due": ""},
        {"op": "add", "id": "c-3", "text": "Send the test accounts", "owner": "David Kim", "call": c3.name, "created": "2026-11-05T10:31:00+02:00", "due": "Friday"},
        {"op": "done", "id": "c-1", "at": "2026-11-04T09:00:00+02:00"}])
    (root / "pacenote").mkdir()
    (root / "pacenote" / "decisions.md").write_text(
        "# Active decisions\n\nSnapshot of the Notion Decisions register, taken 2026-11-03 08:00. Read by Pacenote; do not edit.\n\n"
        "- 2026-10-20 | Export goes to production on Tuesday | Mike Johnson | Delivery\n"
        "- 2026-10-15 | Weekly call moves to Wednesday (superseded) | Emily Carter | Process\n"
        "- 2026-10-10 | Retries after 1, 6 and 24 hours | Mike Johnson | Payments\n", encoding="utf-8")
    (root / "_notion").mkdir()
    (root / "_notion" / "current-state.md").write_text(
        "---\ntitle: \"Current State\"\nlast_edited: 2026-11-04T16:20:00.000Z\nmirrored: 2026-11-05T07:00:00Z\nproperties:\n"
        "  \"Status\": \"Green\"\n---\n\n# Current State\nPilot on November 10. Budget 42 hours left.\n", encoding="utf-8")
    return root


def test_past_calls_newest_first_with_dates_sources_and_no_repeats(tmp_path):
    root = orbit(tmp_path)
    out = pn_tools.past_calls(root, n=3)
    assert out.index("2026-11-05 10:00") < out.index("2026-11-02 10:00") < out.index("2026-10-29 10:00")
    assert "source: notes 2026-11-05-1000-orbit-weekly.notes.md" in out
    assert "source: call picture 2026-11-02-1000-orbit-weekly.app.md" in out
    assert "source: transcript 2026-10-29-1000-orbit-weekly.md" in out
    assert "- 2026-11-05 10:04 | decision | Export goes to production on Tuesday." in out
    assert "- 2026-11-05 10:06 | promise | David Kim: send the test accounts (due: Friday)" in out
    assert out.count("Export goes to production") == 1            # the newer call wins, the older repeat is dropped
    assert "Pilot uses the staging tenant" in out and "Emily Carter: confirm the security review" in out
    assert "Who signs the data retention statement?" in out
    assert "The export is late by a week." in out                 # no notes, no picture: transcript lines
    assert pn_tools.past_calls(root, n=1).count("CALL ") == 1


def test_past_calls_without_data(tmp_path):
    assert pn_tools.past_calls(tmp_path / "missing") == pn_tools.NO_DATA
    assert pn_tools.past_calls(tmp_path) == pn_tools.NO_DATA


def test_commitments_open_and_all(tmp_path):
    root = orbit(tmp_path)
    out = pn_tools.commitments(root)
    lines = out.splitlines()
    assert lines[0].startswith("Promises (open; source: live/commitments.jsonl")
    assert lines[1] == "- 2026-11-05 | open | David Kim | Send the test accounts | due Friday | call 2026-11-05-1000-orbit-weekly.md"
    assert "Share the risk list" in out and "Send the pilot plan" not in out
    full = pn_tools.commitments(root, open_only=False)
    assert "| done 2026-11-04 | me | Send the pilot plan | due Nov 4 |" in full
    assert pn_tools.commitments(tmp_path) == pn_tools.NO_DATA


def test_decisions_register_plus_later_calls_newer_wins(tmp_path):
    root = orbit(tmp_path)
    out = pn_tools.decisions(root)
    assert "register snapshot taken 2026-11-03 08:00" in out
    assert out.count("Export goes to production") == 1
    assert "- 2026-11-05 10:04 | Export goes to production on Tuesday. | - | - | notes " in out   # the newest copy
    assert "superseded" not in out
    assert "Retries after 1, 6 and 24 hours | Mike Johnson | Payments | register" in out
    assert "Pilot uses the staging tenant" not in out               # call 2 is older than the snapshot
    pay = pn_tools.decisions(root, area="payments")
    assert "Retries" in pay and "Export" not in pay
    assert pn_tools.decisions(tmp_path) == pn_tools.NO_DATA


def test_project_state_with_freshness(tmp_path):
    root = orbit(tmp_path)
    out = pn_tools.project_state(root)
    assert out.startswith("Project current state (source: _notion/current-state.md, edited in Notion 2026-11-04 16:20, copied 2026-11-05)")
    assert "Budget 42 hours left." in out and "properties:" not in out
    assert pn_tools.project_state(tmp_path) == pn_tools.NO_DATA


def test_tool_list_and_dispatch(tmp_path):
    root = orbit(tmp_path)
    assert pn_tools.NAMES[:4] == ["search_folders", "call_transcript", "brief", "past_calls"]
    prep = [t[0] for t in pn_tools.tools(live=False)]
    assert "call_transcript" not in prep and "brief" not in prep and "commitments" in prep
    ctx = pn_tools.FolderContext(str(root))
    assert "Send the test accounts" in pn_tools.call(ctx, "commitments", {})
    assert "Send the pilot plan" in pn_tools.call(ctx, "commitments", {"all": True})
    assert "Retries" in pn_tools.call(ctx, "decisions", {"area": "Payments"})
    assert pn_tools.call(ctx, "search_folders", {"query": "export"}).startswith("(the folder index is not available")
    for _n, _live, _d, sc in pn_tools.TOOLS:
        assert sc["type"] == "object" and "required" not in sc


def test_agent_tool_names_match_pn_tools():
    from livetips_m0 import agent as ag
    assert ag.TOOL_NAMES == ["mcp__pacenote__" + n for n in pn_tools.NAMES]


def test_engine_context_uses_the_shared_tools(tmp_path):
    from livetips_m0.engine import AgentContext
    root = orbit(tmp_path)

    class E:
        cfg = {"project_root": str(root)}
    ctx = AgentContext(E())
    assert ctx.commitments().startswith("Promises (open")
    assert "Export goes to production" in ctx.decisions()
    assert "Budget 42 hours" in ctx.project_state()
    assert "CALL 2026-11-05 10:00" in ctx.past_calls("")


def rpc(lines):
    out = io.StringIO()
    pn_mcp.serve(pn_tools.FolderContext(lines[0]), io.StringIO("\n".join(json.dumps(m) for m in lines[1:]) + "\n"), out)
    return [json.loads(x) for x in out.getvalue().splitlines()]


def test_mcp_server_lists_and_calls(tmp_path):
    root = orbit(tmp_path)
    r = rpc([str(root),
             {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
             {"jsonrpc": "2.0", "method": "notifications/initialized"},
             {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
             {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "commitments", "arguments": {}}},
             {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "brief", "arguments": {}}},
             {"jsonrpc": "2.0", "id": 5, "method": "nope"}])
    assert [x["id"] for x in r] == [1, 2, 3, 4, 5]                 # no answer to the notification
    assert r[0]["result"]["serverInfo"]["name"] == "pacenote" and r[0]["result"]["protocolVersion"] == "2025-06-18"
    names = [t["name"] for t in r[1]["result"]["tools"]]
    assert names == ["search_folders", "past_calls", "commitments", "decisions", "project_state"]
    assert all(t["annotations"]["readOnlyHint"] for t in r[1]["result"]["tools"])
    assert "Send the test accounts" in r[2]["result"]["content"][0]["text"] and r[2]["result"]["isError"] is False
    assert r[3]["result"]["isError"] is True                        # no brief tool in a preparation
    assert r[4]["error"]["code"] == -32601


def test_mcp_config_for_claude_p():
    c = pn_mcp.mcp_config("/venv/bin/python", "/p/orbit", ["/p/docs"], ["/venv/bin/python", "/bin/lt"], cwd="/app/spikes/m0")
    s = c["mcpServers"]["pacenote"]
    assert s["type"] == "stdio" and s["command"] == "/venv/bin/python"
    assert s["args"] == ["-m", "livetips_m0.pn_mcp", "--root", "/p/orbit", "--extra", "/p/docs", "--lt", "/venv/bin/python", "/bin/lt"]
    assert s["env"] == {"PYTHONPATH": "/app/spikes/m0"}


def test_mcp_server_as_a_process_answers_line_by_line(tmp_path):
    """As claude -p runs it: a child process, one request, wait for its answer, the next one."""
    import subprocess
    import sys
    root = orbit(tmp_path)
    here = str(Path(__file__).resolve().parents[1])
    p = subprocess.Popen([sys.executable, "-m", "livetips_m0.pn_mcp", "--root", str(root)], cwd=here,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        def ask(m):
            p.stdin.write(json.dumps(m) + "\n")
            p.stdin.flush()
            return json.loads(p.stdout.readline())
        assert ask({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})["result"]["protocolVersion"]
        out = ask({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "decisions", "arguments": {"area": "payments"}}})
        assert "Retries after 1, 6 and 24 hours" in out["result"]["content"][0]["text"]
    finally:
        p.stdin.close()
        p.wait(10)
    assert p.returncode == 0
