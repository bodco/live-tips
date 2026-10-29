# Pacenote 0.8.5 · Presentation, rehearsal, after the call

Макети: Claude Design canvas, розділ "0.8.5 · Presentation, rehearsal, after the call" (борди P1-P8). Статичні копії: `mockups-0.8.5/*.html`, відкриваються в браузері.
Кольори: v1.2 (`tokens/tokens.css`, `swift/PacenoteTheme.swift`). Кнопки лише `.b1` primary, `.b2` secondary, `.b3` tertiary. Жодних емодзі в UI.

## 1. Що на кожному борді

| Борд | Екран | Тема · мова | Головне рішення |
|---|---|---|---|
| P1 Present-form | Start call: Regular і Presentation | light EN, dark UK | Блок 1 (Title, Date, Time, Call type, Audience, Language) і блок 2 (Context) ніколи не рухаються. Секція типу завжди остання, тому зміна типу міняє лише її. |
| P2 Present-deck | Presentation block: not attached, attached, reading, error | light EN | Власник кожного слайда стрічкою мініатюр; bulk assign "slides 5-9 Ann"; "All" = спільний слайд; Talk time = тривалість мінус Q&A. |
| P3 Present-speech | Prep result, виступ слайд за слайдом | light EN, dark UK | Кожен слайд окрема картка; say, numbers, 1-2 Q&A, Can skip; слайди колеги згорнуті в одну групу; банер "26:30 of 25:00 · 1:30 over" з однією порадою. |
| P4 Present-again | Prepare again: ask, working, done | light EN, dark UK, light EN | За замовчуванням Keep my edits; Rewrite everything з можливістю Restore previous version. |
| P5 Present-tips | Tips window, presentation mode | light EN (sync A), dark UK (sync B) | Rail слайдів done/now/next, countdown слайда з +30 s, рядок Plan/Elapsed/Behind, одна тиха порада, що оновлюється на місці, числа жирним, Q&A card, Previous/Next, хоткеї. |
| P5 Present-states | Слайди колеги, ⋯ меню і порожній стан, compact | light EN, dark UK, light EN 380 px | На слайдах колеги підказок немає, лише handoff card перед вашим слайдом. Presentation mode завжди в ⋯ для типу Presentation. |
| P6 Rehearse | Точки входу, intro, run-through, question, result | light EN, dark UK | 3 видимі входи; нічого не записується; 4 питання від Claude у ролі клієнта; письмові відповіді; Apply to talk. |
| P7 After-call | Екран одразу після End call, Recent hover, пояснення серії | light EN, dark UK | Follow-up draft з Copy і Open in Mail, ніколи не надсилається сам; серія пояснена за правилом series_key (проєкт + назва). |
| P8 System-state | Not recording, Can't hear the other side | light EN, dark UK | Системний стан: червона смуга під заголовком, область підказок замінена, одна дія, жодних дій підказки. |

## 2. Нові рядки UI (EN · UK)

### Start call і Presentation block

