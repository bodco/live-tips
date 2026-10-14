# live-tips-keepalive

[Українською](README.uk.md)

A tiny Cowork plugin for the `live-tips` skill. Tips exist only while Claude's turn runs; if
Claude ends its turn with a text answer during a call, nobody reads the transcript and the
tips window falls silent. This plugin adds a **Stop hook**: while a call is being recorded,
Claude cannot end its turn and goes straight back to the live loop.

## How it works

- At the start of a recording the skill writes a marker `$HOME/.live-tips/keepalive.json` in
  the session's own environment: `until` (start + `tips.hard_cap_minutes` + 30 min), the
  call title, the state file, `max_blocks` (400).
- `hooks/keepalive.py` runs on every Stop event. With a valid marker it answers
  `{"decision": "block", "reason": "... go back to the read_delta loop ..."}` and counts the
  block in the marker (`blocks`).
- After the wrap-up and the Meetings DB page the skill reports `blocks` and removes the
  marker; the turn then ends normally.
- **Fails open:** no marker, a broken marker, an expired marker or more than `max_blocks`
  blocks and the hook does nothing. The stop button in Cowork works as usual.

## Install

Zip the folder (with `.claude-plugin/` and `hooks/` at the top level) into
`live-tips-keepalive.plugin` and install it in Cowork as a plugin. Needs `python3` in the
session environment.

## Check

During a test call ask in the chat: "show `~/.live-tips/keepalive.json`". Then ask for a
short text answer that ends the turn: with the plugin the session keeps polling and `blocks`
grows.
