# Changelog

Pacenote. Earlier versions are described in the commit messages and in
[docs/en/live-tips.md](docs/en/live-tips.md), section 14.

## 0.9.5 (unreleased)

- **Call recording (2026-11-05, off by default):** save the call's sound, or the sound and the screen, on this Mac in
  `<project>/video/`, to watch a call again (for example the other side's reactions). Start call > Record the call
  (Off, Sound, Sound and screen) for one call; Settings > Call recording > Record every call for all. In the call the
  tips window's top bar has Record, then the time with Pause and Stop; Stop and Record again make a second part. A whole
  screen (the main one or another monitor) or one window (asked when the recording starts, or the call's window found
  by itself), switchable during the call; Pacenote's own windows and sounds are never recorded. The call's sound and
  your microphone in one track. Light (1280 px, the default), Standard (1920 px) and Sharp (2560 px), HEVC (the
  default, about 200 MB an hour at most with Light; Google Drive plays it) or H.264, with the most an hour takes shown
  in Settings. The file is written as it goes and saved when Pacenote quits. Never sent to an AI.
- **Recordings to Google Drive (2026-11-05):** Upload to Google Drive on the call page, or every recording after the
  call, into My Drive > Pacenote > <project> of the account you choose (`drive.file`, Pacenote sees only what it made);
  resumable, it goes on after a dropped connection or a restart. The call page shows the recording: length, size,
  Play, Show in Finder, Open in Drive.
- **Screen recording permission in onboarding (2026-11-05):** asked together with the microphone and the system audio
  (optional), so a recording never stops to ask; Settings > Call recording shows it and asks again.
- **Recording consent names the recording (2026-11-05):** when the call is also recorded, Settings > General > Recording
  consent says or copies its second message ("transcribes and records this call"), also when the recording starts
  later in the call. PRIVACY updated.
- **Call pages redesign (2026-11-05):** the pages of a held and an upcoming call are built from Home's cards: a header
  card with the actions on the right, counts on the tabs, Summary in two columns (topics with times and quotes; the next
  call, agenda progress, open questions), On you and On them side by side with others grouped by person, a transcript
  grouped by speaker with speaker filters. Fixed: topic titles showed stray stars and were cut at 10; Decisions falls
  back to the call notes.
- **Menu bar while recording (2026-11-05):** during a call the P stays as it is and only its small dot turns red.
- **Floating call controls (2026-11-05):** a movable panel above other windows while a call is running, with the
  transcription state, Home, Tips, pause/resume transcription and End call. Active sound or video recording has
  separate pause/resume and Stop and save controls. On by default; turn it off in Settings > General or the panel menu.
  Its position is remembered. With the panel on, the menu bar uses only the icon; the timer is in the panel.
  macOS determines menu bar order; Settings explains how to move the icon with Command-drag.

## 0.9.4.1 (2026-11-05)

- **Fixed: tip rating (2026-11-05):** a click on the amber wave or the red cross opened "What was off?" and hid it at once,
  and the rating was not counted. The window kept the rating only on a temporary copy of the card, and the next state
  update replaced it. The rating now lives in the feed (it survives updates and a rebuild of the card, with the reasons
  and the comment), so the box stays open until Save or Skip and the mark is kept.
- **Documentation for 0.9.4 (2026-11-05):** README and the guide (English and Ukrainian) now cover the three ways to the
  AI (Claude, ChatGPT, Gemini), the Gemini account through Antigravity CLI with its warning, plan B, OpenAI prompt
  caching, Settings > Usage, the measured prices with a link to the pricing page, rating tips and learning from ratings
  (edits.jsonl schema 2), one person with many names, Meet naming the voices and Help improve Pacenote. The guide has a
  section about the new website (14.1r) and the privacy section names where text goes. PRIVACY and TERMS link to
  pacenote.bodco.pm and TERMS covers the Gemini account and the website. DEVELOPMENT.md describes how the website is
  built and published, the telemetry Worker (what it validates, deploy, looking at the data) and the shared learning
  fixture.

## 0.9.4 (2026-11-05)

Includes 0.9.3, which was not released on its own.

- **Rate tips (2026-11-05):** each card ends with a green check (useful), an amber wave (fine, but off the point) and a
  red cross (not useful), own icons of one stroke width. After the wave or the cross: reason chips (Off topic, Late,
  Wrong fact, Too long, Not now) and an optional comment. The tips engine reads them during the call (STATE.pm_ratings:
  fewer of a kind off topic, shorter after too long, the comment wins; red tips and facts are never muted), the skill
  gets them as before (tip_feedback).
- **Learning from ratings and a richer corrections log (2026-11-05):** ratings join edits.jsonl; a tip rated down on
  two or more calls is a standing lesson for the tips of every next call and for every preparation. Every line now
  carries surface, call type, the way to the AI per job, app and rules versions (rules/learning.yaml, schema 2; the
  shared fixture covers ratings).
- **One person, many names (2026-11-05):** Settings > Speakers > Voice library > Names keeps the primary name and other
  spellings; Merge into asks which name stays, either one or a fuller one. Earlier transcripts are not rewritten.
- **Google Meet names the voices after the call (2026-11-05):** the Meet record is read by itself after End call (1.5 to
  20 minutes later). With Meet's transcript, voices are matched to participants by time; without it, the participants
  are offered first and the one-voice, one-participant case is named. The call page's Google Meet record does the same.
- **Help improve Pacenote (2026-11-05, off by default):** Settings > General > Privacy sends the usage log's event names
  and numbers of whole days once a week, with a random id per Mac, to the author's Cloudflare Worker (app/telemetry).
  Never call text, comments or names; Show what is sent opens the next batch. PRIVACY updated.

## 0.9.3 (released as part of 0.9.4)

- **Gemini API (2026-11-04):** Settings > AI has a third tab, Gemini, with a key (aistudio.google.com/apikey, a project
  with billing on: Google may use free-tier content to improve its products and does not use paid-tier content).
  Gemini can run the preparation, the tips and the work after the call, with a model per job: Gemini 3.5 Flash-Lite
  (fast, the default during the call), Gemini 3.8 Flash (balanced, the default for the preparation and after the
  call), Gemini 4 Argon. The classic streaming API is used: no stored interactions, no tools, no files.
  Spending counts Gemini prices, with the rises Google announced (Argon from 1 December 2026, Flash from 1 January
  2027). livetips_m0/gemini_provider.py, geminiprep.py, rules/ai.yaml > gemini.
- **Plan B through Gemini (2026-11-04, off by default):** Settings > AI > Automatic switching has "Use Gemini when
  Claude or ChatGPT is out". When the chosen way has no credit, hits its plan limit or has a bad key, the job goes to
  Gemini (tips, preparation and after the call), and goes back as soon as the chosen way answers. The text of the call
  then reaches Google, which is why it is a switch you turn on. A chosen Gemini never falls back to another provider.
- **Gemini account (2026-11-05):** the preparation and the work after the call can run on your Google account
  through Google's Antigravity CLI (`agy`): your plan pays, no API key. Settings > AI > Gemini shows the sign-in and
  the account's models (default Gemini 3.8 Flash, medium). Each request runs in an empty folder with no file, shell or
  write access, and Pacenote removes agy's own copy of the conversation afterwards. Not for tips during a call: a
  request takes 20-30 seconds. With plan B on and no Gemini key, the account takes over those jobs. When it is chosen,
  a red warning says that Google's Antigravity terms forbid use through third-party software (the account may be
  suspended) and let Google use and review the conversations, with a link to the terms.
