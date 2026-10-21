# live-tips module: Tips window protocol, language switching, the PM's questions, context refresh

Read once early in the call (in a quiet poll after the speech), and again when an `@@SET`, `@@ASK` or rating arrives whose handling you do not remember.

### Tips window (settings.tips.output)

- `window`: tips go only to the window; the chat gets the start message, health warnings
  and the wrap-up. `both` (default): window and chat. `chat`: no window, as before. A missing
  `tips.output` (older settings.yaml) means `both`.
- One tip = one JSON line (UTF-8, `ensure_ascii` not needed):
  `{"t":"HH:MM:SS","kind":"tip","level":"red","gist":"🔴 Нова вимога. Не погоджуй зараз.","phrase":"Good idea. I will write it down.","items":["..."],"note":"рішення від 30.09"}`
  - `kind`: `tip` | `answer` (reply to a window question, add `"q":"<the question>"`) |
    `checklist` | `speech` (the PM's theses, Step 2a; `phrase` = the opening sentence,
    `items` = the theses, group names go in the items as plain lines) | `status` | `wrapup` |
    `agenda` (see below); the recorder itself writes `card` items (instant cards);
  - **`src` is required on every tip and answer**: the `HH:MM:SS` of the transcript line that
    triggered it (for an answer: the time of the question). `read_delta` stamps `at` (when it
    landed); the window shows the difference on the card ("+18s", orange over 20 s) and a
    rolling median in the status line. The wrap-up and the hiring analysis report the
    median and max of `at - src`.
  - `level`: `red` | `orange` | `info`; `gist` keeps its emoji;
  - `phrase` without quotes (the window adds them), `items` for numbered points, `note`
    for the source; omit empty fields. The same "Tip format" rules apply.
- **Agenda strip** (`kind: agenda`): `{"kind":"agenda","gist":"<title>","items":[{"text":"Release date","done":true},{"text":"New export request","done":false}]}`.
  Emit it once the checklist is known (Step 2: the checklist; hiring: the planned or likely
  questions; standup you lead: the people to hear from) and again, whole, each time an item
  becomes covered. Max 8 items, ~30 characters each. It replaces the previous strip.
- **Quick asks** (window buttons) arrive as `@@ASK`: `catch me up` -> `kind: answer`, 3-5 lines
  on the last ~5 minutes (who said what, what is open); `what was decided` -> decisions and
  action items so far with owner and date ("не зафіксовано" where missing); `what to ask
  now` -> 1-2 ready questions for the open points; `suggest a reply` -> what the PM can say
  right now on the topic being discussed (the last ~2 minutes), even with no direct
  question yet: a 🟠 `answer` with gist "Можеш сказати: {тема}" and 1-2 ready phrases in
  `answer_lang`, each a different move (an answer to the question that is coming, a fact
  from the Insight Bank or a card with its number and source, a clarifying question, a next
  step with an owner); never a date, estimate or scope commitment; if the topic is not
  clear from the tail, say what was heard and give the most useful generic move. Answer from the transcript tail and state
  only, no lookups, in the next poll call (target under 10 s).
- **Tip rating** (✓ / ~ / ✕ on a card) arrives as
  `@@SET tip_feedback=<verdict>|<card id>|<t>|<gist>[|r=<reasons>|c=<comment>]`, verdict
  `used` | `partly` | `not_useful`. After ~ or ✕ the window offers reason chips and a short
  comment, so the same tip may arrive several times: the LAST line for the same
  `<card id>|<t>|<gist>` wins. Reasons (comma separated, may be empty): `late`, `off_topic`,
  `wrong_fact`, `too_long`, `not_now`. `read_delta` also logs every rating to
  `<transcript name>.feedback.jsonl`, so nothing is lost if state is trimmed. Log it in state
  (`feedback`) and act by the reason, not by the verdict alone:
  - `late`: no change to the topic; the tip joins the late analysis (Step 6);
  - `too_long`: shorter tips of that kind for the rest of the call, same topics;
  - `not_now`: nothing changes;
  - `wrong_fact`: check the fact at once (narrow lookup), fix it in `facts.json`, the cards
    and the brief; if the fact was right, keep it and note the doubt for Step 6;
  - `off_topic`: two on the same card or the same kind of tip -> that card off / that kind
    less often for the rest of the call;
  - no reason: treated as `not_now` for a ✕ or `partly`; it never mutes anything.
  - **The comment wins over the chips.** Read it as the PM's words ("part A useful, part B
    off"): keep what it says was useful, drop or fix only the part it names, and log it in
    `pm_notes` for Step 6. Never mute a topic because of a comment that praises part of it.
  📌 facts and 🔴 tips are never muted during the call, whatever the rating. The wrap-up
  lists counts: shown, rated ✓, rated ~, rated ✕ (with reasons), cards fired, 📌 facts shown (`grep -c '"kind": *"fact"'` in the tips
  file), late tips (`<transcript name>.late.jsonl`), fact searches sent to Claude (`find:` asks), and the facts
  that were asked for but missing from the book (add them to the next prep).
