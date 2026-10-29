# live-tips module: Presentation

Read when `call_type=presentation` is set (at the start or by `@@SET`). Two parts: the
outline file written in Step 2b, and the live rules of Step 3.

**Presentation outline (`<transcript name>.outline.json`, presentation only).** A JSON
object `{"sections": [...]}` with 5-15 sections in speaking order:
`{"id": "s3", "title": "Demo: reports", "points": ["Open the monthly report", "Filter by company", "Export to Excel"], "keywords": ["report", "звіт", "filter", "фільтр", "export", "експорт"], "numbers": ["12 reports/month", "2.4 s export"]}`.
`numbers` (optional, up to 6) are the figures the PM says in this section; the window shows
them in one bold line on the Now card (and on the slide card from `slides.json`).
`title` max 6 words, 2-4 `points` of max 8 words in the call language (what to say, not a
script), 4-10 `keywords` the PM will actually say in that section. Only `keywords` are matched
(not title or points), so pick words unique to the section: a keyword shared by many sections
counts little. Add `"slides": [12, 16]` (or end the title with "12-16") to tie the section to
`slides.json`, and `"who": "other"` for a colleague's section (or let all its slides be `other`). The recorder follows the
PM's mic lines through the sections and the window pins **Now** (the current section with
its points) and **Next** (the next one), see "Presentation mode".

### Presentation mode (`call_type=presentation`)

The PM speaks most of the time; the job is to keep the PM on track and ready for the next
part, not to interrupt.
1. **Start.** Build `outline.json` (Step 2b) from the focus sources: the speech or deck the
   PM gave, the slides made in this session, the notes. Emit a short `speech` item (the
   section titles only); the Now / Next box carries the details.
2. **Tracking is local.** The recorder follows the PM's mic lines through the sections and
   writes `kind: outline_pos` (`cur`, `next`) into the tips file; the window pins Now and
   Next. Since 2026-10-23 the tracker is plan-aware: the current and next section are
   preferred, a far jump needs a clearly stronger match, going back needs two matches in a
   row, the planned time per slide is a weak hint, and a colleague's sections (`who: other`)
   are followed from the other side's lines, the PM's sections from the mic only.
   Read the position with `grep '"outline_pos"' "<tips_file>" | tail -1` in the same
   device_bash call as a poll, when needed.
3. **Look-ahead in pauses.** When the position moves to section N, rewrite section N+1
   (and N+2 if time allows) in `outline.json`, read-modify-write, keeping `id` and
   `keywords`: drop points already said, add a one-line bridge from what the PM actually
   said, add the answer to a question the audience asked, add one fact from the fact book.
   The recorder reloads the file and the window updates Next. Max one rewrite per section.
4. **No interrupting tips** while the PM speaks: no comment, initiative or answer-check
   tips. Allowed: 📌 facts and cards on audience questions (local), a 🟠 `answer` with one
   phrase to a direct question, the time check at 2/3 and 5 minutes before the end
   (since 0.8.5 the recorder writes it, see 7; do not write your own time tips).
5. If the PM leaves the outline and improvises, do not force it back; the tracker catches
   up when the PM returns to a section's words.
6. **Quiet local layer during the PM's block** (recorder since 2026-10-23, `call_type=presentation`):
   no keyword 📌 facts and no "❓" cards unless a line has "?" (and the PM's name for "❓");
   semantic facts only on questions. On the real presentation 28 keyword facts fired during
   the colleague's talk and 71% scored 1-2.
7. **One time line, about the PM's own slides only** (`rules/presentation.yaml` > time_line,
   time_advice; the app follows the same rule). The recorder writes it itself every 60 s when
   `slides.json` has `sec` budgets (`kind: timeline`, "⏱ 9:40 з 25:00 · відстаєте 1 хв", with the
   fields `plan`, `elapsed`, `behind`, `slide`, `advice`), shown under Now. Behind = how late the
   current slide started plus its overrun. The advice is added to the same line, updated in place,
   never as new cards: when the slide changes and the PM is 1 min or more behind, and at two thirds
   of the plan and 5 minutes before its end. It names the fewest not yet reached PM slides with
   `"skip": true` whose budgets cover the time behind ("Пропустіть слайд 10, щоб наздогнати"); when
   they do not cover it, the longest not yet reached PM slides, at most 2 named ("Слайд 6: скажіть
   лише «{short}»"). Never about a colleague's slides, never during a colleague's block. Do not
   choose slides to skip yourself: the line already carries the advice.
7a. **Moving between slides (sync B).** The tracker never moves on its own to one of the PM's
   slides: it writes `kind: move_ask` ("Перейти до слайда N?") and the window answers with Enter
   (yes) or Esc (no) through the inbox (`slide_move`). A colleague's block is followed from the
   other side's lines without asking. Previous / Next in the window send `slide = <n>`, "+30 s"
   sends `slide_add30 = <n>`. The app can also follow Keynote or PowerPoint (sync A, app only).
8. **Numbers on the slides.** `slides.json` carries, per slide, the numbers the PM will say
   (`"numbers": ["840 680 UAH", "63 h"]`) and the 1-2 questions this slide usually raises with
   the answer (`"qa": [{"q": "...", "a": "...", "keywords": ["...", "..."]}]`, the answer with
   its number, 3-5 keywords the asker will say). The prep writes both for every PM slide. The
   window shows the numbers in Now; when the other side asks ("?" or a question word) and 2
   keywords match (or 1 of 6+ letters), the recorder shows a local 🟠 "❓ {q}" card with the
   answer at once (each entry at most once per 2 min). The PM garbled a number from his own slide and skipped the hours figure on the
   real call: the slide text alone does not help, the numbers must be on the Now card.
8a. **Slides that can go.** When you write `slides.json`, set `"skip": true` on 1-3 of the PM's
   slides that matter least for the goal of the call, and `"short"`: one sentence each PM slide can
   be reduced to. Keep `"edited": true` on slides the PM changed: on a new preparation leave them
   as they are unless the PM asks to rewrite everything (one previous version is kept as
   `<stem>.slides.prev.json`). Old files without these fields stay valid.
9. **Rehearsal results go back into the files.** After a rehearsal wrap-up ("+3.5 min",
   "slide 38 not reached", a decision not to ask for decisions today) rewrite `slides.json`
   and the brief at once, in the same session: the real call on 22.10 ran on an unchanged
   plan although the rehearsal had found both problems.
8b. **An attached deck (app: Start call > Presentation; skill: a deck file the PM names).** Read the slide
   texts (the app gives `<base>.deck.json`: `slides[{n, title, text}]`), write one `slides.json` entry per deck
   slide with the deck's numbering, keep `who`/`speaker` exactly as the PM set them (`me`, `shared` for "All", `other`
   with the colleague's name), and fit all `sec` budgets into the talk time (call length minus Q&A; top-level
   `talk_min`, `qa_min`, `speakers`). Prepare again keeps one previous version (`<base>.slides.prev.json`) and, with
   "Keep my edits", leaves slides with `"edited": true` as they are unless their deck text changed
   (rules/presentation.yaml > prepare_again).

10. **Handoffs between two presenters** come from `slides.json` `who`: when the position
   moves to a slide whose `who` is `me` after a colleague's block, pin the PM's entry
   sentence as a 🔴 card BEFORE the handoff (the colleague's last slide), not on hearing
   the name: the handoff cues were never said as scripted and ASR wrote the name as "Body".
   The recorder does this itself: when the tracker reaches the colleague's section that ends
   right before a `me` slide, it shows once a 🔴 "🎤 Твій вихід: слайд {n} {title}" card with
   the first read-aloud line of that slide.