- **Usage: AI through API keys (2026-11-04):** Settings > Usage shows every provider with an API key (Claude,
  OpenAI, Gemini): spend by stage (call preparation, live tips, after the call, total) and by model with requests and
  tokens, for today, the last 7 days (the default), this month or chosen dates. The preparation through the OpenAI or
  Gemini API now counts its cost (it was logged as $0), and each preparation line in the spend ledger names its model.
  The Claude and ChatGPT accounts are paid by their plans and are not counted.
- **Developer: provider bench (2026-11-04):** `tools/provider_bench.py` replays 5 invented meetings
  (Fixtures/bench, American names only) through Claude, OpenAI and Gemini variants and compares cost, latency and tips.
- **OpenAI prompt caching (2026-11-04):** on the OpenAI API route the blocks Pacenote marks for caching (the call's
  rules, brief and facts during the tips) now carry explicit cache breakpoints (30 minutes, renewed by every read), the way
  Claude's `cache_control` works. Cache writes are billed apart from ordinary input and are shown in the cost; a model that
  rejects the cache settings is asked once more without them. livetips_m0/openai_provider.py, cost.py (GPT-6 prices).

## 0.9.2 (2026-11-04)

Includes the Google accounts work of 0.9.1 (never released on its own) and the fixes from the audit of a
live call.

- **Google verification submitted (2026-11-04):** the Pacenote OAuth app passed Google's branding check and its data
  access (5 sensitive scopes, none restricted) was submitted for review. Until Google approves it, the sign-in still
  shows "Google hasn't verified this app" (Advanced, then Go to Pacenote) and the 100-user cap applies. The privacy
  page has a Google user data section with the Limited Use statement. No app behaviour changed.
- **Fewer lost and wrong tips with OpenAI (2026-11-04):** an answer that ran past the output limit after a complete
  JSON is kept (the rest is cut) instead of being thrown away; without a complete JSON it is asked once more with a
  larger limit. A tip with stray tokens in another script is dropped. run.json now names the route and the model each
  role really used (it showed the Claude ids while the tips ran on OpenAI), and the request log keeps the reasoning
  tokens, the cut and the retry. rules/ai.yaml.
- **Card hygiene (2026-11-04):** a "your turn" card is no longer shown by its trigger (the PM decides when to speak);
  a card with only regex triggers no longer fires by the meaning of its text; a card shows by meaning once per call;
  `lt prep-check` warns about one-word triggers the recorder ignores and `--fix` moves them to `words`.
  rules/semantic.yaml.
- **Facts follow the topic, not one line (2026-11-04):** a fact card also matches the last minute of what the other side
  said, so a point made over several lines gets its fact; it is not shown when you just said it yourself, when the
  last minute is about something else, or a second time on the same topic (a question still gets it).
  rules/semantic.yaml > fact_window.
- **A ready answer to a statement (2026-11-04):** when the other side states something (a claim, a doubt, a pain)
  that the prepared material answers with a ready answer, proof or caveat nobody said yet, a 🟠 tip gives it, at most
  2 in 10 minutes and once per topic; off in interviews. rules/triggers.yaml > answer_in_primary, rules/diet.yaml.
- **The main document in the preparation (2026-11-04):** the files you add to a call are named to the preparation as
  the primary document: each of its sections gives a fact or card marked primary, its "what is missing" points and
  ready answers stay whole sentences, and "Needs confirmation" keeps only conflicts it does not resolve. The run of a
  preparation keeps the names of the files it read and searched (never their content). An agenda item to agree or
  decide is no longer ticked done without a clear yes from the person who decides. rules/agenda.yaml, sweep.md.
- **Google calendars folded (2026-11-04):** Settings > Integrations > Google shows each account's calendar list
  folded, with how many are on; click to open it.
- **Developer: local layer replay (2026-11-04):** `tools/replay_local.py` replays the recorder's facts and cards on a
  recorded call with the same thresholds and model; on the Mac it reproduces a live call item by item.

- **Call notes in the call's language (2026-11-04):** the notes after a call (and the call page Summary made from
  them) are written in the language the call was held in, taken from the transcript, not in the app's interface
  language. rules/notes.yaml.
- **Start a call now (2026-11-04):** the arrow with Plan a call is part of the blue button now, not a loose chevron.
- **Fix: preparation through the OpenAI API (2026-11-04):** with GPT-6.1 Sol (the default for the preparation and after
  the call) every request failed at once with "OpenAI: HTTP 400": Sol and Astra do not accept the lowest reasoning
  setting the app sent. They now get the lowest one they accept, a model that still refuses it is retried once, and the
  error line says which setting was refused (never the request text).
- **Google accounts (2026-11-04):** Settings > Integrations > Google connects one or more Google accounts, like Notion
  workspaces (sign-in in your browser; tokens in the Keychain; Remove revokes them). Their calendars show on Home and in
  Coming up next to the macOS ones, without doubles (the same event from Internet Accounts shows once); the main calendar
  of each account is on, the others can be ticked. A Google Docs, Sheets or Slides link in a call's setup, or a document
  attached to the invitation, is read through your account before the brief is made, also when the document is private.
  Export has Google Docs (a new doc in the chosen account). A past call's "..." menu has Google Meet record: the
  participants and, when transcription was on in Meet, the Meet transcript, saved next to the call. Rules: google.yaml.
- **Resizable tips window (2026-11-04):** drag the border between the tips and the side panel (Transcript, On me,
  Brief) to make either wider; drag the bottom edge of the open agenda to show more or fewer items. Both are kept;
  double-click goes back to the default.

- **OpenAI model per job (2026-11-04):** Settings > AI has an OpenAI model for the preparation, the call and after the
  call, each with its Claude counterpart and price: GPT-6 Luna (fast, like Haiku, the default during the call), GPT-6.1
  Terra, GPT-6.1 Sol (like Sonnet, the default for preparation and after the call), GPT-6 Astra, and the older GPT-5.4
  mini. The preparation no longer shows Claude models when it runs on the OpenAI API. Spending counts the GPT-6 prices.

- **Home call cards like the mockup (2026-11-04):** the live call and the next call are big white cards: what the
  call is on the left (live timer, lines and tips so far, project, people, the brief state in green or orange), one
  big action on the right (Show tips, Get ready, Start call) with one link under it; the live card also has Prepare
  again / Prepare now and End call. Coming up sits in a white card too.

## 0.9.0 (2026-11-04)

- Live agenda: stable same-call identities survive rewording and reordering; all manual states and the current
  item survive. Ambiguous legacy matches stay open. Restore the previous agenda after an ordinary refresh.
  Repeated context corrections no longer overwrite the suspended agenda with an empty one. Situation results
  apply their revision check and derived state atomically; model requests do not hold the state lock.
