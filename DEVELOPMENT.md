# LiveTips.app (beta)

Native macOS companion for the `live-tips` skill: records the call locally, transcribes it on
the Mac and asks a model for tips on events instead of polling. Status: **beta** (Pacenote; the current version is in [CHANGELOG.md](CHANGELOG.md)), a
downloadable app (see Install below); the M0 spike that measured the approach is kept further down.

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
| `telemetry/` | the Cloudflare Worker and D1 schema behind the optional Help improve Pacenote (see Telemetry below) |
| `docs/` | the guide in English and Ukrainian (`docs/en`, `docs/uk`, kept in step) and the team design |

## Names

Pacenote is the product name since 0.8. Before that the product was called Live Tips, and the name is still
inside the code on purpose: renaming it would reset macOS permissions, move the users' files and break the skill.

| What says "live tips" | What it is | Why it stays |
|---|---|---|
| `live-tips` skill (`skill/`) | the Cowork skill that runs the same loop in a chat; Pacenote's other half | skill names are what people type and what other skills call |
| `LiveTips.app`, the `LiveTips` executable, `io.github.example.livetips` | the app's file, binary and bundle id | macOS ties the microphone and screen recording permissions to them |
| `LiveTipsCore`, `Sources/LiveTips/` | Swift module and folder names | internal only |
| `~/Library/Application Support/LiveTips`, `<work>/Tools/LiveTips`, `Library/Logs/LiveTips`, `.livetips-index/` | where settings, the recorder core, logs and the local search index live | moving them would lose the users' data; the skill reads the same folders |
| `livetips_m0` (Python), the prompts ("You are Live Tips, ...") | the tips engine and its model prompts | a prompt change is a behaviour change: it goes through `rules/`, not through a rename |
| `window.LiveTips`, the `liveTips` message handler | the bridge between Swift and the tips window | internal API name |
| `live-transcriber`, `recorder/` | the recorder the skill uses and the app copies | not changed without the owner |
| headings "Live Tips: ..." in older Notion pages | written before 0.8 | the app and the skill still recognise them |

Everything a person sees says Pacenote: the app name, the menu bar, windows, notifications, Notion pages and the site.

## The tips window (0.8)

`app/Resources/tips/`: `index.html`, `tokens.css` (the design tokens, the same values as `PacenoteTheme.swift`),
`tips.css`, `tips.js` (the window: hero card, Earlier, agenda, On me, transcript, brief, presentation, compact mode)
and `feed.js`. The recorder and the tips engine still write the item stream the skill's window reads
(`<stem>.app.tips.jsonl`), and the app still pushes it with `addItems`, `setStatus`, `addTranscript`, `setSpeakers`,
`setPrepDoc`, `setPrep`, `setUpNext`. `feed.js` turns that into the window's state (`LiveTips.setState`); it has no
DOM and is tested with `node app/WebTests/feed.test.js`. The window answers on one WebKit handler, `liveTips`,
with `{"action": ...}` (`PrompterController.handleAction`). Open `index.html` in a browser to see it on demo data:
`?state=ready`, `?state=empty`, `?theme=dark`, `?lang=uk`, `?mode=compact`, `?mode=presentation`, `?left=4`.

## Agenda, commitments, brief freshness (0.8)

Rules: `rules/agenda.yaml`, `rules/commitments.yaml`, `rules/freshness.json`; `tools/gen_skill_section.py` renders them
into `rules/generated/skill_register.md`, and the skill keeps that text in SKILL.md (`--compare` checks it). The
engine adds the agenda and the open commitments to the call picture (`livetips_m0/agenda.py`,
`livetips_m0/commitments.py`, Engine `_situation_extra_*`) and writes the register at the end of the call; the app
reads and ticks it (`LiveTipsCore/Commitments.swift`, `Register.swift`), checks the brief (`Freshness.swift`), runs a
Refresh (`PrepRunner`, `refreshBase`) and offers to start tips when a call begins (`AutoStart.swift`). The register is
one append-only file per project, `<project>/live/commitments.jsonl`, so a project's data never mixes with another's.

## After the call (0.8)

