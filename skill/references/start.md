# live-tips module: Start details (paths, project, meeting, languages, Whisper prompt)

Read at the start of every call, before `lt start`. The core SKILL.md has the start checklist; this file has the details behind each step.

## Paths

| What | On the Mac | Inside device_bash |
|---|---|---|
| Tool root | `{tool_root}` | `$HOME/mnt/<basename of the tool_root folder>` if only the tool folder is connected, else `{tool_root}` with `{work_root}` replaced by `$HOME/mnt/<basename of work_root>` |
| Project folder | `{config.project_root}` | same replacement; check `ls $HOME/mnt/` to see what is mounted |

`work_root` and `tool_root` come from `settings.paths`. `project_root` comes from the
project config `Local Paths`. Missing: use the parent of `repos_root` / `reports_root`,
else `{work_root}/{project_name}` if it exists, else ask. If the tool folder is not mounted,
call `device_request_folder_access` for the tool root (one request, with a reason), do not
wait for the user to find the button.

**Live Tips app on the same call.** The macOS app can record the same call next to this skill
(for a fair comparison, or as a backup). It runs its own recorder from its own app folder and
writes only `<stem>.app.*` files (`2026-10-22-1500-team-daily.app.md`, `.app.md.tips.jsonl`), so
the two never share a transcript, control or state. Never read, edit or delete the `.app.*`
files during the call. `<app folder>/bin/lt status` shows the app's recorder the same way
`lt status` shows this one. Both recorders run Whisper, so expect about twice the CPU and memory.

## Step 0 - Project and meeting

1. **Project.** Slug from the request, or from the instructions of the claude.ai Project
   this session is attached to when they name the slug explicitly (for example
   "Проєкт: Acme Portal (slug: acme-portal)"). That counts as explicit. Otherwise ask, listing
   configs in `projects/` (Default Project Rule).
2. Read `../projects/{slug}.md` (fallback: Glob `**/projects/{slug}.md`), the `PM Profile`
   and `projects/_standards.md` section 5 (agendas).
3. **Meeting: audience, type, title, length (concept since v36).** Two axes, both `auto` by
   default; the PM never has to pick anything to get a useful call.
   - **Audience** (`audience`): who is on the other side. `team` (our own people; candid,
     Ukrainian by default), `client` (external client; English or the project's client
     language, 🔒 rules strict, culture lens on), `boss` (an internal project where the PM's own
     manager acts as the client: client rules for wording and commitments, Ukrainian by
     default, culture lens off), plus the interview roles below. `auto` = from the user's
     words, else the config Meetings Schedule slot within 30 minutes (its `Type`, for
     example "Client Weekly" is client, "Team Daily" is team), else the
     project config (`client_language`, internal project or not), and corrected live by the
     language and names heard. Never guess the project from the audience.
   - **Type** (`call_type`): `auto` (default) | `presentation` | `interview`. Only these two
     custom types need an explicit choice, because they need a special prep: a presentation
     needs the outline (`references/presentation.md`), an interview needs a role
     (`hiring_role` = `observer` | `coach` | `interviewer`, `references/hiring.md`; `coach` = the
     PM is the one being asked, the legacy value `candidate` maps to `coach`; the
     `coach` role may have no project: then the other side, an organisation or a person, takes its place). Words like "співбесіда",
     "інтерв'ю з кандидатом", "hiring" set `interview`; "моя доповідь", "презентація",
     "demo" set `presentation`. Legacy words and values map: status, standup, topic, working
     session, discussion -> `auto`; client -> `auto` + audience `client`; hiring -> `interview`.
   - **Mode** (only in `auto`, never asked): read_delta reports `@@MODE presenting` when the PM
     speaks most of the last 2+ minutes, else `discussion`. A round of updates (people
     reporting in turn, a daily or stand-up slot) is handled by the speech and the "Your
     turn" trigger; a deep dive into one point is just discussion. There is no separate
     "working session" type: any call can turn into one.
   - **Title** from the user's words or the schedule slot, else "<project> call". **Length**:
     default 60 min.