- **Talk meter** (status `talk_me_pct`, `monologue_s`, also in `@@STATUS` as `talk_me=`,
  `mono=`): the window shows it to the PM. Tip only on a client call or when the PM leads,
  when the PM's monologue passes ~2 minutes and a question from the other side is waiting:
  🟠 "Дай слово: {хто / питання}". Never in an interview where the PM is the candidate.
- `@@ASK` lines are the PM's questions or comments typed in the window: treat them exactly
  like chat messages during the loop (answer first, briefly), and send the answer back to
  the window as `kind: answer` (and to the chat too in `both`). "стоп" typed in the window
  stops the call like in the chat. "онови спіч" regenerates the speech (`references/speech.md`).
- **`@@ASK find: <query>`** (Enter in the input after the local fact search found nothing useful).
  Search the fact book first, then the local semantic index of the project folder (it
  includes the local Notion mirror): `python3 <tool_root>/bin/lt search "<query>" --root
  <project_root> -k 5 --json` (relayed through the running recorder to Ollama; plain text
  search with a `NOTE:` line when Ollama is off), then ONE narrow lookup (a tracker search by
  the words, or the brief and Insight Bank). Answer as `kind: fact` with gist "📌 {title}" and one item
  "{title}: {numbers}" plus the source in `note`, or "Не знайшов: {query}" with where you
  looked. Append the found fact to `facts.json` (read-modify-write) so the next search is
  instant. Target under 15 s; a long lookup goes to the background research team.
- **"фокус: X" / "focus: X"** (chat or window): the PM tells where to look now. Start one
  background research job (not blocking) for X: all tracker tickets matching X with
  estimates, status, assignee, dates; decisions; the named document or thread. Merge the
  results into `facts.json` (keep ids unique, newest wins) and into the cards for X, then
  emit one `info` item "📌 Факти по {X}: +{N}". Format words ("обговорення",
  "презентація") in the same line work as in `references/start.md`, Step 0 item 5 (Orientation).
- Keep `inbox_offset` in state next to `offset`.
- **Window layout (v36).** Top bar: recording dot, title, timer, talk share, `🎙` mute, `⚙`
  menu. One alert slot under it (the most important warning only, with an action button
  such as "Use Mac mic"). Dock: the agenda as one line with progress (expands on click),
  Now/Next in a presentation, then pinned cards (📌 on any tip, the speech, the checklist,
  the status and the wrap-up; an unpinned card returns to its place). Bottom row: one input
  (typing searches the fact book locally, Enter sends the text to Claude as `@@ASK`),
  ⏸/▶ pause or resume tips (`@@SET tips_paused=on|off`) and 🆘 HELP NOW (`@@SOS`), plus the
  quick-ask chips. A slim line under the top bar shows who is speaking now (from the voice
  clusters: a name or "Speaker 2"); clicking it renames the speaker, fixes one line or merges
  two speakers. A "Who is speaking?" card asks for a name once a new voice has ~8 s of speech,
  with suggestions from the local voice library and the project people; the PM decides, never
  the skill. ⚙ Display also holds the interface language (English by default | Українська,
  `@@SET ui_lang`) and Stealth (on by default: the window is hidden from screen sharing and
  screenshots; off lets colleagues see it). The quick asks always arrive in English
  ("catch me up", ...) whatever the interface language.
  The ⚙ menu holds everything else: Call (Type, Role, Audience, Language, Mic, Proactive
  tips, Comment rate when proactive is on), Display (text size slider, Cmd+ / Cmd-,
  opacity, always on top), Context ("Brief from HH:MM" + Refresh, which sends
  `refresh context`), Diagnostics (the old footer) and Help.
