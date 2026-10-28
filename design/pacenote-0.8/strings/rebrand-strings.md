# Pacenote: рядки, що змінюються

Ключі - пропозиція. Claude Code має зіставити їх із реальними ключами в `Localizable.xcstrings` / `InfoPlist.xcstrings` і веб-сторінці вікна підказок, а рядки, яких тут немає, але які містять «Live Tips», знайти пошуком (`grep -rn "Live Tips"`). `(none)` - рядок новий. `{...}` - підстановки.

| key | old EN | new EN | new UK |
|---|---|---|---|
| `Info.plist CFBundleDisplayName` | Live Tips | Pacenote | Pacenote |
| `Info.plist CFBundleName` | Live Tips | Pacenote | Pacenote |
| `Info.plist NSMicrophoneUsageDescription` | (contains "Live Tips") | Pacenote transcribes your voice on this Mac. Audio never leaves it. | Pacenote транскрибує ваш голос на цьому Mac. Аудіо його не залишає. |
| `Info.plist NSAudioCaptureUsageDescription` | (contains "Live Tips") | Pacenote transcribes the other side of the call on this Mac. | Pacenote транскрибує іншу сторону дзвінка на цьому Mac. |
| `Info.plist NSCalendarsFullAccessUsageDescription` | (contains "Live Tips") | Pacenote reads your calendars to suggest and prepare the right call. It never changes them. | Pacenote читає ваші календарі, щоб запропонувати і підготувати потрібний дзвінок. Нічого в них не змінює. |
| `app.name` | Live Tips | Pacenote | Pacenote |
| `app.tagline` | A quiet co-pilot for your calls | Your co-driver on calls | Ваш штурман на дзвінках |
| `app.description` | Live Tips transcribes the call on your Mac and shows a small window with the right fact or a ready phrase when you need it. | Pacenote prepares a short brief before the call, gives quiet, precise tips during it, and writes the notes after. You keep the wheel. | Pacenote готує короткий бриф перед дзвінком, дає тихі й точні підказки під час нього і пише нотатки після. Кермо у ваших руках. |
| `home.window.title` | Live Tips | Pacenote | Pacenote |
| `menubar.tooltip` | Live Tips | Pacenote | Pacenote |
| `menubar.status.idle` | Not recording | not recording | не записую |
| `menubar.status.recording` | (none) | Recording · {elapsed} | Запис · {elapsed} |
| `menubar.home` | Home | Open Home | Відкрити Home |
| `menubar.startCall` | Start call... | Start a call… | Почати дзвінок… |
| `menubar.upNext` | Up next ({n}) | Up next · {relative} · {time} | Далі · {relative} · {time} |
| `menubar.lastCall` | Last call: ${cost} (tips ${tips}, Notion notes ${notion}) · {n} tips · Tips rated: app {r}/5 ({k} tips) | Last call ${cost} · {n} tips · rated {r} of 5 | Останній дзвінок ${cost} · {n} підказок · оцінка {r} з 5 |
| `menubar.thisMonth` | This month: ${spent} of ${cap} | This month ${spent} of ${cap} | Цього місяця ${spent} з ${cap} |
| `menubar.thisCall` | (none) | This call ${cost} | Цей дзвінок ${cost} |
| `menubar.helpAbout` | (none) | Help and About | Довідка і про застосунок |
| `menubar.setup` | Setup | Setup… | Початкове налаштування… |
| `menubar.welcomeTour` | Welcome tour | Welcome tour | Ознайомчий тур |
| `menubar.about` | About Live Tips | About Pacenote | Про Pacenote |
| `menubar.quit` | Quit Live Tips | Quit Pacenote | Вийти з Pacenote |
| `menubar.showTips` | (none) | Show tips | Показати підказки |
| `menubar.helpNow` | (none) | Help now | Допоможи зараз |
| `menubar.compact` | (none) | Compact tips | Компактні підказки |
| `onboarding.window.title` | Welcome to Live Tips | Pacenote setup | Налаштування Pacenote |
| `onboarding.splash.cta` | Continue | Get started | Почати |
| `onboarding.splash.hint` | (none) | Setup takes about 3 minutes | Налаштування займе близько 3 хвилин |
| `onboarding.splash.footer` | (none) | Audio never leaves your Mac · Pacenote {version} | Аудіо не залишає ваш Mac · Pacenote {version} |
| `onboarding.welcome.title` | A quiet co-pilot for your calls | Your co-driver on calls | Ваш штурман на дзвінках |
| `onboarding.welcome.body` | Live Tips listens to your call on this Mac and shows the right fact or a ready sentence when you need it... | Pacenote prepares a short brief before the call, gives quiet, precise tips during it, and writes the notes after. | Pacenote готує короткий бриф перед дзвінком, дає тихі й точні підказки під час нього і пише нотатки після. |
| `onboarding.permissions.title` | Allow access to capture your calls | Let Pacenote hear your calls | Дозвольте Pacenote чути ваші дзвінки |
| `onboarding.folder.body` | Live Tips works with plain folders: ... | Pacenote works with plain folders: a work folder, a folder per workspace inside it, a folder per project inside those. | Pacenote працює зі звичайними папками: робоча папка, у ній папка на кожен workspace, у них папка на кожен проєкт. |
| `onboarding.name.body` | So Live Tips knows when a question is for you... | So Pacenote knows when a question is for you. Add the names and short forms people use on calls. | Щоб Pacenote знав, коли питання до вас. Додайте імена і короткі форми, якими вас звуть на дзвінках. |
| `onboarding.claude.body` | ...Without a key Live Tips still records, transcribes and shows prepared facts. | Tips, answers and the call summary come from Claude with your own key, about $0.3-0.8 per call. Without a key Pacenote still records, transcribes and shows prepared facts. | Підказки, відповіді й підсумок дзвінка робить Claude з вашим ключем, приблизно $0.3-0.8 за дзвінок. Без ключа Pacenote все одно записує, транскрибує і показує підготовлені факти. |
| `onboarding.notion.body` | After each call Live Tips adds a page to a Notion database... | After each call Pacenote adds a page to a Notion database: a short summary, decisions, action items, open questions and the transcript. | Після кожного дзвінка Pacenote додає сторінку в базу Notion: короткий підсумок, рішення, задачі, відкриті питання і транскрипт. |
| `onboarding.install.progress` | (list of components) | Getting speech recognition ready · {done} of {total} | Готую розпізнавання мовлення · {done} з {total} |
| `onboarding.done.title` | You are ready | Pacenote is ready | Pacenote готовий |
| `onboarding.done.body` | Before a call: Live Tips in the menu bar > Start call, pick the project, Start... | It lives in your menu bar. During a call, press ⌃⌥H when you need help. | Він живе в рядку меню. Під час дзвінка натисніть ⌃⌥H, коли потрібна допомога. |
| `onboarding.done.menubarHint` | (none) | Look for this in the menu bar | Шукайте цей значок у рядку меню |
| `onboarding.done.primary` | Start a call | Try a demo call | Спробувати демо-дзвінок |
| `onboarding.done.secondary` | Open the demo window / Settings... | Go to Home | Перейти в Home |
| `tips.window.title` | Live Tips: {call} | {call} | {call} |
| `tips.header.label` | Live Tips | (removed, the native title bar shows the mark) | (прибрано) |
| `tips.ready.status` | (none) | Ready · starts {time} | Готово · початок {time} |
| `tips.ready.title` | (none) | Ready when you are | Можна починати |
| `tips.ready.start` | (none) | Start listening | Почати слухати |
| `tips.ready.openBrief` | (none) | Open brief | Відкрити бриф |
| `tips.listening.title` | (none) | Listening | Слухаю |
| `tips.listening.body` | (none) | Tips show up here when they matter. Stuck? Press ⌃⌥H. | Підказки зʼявляться тут, коли будуть потрібні. Застряг? Натисни ⌃⌥H. |
| `tips.footer.onDevice` | (none) | Audio stays on this Mac | Аудіо лишається на цьому Mac |
| `settings.about.windowTitle` | About Live Tips | About Pacenote | Про Pacenote |
| `settings.about.byline` | Live Tips by PM Control Tower | Your co-driver on calls | Ваш штурман на дзвінках |
| `settings.about.description` | A quiet co-pilot for video calls. Live Tips transcribes the call on your Mac... | Pacenote prepares a short brief before the call, gives quiet, precise tips during it, and writes the notes after. | Pacenote готує короткий бриф перед дзвінком, дає тихі й точні підказки під час нього і пише нотатки після. |
| `settings.about.version` | Version {version} | Version {version} ({build}) · macOS {os} | Версія {version} ({build}) · macOS {os} |
| `settings.about.formerly` | (none) | Formerly Live Tips. Your calls, folders and permissions carry over. | Раніше Live Tips. Ваші дзвінки, папки і дозволи збережено. |
| `settings.about.checkUpdates` | (none) | Check for updates | Перевірити оновлення |
| `settings.general.dock` | Show Live Tips in the Dock | Show Pacenote in the Dock | Показувати Pacenote у Dock |
| `settings.how.title` | How Live Tips works | How Pacenote works | Як працює Pacenote |
| `settings.calendars.note` | ...Live Tips only reads them. | Nothing to install: macOS keeps you signed in and syncs the calendars. Pacenote only reads them. | Нічого встановлювати не треба: macOS тримає вхід і синхронізує календарі. Pacenote лише читає їх. |
| `settings.ai.note` | (mentions Live Tips) | Pacenote builds the brief, facts and cards from local files: the project folder, the local Notion mirror, earlier calls. | Pacenote будує бриф, факти й картки з локальних файлів: папки проєкту, локальної копії Notion, попередніх дзвінків. |
| `notion.page.footer` | (none) | Notes by Pacenote · transcribed on device | Нотатки Pacenote · транскрибовано на пристрої |
| `notification.title` | Live Tips | Pacenote | Pacenote |
| `web.title` | Live Tips - A quiet co-pilot on your calls | Pacenote - Your co-driver on calls | Pacenote - Ваш штурман на дзвінках |
| `web.hero.eyebrow` | (none) | For PMs, sales and interviews | Для PM, продажів і співбесід |
| `web.hero.title` | Live Tips | Your co-driver on calls | Ваш штурман на дзвінках |
| `web.hero.body` | A quiet co-pilot on your calls... | Pacenote prepares a short brief before the call, gives quiet, precise tips during it, and writes the notes after. You keep the wheel. | Pacenote готує короткий бриф перед дзвінком, дає тихі й точні підказки під час нього і пише нотатки після. Кермо у ваших руках. |
| `web.hero.cta` | Download | Download for Mac | Завантажити для Mac |
| `web.hero.cta2` | (none) | See how it works | Як це працює |
| `web.hero.footnote` | (none) | macOS 26 · Transcribed on your Mac · English and Ukrainian | macOS 26 · Транскрипція на вашому Mac · англійська й українська |
