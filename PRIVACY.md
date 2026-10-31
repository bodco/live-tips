# Pacenote privacy policy

Updated 31 October 2026. The full text is on the website: **[tower.bodco.pm/pacenote/privacy/](https://tower.bodco.pm/pacenote/privacy/)** ([українською](PRIVACY.uk.md)).

In short:

- **Audio stays on your Mac.** Speech is recognised locally with Whisper; audio is never written to disk or sent anywhere.
- **Transcripts, voice prints, settings and logs** stay in your project folders, the app's folder and the macOS Keychain.
- **Text leaves the Mac only to services you set up with your own keys or accounts:** Anthropic, through your API key or your Claude account with Claude Code (or another OpenAI-compatible provider), for tips, preparation, search and the wrap-up; Notion for the meeting page; HubSpot, if you connect it, for the CRM update you approve after a call; web pages you name in the preparation; one-time model and package downloads (Hugging Face, GitHub, PyPI).
- **HubSpot (0.8.7).** The service key stays in the macOS Keychain. Pacenote reads the company, the deal, contacts and recent activity into a local snapshot next to the brief. It writes a note, deal fields and a task only after you tick them in Update HubSpot and press Apply; the transcript goes into the note only if you turn that on (off by default).
- **Company web search before sales calls (0.8.7).** On by default, switch it off in Settings > AI. Only the company's name or domain goes into the search, never anything from your files; the brief says what was searched.
- **Local usage log (0.8.7).** Pacenote keeps a log of which features you use (event names and numbers, never the words of a call, names or titles) in the app's folder, one file a month, 12 months kept. It stays on your Mac; switch it off in Settings > General > Privacy.
- **Nothing is sent to the author.** No analytics, no tracking, no crash reporting. Nothing is sent to clients by itself.
- **You are responsible for the people on your calls:** tell them you transcribe and use an AI assistant, and get consent where it is required.

Questions: [issues](https://github.com/bodco/live-tips/issues). Terms of use: [TERMS.md](TERMS.md).
