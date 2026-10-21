# LiveTips.app (work in progress)

Native macOS companion for the `live-tips` skill: records the call locally, transcribes it on
the Mac and asks a model for tips on events instead of polling. Status: **M0 spike**, nothing
here is a usable app yet.

The skill and the app are both supported and behave the same way. Behaviour lives in one
place, [`rules/`](rules/), which both read.

## Layout

| Path | What |
|---|---|
| `rules/` | shared rules: triggers and cue words, tip diet, priorities, call concept, ASR filters, JSON schemas, UI strings (en, uk) |
| `rules/generated/` | sections of the skill's `SKILL.md` generated from `rules/` (do not edit by hand) |
| `spikes/m0/` | M0 spike: event-driven model calls on top of live-transcriber files, real-time replay of recorded calls, latency and cost report |
| `tools/gen_skill_section.py` | regenerates the skill sections; `--check` fails when they are stale, `--compare SKILL.md` fails on drift |
| `tools/check_anonymized.py` | fails on user paths, keys, IDs, long dashes and terms from a private deny list |
| `Fixtures/` | synthetic demo call used by the tests |

## M0 spike

Measures whether direct, event-driven model calls reach the target: from the end of the
question to the tip on screen, median 5 s or less, p90 8 s or less.

```
cd spikes/m0
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest -q tests
cp config.example.json my.json        # set model ids, labels, name aliases, secrets file
.venv/bin/python -m livetips_m0.replay --config my.json --md /path/to/<stem>.md --out runs/r1
.venv/bin/python -m livetips_m0.report runs/r1 --calls-root /path/to/live
```

The replay feeds each transcript line at the moment the recorder wrote it (from
`<stem>.md.timing.jsonl`), so the real ASR lag is included. Keep `--speed 1` for latency numbers.
Outputs go to the run folder only: `<stem>.app.tips.jsonl`, `.app.llm.jsonl` (role, model,
tokens, cache reads and writes, cost, timings), `.app.timing.jsonl` (spans per event).

### Pipeline

1. Local cue detection on each final line (no model): name of the PM, question, second person,
   new requirement, commitment by the PM, frustration. Cue words are in `rules/triggers.yaml`.
2. Strong signals go straight to the `tip` role. Weaker ones go to `classify` (fast model) first.
3. The `tip` role streams JSON with `gist` first; the time the gist is complete is logged.
4. The diet runs in code: rate limit for non-red tips, no non-red tip while the PM speaks,
   one tip per topic. Invalid model output is never shown.
5. Prompt caching: rules, call header with brief, and the fact book are three cached system
   blocks; the transcript tail is the only volatile part.

### Providers

`livetips_m0/providers.py` keeps the model behind a small interface: Claude API (streaming,
prompt caching), any OpenAI-compatible server (for a local model; not measured yet), and a fake
provider for tests.

### Spending limit

`budget` in the config: a soft and a hard limit per call and a hard monthly cap kept in a small
local ledger. At the hard limit model tips stop and only the local layer runs.

## Privacy

Audio and voice prints never leave the Mac. Only text goes to the model API. Keys are read at
runtime (Keychain in the app, an environment variable or a secrets file in the spike) and are
never printed or logged.