`livetips_m0/followup.py`, `memory.py`, `rehearse.py` and `risk_notion.py` are small command-line modules the app runs
through `PyTool.swift` (one JSON object out; the key and the Notion token go to the child only). Shared rules:
`rules/followup.yaml`, `rules/risks.yaml`, `rules/rehearsal.yaml`; the skill's copy is the SKILL.md section "Risks and
the follow-up email". Native windows: `CallPage.swift` (call page, transcript, follow-up), `Memory.swift` (call
memory, series), `Rehearsal.swift`; statistics in `HomeStats.swift` (`CallMetrics`).

## Install (beta)

1. Download the dmg from the release page:
   [Pacenote.dmg](https://github.com/bodco/live-tips/releases/latest/download/Pacenote.dmg).
   Open it and drag **Pacenote** into Applications.
2. **First open:** the beta is not notarized by Apple yet, so macOS blocks the first launch. Open
   **System Settings > Privacy & Security** and press **Open Anyway** (on macOS 14 a right-click >
   **Open** also works). After that it opens normally. Check the download first against
   `SHA256SUMS.txt` in the release: `shasum -a 256 ~/Downloads/Pacenote.dmg`.
3. The **Setup** window checks what is there and installs the rest: the Python modules, the speech
   model and the local AI model. Each step gets a tick when it is done. In total it is about
   2.5 GB, and nothing needs an administrator password.
4. Add your Claude API key in Settings > Keys (it is stored in Keychain) and check the spending limits in Settings > AI.

Requirements: macOS 14.4 or newer on Apple silicon, Python 3.10 or newer (Setup checks it and
says what to do when it is missing). Expect rough edges: this is a beta.

## Using Pacenote: start a call

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

### Standby: open the window before the call

**Recording starts: When the call begins** (in Start call) opens the tips window early, while you
wait for the others. Nothing is recorded and there are no microphone warnings yet. Recording
starts by itself when the other side has been speaking for about 5 seconds, or at once when you
press the green **Start** in the window. The red **End call** ends the call. The Cowork skill has
the same standby.

### Presentation: split view

With meeting type **Presentation** and a prep that has slides (`<stem>.slides.json`), the tips
window splits into 2 halves: slide cards with the full text of your speech, and the usual tips
stream.

- Cards scroll one slide at a time (snap); move with the arrows, the ◀ ▶ buttons or the wheel.
- A timer with a limit in minutes scales the time of each slide to fit. **Auto** turns the slides
  on schedule with a short signal and warns 10 s before the end of a slide. The pace line shows
  your words per minute.
- **Trim** hides the paragraphs marked as safe to skip. **My slides / All slides** switches between
  your part and the whole deck.
- Paragraph kinds: read aloud, may skip, a hint (not to be read), a colleague's line right before
  your part.
- At the end a table compares the plan with the actual time of every slide.
- 📑 hides or shows the cards, ⇄ swaps the 2 sides (remembered). The window grows towards the
  cards, so the tips stream stays where you put it.

### See-through window

In the tips window, ⚙ > Display > **Opacity** fades only the window background. The text stays fully opaque and
gets a soft halo in the background colour, so it stays readable over whatever is behind the
window, even at low opacity.

### FAQ

- **Do I need Cowork open during the call?** No. Pacenote calls the Claude API itself with your key from Keychain. Cowork is only needed for the prep and for the wrap-up you ask for later.
- **Can I change the microphone during the call?** Yes, in the tips window (Mic menu). "System default" follows macOS; choosing a device keeps it even if macOS switches.
- **What is Local AI?** A small model on this Mac (built-in bge-m3, or your Ollama) that matches facts and cards by meaning and powers HELP NOW and project search. Settings > AI explains the engines and how to add another one.
- **Which "❓" cards are shown?** Only for a line that names you and asks something, a line with a work word (estimate, deadline, status, price, release…), or a question about time or amount ("when…?", "how much…?"). Rule: `rules/triggers.yaml` > `question_card`.
- **What does it cost?** Usually $0.10 to $1.20 per hour of a call; the menu shows this call and this month against the limits from Settings.
- **Does it write to Notion?** Yes, if Settings > General > "Write the call summary to Notion" is on and the Notion token in Keys can see the project's Meetings DB. After the call it appends a "Live Tips" section (wrap-up and the transcript file) to this meeting's page, found by `Date` within 20 min of the start, or creates the page. Menu bar > "Send last call to Notion" does it later. Details: docs, section 14.2.
- **Can the app and the Cowork skill record the same call?** Yes. The app writes only `<call>.app.*` files with its own recorder, so nothing is shared; expect about twice the CPU. `livetips_m0.report` and `livetips_m0.judge` compare the two afterwards (docs, section 14.3).
- **Speakers?** As in the skill: the "Who is speaking?" card offers the project's people, names you give appear in tips and in the Notion summary and are remembered in `<app folder>/voices`. On or off: Settings > AI > Speakers.
- **Interviews?** Start call > Meeting type Interview > Your role: Observer (someone else interviews a candidate), Interviewer (you ask) or Coach (you are the one being interviewed). Tips follow the role, as in the skill.
- **A different model for one call?** Start call > Tip model. Settings > AI sets the default.
- **What if Claude is slow?** With "Second request when Claude is slow" on (Settings > AI), a request with no answer after 2 s (classify) or 3 s (tip), or one that fails at once, is sent again and the first good answer wins. Both are billed and counted in the limits.
- **Whose voices are remembered?** Your team's for every project, a client's for that project only, nobody's on a call marked Public call in Start call. Settings > AI > Speakers lists the library; Forget removes a person.
- **Notion mirror?** Settings > General > Notion mirror > Set up sync copies `notion-mirror/` to `<work>/Tools/notion-mirror`, finds your Control Tower databases with the Notion token and runs it every 2 hours outside calls. A mirror you already run yourself is left alone.
- **Shortcuts?** Control-Option-H is HELP NOW and Control-Option-P pauses tips, also while the meeting app has the focus. They are shown in the menu bar menu, on the HELP button and in Settings > General > Shortcuts.
- **Where are the files?** Transcript, tips and wrap-up data: `<project folder>/live/`. App logs: `<app folder>/logs/`.

## How tips are decided (0.5.1)

Local signals route a line (vocative name + request, second-person question, new request, the PM's commitment go straight to the tip model; a name in the third person never counts). The gist is shown first and the full tip replaces it. Before showing, the engine checks the tip is still open (the PM has not answered, the numbers were not said) and that every number exists in the brief, facts, cards or transcript. Presentation: keyword facts and question cards only on explicit questions. Details: docs, section 14.5.

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

The local layer (keyword and semantic facts, cards, the "❓" items; `recorder/src/transcriber.py`) has its own replay,
with the same classes, the thresholds from the app's `config.json` and the same embedding model:

```
<work>/Tools/LiveTips/.venv/bin/python tools/replay_local.py --md /path/to/<stem>.md --out /tmp/rl \
    --config <work>/Tools/LiveTips/config.json --embed-url http://127.0.0.1:11435 --compare
```

The replay clock replaces the wall clock, so cooldowns and the topic window behave as live. `--compare` lists what
showed live and not in the replay and the other way round, and the semantic decisions by reason
(`below threshold`, `not a question, topic not held`, `cooldown`). Run it on the Mac against the running engine:
`--model-dir` runs the int8 model in-process anywhere, but on another CPU its vectors differ slightly (cosine about
0.985), which moves the cases near a threshold. The same holds for batching: the model quantizes each request as a whole, so lines are embedded one per request, as live. The live `<stem>.semantic.npz` seeds the fact and card vectors.
The output holds call text: keep `--out` outside the repository.

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

## Meeting Sheet (0.10.0)

The preparation of every call type except Transcript builds a Meeting Sheet instead of a brief. User guide: docs,
section 14.1x. The design rules: every AI route is equal (the sources, access checks, size and readers are shared
and run before any model), nothing is cut silently, every fact has a source, a locator, a date and a status, the
PM's edits survive a refresh, Google uses no restricted scope.

**Layout.**

| Part | Where | What |
|---|---|---|
| Sidecar package | `spikes/m0/livetips_m0/sheet/` | `schema.py` (validator), `presets.py` (rules + the PM's presets), `readiness.py` (rules, auto questions, stale), `merge.py` (`protect_edits`), `sources.py` (link kinds, access, fix actions, Move to Sources, candidates with "why"), `readers.py` (pdf, pptx in `presentation.xml` order, xlsx, docx, csv, md, txt, html; stdlib only), `size.py` (tokens per script, windows, plans), `prompt.py` (one contract for all routes), `build.py` (passes, merge, conflicts, refresh diff, the report), `derive.py` (files for the live layer), `web.py` + `linkedin.py` (crawl plan, robots.txt, captured pages, the profile parser), `lookup.py` (the folder search during a call), `aftercheck.py` (questions and best outcome after the call) |
| Rules | `rules/meeting-sheet.yaml` | The block library (title, fields, `only_if_data`, which live file a block feeds), the presets (blocks, quick or expert, readiness rules), the readiness rules, settings (`stale_months: 6`, `remind_minutes: 30`, `default_mode` rules, auto questions), the qualification methods (names from `rules/sales.yaml`) |
| Windows | `rules/ai.yaml > windows` | Context window, output and reserve per route and model, from the providers' documentation; `pass_cap` 250,000 tokens per pass, `near_share` 0.8; unverified numbers are marked `unverified: true` |
| Swift models | `LiveTipsCore/MeetingSheet.swift`, `SheetPipeline.swift`, `MeetingSheetOps.swift`, `BrowserCapture.swift` | Codable models with tolerant enums (an unknown value round-trips), the pure logic of Quick/Expert, diff counts, edits, export, the browser's plan and contact scrubber |
| Runner | `LiveTips/SheetRunner.swift` | Starts the sidecar with the route's key in the child's environment only, mirrors progress into `PrepRunner.shared` (Up next, the tips window and the queue work unchanged), asks before switching routes (a queued run switches and writes `route_switch` into the report), ledger and usage lines. `PrepRunner.start` hands every call type except Transcript to it |
| UI | `LiveTips/MeetingSheet*.swift`, `UpcomingCallPage.swift`, `PacenoteBrowser.swift` | Quick and Expert (S1-S5), the sheet, readiness, sources, versions tabs, export (PDF through WKWebView), Settings > Meeting Sheet, the reminder, the Pacenote browser (non-persistent `WKWebsiteDataStore`) |
| Recorder | `recorder/src/transcriber.py` (`SheetLive`) | Reads `<stem>.sheet.json` directly: questions, Ask now, red lines, facts with source numbers, best outcome, slides, stand-up; drops the copies `derive.py` made from the same sheet |
| Custom presets | `<appRoot>/meeting-sheet/presets/*.yaml` | The PM's own presets; delete moves the file to `presets/_deleted/` |

**CLI.** `cd spikes/m0 && python -m livetips_m0.sheet <command> --request <request.json>` (or `--sheet <path>`).
Commands: `validate`, `readiness`, `presets`, `new`, `sources`, `candidates`, `size`, `build`, `refresh`, `derive`,
`export`, `webplan`, `webfetch`. Output is JSON on stdout; `build` and `refresh` print progress lines
(`{"progress": 0.4, "stage": "model", "pass": 1, "passes": 2}`) and end with `{"done": true, ...}` or
`{"error": ...}`. Exit codes: 0 ok, 1 invalid sheet, 2 unknown command, 3 bad input, 4 too much for one pass (choose
`plan: passes` or `compress`), 5 the model did not answer. A request (only `meeting` is required; invented names):

```json
{"meeting": {"title": "Lumenfield intro", "start": "2026-11-13T16:00:00+02:00", "event_id": "..."},
 "participants": {"ours": [{"name": "Mike Carter"}], "theirs": [{"name": "Emily Parker", "company": "Lumenfield"}]},
 "preset": "sales_intro", "blocks": ["header", "company", "qualification", "questions"], "method": "bant",
 "mode": "expert", "language": "en", "context": "free text; links in it come back as suggestions",
 "route": "code|api|codex|openai|gemini|agy|local", "plan": "one|passes|compress",
 "sources": [{"path": "~/deck.pptx", "deck": {"owners": {"2": "Jake T."}, "minutes": 20, "qa_minutes": 5}},
             {"uri": "https://docs.google.com/document/d/<id>/edit"}, {"type": "linkedin_manual", "text": "..."}],
 "google": {"connected": true, "copies": {"<id>": "<live/google/...md>"}}, "notion": {"connected": false},
 "project": {"slug": "lumenfield", "root": "~/work/..."}, "base": "<root>/live/prep-2026-11-13-1600-lumenfield-intro"}
```

**Files of a call** (`<base>` = `prep-<yyyy-MM-dd-HHmm>-<slug>` in `<project>/live/`, so the live layer finds them by
name as before): `<base>.sheet.json` (the sheet), `<base>.sheet.md` (a readable copy), `<base>.sheet.v<N>.json`
(versions), `<base>.sheet.sources.json` (the report: per source used / reason / access / facts citing it, passes,
failures, tokens, cost, time), `<base>.sheet.request.json`. Text copies for Claude go to `live/.sheet-cache/<base>/`;
pages from the Pacenote browser to `live/sources/`. After a call: `<stem>.sheet-live.json` (questions asked) and
`<stem>.sheet-check.json`.

**Schema v1** (`"schema": "pacenote.sheet/1"`): `sheet` {id, title, meeting_ref, mode quick|expert, preset, language,
route, project, call_type, audience, participants, goal, blocks[], sources[], size_report, readiness, versions[],
built_at, refreshed_at, diff}; `block` {id, type, title, visible, only_if_data, order, method, facts[],
edited_by_user}; `fact` {id, label, text, source_ids[], locator {quote, line, page, url, slide, cell}, checked_at,
status found|not_found|needs_check|conflict|stale|edited, conflict_with[], origin model|user|readiness, value {level,
key, owner, due}, diff}; `source` {id, n, type, uri|path, title, size_tokens, chars, access ok|denied|unsupported|
pending, access_reason, fix_action, used full|summarized|truncated|skipped|not_used, reason, pass, auto, why[], deck,
modified_at}; `gap` {id, rule, text, block, fact, action add_question|find_again|mark_checked|drop_check|
assign_owner|add_source, severity blocker|warning}. Unknown keys are allowed; `schema.validate` checks types, enums,
unique ids, references and that a model fact marked found has a source and a date. The Swift models mirror it
(`meeting_ref.where` is `place` in Swift).

**Conflicts and stale facts.** Only attribute blocks (company, contact, tech stack, project context, qualification,
interview candidate, signals, header, fit) can conflict: the same label, different values, different sources. When
both sources are dated and differ, the newer wins (`found`) and the older is `stale` with `conflict_with` (shown as
"was X"); `conflict` remains when the dates are equal or unknown. A source's date is the date in its file name, else
its modification time. A fact is `stale` when all its dated sources are older than `stale_months`. `edited` and
`user` facts never go stale and are never replaced (`merge.protect_edits`).

**Derive, the fallback for live.** `derive.py` writes from the sheet `<base>.brief.md` (a generated readable copy,
first line `# Live Brief: ... Meeting Sheet`), `<base>.cards.json`, `.facts.json`, `.agenda.json` and, for a deck
source, `.slides.json`, so the recorder and the engine work with or without `SheetLive`. Derived cards and facts
carry `sheet_fact` (or `"sheet": true`); the recorder drops them when it reads the sheet itself, so nothing shows
twice. Without a `.sheet.json` the live layer behaves exactly as in 0.9.7 (golden replays unchanged).

**Tests.**

```
cd spikes/m0 && .venv/bin/python -m pytest -q tests -k sheet     # schema, presets, readiness, pipeline, web, live
cd app && swift build && swift run CoreChecks                      # meetingSheet0100, sheetPipeline0100,
                                                                   # meetingSheetUI0100, browserCapture0100
node app/WebTests/feed.test.js                                    # the sheet's questions in the tips window
```

Fixtures are invented only (`spikes/m0/tests/fixtures/sheet/`: Lumenfield, Orbit; people Emily Parker, Mike Carter,
Sarah M., Jake T.); never real leads. `tools/check_anonymized.py` and the em dash test run in the full pytest suite.
The web tests run a local `http.server` with its own robots.txt; never test against other people's profiles.

## Call recording (0.9.5)

`LiveTipsCore/RecordingCore.swift`: the settings (`AppConfig.recording`), the quality presets and their size an hour,
the file names (`<project>/video/<stem>.recording[-N].mp4|m4a`, `<stem>.recording.json`) and how the call's window is
found (`MeetingWindow`); `CoreChecks` covers them. `LiveTips/CallRecorder.swift`: ScreenCaptureKit (a display without
Pacenote's windows, or one window) and an AVCaptureSession for the microphone, both sounds mixed by their timestamps
into one AAC track, AVAssetWriter with 10 s fragments; pause keeps one file, stop and start make parts. Started by
`CallEngine.startCallRecording` (the request's `recording`) and by the tips window (`{"action": "rec"}`), stopped with
the call and before the app quits. `RecordingPicker.swift` (the window list), `RecordingSettingsPane.swift` (Settings
> Call recording), `RecordingRow.swift` (the call page), `DriveRecordings.swift` (resumable upload, `drive.file`, the
queue in UserDefaults). The recorder (`recorder/`) is not involved: the transcript works as before.

Sizes on this Mac: `"/Applications/Pacenote.app/Contents/MacOS/LiveTips" --rec-bench /tmp/rb 15` (better through
`open -n Pacenote.app --args --rec-bench /tmp/rb 15`, so the app's Screen Recording permission applies) records the main
screen with every preset and format and writes `bench.json`.

## Privacy

Audio and voice prints never leave the Mac, and a call recording leaves it only to the PM's own Google Drive when the
PM uploads it. Only text goes to the model API. Keys are read at
runtime (Keychain in the app, an environment variable or a secrets file in the spike) and are
never printed or logged.

## Screenshots for the website

The pictures on the Pacenote pages are made by the app itself, on demo data:

```bash
"/Applications/Pacenote.app/Contents/MacOS/LiveTips" --shots ~/Desktop/livetips-shots
```

It writes the demo projects (Orbit SaaS Launch, Internal Delivery Playbook in the Northwind Studio
workspace) and demo voices to `/Users/Shared/LiveTipsDemo`, never reads your own projects or the
Keychain, opens Start call, Start call in plan mode during a (faked) live call (`plan-call`), Home on demo calendars and demo transcripts (`home`), Settings (General, Notion, AI, Projects), the tips window and the
presentation mode, and saves each as `<name>-dark.png` and `<name>-light.png` at 2x. Convert them to
WebP and put them in the website's `public/live-tips/shots/`. Run it again after every visible change
in the app, so the site always shows the current windows.

## Learning from corrections (0.9.3, 0.9.4)

The app and the skill learn from what you change and from how you rate tips. The rules are in `rules/learning.yaml`; they
are implemented twice, in Python (`spikes/m0/livetips_m0/learning.py`) and in Swift (`LiveTipsCore/Learning.swift`), and
the same input must give the same standing lessons in both. That is pinned by one shared fixture,
`rules/fixtures/learning-patterns.json`:

- `records`: the corrections log lines of several invented calls (`followup_instruction`, `brief_edit`,
  `card_onme_remove`, `tip_rating` with `tip_partly` or `tip_not_useful` and a reason chip), each with a file and a series;
- `expect`: the standing patterns that must come out (`kind`, `text`, `calls`). A pattern is standing when it repeats on
  two or more different calls (`calls: 2`); a rating on one call stays with that call.

Both suites read the fixture: `spikes/m0/tests/test_learning.py` (pytest) and the `CoreChecks` target of the Swift package
(`app/`, `swift run CoreChecks`). To change a rule, change `learning.yaml`, both implementations and the fixture in one
commit and run both suites. The log is `edits.jsonl`, schema 2: each line also carries `surface` (live, preparation,
after the call, speakers), `meeting_type`, `route` (the way to the AI of the job), `app_version` and `rules_version`.
The tips of a new call get the standing lessons as `tip_lessons` (`edits_log`), a preparation gets them through
`EditLog.promptBlock`. Use invented American names in the fixture, as everywhere in the repository.

## Telemetry (0.9.4, Help improve Pacenote)

Off by default. When a person turns it on (Settings > General > Privacy, needs the usage log on), the app sends the lines of
its usage log once a week (checked at launch and every 6 hours), complete days only, never days from before it was turned
on, with one random install id per Mac (made when sharing is turned on, kept until it is turned off). Never call text,
comments, names, projects, files, titles or emails. Show what is sent writes the next batch to `usage/next-batch.json`.

| Where | What |
|---|---|
| `rules/usage.yaml > telemetry` | the setting, the endpoint, the schedule and the list of what is never sent; the events and their parameters are in the same file |
| `LiveTipsCore/Telemetry.swift`, `LiveTips/TelemetrySender.swift`, `UsageLog.swift`, `SettingsView.swift` | building the batch, sending it, the usage log, the switch and Show what is sent (`CoreChecks` covers the batch) |
| `telemetry/worker.js` | the Cloudflare Worker `pacenote-telemetry`: `POST /v1/batch`, `GET /v1/health` |
| `telemetry/schema.sql` | the D1 tables: `batches` (one row per batch, the hour of arrival, the payload) and `event_counts` (the same events summed per day, event, parameters and version) |
| `telemetry/README.md`, `telemetry/wrangler.toml` | the short description and the deploy config |

**What `validate` in `worker.js` checks again on the server.** The header is schema 1 with an install id (hex digits and
dashes, 8 to 40 characters); `app_version`, `rules_version` and `ui_lang` are short plain strings; `from` and `to` are days
(`YYYY-MM-DD`); at most 20,000 events, each with a lower-case snake_case name of up to 40 characters, a day and flat
parameters (strings up to 80 characters, numbers, booleans: anything nested or longer refuses the whole batch with 400);
route names are checked the same way. A body over 256 KB gets 413, and an install may send 3 batches a day at most
(429). The Worker stores the hour of arrival, never an IP address or a user agent. `validate` has no automated test yet:
after changing it, try a good and a bad batch against a local `wrangler dev`.

**Deploy.** From a Mac where `wrangler` is signed in: `npx wrangler deploy` with a config that has the real D1 id. The
`wrangler.toml` in this repository carries a placeholder instead of the id on purpose: `tools/check_anonymized.py` rejects
UUIDs, so the working config (a copy with the real `database_id` and `main` pointing at `telemetry/worker.js`) is kept
outside git. A new database gets its tables from `schema.sql` (`wrangler d1 execute`). The endpoint address is in
`rules/usage.yaml`; a custom domain instead of `workers.dev` would be a change there and in the Worker's routes.

**Looking at the data.** Cloudflare dashboard > Storage and databases > D1 > `pacenote-telemetry` > Console, for example
`SELECT event, params, SUM(n) FROM event_counts GROUP BY 1, 2`. One test row from the first check (install id of zeros,
version `0.9.4-test`) is still there; delete it only with the owner's agreement.

## The website (pacenote.bodco.pm)

The site is separate from PM Control Tower, the author's other project, and has no source in this repository. Its pages
are part of the PM Control Tower website source (github.com/bodco/tower.bodco.pm, Astro 5): the content in
`src/content/pages/{en,uk}/pacenote*.md` (the product page, `-details`, `-pricing`, `-compare`, `-privacy`, `-terms`)
and `changelog.md`, the routes in `src/pages/pacenote/` and `src/pages/uk/pacenote/`. One source gives two builds:

| Build | What it makes |
|---|---|
| `npm run build` | the PM Control Tower site; `/pacenote/*` there are redirects to pacenote.bodco.pm (`scripts/pacenote-redirects.mjs`, `src/data/pacenote-domain.json` with `"live": true`) |
| `npm run build:pacenote` | `PACENOTE_KEEP=1 astro build`, then `scripts/csp.mjs`, then `scripts/pacenote-site.mjs dist dist-pacenote`: the standalone Pacenote site |

`dist-pacenote/` is the built site and nothing else. It is copied into github.com/bodco/pacenote.bodco.pm (built files
only, never edited by hand) and served by GitHub Pages from `main` under the custom domain (`CNAME`, a DNS record
`pacenote` pointing at `bodco.github.io`). Publishing happens only on the owner's command, together with a release.

What makes it its own site:

- `src/components/PacenoteHeader.astro` and `PacenoteFooter.astro`. `Base.astro` renders them for `brand="pacenote"` instead
  of the PM Control Tower header and footer. The header has Overview, How it works, Pricing, Compare, the language and
  theme switches, GitHub and Download. The footer has the product pages, the downloads, `CHANGELOG.md` and the guide on
  GitHub, the privacy policy and terms of this site, Analytics settings, and "Also by bodco: PM Control Tower".
- `Base.astro` with `brand="pacenote"` also sets the accent, the favicon, the title suffix, the share image and the
  breadcrumbs and JSON-LD that point at Pacenote; `Feature.astro` makes the breadcrumbs "Pacenote / page".
- `src/pages/pn404/[v].astro` is the 404 page. It is built only with `PACENOTE_KEEP=1`, so the PM Control Tower build
  has no such page; `pacenote-site.mjs` writes it as `404.html`.
- `scripts/pacenote-site.mjs` copies the six pages (`SUBS`: the home, `details`, `pricing`, `compare`, `privacy`,
  `terms`) in both languages, the assets, Pacenote's own `favicon.svg`, `favicon-32.png` and `apple-touch-icon.png`, and
  writes `site.webmanifest` for Pacenote. It rewrites the links (everything outside `/pacenote/` goes to
  https://tower.bodco.pm, `/pacenote/x/` becomes `/x/`, also in canonical, hreflang and og:url), writes `sitemap.xml` with
  hreflang, `robots.txt`, `CNAME`, `.nojekyll` and the README of the site repository (the text is in this script), and
  `csp.mjs` recomputes the Content-Security-Policy.
- The version lives in `src/data/pacenote-version.json`, the `v:` fact of the details and compare pages, the "Version"
  fact of the product page and the "New in" list there; every release adds a row to `changelog.md` (English and Ukrainian).

Before publishing: `npm run check:text` (fails on a long dash, on the numbers 11 to 22 written as words and on words
from the local `.private-words`), `npm run build:pacenote`, a look at `dist-pacenote` (`python3 -m http.server 8765
--directory dist-pacenote`, then http://127.0.0.1:8765/, English and Ukrainian, light and dark, a narrow window), and
`npm run build` compared before and after: every file outside `/pacenote/` must stay the same, except `lastmod` in the
sitemap. The privacy policy and terms of the app (`PRIVACY.md`, `TERMS.md` and the Ukrainian files) are the short
versions of the site's pages and are compared with them at every release; the section about the website itself exists
only on the site.

## Quality gates (ub-mode)

Since 0.8.3 the code is held to [ub-mode](https://github.com/unclebob/ub-mode): every function under CRAP 10
([crapper](https://github.com/unclebob/crapper)), no duplicated structure scoring 0.8 or more
([dryer](https://github.com/unclebob/dryer)), and mutation testing of each changed file
([mutator](https://github.com/unclebob/mutator)). The tools need Python 3.11+. Run them from the folder you
analyze; their output goes to `.metrics/` (ignored by git):

```bash
cd spikes/m0
~/work/Tools/crapper/crapper --coverage-command 'python -m coverage run -m pytest -q tests && python -m coverage lcov -o target/coverage/python/lcov.info'
~/work/Tools/dryer/dryer --threshold 0.8
~/work/Tools/mutator/mutator --use-existing-coverage --test-command 'python -m pytest -q -x tests/test_routing.py' livetips_m0/routing.py
```

The tools cover Python and TypeScript. The Swift app and the tips window's JavaScript are not covered by
them; they keep their own checks (`CoreChecks`, `app/WebTests`).

Baseline on 2026-10-28, worst first, is the work list: the tips engine (`spikes/m0`) has 299 functions, 100
of them at CRAP 10 or more (the largest: `Engine._run_situation`, `Engine._run_tip`, `live.run`); the recorder
(`recorder/src`) has 267 functions, 50 with complexity 10 or more (`transcriber.main` is the largest) and one
duplicate pair; `routing.py` is done. Each change brings the functions it touches under the gate.

Status on 2026-10-29 (0.8.4): every function of the shipped engine (`spikes/m0/livetips_m0`) is under CRAP 10;
what is left over the gate are the developer bench scripts (`asr_bench`, `embed_bench`, `embed_equiv`,
`semantic_eval`, `skill_baseline`, `report`), which the app never runs. dryer finds no duplicate
pair at 0.8. The Notion mirror (`notion-mirror/`, the same file as `tools/notion-mirror` in pm-control-tower),
`tools/` and `keepalive/` have tests of their own and are under the gate (the mirror's own `--selftest` is left
as it is). The recorder (`recorder/`) is not changed without the owner, so its numbers stay as above.
How the behaviour is pinned before a split: `tests/test_golden.py` replays a synthetic call through the engine in
9 configurations and compares every output file; `notion-mirror/tests/test_mirror_golden.py` runs the mirror
four times against a fake Notion and compares the written tree.

