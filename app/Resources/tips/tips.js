/* Pacenote 0.8 (F2): the tips window, Concept A "Focus". Built on design/pacenote-0.8/tips-window.
 *
 * Native -> web:  the item stream and the recorder status through feed.js (addItems, setStatus, addTranscript,
 *                 setSpeakers, setPrepDoc, setPrep, setUpNext), plus window.LiveTips.setState(partial) for
 *                 window state, LiveTips.setLang('en'|'uk'), setTheme('auto'|'light'|'dark'), setOpacity(0.65..1),
 *                 setMode('normal'|'compact'), togglePause(), toggleMute(), rename(title), setKeys({help, pause, mute, compact}).
 * Web -> native:  window.webkit.messageHandlers.liveTips.postMessage({action, ...payload}).
 * No emoji, no colored left stripes, nothing smaller than 12 px.
 */
(function () {
  'use strict';

  // ---------- i18n (Ukrainian is about 30% longer; the layout must survive it) ----------
  const STR = {
    en: {
      listening: 'Listening', paused: 'Paused', muted: 'Mic off', ended: 'Call ended', ending: 'Ending the call…', starting: 'Starting…',
      rec: { start: 'Record the call', sound: 'Record the sound', screen: 'Record the sound and the screen', rec: 'Rec', paused: 'Paused',
        pause: 'Pause the recording', resume: 'Resume the recording', stop: 'Stop and save the recording', source: 'Record another window or screen',
        settings: 'Recording settings', choosing: 'Choose what to record…', starting: 'Starting the recording…', menu: 'Recording',
        hint: 'Saved on this Mac in the project\'s video folder',
        armTitle: 'Record this call', armOff: 'Off', armSound: 'Sound', armScreen: 'Sound and screen', armChange: 'Change', armChoose: 'Choose what to record',
        armStarts: 'Starts with Start listening. Pacenote\'s own windows are never recorded.', armSoundNote: 'The call\'s sound and your microphone, starts with Start listening.' },
      micStalled: 'The microphone stopped', cantHear: "Can't hear the other side", asrBehind: (o) => `Transcription is ${o.n} s behind`,
      engineDeaf: 'Tips are not coming: end the call and start again',
      onMe: 'On me', more: 'More', earlier: 'Earlier', allTips: 'Tips', showHero: 'Show the main card',
      agenda: (a, b) => `Agenda ${a} of ${b}`, notRaised: 'Not raised yet:', moreItems: (n) => `+${n} more in the agenda`, allRaised: 'All agenda items raised',
      questionsCap: (a, b) => `Questions: ${a} of ${b} asked`, questionsHead: 'Questions for the call', qState: { todo: 'not asked yet', asked: 'asked' },
      agendaOpen: 'Show the whole agenda', agendaClose: 'Hide the agenda', agendaHint: 'A click moves an item on:', agendaLegend: ['not raised', 'now', 'done', 'skipped, not relevant'],
      agState: { todo: 'not raised', now: 'now', raised: 'raised, not decided', done: 'done', skip: 'skipped' },
      kinds: { answer: 'Answer', turn: 'Your turn', onme: 'On me', docs: 'From docs', finish: 'min left', neutral: 'Note', answered: 'Answered', risk: 'Risk', decision_conflict: 'Decided earlier',
        objection: 'Objection', qualify: 'Qualify', pain: 'Pain', next_step: 'Next step', competitor: 'Competitor', signal: 'Buying signal' },
      firstHint: (k) => `Press ${k.h} when you need help · ${k.t} compact · ${k.l} proactive tips`,
      deal: { tab: 'Deal', unknown: 'Unknown', partial: 'Partly', known: 'Known', objections: 'Objections', next: 'Next step', signals: 'Signals', noNext: 'No next step with a date yet', cycle: 'Click to change the state' },
      afterCall: 'What next', callPage: 'Call page', followup: 'Draft follow-up email',
      asked: (w) => `${w} asked`, now: 'now', ago: (m) => `${m}m`,
      saidIt: 'Said it', collapse: 'Collapse', expand: 'Expand', notByVoice: 'On this meeting, not matched by voice', del: 'Delete', delConfirm: 'Click again to delete', delTip: 'Delete this line from the transcript', restore: 'Restore', lineDeleted: 'Line deleted: it leaves the transcript after the call', backAuto: 'Back to latest', shorter: 'Shorter', hide: 'Hide', pin: 'Pin', unpin: 'Unpin', edit: 'Edit', save: 'Save', cancel: 'Cancel', rateUsed: 'Useful', ratePartly: 'Fine, but off the point', rateNot: 'Not useful', rateWhy: 'What was off?', rateComment: 'A comment, if you like (what to keep, what to change)', rateSave: 'Save', rateSkip: 'Skip', rateThanks: 'Rated: Pacenote learns from it after the call', reasons: { off_topic: 'Off topic', late: 'Late', wrong_fact: 'Wrong fact', too_long: 'Too long', not_now: 'Not now' },
      unverified: 'Not verified against documents',
      next: (t, m) => `${t} in ${m} min`, notPrepared: 'not prepared', ready: 'brief ready', preparing: 'preparing', prepare: 'Prepare', open: 'Open',
      ask: 'Ask about this project', help: 'Help',
      tabs: { transcript: 'Transcript', onme: (n) => `On me · ${n}`, brief: 'Brief' },
      newVoice: 'New voice:', name: 'Name', client: 'Client', team: 'Team', speakersH: 'Speakers', namedOf: (o) => `${o.n} of ${o.m} named`, notNamed: 'not named yet',
      toName: 'to name', mins: (o) => o.m < 1 ? '<1 min' : `${o.m} min`, secsSpoken: (o) => `${o.s} s of speech`, noClip: 'No clip to play: Pacenote never keeps the call audio. The last line helps tell who it is.', soundsLike: (o) => `${o.name} · sounds like ${o.p}%`,
      whoGroups: { voice: 'Sounds like', call: 'On this call', invited: 'Invited to this call', project: 'Project people', library: 'Voice library' }, whoMore: (o) => `${o.n} more from your voice library`, whoWhy: 'Why these names: the voice match, who is on this call, the invitation, then the project and your voice library.',
      whoHint: 'Pick a person and a side: it saves at once.', whoNeedName: 'Pick or type a name first.',
      whoTitle: 'Who is speaking?', whoLine: 'Who said this?', sideH: 'Side', teamSub: 'your side', clientSub: 'the other side', newPerson: 'new', pickSide: 'Choose Team or Client', whoName: 'Name this voice',
      typeName: 'Type a name', more: 'More:', samePerson: 'Same person as…', notNow: 'Not now', lastSaid: 'Last said:',
      mine: 'Mine', mineTip: 'Put this on me', addOnMe: 'Add to On me', fromThisCall: 'From this call', openBefore: 'Open before the call',
      notionGroup: (o) => `Notion · ${o.p}`, removeItem: 'Remove', removeTip: 'Remove from On you and move to the Notion trash', fromACall: 'from a call',
      onThem: (o) => `on ${o.w}`, notionRemoved: 'Notion page was removed', waitingOthers: (n) => `Waiting on others · ${n}`, waitingHint: 'What others promised: tick when it is done, Mine to take it over.', theyDid: 'Done by them', home: 'Home (⌘0)',
      legend: 'Client in purple, team in blue', following: 'Following live', jump: 'Jump to latest',
      ariaMic: 'Mute microphone', ariaPause: 'Pause listening', ariaProactive: 'Proactive tips',
      proactiveOn: 'Proactive tips: on', proactiveOff: 'Proactive tips: off', resumeShort: 'Resume',
      menu: { pause: 'Pause listening', resume: 'Resume listening', mute: 'Turn mic off', unmute: 'Turn mic on',
        compact: 'Compact mode', full: 'Full window', present: 'Presentation mode', stopPresent: 'Stop presenting', presentNeedDeck: 'Attach a deck in Start call',
        heroHide: 'Hide the main card', heroShow: 'Show the main card',
        transcript: 'Transcript', brief: 'Brief', settings: 'Call settings…', switchCall: 'Switch to next call…', clearSpeakers: 'Forget speaker names' },
      recap: 'Recap:',
      after: { window: 'Call ended', meta: (o) => [o.when, o.dur, o.people].filter(Boolean).join(' · ') + (o.notion ? ' · summary saved to Notion' : ''),
        series: (o) => `Part of a series: ${o.name}, call ${o.n}. Calls in this project with the same title are linked. Open items and agenda points not raised go into the next brief${o.next ? ', ' + o.next : ''}.`,
        showSeries: 'Show series', decisions: (o) => `Decisions · ${o.n}`, onYou: (o) => `On you · ${o.n} · open questions · ${o.k}`,
        draft: 'Follow-up draft', draftTo: (o) => `To ${o.people} · not sent`, write: 'Write draft', writing: 'Writing the draft…', instruct: 'What to change: "drop the pricing line", "shorter"',
        rewrite: 'Rewrite', copy: 'Copy', openMail: 'Open in Mail', edit: 'Edit', neverSends: 'Pacenote never sends it for you', openNotion: 'Open in Notion', openCall: 'Open call page', done: 'Done',
        lessons: (o) => `Uses ${o.n} of your recurring corrections`, copied: 'Copied' },
      meetEnd: { q: (o) => `The meeting has ended? Stopping the call in ${o.n} s`, stop: 'Stop now', keep: 'Keep recording' },
      sys: { details: 'Details', hideDetails: 'Hide', notRecording: 'Not recording', noAudio: 'No audio is captured', noAudioWhy: 'No sound from the microphone or the call for a minute. Usually another app took the microphone, or macOS revoked access after an update.',
        restart: 'End and restart', noAudioFoot: (o) => `Tips are off until audio comes back. What was said before ${o.t} is saved.`,
        noOther: "Can't hear the other side", noOtherTitle: 'No call audio is coming in', noOtherWhy: 'No call audio for 45 s while you were not speaking. Most often the call plays through another device, or Pacenote lost access to system audio.',
        check: 'Check audio', noOtherFoot: 'Your words are recorded. Tips about the other side are off until their audio comes back.', mic: 'Mic', call: 'Call' },
      // 0.8.5 presentation mode (PRESENTATION-SPEC 2, keys pm.*)
      pm: { slides: 'Slides', slideOf: (o) => `Slide ${o.i} of ${o.n}`, you: 'You', all: 'All', left: 'left on this slide', overSlide: 'over slide time', add30: '+30 s',
        plan: (o) => `Plan ${o.t}`, elapsed: (o) => `Elapsed ${o.t}`, behind: (o) => `Behind ${o.t}`, ahead: (o) => `Ahead ${o.t}`,
        updated: (o) => `updated ${o.t}`, asked: (o) => `${o.name} asked`, hide: 'Hide', now: (o) => `Now · ${o.n}`, next: (o) => `Next · ${o.n} · ${o.owner}`,
        nextColleague: (o) => `After this slide ${o.name} presents ${o.range}. Tips go quiet until slide ${o.n}.`, prev: 'Previous', nextBtn: 'Next',
        syncA: (o) => `Following ${o.app} · slide ${o.n}`, stopFollowing: 'Stop following', askMove: (o) => `Move to slide ${o.n}?`, why: (o) => `You are already talking about ${o.topic}.`,
        go: 'Move', no: 'No', syncB: 'Slides follow your speech · asks before moving', colleague: (o) => `${o.name} is presenting`, takeSlide: 'Take this slide', backupHide: 'Hide their text', backupNote: (o) => `${o.name}'s text, in case you take over`,
        colleagueHint: (o) => `Tips stay quiet while ${o.name} speaks. Questions to you still get an answer card.`, turnIn: (o) => `Your turn in about ${o.t}`,
        turnNext: (o) => `Your turn next · slide ${o.n}`, startWith: (o) => `Start with: "${o.line}"`, mode: 'Presentation mode', compactView: 'Compact view',
        emptyTitle: 'No presentation attached', emptyText: 'Attach a file and Pacenote shows the slides, the time for each and answers to questions. Until then, tips work as on a regular call.',
        attach: 'Attach presentation', slidesN: (o) => `${o.n} slides`, ofShort: (o) => `${o.i} of ${o.n}` },
      present: { next: 'Next', prev: 'Back', start: 'Start', nextUp: (t, s) => `Next: ${t} (${s})`, canSkip: 'Can skip if short on time' },
      // 0.9.7 presentation controls, as in the 0.7.5 split view
      dk: { start: 'Start', pause: 'Pause', cont: 'Resume', auto: 'Auto', comp: 'Trim', snd: 'Sound', reset: 'Reset',
        mine: 'My slides', all: 'All slides', min: 'min', minTt: 'Talk time in minutes', of: (o) => `${o.a} of ${o.b}`, me: 'yours', shared: 'shared', other: 'speaks',
        onSlide: (o) => `On screen: slide ${o.n}.`, silent: 'You stay quiet.', next: (o) => `Next: ${o.n}. ${o.title} (${o.t})`, last: 'This is the last slide.', skip: 'can skip', canSkip: 'can skip',
        ontrack: 'on schedule', ahead: 'ahead', back: 'back', behind: 'behind', early: 'ahead', wpm: 'wpm',
        slow: 'slow', ok: 'ok', fast: 'fast', squeeze: 'trim', timeout: 'slide time is up',
        done: 'Run finished', total: (o) => `Total ${o.a} with a limit of ${o.b} (${o.d})`, over: 'over', spare: 'spare', close: 'Close',
        slide: 'Slide', title: 'Title', plan: 'Plan', fact: 'Actual', diff: 'Diff',
        autoTt: 'Slides turn by the schedule, with a beep', compTt: 'Hide the "can skip" paragraphs', swap: 'Swap the slides and tips sides',
        expand: 'Expand', collapse: 'One window', expandTt: 'Slides next to the tips: the window gets twice as wide', collapseTt: 'Back to one window: the slide on top, the tips below' },
      doneQ: 'Done?', markDone: 'Mark done', onThemKind: 'On them', closed: 'Closed',
      noItems: 'Nothing on you yet', notMine: 'Not mine', tipsIn: (o) => `Tips in ${o.l}, click for ${o.o}`, close: 'Close', noBriefYet: 'No brief for this call yet.',
      readyStatus: 'Ready', readyTitle: 'Ready when you are', startListening: 'Start listening', openBrief: 'Open brief',
      listeningTitle: 'Listening', tipsOffTitle: 'Transcript only', tipsOffSub: 'Tips are off. The summary and the follow-up come after the call. Turn tips on in Call settings.', listeningSub: (k) => `Tips show up here when they matter. Stuck? Press ${k}.`, onDevice: 'Audio stays on this Mac',
      searched: (o) => `You searched: ${o.q}`, shorterMeta: 'Shorter', applied: 'Settings applied', prepReady: 'The brief is ready',
      speakerN: (o) => `Speaker ${o.n}`, yourTurn: 'Your turn: give your update', me: 'Me', them: 'Unknown voice', lineWhoTip: 'The voice was not recognised. Click to say who said this line.', lineWhoSaved: 'Saved: the transcript shows it after the call',
      briefReady: (o) => o.at ? `Brief ready · ${o.at}` : 'Brief ready', briefPreparing: 'Preparing the brief…', briefFailed: 'The brief could not be prepared', noBrief: 'No brief yet',
      bbReady: (o) => o.made ? `Brief · made ${o.made}${o.before ? ', before the call' : ''}` : 'Brief', bbReadySub: 'Uses what was said so far, plus the project files',
      bbAgain: 'Prepare again', bbNone: 'No brief · tips use only the call so far', bbNow: 'Prepare now', bbRunning: 'Preparing in the background…',
      bbRunningSub: 'Recording and tips keep going. The new brief takes over when it is ready, about 1 min.', bbCancel: 'Cancel'
    },
    uk: {
      listening: 'Слухаю', paused: 'Пауза', muted: 'Мікрофон вимкнено', ended: 'Дзвінок завершено', ending: 'Завершую дзвінок…', starting: 'Запускаю…',
      rec: { start: 'Записати дзвінок', sound: 'Записати звук', screen: 'Записати звук і екран', rec: 'Запис', paused: 'Пауза',
        pause: 'Призупинити запис', resume: 'Продовжити запис', stop: 'Зупинити і зберегти запис', source: 'Записувати інше вікно чи екран',
        settings: 'Налаштування запису', choosing: 'Оберіть, що записувати…', starting: 'Запускаю запис…', menu: 'Запис',
        hint: 'Зберігається на цьому Mac у папці video проєкту' ,
        armTitle: 'Записати цей дзвінок', armOff: 'Ні', armSound: 'Звук', armScreen: 'Звук і екран', armChange: 'Змінити', armChoose: 'Обрати, що записувати',
        armStarts: 'Почнеться разом із «Почати слухати». Вікна Pacenote ніколи не записуються.', armSoundNote: 'Звук дзвінка і ваш мікрофон, почнеться разом із «Почати слухати».' },
      micStalled: 'Мікрофон зупинився', cantHear: 'Не чую іншу сторону', asrBehind: (o) => `Транскрипція відстає на ${o.n} с`,
      engineDeaf: 'Підказки не надходять: заверши дзвінок і почни знову',
      onMe: 'На мені', more: 'Більше', earlier: 'Раніше', allTips: 'Підказки', showHero: 'Показати основну картку',
      agenda: (a, b) => `Агенда ${a} з ${b}`, notRaised: 'Ще не підняли:', moreItems: (n) => `ще ${n} в агенді`, allRaised: 'Усі пункти агенди підняті',
      questionsCap: (a, b) => `Питання: поставлено ${a} з ${b}`, questionsHead: 'Питання на дзвінок', qState: { todo: 'ще не спитав', asked: 'спитав' },
      agendaOpen: 'Показати всю агенду', agendaClose: 'Сховати агенду', agendaHint: 'Клік по пункту змінює його стан:', agendaLegend: ['не піднято', 'зараз', 'зроблено', 'пропущено, неактуально'],
      agState: { todo: 'не піднято', now: 'зараз', raised: 'піднято, не вирішено', done: 'зроблено', skip: 'пропущено' },
      kinds: { answer: 'Відповідь', turn: 'Твоя черга', onme: 'На мені', docs: 'З документів', finish: 'хв лишилось', neutral: 'Нотатка', answered: 'Відповіли', risk: 'Ризик', decision_conflict: 'Вже вирішено',
        objection: 'Заперечення', qualify: 'Кваліфікація', pain: 'Біль', next_step: 'Наступний крок', competitor: 'Конкурент', signal: 'Сигнал купівлі' },
      firstHint: (k) => `Натисніть ${k.h}, коли потрібна допомога · ${k.t} компактно · ${k.l} проактивні підказки`,
      deal: { tab: 'Угода', unknown: 'Невідомо', partial: 'Частково', known: 'Відомо', objections: 'Заперечення', next: 'Наступний крок', signals: 'Сигнали', noNext: 'Ще немає наступного кроку з датою', cycle: 'Клік змінює стан' },
      afterCall: 'Що далі', callPage: 'Сторінка дзвінка', followup: 'Чернетка листа-підсумку',
      asked: (w) => `${w} питає`, now: 'щойно', ago: (m) => `${m} хв`,
      saidIt: 'Сказав', collapse: 'Згорнути', expand: 'Розгорнути', notByVoice: 'Є на цій зустрічі, не за голосом', del: 'Видалити', delConfirm: 'Клацніть ще раз, щоб видалити', delTip: 'Видалити репліку з транскрипту', restore: 'Повернути', lineDeleted: 'Репліку видалено: її не буде в транскрипті після дзвінка', backAuto: 'До останньої', shorter: 'Коротше', hide: 'Сховати', pin: 'Закріпити', unpin: 'Відкріпити', edit: 'Виправити', save: 'Зберегти', cancel: 'Скасувати', rateUsed: 'Корисно', ratePartly: 'Ніби ок, але не в тему', rateNot: 'Не корисно', rateWhy: 'Що не так?', rateComment: 'Коментар, якщо хочете (що лишити, що змінити)', rateSave: 'Зберегти', rateSkip: 'Пропустити', rateThanks: 'Оцінено: Pacenote врахує це після дзвінка', reasons: { off_topic: 'Не в тему', late: 'Запізно', wrong_fact: 'Хибний факт', too_long: 'Задовго', not_now: 'Не зараз' },
      unverified: 'Не звірено з документами',
      next: (t, m) => `${t} за ${m} хв`, notPrepared: 'не підготовлено', ready: 'бриф готовий', preparing: 'готується', prepare: 'Підготувати', open: 'Відкрити',
      ask: 'Запитай про проєкт', help: 'Допоможи',
      tabs: { transcript: 'Транскрипт', onme: (n) => `На мені · ${n}`, brief: 'Бриф' },
      newVoice: 'Новий голос:', name: 'Назвати', client: 'Клієнт', team: 'Команда', speakersH: 'Спікери', namedOf: (o) => `названо ${o.n} з ${o.m}`, notNamed: 'ще без імені',
      toName: 'назвати', mins: (o) => o.m < 1 ? '<1 хв' : `${o.m} хв`, secsSpoken: (o) => `${o.s} с мовлення`, noClip: 'Кліпу немає: Pacenote не зберігає звук дзвінка. Остання фраза допомагає зрозуміти, хто це.', soundsLike: (o) => `${o.name} · схоже на ${o.p}%`,
      whoGroups: { voice: 'Схожий голос', call: 'Уже на цьому дзвінку', invited: 'Запрошені на дзвінок', project: 'Люди проєкту', library: 'Бібліотека голосів' }, whoMore: (o) => `Ще ${o.n} з бібліотеки голосів`, whoWhy: 'Звідки ці імена: схожість голосу, хто вже на дзвінку, запрошення, потім проєкт і ваша бібліотека голосів.',
      whoHint: 'Оберіть людину і сторону: зберігається одразу.', whoNeedName: 'Спершу оберіть або впишіть імʼя.',
      whoTitle: 'Хто говорить?', whoLine: 'Хто це сказав?', sideH: 'Сторона', teamSub: 'ваша сторона', clientSub: 'інша сторона', newPerson: 'нова', pickSide: 'Оберіть Команда або Клієнт', whoName: 'Назвати голос',
      typeName: 'Введіть імʼя', more: 'Ще:', samePerson: 'Та сама людина, що…', notNow: 'Не зараз', lastSaid: 'Останнє:',
      mine: 'Моє', mineTip: 'Записати на мене', addOnMe: 'Додати в На мені', fromThisCall: 'З цього дзвінка', openBefore: 'Відкриті до дзвінка',
      notionGroup: (o) => `Notion · ${o.p}`, removeItem: 'Прибрати', removeTip: 'Прибрати з На вас і перенести в кошик Notion', fromACall: 'з дзвінка',
      onThem: (o) => `на ${o.w}`, notionRemoved: 'Сторінку в Notion видалено', waitingOthers: (n) => `Чекаю від інших · ${n}`, waitingHint: 'Що обіцяли інші: постав галочку, коли зроблено, Моє, щоб узяти на себе.', theyDid: 'Зроблено ними', home: 'Home (⌘0)',
      legend: 'Клієнт фіолетовим, команда синім', following: 'Слідкую наживо', jump: 'До останнього',
      ariaMic: 'Вимкнути мікрофон', ariaPause: 'Пауза прослуховування', ariaProactive: 'Проактивні підказки',
      proactiveOn: 'Проактивні підказки: увімкнено', proactiveOff: 'Проактивні підказки: вимкнено', resumeShort: 'Продовжити',
      menu: { pause: 'Призупинити', resume: 'Продовжити', mute: 'Вимкнути мікрофон', unmute: 'Увімкнути мікрофон',
        compact: 'Компактний режим', full: 'Повне вікно', present: 'Режим презентації', stopPresent: 'Завершити презентацію', presentNeedDeck: 'Додайте презентацію в Start call',
        heroHide: 'Сховати основну картку', heroShow: 'Показати основну картку',
        transcript: 'Транскрипт', brief: 'Бриф', settings: 'Налаштування дзвінка…', switchCall: 'Перейти до наступного дзвінка…', clearSpeakers: 'Забути імена спікерів' },
      recap: 'Підсумок:',
      doneQ: 'Зроблено?', markDone: 'Позначити зробленим', onThemKind: 'На них', closed: 'Закрито',
      after: { window: 'Дзвінок завершено', meta: (o) => [o.when, o.dur, o.people].filter(Boolean).join(' · ') + (o.notion ? ' · підсумок збережено в Notion' : ''),
        series: (o) => `Частина серії: ${o.name}, дзвінок ${o.n}. Дзвінки цього проєкту з тією самою назвою звʼязані. Відкриті обіцянки і пункти, до яких не дійшли, переходять у бриф наступного${o.next ? ', ' + o.next : ''}.`,
        showSeries: 'Показати серію', decisions: (o) => `Рішення · ${o.n}`, onYou: (o) => `На вас · ${o.n} · відкриті питання · ${o.k}`,
        draft: 'Чернетка листа-підсумку', draftTo: (o) => `Кому: ${o.people} · не надіслано`, write: 'Написати чернетку', writing: 'Пишу чернетку…', instruct: 'Що змінити: «прибери рядок про ціну», «коротше»',
        rewrite: 'Переписати', copy: 'Копіювати', openMail: 'Відкрити в Mail', edit: 'Редагувати', neverSends: 'Pacenote ніколи не надсилає його за вас', openNotion: 'Відкрити в Notion', openCall: 'Сторінка дзвінка', done: 'Готово',
        lessons: (o) => `Враховує ваші повторювані правки: ${o.n}`, copied: 'Скопійовано' },
      meetEnd: { q: (o) => `Мітинг закінчився? Зупиняю дзвінок за ${o.n} с`, stop: 'Зупинити зараз', keep: 'Не зупиняти' },
      sys: { details: 'Деталі', hideDetails: 'Сховати', notRecording: 'Запис не йде', noAudio: 'Звук не записується', noAudioWhy: 'Хвилину немає звуку ні з мікрофона, ні з дзвінка. Найчастіше мікрофон зайняв інший застосунок або macOS забрав доступ після оновлення.',
        restart: 'Завершити і почати знову', noAudioFoot: (o) => `Підказки вимкнені, поки звук не повернеться. Сказане до ${o.t} збережено.`,
        noOther: 'Не чую співрозмовника', noOtherTitle: 'Звук дзвінка не надходить', noOtherWhy: '45 с немає звуку дзвінка, поки ви мовчали. Найчастіше дзвінок іде через інший пристрій або Pacenote втратив доступ до системного звуку.',
        check: 'Перевірити звук', noOtherFoot: 'Ваші слова записуються. Підказки про співрозмовника вимкнені, поки звук не повернеться.', mic: 'Мікр.', call: 'Дзвінок' },
      pm: { slides: 'Слайди', slideOf: (o) => `Слайд ${o.i} з ${o.n}`, you: 'Ви', all: 'Усі', left: 'лишилось на слайді', overSlide: 'понад час слайда', add30: '+30 с',
        plan: (o) => `План ${o.t}`, elapsed: (o) => `Минуло ${o.t}`, behind: (o) => `Відставання ${o.t}`, ahead: (o) => `Випереджаєте на ${o.t}`,
        updated: (o) => `оновлено ${o.t}`, asked: (o) => `${o.name} питає`, hide: 'Сховати', now: (o) => `Зараз · ${o.n}`, next: (o) => `Далі · ${o.n} · ${o.owner}`,
        nextColleague: (o) => `Після цього слайда ${o.name} презентує ${o.range}. Підказки мовчать до слайда ${o.n}.`, prev: 'Назад', nextBtn: 'Далі',
        syncA: (o) => `Слідую за ${o.app} · слайд ${o.n}`, stopFollowing: 'Не слідувати', askMove: (o) => `Перейти до слайда ${o.n}?`, why: (o) => `Ви вже говорите про ${o.topic}.`,
        go: 'Перейти', no: 'Ні', syncB: 'Слайди за вашою мовою · питаю перед переходом', colleague: (o) => `Презентує ${o.name}`, takeSlide: 'Взяти слайд', backupHide: 'Сховати текст', backupNote: (o) => `Текст ${o.name}, якщо підхопите`,
        colleagueHint: (o) => `Поки говорить ${o.name}, підказки мовчать. На питання до вас картка з відповіддю все одно зʼявиться.`, turnIn: (o) => `Ваша черга приблизно через ${o.t}`,
        turnNext: (o) => `Далі ви · слайд ${o.n}`, startWith: (o) => `Почніть з: «${o.line}»`, mode: 'Режим презентації', compactView: 'Компактний вигляд',
        emptyTitle: 'Презентацію не додано', emptyText: 'Додайте файл, і Pacenote покаже слайди, час кожного слайда і відповіді на питання. Поки файлу немає, підказки працюють як на звичайному дзвінку.',
        attach: 'Додати презентацію', slidesN: (o) => `${o.n} слайдів`, ofShort: (o) => `${o.i} з ${o.n}` },
      present: { next: 'Далі', prev: 'Назад', start: 'Почати', nextUp: (t, s) => `Далі: ${t} (${s})`, canSkip: 'Можна пропустити, якщо бракує часу' },
      dk: { start: 'Старт', pause: 'Пауза', cont: 'Продовжити', auto: 'Авто', comp: 'Стиснути', snd: 'Звук', reset: 'Скинути',
        mine: 'Мої слайди', all: 'Усі слайди', min: 'хв', minTt: 'Час виступу, хвилин', of: (o) => `${o.a} з ${o.b}`, me: 'твоє', shared: 'спільне', other: 'говорить',
        onSlide: (o) => `У презентації: слайд ${o.n}.`, silent: 'Ти мовчиш.', next: (o) => `Далі: ${o.n}. ${o.title} (${o.t})`, last: 'Це останній слайд.', skip: 'можна пропустити', canSkip: 'можна пропустити',
        ontrack: 'за графіком', ahead: 'уперед', back: 'назад', behind: 'відстаєш', early: 'випереджаєш', wpm: 'сл/хв',
        slow: 'повільно', ok: 'норм', fast: 'швидко', squeeze: 'стисни', timeout: 'час слайда вийшов',
        done: 'Прогін завершено', total: (o) => `Загалом ${o.a} при ліміті ${o.b} (${o.d})`, over: 'перебір', spare: 'запас', close: 'Закрити',
        slide: 'Слайд', title: 'Назва', plan: 'План', fact: 'Факт', diff: 'Різниця',
        autoTt: 'Слайди гортаються самі за розкладом, з сигналом', compTt: 'Сховати абзаци «можна пропустити»', swap: 'Поміняти місцями слайди і підказки',
        expand: 'Розгорнути', collapse: 'Одне вікно', expandTt: 'Слайди поруч із підказками: вікно стає вдвічі ширшим', collapseTt: 'Назад в одне вікно: слайд зверху, підказки внизу' },
      noItems: 'Поки нічого на тобі', notMine: 'Не моє', tipsIn: (o) => `Підказки: ${o.l}, клацніть для ${o.o}`, close: 'Закрити', noBriefYet: 'Брифу для цього дзвінка ще немає.',
      readyStatus: 'Готово', readyTitle: 'Можна починати', startListening: 'Почати слухати', openBrief: 'Відкрити бриф',
      listeningTitle: 'Слухаю', tipsOffTitle: 'Лише транскрипт', tipsOffSub: 'Підказки вимкнено. Підсумок і фоллоу-ап будуть після дзвінка. Увімкнути підказки можна в налаштуваннях дзвінка.', listeningSub: (k) => `Підказки зʼявляться тут, коли будуть потрібні. Застряг? Натисни ${k}.`, onDevice: 'Аудіо лишається на цьому Mac',
      searched: (o) => `Ви шукали: ${o.q}`, shorterMeta: 'Коротше', applied: 'Налаштування застосовано', prepReady: 'Бриф готовий',
      speakerN: (o) => `Спікер ${o.n}`, yourTurn: 'Твоя черга: розкажи свій апдейт', me: 'Я', them: 'Невідомий голос', lineWhoTip: 'Голос не розпізнано. Клацніть, щоб вказати, хто сказав цей рядок.', lineWhoSaved: 'Збережено: у транскрипті буде після дзвінка',
      briefReady: (o) => o.at ? `Бриф готовий · ${o.at}` : 'Бриф готовий', briefPreparing: 'Готую бриф…', briefFailed: 'Бриф не вдалося підготувати', noBrief: 'Брифу ще немає',
      bbReady: (o) => o.made ? `Бриф · зроблено ${o.made}${o.before ? ', до дзвінка' : ''}` : 'Бриф', bbReadySub: 'Враховує сказане досі і файли проєкту',
      bbAgain: 'Підготувати ще раз', bbNone: 'Брифу немає · підказки лише з того, що сказано', bbNow: 'Підготувати зараз', bbRunning: 'Готую у фоні…',
      bbRunningSub: 'Запис і підказки не зупиняються. Новий бриф підхопиться, щойно буде готовий, приблизно за 1 хв.', bbCancel: 'Скасувати'
    }
  };

  // ---------- State ----------
  const PREFS = window.LT_PREFS || {};
  const S = {
    lang: PREFS.ui_lang === 'uk' ? 'uk' : 'en', theme: 'auto',
    call: { title: '', state: 'live', startedAt: null, paused: false, micOff: false, minutesLeft: null, mode: 'normal', recap: '', briefLine: '', alert: null },
    agenda: [], questions: [], cards: [], onMe: [], next: null, deal: null,
    transcript: [], speakers: {}, brief: null, briefText: '', steps: [], toast: null,
    keys: { help: '⌃⌥H', pause: '⌃⌥P', mute: '⌃⌥M', compact: '⌃⌥T', present: '⌃⌥S', prev: '⌃⌥←', next: '⌃⌥→', add30: '⌃⌥=' },
    rec: { state: 'off', kind: 'video', elapsed: 0, source: '', note: '' },
    pres: { slide: null, slideRx: 0, timeline: null, moveAsk: null, follow: null }, thumbs: {}, syncA: null, extra: {}, after: null, sys: null, meetEnd: null, rosterSide: {}, knownNames: [], knownSrc: {}, tipsLang: null,
    openItems: [], notionItems: [], notionProject: '', minePending: [], mineN: 0, spkPrompt: 15,
    ui: { spkOpen: null, spkCard: null, spkSnooze: {}, lineWho: {}, lineDel: {}, delArm: null, openPts: {}, heroMin: {}, paneTab: 'transcript', sheet: null, menuOpen: false, heroOverride: null, follow: true, editing: null, rateOpen: null, briefEdit: false,
          present: { index: 0, running: false, stepStart: 0 }, presentForced: null }
  };
  const T = () => STR[S.lang] || STR.en;
  const tr = (k, p) => { const v = T()[k]; return typeof v === 'function' ? v(p || {}) : (v == null ? k : v); };
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const inApp = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liveTips);

  // 0.8.7 (M, rules/usage.yaml): a tip action for the local usage log, the card's kind only, never its text
  function usage(e, p) { post('usage', { e, p }); }
  /** 2026-11-02: one part of the window that throws does not stop the rest; the app logs it once (logs/window.log). */
  const seenErr = new Set();
  function guard(where, fn) {
    try { return fn(); }
    catch (e) {
      const key = where + ':' + (e && e.message);
      if (!seenErr.has(key)) { seenErr.add(key); post('jserror', { where, msg: String(e && e.message || e), stack: String(e && e.stack || '').slice(0, 800) }); }
      return undefined;
    }
  }
  window.addEventListener('error', (ev) => post('jserror', { where: 'window', msg: String(ev.message || ''), stack: String((ev.error && ev.error.stack) || '').slice(0, 800) }));

  function post(action, payload) {
    const msg = Object.assign({ action }, payload || {});
    try { window.webkit.messageHandlers.liveTips.postMessage(msg); }
    catch (e) { console.log('[Pacenote to native]', JSON.stringify(msg)); }
  }

  const feed = window.PacenoteFeed ? new window.PacenoteFeed({ setState: (st) => window.LiveTips.setState(st), tr }) : null;

  // ---------- Derivations ----------
  const ACTION_KINDS = ['answer', 'turn', 'finish'];
  function presenting() {
    // 0.8.5: a Presentation call is always in presentation mode (empty state until a deck is attached).
    if (!S.steps.length && !S.call.presType) return false;
    return S.ui.presentForced != null ? S.ui.presentForced : !!(S.call.presenting || S.call.presType);
  }
  function withSlides() { return presenting() && S.steps.length > 0; }
  function finishCard() {
    const left = S.call.minutesLeft;
    if (left == null || left > 5 || left < 0) return null;
    const missing = S.agenda.filter((a) => a.state === 'todo');
    // 2026-11-10 (owner): 17 cut titles in one comma line could not be read in the last minutes. Now: the count,
    // the first three as a short list (no numbering, no "\$", up to the first colon), "+N more" opens the agenda.
    const short = (m) => {
      let x = String(m.full || m.title || '').replace(/\\\$/g, '$').replace(/^\s*\d+[.)]\s*/, '').replace(/\s*(…|\.\.\.)\s*$/, '');
      const c = x.indexOf(':'); if (c > 12) x = x.slice(0, c);
      return x.length > 70 ? x.slice(0, 68).replace(/\s+\S*$/, '') + '…' : x;
    };
    const top = missing.slice(0, 3).map(short), more = missing.length - top.length;
    return {
      id: '__finish', kind: 'finish', at: Date.now() - 60000, state: 'active',
      label: `${left} ${T().kinds.finish}`,
      question: missing.length ? `${T().notRaised} ${missing.length}` : T().allRaised,
      finishItems: top, finishMore: more > 0 ? T().moreItems(more) : '',
      say: S.call.recap ? `${T().recap} ${String(S.call.recap).replace(/\\\$/g, '$')}` : '', source: ''
    };
  }
  // 2026-11-05 (owner): the main card can be hidden when the feed alone is easier to read; kept per Mac.
  const HERO_KEY = 'pacenote.heroOff';
  function heroOffSaved() { try { return localStorage.getItem(HERO_KEY) === '1'; } catch (e) { return false; } }
  function setHeroOff(on) { S.ui.heroOff = !!on; try { if (on) localStorage.setItem(HERO_KEY, '1'); else localStorage.removeItem(HERO_KEY); } catch (e) {} }
  // Compact mode shows only the main card, so hiding it applies to the full window only.
  function heroOffNow() { if (S.ui.heroOff == null) S.ui.heroOff = heroOffSaved(); return S.ui.heroOff; }
  function heroHidden() { return heroOffNow() && S.call.mode !== 'compact'; }
  function visibleCards() {
    const list = S.cards.filter((c) => c.state !== 'hidden').slice();
    const f = finishCard(); if (f) list.push(f);
    return list.sort((a, b) => b.at - a.at);
  }
  // Hero order (spec 3.2): pinned, a fresh answer or your turn (90 s), N min left, the newest action, the newest active.
  function pickHero(list) {
    if (S.ui.heroOverride) { const o = list.find((c) => c.id === S.ui.heroOverride); if (o) return o; }
    if (heroHidden()) return null;   // a click on a row still opens that card big (heroOverride)
    list = list.filter((c) => !c.quiet || c.pinned);   // quiet cards (a commitment said to be done) stay in Earlier
    const pinned = list.find((c) => c.pinned && c.state === 'active'); if (pinned) return pinned;
    const fresh = list.find((c) => c.state === 'active' && (c.kind === 'answer' || c.kind === 'turn') && Date.now() - c.at < 90000); if (fresh) return fresh;
    const fin = list.find((c) => c.kind === 'finish'); if (fin) return fin;
    // 2026-11-02 (owner): an answer from 14 minutes ago stayed big over newer tips. Your speech stays until "Said it";
    // an answer stays 3 min; then the newest card for 5 min; older ones all go to the list below.
    const age = (c) => Date.now() - c.at;
    // 2026-11-02 (owner): "Your speech" stayed big for 85 minutes; a speech or your-turn card leaves the big place after 5 min.
    const action = list.find((c) => c.state === 'active' && ACTION_KINDS.includes(c.kind)
      && (c.kind === 'answer' ? age(c) < 180000 : c.kind === 'turn' ? age(c) < 300000 : true));
    if (action) return action;
    const newest = list.find((c) => c.state === 'active');
    return newest && age(newest) < 300000 ? newest : null;
  }
  function rel(at) { const m = Math.floor((Date.now() - at) / 60000); return m < 1 ? T().now : T().ago(m); }

  // ---------- Icons (inline SVG, 1.3-1.5 px stroke) ----------
  const ICON = {
    doc: '<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true"><path d="M3 1.5h5l3 3v8H3z"/><path d="M8 1.5v3h3"/></svg>',
    cal: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true" style="color:var(--text-3)"><rect x="2" y="3" width="12" height="11" rx="2"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/></svg>',
    person: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true" style="color:var(--accent)"><circle cx="8" cy="5.5" r="2.5"/><path d="M3 14c.6-2.8 2.6-4.2 5-4.2s4.4 1.4 5 4.2"/></svg>',
    x: '<svg width="14" height="14" viewBox="0 0 14 14" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="M3 3l8 8M11 3l-8 8"/></svg>'
  };
  const MARK = '<svg class="mark" viewBox="320 206 460 626" aria-hidden="true"><path d="M400 742V404C400 312 466 262 556 262C664 262 724 330 724 412C724 500 662 560 556 560H500" fill="none" stroke="currentColor" stroke-width="92" stroke-linecap="round" stroke-linejoin="round"/><circle cx="400" cy="752" r="70" fill="var(--brand)"/></svg>';

  // ---------- Render ----------
  // 0.9.0 (rules/live_prep.yaml): the brief strip under the header, only while a call runs
  function renderBriefBar(t) {
    const bar = $('briefBar');
    if (!bar) return;
    const live = S.call.state === 'live' && !S.call.tipsOff && S.call.mode !== 'compact';
    bar.hidden = !live;
    if (!live) return;
    const p = S.call.prep || 'none', info = S.call.prepInfo || {};
    let html;
    if (p === 'running') {
      const pct = Math.round((info.progress || 0) * 100);
      html = `<div class="bb-main"><span class="bb-t">${esc(t.bbRunning)}</span><span class="bb-s">${esc(t.bbRunningSub)}</span>`
        + `<span class="bb-prog"><span style="width:${pct}%"></span></span></div><button class="ghost" type="button" data-act="liveprep-cancel">${esc(t.bbCancel)}</button>`;
    } else if (p === 'ready') {
      html = `<div class="bb-main"><span class="bb-t">${esc(t.bbReady(info))}</span><span class="bb-s">${esc(t.bbReadySub)}</span></div>`
        + `<button class="ghost" type="button" data-act="liveprep">${esc(t.bbAgain)}</button>`;
    } else {
      html = `<div class="bb-main"><span class="bb-t">${esc(t.bbNone)}</span></div><button class="btn1" type="button" data-act="liveprep">${esc(t.bbNow)}</button>`;
    }
    if (p !== 'running') html += `<button class="ghost" type="button" data-act="correct-context">${S.lang === 'uk' ? 'Виправити контекст' : 'Correct context'}</button>`;
    if (bar.dataset.html !== html) { bar.innerHTML = html; bar.dataset.html = html; }
  }

  // 0.9.5: the call recording. Off: one button (a menu: sound, or sound and screen). On: the time, Pause, Stop.
  function mmss(sec) { sec = Math.max(0, sec | 0); const h = (sec / 3600) | 0, m = ((sec % 3600) / 60) | 0, x = sec % 60; return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(x).padStart(2, '0'); }
  function renderRec(t, hide) {
    const el = $('recCtl'), r = S.rec || {}, tr2 = t.rec || STR.en.rec;
    el.hidden = hide;
    if (hide) { S.ui.recMenu = false; el.innerHTML = ''; el.dataset.html = ''; return; }
    const on = r.state === 'recording' || r.state === 'paused';
    el.classList.toggle('paused', r.state === 'paused');
    let html;
    if (on) {
      const p = r.state === 'paused';
      html = `<button class="pill" type="button" data-act="rec-menu" title="${esc(r.source ? tr2.menu + ': ' + r.source : tr2.menu)}" aria-haspopup="menu"><span class="dot"></span><span class="lbl">${esc(p ? tr2.paused : tr2.rec)}</span><span>${mmss(r.elapsed)}</span></button>`
        + `<button class="icon-btn tool" type="button" data-act="${p ? 'rec-resume' : 'rec-pause'}" title="${esc(p ? tr2.resume : tr2.pause)}" aria-label="${esc(p ? tr2.resume : tr2.pause)}">${p ? PLAY : PAUSE}</button>`
        + `<button class="icon-btn tool" type="button" data-act="rec-stop" title="${esc(tr2.stop)}" aria-label="${esc(tr2.stop)}">${STOP}</button>`;
    } else {
      const busy = r.state === 'choosing' || r.state === 'starting';
      const tip = busy ? (r.state === 'choosing' ? tr2.choosing : tr2.starting) : tr2.start;
      html = `<button class="icon-btn tool recstart" type="button" data-act="rec-menu" title="${esc(tip)}" aria-label="${esc(tip)}" aria-haspopup="menu"${busy ? ' disabled' : ''}><span class="ring"><i></i></span></button>`;
    }
    if (S.ui.recMenu) {
      html += '<div class="recmenu" role="menu">';
      if (on) {
        if (r.kind === 'video') html += `<button type="button" role="menuitem" data-act="rec-source">${esc(tr2.source)}</button>`;
        html += `<button type="button" role="menuitem" data-act="rec-stop">${esc(tr2.stop)}</button>`;
      } else {
        html += `<button type="button" role="menuitem" data-act="rec-start" data-kind="video">${esc(tr2.screen)}</button>`
          + `<button type="button" role="menuitem" data-act="rec-start" data-kind="audio">${esc(tr2.sound)}</button>`;
      }
      html += `<button type="button" role="menuitem" data-act="rec-settings">${esc(tr2.settings)}</button><div class="sub">${esc(tr2.hint)}</div></div>`;
    }
    if (el.dataset.html !== html) { el.innerHTML = html; el.dataset.html = html; }
  }

  // 2026-11-10 (owner): text in the window can be selected and copied (to paste into the ask field and comment).
  // A drag that selects text is not a click on the card, and a new tip waits (up to 20 s) instead of redrawing
  // the window under the selection.
  function selectingText() {
    const s = window.getSelection();
    if (!s || s.isCollapsed || !String(s).trim()) return false;
    const n = s.anchorNode && (s.anchorNode.nodeType === 1 ? s.anchorNode : s.anchorNode.parentNode);
    return !!(n && !n.closest('input,textarea,[contenteditable="true"]'));
  }
  let renderHeldSince = 0, renderTimer = null;
  function render() {
    if (selectingText() && (!renderHeldSince || Date.now() - renderHeldSince < 20000)) {
      if (!renderHeldSince) renderHeldSince = Date.now();
      clearTimeout(renderTimer); renderTimer = setTimeout(render, 800);
      return;
    }
    renderHeldSince = 0; clearTimeout(renderTimer); renderTimer = null;
    renderNow();
  }
  function renderNow() {
    const t = T();
    document.documentElement.lang = S.lang;
    if (S.theme === 'auto') document.documentElement.removeAttribute('data-theme');
    else document.documentElement.setAttribute('data-theme', S.theme);
    const app = $('app');
    // 0.10.0 (Meeting Sheet, phase 7): a stand-up opens in the small window once (my update, today, whom to ask);
    // the PM's own switch back to the full window wins for the rest of the call.
    if (S.call.standup && !S.ui.standupAuto) {
      S.ui.standupAuto = true;
      if (S.call.mode !== 'compact' && S.call.state === 'live') { S.call.mode = 'compact'; post('compact', { on: true }); }
    }
    app.classList.toggle('compact', S.call.mode === 'compact');

    // header: dot, timer, status (or the one problem that matters), On me, menu
    const isReady = S.call.state === 'ready', ended = S.call.state === 'ended';
    $('rec').classList.toggle('paused', !!S.call.paused || ended);
    $('rec').classList.toggle('ready', isReady);
    $('timer').style.display = isReady || !S.call.startedAt ? 'none' : '';
    const al = S.call.alert;
    const st = $('status');
    st.textContent = al ? al.text : isReady ? t.readyStatus : ended ? t.ended : S.call.paused ? t.paused : (S.call.micOff ? t.muted : t.listening);
    st.classList.toggle('warn', !!(al && al.level === 'warn'));
    const openOnMe = openOnMeCount();
    $('onmeLbl').textContent = t.onMe; $('onmeN').textContent = openOnMe;
    $('onmeBtn').hidden = openOnMe === 0;
    firstCallHint();
    renderBriefBar(t);
    // 0.8.7 (H4): "BANT 2/4" in the header for methods with a chip; a click opens the Deal tab
    const dealChip = S.deal && S.deal.chip ? `${S.deal.name} ${S.deal.known}/${S.deal.total}` : '';
    $('dealBtn').hidden = !dealChip; $('dealBtn').textContent = dealChip;
    $('onmeBtn').setAttribute('aria-label', t.onMe + ': ' + openOnMe);   // below 460 px only the count is visible
    $('moreBtn').setAttribute('aria-label', t.more);
    // 0.8 (owner): the microphone switch is back in the top bar (a cafe: the meeting is muted, the transcript too).
    // 0.8 (owner): three tools, each with its shortcut in the tooltip, aria-label and aria-pressed.
    const key = (k) => (S.keys && S.keys[k] ? ' (' + S.keys[k] + ')' : '');
    $('micBtn').parentElement.hidden = isReady || ended;
    const mb = $('micBtn'), off = !!S.call.micOff;
    mb.classList.toggle('off', off);
    mb.setAttribute('aria-pressed', String(off));
    mb.title = (off ? t.menu.unmute : t.menu.mute) + key('mute');
    mb.setAttribute('aria-label', t.ariaMic);   // stable name; the state is aria-pressed
    mb.innerHTML = off ? MIC_OFF : MIC_ON;
    const pb = $('pauseBtn'), paused = !!S.call.paused;
    pb.classList.toggle('resume', paused);
    pb.setAttribute('aria-pressed', String(paused));
    pb.title = (paused ? t.menu.resume : t.menu.pause) + key('pause');
    pb.setAttribute('aria-label', paused ? t.menu.resume : t.ariaPause);   // the name keeps the visible "Resume"
    pb.innerHTML = paused ? PLAY + `<span>${esc(t.resumeShort)}</span>` : PAUSE;
    $('timer').classList.toggle('paused', paused);
    const bb = $('bulbBtn'), pro = proactiveOn();
    bb.classList.toggle('on', pro);
    bb.setAttribute('aria-pressed', String(pro));
    bb.title = (pro ? t.proactiveOn : t.proactiveOff) + key('proactive');
    bb.setAttribute('aria-label', t.ariaProactive);
    bb.innerHTML = BULB;
    guard('rec', () => renderRec(t, isReady || ended));

    // agenda
    const ag = $('agenda');
    // 0.10.0 (Meeting Sheet, phase 7): the sheet's questions are a checklist here too (with or without an agenda)
    const qs = S.questions || [];
    ag.hidden = (!S.agenda.length && !S.agendaCanUndo && !qs.length) || withSlides() || isReady;
    const qHtml = qs.length ? `<li class="hint qhead">${esc(t.questionsHead)}</li>` + qs.map((q) => `<li class="q ${esc(q.state)}"><button type="button" data-act="sheetq" data-id="${esc(q.id)}" aria-label="${esc(q.title + ', ' + (t.qState[q.state] || q.state))}"><span class="st ${q.state === 'asked' ? 'done' : 'todo'}"></span><span class="tt">${esc(q.title)}</span></button></li>`).join('') : '';
    if (!S.agenda.length && !S.agendaCanUndo && qs.length) {
      $('segs').innerHTML = qs.map((q) => `<button type="button" class="seg ${q.state === 'asked' ? 'done' : 'todo'}" data-act="sheetq" data-id="${esc(q.id)}" title="${esc(q.title)}" aria-label="${esc(q.title)}"></button>`).join('');
      const askedN = qs.filter((q) => q.state === 'asked').length;
      $('agendaNow').textContent = t.questionsCap(askedN, qs.length);
      const left = qs.filter((q) => q.state !== 'asked');
      $('agendaMissing').textContent = left.length ? `${left[0].title}${left.length > 1 ? ` +${left.length - 1}` : ''}` : '';
      const cap = $('agendaCap'), list = $('agendaList'), open = !!S.ui.agendaOpen;
      cap.setAttribute('aria-expanded', String(open));
      list.hidden = !open;
      if (open && list.dataset.html !== qHtml) { const top = list.scrollTop; list.innerHTML = qHtml; list.dataset.html = qHtml; list.scrollTop = top; }
    }
    if (S.agenda.length || S.agendaCanUndo) {
      $('segs').innerHTML = S.agenda.map((a) => `<button type="button" class="seg ${a.state}" data-act="agenda" data-id="${esc(a.id)}" title="${esc(a.full || a.title)}" aria-label="${esc(a.full || a.title)}"></button>`).join('');
      const now = S.agenda.find((a) => a.state === 'now');
      const doneN = S.agenda.filter((a) => a.state !== 'todo').length;
      const pos = now ? S.agenda.indexOf(now) + 1 : Math.min(S.agenda.length, Math.max(doneN, 1));
      $('agendaNow').innerHTML = `${esc(t.agenda(pos, S.agenda.length))}${now ? ` · <b>${esc(now.title)}</b>` : ''}`;
      const missing = S.agenda.filter((a) => a.state === 'todo').map((a) => a.title);
      $('agendaMissing').textContent = missing.length ? `${t.notRaised} ${missing[0]}${missing.length > 1 ? ` +${missing.length - 1}` : ''}` : '';
      // 0.8.6 (owner): the line opens the whole agenda, each item with its state; a click moves it on
      const cap = $('agendaCap'), list = $('agendaList'), open = !!S.ui.agendaOpen;
      cap.setAttribute('aria-expanded', String(open));
      cap.title = open ? t.agendaClose : t.agendaOpen;
      list.hidden = !open;
      if (open) {
        // 2026-11-02 (owner): the opened agenda shows each item in full (13 interview questions were cut to "…")
        const html = S.agenda.map((a) => `<li class="${esc(a.state)}"><button type="button" data-act="agenda" data-id="${esc(a.id)}" aria-label="${esc((a.full || a.title) + ', ' + (t.agState[a.state] || a.state))}"><span class="st ${esc(a.state)}"></span><span class="tt">${esc(a.full || a.title)}</span></button></li>`).join('')
          + `<li class="hint">${esc(t.agendaHint)} ${['todo', 'now', 'done', 'skip'].map((s, i) => `<span class="lg"><span class="st ${s}"></span>${esc(t.agendaLegend[i])}</span>`).join(' → ')}</li>` + (S.agendaCanUndo ? `<li><button type="button" data-act="agenda-undo">${S.lang === 'uk' ? 'Повернути попередню агенду' : 'Restore previous agenda'}</button></li>` : '') + qHtml;
        // 2026-11-03 (owner): the list was rebuilt every second and jumped back to the top while scrolling
        if (list.dataset.html !== html) { const top = list.scrollTop; list.innerHTML = html; list.dataset.html = html; list.scrollTop = top; }
      }
    }

    // Pacenote 0.8: after the call, the call page and the follow-up email draft (nothing is sent).
    const af = $('after');
    af.hidden = !ended;
    app.classList.toggle('afterview', ended && !!S.after);
    if (ended && S.after) renderAfter(af);
    else if (ended) { af.className = 'after'; af.innerHTML = `<span class="meta">${esc(t.afterCall)}</span>
      <button class="btn1" type="button" data-act="after" data-item="followup">${esc(t.followup)}</button>
      <button class="ghost" type="button" data-act="after" data-item="callpage">${esc(t.callPage)}</button>`; }

    // 0.8.5 (owner): tips follow the meeting's language; a switch when it differs from the interface language.
    renderLangSwitch();

    // 0.8.5 (P8): a recording problem replaces the tips area: red strip, the state, the levels, one action.
    const sysOn = !!(S.sys && !ended);
    app.classList.toggle('sysview', sysOn);
    renderSys(sysOn);
    renderMeetEnd(!!(S.meetEnd && !ended));   // 2026-11-10 (owner): the meeting app let go of the microphone

    // 2026-11-02 (owner, live call): an error in one part stopped render() before the side pane, so the tabs
    // did not switch and the transcript stayed empty. Each part now fails on its own and is reported to the app.
    const stream = $('stream'), streamTop = stream ? stream.scrollTop : 0;   // 2026-11-02: never jump back to the top
    const list = guard('cards', visibleCards) || [];
    const hero = guard('pickHero', () => pickHero(list));   // 0.9.7: tips below the slide as on any call
    guard('presentation', renderPresentation);
    guard('reportPresenting', reportPresenting);
    const showEmpty = guard('empty', () => renderEmpty(list));
    guard('hero', () => renderHero(showEmpty ? null : hero));
    guard('earlier', () => renderEarlier(showEmpty ? [] : list.filter((c) => !hero || c.id !== hero.id)));
    if (stream && stream.scrollTop !== streamTop) stream.scrollTop = streamTop;

    // next call, only within 10 minutes
    const nx = $('next');
    if (S.next && S.next.startsInMin != null && S.next.startsInMin <= 10) {
      nx.hidden = false;
      const state = S.next.prepared ? esc(t.ready) : S.next.preparing ? esc(t.preparing) : `<span class="warn">${esc(t.notPrepared)}</span>`;
      nx.innerHTML = `${ICON.cal}<span class="t">${esc(t.next(S.next.title, S.next.startsInMin))} · ${state}</span>` +
        (S.next.preparing ? '' : `<button class="link" type="button" data-act="${S.next.prepared ? 'open-next' : 'prepare-next'}">${esc(S.next.prepared ? t.open : t.prepare)}</button>`);
    } else nx.hidden = true;

    $('askLbl').textContent = t.ask; $('askInput').placeholder = t.ask;
    $('helpLbl').textContent = t.help; $('helpKey').textContent = S.keys.help;

    guard('pane', () => renderPane($('pane'), S.ui.paneTab, false));
    // A sheet opened in a narrow window becomes the side pane when the window gets wide (no double tabs).
    if (S.ui.sheet && isWide()) { S.ui.paneTab = S.ui.sheet; S.ui.sheet = null; }
    if (S.ui.sheet) { $('sheet').hidden = false; guard('sheet', () => renderPane($('sheet'), S.ui.sheet, true)); } else $('sheet').hidden = true;
    renderMenu();
    tick();
  }

  // 2026-11-05 (owner): the recording is prepared before listening starts: Off / Sound / Sound and screen, and for the
  // screen what exactly will be recorded (a small picture, the app and the window) with Change.
  function armCard(t) {
    const tr2 = t.rec || STR.en.rec, a = (S.rec && S.rec.arm) || { kind: 'off' }, k = a.kind || 'off';
    const seg = [['off', tr2.armOff], ['audio', tr2.armSound], ['video', tr2.armScreen]]
      .map(([v, l]) => `<button type="button" class="${k === v ? 'on' : ''}" data-act="rec-arm" data-kind="${v}" aria-pressed="${k === v}">${esc(l)}</button>`).join('');
    let src = '';
    if (k === 'video') {
      src = a.app
        ? `<div class="armsrc">${a.thumb ? `<img src="${a.thumb}" alt="">` : '<span class="ph"></span>'}<span class="x"><b>${esc(a.app)}</b><span>${esc([a.title, a.size].filter(Boolean).join(' · '))}</span></span><button type="button" class="lnk" data-act="rec-arm-pick">${esc(tr2.armChange)}</button></div>`
        : `<div class="armsrc"><span class="ph"></span><span class="x"><b>${esc(tr2.armChoose)}</b></span><button type="button" class="lnk" data-act="rec-arm-pick">${esc(tr2.armChange)}</button></div>`;
    }
    const note = k === 'video' ? tr2.armStarts : k === 'audio' ? tr2.armSoundNote : '';
    return `<div class="armcard"><div class="armtop"><span class="rdot${k === 'off' ? ' off' : ''}"><i></i></span>${esc(tr2.armTitle)}</div>
      <div class="armseg" role="group">${seg}</div>${src}${note ? `<div class="armsub">${esc(note)}</div>` : ''}</div>`;
  }

  // Returns true when an empty state is shown instead of cards.
  function renderEmpty(list) {
    const el = $('empty'), t = T();
    const isReady = S.call.state === 'ready';
    const nothing = !presenting() && !list.some((c) => c.state !== 'hidden');
    if (!isReady && !nothing) { el.hidden = true; return false; }
    el.hidden = false;
    if (isReady) {
      el.innerHTML = `${MARK}<div class="t1">${esc(t.readyTitle)}</div>${S.call.briefLine ? `<div class="t2">${esc(S.call.briefLine)}</div>` : ''}
        <div class="ctl"><button class="btn1" type="button" data-act="start">${esc(t.startListening)}</button>${S.brief ? `<button class="btn2" type="button" data-act="open-brief">${esc(t.openBrief)}</button>` : ''}</div>
        ${armCard(t)}
        <div class="foot">${esc(t.onDevice)}</div>`;
    } else {
      const off = S.call.tipsOff && S.call.state !== 'ended';     // 0.8.5: Tips off or a Transcript call
      el.innerHTML = `<div class="ring">${MARK}</div><div class="t1">${esc(S.call.state === 'ended' ? t.ended : off ? t.tipsOffTitle : t.listeningTitle)}</div>` +
        (S.call.state === 'ended' ? '' : `<div class="t2">${esc(off ? t.tipsOffSub : t.listeningSub(S.keys.help))}</div>`);
    }
    return true;
  }

  function kindLabel(c) {
    if (c.kind === 'finish') return c.label;
    if (c.commit && !c.commit.mine) return T().onThemKind;   // 2026-11-02: was a second key 'onThem' that replaced the On me function
    if (c.state === 'done' && (c.kind === 'answer' || c.kind === 'turn')) return T().kinds.answered;
    return T().kinds[c.kind] || T().kinds.neutral;
  }

  // 0.8.5 (owner): a speech point with its full text is a toggle; it stays open across renders.
  function itemsHtml(c) {
    const f = c.fulls || [];
    if (!f.some(Boolean)) return `<ul class="items">${c.items.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>`;
    return `<ul class="items pts" data-card="${esc(c.id)}">${c.items.map((x, i) => f[i]
      ? `<li><details data-pt="${esc(c.id + ':' + i)}"${S.ui.openPts[c.id + ':' + i] ? ' open' : ''}><summary>${esc(x)}</summary><p>${esc(f[i])}</p></details></li>`
      : /^\d/.test(x) || x.split(/\s+/).length > 3 ? `<li class="pt">${esc(x)}</li>` : `<li class="grp">${esc(x)}</li>`).join('')}</ul>`;
  }
  // 0.9.4 (owner, rules/learning.yaml > tip_rating): a green check (useful), an amber wave (fine but off the point), a red cross (not useful). After 〰️ or ❌
  // reason chips and a short comment; every click is sent (the last one for a tip wins) and logged for learning.
  // Own icons, one stroke width (owner 2026-11-05: the emoji had a thin cross and a thin wave next to a bold check).
  const RATE_ICON = { used: '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8.5l3.2 3.2L13 4.8"/></svg>', partly: '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 9c1.4-2.2 2.8-2.2 4.2 0s2.8 2.2 4.2 0 2.1-2.2 2.6-1.2"/></svg>', not_useful: '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4l8 8M12 4l-8 8"/></svg>' };
  const RATE = [['used', RATE_ICON.used, 'rateUsed'], ['partly', RATE_ICON.partly, 'ratePartly'], ['not_useful', RATE_ICON.not_useful, 'rateNot']];
  const REASONS = ['off_topic', 'late', 'wrong_fact', 'too_long', 'not_now'];
  function rateHtml(c) {
    const t = T(), v = c.rating && c.rating.v;
    return `<span class="rate" role="group" aria-label="${esc(t.rateWhy)}">${RATE.map(([k, ico, lab]) =>
      `<button class="ghost rbtn r-${k}${v === k ? ' on' : ''}" type="button" data-act="rate" data-v="${k}" data-id="${esc(c.id)}" title="${esc(t[lab])}" aria-label="${esc(t[lab])}" aria-pressed="${v === k}">${ico}</button>`).join('')}</span>`;
  }
  function rateBoxHtml(c) {
    const t = T(), r = c.rating;
    if (!r || S.ui.rateOpen !== c.id || r.v === 'used') return '';
    return `<div class="ratebox"><div class="rh">${esc(t.rateWhy)}</div><div class="chips">${REASONS.map((k) =>
      `<button class="chip${(r.reasons || []).includes(k) ? ' on' : ''}" type="button" data-act="rate-reason" data-r="${k}" data-id="${esc(c.id)}">${esc(t.reasons[k])}</button>`).join('')}</div>
      <input type="text" maxlength="300" placeholder="${esc(t.rateComment)}" value="${esc(r.comment || '')}" data-id="${esc(c.id)}">
      <div class="ra"><button class="btn1" type="button" data-act="rate-save" data-id="${esc(c.id)}">${esc(t.rateSave)}</button><button class="ghost" type="button" data-act="rate-skip" data-id="${esc(c.id)}">${esc(t.rateSkip)}</button></div></div>`;
  }
  function sendRate(card) {
    const r = card.rating || {}, raw = card.raw || {};
    post('rate', { id: card.id, key: cardKey(card), verdict: r.v, reasons: r.reasons || [], comment: (r.comment || '').slice(0, 300),
                   kind: String(raw.kind || card.kind || 'tip').slice(0, 40), card: card.card || '', gist: String(raw.gist || card.say || '').slice(0, 300),
                   say: String(card.say || '').slice(0, 300) });
    usage('tip_rated', { kind: String(raw.kind || card.kind || 'tip').slice(0, 40), verdict: r.v, reason: (r.reasons || [])[0] || '' });
  }
  function renderHero(c) {
    const el = $('hero'), t = T();
    if (!c) { el.hidden = true; el.dataset.id = ''; return; }
    if (S.ui.editing === c.id && el.dataset.id === c.id && el.querySelector('.say[contenteditable="true"]')) return;   // the PM is typing
    if (S.ui.rateOpen === c.id && el.dataset.id === c.id && el.contains(document.activeElement) && document.activeElement.matches('.ratebox input')) return;   // 0.9.4: typing a rating comment
    if (el.dataset.id !== c.id) { el.style.animation = 'none'; void el.offsetWidth; el.style.animation = ''; }
    el.hidden = false; el.dataset.id = c.id;
    el.classList.toggle('finish', c.kind === 'finish');
    // 2026-11-05 (owner): a long phrase gets a smaller font so the card does not fill the window.
    const len = String(c.say || '').length + String(c.why || '').length / 2;
    el.classList.toggle('long', len > 130 && len <= 210);
    el.classList.toggle('xlong', len > 210);
    const meta = [c.meta || (c.who ? t.asked(c.who) : ''), rel(c.at)].filter(Boolean).join(' · ');
    const editing = S.ui.editing === c.id;
    const ptsEl = el.querySelector('.items.pts'), ptsTop = ptsEl && ptsEl.dataset.card === c.id ? ptsEl.scrollTop : 0;
    el.innerHTML = `
      <div class="head"><span class="kind k-${c.kind === 'finish' ? 'onme' : c.kind}">${esc(kindLabel(c))}</span>${c.kind === 'finish' ? '' : `<span class="meta"${c.unverified ? ` title="${esc(t.unverified)}"` : ''}>${esc(meta)}</span>`}${S.ui.heroOverride === c.id ? `<button class="ghost backauto" type="button" data-act="hero-auto" title="Esc">${esc(t.backAuto)}</button>` : ''}</div>
      ${(c.commit ? t.doneQ : c.question) ? `<div class="q">${esc(c.commit ? t.doneQ : c.question)}</div>` : ''}
      ${c.kind === 'finish' && (c.finishItems || []).length ? `<ul class="items fin">${c.finishItems.map((x) => `<li>${esc(x)}</li>`).join('')}${c.finishMore ? `<li class="more"><button class="ghost" type="button" data-act="agenda-toggle">${esc(c.finishMore)}</button></li>` : ''}</ul>` : ''}
      ${c.why && !c.commit ? `<div class="why">${esc(c.why)}</div>` : ''}
      ${c.say ? `<div class="say"${editing ? ' contenteditable="true" spellcheck="false"' : ''}>${esc(c.say)}</div>` : ''}
      ${(c.items || []).length && c.kind !== 'finish' && !S.ui.heroMin[c.id] ? itemsHtml(c) : ''}
      ${c.source ? `<div class="src">${ICON.doc}<span>${esc(c.source)}</span></div>` : ''}
      ${c.commit ? `<div class="acts">${c.state === 'done' ? `<span class="meta">${esc(t.closed)}</span>` : `<button class="btn1" type="button" data-act="commit-done" data-id="${esc(c.id)}">${esc(t.markDone)}</button>`}
        <button class="ghost" type="button" data-act="hide" data-id="${esc(c.id)}">${esc(t.hide)}</button></div>` : c.kind === 'finish' ? '' : editing ? `<div class="acts">
        <button class="btn1" type="button" data-act="edit-save" data-id="${esc(c.id)}">${esc(t.save)}</button>
        <button class="ghost" type="button" data-act="edit-cancel">${esc(t.cancel)}</button></div>` : `<div class="acts">
        <button class="ghost" type="button" data-act="said" data-id="${esc(c.id)}">${esc(t.saidIt)}</button>
        ${(c.items || []).length > 2 ? `<button class="ghost" type="button" data-act="hero-min" data-id="${esc(c.id)}">${esc(S.ui.heroMin[c.id] ? t.expand : t.collapse)}</button>` : ''}
        <button class="ghost" type="button" data-act="shorter" data-id="${esc(c.id)}">${esc(t.shorter)}</button>
        <button class="ghost" type="button" data-act="pin" data-id="${esc(c.id)}">${esc(c.pinned ? t.unpin : t.pin)}</button>
        <button class="ghost" type="button" data-act="edit" data-id="${esc(c.id)}">${esc(t.edit)}</button>
        <button class="ghost" type="button" data-act="hide" data-id="${esc(c.id)}">${esc(t.hide)}</button>
        ${rateHtml(c)}
      </div>${rateBoxHtml(c)}`}`;
    if (ptsTop) { const p = el.querySelector('.items.pts'); if (p) p.scrollTop = ptsTop; }
    if (editing) { const s = el.querySelector('.say'); if (s) { s.focus(); document.getSelection().selectAllChildren(s); } }
  }

  function renderEarlier(list) {
    const t = T(), el = $('earlier');
    if (!list.length) { el.innerHTML = ''; return; }
    const off = heroHidden();
    el.innerHTML = `<div class="h"><b>${esc(off ? t.allTips : t.earlier)}</b>${off ? `<button class="ghost showhero" type="button" data-act="hero-show">${esc(t.showHero)}</button>` : ''}<span>${list.length}</span></div>` + list.map((c) => {
      const text = c.commit ? `${t.doneQ} ${c.say}` : c.kind === 'decision_conflict' && (c.items || []).length ? `${c.say} · ${c.items[0]}` : c.state === 'done' && c.question ? `${c.question}${c.say ? ' · ' + c.say : ''}` : (c.say || c.question || '');
      return `<div class="row ${c.state === 'done' ? 'done' : ''}" role="button" tabindex="0" data-act="promote" data-id="${esc(c.id)}">
        <span class="kind k-${c.kind === 'finish' ? 'onme' : c.kind}">${esc(kindLabel(c))}</span>
        <span class="t">${off && c.question && !c.commit && c.state !== 'done' ? `<span class="rq">${esc(c.question)}</span>` : ''}${esc(text)}</span>
        <span class="m">${esc(rel(c.at))}</span>
        ${c.commit && c.state !== 'done' ? `<button class="ghost" type="button" data-act="commit-done" data-id="${esc(c.id)}">${esc(t.markDone)}</button>` : ''}
        <span class="hover-acts"><button class="ghost" type="button" data-act="pin" data-id="${esc(c.id)}">${esc(c.pinned ? t.unpin : t.pin)}</button><button class="ghost" type="button" data-act="hide" data-id="${esc(c.id)}">${esc(t.hide)}</button></span>
      </div>`;
    }).join('');
  }

  function stepElapsed() { const p = S.ui.present; return p.running ? Math.floor((Date.now() - p.stepStart) / 1000) : 0; }
  function fmtSecs(s) { return `${s < 0 ? '+' : ''}${Math.floor(Math.abs(s) / 60)}:${String(Math.abs(s) % 60).padStart(2, '0')}`; }
  function clock(s) { s = Math.max(0, Math.round(Math.abs(s))); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; }

  // ---------- 0.9.7 presentation mode (owner, 11.11; rules/presentation.yaml > window) ----------
  // One window by default: the slide on top (number, title, the countdown, the 0.7.5 controls, the time bar, the talk),
  // the tips below. "Expand" makes the window twice as wide (native "split") with the slide cards beside the tips, as
  // the 0.7.5 split view. The window keeps its own clock: Start / Pause, Auto turns the slides by the schedule with a
  // beep, Previous / Next and a click on the bar move at once; Keynote or PowerPoint (sync A) move it too. Every move
  // goes to the recorder (inbox slide = n|manual), so its facts, handoff card and time advice follow the window.
  const DK = S.dk = { running: false, elapsed: 0, last: 0, offset: 0, idx: 0, enter: {}, warned: {}, finished: false, entryLag: 0,
    auto: PREFS.deck_auto !== '0', sound: PREFS.deck_sound !== '0', compress: false, mode: PREFS.deck_mode === 'mine' ? 'mine' : 'all',
    min: 0, minFor: '', split: PREFS.deck_split === '1', swap: PREFS.deck_swap === '1', sig: '', list: [], cs: [], ce: [], total: 0,
    isSplit: false, prog: false, progT: null, scrollT: null, actx: null, open: {} };
  function dkPref(k, v) { PREFS[k] = String(v); post('pref', { k, v: String(v) }); }
  function dkIncl(st) { return DK.mode === 'all' || st.who !== 'other'; }
  function dkDefMin() {
    const m = S.deckMeta || {};
    if (DK.mode === 'all' && m.talkMin > 0) return Math.round(m.talkMin);
    const s = S.steps.filter(dkIncl).reduce((a, x) => a + (x.secs || 60), 0);
    return Math.max(1, Math.round(s / 60));
  }
  function dkBody(st) {
    if (Array.isArray(st.body) && st.body.length) return st.body;
    const say = Array.isArray(st.say) ? st.say : (st.say ? [String(st.say)] : []);
    return say.map((t) => ({ k: 'p', t }));
  }
  function dkWords(st) { return dkBody(st).reduce((n, b) => n + ((b.k === 'p' || b.k === 'c' || (b.k === 's' && !DK.compress)) ? String(b.t).split(/\s+/).filter(Boolean).length : 0), 0); }
  function dkPlan() {
    const base = S.steps.filter(dkIncl);
    const key = DK.mode + '|' + base.map((x) => x.n).join(',');
    if (DK.minFor !== key) { DK.minFor = key; DK.min = dkDefMin(); }
    const sum = base.reduce((a, x) => a + (x.secs || 60), 0) || 1, k = DK.min * 60 / sum;
    let acc = 0; DK.cs = []; DK.ce = [];
    DK.list = base.map((x) => { const b = (x.secs || 60) * k + (S.extra[x.n] || 0); DK.cs.push(acc); acc += b; DK.ce.push(acc); return Object.assign({}, x, { b }); });
    DK.total = acc;
  }
  function curIdx() { const st = DK.list[DK.idx]; const i = st ? S.steps.findIndex((x) => x.n === st.n) : -1; return i >= 0 ? i : 0; }
  function dkCur() { return DK.list[Math.min(DK.idx, DK.list.length - 1)]; }
  function dkSlideAt(v) { for (let i = 0; i < DK.list.length; i++) if (v < DK.ce[i]) return i; return DK.list.length - 1; }
  function dkBeep(kind) {
    if (!DK.sound) return;
    try {
      if (!DK.actx) DK.actx = new (window.AudioContext || window.webkitAudioContext)();
      const a = DK.actx, f = kind === 'warn' ? [520] : [660, 880], t0 = a.currentTime;
      f.forEach((fr, i) => {
        const o = a.createOscillator(), g = a.createGain(); o.frequency.value = fr; o.type = 'sine';
        g.gain.setValueAtTime(0.0001, t0 + i * 0.16); g.gain.exponentialRampToValueAtTime(0.16, t0 + i * 0.16 + 0.02);
        g.gain.exponentialRampToValueAtTime(0.0001, t0 + i * 0.16 + 0.14);
        o.connect(g); g.connect(a.destination); o.start(t0 + i * 0.16); o.stop(t0 + i * 0.16 + 0.16);
      });
    } catch (e) { /* no sound */ }
  }
  /** Numbers in bold: the slide's own numbers and any figure in the text (P5). */
  function bold(text, nums) {
    let h = esc(text);
    const list = (nums || []).filter((x) => x && x.length > 1).sort((x, y) => y.length - x.length);
    for (const x of list) { const e = esc(x); if (h.includes(e)) h = h.split(e).join('\u0000' + e + '\u0001'); }
    // 0.9.7: "1 192" stays one number (a space between thousands), a trailing comma or dot is not part of it
    h = h.replace(/(^|[^\u0000\w])((?:\d{1,3}(?:[   ]\d{3})+(?!\d)|\d(?:[\d.,:]*\d)?)(?:\s?(?:%|k|K|m|M|x|×)(?![\p{L}\d]))?)/gu, (m, p, d) => p + '\u0000' + d + '\u0001');
    return h.replace(/\u0000/g, '<b>').replace(/\u0001/g, '</b>').replace(/<b>([^<]*)<b>/g, '<b>$1').replace(/<\/b>([^<]*)<\/b>/g, '$1</b>');
  }
  function dkWho(st) { const d = T().dk; return st.who === 'other' ? d.other + (st.speaker ? ': ' + st.speaker : '') : st.who === 'shared' ? d.shared : d.me; }
  function dkCard(st, i) {
    const d = T().dk, pm = T().pm, other = st.who === 'other', nx = DK.list[i + 1];
    const folded = other && !DK.isSplit && !DK.open[st.n];
    const nums = (st.numbers || []).length ? `<p class="nums">${(st.numbers || []).map(esc).join('  ·  ')}</p>` : '';
    const body = dkBody(st).map((b) => `<p class="${b.k === 'p' ? '' : b.k}"${b.k === 's' ? ` data-l="${esc(d.skip)}"` : ''}>${bold(b.t, st.numbers)}</p>`).join('');
    const qa = (st.qa || []).slice(0, 2).map((x) => `<div class="dk-qa"><b>${esc(x.q)}</b> ${bold(x.a, st.numbers)}</div>`).join('');
    const take = other && !DK.isSplit && (body || nums) ? `<button class="btn2 dk-take" type="button" data-act="dk-take" data-n="${st.n}">${esc(DK.open[st.n] ? pm.backupHide : pm.takeSlide)}</button>` : '';
    return `<section class="dk-card${i === DK.idx ? ' cur' : ''}${other ? ' other' : ''}" data-i="${i}">
      <div class="dk-head"><span class="dk-num">${st.n}</span><span class="dk-who ${esc(st.who || 'me')}">${esc(dkWho(st))}</span><h2>${esc(st.title)}</h2><span class="dk-bud">${clock(st.b)}</span></div>
      <div class="dk-go">${other ? esc(d.silent) + ' ' : ''}${esc(d.onSlide({ n: st.n }))}${st.canSkip && !other ? ' · ' + esc(d.canSkip) : ''}</div>
      ${take}<div class="dk-txt${folded ? ' folded' : ''}">${nums}${body}${qa ? `<div class="dk-qas">${qa}</div>` : ''}</div>
      <div class="dk-nx">${nx ? esc(d.next({ n: nx.n, title: nx.title, t: clock(nx.b) })) + (nx.who === 'other' && !other ? ' · ' + esc(dkWho(nx)) : '') : esc(d.last)}</div>
    </section>`;
  }
  const ICO = {
    prev: '<svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="M8 2 4 6l4 4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    next: '<svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="M4 2l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    bell: '<svg width="13" height="13" viewBox="0 0 14 14" aria-hidden="true"><path d="M3.5 10V6.5a3.5 3.5 0 0 1 7 0V10l1 1h-9zM5.8 12.3a1.3 1.3 0 0 0 2.4 0" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg>',
    reset: '<svg width="13" height="13" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 7a4 4 0 1 0 1.2-2.9M3 2.5v2.2h2.2" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    swap: '<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M2 4.5h9M8.5 2l2.5 2.5L8.5 7M12 9.5H3M5.5 7 3 9.5 5.5 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    expand: '<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><rect x="1.5" y="2.5" width="11" height="9" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M7 2.5v9" stroke="currentColor" stroke-width="1.3"/></svg>',
    collapse: '<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><rect x="3" y="2.5" width="8" height="9" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.3"/></svg>'
  };
  function dkBuild() {
    const el = $('present'), d = T().dk;
    const many = DK.list.length > 40;
    const segs = DK.list.map((st, i) => `<button type="button" class="dk-seg${st.who === 'other' ? ' o' : ''}" style="flex:${st.b.toFixed(1)}" data-act="dk-seg" data-i="${i}" title="${esc(st.n + '. ' + st.title + ' (' + clock(st.b) + ')')}" aria-label="${esc(st.n + '. ' + st.title)}"></button>`).join('');
    el.innerHTML = `<div class="dk-top">
      <div class="dk-row r1"><span class="dk-num" id="dkNum"></span><span class="dk-ttl" id="dkTtl"></span><span class="dk-rem" id="dkRem">0:00</span></div>
      <div class="dk-row r2" role="toolbar" aria-label="${esc(T().pm.mode)}">
        <button class="dk-b pri" type="button" id="dkStart" data-act="dk-start"></button>
        <button class="dk-b" type="button" data-act="dk-prev" title="${esc(T().pm.prev + ' ' + S.keys.prev)}" aria-label="${esc(T().pm.prev)}">${ICO.prev}</button>
        <button class="dk-b" type="button" data-act="dk-next" title="${esc(T().pm.nextBtn + ' ' + S.keys.next)}" aria-label="${esc(T().pm.nextBtn)}">${ICO.next}</button>
        <button class="dk-b" type="button" id="dkAuto" data-act="dk-auto" title="${esc(d.autoTt)}">${esc(d.auto)}</button>
        <button class="dk-b" type="button" id="dkComp" data-act="dk-comp" title="${esc(d.compTt)}">${esc(d.comp)}</button>
        <button class="dk-b" type="button" id="dkSnd" data-act="dk-snd" title="${esc(d.snd)}" aria-label="${esc(d.snd)}">${ICO.bell}</button>
        <button class="dk-b" type="button" data-act="dk-reset" title="${esc(d.reset)}" aria-label="${esc(d.reset)}">${ICO.reset}</button>
        <select id="dkMode" aria-label="${esc(d.mine + ' / ' + d.all)}"><option value="mine"${DK.mode === 'mine' ? ' selected' : ''}>${esc(d.mine)}</option><option value="all"${DK.mode === 'all' ? ' selected' : ''}>${esc(d.all)}</option></select>
        <span class="dk-minw"><input id="dkMin" type="number" min="1" max="180" step="1" value="${DK.min}" aria-label="${esc(d.minTt)}"><span class="dk-lab">${esc(d.min)}</span></span>
        <span class="dk-clock" id="dkClock"></span>
        <button class="dk-b dk-swapb" type="button" id="dkSwap" data-act="dk-swap" title="${esc(d.swap)}" aria-label="${esc(d.swap)}">${ICO.swap}</button>
        <button class="dk-b" type="button" id="dkSplit" data-act="dk-split" title="${esc(DK.isSplit ? d.collapseTt : d.expandTt)}">${DK.isSplit ? ICO.collapse : ICO.expand}<span>${esc(DK.isSplit ? d.collapse : d.expand)}</span></button>
      </div>
      <div class="dk-row dk-pace" id="dkPace"></div>
      <div id="dkAdv"></div>
      <div class="dk-track${many ? ' many' : ''}" id="dkTrack">${segs}<div class="dk-mark" id="dkMark"></div></div>
    </div>
    <div class="dk-cards" id="dkCards">${DK.list.map(dkCard).join('')}</div>
    <div class="dk-wrap" id="dkWrap"></div>`;
    $('dkCards').addEventListener('scroll', dkOnScroll);
    dkMark(); dkUpdate();
  }
  function dkMark() {
    const segs = $('dkTrack') ? $('dkTrack').querySelectorAll('.dk-seg') : [];
    segs.forEach((e, j) => { e.classList.toggle('done', j < DK.idx); e.classList.toggle('cur', j === DK.idx); });
    const cards = $('dkCards') ? $('dkCards').children : [];
    for (let j = 0; j < cards.length; j++) cards[j].classList.toggle('cur', j === DK.idx);
  }
  function dkLabels() {
    const d = T().dk, b = $('dkStart'); if (!b) return;
    b.textContent = DK.running ? d.pause : (DK.elapsed > 0 && !DK.finished ? d.cont : d.start);
    $('dkAuto').setAttribute('aria-pressed', String(DK.auto));
    $('dkComp').setAttribute('aria-pressed', String(DK.compress));
    $('dkSnd').setAttribute('aria-pressed', String(DK.sound));
    $('dkSwap').setAttribute('aria-pressed', String(DK.swap));
    $('dkCards').classList.toggle('comp', DK.compress);
  }
  function dkUpdate() {
    const st = dkCur(); if (!st || !$('dkRem')) return;
    const d = T().dk, v = DK.elapsed + DK.offset, rem = DK.ce[DK.idx] - v;
    $('dkNum').textContent = st.n; $('dkTtl').textContent = st.title; $('dkTtl').title = st.title;
    const r = $('dkRem'); r.textContent = (rem < 0 ? '-' : '') + clock(rem); r.className = 'dk-rem' + (rem < 0 ? ' neg' : rem < 10 ? ' warn' : '');
    $('dkClock').textContent = d.of({ a: clock(DK.elapsed), b: clock(DK.min * 60) });
    $('dkMark').style.left = Math.min(100, Math.max(0, v / (DK.total || 1) * 100)) + '%';
    const chips = [];
    if (DK.running || DK.elapsed > 0) {
      if (Math.abs(DK.offset) > 8) chips.push([DK.offset > 0 ? 'ok' : 'warn', (DK.offset > 0 ? d.ahead : d.back) + ' ' + clock(DK.offset)]);
      else if (!DK.auto && Math.abs(DK.entryLag) > 8) chips.push([DK.entryLag > 0 ? 'bad' : 'ok', (DK.entryLag > 0 ? d.behind : d.early) + ' ' + clock(DK.entryLag)]);
      else chips.push(['ok', d.ontrack]);
      if (st.who !== 'other') {
        const wn = dkWords(st);
        if (rem > 5 && wn > 0) {
          const wpm = Math.round(wn / (rem / 60));
          chips.push([wpm > 150 ? 'bad' : (wpm > 135 || wpm < 95) ? 'warn' : 'ok', wpm + ' ' + d.wpm + ' ' + (wpm > 150 ? d.squeeze : wpm > 135 ? d.fast : wpm < 95 ? d.slow : d.ok)]);
        } else if (rem <= 5 && wn > 0) chips.push(['bad', d.timeout]);
      }
    }
    const sync = S.syncA ? `<span class="dk-sync">${esc(T().pm.syncA({ app: S.syncA.app, n: S.syncA.n }))} <button class="link" type="button" data-act="stop-follow">${esc(T().pm.stopFollowing)}</button></span>` : '';
    const html = chips.map(([c, x]) => `<span class="dk-chip ${c}">${esc(x)}</span>`).join('') + sync;
    const pc = $('dkPace'); if (pc.innerHTML !== html) pc.innerHTML = html;
    dkLabels();
  }
  function dkAdvice() {
    const a = $('dkAdv'); if (!a) return;
    const tl = S.pres && S.pres.timeline, st = dkCur();
    const h = tl && tl.advice && tl.advice.text && st && st.who !== 'other'
      ? `<div class="pm-adv" role="status">${bold(tl.advice.text, [])} <span class="m">${esc(T().pm.updated({ t: clock(tl.elapsed) }))}</span></div>` : '';
    if (a.innerHTML !== h) a.innerHTML = h;
  }
  function dkShowCard(i) {
    const box = $('dkCards'); if (!box || !DK.isSplit || !box.clientHeight) return;
    DK.prog = true; box.scrollTop = i * box.clientHeight;
    clearTimeout(DK.progT); DK.progT = setTimeout(() => { DK.prog = false; }, 250);
  }
  function dkOnScroll() {
    if (DK.prog || !DK.isSplit) return;
    clearTimeout(DK.scrollT);
    DK.scrollT = setTimeout(() => {
      const box = $('dkCards'); if (!box || !box.clientHeight) return;
      const i = Math.round(box.scrollTop / box.clientHeight);
      if (i !== DK.idx && i >= 0 && i < DK.list.length) dkJump(i, true);
    }, 120);
  }
  /** The slide changes: the bar and the cards, a beep on an automatic turn, the recorder is told. */
  function dkSetCur(i, withBeep, fromScroll, source) {
    if (!DK.list.length) return;
    const was = DK.list[DK.idx] && DK.list[DK.idx].n;
    DK.idx = i;
    if (!(i in DK.enter)) DK.enter[i] = DK.elapsed;
    DK.entryLag = DK.elapsed + DK.offset - DK.cs[i];
    if (withBeep) dkBeep('go');
    dkMark();
    if (!fromScroll) dkShowCard(i);
    const n = DK.list[i].n;
    if (n !== was || source) {
      S.ui.present.index = curIdx();
      post('setting', { key: 'slide', value: n + '|' + (source || 'manual') });
    }
    dkAdvice(); dkUpdate();
  }
  function dkJump(i, fromScroll, source) {
    if (!DK.list.length) return;
    i = Math.max(0, Math.min(DK.list.length - 1, i));
    if (DK.auto) DK.offset = DK.cs[i] - DK.elapsed;
    dkSetCur(i, false, fromScroll, source);
  }
  function dkStartStop() {
    if (DK.finished || !DK.list.length) return;
    DK.running = !DK.running; DK.last = performance.now();
    if (DK.running) { dkBeep('go'); if (!(DK.idx in DK.enter)) DK.enter[DK.idx] = DK.elapsed; }
    dkUpdate();
  }
  function dkNext() {
    if (!DK.running && !DK.finished && DK.elapsed === 0 && DK.idx === 0) { dkStartStop(); dkSetCur(0, false, false, 'manual'); return; }
    if (DK.idx >= DK.list.length - 1) { dkFinish(); return; }
    dkJump(DK.idx + 1);
  }
  function dkReset() {
    Object.assign(DK, { running: false, elapsed: 0, offset: 0, enter: {}, warned: {}, finished: false, entryLag: 0 });
    const w = $('dkWrap'); if (w) w.classList.remove('on');
    dkSetCur(0, false, false);
  }
  function dkFinish() {
    DK.running = false; DK.finished = true;
    const d = T().dk, w = $('dkWrap'); if (!w) return;
    const keys = Object.keys(DK.enter).map(Number).sort((a, b) => a - b);
    const rows = keys.map((i, j) => {
      const end = j + 1 < keys.length ? DK.enter[keys[j + 1]] : DK.elapsed, act = end - DK.enter[i], df = act - DK.list[i].b;
      return `<tr><td>${DK.list[i].n}</td><td class="t">${esc(DK.list[i].title)}</td><td class="r">${clock(DK.list[i].b)}</td><td class="r">${clock(act)}</td><td class="r ${df > 8 ? 'bad' : df < -8 ? 'ok' : ''}">${df > 0 ? '+' : df < 0 ? '-' : ''}${clock(df)}</td></tr>`;
    }).join('');
    const dd = DK.elapsed - DK.min * 60;
    w.innerHTML = `<div class="dk-row"><b style="flex:1">${esc(d.done)}</b><button class="dk-b" type="button" data-act="dk-close">${esc(d.close)}</button></div>
      <div class="dk-lab">${esc(d.total({ a: clock(DK.elapsed), b: clock(DK.min * 60), d: (dd > 0 ? d.over : d.spare) + ' ' + clock(dd) }))}</div>
      <table><tr><th>${esc(d.slide)}</th><th>${esc(d.title)}</th><th class="r">${esc(d.plan)}</th><th class="r">${esc(d.fact)}</th><th class="r">${esc(d.diff)}</th></tr>${rows}</table>`;
    w.classList.add('on'); dkUpdate();
  }
  function dkTick() {
    if (!withSlides() || !DK.list.length) return;
    if (DK.running) {
      const n = performance.now(); DK.elapsed += (n - DK.last) / 1000; DK.last = n;
      const v = DK.elapsed + DK.offset;
      if (v >= DK.total && DK.auto) { dkFinish(); return; }
      if (DK.auto) { const ni = dkSlideAt(v); if (ni !== DK.idx) dkSetCur(ni, true, false); }
      const rem = DK.ce[DK.idx] - v;
      if (rem <= 10 && rem > 0 && !DK.warned[DK.idx]) { DK.warned[DK.idx] = 1; dkBeep('warn'); }
    }
    dkUpdate();
  }
  setInterval(() => guard('deckTick', dkTick), 250);
  /** The split view: the window grows twice as wide on the slides side (as in 0.7.5), the slide cards move next to the tips. */
  function dkApplySplit(want) {
    const app = $('app'), el = $('present');
    app.classList.toggle('pm-swap', DK.swap);
    if (want === DK.isSplit) return false;
    DK.isSplit = want;
    app.classList.toggle('pm-split', want);
    if (want) app.insertBefore(el, app.firstChild); else $('stream').parentNode.insertBefore(el, $('stream'));
    post('split', { on: want, grow: DK.swap ? 'right' : 'left' });
    if (want) setTimeout(() => dkShowCard(DK.idx), 350);
    return true;
  }
  function renderPresentation() {
    const el = $('present'), t = T(), pm = t.pm;
    const compact = S.call.mode === 'compact';
    if (!presenting()) { dkApplySplit(false); el.hidden = true; el.className = 'present'; DK.sig = ''; return; }
    el.hidden = false;
    if (!S.steps.length) {   // P5 states: no deck yet
      dkApplySplit(false); DK.sig = '';
      el.className = 'present pm-empty';
      el.innerHTML = `<div class="step">${esc(pm.emptyTitle)}</div><div class="say">${esc(pm.emptyText)}</div><div class="ctl"><button class="btn2" type="button" data-act="attach-deck">${esc(pm.attach)}</button></div>`;
      return;
    }
    const keep = dkCur() && dkCur().n;
    dkPlan();
    const moved = dkApplySplit(DK.split && !compact);
    el.className = 'present pm dk' + (DK.isSplit ? ' sv' : '') + (compact ? ' compact' : '');
    const sig = [S.lang, DK.mode, DK.min, DK.isSplit, JSON.stringify(DK.open), DK.list.map((x) => [x.n, x.title, x.who, x.speaker, Math.round(x.b), dkBody(x).length, (x.numbers || []).length, (x.qa || []).length].join('~')).join('|')].join('#');
    if (keep != null) { const i = DK.list.findIndex((x) => x.n === keep); DK.idx = i >= 0 ? i : Math.min(DK.idx, DK.list.length - 1); }
    DK.idx = Math.max(0, Math.min(DK.idx, DK.list.length - 1));
    if (sig !== DK.sig || moved || !$('dkCards')) { DK.sig = sig; dkBuild(); if (DK.isSplit) setTimeout(() => dkShowCard(DK.idx), 30); }
    dkMark(); dkAdvice(); dkUpdate();
  }
  // Kept names: the shortcuts, sync A and the menu use them.
  function goSlide(n, source) { const i = DK.list.findIndex((x) => x.n === n); if (i >= 0) dkJump(i, false, source); }
  function stepBy(d) { if (!DK.list.length) return; if (d > 0) dkNext(); else dkJump(DK.idx - 1); }
  function add30(n) { S.extra[n] = (S.extra[n] || 0) + 30; post('setting', { key: 'slide_add30', value: String(n) }); render(); }
  let lastPresenting = null;
  function reportPresenting() { const p = presenting() && S.steps.length > 0; if (p !== lastPresenting) { lastPresenting = p; post('presenting', { on: p }); } }
  window.addEventListener('resize', () => { if (DK.isSplit) dkShowCard(DK.idx); });

  function renderLangSwitch() {
    let b = $('langBtn');
    const tl = S.tipsLang, show = !!(tl && tl.meeting && tl.meeting !== S.lang);
    if (!b) { b = document.createElement('button'); b.id = 'langBtn'; b.type = 'button'; b.className = 'langbtn'; b.dataset.act = 'tips-lang'; const more = $('moreBtn'); more.parentNode.insertBefore(b, more); }
    b.hidden = !show;
    if (!show) return;
    const cur = tl.current || tl.meeting, other = cur === 'uk' ? 'en' : 'uk', name = (l) => l === 'uk' ? 'УК' : 'EN';
    b.textContent = name(cur);
    b.title = T().tipsIn({ l: name(cur), o: name(other) });
    b.setAttribute('aria-label', b.title);
  }

  // ---------- 2026-11-10 (owner): the meeting has ended, the call stops in a few seconds (MeetingEndWatch) ----------
  function renderMeetEnd(on) {
    let el = $('meetend');
    if (!el) { el = document.createElement('section'); el.id = 'meetend'; el.className = 'sys meetend'; el.setAttribute('role', 'alert'); const bar = document.querySelector('header.bar'); bar.parentNode.insertBefore(el, bar.nextSibling); }
    el.hidden = !on;
    if (!on) return;
    const t = T().meetEnd;
    el.innerHTML = `<div class="strip"><span class="st">${esc(t.q({ n: S.meetEnd.left }))}</span>
        <button class="sbtn" type="button" data-act="meetend-keep">${esc(t.keep)}</button>
        <button class="sbtn ghostish" type="button" data-act="meetend-stop">${esc(t.stop)}</button></div>`;
  }

  // ---------- 0.8.5 recording problems (P8; rules/recording.yaml) ----------
  function renderSys(on) {
    let el = $('sys');
    if (!el) { el = document.createElement('section'); el.id = 'sys'; el.className = 'sys'; el.setAttribute('role', 'alert'); const bar = document.querySelector('header.bar'); bar.parentNode.insertBefore(el, bar.nextSibling); }
    el.hidden = !on;
    if (!on) { S.ui.sysOpen = null; return; }
    const t = T().sys, s = S.sys, no = s.kind === 'notRecording';
    // 2026-11-02 (owner): the red strip stays, but it no longer hides the brief and the tips: a pause or a long
    // monologue of the PM is not a broken call. Details open on a click (open by default only when nothing records).
    const open = S.ui.sysOpen == null ? no : S.ui.sysOpen;
    const meter = (label, v) => `<div class="lv"><span>${esc(label)}</span><span class="bar"><i style="width:${Math.round(Math.max(0, Math.min(1, v)) * 100)}%"></i></span></div>`;
    el.innerHTML = `<div class="strip"><span class="st">${esc(no ? t.notRecording : t.noOther)}</span>
        <button class="sbtn" type="button" data-act="${no ? 'sys-restart' : 'sys-check'}">${esc(no ? t.restart : t.check)}</button>
        <button class="sbtn ghostish" type="button" data-act="sys-more" aria-expanded="${open}">${esc(open ? t.hideDetails : t.details)}</button></div>
      ${open ? `<div class="body"><div class="step">${esc(no ? t.noAudio : t.noOtherTitle)}</div><div class="say">${esc(no ? t.noAudioWhy : t.noOtherWhy)}</div>
      <div class="levels">${meter(t.mic, s.mic)}${meter(t.call, s.call)}</div>
      <div class="meta">${esc(no ? t.noAudioFoot({ t: s.at || '' }) : t.noOtherFoot)}</div></div>` : ''}`;
  }

  // ---------- 0.8.5 after the call (P7) ----------
  function renderAfter(af) {
    const a = S.after, t = T().after, dr = a.draft || {};
    if (document.activeElement && af.contains(document.activeElement) && /^(TEXTAREA|INPUT)$/.test(document.activeElement.tagName) && !dr.busy && af.dataset.body === (dr.body || '')) return;   // the PM is typing
    af.className = 'after full';
    af.dataset.body = dr.body || '';
    const list = (xs, mark) => xs.map((x) => `<li><span class="mk">${mark}</span>${esc(x)}</li>`).join('');
    const people = a.people || '';
    af.innerHTML = `
      <div class="kind">${esc(t.window)}</div>
      <h2>${esc(a.title || '')}</h2>
      <div class="meta">${esc(t.meta({ when: a.when, dur: a.dur, people, notion: !!a.notion }))}</div>
      ${a.series ? `<div class="series"><span>${esc(t.series(a.series))}</span><button class="link" type="button" data-act="after" data-item="series">${esc(t.showSeries)}</button></div>` : ''}
      ${(a.decisions || []).length ? `<h3>${esc(t.decisions({ n: a.decisions.length }))}</h3><ul>${list(a.decisions, '✓')}</ul>` : ''}
      ${((a.onMe || []).length || (a.open || []).length) ? `<h3>${esc(t.onYou({ n: (a.onMe || []).length, k: (a.open || []).length }))}</h3><ul>${list(a.onMe || [], '•')}${list(a.open || [], '?')}</ul>` : ''}
      <div class="draft">
        <div class="dh"><b>${esc(t.draft)}</b>${people ? `<span class="meta">${esc(t.draftTo({ people }))}</span>` : ''}</div>
        ${dr.busy ? `<div class="meta">${esc(t.writing)}</div>` : ''}
        ${dr.error ? `<div class="meta err">${esc(dr.error)}</div>` : ''}
        ${dr.body ? `<input id="afSubject" type="text" value="${esc(dr.subject || '')}" aria-label="Subject">
          <textarea id="afBody" spellcheck="true" rows="9">${esc(dr.body)}</textarea>
          <form class="instr" id="afInstr"><input id="afInstruction" type="text" placeholder="${esc(t.instruct)}" aria-label="${esc(t.instruct)}"><button class="btn2" type="submit" ${dr.busy ? 'disabled' : ''}>${esc(t.rewrite)}</button></form>
          <div class="ctl"><button class="btn1" type="button" data-act="after" data-item="copy">${esc(t.copy)}</button><button class="btn2" type="button" data-act="after" data-item="mail">${esc(t.openMail)}</button><span class="meta">${esc(t.neverSends)}</span></div>`
        : dr.busy ? '' : `<div class="ctl"><button class="btn1" type="button" data-act="after" data-item="write">${esc(t.write)}</button>${a.lessons ? `<span class="meta">${esc(t.lessons({ n: a.lessons }))}</span>` : ''}</div>`}
      </div>
      <div class="ctl foot">${a.notion ? `<button class="btn3" type="button" data-act="after" data-item="notion">${esc(t.openNotion)}</button>` : ''}<button class="btn3" type="button" data-act="after" data-item="callpage">${esc(t.openCall)}</button><span class="spacer"></span><button class="btn2" type="button" data-act="after" data-item="done">${esc(t.done)}</button></div>`;
    const form = $('afInstr');
    if (form) form.onsubmit = (e) => { e.preventDefault(); const v = $('afInstruction').value.trim(); if (!v) return; post('after', Object.assign({ item: 'revise', instruction: v }, draftNow())); };
    const body = $('afBody');
    if (body) body.onblur = () => post('after', Object.assign({ item: 'edited' }, draftNow()));
  }
  function draftNow() { const s = $('afSubject'), b = $('afBody'); return b ? { subject: s ? s.value : '', body: b.value } : {}; }

  function renderBrief() {
    const t = T(), b = S.brief;
    if (S.ui.briefEdit) {
      return `<textarea class="briefedit" id="briefEdit" spellcheck="false">${esc(S.briefText)}</textarea>
        <div class="ctl"><button class="btn1" type="button" data-act="brief-save">${esc(t.save)}</button><button class="btn2" type="button" data-act="brief-cancel">${esc(t.cancel)}</button></div>`;
    }
    if (!b) return `<p class="meta">${esc(t.noBriefYet)}</p>`;
    const sections = S.ui.briefFull ? b.sections : (b.sections || []).filter((s) => /live essentials|needs confirmation|увага|розбіжність|ключове|checklist|red lines|червон/i.test(s.title));
    const selected = sections.length ? sections : (b.sections || []).slice(0, 2);
    const toggle = `<button class="link" type="button" data-act="brief-full">${S.lang === 'uk' ? (S.ui.briefFull ? 'Короткий бриф' : 'Повний бриф і джерела') : (S.ui.briefFull ? 'Live essentials' : 'Full brief and sources')}</button>`;
    return toggle + `<div class="brief">${b.goal ? `<p><b>${esc(b.goal)}</b></p>` : ''}${selected.map((s) => `<h3>${esc(s.title)}</h3><ul>${(S.ui.briefFull ? s.items : s.items.slice(0, 5)).map((i, k) => (s.fulls || [])[k]
      ? `<li class="pt"><details data-pt="${esc('brief:' + s.title + ':' + k)}"${S.ui.openPts['brief:' + s.title + ':' + k] ? ' open' : ''}><summary>${esc(i)}</summary><p>${esc(s.fulls[k])}</p></details></li>`
      : `<li>${esc(i)}</li>`).join('')}</ul>`).join('')}</div>
      ${S.briefText ? `<div><button class="link" type="button" data-act="brief-edit">${esc(t.edit)}</button></div>` : ''}`;
  }

  /** 0.8.5 (owner): a line given to a person shows that person's side; nobody known = grey, like Speaker N. */
  function sideOfName(n) {
    const sp = Object.values(S.speakers).find((x) => x && x.name && x.name === n);
    const side = (sp && sp.side) || (S.rosterSide && S.rosterSide[n]) || '';
    return side === 'client' ? 'client' : side === 'team' ? 'team' : 'unknown';
  }
  // 0.8.6 (F): the speakers block lives in speakers.js (shared with the tests).
  const SPK = window.PacenoteSpeakers;
  const speakerList = () => SPK.list(S);
  const cardVoice = (list) => SPK.cardVoice(S, list);
  const speakersBlock = () => SPK.block(S, T(), esc);
  function renderPane(root, tab, isSheet) {
    const t = T();
    const openN = openOnMeCount();
    const tabs = S.deal ? ['transcript', 'onme', 'deal', 'brief'] : ['transcript', 'onme', 'brief'];   // 0.8.7 (H4): Deal only in Sales mode
    if (tab === 'deal' && !S.deal) tab = 'transcript';
    if (tab === 'brief' && S.ui.briefEdit && root.querySelector('#briefEdit')) return;   // the PM is typing
    if (tab === 'onme' && S.ui.onmeEdit && root.querySelector('#onmeEditInput')) return;   // 0.8.5: an On me line being reworded
    const typing = document.activeElement && (document.activeElement.id === 'spkCardName' || document.activeElement.id === 'onmeAdd') && root.contains(document.activeElement);
    if (typing) return;                                                                         // 0.8.6: the PM is typing a name or a task
    const old = root.querySelector('.panebody');
    S.ui.paneScroll = S.ui.paneScroll || {};
    if (old && root.dataset.tab) S.ui.paneScroll[root.dataset.tab] = old.scrollTop;
    const top = S.ui.paneScroll[tab] || 0;
    root.dataset.tab = tab;
    let body = '';
    if (tab === 'transcript') {
      const unknown = Object.entries(S.speakers).find(([sid, s]) => /^S\d+$/i.test(sid) && !s.name);
      const sugBtns = (sid, sp) => (sp.suggestions || []).map((x) => `<button class="sug" type="button" data-act="name-pick" data-sid="${esc(sid)}" data-name="${esc(x.name)}" title="${x.score == null ? esc(T().notByVoice) : Math.round(x.score * 100) + '%'}">${esc(x.name)}</button>`).join('');
      body = S.transcript.map((l, i) => {
          const sp = S.speakers[l.speakerId] || {};
          const cls = sp.side === 'client' ? 'client' : sp.side === 'team' ? 'team' : 'unknown';
          const named = /^S\d+$/i.test(l.speakerId);
          const fixed = S.ui.lineWho[lineKey(l)];
          const who = esc(fixed || sp.name || sp.label || l.speakerId);
          // 0.8 (owner): a line whose voice was not recognised can be given to a person (recorder: line_who).
          const btn = named ? `<button class="who ${cls}" type="button" data-act="name" data-sid="${esc(l.speakerId)}">${who}</button>`
            : l.speakerId === 'me' ? `<span class="who ${cls}">${who}</span>`
            : `<button class="who ${fixed ? sideOfName(fixed) : 'unknown'}" type="button" data-act="line-who" data-i="${i}" title="${esc(t.lineWhoTip)}">${who}</button>`;
          // 0.8.5 (owner, back from 0.7): any line can be deleted (two clicks) and restored; applied after the stop.
          const k = lineKey(l), gone = !!S.ui.lineDel[k];
          const del = !l.t ? '' : gone
            ? `<button class="ghost" type="button" data-act="line-undel" data-i="${i}">${esc(t.restore)}</button>`
            : `<button class="ghost${S.ui.delArm === k ? ' armed' : ''}" type="button" data-act="line-del" data-i="${i}" title="${esc(t.delTip)}">${esc(S.ui.delArm === k ? t.delConfirm : t.del)}</button>`;
          const mine = !l.t || l.speakerId === 'me' ? '' : `<button class="ghost" type="button" data-act="line-mine" data-i="${i}" title="${esc(t.mineTip)}">${esc(t.mine)}</button>`;
          return `<div class="tl${gone ? ' gone' : ''}">${btn}<span class="tx">${esc(l.text)}</span><span class="hover-acts">${mine}${del}</span></div>`;
        }).join('');
    } else if (tab === 'onme') {
      const item = (o) => S.ui.onmeEdit === o.id
        ? `<div class="onme-item editing"><input id="onmeEditInput" type="text" value="${esc(o.text)}" aria-label="${esc(t.edit)}"><button class="btn1" type="button" data-act="onme-save" data-id="${esc(o.id)}">${esc(t.save)}</button><button class="ghost" type="button" data-act="onme-cancel">${esc(t.cancel)}</button></div>`
        : `<div class="onme-item"><label><input type="checkbox" data-act="onme-toggle" data-id="${esc(o.id)}" ${o.done ? 'checked' : ''}><span><span class="${o.done ? 'struck' : ''}">${esc(o.text)}</span>${o.due ? `<br><span class="meta">${esc(o.due)}</span>` : ''}</span></label>
          <span class="hover-acts"><button class="ghost" type="button" data-act="onme-edit" data-id="${esc(o.id)}">${esc(t.edit)}</button><button class="ghost" type="button" data-act="onme-notmine" data-id="${esc(o.id)}">${esc(t.notMine)}</button></span></div>`;
      // 0.8.6 (D4): items of the register opened before this call and the PM's Notion tasks of this call's project
      const ext = (o) => {
        // 2026-11-03 (owner): items on others sit in their own group by person (no "on X" line), and can be ticked
        const sub = [o.badge === 'N' && o.fromCall ? t.fromACall : '', o.status || '', o.due || '', o.note === 'removed' ? t.notionRemoved : ''].filter(Boolean).join(' · ');
        return `<div class="onme-item ext${o.mine === false ? ' theirs' : ''}" data-id="${esc(o.id)}"><label${o.mine === false ? ` title="${esc(t.theyDid)}"` : ''}><input type="checkbox" data-act="ext-toggle" data-id="${esc(o.id)}" ${o.done ? 'checked' : ''}><span><span class="badge-src">${esc(o.badge || 'CALL')}</span> <span class="${o.done ? 'struck' : ''}">${esc(o.text)}</span>${sub ? `<br><span class="meta">${esc(sub)}</span>` : ''}</span></label>
          <span class="hover-acts">${o.mine === false ? `<button class="ghost" type="button" data-act="ext-mine" data-id="${esc(o.id)}">${esc(t.mine)}</button>` : ''}<button class="ghost" type="button" data-act="ext-remove" data-id="${esc(o.id)}" title="${esc(t.removeTip)}" aria-label="${esc(t.removeTip)}">${TRASH}</button></span></div>`;
      };
      const pend = S.minePending.filter((p) => !S.onMe.some((o) => o.from === p.tag)).map((p) => ({ id: 'p:' + p.tag, text: p.text, due: '', done: false }));
      const here = S.onMe.concat(pend);
      const open = S.openItems || [], theirs = open.filter((o) => o.mine === false);
      const groups = [[t.fromThisCall, here.map(item)], [t.openBefore, open.filter((o) => o.mine !== false).map(ext)]];
      if ((S.notionItems || []).length) groups.push([t.notionGroup({ p: S.notionProject || '' }), S.notionItems.map(ext)]);
      body = groups.filter(([, rows]) => rows.length).map(([h, rows]) => `<h4 class="grp">${esc(h)}</h4>${rows.join('')}`).join('');
      // 2026-11-03 (owner): "On me · 11" listed other people's promises among mine. They are a separate, folded group
      // by person: useful at a stand-up, never counted as mine.
      if (theirs.length) {
        const left = theirs.filter((o) => !o.done).length, by = {};
        theirs.forEach((o) => { (by[o.owner || '?'] = by[o.owner || '?'] || []).push(o); });
        const openW = S.ui.theirsOpen != null ? S.ui.theirsOpen : !groups.some(([, rows]) => rows.length);
        body += `<button type="button" class="grp-toggle" data-act="theirs-toggle" aria-expanded="${openW}"><h4 class="grp">${esc(t.waitingOthers(left))}</h4><span class="chev">${openW ? '▾' : '▸'}</span></button>`
          + (openW ? `<p class="meta grp-hint">${esc(t.waitingHint)}</p>` + Object.keys(by).map((w) => `<h5 class="who">${esc(w)}</h5>${by[w].map(ext).join('')}`).join('') : '');
      }
      if (!body) body = `<p class="meta">${esc(t.noItems)}</p>`;
      body += `<div class="onme-add"><input id="onmeAdd" type="text" placeholder="${esc(t.addOnMe)}" aria-label="${esc(t.addOnMe)}"></div>`;
    } else if (tab === 'deal') {
      body = renderDeal();
    } else if (tab === 'brief') {
      body = renderBrief();
    }
    const paneHTML = `
      ${isSheet ? `<button class="icon-btn close" type="button" data-act="close-sheet" aria-label="${esc(t.close)}">${ICON.x}</button>` : ''}
      ${speakersBlock()}
      <div class="tabs" role="tablist" ${isSheet ? 'style="margin-right:48px"' : ''}>${tabs.map((k) => `<button class="tab" role="tab" type="button" aria-selected="${k === tab}" data-act="${isSheet ? 'sheet-tab' : 'pane-tab'}" data-tab="${k}">${esc(k === 'onme' ? t.tabs.onme(openN) : k === 'deal' ? t.deal.tab : t.tabs[k])}</button>`).join('')}</div>
      <div class="panebody">${body}</div>
      ${tab === 'transcript' ? `<div class="panefoot"><span>${esc(t.legend)}</span>${S.ui.follow ? `<span>${esc(t.following)}</span>` : `<button class="link" type="button" data-act="follow">${esc(t.jump)}</button>`}</div>` : ''}`;
    if (root.dataset.html !== paneHTML) { root.innerHTML = paneHTML; root.dataset.html = paneHTML; }
    const pb = root.querySelector('.panebody');
    if (tab === 'transcript' && S.ui.follow) pb.scrollTop = pb.scrollHeight; else pb.scrollTop = top;
  }

  // 0.8.7 (H4): the Deal tab, a row per criterion like the agenda; a click cycles the state (the PM's fix goes to
  // the engine and to the learning log, rules/learning.yaml > deal_edit)
  function renderDeal() {
    const t = T(), d = S.deal;
    if (!d) return '';
    const rows = d.criteria.map((c) => `<div class="deal-row ${esc(c.state)}"><button class="seg ${c.state === 'known' ? 'done' : c.state === 'partial' ? 'now' : 'todo'}" type="button" data-act="deal-cycle" data-key="${esc(c.key)}" title="${esc(t.deal.cycle)}" aria-label="${esc(c.name + ': ' + t.deal[c.state])}"></button>
      <span><b>${esc(c.name)}</b> <span class="meta">${esc(t.deal[c.state])}</span>${c.what ? `<br>${esc(c.what)}` : ''}${c.quote ? `<br><span class="meta">"${esc(c.quote)}"${c.t ? ' · ' + esc(c.t) : ''}</span>` : ''}</span></div>`).join('');
    const list = (h, xs) => xs.length ? `<h4 class="grp">${esc(h)}</h4>${xs.map((x) => `<div class="onme-item">${esc(x)}</div>`).join('')}` : '';
    return `<h4 class="grp">${esc(d.name)}</h4>${rows}${list(t.deal.objections, d.objections)}<h4 class="grp">${esc(t.deal.next)}</h4><div class="onme-item${d.nextStep ? '' : ' meta'}">${esc(d.nextStep || t.deal.noNext)}</div>${list(t.deal.signals, d.signals)}`;
  }

  function openOnMeCount() {
    const pend = S.minePending.filter((p) => !S.onMe.some((o) => o.from === p.tag)).length;
    return S.onMe.filter((o) => !o.done).length + pend + (S.openItems || []).filter((o) => !o.done && o.mine !== false).length
      + (S.notionItems || []).filter((o) => !o.done).length;
  }
  const TRASH = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><path d="M2.5 4h11M6 4V2.5h4V4M4 4l.7 9.5h6.6L12 4"/></svg>';
  function mine(text, fromId, fromText) {
    S.mineN += 1;
    const tag = 'mine' + S.mineN;
    S.minePending.push({ tag, text: String(text || '').slice(0, 160) });
    post('onme-mine', { text: String(text || ''), fromId: fromId || '', fromText: fromText || '' });
    render();
  }

  function renderMenu() {
    const m = $('menu'), t = T().menu, k = S.keys;
    m.hidden = !S.ui.menuOpen;
    if (!S.ui.menuOpen) return;
    // 0.8 (spec 3.7): pause and the microphone live in the top bar, not repeated here.
    const items = [
      // 0.8.7 (L2): without a deck the item stays, greyed, with the condition; a click attaches a deck
      (S.steps.length || S.call.presType) ? ['present', presenting() ? t.stopPresent : t.present, k.present] : ['present-off', t.present, '', t.presentNeedDeck],
      ['compact', S.call.mode === 'compact' ? t.full : t.compact, k.compact],
      S.call.mode === 'compact' ? null : ['hero', heroOffNow() ? t.heroShow : t.heroHide, ''],
      ['transcript', t.transcript, ''], ['brief', t.brief, ''],
      '-',
      ['clear-speakers', t.clearSpeakers, ''],
      ['switch-call', t.switchCall, ''], ['settings', t.settings, '⌘,']
    ].filter(Boolean);
    m.innerHTML = items.map((i) => i === '-' ? '<div class="sep"></div>' : i[3]
      ? `<button type="button" role="menuitem" class="off" aria-disabled="true" title="${esc(i[3])}" data-act="menu" data-item="${i[0]}"><span>${esc(i[1])}<small>${esc(i[3])}</small></span><kbd>${esc(i[2])}</kbd></button>`
      : `<button type="button" role="menuitem" data-act="menu" data-item="${i[0]}"><span>${esc(i[1])}</span><kbd>${esc(i[2])}</kbd></button>`).join('');
  }

  function tick() {
    const start = S.call.startedAt;
    if (start) {
      const s = Math.max(0, Math.floor((Date.now() - start) / 1000));
      const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
      $('timer').textContent = (h ? h + ':' + String(m).padStart(2, '0') : String(m).padStart(2, '0')) + ':' + String(sec).padStart(2, '0');
    }
  }

  let lastToast = 0, toastTimer = null;
  // 0.8.7 (L3): once, on the first real call, the three shortcuts for 20 seconds; a click closes it
  function firstCallHint() {
    if (PREFS.firstCallHintShown === '1' || PREFS.demo === '1' || S.call.state !== 'live' || !S.call.startedAt) return;
    PREFS.firstCallHintShown = '1';
    post('pref', { k: 'firstCallHintShown', v: '1' });
    const k = Object.assign({}, S.keys, PREFS.keys || {});
    const el = $('toast');
    el.textContent = T().firstHint({ h: k.help, t: k.compact, l: k.proactive || '⌃⌥L' });
    el.className = 'toast show first';
    el.onclick = () => { el.className = 'toast'; el.onclick = null; };
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { el.className = 'toast'; }, 20000);
  }

  function showToast(tst) {
    if (!tst || tst.at === lastToast) return;
    lastToast = tst.at;
    const el = $('toast'); el.textContent = tst.text; el.className = 'toast show ' + (tst.kind || '');
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { el.className = 'toast'; }, 2600);
  }

  // ---------- Speaker naming popover ----------
  function lineKey(l) { return (l.t || '') + '|' + String(l.text || '').slice(0, 40); }
  /** A line nobody's voice was matched to: say who said it. Applied to the transcript file after the call. */
  /** 0.8.5 (owner): under the anchor, or above it when the window has no room below (a name near the bottom). */
  function placePop(pop, r) {
    const h = pop.offsetHeight, room = window.innerHeight - 8;
    let top = r.bottom + 6;
    if (top + h > room) top = r.top - h - 6 >= 8 ? r.top - h - 6 : Math.max(8, room - h);
    pop.style.top = top + 'px';
  }
  function openLinePopover(i, anchor) {
    const l = S.transcript[+i];
    if (!l || !l.t) return;
    openWhoSheet({ line: l, anchor });
  }

  function openNamePopover(sid, anchor) { openWhoSheet({ sid, anchor }); }

  /** 2026-11-05 (owner): one sheet for naming a voice or a line: the name with the people of this meeting as a list
   *  inside the sheet (no system dropdown over the controls), and Team / Client always there, chosen on purpose. */
  function openWhoSheet({ sid, line, anchor }) {
    const t = T(), pop = $('pop'), sp = sid ? (S.speakers[sid] || {}) : {};
    const r = anchor.getBoundingClientRect();
    const sideOf = (n) => { const x = Object.values(S.speakers).find((v) => v && v.name === n); return (x && x.side) || (S.rosterSide && S.rosterSide[n]) || ''; };
    // 2026-11-05 (owner): every name says why it is offered; an invitation of 3 people offers those 3 first, the voice
    // library only on a click (or when typing).
    const people = [];
    const addP = (name, score, why) => { if (!name || name === t.me || name === t.them || people.some((p) => p.name === name)) return; people.push({ name, score, why }); };
    (sp.suggestions || []).forEach((x) => addP(x.name, x.score, x.score == null ? ((S.knownSrc || {})[x.name] || 'invited') : 'voice'));
    Object.entries(S.speakers).forEach(([k, v]) => v && k !== sid && addP(v.name, null, 'call'));
    (S.knownNames || []).forEach((n) => addP(n, null, (S.knownSrc || {})[n] || 'project'));
    let libOpen = false;
    let name = sid ? (sp.name || '') : (S.ui.lineWho[lineKey(line)] || '');
    let side = sid ? (sp.side === 'team' || sp.side === 'client' ? sp.side : (name ? sideOf(name) : '')) : (name ? sideOf(name) : '');
    const quote = sid ? sp.lastQuote : line.text;
    pop.classList.add('who');
    pop.innerHTML = `<div class="who-h"><b>${esc(sid ? t.whoTitle : t.whoLine)}</b>${sid && (sp.label || sp.seconds) ? `<span class="meta">${esc(sp.label || '')}${sp.seconds ? ' · ' + esc(t.secsSpoken({ s: Math.round(sp.seconds) })) : ''}</span>` : ''}</div>
      ${quote ? `<div class="who-q">“${esc(String(quote).slice(0, 140))}”</div>` : ''}
      <input id="whoName" type="text" autocomplete="off" spellcheck="false" placeholder="${esc(t.typeName)}" aria-label="${esc(t.name)}" value="${esc(name)}">
      <div class="who-list" role="listbox" id="whoList"></div>
      <div class="who-sh meta">${esc(t.sideH)}</div>
      <div class="who-side" role="radiogroup">
        <button type="button" data-side="team" role="radio"><span class="dot team"></span><b>${esc(t.team)}</b><small>${esc(t.teamSub)}</small></button>
        <button type="button" data-side="client" role="radio"><span class="dot client"></span><b>${esc(t.client)}</b><small>${esc(t.clientSub)}</small></button>
      </div>
      <div class="who-f"><span class="who-err meta" id="whoErr">${esc(t.whoHint)}</span></div>`;
    const input = pop.querySelector('#whoName'), list = pop.querySelector('#whoList'), err = pop.querySelector('#whoErr');
    let typed = false;
    const paintSide = () => pop.querySelectorAll('[data-side]').forEach((b) => { b.setAttribute('aria-checked', String(b.dataset.side === side)); b.classList.toggle('on', b.dataset.side === side); });
    const chip = (p) => {
      const sd = sideOf(p.name), on = p.name === input.value.trim();
      return `<button type="button" class="who-chip${on ? ' on' : ''}" data-pick="${esc(p.name)}" title="${esc(t.whoGroups[p.why] || '')}"><span class="dot ${sd || 'unknown'}"></span>${esc(p.name)}${p.score == null ? '' : `<span class="pc">${Math.round(p.score * 100)}%</span>`}</button>`;
    };
    const paintList = () => {
      const q = input.value.trim().toLowerCase();
      const match = (p) => !typed || !q || p.name.toLowerCase().includes(q);
      const exact = people.some((p) => p.name.toLowerCase() === q);
      let html = '';
      for (const g of ['voice', 'call', 'invited', 'project', 'library']) {
        const rows = people.filter((p) => p.why === g && match(p));
        if (!rows.length) continue;
        if (g === 'library' && !libOpen && !(typed && q)) { html += `<button type="button" class="who-more" data-lib="1">${esc(t.whoMore({ n: rows.length }))}</button>`; continue; }
        html += `<div class="who-g"><div class="who-gh">${esc(t.whoGroups[g])}</div><div class="who-chips">${rows.map(chip).join('')}</div></div>`;
      }
      if (typed && q && !exact) html += `<div class="who-g"><div class="who-chips"><span class="who-chip new"><span class="dot unknown"></span>${esc(input.value.trim())}<span class="pc">${esc(t.newPerson)}</span></span></div></div>`;
      list.innerHTML = html; list.hidden = !html;
      list.title = t.whoWhy;
      const more = list.querySelector('[data-lib]'); if (more) more.onclick = () => { libOpen = true; paintList(); };
      list.querySelectorAll('[data-pick]').forEach((b) => b.onclick = () => {
        input.value = b.dataset.pick; const sd = sideOf(b.dataset.pick); if (sd) side = sd;
        paintSide(); paintList();
        save();          // a known side saves now; without one the sheet asks for Team or Client
      });
    };
    // 2026-11-05 (owner): no Save: a person and a side are enough, the sheet saves at once (click again to change)
    pop.querySelectorAll('[data-side]').forEach((b) => b.onclick = () => { side = b.dataset.side; paintSide(); if (input.value.trim()) save(); else { err.textContent = t.whoNeedName; input.focus(); } });
    const close = () => { pop.hidden = true; pop.classList.remove('who'); };
    const save = () => {
      const nm = input.value.replace(/\s+/g, ' ').replace(/\|/g, ' ').trim().slice(0, 60);
      if (!nm) { input.focus(); return; }
      if (side !== 'team' && side !== 'client') { err.textContent = t.pickSide; err.classList.add('ask'); return; }
      S.rosterSide = Object.assign({}, S.rosterSide, { [nm]: side });
      if (sid) {
        S.speakers[sid] = Object.assign({}, sp, { name: nm, side, suggestions: [] });
        if (feed) feed.speakers[sid] = Object.assign({}, feed.speakers[sid], { name: nm, side, suggestions: [] });
        post('name-speaker', { speakerId: sid, name: nm, side });
        if (S.ui.spkCard === sid) S.ui.spkCard = null;
      } else {
        S.ui.lineWho[lineKey(line)] = nm;
        post('setting', { key: 'line_who', value: line.t + '|' + String(line.text || '').slice(0, 40).replace(/\|/g, ' ') + '|' + nm });
        showToast({ text: t.lineWhoSaved, kind: 'ok', at: Date.now() });
      }
      close(); render();
    };
    input.oninput = () => { typed = true; const sd = sideOf(input.value.trim()); if (sd) { side = sd; paintSide(); } paintList(); };
    input.onkeydown = (e) => { if (e.key === 'Enter') save(); if (e.key === 'Escape') close(); e.stopPropagation(); };
    paintSide(); paintList();
    pop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 316)) + 'px';
    pop.hidden = false; placePop(pop, r);
    input.focus(); input.select();
  }


  // ---------- Actions ----------
  function setMode(mode) { S.call.mode = mode === 'compact' ? 'compact' : 'normal'; render(); }
  function togglePause() {
    S.call.paused = !S.call.paused;
    post('setting', { key: 'tips_paused', value: S.call.paused ? 'on' : 'off' });
    render();
  }
  const MIC_ON = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><rect x="5.5" y="1.5" width="5" height="8" rx="2.5"/><path d="M3 7.5a5 5 0 0 0 10 0M8 12.5v2"/></svg>';
  const MIC_OFF = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><rect x="5.5" y="1.5" width="5" height="8" rx="2.5"/><path d="M3 7.5a5 5 0 0 0 10 0M8 12.5v2M2 2l12 12"/></svg>';
  // 2026-11-05 (owner): one family for pause, play, stop and Home: 16 px, rounded, the same weight
  const PAUSE = '<svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><rect x="4" y="3" width="2.8" height="10" rx="1.2" fill="currentColor"/><rect x="9.2" y="3" width="2.8" height="10" rx="1.2" fill="currentColor"/></svg>';
  const PLAY = '<svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="M5 3.9c0-.9 1-1.4 1.7-.9l6 3.9c.7.5.7 1.6 0 2.1l-6 3.9c-.7.5-1.7 0-1.7-.9z" fill="currentColor"/></svg>';
  const STOP = '<svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><rect x="3.5" y="3.5" width="9" height="9" rx="2.2" fill="currentColor"/></svg>';
  const BULB = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><path d="M5.6 11.5c0-1.6-2.1-2.6-2.1-5.1a4.5 4.5 0 0 1 9 0c0 2.5-2.1 3.5-2.1 5.1z"/><path d="M6 13.5h4M6.8 15h2.4"/></svg>';
  /** Proactive tips: the PM's click in this call, else the recorder status, else the remembered choice. */
  function proactiveOn() {
    if (S.ui.proactive != null) return S.ui.proactive;
    if (S.call.proactive != null) return !!S.call.proactive;
    return String((PREFS && PREFS.proactive) || '') === '1';
  }
  function toggleProactive() {
    S.ui.proactive = !proactiveOn();
    post('setting', { key: 'proactive', value: S.ui.proactive ? 'on' : 'off' });
    render();
  }
  function toggleMute() {
    S.call.micOff = !S.call.micOff;
    post('mute', { on: S.call.micOff });
    render();
  }
  function isWide() { return !$('app').classList.contains('pm-split') && $('app').clientWidth >= 760; }   // 0.9.7: no side pane in the split view
  // A window made wide with a sheet open: the sheet becomes the side pane (render() moves it).
  // 0.8.5: the presentation rail shows from 560 px, so a resize redraws it.
  let resizeT = null;
  window.addEventListener('resize', () => { if (S.ui.sheet && isWide()) { render(); return; } });
  function openTab(tab) { if (isWide()) S.ui.paneTab = tab; else S.ui.sheet = tab; render(); }
  function cardKey(c) { return (c.card || '') + '|' + (c.t || '') + '|' + String((c.raw && c.raw.gist) || '').slice(0, 60); }

  document.addEventListener('toggle', (e) => {
    const d = e.target; if (!d || !d.dataset || !d.dataset.pt) return;
    if (d.open) S.ui.openPts[d.dataset.pt] = true; else delete S.ui.openPts[d.dataset.pt];
  }, true);
  document.addEventListener('click', (e) => {
    if (selectingText() && !e.target.closest('button,input,textarea,label,a,select')) return;   // 2026-11-10: a text selection, not a click
    if (e.target.closest('button,[data-act]')) { const sel = window.getSelection(); if (sel && !sel.isCollapsed) sel.removeAllRanges(); }   // a real click: the redraw goes ahead
    const b = e.target.closest('[data-act]');
    if (!$('menu').hidden && !e.target.closest('#menu') && !e.target.closest('#moreBtn')) { S.ui.menuOpen = false; renderMenu(); }
    // 2026-11-05: composedPath, not closest: a chip re-drawn by its own click is detached and looked like a click outside
    if (!$('pop').hidden && !e.composedPath().includes($('pop')) && !(b && (b.dataset.act === 'name' || b.dataset.act === 'line-who'))) $('pop').hidden = true;
    if (S.ui.delArm && !(b && b.dataset.act === 'line-del')) { S.ui.delArm = null; if (!b) render(); }
    if (S.ui.recMenu && !e.target.closest('#recCtl')) { S.ui.recMenu = false; if (!b) render(); }   // 0.9.5
    if (!b) return;
    const act = b.dataset.act, id = b.dataset.id;
    const card = id && S.cards.find((c) => c.id === id);
    switch (act) {
      case 'correct-context':
        $('askInput').value = '/context ' + $('askInput').value.replace(/^\/context\s*/i, '');
        $('askInput').focus();
        showToast({ text: S.lang === 'uk' ? 'Напиши, з ким дзвінок, його мету та потрібний документ. Enter оновить підготовку.' : 'Enter the participant, goal and source document. Press Enter to update preparation.', kind: 'info', at: Date.now() });
        return;
      case 'brief-full': S.ui.briefFull = !S.ui.briefFull; render(); return;
      case 'liveprep': post('liveprep', { a: 'start' }); if (feed) feed.setPrep({ state: 'running', progress: 0 }); return;
      case 'liveprep-cancel': post('liveprep', { a: 'cancel' }); return;
      case 'said':
        if (card) { card.state = 'done'; card.rating = { v: 'used', reasons: [], comment: '' }; if (feed) feed.mark(id, { state: 'done', rating: card.rating }); post('said', { id, key: cardKey(card) }); usage('tip_action', { kind: String((card.raw || {}).kind || 'tip').slice(0, 40), action: 'say' }); }
        S.ui.heroOverride = null; break;
      case 'rate': {
        if (!card) return;
        const v = b.dataset.v, prev = card.rating || {};
        card.rating = { v, reasons: v === prev.v ? (prev.reasons || []) : [], comment: v === prev.v ? (prev.comment || '') : '' };
        S.ui.rateOpen = v === 'used' ? null : id;
        if (feed) feed.mark(id, { rating: card.rating });   // 0.9.4 fix: the feed hands out fresh card copies, a rating kept only on the copy vanished on the next update
        sendRate(card); e.stopPropagation(); break;
      }
      case 'rate-reason': {
        if (!card || !card.rating) return;
        const r = b.dataset.r, list = card.rating.reasons || [];
        const box = $('hero').querySelector('.ratebox input'); if (box) card.rating.comment = box.value;
        card.rating.reasons = list.includes(r) ? list.filter((x) => x !== r) : list.concat(r);
        if (feed) feed.mark(id, { rating: card.rating });
        e.stopPropagation(); break;
      }
      case 'rate-save': {
        if (!card || !card.rating) return;
        const box = $('hero').querySelector('.ratebox input'); if (box) card.rating.comment = box.value.trim();
        if (feed) feed.mark(id, { rating: card.rating });
        S.ui.rateOpen = null; sendRate(card); showToast({ text: T().rateThanks, kind: 'info', at: Date.now() });
        e.stopPropagation(); break;
      }
      case 'rate-skip': S.ui.rateOpen = null; e.stopPropagation(); break;
      case 'hide':
        if (card) { card.state = 'hidden'; if (feed) feed.mark(id, { state: 'hidden' }); post('hide', { id, key: cardKey(card) }); usage('tip_action', { kind: String((card.raw || {}).kind || 'tip').slice(0, 40), action: 'hide' }); }
        S.ui.heroOverride = null; e.stopPropagation(); break;
      case 'pin':
        if (card) { card.pinned = !card.pinned; if (feed) feed.mark(id, { pinned: card.pinned }); post('pin', { id, pinned: card.pinned }); usage('tip_action', { kind: String((card.raw || {}).kind || 'tip').slice(0, 40), action: 'pin' }); }
        e.stopPropagation(); break;
      case 'shorter': if (card) post('shorter', { id, say: card.say, question: card.question || '' }); return;
      case 'edit': S.ui.editing = id; break;
      case 'edit-cancel': S.ui.editing = null; break;
      case 'edit-save': {
        const el = $('hero').querySelector('.say');
        const v = el ? el.textContent.replace(/\s+/g, ' ').trim() : '';
        S.ui.editing = null;
        if (card && v && v !== card.say) {
          const raw = card.raw || {};
          post('edit', { id, card: card.card || '', kind: raw.kind || 'tip', t: card.t || '',
                         before: { gist: raw.gist || '', phrase: raw.phrase || '', items: raw.items || [] },
                         after: { gist: raw.gist || '', phrase: v, items: raw.items || [] } });
          card.say = v; if (feed) feed.edit(id, v);
        }
        break;
      }
      case 'promote': {
        // 0.8.5 (owner): picking the card the window would show anyway (the newest) returns to the automatic order.
        const keep = S.ui.heroOverride; S.ui.heroOverride = null;
        const auto = pickHero(visibleCards());
        S.ui.heroOverride = auto && auto.id === id ? null : (id || keep);
        break;
      }
      case 'hero-auto': S.ui.heroOverride = null; break;
      case 'hero-show': setHeroOff(false); S.ui.heroOverride = null; break;
      case 'after': post('after', Object.assign({ item: b.dataset.item }, draftNow())); return;
      case 'commit-done': {
        if (!card || !card.commit) return;
        card.state = 'done'; if (feed) feed.commitDone(id);
        post('commitment-done', { id: card.commit.id, text: card.commit.text });
        e.stopPropagation(); break;
      }
      case 'agenda-undo': post('agenda-undo', {}); break;
      case 'agenda-toggle': S.ui.agendaOpen = !S.ui.agendaOpen; break;
      case 'sheetq': if (feed && feed.toggleQuestion) feed.toggleQuestion(id); break;   // 0.10.0: the PM ticks a sheet question
      case 'theirs-toggle': S.ui.theirsOpen = !(b.getAttribute('aria-expanded') === 'true'); break;
      case 'home': post('menu', { item: 'home' }); return;
      case 'hero-min': S.ui.heroMin[id] = !S.ui.heroMin[id]; break;   // 2026-11-02: the speech card folds to its first line
      case 'agenda': {
        const a = S.agenda.find((x) => x.id === id); if (!a) return;
        const nextState = { todo: 'now', now: 'done', raised: 'done', done: 'skip', skip: 'todo' }[a.state] || 'todo';   // 2026-11-03: skip = not relevant
        a.state = nextState; if (feed) feed.setAgendaState(id, nextState);
        post('agenda', { id, title: a.title, state: nextState });
        break;
      }
      case 'pane-tab': S.ui.paneTab = b.dataset.tab; S.ui.briefEdit = false; break;
      case 'deal-cycle': {
        const c = S.deal && S.deal.criteria.find((x) => x.key === b.dataset.key);
        if (c) {
          c.state = c.state === 'unknown' ? 'partial' : c.state === 'partial' ? 'known' : 'unknown';
          S.deal.known = S.deal.criteria.filter((x) => x.state === 'known').length;
          post('setting', { key: 'deal_fix', value: `${c.key}|${c.state}|${c.what || ''}` });
        }
        break;
      }
      case 'sheet-tab': S.ui.sheet = b.dataset.tab; S.ui.briefEdit = false; break;
      case 'close-sheet': S.ui.sheet = null; S.ui.briefEdit = false; break;
      case 'follow': S.ui.follow = true; break;
      case 'name': openNamePopover(b.dataset.sid, b); return;
      case 'name-pick': {   // 0.8.5 fix: one click on a suggested name from the voice library
        const sid = b.dataset.sid, name = b.dataset.name, sp = S.speakers[sid] || {};
        const side = (S.rosterSide && S.rosterSide[name]) || sp.side || 'team';
        S.speakers[sid] = Object.assign({}, sp, { name, side, suggestions: [] });
        if (feed) feed.speakers[sid] = Object.assign({}, feed.speakers[sid], { name, side, suggestions: [] });
        post('name-speaker', { speakerId: sid, name, side });
        render(); return;
      }
      case 'line-who': openLinePopover(b.dataset.i, b); return;
      case 'spk-toggle': {
        const vis = !!document.querySelector('.spk-card');
        S.ui.spkOpen = !vis;
        if (S.ui.spkOpen && !cardVoice(speakerList())) { const u = speakerList().find(([, sp]) => !sp.name); if (u) { S.ui.spkCard = u[0]; delete S.ui.spkSnooze[u[0]]; } }
        render(); return;
      }
      case 'spk-card': S.ui.spkCard = b.dataset.sid; S.ui.spkOpen = true; delete S.ui.spkSnooze[b.dataset.sid]; render(); return;
      case 'spk-who': openWhoSheet({ sid: b.dataset.sid, anchor: b }); return;      // 2026-11-05: the card's Name this voice
      case 'spk-notnow': {   // 0.8.6 (F3): the card of this voice waits for its next 60 s of speech
        const sid = b.dataset.sid; S.ui.spkSnooze[sid] = (S.speakers[sid] || {}).seconds || 0;
        if (S.ui.spkCard === sid) S.ui.spkCard = null;
        render(); return;
      }
      case 'line-mine': { const l = S.transcript[+b.dataset.i]; if (l) mine(l.text, '', ''); return; }
      case 'ext-mine': { const o = (S.openItems || []).find((x) => x.id === b.dataset.id); if (o) mine(o.text, o.id, o.text); return; }
      case 'ext-remove': post('onme-remove', { id: b.dataset.id }); S.openItems = (S.openItems || []).filter((x) => x.id !== b.dataset.id); S.notionItems = (S.notionItems || []).filter((x) => x.id !== b.dataset.id); render(); return;
      case 'spk-side': {
        const sid = b.dataset.sid, side = b.dataset.side, sp = S.speakers[sid] || {};
        S.speakers[sid] = Object.assign({}, sp, { side });
        if (feed) feed.speakers[sid] = Object.assign({}, feed.speakers[sid], { side });
        post('setting', { key: 'speaker_side', value: sid + '|' + side });
        render(); return;
      }
      case 'line-del': case 'line-undel': {
        const l = S.transcript[+b.dataset.i]; if (!l || !l.t) return;
        const k = lineKey(l), v = l.t + '|' + String(l.text || '').slice(0, 40).replace(/\|/g, ' ');
        if (act === 'line-undel') { delete S.ui.lineDel[k]; post('setting', { key: 'line_undelete', value: v }); }
        else if (S.ui.delArm !== k) { S.ui.delArm = k; render(); return; }
        else { S.ui.lineDel[k] = true; S.ui.delArm = null; post('setting', { key: 'line_delete', value: v }); showToast({ text: T().lineDeleted, kind: 'ok', at: Date.now() }); }
        render(); return;
      }
      case 'onme-edit': S.ui.onmeEdit = id; render(); { const i = $('onmeEditInput'); if (i) { i.focus(); i.select(); i.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); i.parentNode.querySelector('[data-act=onme-save]').click(); } if (e.key === 'Escape') { S.ui.onmeEdit = null; render(); } e.stopPropagation(); }; } } return;
      case 'onme-cancel': S.ui.onmeEdit = null; render(); return;
      case 'onme-save': case 'onme-notmine': {
        const o = S.onMe.find((x) => x.id === id); if (!o) return;
        const v = act === 'onme-notmine' ? '' : (($('onmeEditInput') || {}).value || '').replace(/\s+/g, ' ').trim();
        if (act === 'onme-save' && (!v || v === o.text)) { S.ui.onmeEdit = null; render(); return; }
        S.ui.onmeEdit = null;
        if (feed) feed.fixOnMe(id, v); else S.onMe = S.onMe.filter((x) => x.id !== id);
        post('onme-fix', { id, text: o.text, newText: v });
        render(); return;
      }
      case 'onme-toggle': {
        const o = S.onMe.find((x) => x.id === id);
        if (o) { o.done = b.checked; if (feed) feed.toggleOnMe(id, o.done); post('onme-toggle', { id, done: o.done, text: o.text }); }
        break;
      }
      case 'start': S.call.state = 'live'; post('start'); break;
      case 'rec-menu': S.ui.recMenu = !S.ui.recMenu; break;
      case 'rec-start': S.ui.recMenu = false; S.rec = Object.assign({}, S.rec, { state: 'starting' }); post('rec', { a: 'start', kind: b.dataset.kind || 'video' }); break;
      case 'rec-pause': S.ui.recMenu = false; post('rec', { a: 'pause' }); return;
      case 'rec-resume': S.ui.recMenu = false; post('rec', { a: 'resume' }); return;
      case 'rec-stop': S.ui.recMenu = false; post('rec', { a: 'stop' }); break;
      case 'rec-source': S.ui.recMenu = false; post('rec', { a: 'source' }); break;
      case 'rec-settings': S.ui.recMenu = false; post('rec', { a: 'settings' }); break;
      case 'rec-arm': S.rec = Object.assign({}, S.rec, { arm: Object.assign({}, (S.rec || {}).arm, { kind: b.dataset.kind }) }); post('rec', { a: 'arm', kind: b.dataset.kind }); break;
      case 'rec-arm-pick': post('rec', { a: 'arm-pick' }); return;
      case 'open-brief': openTab('brief'); return;
      case 'brief-edit': S.ui.briefEdit = true; break;
      case 'brief-cancel': S.ui.briefEdit = false; break;
      case 'brief-save': {
        const v = $('briefEdit') ? $('briefEdit').value : '';
        S.ui.briefEdit = false;
        if (v && v !== S.briefText) { post('prepdoc', { text: v }); if (feed) feed.setPrepDoc({ text: v, at: feed.briefAt }); }
        break;
      }
      case 'prepare-next': post('prepare-next', { id: S.next && S.next.id }); return;
      case 'open-next': post('open-next', { id: S.next && S.next.id }); return;
      case 'present-next': case 'dk-next': dkNext(); return;
      case 'present-prev': case 'dk-prev': dkJump(DK.idx - 1); return;
      case 'slide-go': goSlide(+b.dataset.n, 'manual'); return;
      // 0.9.7: the 0.7.5 controls (rules/presentation.yaml > window)
      case 'dk-start': { const first = DK.elapsed === 0 && !DK.running; dkStartStop(); if (first) dkSetCur(DK.idx, false, false, 'manual'); return; }
      case 'dk-auto': DK.auto = !DK.auto; dkPref('deck_auto', DK.auto ? '1' : '0'); DK.offset = DK.auto ? DK.cs[DK.idx] - DK.elapsed : 0; dkUpdate(); return;
      case 'dk-comp': DK.compress = !DK.compress; dkUpdate(); return;
      case 'dk-snd': DK.sound = !DK.sound; dkPref('deck_sound', DK.sound ? '1' : '0'); dkUpdate(); return;
      case 'dk-reset': dkReset(); return;
      case 'dk-swap': DK.swap = !DK.swap; dkPref('deck_swap', DK.swap ? '1' : '0'); $('app').classList.toggle('pm-swap', DK.swap); dkUpdate(); return;
      case 'dk-split': DK.split = !DK.isSplit; dkPref('deck_split', DK.split ? '1' : '0'); render(); return;
      case 'dk-seg': dkJump(+b.dataset.i); return;
      case 'dk-take': { const n = +b.dataset.n; DK.open[n] = !DK.open[n]; render(); return; }
      case 'dk-close': { const w = $('dkWrap'); if (w) w.classList.remove('on'); return; }
      case 'add30': add30(+b.dataset.n); return;
      case 'stop-follow': S.syncA = null; post('stop-follow'); render(); return;
      case 'attach-deck': post('attach-deck'); return;
      case 'tips-lang': {
        const tl = S.tipsLang; if (!tl) return;
        const cur = tl.current || tl.meeting; tl.current = cur === 'uk' ? 'en' : 'uk';
        post('setting', { key: 'tips_lang', value: tl.current }); render(); return;
      }
      case 'meetend-stop': post('meetend', { item: 'stop' }); S.meetEnd = null; render(); return;
      case 'meetend-keep': post('meetend', { item: 'keep' }); S.meetEnd = null; render(); return;
      case 'sys-restart': post('sys', { item: 'restart' }); return;
      case 'sys-check': post('sys', { item: 'check' }); return;
      case 'sys-more': S.ui.sysOpen = !(S.ui.sysOpen == null ? (S.sys && S.sys.kind === 'notRecording') : S.ui.sysOpen); break;
      case 'menu': {
        const item = b.dataset.item; S.ui.menuOpen = false;
        if (item === 'hero') { setHeroOff(!heroOffNow()); S.ui.heroOverride = null; }
        else if (item === 'compact') { S.call.mode = S.call.mode === 'compact' ? 'normal' : 'compact'; post('compact', { on: S.call.mode === 'compact' }); }
        else if (item === 'present-off') { post('attach-deck'); render(); return; }
        else if (item === 'present') { S.ui.presentForced = !presenting(); post('setting', { key: 'call_type', value: S.ui.presentForced ? 'presentation' : 'auto' }); }
        else if (item === 'transcript' || item === 'brief') { openTab(item); return; }
        else if (item === 'pause') { togglePause(); return; }
        else if (item === 'mute') { toggleMute(); return; }
        else post('menu', { item });
        break;
      }
      default: return;
    }
    render();
  });
  // 0.8.6: ticks on register and Notion items, "Same person as", the card's name field and "Add to On me"
  document.addEventListener('change', (e) => {
    if (e.target && e.target.id === 'dkMode') {   // 0.9.7: My slides / All slides
      DK.mode = e.target.value === 'mine' ? 'mine' : 'all'; dkPref('deck_mode', DK.mode);
      if (!DK.running) Object.assign(DK, { elapsed: 0, offset: 0, enter: {}, warned: {}, finished: false, entryLag: 0 });
      render(); return;
    }
    if (e.target && e.target.id === 'dkMin') {    // 0.9.7: the talk time in minutes; the slide budgets scale to it
      let x = parseInt(e.target.value, 10); if (!x || x < 1) x = 1; if (x > 180) x = 180;
      DK.min = x; render(); return;
    }
    const el = e.target;
    if (el.dataset && el.dataset.act === 'ext-toggle') {
      const id = el.dataset.id, done = el.checked;
      for (const k of ['openItems', 'notionItems']) S[k] = (S[k] || []).map((x) => x.id === id ? Object.assign({}, x, { done }) : x);
      post('ext-tick', { id, done }); render();
    } else if (el.classList && el.classList.contains('spk-same') && el.value) {
      post('setting', { key: 'speaker_merge', value: el.dataset.sid + '|' + el.value });
      const to = S.speakers[el.value] || {};
      S.speakers[el.dataset.sid] = Object.assign({}, S.speakers[el.dataset.sid], { name: to.name, side: to.side });
      if (S.ui.spkCard === el.dataset.sid) S.ui.spkCard = null;
      render();
    }
  });
  document.addEventListener('keydown', (e) => {
    if (e.target && e.target.matches && e.target.matches('.ratebox input')) {   // 0.9.4: the rating comment
      if (e.key === 'Enter') { e.preventDefault(); const sb = e.target.closest('.ratebox').querySelector('[data-act=rate-save]'); if (sb) sb.click(); }
      else if (e.key === 'Escape') { S.ui.rateOpen = null; render(); }
      e.stopPropagation(); return;
    }
    if (e.key === 'Enter' && e.target && e.target.id === 'spkCardName') {
      const sid = e.target.dataset.sid, name = e.target.value.replace(/\s+/g, ' ').trim().slice(0, 60);
      if (!name) return;
      e.preventDefault();
      const sp = S.speakers[sid] || {}, side = sp.side || (S.rosterSide && S.rosterSide[name]) || 'client';
      S.speakers[sid] = Object.assign({}, sp, { name, side, suggestions: [] });
      if (feed) feed.speakers[sid] = Object.assign({}, feed.speakers[sid], { name, side, suggestions: [] });
      post('name-speaker', { speakerId: sid, name, side });
      e.target.blur(); if (S.ui.spkCard === sid) S.ui.spkCard = null; render(); return;
    }
    if (e.key === 'Enter' && e.target && e.target.id === 'onmeAdd') {
      const v = e.target.value.replace(/\s+/g, ' ').trim();
      if (!v) return;
      e.preventDefault(); e.target.value = ''; e.target.blur();
      S.mineN += 1; const tag = 'mine' + S.mineN;
      S.minePending.push({ tag, text: v.slice(0, 160) });
      post('onme-mine', { text: v, fromId: '', fromText: '', typed: true });
      render(); return;
    }
    if (e.target.classList && e.target.classList.contains('row') && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); e.target.click(); }
    if (e.metaKey && (e.key === '=' || e.key === '+' || e.key === '-' || e.key === '0')) { e.preventDefault(); post('zoom', { step: e.key === '-' ? -1 : e.key === '0' ? 0 : 1 }); return; }
    if (e.metaKey && e.key === ',') { e.preventDefault(); post('menu', { item: 'settings' }); return; }
    const typing = e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA');
    if (e.key === 'Escape') {
      if (S.ui.editing) { S.ui.editing = null; render(); return; }
      S.ui.menuOpen = false; S.ui.recMenu = false; S.ui.sheet = null; S.ui.heroOverride = null; $('pop').hidden = true; render();
    }
  });
  $('moreBtn').addEventListener('click', () => { S.ui.menuOpen = !S.ui.menuOpen; renderMenu(); });
  $('micBtn').addEventListener('click', () => toggleMute());
  $('pauseBtn').addEventListener('click', () => togglePause());
  $('bulbBtn').addEventListener('click', () => toggleProactive());
  $('dealBtn').addEventListener('click', () => openTab('deal'));
  $('onmeBtn').addEventListener('click', () => { if (isWide()) { S.ui.paneTab = 'onme'; } else { S.ui.sheet = S.ui.sheet === 'onme' ? null : 'onme'; } render(); });
  $('helpBtn').addEventListener('click', () => post('help'));
  $('ask').addEventListener('submit', (e) => {
    e.preventDefault();
    const v = $('askInput').value.trim(); if (!v) return;
    if (/^\/context\s+/i.test(v)) {
      const text = v.replace(/^\/context\s+/i, '').trim();
      if (text) { post('correct-context', { text }); $('askInput').value = ''; }
      return;
    }
    // Prepared facts answer at once; Claude's answer follows as its own card.
    if (feed) feed.searchFacts(v).forEach((f, i) => feed.addItems([{ kind: 'fact', q: v, gist: f.text, note: f.source, uid: 'local-' + Date.now() + '-' + i, t: new Date().toTimeString().slice(0, 8) }]));
    post('ask', { text: v }); $('askInput').value = '';
  });
  document.addEventListener('scroll', (e) => {
    const pb = e.target;
    if (!pb || !pb.classList || !pb.classList.contains('panebody')) return;
    const atEnd = pb.scrollTop + pb.clientHeight >= pb.scrollHeight - 8;
    if (atEnd === S.ui.follow) return;
    S.ui.follow = atEnd;
    const f = pb.parentNode.querySelector('.panefoot');
    if (f) f.lastElementChild.outerHTML = atEnd ? `<span>${esc(T().following)}</span>` : `<button class="link" type="button" data-act="follow">${esc(T().jump)}</button>`;
  }, true);
  setInterval(() => { tick(); }, 1000);
  setInterval(() => { if (!S.ui.editing && !S.ui.briefEdit) render(); }, 30000);   // relative times, the 90 s hero rule

  // ---------- Public API ----------
  window.LiveTips = {
    setState(partial) {
      for (const k of Object.keys(partial || {})) {
        if (k === 'call') { const mode = S.call.mode; S.call = Object.assign({}, S.call, partial.call); if (!partial.call.mode) S.call.mode = mode; }
        else if (k === 'speakers' || k === 'keys') S[k] = Object.assign({}, S[k], partial[k]);
        else if (k === 'ui') S.ui = Object.assign({}, S.ui, partial.ui);
        else if (k === 'toast') showToast(partial.toast);
        else S[k] = partial[k];
      }
      if (S.ui.heroOverride && !S.cards.some((c) => c.id === S.ui.heroOverride)) S.ui.heroOverride = null;
      render();
    },
    setLang(l) { S.lang = STR[l] ? l : 'en'; if (feed) feed.emit(); render(); post('setting', { key: 'ui_lang', value: S.lang }); },
    setTheme(th) { S.theme = th; render(); },
    setOpacity(v) { document.documentElement.style.setProperty('--fade', String(Math.max(0.35, Math.min(1, +v || 1)))); },
    setMode,
    setKeys(k) { S.keys = Object.assign({}, S.keys, k); render(); },
    togglePause, toggleMute, toggleProactive, openTab,
    /** 0.8.5 shortcuts: 'prev' | 'next' | 'add30' | 'mode'. */
    presentKey(k) {
      if (k === 'mode') { S.ui.presentForced = !presenting(); render(); return; }
      if (!presenting() || !S.steps.length) return;
      if (k === 'prev') stepBy(-1); else if (k === 'next') stepBy(1); else if (k === 'add30' && dkCur()) add30(dkCur().n);
    },
    /** Sync A (app only): the slide number read from Keynote or PowerPoint; null when not following. */
    setFollow(f) { S.syncA = f && f.n ? { app: String(f.app || ''), n: +f.n } : null; if (S.syncA && !DK.list.length) renderPresentation(); if (S.syncA) goSlide(S.syncA.n, String(f.app || '').toLowerCase().includes('power') ? 'powerpoint' : 'keynote'); else render(); },
    setThumbs(t) { S.thumbs = t || {}; render(); },
    /** 2026-11-10: {left: seconds} while the call is about to stop because the meeting ended; null hides it. */
    setMeetEnd(m) { S.meetEnd = m && m.left != null ? { left: +m.left } : null; render(); },
    /** 0.8.5 (P7): the after-call screen: outcome, series, the follow-up draft. */
    setAfter(a) { S.after = a || null; render(); },
    /** 0.8.5: {meeting: 'uk', current: 'uk'}: the tips language and the meeting's. */
    /** 0.8.6 (D4): open register items of this project from earlier calls and the PM's Notion tasks:
     *  [{id, text, due, done, mine, owner, badge: 'CALL'|'N', status, fromCall, note}]; project = the group's name. */
    setOnYou(d) { S.openItems = (d && d.open) || []; S.notionItems = (d && d.notion) || []; S.notionProject = (d && d.project) || ''; render(); },
    setSpeakerPrompt(sec) { S.spkPrompt = +sec || 15; render(); },
    setTipsLang(t) { S.tipsLang = t && t.meeting ? { meeting: t.meeting, current: t.current || t.meeting } : null; render(); },
    help() { post('help'); },
    rename(title) { if (feed) feed.rename(title); },
    _state: S, _feed: feed
  };

  // The calls the app has always made (the item format is shared with the skill's window).
  if (feed) {
    window.addItems = (items) => feed.addItems(items);
    window.setStatus = (s) => feed.setStatus(s);
    window.addTranscript = (lines) => feed.addTranscript(lines);
    window.setSpeakers = (d) => feed.setSpeakers(d);
    window.setPrepDoc = (p) => feed.setPrepDoc(p);
    window.setPrep = (p) => feed.setPrep(p);
    window.setUpNext = (l) => feed.setUpNext(l);
    window.setStarting = () => { feed.starting = Date.now(); feed.emit(); };
    window.setEnding = () => { feed.ending = true; feed.emit(); };
    window.toastMsg = (m) => showToast({ text: String(m || ''), kind: 'warn', at: Date.now() });
    window.ackSetting = () => showToast({ text: tr('applied'), kind: 'ok', at: Date.now() });
    window.setUiLang = (l) => window.LiveTips.setLang(l);
    window.setPinned = () => {};
    window.enableGlass = () => {};
  }
  if (PREFS.opacity) window.LiveTips.setOpacity(PREFS.opacity);
  if (PREFS.keys) S.keys = Object.assign({}, S.keys, PREFS.keys);
  render();
  if (inApp) { post('setting', { key: 'ui_lang', value: S.lang }); post('ready'); }

  // ---------- Demo data when opened in a browser (?state=ready|empty, ?lang=uk, ?theme=dark, ?mode=compact|presentation, ?left=4) ----------
  if (!inApp) {
    const now = Date.now(), min = 60000;
    const q = new URLSearchParams(location.search);
    window.LiveTips.setState({
      lang: q.get('lang') || 'en', theme: q.get('theme') || 'auto',
      call: { title: 'Orbit weekly with the client', state: q.get('state') === 'ready' ? 'ready' : 'live', briefLine: 'Brief ready · 09:40',
              startedAt: q.get('state') === 'empty' ? now - 42000 : now - 32 * min - 14000, minutesLeft: Number(q.get('left') || 13),
              mode: q.get('mode') === 'compact' ? 'compact' : 'normal', recap: 'export on Tuesday, our QA tests week one, names from you by Friday.',
              presenting: q.get('mode') === 'presentation', presType: q.get('mode') === 'presentation' },
      agenda: [
        { id: 'a1', title: 'Export release date', state: 'done' },
        { id: 'a2', title: 'Who tests the pilot', state: 'now' },
        { id: 'a3', title: 'Test accounts', state: 'todo' }
      ],
      cards: q.get('state') ? [] : [
        { id: 'c5', kind: 'answer', who: 'Emily C.', question: 'Who tests the pilot?', say: 'Our QA covers the first week, then your team takes over.', source: 'Kick-off notes, 21 Oct: 5 pilot users, names by Friday', at: now - 10000, state: 'active', raw: {} },
        { id: 'c4', kind: 'turn', say: 'Pilot plan: 5 users, 2 weeks, starts Monday', at: now - 2 * min, state: 'active', raw: {} },
        { id: 'c3', kind: 'onme', say: 'Send the test account list today', at: now - 6 * min, state: 'active', raw: {} },
        { id: 'r:demo', kind: 'risk', quiet: true, who: 'David K.', say: 'If the API release slips, the pilot moves a week', at: now - 8 * min, state: 'active', raw: {} },
        { id: 'k:c-demo', kind: 'onme', quiet: true, say: 'Share the pilot schedule with Emily', commit: { id: 'c-demo', text: 'Share the pilot schedule with Emily', mine: true }, at: now - 7 * min, state: 'active', raw: {} },
        { id: 'c2', kind: 'docs', say: 'Pilot: 5 users, list from the client', meta: 'You searched: pilot users', source: 'kickoff-notes.md', at: now - 8 * min, state: 'active', raw: {} },
        { id: 'c1', kind: 'answer', who: 'Emily C.', question: 'When is the export live?', say: 'Tuesday, after the review', at: now - 12 * min, state: 'done', raw: {} }
      ],
      onMe: [ { id: 'o1', text: 'Send the test account list', due: 'Today' }, { id: 'o2', text: 'Add 2 support users to the pilot', due: 'This week' } ],
      next: { title: 'Team retro', startsInMin: 8, prepared: false },
      speakers: { S1: { name: 'Emily', side: 'client' }, me: { name: 'Me', side: 'team' }, S3: { name: 'David', side: 'client' }, S4: { name: '', label: 'Speaker 4' } },
      transcript: [
        { speakerId: 'S1', text: 'When is the export live for our users?' },
        { speakerId: 'me', text: 'It is on dev now, production on Tuesday after the review.' },
        { speakerId: 'S3', text: 'Good. And the test accounts, who sends those?' },
        { speakerId: 'me', text: 'I will send the list today.' },
        { speakerId: 'S4', text: 'Can we add two people from support to the pilot?' },
        { speakerId: 'S1', text: 'And who tests the pilot itself?' }
      ],
      brief: { goal: 'Agree the pilot plan and the export release date.', sections: [
        { title: 'Open from last call', items: ['Test accounts from the client (open)', 'Who tests the pilot (partly answered)'] },
        { title: 'Risks', items: ['Pilot slips if the test accounts are late'] } ] },
      steps: [
        { n: 1, title: 'Why a pilot', who: 'me', secs: 90, numbers: ['5 users', '2 weeks', '1 h a day'], say: [],
          body: [{ k: 'p', t: 'We want to know one thing before the full rollout: does the export save your team an hour a day?' },
                 { k: 'p', t: 'Five users for two weeks give us that answer with real work, not a demo.' },
                 { k: 's', t: 'Last quarter the manual export took about 6 hours a week per person.' }],
          qa: [{ q: 'Why only five users?', a: 'Five covers both teams and keeps support to one person.' }] },
        { n: 2, title: 'What we found in the CRM', who: 'other', speaker: 'Emily', secs: 120, numbers: ['216 calls', '4 meetings'],
          body: [{ k: 'p', t: 'Almost nothing in the CRM is logged by itself: all 216 calls this year were typed in by hand.' },
                 { k: 'c', t: 'Mike, do you know why the call notes stopped in January?' }] },
        { n: 3, title: 'Plan and dates', who: 'me', secs: 120, numbers: ['Monday', 'day 10'],
          body: [{ k: 'p', t: 'We start on Monday and review on day 10, so you get the numbers before the budget meeting.' },
                 { k: 'h', t: 'Pause for questions' }] },
        { n: 4, title: 'What we need from you', who: 'me', secs: 60, canSkip: true,
          body: [{ k: 'p', t: 'Two things from your side: the names by Friday and the test accounts by Thursday.' }] } ],
      deckMeta: { talkMin: 6, qaMin: 2 }
    });
  }

  // 0.9.1 (owner): drag the border between the tips and the side panel (Transcript, On me, Brief). The width is kept
  // in this window's storage (per Mac); double-click or Home key resets it. Arrows move it by 24 px.
  (function paneSplit() {
    const split = document.getElementById('split'), app = document.querySelector('.app');
    if (!split || !app) return;
    const KEY = 'pacenote.paneWidth', MIN = 260, MAIN_MIN = 360;
    const clamp = w => Math.round(Math.max(MIN, Math.min(w, app.clientWidth - MAIN_MIN)));
    const apply = w => { if (w) app.style.setProperty('--pane-w', clamp(w) + 'px'); else app.style.removeProperty('--pane-w'); };
    const save = w => { try { if (w) localStorage.setItem(KEY, String(w)); else localStorage.removeItem(KEY); } catch (e) {} };
    let saved = 0;
    try { saved = parseInt(localStorage.getItem(KEY) || '0', 10) || 0; } catch (e) {}
    if (saved) apply(saved);
    const current = () => { const p = document.getElementById('pane'); return p ? p.getBoundingClientRect().width : 0; };
    split.addEventListener('pointerdown', ev => {
      ev.preventDefault(); split.setPointerCapture(ev.pointerId); app.classList.add('resizing');
      const right = app.getBoundingClientRect().right;
      const move = e => { saved = clamp(right - e.clientX); apply(saved); };
      const up = () => { app.classList.remove('resizing'); split.removeEventListener('pointermove', move); split.removeEventListener('pointerup', up); split.removeEventListener('pointercancel', up); save(saved); };
      split.addEventListener('pointermove', move); split.addEventListener('pointerup', up); split.addEventListener('pointercancel', up);
    });
    split.addEventListener('dblclick', () => { saved = 0; apply(0); save(0); });
    split.addEventListener('keydown', e => {
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { saved = clamp(current() + (e.key === 'ArrowLeft' ? 24 : -24)); apply(saved); save(saved); e.preventDefault(); }
      else if (e.key === 'Home') { saved = 0; apply(0); save(0); e.preventDefault(); }
    });
    // a narrower window keeps the tips readable: the saved width is clamped again
    window.addEventListener('resize', () => { if (saved) apply(saved); });
  })();

  // 0.9.1 (owner): the open agenda's height. Drag its bottom edge; double-click or Home resets; arrows move by 24 px.
  (function agendaGrip() {
    const grip = document.getElementById('agendaGrip'), list = document.getElementById('agendaList'), app = document.querySelector('.app');
    if (!grip || !list || !app) return;
    const KEY = 'pacenote.agendaHeight', MIN = 60;
    const clamp = h => Math.round(Math.max(MIN, Math.min(h, window.innerHeight - 220)));
    const apply = h => { if (h) app.style.setProperty('--agenda-h', clamp(h) + 'px'); else app.style.removeProperty('--agenda-h'); };
    const save = h => { try { if (h) localStorage.setItem(KEY, String(h)); else localStorage.removeItem(KEY); } catch (e) {} };
    let saved = 0;
    try { saved = parseInt(localStorage.getItem(KEY) || '0', 10) || 0; } catch (e) {}
    if (saved) apply(saved);
    grip.addEventListener('pointerdown', ev => {
      ev.preventDefault(); grip.setPointerCapture(ev.pointerId); app.classList.add('resizing-v');
      const y0 = ev.clientY, h0 = list.getBoundingClientRect().height;
      const move = e => { saved = clamp(h0 + e.clientY - y0); apply(saved); };
      const up = () => { app.classList.remove('resizing-v'); grip.removeEventListener('pointermove', move); grip.removeEventListener('pointerup', up); grip.removeEventListener('pointercancel', up); save(saved); };
      grip.addEventListener('pointermove', move); grip.addEventListener('pointerup', up); grip.addEventListener('pointercancel', up);
    });
    grip.addEventListener('dblclick', () => { saved = 0; apply(0); save(0); });
    grip.addEventListener('keydown', e => {
      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') { saved = clamp(list.getBoundingClientRect().height + (e.key === 'ArrowDown' ? 24 : -24)); apply(saved); save(saved); e.preventDefault(); }
      else if (e.key === 'Home') { saved = 0; apply(0); save(0); e.preventDefault(); }
    });
    window.addEventListener('resize', () => { if (saved) apply(saved); });
  })();
})();
