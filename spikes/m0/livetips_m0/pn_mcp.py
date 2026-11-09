"""Pacenote's shared tools as a stdio MCP server (0.9.6 Б2), for a preparation through the Claude account:
`claude -p --mcp-config <file>` with mcp_config(...) below. Read-only: past_calls, commitments, decisions,
project_state and search_folders (pn_tools.tools(live=False); the call transcript and the brief exist only during
a call). The folders come as arguments; nothing is read outside them, nothing is written, no network.

No dependencies on purpose (the dev venv is Python 3.9, the `mcp` package needs 3.10): newline-delimited JSON-RPC
2.0 on stdin/stdout with initialize, ping, tools/list and tools/call, the subset Claude Code uses.

  python -m livetips_m0.pn_mcp --root <project folder> [--extra <folder> ...] [--lt <python> <lt>]
"""
import argparse
import json
import sys
from typing import Optional

from . import pn_tools

NAME = "pacenote"
VERSION = "1.1.0"
PROTOCOL = "2025-06-18"
TEXT_MAX = 12000


def tool_list() -> list:
    return [{"name": n, "description": d, "inputSchema": sc, "annotations": {"readOnlyHint": True}}
            for n, _live, d, sc in pn_tools.tools(live=False)]


def handle(ctx, msg: dict) -> Optional[dict]:
    """One request -> its response (None for a notification)."""
    mid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
    if mid is None:
        return None                                   # notifications/initialized and the like
    ok = lambda r: {"jsonrpc": "2.0", "id": mid, "result": r}  # noqa: E731
    if method == "initialize":
        return ok({"protocolVersion": params.get("protocolVersion") or PROTOCOL,
                   "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": NAME, "version": VERSION}})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": tool_list()})
    if method == "tools/call":
        name = str(params.get("name") or "")
        if name not in [t["name"] for t in tool_list()]:
            return ok({"content": [{"type": "text", "text": "unknown tool: " + name[:60]}], "isError": True})
        try:
            text = pn_tools.call(ctx, name, params.get("arguments") or {}) or "(nothing found)"
        except Exception as e:  # noqa: BLE001  (a tool error is a result the model can read)
            return ok({"content": [{"type": "text", "text": "the tool failed: " + type(e).__name__}], "isError": True})
        if len(text) > TEXT_MAX:
            text = text[:TEXT_MAX] + "\n[... cut]"
        return ok({"content": [{"type": "text", "text": text}], "isError": False})
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found: " + str(method)[:60]}}


def serve(ctx, inp=None, out=None) -> None:
    inp, out = inp or sys.stdin, out or sys.stdout
    for line in iter(inp.readline, ""):          # one line at a time: Claude Code waits for each answer
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}
        else:
            resp = handle(ctx, msg) if isinstance(msg, dict) else None
        if resp is not None:
            out.write(json.dumps(resp, ensure_ascii=False) + "\n")
            out.flush()


def mcp_config(python: str, root: str, extra=(), lt=None, cwd: Optional[str] = None) -> dict:
    """The --mcp-config JSON for `claude -p` (the preparation, Б3): this server under the name "pacenote", so its
    tools are mcp__pacenote__past_calls and so on. cwd = the spikes/m0 folder (the package's parent)."""
    args = ["-m", "livetips_m0.pn_mcp", "--root", root]
    for d in extra or []:
        args += ["--extra", d]
    if lt:
        args += ["--lt"] + list(lt)
    srv = {"type": "stdio", "command": python, "args": args}
    if cwd:
        srv["env"] = {"PYTHONPATH": cwd}
    return {"mcpServers": {NAME: srv}}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="")
    ap.add_argument("--extra", action="append", default=[])
    ap.add_argument("--lt", nargs=2)
    a = ap.parse_args(argv)
    serve(pn_tools.FolderContext(a.root, a.extra, list(a.lt) if a.lt else None))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