- Offline fact-quality audit separates development and held-out calls, reports lost useful facts, and requires
  human-reviewed labels before recommending a threshold. Semantic evaluation reads actual fact books when present.
  Runtime semantic thresholds are unchanged: increasing the cosine threshold discarded useful recorded facts.
- Latency audit reports audio-to-transcript, first gist and final response separately; missing audio timing is
  excluded from audio latency and UI paint is explicitly unmeasured.
- The agenda ID markers on checklist lines no longer show in the brief view on the call page and in the brief window.

- **Live tips reliability:** suppress expired automatic requests before generation, streaming and final output;
  repeated transcript lines cannot trigger twice. Context corrections from the live window rebuild preparation,
  invalidate old model responses and clear the obsolete agenda. Preparation checks participant/goal/source conflicts
  and includes live essentials. Exact completed/skipped agenda questions survive ordinary refreshes.
  Noncritical repeated topics share a card; manual answers and red warnings remain separate. Interviewer tips
  ask follow-up questions rather than answering for the interviewee. Backchannels alone no longer trigger the
  situation model. Rules: diet.yaml and live_prep.yaml. Use Correct context, type the correction, then Enter.
- **Live tips reliability, review fixes (2026-11-04):** the interviewer gets answer tips to questions the other side
  asks them again; only an automatic statement that would answer for the interviewee is held back. A correction
  reaches the tips even when the brief cannot be remade, is sent once in the cached brief block instead of with every
  request, and a failed or cancelled remake brings the old agenda back with its states; answers, the speech card and
  the brief are no longer hidden by it. Old speech still moves the agenda and the brief reload, it only starts no
  tip; a line without timing ages from when it arrived. A late red warning still shows (up to 40 s, marked late).
  The same non-red gist within 5 minutes is dropped (9 of 31 tips of a recent discovery interview).

- **Call pages (0.9.0, 2026-11-03):** an upcoming call has its own page in Home (from its name on Home, on Coming up
  or in the menu bar): Setup (what kind of call, what matters, files, the rest under More settings; changes apply
  only on Save and leaving with unsaved changes asks), Brief, Tasks (on you, waiting on others, decided last time)
  and Earlier calls, with Get ready or Start call on the right. A past call has tabs: Summary (in short, what was
  discussed, for the next call, open questions, the agenda), Decisions, Tasks, Risks, Transcript and Sales for a
  sales call. "Add to Tracker" replaces "Add to register"; nothing goes there without a click unless auto-add is on.
- **Export (0.9.0):** a past call exports to Word (.docx), Markdown (.md) or a Notion page in the meetings database,
  with the sections to include and the whole text editable before it goes out. Edits change only the export.
- **Tracker (0.9.0):** one screen with the tasks, decisions and risks of every project, filtered by workspace, project,
  call, owner, status and text, grouped (overdue, this week, later; waiting for your OK, confirmed; open). It reads
  what is in Notion from the local Notion mirror and the call commitments kept on this Mac; no new register, no
  schema change. Settings > Modules turns it off.
- **Prepare now / Prepare again during a call (0.9.0):** a strip under the tips window header shows the brief and
  remakes it in the background from what was said so far plus the project files. Recording and tips keep going; the
  new brief replaces the old one at once and the old one is kept as the previous version. The skill does the same on
  the PM's words. Contract: rules/live_prep.yaml.
- **Menu bar panel (0.9.0):** the same soft Ready / Not ready pills and the same one main button as Home; the call name
  opens its page.
- **Claude and ChatGPT side by side (0.9.0, 2026-11-03):** Settings > AI and the onboarding have two tabs, Claude
  (Claude Code sign-in, Claude API key) and ChatGPT (ChatGPT account through Codex, OpenAI API key). The OpenAI API can
  now prepare calls too, not only give tips and write the notes after the call, so every job can run on either
  provider. Contract: rules/ai.yaml.
- **Not ready is orange (0.9.0):** a call that is not prepared shows a clear orange, not brown.
- **New Home (0.9.0, 2026-11-03):** Home shows what is next and what already happened, nothing else. The
  next call has one main button (Get ready, Start call, or Start call that only records without Claude) and one link
  under it; the rest of today and tomorrow is a Coming up line with Ready / Not ready, a "..." menu and Undo for a hidden
  call; Recent calls are three cards with one sentence from the notes and the number of decisions and tasks. Colours
  follow the call's state, not the project. The status line and Finish setup became one pill in the header, shown only
  when something needs you. This week's numbers moved to Settings > Usage, "What Pacenote can do" to Settings > Help,
  On you to the Tracker screen. A call can start without a project: it goes to the app's own folder ("My calls").
  Docs 14.1m.

- **ChatGPT account through Codex, alongside Claude:** onboarding and Settings > AI offer browser sign-in through
  the official Codex CLI and a separate account route for preparation, live tips and after-call jobs. API-key
  login is rejected for this route; OAuth credentials stay with Codex. Preparation uses a context pack built
  by Pacenote and writes the brief, speech, cards and facts without giving Codex file or tool access. Ephemeral,
  read-only CLI jobs do not load user config or switch providers automatically. Contracts: rules/ai.yaml;
  setup and account/API limits: README.md and README.uk.md.

- **OpenAI API for live tips and after-call work:** Settings > AI accepts an OpenAI key in macOS Keychain and
  offers OpenAI API for those two jobs, using GPT-5.4 mini with streaming Responses, no stored responses, token
  accounting and the existing live-call spending limits. Preparation can use Claude Code, the local model or the
  ChatGPT account route.
  OpenAI does not auto-switch providers; Claude Code deep folder lookup is disabled for OpenAI live tips, while
  local project search stays available. Contract: rules/ai.yaml; setup and limitations: README.md / README.uk.md.

- **On me is yours only, and Home from the call window (2026-11-03):** other people's promises from earlier calls no
  longer sit among yours with "on X" and a disabled tick: they are a folded "Waiting on others" group by person, can be
  ticked when done (closes them in the register) or taken over with Mine, and never count in On me. A house button next
  to More opens Home (also Command-0); it hides in a very narrow window.
- **Agenda: Skipped, and the list keeps its scroll (2026-11-03):** a click now goes not raised, now (blue), done
  (green), skipped (crossed out, for an item that is not relevant); a skipped item is never reminded, never carried
  into the next call and shows as Skipped on the call page. The opened agenda shows a legend of the four states and
  no longer jumps back to the top a second after you scroll (it was rebuilt on every update).
- **Two real calls reviewed (2026-11-02), docs 14.1l:** the agenda takes up to 20 checklist items with the full text
  on a click and for the model, and skips brief lines that only point elsewhere; interview follow-ups no longer stop
  after the PM's "mhm" and come again every 150 words of a long answer, as open questions for hiring and discovery
  interviews alike; "Anything else?", "my list is closed" or a typed "what did I forget" give one red tip with what
  the agenda and "Decisions to obtain" still miss, checked against the whole transcript; Proactive switched on during
  a call now changes the model's rules; a card found by meaning no longer fires on the PM's own words and comes back
  after 15 minutes at the earliest; HELP NOW shows a raw folder snippet only when nothing else matched, without
  Notion page ids. Also fixed: rules/recording.yaml was not valid YAML.

