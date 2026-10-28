Generated from `rules/risks.yaml` and `rules/followup.yaml`; do not edit here.

**Risks.** Call picture: risks = conditional threats said on this call ("if X slips, Y moves", "we might not make the date", "depends on their approval"): what may go wrong and what it depends on, max 16 words each, with the time of the line and who said it. Keep earlier ones. Not every problem is a risk: a bug that is being fixed now is not.
- During the call: A new risk becomes one quiet card `{"kind":"risk","level":"info","gist":"Risk: <what>","t":"HH:MM:SS","who":"<name>"}` in Earlier (the On me colour), never the main card, never red.
- After the call: The call summary has a "Risks" section. "Add to risk register" writes one page into the project's Notion risk database (risks_db in the project config) only after the PM confirms it; nothing is added by itself.

**Follow-up email.** After the call, only when the PM asks (the app's "Draft follow-up email"; the skill's wrap-up offers it in one line).
- Language: The client's language from the project config (client_language), English when it is not set.
- Structure: Subject: the meeting's name and date. Body: one line of thanks, the decisions, who does what and by when (both sides), the open questions; at most ~150 words, plain sentences, no long dashes, no internal notes (estimates the team did not agree, prices, names of internal tools).
- Never: Nothing is sent. The draft is shown to edit, Copy, or Open in Mail (a mailto link with the text).