| Key | EN | UK |
|---|---|---|
| start.date | Date | Дата |
| start.time | Time | Час |
| start.fromCalendar | From calendar · {app} | З календаря · {app} |
| start.callType | Call type | Тип дзвінка |
| start.type.regular | Regular | Звичайний |
| start.type.presentation | Presentation | Презентація |
| start.audience | Audience | Аудиторія |
| start.language | Language | Мова |
| start.context | Context | Контекст |
| start.regularHint | Tips follow the agenda, open questions and what is on you. Pick Presentation to attach a deck. | Підказки йдуть за порядком денним, відкритими питаннями і тим, що на вас. Оберіть «Презентація», щоб додати слайди. |
| deck.title | Presentation | Презентація |
| deck.attach | Attach presentation | Додати презентацію |
| deck.formats | PDF, PowerPoint, Keynote or a text outline. You can also drop the file here. | PDF, PowerPoint, Keynote або текстовий план. Файл можна перетягнути сюди. |
| deck.promise | Prepare reads the deck, writes your talk slide by slide, times each slide and the questions the audience may ask. | Prepare прочитає презентацію, напише ваш виступ слайд за слайдом, розрахує час кожного слайда і питання, які може поставити аудиторія. |
| deck.ready | Ready to prepare | Готово до підготовки |
| deck.meta | {n} slides · {format} · read {time} | {n} слайдів · {format} · прочитано {time} |
| deck.replace | Replace | Замінити |
| deck.remove | Remove | Прибрати |
| deck.reading | Reading slide {i} of {n} | Читаю слайд {i} з {n} |
| deck.readingHint | Keep filling the form. Slide owners and timing unlock when reading is done. | Заповнюйте форму далі. Власники слайдів і час стануть доступні після читання. |
| deck.err.title | Can't read {file} | Не вдається прочитати {file} |
| deck.err.keynote | Keynote isn't installed on this Mac, so the slides can't be opened. Export the deck as PDF and attach it. | Keynote не встановлено на цьому Mac, тому слайди не відкриваються. Експортуйте презентацію в PDF і додайте її. |
| deck.err.choose | Choose another file | Обрати інший файл |
| deck.pasteText | Paste the talk as text | Вставити виступ текстом |
| deck.speakers | Speakers | Доповідачі |
| deck.addSpeaker | Add speaker | Додати доповідача |
| deck.me | Me | Я |
| deck.all | All | Усі |
| deck.owners | Who presents each slide | Хто презентує кожен слайд |
| deck.ownersHint | Click a slide to change, or assign a range | Клацніть слайд, щоб змінити, або задайте діапазон |
| deck.assign | Assign | Призначити |
| deck.apply | Apply | Застосувати |
| deck.assignExamples | Also works: "1, 14 all", "10-13 me" | Також працює: «1, 14 усі», «10-13 я» |
| deck.allHint | "All" means a shared slide: tips show, nobody gets a handoff card. On {name}'s slides the tips window stays quiet and tells you when your turn comes. | «Усі» означає спільний слайд: підказки показуються, картки передачі слова немає. На слайдах {name} вікно підказок мовчить і скаже, коли ваша черга. |
| deck.duration | Duration | Тривалість |
| deck.custom | Custom | Свій час |
| deck.questions | Questions | Питання |
| deck.qaEnd | Q&A at the end | Q&A наприкінці |
| deck.talkTime | Talk time is {t}: {d} call minus {q} Q&A. Prepare times the slides to fit it. | Час виступу {t}: дзвінок {d} мінус {q} на питання. Prepare розподіляє час слайдів під нього. |

### Виступ слайд за слайдом і Prepare again

| Key | EN | UK |
|---|---|---|
| talk.window | {call} · Your talk | {call} · Ваш виступ |
| talk.title | Your talk, slide by slide | Ваш виступ, слайд за слайдом |
| talk.meta | {n} slides · you present {m} · {name} {k} · {s} shared · prepared {time} | {n} слайдів · ви презентуєте {m} · {name} {k} · спільних {s} · підготовлено {time} |
| talk.allSlides | All slides | Усі слайди |
| talk.mine | Mine only | Лише мої |
| talk.over | {total} of {plan} · {diff} over. | {total} з {plan} · {diff} понад план. |
| talk.fits | Now {total} of {plan} talk time. Fits. | Тепер {total} з {plan} часу виступу. Вкладаєтесь. |
| talk.showLong | Show long slides | Показати довгі слайди |
| talk.say | Say | Що сказати |
| talk.numbers | Numbers | Цифри |
| talk.canSkip | Can skip | Можна пропустити |
| talk.longest | longest | найдовший |
| talk.edited | Edited by you | Змінено вами |
| talk.colleague | {name} presents. No talk written for these slides, no tips during them. You get a "your turn" card before slide {n}. | Презентує {name}. Для цих слайдів текст не пишемо і підказок не показуємо. Перед слайдом {n} буде картка «ваша черга». |
| talk.saveHint | Edits save as you type. The tips window and rehearsal use this text. | Правки зберігаються одразу. Вікно підказок і репетиція беруть цей текст. |
| talk.prepareAgain | Prepare again | Підготувати знову |
| talk.rehearse | Rehearse | Репетиція |
| again.title | Prepare again? | Підготувати знову? |
| again.age | Brief is {d} days old · {n} changes since | Брифу {d} дні · з того часу {n} змін |
| again.deckChanged | The deck file changed | Файл презентації змінився |
| again.callLonger | The call is now {d} | Дзвінок тепер {d} |
| again.keep | Keep my edits | Зберегти мої правки |
| again.keepHint | Slides you edited ({list}) stay as they are. The rest is rewritten. | Слайди, які ви змінили ({list}), лишаються як є. Решту переписуємо. |
| again.rewrite | Rewrite everything | Переписати все |
| again.rewriteHint | Your edits on {n} slides are replaced. You can restore them after. | Ваші правки на {n} слайдах буде замінено. Їх можна відновити. |
| again.working | Updating the talk · slide {i} of {n} | Оновлюю виступ · слайд {i} з {n} |
| again.workingHint | Your edits on slides {list} stay. While updating, these slides can be read, not edited. | Ваші правки на слайдах {list} лишаються. Поки йде оновлення, ці слайди можна читати, але не редагувати. |
| again.stop | Stop | Зупинити |
| again.updated | Updated | Оновлено |
| again.yours | Your edits | Ваші правки |
| again.writing | Writing… | Пишу… |
| again.queued | Queued | У черзі |
| again.done | Talk updated · {n} slides rewritten, {k} kept with your edits | Виступ оновлено · переписано {n} слайдів, {k} з вашими правками |
| again.review | Review changes | Переглянути зміни |
| again.restore | Restore previous version | Відновити попередню версію |
| again.newText | New text | Новий текст |
| again.kept | Your edits kept | Ваші правки збережено |

