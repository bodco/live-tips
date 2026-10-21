# live-tips module: Culture lens (client and cross-cultural calls)

Read at the start when the audience is `client` (or turns into `client` by `@@SET audience`),
and the project config has a `## Cultural Profile` section (Erin Meyer's Culture Map: our
team's culture, the client's culture, and per-person calibration). With audience `team` or
`boss`, or with no profile in the config, skip this module.

**Prep (in the sweep subagent, part of the brief).** Copy into the brief a section
`## Culture lens` of max ~12 lines: the 3-4 scales where the distance between our culture and
the client's is largest (for example communicating, evaluating, disagreeing, trusting), what
each means for wording on THIS call, and per attendee who will be on the call (names from the
schedule, the user's words or the first minute of the transcript) their calibration line and
behavioural tells (for example "switches from warm to formal = escalation"). Facts only from
the config; never stereotype beyond what the config says.

**Live, in the main loop (no extra agent, no delay).**
- **Wording.** Every ready phrase for the client follows the lens: with a high-context,
  indirect-feedback client soften disagreement ("I see the point. One thing we should check
  is ..."), never blame, keep warmth in the first sentence; with a direct client be short and
  explicit. The gist line stays as usual.
- **Signals.** A downgraded complaint ("a bit concerning", "maybe we could consider", "un
  poco") from a person the lens calls indirect is a real problem: 🟠 "Сигнал: {що насправді}"
  with one acknowledging phrase. A tell from the lens (a warm person turns formal, silence
  after a proposal, a question repeated) -> 🟠 "Тон змінився: {хто}" with a phrase that
  checks in ("Does this work for you, Maria?"). One signal tip per person per 10 minutes.
- **Small talk is business** for relationship-based cultures: never steer back from it in the
  first minutes; offer a warm one-line reply when the PM is asked something personal.

**Background tone read (optional, client calls of 20+ minutes, needs the Workflow tool and
`tips.research` on).** Every ~10 minutes, in a quiet poll, start ONE background job (same
mechanism and limits as `references/research.md`, counts toward `max_jobs`) with the last 10
minutes of the transcript and the culture lens: it returns max 3 lines: the client's mood
now (with the quote that shows it), what is likely unsaid, and one phrase to address it.
Deliver as one 🔵 item "Тон клієнта" only if it adds something the signals above did not.

**Wrap-up.** Add a line "Сигнали клієнта" to Step 4 (quotes with times, the lens reading) so
the client-satisfaction-tracker skill can use them later; never score satisfaction here.