4. **Languages.** `me_lang` = the PM's main mic language on this call, `me_langs` = the
   languages the PM may switch to on this call (the mic picks only among them, so Ukrainian
   is never heard as Russian), `langs` = all languages expected on the call. Resolution order:
   1. the user's words ("сьогодні англійською", "будуть іспанською");
   2. `settings.languages.per_project.{slug}.{internal|client}`;
   3. `settings.languages.internal` or `settings.languages.client`, where `from_project`
      means the project config `client_language` (as an ISO code: English -> en).

5. **Fast start (default, `settings.start.mode: window`).** Speed first: the recording must
   start within ~20 s of the request, nothing said on the call may be lost to questions.
   - In chat ask ONLY what decides where the recording goes: the Project when it is not
     explicit (Default Project Rule), or the other side for a `coach` call when the
     words say it is one and do not name who will ask. One AskUserQuestion call, or none.
   - Everything else starts from defaults: audience and type per item 3 (`auto` when not
     settled), language from item 4, mic from `settings.audio.mic`, `proactive` from
     `settings.tips.proactive` (default `off`). Pass `"setup": true`, `call_type`, `audience`
     and `hiring_role` (when known) in the `lt start` JSON: the window shows them in its ⚙
     menu and the PM corrects them during the call. Language and mic are applied by the
     recorder itself at once (a `--- мова: ... ---` / `--- мікрофон: ... ---` line marks the
     switch, nothing is lost). Type, role, audience and proactive reach this skill as
     `@@SET call_type=...`, `@@SET hiring_role=...`, `@@SET audience=...`,
     `@@SET proactive=...`: ack each one (core, "@@ lines") and rebuild the speech or prep for
     the new setting at once, keeping everything already said.
   - The start message names the defaults in one line and says "змінити можна в ⚙︎ у вікні".
   - **Orientation (item 6).** The PM can steer the preparation with one line at the start
     or at any moment of the call: the **format** ("обговорення" / "discussion",
     "моя доповідь" / "презентація" / "presentation", "статус", "клієнт", "з шефом") and **where to
     look** ("дивись епік X", "тред про Y", "документ Z", "слайди з цієї сесії", a ticket
     key). The format sets the type or the audience as if `@@SET call_type` / `@@SET audience` arrived; the named sources
     go first into the sweep and the fact book (they are a priority, not a limit). When the
     request names neither and the type is not settled, the start message adds one line:
     "Формат: обговорення чи моя доповідь? Куди дивитись (епік, тред, документ)?" The
     recording already runs; the PM answers in chat or in the window ask box. Never block on it.
   - A **prep ahead** makes the start instant: "підготуй live tips до {дзвінок}" (any time
     before the call) runs Step 0 and Step 2 without recording and saves the brief as
     `<project_root>/live/prep-<YYYY-MM-DD-HHMM>-<title>.brief.md`. At the start, a prep brief
     of the same project (or the same other side for `coach`) younger than 3 hours is reused: no sweep, the speech
     and tips are ready from the first second. Say "Бриф з підготовки {час} підхоплено".
   `settings.start.mode: chat` keeps the start questions (module `references/start-chat.md`).

   After the start, check `logs/audiocap-mic.log`: if `frames=0` repeats or `mic restart`
   lines pile up, tell the user at once and offer to restart with `default`.

## Step 1 details


**Helper `lt`.** `<tool_root>/bin/lt` does the mechanical procedures (start, status, stop,
prep check, state, wrap-up numbers). Call it inside device_bash as `python3 <tool_root>/bin/lt
<command> ...`; it maps Mac paths to the mounted folder itself and says plainly what failed.

1. Nothing to check by hand: `lt start` (item 3) checks the install, reuses a recording of the
   same project, refuses another project's recording (do not mix: tell the user), clears a
   stale status, and drops `ru` from the language lists.