### Вікно підказок, presentation mode

| Key | EN | UK |
|---|---|---|
| pm.slides | Slides | Слайди |
| pm.slideOf | Slide {i} of {n} | Слайд {i} з {n} |
| pm.you | You | Ви |
| pm.left | left on this slide | лишилось на слайді |
| pm.overSlide | over slide time | понад час слайда |
| pm.add30 | +30 s | +30 с |
| pm.plan | Plan {t} | План {t} |
| pm.elapsed | Elapsed {t} | Минуло {t} |
| pm.behind | Behind {t} | Відставання {t} |
| pm.ahead | Ahead {t} | Випереджаєте на {t} |
| pm.adv.skip | Skip slide {n} to catch up. It is marked as can skip. | Пропустіть слайд {n}, щоб наздогнати. Його позначено «можна пропустити». |
| pm.adv.shorten | Shorten slide {n} to one sentence to catch up. | Скоротіть слайд {n} до однієї фрази, щоб наздогнати. |
| pm.updated | updated {t} | оновлено {t} |
| pm.asked | {name} asked | {name} питає |
| pm.hide | Hide | Сховати |
| pm.now | Now · {n} | Зараз · {n} |
| pm.next | Next · {n} · {owner} | Далі · {n} · {owner} |
| pm.nextColleague | After this slide {name} presents {range}. Tips go quiet until slide {n}. | Після цього слайда {name} презентує {range}. Підказки мовчать до слайда {n}. |
| pm.prev | Previous | Назад |
| pm.nextBtn | Next | Далі |
| pm.syncA | Following {app} · slide {n} | Слідую за {app} · слайд {n} |
| pm.stopFollowing | Stop following | Не слідувати |
| pm.syncB.ask | Move to slide {n}? | Перейти до слайда {n}? |
| pm.syncB.why | You are already talking about {topic}. | Ви вже говорите про {topic}. |
| pm.syncB.go | Move | Перейти |
| pm.syncB.no | No | Ні |
| pm.syncB.label | Slides follow your speech · asks before moving | Слайди за вашою мовою · питаю перед переходом |
| pm.colleague | {name} is presenting | Презентує {name} |
| pm.colleagueHint | Tips stay quiet while {name} speaks. Questions to you still get an answer card. | Поки говорить {name}, підказки мовчать. На питання до вас картка з відповіддю все одно зʼявиться. |
| pm.turnIn | Your turn in about {t} | Ваша черга приблизно через {t} |
| pm.turnNext | Your turn next · slide {n} | Далі ви · слайд {n} |
| pm.startWith | Start with: "{line}" | Почніть з: «{line}» |
| pm.menu.mode | Presentation mode | Режим презентації |
| pm.menu.compact | Compact view | Компактний вигляд |
| pm.empty.title | No presentation attached | Презентацію не додано |
| pm.empty.text | Attach a file and Pacenote shows the slides, the time for each and answers to questions. Until then, tips work as on a regular call. | Додайте файл, і Pacenote покаже слайди, час кожного слайда і відповіді на питання. Поки файлу немає, підказки працюють як на звичайному дзвінку. |

