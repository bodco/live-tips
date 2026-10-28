# Changelog

Pacenote (formerly Live Tips). Earlier versions are described in the commit messages and in
[docs/en/live-tips.md](docs/en/live-tips.md), section 14.

## 0.8.2 (F2: tips window)

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

## 0.8.1 (F1: foundation)

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

## 0.8.0 (F0: rebrand)

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
