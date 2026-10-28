Generated from `rules/agenda.yaml`, `rules/commitments.yaml` and `rules/freshness.json`; do not edit here.

**Agenda.** Source: The checklist lines of the call's brief (`- [ ] item` and `- [x] item`, in the order of the brief). Hiring: the planned or likely questions; a stand-up the PM leads: the people to hear from. At most 8 items, ~60 characters each.
- States: `todo` not raised yet; `now` being discussed now (at most one item); `done` discussed, decided or answered.
- Call picture: agenda_now = the number of the AGENDA item being discussed in the new lines, or -1 when none is. agenda_done = numbers of AGENDA items that were discussed, decided or answered on this call (keep earlier ones). An item counts only when its subject was really talked about, not when someone only names it in a list.
- Window: One item `{"kind":"agenda","items":[{"text":"<item>","done":true|false,"cur":true|false}]}` each time the state changes; it replaces the previous strip. The PM can change an item's state in the window (`@@SET agenda_state=<index>|todo|now|done`, index from 0); the PM's state wins over the model's.
- After the call: The call summary gets an "Agenda" section: each item with Discussed, Raised or Not raised. Items not raised go into the "What matters" text of the next call of the same series, as one line "Not raised last time: <item>; <item>".

**Commitments register.** File: `<call folder>/commitments.jsonl`. JSON lines, append only. Each line is an event; the register is the events folded by id. Never rewrite or delete lines: a later event wins.
- `add`: `{"v":1,"op":"add","id":"<id>","text":"<what, max 120 chars>","owner":"me|<name>","project":"<slug>","series":"<series key>","call":"<transcript file name>","t":"HH:MM:SS","created":"<ISO time>","due":"<day or date, or empty>","by":"app|skill"}`
- `done`: `{"v":1,"op":"done","id":"<id>","at":"<ISO time>","source":"manual|detected","call":"<transcript file name, when closed on a call>"}`
- `reopen`: `{"v":1,"op":"reopen","id":"<id>","at":"<ISO time>"}`
- `drop`: `{"v":1,"op":"drop","id":"<id>","at":"<ISO time>"}`
- id: `c-<first 10 hex characters of sha1 of: call file name without .app, owner, text in lower case>`; series: `<project slug>|<call title in lower case, letters and digits only>`.
- Owner: me = what the PM took on (the call picture's actions). A name = what someone else promised the PM or the PM's team on this call ("on them"). General team to-dos and other people's updates about their own work are not commitments.
- Duplicates: The app and the skill may record the same call. An add whose call (without .app) is the same and whose text shares at least 60% of its words with an open item is the same commitment: keep the first.
- Write when: At the end of the call (state stopped), once: every action of the call picture (owner me) and every promise made to the PM's side (owner = the person's name), with the due date when one was named. An item the PM ticked in the window's On me is added and closed at once (done, source manual).
- Open on call: At the start, read the open items of this project (up to 15, this series first). Give them to the model that keeps the call picture as OPEN COMMITMENTS with their ids.
- Model rule theirs: theirs = promises other people made to the PM or the PM's team on this call: who and what, with the due date when named ("I will send the list by Friday" said by the client). Never the PM's own tasks, never a task for a third person, never someone's update about their own work.
- Model rule done: done_commitments = ids of OPEN COMMITMENTS that someone said on this call are done, sent or finished ("done", "sent", "зроблено", "надіслав"), about that same item.
- Closing: A detected close is only a proposal: the window shows a quiet card "Done? <item>" with Mark done; only the PM's click closes it (done, source detected). Nothing closes by itself.
- Export: Copy as text only. No tracker integration (no Jira in the app).
- Order: overdue first, then items with a due date (soonest first), then the rest (newest first)

**Brief freshness.** Brief freshness (Pacenote 0.8, idea 03). Shared by the skill and the app. Nothing runs by itself: the PM presses Refresh.
- Prepared at: The time the preparation was made: prepared_at in <stem>.prep.json when it exists, otherwise the creation time of <stem>.brief.md (an edit by the PM does not make a brief fresh).
- Changes: Files in the project folder (and the folders added in the call form) changed after prepared_at, except the paths below. Each file counts once.
- Stale rule: A brief is stale when at least one change happened since prepared_at, or it is older than stale_after_hours and the call is a different day.
- Label: Brief is <age> old · <n> changes since
- Refresh: Refresh = an incremental update: Claude gets the old brief and the list of changed files, reads only those, and rewrites only the sections they change. The checklist and the PM's edits stay. The facts and cards follow the same changes. It never starts by itself.
- Snapshot: After a preparation or a refresh, write <stem>.prep.json: {"prepared_at": "<ISO time>", "by": "app|skill", "refresh_of": "<ISO time of the previous one, or empty>"}.
- Ignored paths: `live/`, `.livetips-index/`, `.git/`, `node_modules/`, `.DS_Store`, `Tools/`; hidden files ignored: yes; stale after 24 h.
