# live-tips module: Start questions (`start.mode: chat` only)

Part of Step 0, item 5 (`references/start.md`). Legacy flow: the answers map to the v36 concept (`references/start.md`, item 3): a schedule slot sets the audience and `auto`, `Співбесіда (hiring)` sets `interview`, `Інша тема` sets `auto` with that subject as the focus. Read only when `settings.start.mode` is `chat`.

   **Start questions (`start.mode: chat` only, in chat, before anything is written or
   started).** Ask with the AskUserQuestion tool, ONE call, in this order, and skip any question the user's words
   or the claude.ai Project instructions already answered:
   1. **Project** (only if not explicit, Default Project Rule): options = the configs in
      `projects/`, plus the workspace entries from `settings.workspaces`. The FIRST option
      is the first workspace entry from `settings.workspaces` (a general call about all
      projects of that workspace), when one is configured. Choosing a workspace entry is an
      explicit choice: no project guess happens. For a workspace entry: `project_root` =
      `settings.workspaces.<key>.project_root`; for a project slug in `settings.project_roots`,
      that path wins. The Live Brief then covers EVERY project listed in that entry (one brief
      section per project, each from its own `projects/{slug}.md`), and the Notion destination
      is the Meeting page the user names, else ask.
   2. **Call type** (skip when the user's words or the schedule slot in item 3 settled it):
      options = the `Type` values from the config Meetings Schedule (for example
      `Client Weekly`, `Team Daily`), plus `Співбесіда (hiring)` and
      `Інша тема` (the user names the subject in "Other"; it becomes the title and the focus
      of the brief). Max 4 options: keep the 2 schedule slots nearest to the current time.
      Mark as recommended the slot nearest to the current time. The answer sets the call kind
      (status, client, topic, hiring) and the title.
      **Hiring role.** When the user's words already say it is a hiring interview, ask
      instead of the call type: `Твоя роль на співбесіді` with options `Спостерігач`
      (observer), `Мене інтерв'юють` (coach), `Я питаю` (interviewer); "Other" = details.
      When `Співбесіда (hiring)` was picked as the call type, ask the role right after in a
      second AskUserQuestion call (the only case with two calls). The words settle the role
      when they say it ("я спостерігаю", "мене співбесідують", "я наймаю", "я інтерв'юю").
      **Company (role `coach` only).** When the role is or may be `coach` and the
      words do not name the company: before asking, query the Job Tracker
      (`settings.hiring.coach.job_tracker`, fallback `settings.hiring.candidate.job_tracker`) for rows with `Status` in `Recruiter screen`,
      `Interview`, `Final`, nearest `Next step on` first; ask `З якою компанією?` with up to 3
      of them (`Company` + `Vacancy`) as options, "Other" = free text. When the role is
      still unknown, put this question in the same call as the role and label it "(якщо
      мене інтерв'юють)". The Project question is skipped for `coach`. If the query tool
      fails, ask with "Other" only and find the row by name later.
   3. **Call language**: options `Українська` (me_lang `uk`, me_langs `uk+en`, langs `uk+en`),
      `English` (me_lang `en`, me_langs `en+uk`, langs `en+uk`), `Мікс` (main language and
      lists from the resolution order in item 4, which already default to a mix). Mark as
      recommended the option that matches the resolved default for this project and call kind.
      "Other" = free text: take the language(s) named there (for example Spanish) as the
      main language and add `uk` and `en` to `me_langs` / `langs`. Never offer Russian.
   4. **Microphone**: options `За замовчуванням` (`mic_device` `default`: the Mac's current
      input, headset or built-in) and `Мікрофон Мака` (`builtin`: the Mac's own microphone,
      even when AirPods or another headset are connected). Mark as recommended the option
      from `settings.audio.mic`.
   If `settings.start.ask` is `false`, do not ask the language and microphone questions:
   use the defaults and state them in the start message. If the AskUserQuestion tool is
   not available, or nobody is there to answer (scheduled run), use the defaults and state
   them. Meeting length is never asked: use the default.