- **Pushbacks and "why do we need this":** two reactive tips in the PM mode, not only in sales calls
  (rules/triggers.yaml). `scope_pushback`: the other side pushes back on an estimate, a term, a price or the scope; the
  tip acknowledges, names what drives the estimate and offers the choices, never a number. `value_doubt`: the other
  side doubts the work is needed or has forgotten why it is in the plan; the tip gives the reason from the Decision
  register, the brief or the answer cards, the value in the client's terms, and for work the client cannot see what it
  protects and what skipping it costs later. The preparation adds "Likely pushbacks and value questions" to the brief
  (not in a sales call, which keeps "Likely objections"). Off for interviews. Docs 14.1k.
- **"Can't hear the other side" waits for your silence:** it shows only after you have been quiet for 15 s and no call
  audio came for 45 s (never during your own talk); "Not recording" after 60 s with no sound at all (rules/recording.yaml).
- **Tips window, "Can't hear the other side":** the red strip stays with Check audio and Details, but it no longer
  hides the brief, the agenda and the tips (a pause or a long monologue of the PM is not a broken call), and the list
  no longer jumps back to the top when the strip comes and goes.
- **Tips window, the big card:** an answer stays big for 3 minutes, any other card for 5; older cards all go to the
  list below instead of one old answer covering newer tips. Your speech too leaves the big place after 5 minutes and
  has Collapse (docs 14.1l).
- **Tips window, On me:** the tab did not open when an open item from an earlier call was on someone else (two
  interface strings had the same key); any failing part of the window no longer stops the rest and is logged in
  `logs/window.log`.
- **Tips window:** the big card and the earlier cards scroll together; in a short window the bottom of the big card
  and every card below it were cut off.
- **Start call:** Rehearse shows only for Presentation calls; until the talk is prepared it is greyed with an (i) that
  says how to prepare it (attach the deck, press Prepare).

## 0.8.8.1

- **Decision conflict tip:** the reminder sentence said "decision 1" (its number in the snapshot); the rule now asks
  for the decision itself, never its number (rules/decisions.yaml).
- **Add all on the call page:** the last decision of "Add all" still ran the "Replaces?" check; now none does.
- **Ukrainian:** the reasons under Decisions and Risks and the HubSpot hints named the Settings path in English
  ("Settings > Integrations"); they say "Налаштування > Інтеграції" now.

## 0.8.8

The decision register, automatic add after a call, and the Workspace property (rules/decisions.yaml):

- **Decisions to Notion:** Settings > Integrations > Notion > Databases has a Decisions row (the Control Tower
  Decisions database). The call page has "Add to decision register" on each decision and "Add all N"; Pacenote writes
  Decision, Date, Area (from the database's options), Context, Source, Status Active, Stated by, Project and Workspace,
  and the optional fields only when they were said. "In register" with a link after the write, also for risks.
- **Replaces an earlier decision:** after an add, a contradiction with an active decision of the project is offered as
  "Replaces <old, date>?"; only the click sets Superseded and the Supersedes / Superseded By links.
- **Add automatically after each call:** one switch each under Tasks, Risks and Decisions, all off by default; the
  0.8.6 tasks switch moved there with its value. Written once per call and text (`<stem>.notion.json`), never for a
  hidden call.
- **Workspace property:** next to the Project property of every database; meeting, task, risk and decision pages get
  the project's workspace. A workspace's value is set on its card in Settings > Projects.
- **Active decisions:** a local snapshot `<project>/pacenote/decisions.md` before a preparation and a call; the brief's
  "Active decisions" section, the series view, and a new quiet tip `decision_conflict` when someone contradicts one.
- **Usage log:** `decision_added`, `decision_superseded`, `auto_added {kind, n}`.
- **Keychain:** all keys are kept in one Keychain item, so after an update macOS asks once, not once per key (the first
  start of 0.8.8 still asks once for each key saved before, to move them).

## 0.8.7.2

After hands-on testing on the Mac:

- **Update HubSpot window:** it grew to 1572 pt and Apply and Undo were below the screen; it now opens at 560 by 520.
- **CRM row in Start call:** Refresh worked only after a brief existed, so the first brief never had the CRM snapshot;
  the snapshot now goes where Prepare will write the brief, before the first Prepare.
- **Follow-up draft follows the call page:** when the PM corrected a decision on the call page, the draft still used the
  transcript's version; the corrected call picture now wins (rules/followup.yaml).
- **Follow-up panel buttons:** "Write again" was cut and "Open in Mail" broke into two lines in the 380 pt panel; the
  "never sends" line is under the buttons now.
- **Home window minimum size:** below about 640 pt the call page was cut on the right; the window keeps at least 640
  by 480. In a narrow Home window Search and Transcribe become icons and the buttons keep one line (Ukrainian above all).
- **Presentation mode in a short window:** the slide card pushed Ask and Help out of the window; the card scrolls now.
- **Demo call:** shows the Speakers block and a short transcript, as a real call does (the pane was empty).
- **Notion database picker:** while the list was still loading it said "No database with this name"; it shows progress
  and fills in without reopening.
- **Help > Welcome tour:** the onboarding can be run again from the Help menu too (it was only in the menu bar panel).

## 0.8.7.1

- **No freeze after an update (Keychain):** after a new build macOS asks "allow access" for each saved key, and the
  app read the keys on the main thread from Home, so the whole app (Home included) hung until the prompt was answered.
  Presence checks now read only the Keychain item's attributes (no prompt), the keys are read once off the main
  thread at start and kept in memory, the Settings key tests run in the background, and Home opens when that is done.
- **Call page to Notion, one sync at a time:** an edit made while a sync was running started a second one on the same
  page, which could write the bullets twice; the running sync now starts the next one when it ends. A page Notion
  cannot find (not shared with the integration) or a refused token is said in words, not as the raw API reply.
- **Update HubSpot:** Apply is off after a successful write (a second click wrote the note and the task twice) and
  comes back after Undo; an Undo that fails says how many changes are still in HubSpot instead of "Undone".
- **Home starts at Home:** Home from the menu, the Dock or Command-0 on a closed window opens Home itself, not the
  call page or series left open last time (screenshots of Home showed a series for the same reason).
- **Call window tabs in one row:** with the Deal tab the side pane had four tabs and the fourth went to a second row;
  the tab row now holds any number of tabs. The tip card's actions wrap in a narrow window ("Hide" was cut in
  Ukrainian at 380 px).
- **Start call footer in Ukrainian:** "Start call" and "Save for later" no longer break or cut; the Rehearse caption
  wraps instead and is shorter ("Лише для презентацій"), "Save for later" is "Відкласти".
- **Settings > Projects in Ukrainian:** the scan result and "folders inside" were English only.

## 0.8.7