### Репетиція

| Key | EN | UK |
|---|---|---|
| reh.window | Rehearsal · {call} | Репетиція · {call} |
| reh.title | Rehearse your talk | Відрепетируйте виступ |
| reh.meta | About {t}. Nothing is recorded: no audio, no transcript. | Приблизно {t}. Нічого не записується: ні звуку, ні транскрипту. |
| reh.step1 | Run through your slides out loud. | Пройдіть свої слайди вголос. |
| reh.step1Hint | Each slide has a timer. Press Next when you finish. You present {n} slides, {name}'s are skipped. | У кожного слайда свій таймер. Натисніть «Далі», коли закінчите. Ви презентуєте {n} слайдів, слайди {name} пропускаємо. |
| reh.step2 | Answer 4 hard questions. | Дайте відповідь на 4 складні питання. |
| reh.step2Hint | Claude plays the client, {name}, and asks what this audience is likely to ask. | Claude грає клієнта, {name}, і питає те, що ймовірно спитає ця аудиторія. |
| reh.step3 | Type your answers. | Напишіть відповіді. |
| reh.step3Hint | Short is fine. You get a score for each and a better first sentence. | Можна коротко. Для кожної буде оцінка і краще перше речення. |
| reh.step4 | See a short result. | Короткий результат. |
| reh.step4Hint | Overall score, timing per slide and what to change in the talk. | Загальна оцінка, час по слайдах і що змінити у виступі. |
| reh.start | Start rehearsal | Почати репетицію |
| reh.notNow | Not now | Не зараз |
| reh.stopAny | You can stop at any step | Зупинитися можна на будь-якому кроці |
| reh.stepOf | Step {i} of {n} | Крок {i} з {n} |
| reh.slideCount | Slide {n} · your {k} of {m} | Слайд {n} · ваш {k} з {m} |
| reh.overBy | of {plan} · {diff} over | з {plan} · {diff} понад |
| reh.outLoud | Say it out loud. Pacenote only counts the time on each slide. | Говоріть уголос. Pacenote лише рахує час на кожному слайді. |
| reh.total | Total {t} of {plan} so far | Разом {t} з {plan} |
| reh.nextSlide | Next slide | Наступний слайд |
| reh.qOf | Question {i} of {n} | Питання {i} з {n} |
| reh.asks | {name} asks | {name} питає |
| reh.why | Why this question: {reason} | Чому це питання: {reason} |
| reh.answer | Your answer | Ваша відповідь |
| reh.answerHint | Keep it short, as you would say it. Scores come after all 4 questions. | Пишіть коротко, як сказали б уголос. Оцінка після всіх 4 питань. |
| reh.skip | Skip | Пропустити |
| reh.done | Done · {t} | Готово · {t} |
| reh.score | {s} of 5 | {s} з 5 |
| reh.overTalk | +{t} over talk time. Shorten slides {list}. | +{t} понад час виступу. Скоротіть слайди {list}. |
| reh.apply | Apply to talk | Застосувати до виступу |
| reh.applyHint | Apply to talk shortens slides {list} and adds the better answers to their Q&A. You review it in Your talk before it is saved. | «Застосувати до виступу» скорочує слайди {list} і додає кращі відповіді в їхні Q&A. Ви переглядаєте це у «Ваш виступ» перед збереженням. |
| reh.better | Better first sentence | Краще перше речення |
| reh.again | Rehearse again | Ще одна репетиція |
| reh.openTalk | Open talk | Відкрити виступ |
| reh.entry.notYet | Not rehearsed yet | Ще не репетирували |
| reh.entry.notYetHint | About {t} · slides and 4 questions | Приблизно {t} · слайди і 4 питання |
| reh.entry.last | Last rehearsal: {date} · score {s} of 5 | Остання репетиція: {date} · оцінка {s} з 5 |
| reh.beforeUpdate | before update | до оновлення |