- `🎙` is the mic mute: the PM is muted in the meeting
  (cafe, music, people around), so the recorder stops transcribing the mic. `@@STATUS` shows
  `mic=muted`, and the transcript gets `--- мікрофон вимкнено HH:MM:SS ---` and
  `--- мікрофон увімкнено HH:MM:SS ---` lines. While muted: expect no `{me_label}` lines,
  skip the answer check for that time and the `mic=silent` warning; other tips go on. A 🔴
  "Your turn" while muted starts the gist with "Увімкни мікрофон." Treat a `{me_label}`
  line right after an unmute as a normal reply.
  While muted (and while `mic=stalled`) the skill cannot hear the PM: never claim that the
  PM has not reported yet or that their turn is still ahead. In a status round, if the PM may
  have spoken while unheard, ask once in the window ("Ти вже звітував?") instead of guessing.
- **Settings from the ⚙ menu** arrive as `@@SET call_type=` (`auto` | `presentation` |
  `interview`), `@@SET hiring_role=`, `@@SET audience=` (`auto` | `team` | `client` |
  `boss`), `@@SET proactive=` (`on` | `off`), `@@SET comment_rate_seconds=N` (only matters
  with proactive on; overrides `settings.tips.comment_rate_seconds`, `0` = off),
  `@@SET call_lang=` (`uk` | `en` | `mix`) and `@@SET mic_device=` (`default` | `builtin`).
  **Ack every setting**: the window shows a pending pill until it is confirmed. `call_lang`
  and `mic_device` are confirmed by the recorder through the status echo. For `call_type`,
  `hiring_role`, `audience`, `proactive` and `comment_rate_seconds` (applied by you) emit in
  the VERY NEXT call, before any heavy work, a tip line
  `{"kind":"ack","key":"<key>","value":"<value>"}` (read_delta prints `@@DUE ack <key>` until
  you do). The recorder applies language and mic itself (the mic restarts on the new input
  in about a second; a `--- мова ---` / `--- мікрофон ---` line marks it). Then update
  `answer_lang`, the audience rules and the prep; when the language changes and a speech
  was already emitted, re-emit the speech in the new language. The red "Claude not
  listening" alert asks the PM to write "continue" in the chat: treat it like "продовжуй".
- The window may be closed or minimised by the PM; keep emitting, it does not matter.
- Reopen on request ("відкрий суфлер", "поверни вікно", "open the prompter"): `touch
  <tool_root>/control/prompter`. The recorder reopens the window within a second with all
  tips so far. Answer in the chat with `SendUserMessage`: `Суфлер відкрито знову.`

Then:

1. Store the new offset. Never re-read older lines; keep the last 3 lines as tail context.
2. Speakers: `{me_label}` = the PM (mic), `{them_label}` = everyone else (system audio). The
   language tag `(xx)` is per line. If the mic also picks up the other side (speakers, no
   headset), `{me_label}` lines may duplicate `{them_label}` lines or be Whisper noise like
   "Звучить музика": treat them as artefacts.
3. Match the new lines against the speech, the Live Brief, the Insight Bank and the triggers
   below, by meaning, across languages (a Spanish line can match a Ukrainian/English topic).
   Never react to Whisper artefacts that slipped through the filters (subtitle credits, a list of
   names repeated, one word repeated many times, "Звучить музика", short "Thanks" or "Mm-hmm"
   in a language the PM does not use): skip them silently. Whisper garbles product names
   (an unknown name may be a known tool): match against the Insight Bank before judging, and
   mark uncertain tips "(?)".
4. Mark in `theses_used` every speech thesis the PM has already said (by meaning, from the
   `{me_label}` lines). The speech tips only offer what is not used yet.
5. Deep lookup (Jira ticket, Notion page, a project document not yet in the Insight Bank) only
   when a trigger fires and the Insight Bank does not answer it. Max one per 2 min.
6. Post a tip if "Tip diet and rates" allows it: emit it to the window in the next read call and/or
   send it with `SendUserMessage`, per `settings.tips.output`. Otherwise produce no text and
   go straight to the next read.
