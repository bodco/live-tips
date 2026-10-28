# Changelog

Pacenote (formerly Live Tips). Earlier versions are described in the commit messages and in
[docs/en/live-tips.md](docs/en/live-tips.md), section 14.

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