### Після дзвінка

| Key | EN | UK |
|---|---|---|
| after.window | Call ended | Дзвінок завершено |
| after.meta | {when} · {dur} · {people} · summary saved to Notion | {when} · {dur} · {people} · підсумок збережено в Notion |
| after.series | Part of a series: {name}, call {n}. Calls in this project with the same title are linked. Open items and agenda points not raised go into the next brief, {next}. | Частина серії: {name}, дзвінок {n}. Дзвінки цього проєкту з тією самою назвою звʼязані. Відкриті обіцянки і пункти, до яких не дійшли, переходять у бриф наступного, {next}. |
| after.showSeries | Show series | Показати серію |
| after.decisions | Decisions · {n} | Рішення · {n} |
| after.onYou | On you · {n} · open questions · {k} | На вас · {n} · відкриті питання · {k} |
| after.draft | Follow-up draft | Чернетка листа-підсумку |
| after.draftTo | To {people} · not sent | Кому: {people} · не надіслано |
| after.copy | Copy | Копіювати |
| after.openMail | Open in Mail | Відкрити в Mail |
| after.edit | Edit | Редагувати |
| after.neverSends | Pacenote never sends it for you | Pacenote ніколи не надсилає його за вас |
| after.openNotion | Open in Notion | Відкрити в Notion |
| after.openCall | Open call page | Сторінка дзвінка |
| recent.summary | Summary | Підсумок |
| recent.followup | Follow-up | Лист-підсумок |
| recent.series | Series | Серія |
| recent.seriesPill | Series · {n} | Серія · {n} |
| series.why | Why this is a series | Чому це серія |
| series.whyText | Same project and the same call title. Pacenote links such calls: open promises and agenda points not raised go into the next brief. To start a new series, rename the call. | Той самий проєкт і та сама назва дзвінка. Pacenote звʼязує такі дзвінки: відкриті обіцянки і пункти порядку денного, до яких не дійшли, потрапляють у бриф наступного. Щоб почати нову серію, змініть назву дзвінка. |
| series.open | Show series | Показати серію |

### Проблеми із записом

| Key | EN | UK |
|---|---|---|
| sys.notRecording | Not recording | Запис не йде |
| sys.noAudio | No audio is captured | Звук не записується |
| sys.noAudioWhy | No sound from the microphone or the call for 30 s. Usually another app took the microphone, or macOS revoked access after an update. | 30 с немає звуку ні з мікрофона, ні з дзвінка. Найчастіше мікрофон зайняв інший застосунок або macOS забрав доступ після оновлення. |
| sys.restart | End and restart | Завершити і почати знову |
| sys.noAudioFoot | Tips are off until audio comes back. What was said before {t} is saved. | Підказки вимкнені, поки звук не повернеться. Сказане до {t} збережено. |
| sys.noOther | Can't hear the other side | Не чую співрозмовника |
| sys.noOtherTitle | No call audio is coming in | Звук дзвінка не надходить |
| sys.noOtherWhy | Your microphone works, but there is no system audio from the call for 30 s. Most often the call plays through another device, or Pacenote lost access to system audio. | Ваш мікрофон працює, але системного звуку дзвінка немає 30 с. Найчастіше дзвінок іде через інший пристрій або Pacenote втратив доступ до системного звуку. |
| sys.check | Check audio | Перевірити звук |
| sys.noOtherFoot | Your words are recorded. Tips about the other side are off until their audio comes back. | Ваші слова записуються. Підказки про співрозмовника вимкнені, поки звук не повернеться. |
| sys.mic | Mic | Мікр. |
| sys.call | Call | Дзвінок |

### Додано під час реалізації 0.8.5 (29.10)

Ключі, яких не було в макетах, але без яких екрани не працюють. Кожен є в en.json і uk.json.