7. Health from `@@STATUS`: `system=silent` for 2 polls while the call is on -> one message
   "Не чую співрозмовників: перевір дозвіл на запис системного звуку для Terminal";
   `mic=silent` likewise (never for `mic=muted`, never in hiring `observer`); `queue` > 6 -> "Транскрипція відстає на ~{queue} фраз";
   `errors>0` -> tail of `logs/transcriber.log`. Each warning once.
   **Mic stall (top priority, 2026-10-21).** `mic=stalled` means audiocap delivers no mic audio
   at all (the stream froze, typically after the PM unmutes in Meet; macOS gives no notice).
   The recorder restarts the mic by itself within ~12-20 s and writes
   `--- мікрофон завис, перезапускаю HH:MM:SS ---` into the transcript. On the first poll with
   `mic=stalled` or that marker: at once a 🔴 window item "Мікрофон не пишеться" with the phrase
   "Перезапускаю. Якщо за 20 с не повернеться: ⚙ Mic -> Mac built-in" and the same line via
   `SendUserMessage`; repeat on every new stall, not only once. Never trust `mic=ok` alone:
   it is computed from audio that did arrive. Cross-check: `system=silent` for 2+ polls while
   the call is on and no new `{me_label}` lines usually means the PM is talking and is not
   recorded -> check `tail -3 logs/audiocap-mic.log` (the `frames=` counter must grow) in the
   same device_bash call as the next poll (`python3 <tool_root>/bin/lt status` prints
   `mic_frames_growing=yes|NO` and a `WARN` part), and warn if it does not. The recorder
   writes ONE `--- мікрофон завис ---` line per episode and `--- мікрофон відновився після N
   перезапуск(ів) ---` when audio is back: say "Мікрофон повернувся" once then. After 3 failed
   restarts in a row the window itself advises ⚙ Mic -> Mac built-in. The wrap-up lists stall
   restarts (`mic_stall_restarts` in `state/status.json`) and the minutes of the PM's speech
   that may be missing.
  Garbled transcript: if 3+ system lines in a row are nonsense or gibberish in the wrong
  language, warn within the first minute (wrong Whisper language or prompt) and restart the
  recording with the correct language and a prompt in that language (tell the PM what was lost).

### Language of the moment

The call language can change mid-call, mostly on internal calls (Ukrainian and English). Keep `answer_lang` in state = the language the PM is expected to
speak right now; every phrase in a tip goes in `answer_lang`, the gist line always stays
in the tips language (SKILL.md, "Tip format", item 1).

- Start: `answer_lang = me_lang`.
- Switch when someone asks the PM to say or explain something in another language
  ("розкажи це англійською", "скажи по-английски", "can you say it in English", "for Mark
  in English please"), or when a question to the PM comes in a language of `me_langs` other
  than the current one (e.g. an English-speaking guest asks in English). Post at once a
  🟠 tip: gist in Ukrainian with what to say, phrase in the new language:
  > **🟠 Тепер англійською: статус релізу**
  > "Short update in English. The release is on track for Friday."
- Switch back when the PM's own lines return to the main language for 2+ lines, or the
  request is clearly answered.
- Russian is never used: drop `ru` from every language set read from `settings.yaml` or
  the project config before writing `start.json`. A Russian phrase is written as Ukrainian.

### The PM's questions during the call

If the user writes in chat during the loop, answer first with `SendUserMessage` (short, in the
same tip format, from the brief, the Insight Bank, state and transcript tail; a deep lookup is
allowed), then continue the loop from `offset` in the same step. "продовжуй" or "continue" resumes after an
interruption. A user complaint that tips are silent or generic is a signal to check at once:
is the loop running, is the Insight Bank loaded; fix it and say what was wrong.

**Context refresh during the call** (an unexpected call started without prep, or the talk
moved to something the brief does not cover). Triggers in the chat or the window: "онови
контекст", "refresh context", "підготуй бриф", "глянь мітинги / треди / доки", "що в нас по {тема}", the
window button 🔄 (arrives as `@@ASK [..] refresh context`). Then:
1. `SendUserMessage` / window item: "Оновлюю контекст ({фокус}), 1-3 хв. Запис іде, нічого
   не губиться." Emit pending tips first.
2. Run the sweep subagent (full source list of "Context sweep", or only the focus the PM
   named, plus the topics of the last ~10 minutes of the transcript so the brief matches
   what is being discussed right now). It updates `<transcript name>.brief.md` in place
   (merge, keep the speech and what is still valid) and returns the new and changed
   insights only.
3. One `read_delta` catch-up of everything said meanwhile, then tips that use the new
   insights for the topics still open. Note the refresh time in state (`context_refreshed_at`).
The keepalive hook keeps the turn alive during the subagent. Max one full refresh per 10
minutes; a narrow one ("глянь тред про X") any time.
