# Changelog

Pacenote (formerly Live Tips). Earlier versions are described in the commit messages and in
[docs/en/live-tips.md](docs/en/live-tips.md), section 14.

## 0.8.0 (Pacenote)

Live Tips becomes Pacenote, "your co-driver on calls": a new brand, a new tips window, Home, one call form, a
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
- **About:** icon, wordmark, version with build and macOS, Check for updates (opens the releases page),
  "Formerly Live Tips".
- **Notion:** sections and the transcript page say Pacenote; the last block of a meeting page is
  "Notes by Pacenote · transcribed on device" in the page's language. The skill does the same and still
  recognizes the older "Live Tips" sections.
- **Tips window title** is the call's name, without the product prefix.
- **Screenshots:** the shot mode renders every screen in English and Ukrainian (`-uk` files) and the splash.
- **Checks:** CoreChecks verify that both catalogs have the same keys and placeholders, no long dash, no emoji.
