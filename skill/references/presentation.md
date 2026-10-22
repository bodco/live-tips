# live-tips module: Presentation

Read when `call_type=presentation` is set (at the start or by `@@SET`). Two parts: the
outline file written in Step 2b, and the live rules of Step 3.

**Presentation outline (`<transcript name>.outline.json`, presentation only).** A JSON
object `{"sections": [...]}` with 5-15 sections in speaking order:
`{"id": "s3", "title": "Demo: reports", "points": ["Open the monthly report", "Filter by company", "Export to Excel"], "keywords": ["report", "звіт", "filter", "фільтр", "export", "експорт"]}`.
`title` max 6 words, 2-4 `points` of max 8 words in the call language (what to say, not a
script), 4-10 `keywords` the PM will actually say in that section. The recorder follows the
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
   Next. Read the position with `grep '"outline_pos"' "<tips_file>" | tail -1` in the same
   device_bash call as a poll, when needed.
3. **Look-ahead in pauses.** When the position moves to section N, rewrite section N+1
   (and N+2 if time allows) in `outline.json`, read-modify-write, keeping `id` and
   `keywords`: drop points already said, add a one-line bridge from what the PM actually
   said, add the answer to a question the audience asked, add one fact from the fact book.
   The recorder reloads the file and the window updates Next. Max one rewrite per section.
4. **No interrupting tips** while the PM speaks: no comment, initiative or answer-check
   tips. Allowed: 📌 facts and cards on audience questions (local), a 🟠 `answer` with one
   phrase to a direct question, the time check at 2/3 and 5 minutes before the end
   ("Лишилось {N} хв, ще {K} розділів: {які пропустити}").
5. If the PM leaves the outline and improvises, do not force it back; the tracker catches
   up when the PM returns to a section's words.