| Key | EN | UK |
|---|---|---|
| after.instruct | What to change: "drop the pricing line", "shorter" | Що змінити: «прибери рядок про ціну», «коротше» |
| after.lessons | Uses {n} of your recurring corrections | Враховує ваші повторювані правки: {n} |
| after.rewrite | Rewrite | Переписати |
| after.write | Write draft | Написати чернетку |
| again.keepBrief | The brief is written again from the newest sources. The current one is kept as the previous version. | Бриф буде написано знову з найновіших джерел. Поточний збережеться як попередня версія. |
| deck.assignUnknown | Not understood. Try "5-9 Ann". | Не зрозуміло. Спробуйте «5-9 Ann». |
| deck.colleague | your colleague | колеги |
| deck.err.generic | The file can't be opened or has no slides. Export the deck as PDF and attach it, or paste the talk as text. | Файл не відкривається або в ньому немає слайдів. Експортуйте презентацію в PDF і додайте її або вставте виступ текстом. |
| deck.formatText | Text outline | Текстовий план |
| deck.min | min | хв |
| deck.otherName | Someone else | Інша людина |
| deck.pasteHint | One slide per block: start each with "# Title" or "Slide 3:", or leave a blank line between slides. | Один слайд на блок: починайте кожен з «# Назва» або «Слайд 3:», або залишайте порожній рядок між слайдами. |
| deck.readingStart | Opening the file | Відкриваю файл |
| deck.speakerName | Name | Імʼя |
| hotkey.add30 | +30 s on this slide (while presenting) | +30 с на цьому слайді (під час презентації) |
| hotkey.nextSlide | Next slide (while presenting) | Наступний слайд (під час презентації) |
| hotkey.presentation | Presentation mode on or off | Режим презентації |
| hotkey.prevSlide | Previous slide (while presenting) | Попередній слайд (під час презентації) |
| set.aliases | Other spellings: {list} | Інші написання: {list} |
| set.mergeHelp | The same person under another name: {name}'s voice prints join the chosen person, and {name} becomes another spelling of that name (typing or picking it names the kept person). | Та сама людина під іншим імʼям: зразки голосу {name} додаються до обраної людини, а {name} стає іншим написанням її імені (вибір або введення цього імені назве збережену людину). |
| set.mergeInto | Merge into | Обʼєднати з |
| talk.addQuestion | Add question | Додати питання |
| talk.adv | Shorten slide {n} or mark slide {m} as can skip. | Скоротіть слайд {n} або позначте слайд {m} як «можна пропустити». |
| talk.advShort | Shorten slide {n}. | Скоротіть слайд {n}. |
| talk.budget | Time budget | Бюджет часу |
| talk.done | Done | Готово |
| talk.open | Your talk | Ваш виступ |
| talk.proposal | From the rehearsal: slides {list} shortened, {k} better answers added. Review them below, then save. | З репетиції: скорочено слайди {list}, додано кращих відповідей: {k}. Перегляньте нижче і збережіть. |
| talk.proposalDiscard | Discard | Відкинути |
| talk.proposalSave | Save to talk | Зберегти у виступ |
| talk.proposed | Proposed | Запропоновано |
| talk.short | If short on time, say only | Якщо бракує часу, скажіть лише |

## 3. Рішення PM (29.10)

