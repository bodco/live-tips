# Pacenote

**Your co-driver on calls.** [Українською](README.uk.md) · [Site](https://pacenote.bodco.pm/)

Pacenote prepares a Meeting Sheet before the call, gives quiet, precise tips during it, and writes
the notes after. You keep the wheel. It listens to your call on your Mac and speaks up only when a fact or a phrase is needed:
a question to you, your turn, a new request, a date you are about to promise. Audio is transcribed
on the Mac and never leaves it; only text goes to your chosen AI provider. After the call the summary, decisions and
action items are written to your project folder next to the transcript, and to Notion when you connect it.

Beta, built by one project manager for his own calls. The new name changes what you see; the repository,
the `live-tips` skill, the `LiveTips.app` file, folders and settings keep their names, so calls, folders and
permissions carry over. What "live tips" means inside the code: [DEVELOPMENT.md](DEVELOPMENT.md#names).

## Two ways to run it

| | The app | The skill |
|---|---|---|
| What | A native macOS menu bar app | A Claude Cowork skill |
| You need | Apple Silicon Mac, macOS 14.4+; for preparation any AI way: a Claude plan or API key, a ChatGPT account through Codex CLI, an OpenAI or Gemini API key, a Gemini account or a local model | Claude Cowork with a computer linked, the recorder from this repo |
| Tips come from | Claude, OpenAI or Gemini API, called on events | Claude in your Cowork chat |
| Download | [Pacenote.dmg](https://github.com/bodco/live-tips/releases/latest/download/Pacenote.dmg) | [live-tips.skill](https://github.com/bodco/live-tips/releases/latest/download/live-tips.skill) |

Both share the same rules (`rules/`) and the same recorder, so tips behave the same way.

### Before you install the app

- **First open.** This beta is signed by its developer but not notarized by Apple yet. macOS blocks the first launch:
  double-click Pacenote, close the warning, then System Settings > Privacy & Security > **Open Anyway**. A new version
  you download may ask again. The DMG has the same steps in "Read me first".
- **Claude.** Recording, the transcript and the voices work on the Mac without Claude. Preparing calls (the Meeting
  Sheet) can use a **ChatGPT account through Codex CLI** (see below), or **Claude Code**, which the app installs for you (onboarding, or Settings > About >
  Components), and one way to pay: a Claude Pro, Max, Team or Enterprise plan, or an API key in Settings > AI. The
  free Claude plan does not include Claude Code. Claude Cowork is not needed for the app.
- **Your documents.** Plain project folders are enough: preparation reads Markdown, text, Word, PDF, PowerPoint, Excel and CSV files; the
  search during the call covers Markdown, text, CSV and JSON.

## What it does

- **Before the call (Meeting Sheet, beta):** Get ready builds a Meeting Sheet from the sources you add and see before the run (files, links, Google, Notion, LinkedIn, web pages, the project folder, earlier calls): every fact with its source and date, "Not found" instead of a guess, a readiness check with quick fixes, your edits kept on Refresh, export to PDF, Google Doc, Notion, Word or Markdown with the sources. Quick for a regular series, Expert for a new lead. Optional: without it the call still gets tips when you are addressed, HELP NOW and answers to your questions; a late preparation joins the call when it is ready.
- **During the call:** a small window with tips from your own facts, your update when it is your turn, a ready sentence on HELP NOW, a live transcript, a picture of the call (topic, what is on you).
- **Home and your calendars:** the calls ahead from several Google and Microsoft calendars (through macOS, nothing to install), overlaps marked so you pick the one you join; regular meetings start from their last setup; recent calls with Notion, transcript and folder.
- **Back-to-back calls (Up next):** plan and prepare the next calls while one is live, then switch with one question: the current call ends properly and the next starts with its preparation.
- **Call recording (optional):** the sound, or the sound and the screen (a whole screen or the call's window), saved on your Mac for watching a call again, for example to read the other side's reactions; start, pause and stop it in the call window, or record every call. Upload to your own Google Drive by a click or after every call, to share it.
- **Any language in, one language out:** set the call to one language and every speaker is written in it (Ukrainian on an English call comes out in English).
- **After the call:** full call notes in the project folder after every call, with or without Notion; with Notion connected, also a Notion page in the call's language (summary, decisions, our commitments, new requests, open questions, risks, action items) with the whole transcript as a sub-page. A follow-up email is only a draft: nothing is sent to clients by itself.

How it compares with Fireflies and Fathom (price, recording, live help, preparation, summary, CRM, data): [Pacenote vs Fireflies vs Fathom](https://pacenote.bodco.pm/compare/).

## Claude, ChatGPT or Gemini

Settings > AI has three tabs: Claude (Claude account, Claude API), ChatGPT and Gemini. Each job (preparation, live tips, after the call) picks its own way and model. OpenAI has two separate options:

- **ChatGPT account (Codex):** install the official [Codex CLI](https://learn.chatgpt.com/docs/cli), press
  **Log in**, finish the browser sign-in, then return to Pacenote. The account row checks the sign-in again.
  Select this route for preparation, live tips and/or after-call jobs. Onboarding also has **Use ChatGPT** for
  all three jobs. Codex uses its default model and your account's Codex limits. API-key sign-in is rejected for
  this route; Pacenote never reads or copies the CLI's OAuth credentials.
- **OpenAI API:** save an API key in macOS Keychain and select it for preparation (0.9.0), live tips and/or
  after-call work. Each job has its own OpenAI model in Settings > AI (defaults: GPT-6 Luna during the call, like Haiku; GPT-6.1 Sol for preparation and after the call, like Sonnet), through streaming Responses with `store: false`. Tokens and estimated cost count toward
  the existing ledger and live-call limits.

Codex preparation uses a text context pack built by Pacenote (call context, added files, project config,
local Notion mirror, earlier calls and digest), and Pacenote writes the brief, speech, cards and facts. The
model has no shell, MCP, web search or subagents. Each Codex job's session log is removed by its id right after Pacenote reads its usage limits; jobs may start slower than direct
API requests; API spending caps do not measure your account-plan usage. Plan-limit and sign-in failures are
shown without switching providers. Prepared cards and local project search remain available, while Claude
Code's deep folder lookup is disabled for OpenAI/Codex live tips. Failed or incomplete answers are errors.

**Gemini (0.9.3).** Two ways, both in Settings > AI > Gemini:

- **Gemini API:** a key from aistudio.google.com/apikey of a project with billing turned on, because Google may use
  free-tier content to improve its products and does not use paid-tier content. Three models, one per job:
  Gemini 3.5 Flash-Lite (tips), Gemini 3.8 Flash (preparation and after the call) and Gemini 4 Argon. The classic
  streaming API is used: no stored interactions, no tools, no files.
- **Gemini account (Antigravity CLI, `agy`):** the preparation and the work after the call only, never tips during a
  call (a request takes 20-30 seconds). Your Google plan pays, no API key. Each request runs in an empty folder with
  no file, shell or write access, and Pacenote removes agy's own copy of the conversation afterwards. Choosing it
  shows a red warning: Google's Antigravity terms forbid use through third-party software (the account may be
  suspended) and let Google use and review the conversations, and turning the CLI's telemetry off does not stop
  that storage.

**Plan B.** Settings > AI > Automatic switching > "Use Gemini when Claude or ChatGPT is out" (off by default) sends a
job to Gemini when the chosen way has no credit, hits its plan limit or has a bad key. The text of the call then
reaches Google.

**Cost.** Settings > Usage shows the spend by stage and by model for every provider with an API key. On the OpenAI API
the blocks reused during a call carry explicit cache breakpoints. Measured prices and model quality (about $13 a
month for 10 calls on Claude, about $7 on OpenAI or Gemini, prices as of 4 November 2026):
[pacenote.bodco.pm/pricing](https://pacenote.bodco.pm/pricing/).

## For teams (design)

What if project knowledge lived in one place, several people (PMs, sales) each prepared for their own
calls, and every summary landed in one place? Today that works with Google Drive and Notion and no
server; a team server with users, roles and CRM connectors (HubSpot and a custom CRM) is designed but
not built: [docs/team](docs/team/README.md).

## Repository

| Path | What |
|---|---|
| `app/` | The macOS app (Swift) |
| `recorder/` | The recorder: audio capture, local Whisper transcription, speakers, the tips window |
| `skill/` | The Cowork skill: `SKILL.md`, `references/`, `settings.yaml` |
| `spikes/m0/` | The tips engine (Python) and its tests |
| `rules/` | Shared rules for the app and the skill |
| `notion-mirror/` | Optional local copy of Notion pages for facts and search |
| `telemetry/` | The Cloudflare Worker behind the optional Help improve Pacenote (event names and numbers only) |
| `keepalive/` | Optional Cowork plugin that keeps the skill listening during a call |
| `docs/` | The full guide: [English](docs/en/live-tips.md), [українською](docs/uk/live-tips.md); the team design in [`docs/team/`](docs/team/README.md) |
| `DEVELOPMENT.md` | Layout, build, the website, the telemetry endpoint and the measurements behind the design |

Pacenote works on its own. With [PM Control Tower](https://github.com/bodco/pm-control-tower) it also reads your project configs (people, Notion pages, the current state).

History: Pacenote grew inside PM Control Tower; releases up to 0.5.8 are [there](https://github.com/bodco/pm-control-tower/releases). This repository keeps that history.

MIT License. [Privacy policy](PRIVACY.md) and [terms of use](TERMS.md): your audio stays on your Mac (a call recording, if you turn it on, too, unless you upload it to your own Google Drive); nothing is sent to the author unless you turn on Help improve Pacenote (event names and numbers only).