2. Build `prompt` for Whisper: ONE short natural sentence in the main call language, max
   ~150 chars, with the key proper names and terms from the config (team, client, product,
   module names) plus `settings.user.name_aliases`, e.g. "Mike, Emily і John обговорюють
   Acme Portal, реліз і Jira." It improves spelling of names. Never start the prompt with a
   framing word ("Дзвінок ...", "Call about ...", "Зустріч ..."): on silence or noise Whisper
   echoes the opening of the prompt as a fake line ("Дзвінок по ..." with a garbled end).
   Start with the names. Not a bare comma list of names either: on silence Whisper repeats
   such a list back in a loop (live-transcriber drops those lines).
   The prompt MUST be in the language of the speech: a Ukrainian prompt on English speech
   turns it into Ukrainian gibberish. For an English call write an English prompt. Also
   give `prompt_en` and `prompt_uk` in `start.json`: when the window switches the language
   the recorder swaps to the matching prompt (or drops it for `en` if none).
3. Start: `python3 <tool_root>/bin/lt start '<json>'` with this JSON (one device_bash call):
   `{"project_dir": "<Mac path of project_root>", "title": "...", "slug": "...", "me_lang": "...", "me_langs": "xx+yy", "langs": "xx+yy+zz", "me_label": "...", "them_label": "...", "prompt": "...", "prompter": true, "mic_device": "default", "setup": true, "call_type": "auto|presentation|interview", "audience": "auto|team|client|boss", "proactive": "off|on", "hiring_role": "observer|coach|interviewer", "people": ["First Last", "..."]}`
   (`setup`, `call_type`, `audience`, `proactive`, `hiring_role` only in the fast start; omit unknown ones;
   `prompt_en` / `prompt_uk` are optional and allowed)
   (labels from `settings.user`; `prompter` = `settings.tips.output` is not `chat`;
   `mic_device` = `default` (the Mac's current input: AirPods, other headsets) or `builtin`
   (the Mac's own microphone). Take it from the answer to the start question (Step 0, item 5), else from the user's words ("з мікрофона маку", "mac mic",
   "на мікрофон ноутбука" -> `builtin`; "на навушниках" -> `default`), else from
   `settings.audio.mic` (`default` | `mac_mic`; missing = `default`). It cannot change during
   a call: to switch, stop and start again.)
   **Standby** (`"standby": true`): when the PM starts the skill ahead of the call ("запусти
   заздалегідь", "the call starts at 15:00", or more than 2 min before the calendar time), add it.
   The window opens at once, nothing is recorded and no mic or silence warnings show; recording
   starts when the other side speaks for about 5 s (`standby_auto_s`) or the PM presses the green
   Start in the window (or `touch <tool_root>/control/go`). The last 20 s before the start are kept.
   `lt start` then returns `result` = `standby`: tell the PM one line ("Window is ready, recording
   starts when the call begins") and begin polling as usual; nothing arrives until the start.
   The LaunchAgent opens a Terminal window "Live transcriber" with the recording by itself;
   the PM does not start it, may minimise it, should not close it.
4. `lt start` waits up to 60 s (model load 5-20 s) and prints JSON: `result` = `recording`,
   `standby` or `reused` with `file`, `local_file`, `tips_file`, `inbox_file` (already device_bash paths),
   `started_at`, `timezone` -> go on with them. `NOT INSTALLED` -> tell the user to run
   `install.sh` once in Terminal and stop. `BUSY` -> tell the user, do not mix. `START FAILED`
   -> it already parked `start.json` as `.pending` and printed the log tails: show the cause in
   one line and the fix it names.
5. **Keepalive marker.** Right after `recording`, write the marker with the cloud `Bash`
   tool (this session's own environment, NOT device_bash):
   `mkdir -p ~/.live-tips && python3 -c 'import json,time; json.dump({"until": time.time()+60*(<tips.hard_cap_minutes>+30), "title": "<title>", "state_file": "<state file path>", "max_blocks": 400}, open("'$HOME'/.live-tips/keepalive.json","w"))'`.
   If the session has no `Bash` tool, skip it.
6. One `SendUserMessage` (NOT a final answer, see LOOP DISCIPLINE): `Запис іде: {file name}. Мови: я {me_langs or me_lang}, дозволені {langs}. Мікрофон: {навушники або системний за замовчуванням | мікрофон Мака}.` With the tips window on, add `Підказки у вікні-суфлері.` Do NOT wait for the brief: go to Step 2 right away, and keep the loop alive.