1. **Синхронізація слайдів: прийнято.** Застосунок: варіант A (номер слайда з Keynote або PowerPoint, потрібен дозвіл Automation). Скіл: варіант B (локальний трекер за мовою PM, перехід лише після «Move to slide N?» з Enter/Esc). Застосунок падає на B, коли презентація PDF, Google Slides або немає доступу Automation. Previous/Next і хоткеї працюють завжди. У rules/ позначити A як `app only`.
2. **Prepare again: прийнято.** За замовчуванням Keep my edits, друга опція Rewrite everything. Зберігається одна попередня версія виступу (Restore previous version).
3. **Хоткеї: прийнято як дефолти.** ⌃⌥M, ⌃⌥P, ⌃⌥T, ⌃⌥←/→, ⌃⌥=, ⌃⌥S, PM може їх змінити в Settings · Keys. Перед реалізацією звірити з уже зайнятими (⌃⌥H лишається за допомогою).
4. **Серії: рішення не потрібне.** Правило вже є в rules/commitments.yaml: `series_key = <project slug>|<назва дзвінка малими літерами, лише літери і цифри>`. Тексти P7 виправлено під нього: серія = той самий проєкт і та сама назва; переносяться відкриті обіцянки (commitments, this series first) і пункти агенди «Not raised» (rules/agenda.yaml). Кнопку «Not a series» прибрано, бо такої поведінки немає: нова серія починається зі зміною назви.
5. **Поради про час: прийнято (29.10).** Однаково для скіла й застосунку, див. розділ 3a.
6. **Prepare again для будь-якого дзвінка (29.10).** Коли бриф готовий, кнопка «Prepare first» у Start call стає «Prepare again» і спершу питає (вік брифу, кількість змін, попередня версія зберігається як `<base>.brief.prev.md`). Для презентації з виступом вона відкриває «Your talk» з листом Prepare again (Keep my edits, заміна файлу). На Home у картці Up next є та сама дія. Причину «New decision on the project» прибрано: надійного джерела для неї немає.
7. **Прогрес «Updating the talk · slide i of n» (29.10).** Номер слайда оцінюється із загального прогресу підготовки; лишаємо так.
8. **Хоткеї (29.10).** ⌃⌥S режим презентації; ⌃⌥←/→ і ⌃⌥= реєструються лише під час презентації. Компактний вигляд лишається на ⌃⌥T, проактивні підказки на ⌃⌥L (як у 0.8.1). Усі змінюються в Settings · Keys.
9. **Мова підказок (29.10).** Підказки й картки мовою мітингу; якщо мова інтерфейсу інша, у заголовку вікна перемикач УК/EN (rules/meeting.yaml > tips_language).
10. **Голоси (29.10).** Названий спікер бере лише голос своєї людини, перейменування повертає рядки попередньої, у бібліотеці є «Merge into» з псевдонімами (rules/voices.yaml).
11. **Одна підготовка, один дзвінок (29.10).** Підготовка, завершена до кінця проведеного дзвінка серії, належить йому; наступний дзвінок серії не показується як підготовлений.

### 3a. Поради про час (прийнято)

Зараз (skill/references/presentation.md, п. 4 і 7): рядок `timeline` пише recorder раз на 60 с («12:30 з 40:00 · відстаєте 3 хв»), а «пропусти {які}» додається лише у двох точках (2/3 часу і 5 хв до кінця), і які слайди пропускати, вирішує модель на свій розсуд.

Нове правило, однаково для скіла й застосунку:
- Новий необовʼязковий прапорець у slides.json: `"skip": true` (Can skip). Prepare ставить його сам на 1-3 слайди, які найменше впливають на мету дзвінка, PM змінює в «Your talk». Також нове поле `"short"`: одна фраза, якою слайд можна замінити.
- Порада «пропусти»: лише серед ще не пройдених слайдів PM з `skip: true`, найменша кількість, що покриває відставання.
- Порада «скороти»: якщо `skip`-слайдів не вистачає, серед ще не пройдених слайдів PM з найбільшим бюджетом, скільки потрібно, щоб покрити відставання, максимум 2 у підказці. Текст: «Slide 6: say only "{short}"». Тобто не лише найдовший, а довгі за потреби.
- Ніколи не про слайди колеги і не під час його блоку.
- Коли показувати: рядок Plan/Elapsed/Behind раз на 60 с, як зараз; порада зʼявляється, коли відставання 1 хв і більше на зміні слайда, і в двох точках зі скіла (2/3 і 5 хв до кінця). Одна порада, оновлюється на місці.
- Потребує змін у rules/ і skill/references/presentation.md (поля `skip`, `short`, правило вибору), інакше скіл і застосунок розійдуться.

## 4. Свідомо не входить у цей етап

- Синхронізація з Google Slides, PDF у браузері, керування слайдами з Pacenote (лише показ і підказка, ми не перемикаємо слайди в Keynote).
- Запис або оцінка голосу на репетиції, темп мовлення, слова-паразити: rules/rehearsal.yaml каже «нічого не записується».
- Репетиція в скілі: за rules/rehearsal.yaml це тільки застосунок.
- Автоматичне надсилання follow-up, інтеграція з поштою крім «Open in Mail», Jira.
- Спільна робота над виступом з колегою (Ann бачить свій текст): лише розподіл власників.
- Автопідготовка на ніч (знято раніше, різні часові пояси).
- Детальні стани помилок читання для кожного формату: в макеті один приклад (Keynote не встановлено), решта за тим самим шаблоном «причина + одна дія».
