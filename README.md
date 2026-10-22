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

## Using Live Tips: start a call

1. Menu bar icon (or the Dock icon) > **Start call…**
2. **Project**: recordings, notes and the prep live in this project's folder. A workspace is for general calls about several projects.
3. **Title**: a short name of the call, e.g. "Weekly sync". It also links the call to its prep (see below), so keep the same title you gave the prep.
4. **Call context** (optional, strongly recommended): what the call is about and where to look, e.g. "pricing for phase 2, see the estimate and last week's notes". Before the call starts Claude gets this text, the project's current state (`_notion/current-state.md`) and the project files that local search finds for it.
5. **Audience**, **Meeting type**, **Microphone**, **Languages**, then **Start**.

### Prep made in Cowork

A prep is a brief, fact cards and, for a presentation, an outline and slides that Claude builds in Cowork from your project files, Notion and the tracker 10-30 minutes before the call. Tips are much better with it.

- **How to make one:** in Start call press **Copy request for Cowork** and paste it into Cowork in the same project. The request already names the call title, time and your context.
- **Where it lands:** `<project folder>/live/prep-<date>-<HHMM>-<title>.brief.md`, `.cards.json`, `.facts.json` (plus `.outline.json` and `.slides.json` for a presentation).
- **Which prep is used:** on Start the app takes `prep-*` files younger than 3 hours from that folder. Only a prep whose name matches the call title is used ("Weekly Sync" matches `...-weekly-sync`); a prep made for another call is never used, so its brief and internal facts cannot leak into the wrong meeting. Each file kind is taken separately, so a prep without slides still gives the brief and the facts.
- **How to check before Start:** the **Prep** block says "Prep found: <title>" in green when a prep matches the title. When the only fresh prep is for another call, it says so in orange and that prep is not used. In every state there is a button that copies the Cowork request for this call (title, time, project, call context), so the next prep can be made while an older one is still in the folder. The block rechecks the folder every 5 seconds and when the project or the title changes.
- **Without a prep:** the call still works. Claude uses the call context, the project's current state and local search, and the local layer (fact cards, the "❓" question cards, HELP NOW) runs as usual.

### FAQ

- **Do I need Cowork open during the call?** No. Live Tips calls the Claude API itself with your key from Keychain. Cowork is only needed for the prep and for the wrap-up you ask for later.
- **Can I change the microphone during the call?** Yes, in the tips window (Mic menu). "System default" follows macOS; choosing a device keeps it even if macOS switches.
- **What is Local AI?** A small model on this Mac (built-in bge-m3, or your Ollama) that matches facts and cards by meaning and powers HELP NOW and project search. Settings > AI explains the engines and how to add another one.
- **Which "❓" cards are shown?** Only for a line that names you and asks something, a line with a work word (estimate, deadline, status, price, release…), or a question about time or amount ("when…?", "how much…?"). Rule: `rules/triggers.yaml` > `question_card`.
- **What does it cost?** Usually $0.10 to $1.20 per hour of a call; the menu shows this call and this month against the limits from Settings.
- **Where are the files?** Transcript, tips and wrap-up data: `<project folder>/live/`. App logs: `<app folder>/logs/`.

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