- **Windows without tabs (A):** no window ever joins a tab group, whatever "Prefer tabs" says. The call page, a
  series, a transcript and Statistics open inside Home with Back and Command-[; the follow-up email is the call page's
  right panel. Call memory is 640 by 520 with the last call's project chosen and the last three questions.
- **One source for the numbers (B):** Home's week and Statistics count the same calls (hidden calls never count);
  projects are matched by key, so "Orbit" and "orbit" are one; the week runs Monday to Sunday; a Sales calls filter.
- **Home hero (C):** with no call ahead Home shows what is due on you today, else the last call of the past 3 days,
  else one small line; an empty Later is hidden.
- **Series and commitments (D):** "Since last time" shows only changes; open commitments are grouped by owner with a
  "new" tag; a report of done work ("set up", "sent") is no longer a commitment (rules/commitments.yaml).
- **Editable call page (E):** Edit on the call page changes decisions, items on you and on them (text and due date),
  open questions and risks; the change is a new call picture line and an `edit` event in the register, and the call's
  Notion page is updated at once with a status line and Retry. Risks go to the Risks database chosen in Settings.
- **Settings > Integrations (F):** General, Projects, Integrations, AI, About. Integrations has a card each for
  Notion, Calendars and HubSpot. Notion: one Meetings, Tasks and Risks database for all projects, the project as a
  property, Fill from project configs; per-project meeting databases migrate to the most used one with a one-time
  note. Projects get In Notion, Sales with a method and Answer cards. No field is focused when Settings opens; model
  ids are in tooltips. Haiku is the default tip model for new installs.
- **Start call (G):** an empty "What matters" with a hint, Prepare and Start call in the footer, Sales in Options with
  the method and its description, a CRM line with Refresh.
- **Sales mode (H):** an option on top of any call type, with General sales (default), BANT, SPICED or MEDDIC from
  rules/sales.yaml. A Deal tab and a "BANT 2/4" chip in the call window, sales tips (objection, qualify, pain, next
  step, competitor, buying signal), answer cards per project, a sales part of the brief with company web search (only
  the company's name or domain), a Sales section and a scorecard on the call page and in Notion.
- **HubSpot (I):** a service key in the Keychain, Test, the list of scopes with Copy list; a local snapshot of the
  company, deal, contacts and activity next to the brief; Update HubSpot after a call with checkboxes, Apply and Undo
  for 8 seconds. Nothing is written without a click; the transcript is off by default.
- **Small things (J):** the follow-up is written when the panel opens; only the due date is red in On you, the
  project is not repeated, the filter is a "Project" pop-up.
- **What Pacenote can do (L):** a page in Help, the menu bar and on Home for the first 14 days, with Try it and how
  often each feature was used; buttons that depend on a condition stay visible, greyed out with the reason (Rehearse,
  Series, Add to risk register, Update CRM); the demo calls are always in Help; the welcome tour can create the
  folder structure, offers to continue without Claude honestly and shows the three shortcuts, which come back once
  on the first call; How Pacenote works links to the new page.
- **Local usage log (M):** event names and numbers only (rules/usage.yaml), one file a month in the app's folder,
  12 months kept, a switch in Settings > General > Privacy. A server sink can be added later behind the same interface.
- **Finishing (31.10):** call page rows edit in place (double-click or Return, Esc cancels) with Edit, Copy text and a
  menu (Move, Change owner, Set due date, Delete, Save as answer card), "+ Add" per section, agenda state chips, Notion
  sync 2 s after the last change with "Synced to Notion · 5 s ago" or Retry; the follow-up panel on Option-Command-I
  (a sheet in a narrow window); Integrations pages with Back and Command-[; database pickers with search, the project
  property and In Notion values picked from Notion (no ids shown), several relation pages per project; Start call
  in one scroll with a date field, a language pop-up, slide tiles with their first words and the brief as a status
  line; Transcribe languages as chips with More; Series pill in Recent; answer cards as a list, indexed, used first
  by Ask and HELP NOW in Sales mode; HubSpot page with matching, owner, what is read and written, qualification
  fields; welcome tour with a picture of the audio permission, add-ons in plain words and an Install Python button;
  Connect Claude on Home; conditional buttons explain themselves everywhere; the system-audio tap is rebuilt once
  when it hears only silence for 45 s while the Mac is playing sound.
- **Docs:** a review of the guides against the app (tip model, settings paths, hotkeys, Home, after-call notes).

## 0.8.6

- **Call window title bar (A):** the pin is back (Always on top, remembered; Option-Command-T); a taller title bar
  with 24 pt buttons on the traffic lights' line; "Ending…" is translated.
- **Transcribe a recording (B):** a file or a link (Google Drive, YouTube, Vimeo, Dropbox, direct) becomes a
  call-format transcript on this Mac, with the voices told apart after the pass; Speakers card, a player, Save to a
  project, Add to Notion, Markdown and Word. Waits while a call is live. Recent marks File or Link.
- **Settings > Notion (C):** the Keys tab is folded into Notion: connection, meeting pages (per project for projects
  without a config), your tasks, the local copy.
- **Notion tasks in On you (D):** off by default; one list with commitments on Home and in the call window's On me,
  ticks and Remove (Notion trash, Undo) both ways, Mine on any line, items typed in On me, commitments sent to Notion
  by hand or after each call, linked items synced (register ops link and unlink).
- **Notion tasks, after the first look (30.10):** global settings and "Projects in Notion" are separate sections with
  an (i) on every setting; several Notion values per project; a workspace shows once; a period filter (edited in the
  last day, week, 2 weeks, month or all time); a new condition starts on an unused property; Refresh says what is
  missing; people come from the database when the integration cannot list users; On you has Show all.
- **Notion tasks without a person (30.10):** "On me means" is optional (Anyone): a PM who keeps the database alone
  sees every task within the conditions; new tasks get no person.
- **Ollama on demand (30.10):** a job on this Mac starts Ollama by itself and waits for it; downloaded models show
  and can be chosen while Ollama is stopped.
- **Agenda line opens (30.10):** a click on "Agenda N of M" shows every item with its state; a click on an item
  moves it on (not raised, now, done).
- **Fixes (30.10):** a model already downloaded counts as installed while Ollama is stopped (no second 16 GB); one
  green for every status check; a gap and a line under the Settings header.
- **Optional add-ons (E):** Ollama, the local model and the Link downloader in one pattern: Settings, About and an
  optional onboarding step; never part of readiness, never installed during a call.
- **Speakers above the tabs (F):** chips and an open card for an unnamed voice on Transcript, On me and Brief.
- **Recording:** "Can't hear the other side" now says to switch the sound output and back when the call is in a
  browser (it reconnects its audio).

## 0.8.5

- **Start call, the same order for every call:** block 1 (title, date, time, call type, audience, language) and
  block 2 (project and context) never move; the type section is always last, so switching the type changes only it.
- **Presentation block:** attach a PDF, PowerPoint, Keynote file or a text outline (or paste the talk as text, or
  drop the file). The deck is read once (text and a thumbnail per slide) with a progress line; speakers, who
  presents each slide (click a slide or type "5-9 Ann", "1, 14 all", "10-13 me"), the duration from the calendar or
  your own, Q&A at the end and the talk time it leaves. Errors say why and give one action.
- **Your talk, slide by slide:** after Prepare every slide is a card you edit in place (what to say, numbers, Q&A,
  can skip, a one-sentence short version, the time budget). A colleague's slides are one quiet group. A banner
  says whether the talk fits its time. Edits save as you type.
- **Prepare again:** Keep my edits (default) or Rewrite everything; the deck file can be replaced first. One
  previous version is kept (Restore previous version) and Review changes shows what was rewritten or kept.
- **Presentation mode in the tips window:** a slide rail with thumbnails, a countdown per slide with +30 s, one
  line Plan · Elapsed · Behind, one quiet advice that updates in place (skip a "can skip" slide, or say only the
  short version of the longest ones), numbers in bold, the audience's question as one card, Previous and Next.
  The slide follows Keynote or PowerPoint (app only, Automation permission) or your speech: it asks "Move to slide
  N?" (Enter yes, Esc no) before moving. No tips during a colleague's slides, then one "your turn" card. A
  Presentation call always has Presentation mode in the ⋯ menu, with an empty state to attach a deck. Compact
  presentation is a 380 px column.
- **Shortcuts:** Control-Option-S presentation mode; Control-Option-Left and Right and Control-Option-= (+30 s)
  only while presenting, so they never take keys from a window manager. Compact (Control-Option-T) and proactive
  tips (Control-Option-L) keep their keys. All can be changed in Settings.
- **Rehearsal:** three entry points (next to Start call, in Home's Are you ready, in the Presentation block with
  the last result), an intro, a run-through of your own slides with a timer each, 4 questions from Claude playing
  the client with the reason for each, one at a time, and a result. Apply to talk proposes shorter text and better
  answers; you review them in Your talk before they are saved. Nothing is recorded.
- **After the call:** right after End call the tips window shows the decisions, what is on you, the open
  questions, the series and the follow-up. Write draft, then change it in your own words ("drop the pricing
  line", "shorter") or by hand; Copy or Open in Mail, never sent for you. Home's Recent rows show Summary,
  Follow-up and Series on hover and with Tab; the Series pill explains why calls are linked.
- **Learning from your corrections:** every instruction and edit (follow-up, talk, rehearsal changes, brief) is
  logged; a correction you made on two or more different calls is applied to every next preparation or draft by
  itself, a single one stays with its meeting (rules/learning.yaml, the same rule in the skill).
- **Recording problems are a state, not a tip:** after 30 s without any audio, or without the call's audio, a red
  strip, the reason, Mic and Call levels and one action (End and restart, or Check audio). It clears by itself.
- **Fixes:** the tips window offers the voice library's suggested names again (one click, the side kept); a
  preparation still running when the call starts is recognised by the call's title and day, so its progress shows
  and its files join the call when ready; a deck attached during the call gives a basic talk at once.
- **Voices:** a speaker named on the call takes only that person's voice (the library decides when a line is
  clearly someone else's), renaming a speaker to another known person moves the old person's lines back, and
  Settings > Voice library can merge two entries of one person ("Maria H." and "m.holosovska" into "Mariia H.");
  the merged spelling then names the kept person everywhere (rules/voices.yaml).
- **Prepare again for every call:** once the brief is ready, Prepare first becomes Prepare again (asks first, keeps the
  previous brief); a presentation opens Your talk with Keep my edits. Home's Up next card has it too.
- **Ready for a colleague's Mac:** Claude Code is a component like Python (checked in Settings > About > Components,
  installed by one button in onboarding or there; preparing calls needs it whichever way pays), the skill's
  preparation instructions travel inside the app, onboarding and About explain the "Open Anyway" of a beta that
  is not notarized yet, and the DMG's "Read me first" says it all in English and Ukrainian.
- **One preparation, one call:** a preparation finished before a held call of its series ended belongs to that
  call; the next call of the series is not shown as prepared by it. Home's Later badges and actions line up.
- **Your speech, point by point:** each point of the speech is a line that opens to its full text, ready to read
  aloud (the brief keeps it as "> " lines under the point; the skill and the window use the same format). The Brief tab
  opens those points the same way. Preparing a call uses the newest copy of the skill's instructions (an older copy
  was found first, so the full texts were never written).
- **Tips window:** a card picked from Earlier shows Back to latest (or pick the newest card again) to return to the
  automatic order; the speaker name popover opens upward near the bottom of the window. Call settings: the Done
  bar is separated from the form.
- **Transcript:** any line can be deleted again (two clicks, Restore undoes it), as in 0.7; applied after the call.
- **Languages:** choosing Ukrainian or English during a call means that language only, as at the start (English
  and Polish lines no longer slip into a Ukrainian call); a line that comes out in a language outside the call's
  set is recognised again in the main language.
- **Voices:** the voice library learns only from a speaker you named and only from the lines that sound like
  that speaker, so one mixed-up call no longer blurs a person's voice for the next calls.
  How close a voice must be to join a speaker or to merge two speakers now grows with the number of lines behind
  them (one line's voice print is noisy), so two similar colleagues stay apart. With no voice match, the name
  popover offers the people of the meeting series and the calendar event.
- **Ukrainian and names transcribed better again:** a call started from the app now gives Whisper the same short
  prompt the skill always gave (the first names of the people and the title, in the call's language); without
  it Ukrainian and names came out worse.
- **Meeting page:** a quote inside the summary no longer stops the Notion page (the JSON is repaired or asked
  again), and Send last call to Notion in the menu works after the app restarts.
- **Preparation on this Mac (Ollama):** Settings > AI > Preparation can run on a local model (gemma4:26b by
  default): the app gathers the call's material into one pack and the model writes the brief, the cards and the
  facts; free, nothing leaves the Mac (rules/ai.yaml > local).
- **What a preparation costs, measured:** five runs of one real preparation (docs 14.1g): Sonnet through the API
  key $0.77 in 3 minutes, Opus $2.57 in 6, the Claude account the same work from the plan, the local Gemma 4 26B
  free but thin. Sonnet through the key is the recommended default.
- **Plan B when Claude is down:** with "Use it when Claude does not answer" (on by default) the preparation and the
  after-the-call jobs run on the model on this Mac when neither the Claude account nor the API key can run. Tips
  during a call stay on Claude. Settings: "Instant search in your materials" (was Local AI) says what bge-m3 does.
- **Local models everywhere a job can use them:** Settings > AI shows Ollama's state with one action (Get Ollama,
  Start Ollama, Install Gemma 4 26B with progress); the installed models appear in the model lists of Preparation
  and After the call, both of which can now run On this Mac.
- **Local preparation in three passes:** notes of each earlier call, then the brief section by section, then the
  speech with full texts and the cards and facts, to come closer to a Claude brief. The digest and the file check
  that Claude Code was refused are now made by the app around it; a person in the invitation who has left the
  project is named as not expected.
- **Every preparation kept for comparison:** a full preparation starts clean (the previous one's files move to
  prep-runs) and keeps its files with run.json (route, model, time, price, tokens); tools/prep_compare.py lines them up.
- **Transcript call type and a Tips switch:** a Transcript call records and transcribes with no tips; the summary,
  the meeting page and the follow-up come after it as usual. Call settings has Tips on/off before Proactive tips,
  for any call (rules/meeting.yaml > tips; the skill reads `@@SET tips`).
- **Every Claude model turns thinking off its own way:** Sonnet 5.5 needs "between_tools", Haiku 5.5 "disabled",
  Opus 5.5 adaptive thinking at low effort; on such a 400 the request goes once more in the form the model asks for
  and the model keeps it (the follow-up draft failed, and Haiku or Opus as the tip model would have failed every tip).
- **Speakers in the transcript:** the top of the Transcript tab lists every voice of the call, as in 0.7: named or
  not, what an unnamed one said last, Team or Client in one click, and one-click names. An unknown voice is grey
  like Speaker N (it was purple, as if a client); a line given to a person takes that person's colour.
- **Full call notes for the next preparation:** after every call the app writes <stem>.notes.md (topics with quotes,
  every question and its answer, decisions, action items, promises, facts and numbers), checked for lost numbers,
  keys, addresses and questions, with the PM's names and the project's terms to correct garbled words. The next
  preparation reads the newest call in full and the older ones from their notes (rules/notes.yaml).
- **Bluetooth headsets:** with AirPods or another Bluetooth headset as the default input, Pacenote records you
  from the Mac's built-in microphone and leaves the headset to the call app (a second app on a Bluetooth mic, and
  every restart of it, made the headset cut in and out for the call too). A chosen input in the Mic menu still wins.
- **What each stage costs:** every model request (live tips, the meeting page, the after-call drafts, the judge)
  and every preparation adds one line to `state/spend-ledger.jsonl` (stage, route, model, tokens, price; never
  the text), and `<stem>.prep.json` keeps the preparation's price, time and tokens.
- **Skill and app behave the same:** the time line, the advice and "Move to slide N?" are computed once by the
  recorder (rules/presentation.yaml, a shared fixture checked in Python and in the window); slide sync from
  Keynote or PowerPoint is marked app only.

## 0.8.4

- **Engine quality (ub-mode), nothing changes on screen:** the tips engine, live mode, the AI providers, the
  after-call jobs, the built-in embedding engine, the Notion mirror and the keepalive hook are split into small
  tested functions. Every function of the shipped engine is under CRAP 10 (the developer bench tools excepted);
  a replay of a synthetic call pins the tips, and a fake Notion pins the mirror, so the split could not change
  what they do.
- **Fixes:** a request to the built-in embedding engine whose body is not a JSON object gets an error reply
  instead of a dropped connection; one malformed line in the PM's corrections no longer stops the after-call
  summary.

## 0.8.3

- **Cheaper tips on the API key:** the earlier minutes of the call are now read from Claude's prompt cache
  instead of being paid in full on every request (about 8% less per call in an A/B replay of a recorded call).
- **Fix:** after the rename the app could keep pointing at the removed "Live Tips.app" for its tips engine; the
  engine now follows the app at every launch.
- **Engine quality (ub-mode):** the AI routing module is split into small tested pieces (every function under
  CRAP 10, 94% of mutants killed); a missing key or a missing Claude Code now shows up in Settings > AI.

## 0.8.2

- **Settings > AI is the one place for Claude.** Access once for the whole app: your Claude account (Claude
  Code sign-in, the plan pays) and the API key (moved here from Keys). Then each job picks its way and its
  models: preparation (Claude account by default), during the call (API key; the Claude account is there too,
  marked "not recommended", with the reason), after the call (Claude account by default: summary and Notion
  page, follow-up email, call memory, rehearsal, the tip judge).
- **Automatic switch** (on by default): when the chosen way is out (no API credit, the app's monthly limit, the
  plan limit, signed out, Claude Code missing), the job goes the other way; the chosen way is checked again
  before the next job (during a call every 2 minutes) and the job goes back as soon as it answers. Settings > AI
  shows what is out and why, with Check now. Shared with the engine in `state/ai-routes.json`.
- The call form no longer has its own tip model. The after-call summary now uses the "After the call" model
  (it used the tip model).

## 0.8.1

- **Tips window, three tools in the top bar** after On me: microphone (crossed out in red when off), pause (turns
  into a Resume button; the recording dot and the timer turn grey) and a bulb for proactive tips (tinted blue when
  on). Each has its shortcut in the tooltip, an `aria-label` and `aria-pressed`.
- **New shortcut Control-Option-L** for proactive tips, listed in Settings > General > Shortcuts; the choice is
  remembered for the next call.
- **About** no longer shows the old product name.

## 0.8.0 (Pacenote)

Pacenote, "your co-driver on calls": a new brand, a new tips window, Home, one call form, a
four-step onboarding, and new features before, during and after the call. Built in seven phases (F0 to F6):

### F6: after the call

- **Call page:** a click in Recent opens what the call left: decisions, on you and on them, open questions, the
  agenda, the risks; with the follow-up email, the transcript, the series, Notion and Finder. The tips window offers
  the call page and the follow-up email when the call has ended.
- **Follow-up email:** a draft in the client's language to edit, copy or open in Mail. Nothing is sent.
- **Call memory:** Home > Search calls (Command-F), one project at a time: an answer, a quote and Jump to the moment
  in the transcript.
- **Series page:** what changed since last time, open commitments, questions open for several calls, decisions call
  by call.
- **Statistics:** how much you spoke, questions left open, calls without a decision, decisions with a brief and without.
- **Risks:** a quiet Risk card during the call, a Risks section after it, "Add to risk register" (Notion) only after
  you confirm.
- **Rehearsal** of a presentation without recording: steps with timers, 4 client questions answered in writing, a score.
- **Fixed:** Call settings during a call allow one or several languages, as the call form does (in 0.7 only one).
- Shared rules: `rules/followup.yaml`, `rules/risks.yaml`, `rules/rehearsal.yaml` (rules 0.3.0).

### F5: agenda, commitments, brief freshness, call-start offer

- **Agenda as a contract:** the brief's checklist is the agenda; the call picture marks the item being discussed and
  the ones done, a click on the agenda bar sets a state by hand. The Notion page gets an "Agenda" section, and items
  not raised go into "What matters" of the next call of the series.
- **Commitments register:** what you took on and what others promised your side, kept per project in
  `live/commitments.jsonl` (append only), written by the app and the skill alike. Home > On you lists your open items
  from every call (overdue first) with tick, Copy, Open the call and Not a commitment; Up next shows what is still
  open in the series. A later call that says an item is done shows a quiet "Done?" card; only Mark done closes it.
- **Brief freshness instead of overnight preparation:** "Brief is 2 days old · 3 changes since" on Home, Later and
  in the call form, with Refresh: an update of only the sections the changed files touch. Never by itself.
- **Start tips when a call begins:** with Zoom, Teams or a browser call on and a calendar call starting, a quiet
  notification and a Home banner offer to start tips; nothing records by itself (Settings > Calendars).
- Shared rules: `rules/agenda.yaml`, `rules/commitments.yaml`, `rules/freshness.json` (rules 0.2.0); the skill's
  SKILL.md and references follow them.

### F4: forms, brief, onboarding, Settings

- **One call form for three jobs:** Start call, Prepare and Plan a call share one window (project, title, time
  from the calendar, call context with folders and files, one brief line with one action). Audience, call type,
  languages, mic, proactive tips, tip model, recording, Public call and the Cowork request sit under Options.
  The buttons follow the job: Prepare, Start call (or Prepare first, Save for later), Save or Switch for a plan.
  The separate Prepare sheet on Home is gone; Home opens the same form.
- **The brief reads like a document:** prepared and for-the-call times in the header, a line is edited in place
  with a click, checklist lines are real checkboxes saved to the file; Edit the whole text and Show in Finder in
  the menu. Edits are logged as before (the original stays in .brief.orig.md).
- **Onboarding in four steps** (permissions, folder, Claude, done) with a progress bar and Back. Speech
  recognition installs in the background from the first step; the footer shows its progress or what failed.
- **Finish setup on Home:** small cards for what is still missing (the speech engine, your name, calendars, the
  Notion token); each can be hidden.
- **Settings:** keys show Connected, Saved or the error, with Replace, Test and Remove in a menu; AI starts with
  this month's spend and a Balance link; About lists the components with Check again and Install or repair;
  How it works moved to the Help menu; the calendar accounts fold away once calendars are there.
- **Every native screen in English and Ukrainian:** Settings, the setup window, calendars, Notion setup, shortcuts,
  the language picker (language names follow the interface language), alerts and notifications. The prompts to
  Claude stay in English on purpose (see DEVELOPMENT.md, Names).

### F3: Home

- **Home answers "what is next and am I ready":** Today with the day's calls and time on calls, Plan a call and
  Start call on top. Up next is one big card: the call (or the live one with its timer and Show tips), the project,
  people and platform, then **Are you ready?**: the brief (ready and when, preparing, or Prepare), what is still on
  you from the last call of the series, questions left open last time, overlaps with another call (Skip hides it on
  Home only). One verdict: Ready, Mostly with what is left, or Not prepared. Then Start tips for this call and Edit setup.
- **Later:** the rest of today and the next day, one row each: time, call, project and people, one badge and one
  action; Set up, Start now, Show in Calendar and Hide in the row's menu.
- **Right column:** On you (what you took on in the last two weeks, from the call picture; a tick hides it here
  until the commitments register in F5), This week (calls, time on calls, prepared X of Y and a Monday to Friday
  chart, no dollars; Details opens the full statistics), Recent (call, date, "2 decisions · 1 on you · 1 open
  question"; a click opens the Notion page or the transcript, the rest in the context menu).
- **Status line:** Claude, Notion and calendars with a dot, red only when something is wrong; spending appears only
  as a warning near the monthly limit. Dollars are left to Settings > AI (also gone from the statistics).
- Home and the statistics in English and Ukrainian.

### F2: tips window

- **New tips window** (Concept A "Focus"): one card answers "what do I say now" (hero), older cards one line each
  under Earlier, the agenda as a bar on top, On me, the next call when it is 10 minutes away, Ask and Help. Wide
  windows show Transcript, On me and Brief on the right; narrow ones open them as a sheet. Light and dark, English
  and Ukrainian, no emoji, no colored stripes.
- **The call summary is no longer a card in the middle of the call:** it feeds the "N min left" card 5 minutes
  before the calendar end (not raised agenda items and a recap to say aloud) and the summary after the call.
- **Cards:** Said it (moves it to Earlier as Answered), Shorter (asks Claude for one sentence), Pin, Edit, Hide.
  A click on an Earlier line makes it the hero; Esc goes back.
- **Speakers inline:** a "New voice" banner over the transcript, a click on any name opens Name + Client/Team.
  "Forget speaker names" is in the menu, the transcript follows the latest line by itself.
- **Window menu:** Pause, Mic off, Compact mode, Presentation mode, Transcript, Brief, Forget speaker names, Switch to
  next call, Call settings. Call settings is a native window: call type and role, audience, language, microphone,
  proactive tips, the call's name, background opacity, always on top, hiding from screen sharing, interface language.
  Text size with Cmd + and Cmd -.
- **Compact mode** (Control-Option-T): a strip with the timer and the hero's phrase, on top, still hidden from screen
  sharing. Control-Option-M turns the mic off or on. Both can be changed in Settings > General > Shortcuts.
- **Title bar:** the Pacenote symbol and the call's name, End call; no pin.
- **Check for updates** asks GitHub for the latest release and offers the download.
- The old window (`app/Resources/prompter.html`) is removed from the app; the skill's live-transcriber keeps its own.

### F1: foundation

- **Design tokens** (`PacenoteTheme.swift`, the same values as the web `tokens.css`): colors for text, accent,
  status and recording, radii, spacing, type sizes.
- **Three button styles only:** primary (one per window, Return), secondary, tertiary for actions in rows.
  The capsule buttons, the soft blue buttons and link-style main actions are gone; disabled buttons dim.
- **Contrast and size:** no text under 12 pt (the 10 pt captions are 12 pt now), captions in the darker grey
  from the tokens, status colors from the tokens instead of system red, green and orange.
- **Menu bar panel** instead of the system menu: the next call with its readiness, Start tips, Open brief or
  Prepare, two more calls, Open Home and Start a call, this month's spend and the last call; during a call the
  call card with Show tips, Pause and End call (asks first), Help now and this call's cost. Settings in the
  header, Setup, Welcome tour and About under Help and About, the demo windows with Option. Closes on Esc and
  on a click outside.
- **Home ⌘0 and Start a call ⌘N** are also in the app menu.
- **Screenshots:** the panel between calls and during a call.

### F0: rebrand

- **New name: Pacenote**, "Your co-driver on calls" / "Ваш штурман на дзвінках". The bundle identifier,
  the `LiveTips.app` file, folders, settings, the CLI, `.livetips-index/` and the `live-tips` skill keep
  their names, so permissions, calls and folders carry over.
- **Icon and menu bar.** The "Route P" icon (light) drawn at build time; the menu bar shows the Pacenote
  template and, while recording, the elapsed time. No binary assets in the repository.
- **Interface in English and Ukrainian.** A string catalog (`app/Resources/i18n`), the same switch as the
  tips window (Settings > General > Interface language), no restart. In 0.8.0: the menu, onboarding, About,
  window titles, alerts and notifications; the other screens follow with their redesign.
- **macOS names and permission texts** per language (`InfoPlist.strings`, en and uk).
- **First launch:** a splash with the icon, the wordmark and the tagline before the setup steps; the last
  step offers a demo call or Home.
- **About:** icon, wordmark, version with build and macOS, Check for updates (opens the releases page).
- **Notion:** sections and the transcript page say Pacenote; the last block of a meeting page is
  "Notes by Pacenote · transcribed on device" in the page's language. The skill does the same and still
  recognizes the older "Live Tips" sections.
- **Tips window title** is the call's name, without the product prefix.
- **Screenshots:** the shot mode renders every screen in English and Ukrainian (`-uk` files) and the splash.
- **Checks:** CoreChecks verify that both catalogs have the same keys and placeholders, no long dash, no emoji.
