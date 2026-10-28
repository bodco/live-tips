# Pacenote

**Your co-driver on calls.** [Українською](README.uk.md) · [Site](https://tower.bodco.pm/pacenote/)

Pacenote prepares a short brief before the call, gives quiet, precise tips during it, and writes
the notes after. You keep the wheel. It listens to your call on your Mac and speaks up only when a fact or a phrase is needed:
a question to you, your turn, a new request, a date you are about to promise. Audio is transcribed
on the Mac and never leaves it; only text goes to Claude. After the call the summary, decisions and
action items land in Notion, and the transcript stays in your project folder.

Beta, built by one project manager for his own calls. The new name changes what you see; the repository,
the `live-tips` skill, the `LiveTips.app` file, folders and settings keep their names, so calls, folders and
permissions carry over. What "live tips" means inside the code: [DEVELOPMENT.md](DEVELOPMENT.md#names).

## Two ways to run it

| | The app | The skill |
|---|---|---|
| What | A native macOS menu bar app | A Claude Cowork skill |
| You need | Apple Silicon Mac, macOS 14.4+, a Claude API key | Claude Cowork with a computer linked, the recorder from this repo |
| Tips come from | Claude API, called on events | Claude in your Cowork chat |
| Download | [LiveTips.dmg](https://github.com/bodco/live-tips/releases/latest/download/LiveTips.dmg) | [live-tips.skill](https://github.com/bodco/live-tips/releases/latest/download/live-tips.skill) |

Both share the same rules (`rules/`) and the same recorder, so tips behave the same way.

## What it does

- **Before the call:** Prepare now writes a brief and fact cards from your project folders and the documents you name. Optional: without it the call still gets tips when you are addressed, HELP NOW and answers to your questions; a late preparation joins the call when it is ready.
- **During the call:** a small window with tips from your own facts, your update when it is your turn, a ready sentence on HELP NOW, a live transcript, a picture of the call (topic, what is on you).
- **Home and your calendars:** the calls ahead from several Google and Microsoft calendars (through macOS, nothing to install), overlaps marked so you pick the one you join; regular meetings start from their last setup; recent calls with Notion, transcript and folder.
- **Back-to-back calls (Up next):** plan and prepare the next calls while one is live, then switch with one question: the current call ends properly and the next starts with its preparation.
- **Any language in, one language out:** set the call to one language and every speaker is written in it (Ukrainian on an English call comes out in English).
- **After the call:** a Notion page in the call's language (summary, decisions, our commitments, new requests, open questions, risks, action items) with the whole transcript as a sub-page.

How it compares with Fireflies, Fathom and Notion AI Meeting Notes: [tower.bodco.pm/pacenote/compare](https://tower.bodco.pm/pacenote/compare/).

## Repository

| Path | What |
|---|---|
| `app/` | The macOS app (Swift) |
| `recorder/` | The recorder: audio capture, local Whisper transcription, speakers, the tips window |
| `skill/` | The Cowork skill: `SKILL.md`, `references/`, `settings.yaml` |
| `spikes/m0/` | The tips engine (Python) and its tests |
| `rules/` | Shared rules for the app and the skill |
| `notion-mirror/` | Optional local copy of Notion pages for facts and search |
| `keepalive/` | Optional Cowork plugin that keeps the skill listening during a call |
| `docs/` | The full guide: [English](docs/en/live-tips.md), [українською](docs/uk/live-tips.md) |
| `DEVELOPMENT.md` | Layout, build and the measurements behind the design |

Pacenote works on its own. With [PM Control Tower](https://github.com/bodco/pm-control-tower) it also reads your project configs (people, Notion pages, the current state).

History: Pacenote, then called Live Tips, grew inside PM Control Tower; releases up to 0.5.8 are [there](https://github.com/bodco/pm-control-tower/releases). This repository keeps that history.

MIT License. [Privacy policy](PRIVACY.md) and [terms of use](TERMS.md): your audio stays on your Mac, nothing is sent to the author.
