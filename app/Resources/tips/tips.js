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
      micStalled: 'The microphone stopped', cantHear: "Can't hear the other side", asrBehind: (o) => `Transcription is ${o.n} s behind`,
      engineDeaf: 'Tips are not coming: end the call and start again',
      onMe: 'On me', more: 'More', earlier: 'Earlier',
      agenda: (a, b) => `Agenda ${a} of ${b}`, notRaised: 'Not raised yet:', allRaised: 'All agenda items raised',
      kinds: { answer: 'Answer', turn: 'Your turn', onme: 'On me', docs: 'From docs', finish: 'min left', neutral: 'Note', answered: 'Answered', risk: 'Risk' },
      afterCall: 'What next', callPage: 'Call page', followup: 'Draft follow-up email',
      asked: (w) => `${w} asked`, now: 'now', ago: (m) => `${m}m`,
      saidIt: 'Said it', notByVoice: 'On this meeting, not matched by voice', del: 'Delete', delConfirm: 'Click again to delete', delTip: 'Delete this line from the transcript', restore: 'Restore', lineDeleted: 'Line deleted: it leaves the transcript after the call', backAuto: 'Back to latest', shorter: 'Shorter', hide: 'Hide', pin: 'Pin', unpin: 'Unpin', edit: 'Edit', save: 'Save', cancel: 'Cancel',
      unverified: 'Not verified against documents',
      next: (t, m) => `${t} in ${m} min`, notPrepared: 'not prepared', ready: 'brief ready', preparing: 'preparing', prepare: 'Prepare', open: 'Open',
      ask: 'Ask about this project', help: 'Help',
      tabs: { transcript: 'Transcript', onme: (n) => `On me · ${n}`, brief: 'Brief' },
      newVoice: 'New voice:', name: 'Name', client: 'Client', team: 'Team', speakersH: 'Speakers', namedOf: (o) => `${o.n} of ${o.m} named`, notNamed: 'not named yet',
      legend: 'Client in purple, team in blue', following: 'Following live', jump: 'Jump to latest',
      ariaMic: 'Mute microphone', ariaPause: 'Pause listening', ariaProactive: 'Proactive tips',
      proactiveOn: 'Proactive tips: on', proactiveOff: 'Proactive tips: off', resumeShort: 'Resume',
      menu: { pause: 'Pause listening', resume: 'Resume listening', mute: 'Turn mic off', unmute: 'Turn mic on',
        compact: 'Compact mode', full: 'Full window', present: 'Presentation mode', stopPresent: 'Stop presenting',
        transcript: 'Transcript', brief: 'Brief', settings: 'Call settings…', switchCall: 'Switch to next call…', clearSpeakers: 'Forget speaker names' },
      recap: 'Recap:',
      after: { window: 'Call ended', meta: (o) => [o.when, o.dur, o.people].filter(Boolean).join(' · ') + (o.notion ? ' · summary saved to Notion' : ''),
        series: (o) => `Part of a series: ${o.name}, call ${o.n}. Calls in this project with the same title are linked. Open items and agenda points not raised go into the next brief${o.next ? ', ' + o.next : ''}.`,
        showSeries: 'Show series', decisions: (o) => `Decisions · ${o.n}`, onYou: (o) => `On you · ${o.n} · open questions · ${o.k}`,
        draft: 'Follow-up draft', draftTo: (o) => `To ${o.people} · not sent`, write: 'Write draft', writing: 'Writing the draft…', instruct: 'What to change: "drop the pricing line", "shorter"',
        rewrite: 'Rewrite', copy: 'Copy', openMail: 'Open in Mail', edit: 'Edit', neverSends: 'Pacenote never sends it for you', openNotion: 'Open in Notion', openCall: 'Open call page', done: 'Done',
        lessons: (o) => `Uses ${o.n} of your recurring corrections`, copied: 'Copied' },
      sys: { notRecording: 'Not recording', noAudio: 'No audio is captured', noAudioWhy: 'No sound from the microphone or the call for 30 s. Usually another app took the microphone, or macOS revoked access after an update.',
        restart: 'End and restart', noAudioFoot: (o) => `Tips are off until audio comes back. What was said before ${o.t} is saved.`,
        noOther: "Can't hear the other side", noOtherTitle: 'No call audio is coming in', noOtherWhy: 'Your microphone works, but there is no system audio from the call for 30 s. Most often the call plays through another device, or Pacenote lost access to system audio.',
        check: 'Check audio', noOtherFoot: 'Your words are recorded. Tips about the other side are off until their audio comes back.', mic: 'Mic', call: 'Call' },
      // 0.8.5 presentation mode (PRESENTATION-SPEC 2, keys pm.*)
      pm: { slides: 'Slides', slideOf: (o) => `Slide ${o.i} of ${o.n}`, you: 'You', all: 'All', left: 'left on this slide', overSlide: 'over slide time', add30: '+30 s',
        plan: (o) => `Plan ${o.t}`, elapsed: (o) => `Elapsed ${o.t}`, behind: (o) => `Behind ${o.t}`, ahead: (o) => `Ahead ${o.t}`,
        updated: (o) => `updated ${o.t}`, asked: (o) => `${o.name} asked`, hide: 'Hide', now: (o) => `Now · ${o.n}`, next: (o) => `Next · ${o.n} · ${o.owner}`,
        nextColleague: (o) => `After this slide ${o.name} presents ${o.range}. Tips go quiet until slide ${o.n}.`, prev: 'Previous', nextBtn: 'Next',
        syncA: (o) => `Following ${o.app} · slide ${o.n}`, stopFollowing: 'Stop following', askMove: (o) => `Move to slide ${o.n}?`, why: (o) => `You are already talking about ${o.topic}.`,
        go: 'Move', no: 'No', syncB: 'Slides follow your speech · asks before moving', colleague: (o) => `${o.name} is presenting`,
        colleagueHint: (o) => `Tips stay quiet while ${o.name} speaks. Questions to you still get an answer card.`, turnIn: (o) => `Your turn in about ${o.t}`,
        turnNext: (o) => `Your turn next · slide ${o.n}`, startWith: (o) => `Start with: "${o.line}"`, mode: 'Presentation mode', compactView: 'Compact view',
        emptyTitle: 'No presentation attached', emptyText: 'Attach a file and Pacenote shows the slides, the time for each and answers to questions. Until then, tips work as on a regular call.',
        attach: 'Attach presentation', slidesN: (o) => `${o.n} slides`, ofShort: (o) => `${o.i} of ${o.n}` },
      present: { next: 'Next', prev: 'Back', start: 'Start', nextUp: (t, s) => `Next: ${t} (${s})`, canSkip: 'Can skip if short on time' },
      doneQ: 'Done?', markDone: 'Mark done', onThem: 'On them', closed: 'Closed',
      noItems: 'Nothing on you yet', notMine: 'Not mine', tipsIn: (o) => `Tips in ${o.l}, click for ${o.o}`, close: 'Close', noBriefYet: 'No brief for this call yet.',
      readyStatus: 'Ready', readyTitle: 'Ready when you are', startListening: 'Start listening', openBrief: 'Open brief',
      listeningTitle: 'Listening', tipsOffTitle: 'Transcript only', tipsOffSub: 'Tips are off. The summary and the follow-up come after the call. Turn tips on in Call settings.', listeningSub: (k) => `Tips show up here when they matter. Stuck? Press ${k}.`, onDevice: 'Audio stays on this Mac',
      searched: (o) => `You searched: ${o.q}`, shorterMeta: 'Shorter', applied: 'Settings applied', prepReady: 'The brief is ready',
      speakerN: (o) => `Speaker ${o.n}`, yourTurn: 'Your turn: give your update', me: 'Me', them: 'Unknown voice', lineWhoTip: 'The voice was not recognised. Click to say who said this line.', lineWhoSaved: 'Saved: the transcript shows it after the call',
      briefReady: (o) => o.at ? `Brief ready · ${o.at}` : 'Brief ready', briefPreparing: 'Preparing the brief…', briefFailed: 'The brief could not be prepared', noBrief: 'No brief yet'
    },
    uk: {
      listening: 'Слухаю', paused: 'Пауза', muted: 'Мікрофон вимкнено', ended: 'Дзвінок завершено', ending: 'Завершую дзвінок…', starting: 'Запускаю…',
      micStalled: 'Мікрофон зупинився', cantHear: 'Не чую іншу сторону', asrBehind: (o) => `Транскрипція відстає на ${o.n} с`,
      engineDeaf: 'Підказки не надходять: заверши дзвінок і почни знову',
      onMe: 'На мені', more: 'Більше', earlier: 'Раніше',
      agenda: (a, b) => `Агенда ${a} з ${b}`, notRaised: 'Ще не підняли:', allRaised: 'Усі пункти агенди підняті',
      kinds: { answer: 'Відповідь', turn: 'Твоя черга', onme: 'На мені', docs: 'З документів', finish: 'хв лишилось', neutral: 'Нотатка', answered: 'Відповіли', risk: 'Ризик' },
      afterCall: 'Що далі', callPage: 'Сторінка дзвінка', followup: 'Чернетка листа-підсумку',
      asked: (w) => `${w} питає`, now: 'щойно', ago: (m) => `${m} хв`,
      saidIt: 'Сказав', notByVoice: 'Є на цій зустрічі, не за голосом', del: 'Видалити', delConfirm: 'Клацніть ще раз, щоб видалити', delTip: 'Видалити репліку з транскрипту', restore: 'Повернути', lineDeleted: 'Репліку видалено: її не буде в транскрипті після дзвінка', backAuto: 'До останньої', shorter: 'Коротше', hide: 'Сховати', pin: 'Закріпити', unpin: 'Відкріпити', edit: 'Виправити', save: 'Зберегти', cancel: 'Скасувати',
      unverified: 'Не звірено з документами',
      next: (t, m) => `${t} за ${m} хв`, notPrepared: 'не підготовлено', ready: 'бриф готовий', preparing: 'готується', prepare: 'Підготувати', open: 'Відкрити',
      ask: 'Запитай про проєкт', help: 'Допоможи',
      tabs: { transcript: 'Транскрипт', onme: (n) => `На мені · ${n}`, brief: 'Бриф' },
      newVoice: 'Новий голос:', name: 'Назвати', client: 'Клієнт', team: 'Команда', speakersH: 'Спікери', namedOf: (o) => `названо ${o.n} з ${o.m}`, notNamed: 'ще без імені',
      legend: 'Клієнт фіолетовим, команда синім', following: 'Слідкую наживо', jump: 'До останнього',
      ariaMic: 'Вимкнути мікрофон', ariaPause: 'Пауза прослуховування', ariaProactive: 'Проактивні підказки',
      proactiveOn: 'Проактивні підказки: увімкнено', proactiveOff: 'Проактивні підказки: вимкнено', resumeShort: 'Продовжити',
      menu: { pause: 'Призупинити', resume: 'Продовжити', mute: 'Вимкнути мікрофон', unmute: 'Увімкнути мікрофон',
        compact: 'Компактний режим', full: 'Повне вікно', present: 'Режим презентації', stopPresent: 'Завершити презентацію',
        transcript: 'Транскрипт', brief: 'Бриф', settings: 'Налаштування дзвінка…', switchCall: 'Перейти до наступного дзвінка…', clearSpeakers: 'Забути імена спікерів' },
      recap: 'Підсумок:',
      doneQ: 'Зроблено?', markDone: 'Позначити зробленим', onThem: 'На них', closed: 'Закрито',
      after: { window: 'Дзвінок завершено', meta: (o) => [o.when, o.dur, o.people].filter(Boolean).join(' · ') + (o.notion ? ' · підсумок збережено в Notion' : ''),
        series: (o) => `Частина серії: ${o.name}, дзвінок ${o.n}. Дзвінки цього проєкту з тією самою назвою звʼязані. Відкриті обіцянки і пункти, до яких не дійшли, переходять у бриф наступного${o.next ? ', ' + o.next : ''}.`,
        showSeries: 'Показати серію', decisions: (o) => `Рішення · ${o.n}`, onYou: (o) => `На вас · ${o.n} · відкриті питання · ${o.k}`,
        draft: 'Чернетка листа-підсумку', draftTo: (o) => `Кому: ${o.people} · не надіслано`, write: 'Написати чернетку', writing: 'Пишу чернетку…', instruct: 'Що змінити: «прибери рядок про ціну», «коротше»',
        rewrite: 'Переписати', copy: 'Копіювати', openMail: 'Відкрити в Mail', edit: 'Редагувати', neverSends: 'Pacenote ніколи не надсилає його за вас', openNotion: 'Відкрити в Notion', openCall: 'Сторінка дзвінка', done: 'Готово',
        lessons: (o) => `Враховує ваші повторювані правки: ${o.n}`, copied: 'Скопійовано' },
      sys: { notRecording: 'Запис не йде', noAudio: 'Звук не записується', noAudioWhy: '30 с немає звуку ні з мікрофона, ні з дзвінка. Найчастіше мікрофон зайняв інший застосунок або macOS забрав доступ після оновлення.',
        restart: 'Завершити і почати знову', noAudioFoot: (o) => `Підказки вимкнені, поки звук не повернеться. Сказане до ${o.t} збережено.`,
        noOther: 'Не чую співрозмовника', noOtherTitle: 'Звук дзвінка не надходить', noOtherWhy: 'Ваш мікрофон працює, але системного звуку дзвінка немає 30 с. Найчастіше дзвінок іде через інший пристрій або Pacenote втратив доступ до системного звуку.',
        check: 'Перевірити звук', noOtherFoot: 'Ваші слова записуються. Підказки про співрозмовника вимкнені, поки звук не повернеться.', mic: 'Мікр.', call: 'Дзвінок' },
      pm: { slides: 'Слайди', slideOf: (o) => `Слайд ${o.i} з ${o.n}`, you: 'Ви', all: 'Усі', left: 'лишилось на слайді', overSlide: 'понад час слайда', add30: '+30 с',
        plan: (o) => `План ${o.t}`, elapsed: (o) => `Минуло ${o.t}`, behind: (o) => `Відставання ${o.t}`, ahead: (o) => `Випереджаєте на ${o.t}`,
        updated: (o) => `оновлено ${o.t}`, asked: (o) => `${o.name} питає`, hide: 'Сховати', now: (o) => `Зараз · ${o.n}`, next: (o) => `Далі · ${o.n} · ${o.owner}`,
        nextColleague: (o) => `Після цього слайда ${o.name} презентує ${o.range}. Підказки мовчать до слайда ${o.n}.`, prev: 'Назад', nextBtn: 'Далі',
        syncA: (o) => `Слідую за ${o.app} · слайд ${o.n}`, stopFollowing: 'Не слідувати', askMove: (o) => `Перейти до слайда ${o.n}?`, why: (o) => `Ви вже говорите про ${o.topic}.`,
        go: 'Перейти', no: 'Ні', syncB: 'Слайди за вашою мовою · питаю перед переходом', colleague: (o) => `Презентує ${o.name}`,
        colleagueHint: (o) => `Поки говорить ${o.name}, підказки мовчать. На питання до вас картка з відповіддю все одно зʼявиться.`, turnIn: (o) => `Ваша черга приблизно через ${o.t}`,
        turnNext: (o) => `Далі ви · слайд ${o.n}`, startWith: (o) => `Почніть з: «${o.line}»`, mode: 'Режим презентації', compactView: 'Компактний вигляд',
        emptyTitle: 'Презентацію не додано', emptyText: 'Додайте файл, і Pacenote покаже слайди, час кожного слайда і відповіді на питання. Поки файлу немає, підказки працюють як на звичайному дзвінку.',
        attach: 'Додати презентацію', slidesN: (o) => `${o.n} слайдів`, ofShort: (o) => `${o.i} з ${o.n}` },
      present: { next: 'Далі', prev: 'Назад', start: 'Почати', nextUp: (t, s) => `Далі: ${t} (${s})`, canSkip: 'Можна пропустити, якщо бракує часу' },
      noItems: 'Поки нічого на тобі', notMine: 'Не моє', tipsIn: (o) => `Підказки: ${o.l}, клацніть для ${o.o}`, close: 'Закрити', noBriefYet: 'Брифу для цього дзвінка ще немає.',
      readyStatus: 'Готово', readyTitle: 'Можна починати', startListening: 'Почати слухати', openBrief: 'Відкрити бриф',
      listeningTitle: 'Слухаю', tipsOffTitle: 'Лише транскрипт', tipsOffSub: 'Підказки вимкнено. Підсумок і фоллоу-ап будуть після дзвінка. Увімкнути підказки можна в налаштуваннях дзвінка.', listeningSub: (k) => `Підказки зʼявляться тут, коли будуть потрібні. Застряг? Натисни ${k}.`, onDevice: 'Аудіо лишається на цьому Mac',
      searched: (o) => `Ви шукали: ${o.q}`, shorterMeta: 'Коротше', applied: 'Налаштування застосовано', prepReady: 'Бриф готовий',
      speakerN: (o) => `Спікер ${o.n}`, yourTurn: 'Твоя черга: розкажи свій апдейт', me: 'Я', them: 'Невідомий голос', lineWhoTip: 'Голос не розпізнано. Клацніть, щоб вказати, хто сказав цей рядок.', lineWhoSaved: 'Збережено: у транскрипті буде після дзвінка',
      briefReady: (o) => o.at ? `Бриф готовий · ${o.at}` : 'Бриф готовий', briefPreparing: 'Готую бриф…', briefFailed: 'Бриф не вдалося підготувати', noBrief: 'Брифу ще немає'
    }
  };

  // ---------- State ----------
  const PREFS = window.LT_PREFS || {};
  const S = {
    lang: PREFS.ui_lang === 'uk' ? 'uk' : 'en', theme: 'auto',
    call: { title: '', state: 'live', startedAt: null, paused: false, micOff: false, minutesLeft: null, mode: 'normal', recap: '', briefLine: '', alert: null },
    agenda: [], cards: [], onMe: [], next: null,
    transcript: [], speakers: {}, brief: null, briefText: '', steps: [], toast: null,
    keys: { help: '⌃⌥H', pause: '⌃⌥P', mute: '⌃⌥M', compact: '⌃⌥T', present: '⌃⌥S', prev: '⌃⌥←', next: '⌃⌥→', add30: '⌃⌥=' },
    pres: { slide: null, slideRx: 0, timeline: null, moveAsk: null, follow: null }, thumbs: {}, syncA: null, extra: {}, after: null, sys: null, rosterSide: {}, knownNames: [], tipsLang: null,
    ui: { spkOpen: null, lineWho: {}, lineDel: {}, delArm: null, openPts: {}, paneTab: 'transcript', sheet: null, menuOpen: false, heroOverride: null, follow: true, editing: null, briefEdit: false,
          present: { index: 0, running: false, stepStart: 0 }, presentForced: null }
  };
  const T = () => STR[S.lang] || STR.en;
  const tr = (k, p) => { const v = T()[k]; return typeof v === 'function' ? v(p || {}) : (v == null ? k : v); };
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const inApp = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liveTips);

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
    return {
      id: '__finish', kind: 'finish', at: Date.now() - 60000, state: 'active',
      label: `${left} ${T().kinds.finish}`,
      question: missing.length ? `${T().notRaised} ${missing.map((m) => m.title).join(', ')}` : T().allRaised,
      say: S.call.recap ? `${T().recap} ${S.call.recap}` : '', source: ''
    };
  }
  function visibleCards() {
    const list = S.cards.filter((c) => c.state !== 'hidden').slice();
    const f = finishCard(); if (f) list.push(f);
    return list.sort((a, b) => b.at - a.at);
  }
  // Hero order (spec 3.2): pinned, a fresh answer or your turn (90 s), N min left, the newest action, the newest active.
  function pickHero(list) {
    if (S.ui.heroOverride) { const o = list.find((c) => c.id === S.ui.heroOverride); if (o) return o; }
    list = list.filter((c) => !c.quiet || c.pinned);   // quiet cards (a commitment said to be done) stay in Earlier
    const pinned = list.find((c) => c.pinned && c.state === 'active'); if (pinned) return pinned;
    const fresh = list.find((c) => c.state === 'active' && (c.kind === 'answer' || c.kind === 'turn') && Date.now() - c.at < 90000); if (fresh) return fresh;
    const fin = list.find((c) => c.kind === 'finish'); if (fin) return fin;
    const action = list.find((c) => c.state === 'active' && ACTION_KINDS.includes(c.kind)); if (action) return action;
    return list.find((c) => c.state === 'active') || null;
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
  function render() {
    const t = T();
    document.documentElement.lang = S.lang;
    if (S.theme === 'auto') document.documentElement.removeAttribute('data-theme');
    else document.documentElement.setAttribute('data-theme', S.theme);
    const app = $('app');
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
    const openOnMe = S.onMe.filter((o) => !o.done).length;
    $('onmeLbl').textContent = t.onMe; $('onmeN').textContent = openOnMe;
    $('onmeBtn').hidden = openOnMe === 0;
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

    // agenda
    const ag = $('agenda');
    ag.hidden = !S.agenda.length || withSlides() || isReady;
    if (S.agenda.length) {
      $('segs').innerHTML = S.agenda.map((a) => `<button type="button" class="seg ${a.state}" data-act="agenda" data-id="${esc(a.id)}" title="${esc(a.title)}" aria-label="${esc(a.title)}"></button>`).join('');
      const now = S.agenda.find((a) => a.state === 'now');
      const doneN = S.agenda.filter((a) => a.state !== 'todo').length;
      const pos = now ? S.agenda.indexOf(now) + 1 : Math.max(doneN, 1);
      $('agendaNow').innerHTML = `${esc(t.agenda(pos, S.agenda.length))}${now ? ` · <b>${esc(now.title)}</b>` : ''}`;
      const missing = S.agenda.filter((a) => a.state === 'todo').map((a) => a.title);
      $('agendaMissing').textContent = missing.length ? `${t.notRaised} ${missing[0]}${missing.length > 1 ? ` +${missing.length - 1}` : ''}` : '';
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

    const list = visibleCards();
    const hero = withSlides() ? null : pickHero(list);
    renderPresentation();
    reportPresenting();
    const showEmpty = renderEmpty(list);
    renderHero(showEmpty ? null : hero);
    renderEarlier(showEmpty ? [] : list.filter((c) => (!hero || c.id !== hero.id) && (!withSlides() || c.kind === 'answer')));

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

    renderPane($('pane'), S.ui.paneTab, false);
    // A sheet opened in a narrow window becomes the side pane when the window gets wide (no double tabs).
    if (S.ui.sheet && isWide()) { S.ui.paneTab = S.ui.sheet; S.ui.sheet = null; }
    if (S.ui.sheet) { $('sheet').hidden = false; renderPane($('sheet'), S.ui.sheet, true); } else $('sheet').hidden = true;
    renderMenu();
    tick();
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
    if (c.commit && !c.commit.mine) return T().onThem;
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
  function renderHero(c) {
    const el = $('hero'), t = T();
    if (!c) { el.hidden = true; el.dataset.id = ''; return; }
    if (S.ui.editing === c.id && el.dataset.id === c.id && el.querySelector('.say[contenteditable="true"]')) return;   // the PM is typing
    if (el.dataset.id !== c.id) { el.style.animation = 'none'; void el.offsetWidth; el.style.animation = ''; }
    el.hidden = false; el.dataset.id = c.id;
    el.classList.toggle('finish', c.kind === 'finish');
    const meta = [c.meta || (c.who ? t.asked(c.who) : ''), rel(c.at)].filter(Boolean).join(' · ');
    const editing = S.ui.editing === c.id;
    const ptsEl = el.querySelector('.items.pts'), ptsTop = ptsEl && ptsEl.dataset.card === c.id ? ptsEl.scrollTop : 0;
    el.innerHTML = `
      <div class="head"><span class="kind k-${c.kind === 'finish' ? 'onme' : c.kind}">${esc(kindLabel(c))}</span>${c.kind === 'finish' ? '' : `<span class="meta"${c.unverified ? ` title="${esc(t.unverified)}"` : ''}>${esc(meta)}</span>`}${S.ui.heroOverride === c.id ? `<button class="ghost backauto" type="button" data-act="hero-auto" title="Esc">${esc(t.backAuto)}</button>` : ''}</div>
      ${(c.commit ? t.doneQ : c.question) ? `<div class="q">${esc(c.commit ? t.doneQ : c.question)}</div>` : ''}
      ${c.say ? `<div class="say"${editing ? ' contenteditable="true" spellcheck="false"' : ''}>${esc(c.say)}</div>` : ''}
      ${(c.items || []).length && c.kind !== 'finish' ? itemsHtml(c) : ''}
      ${c.source ? `<div class="src">${ICON.doc}<span>${esc(c.source)}</span></div>` : ''}
      ${c.commit ? `<div class="acts">${c.state === 'done' ? `<span class="meta">${esc(t.closed)}</span>` : `<button class="btn1" type="button" data-act="commit-done" data-id="${esc(c.id)}">${esc(t.markDone)}</button>`}
        <button class="ghost" type="button" data-act="hide" data-id="${esc(c.id)}">${esc(t.hide)}</button></div>` : c.kind === 'finish' ? '' : editing ? `<div class="acts">
        <button class="btn1" type="button" data-act="edit-save" data-id="${esc(c.id)}">${esc(t.save)}</button>
        <button class="ghost" type="button" data-act="edit-cancel">${esc(t.cancel)}</button></div>` : `<div class="acts">
        <button class="ghost" type="button" data-act="said" data-id="${esc(c.id)}">${esc(t.saidIt)}</button>
        <button class="ghost" type="button" data-act="shorter" data-id="${esc(c.id)}">${esc(t.shorter)}</button>
        <button class="ghost" type="button" data-act="pin" data-id="${esc(c.id)}">${esc(c.pinned ? t.unpin : t.pin)}</button>
        <button class="ghost" type="button" data-act="edit" data-id="${esc(c.id)}">${esc(t.edit)}</button>
        <button class="ghost" type="button" data-act="hide" data-id="${esc(c.id)}">${esc(t.hide)}</button>
      </div>`}`;
    if (ptsTop) { const p = el.querySelector('.items.pts'); if (p) p.scrollTop = ptsTop; }
    if (editing) { const s = el.querySelector('.say'); if (s) { s.focus(); document.getSelection().selectAllChildren(s); } }
  }

  function renderEarlier(list) {
    const t = T(), el = $('earlier');
    if (!list.length) { el.innerHTML = ''; return; }
    el.innerHTML = `<div class="h"><b>${esc(t.earlier)}</b><span>${list.length}</span></div>` + list.map((c) => {
      const text = c.commit ? `${t.doneQ} ${c.say}` : c.state === 'done' && c.question ? `${c.question}${c.say ? ' · ' + c.say : ''}` : (c.say || c.question || '');
      return `<div class="row ${c.state === 'done' ? 'done' : ''}" role="button" tabindex="0" data-act="promote" data-id="${esc(c.id)}">
        <span class="kind k-${c.kind === 'finish' ? 'onme' : c.kind}">${esc(kindLabel(c))}</span>
        <span class="t">${esc(text)}</span>
        <span class="m">${esc(rel(c.at))}</span>
        ${c.commit && c.state !== 'done' ? `<button class="ghost" type="button" data-act="commit-done" data-id="${esc(c.id)}">${esc(t.markDone)}</button>` : ''}
        <span class="hover-acts"><button class="ghost" type="button" data-act="pin" data-id="${esc(c.id)}">${esc(c.pinned ? t.unpin : t.pin)}</button><button class="ghost" type="button" data-act="hide" data-id="${esc(c.id)}">${esc(t.hide)}</button></span>
      </div>`;
    }).join('');
  }

  function stepElapsed() { const p = S.ui.present; return p.running ? Math.floor((Date.now() - p.stepStart) / 1000) : 0; }
  function fmtSecs(s) { return `${s < 0 ? '+' : ''}${Math.floor(Math.abs(s) / 60)}:${String(Math.abs(s) % 60).padStart(2, '0')}`; }
  function clock(s) { s = Math.max(0, Math.round(Math.abs(s))); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; }

  // ---------- 0.8.5 presentation mode (P5; rules/presentation.yaml) ----------
  // The current slide comes from the recorder (outline_pos / timeline), or from Previous / Next at once.
  function curIdx() {
    const n = S.pres && S.pres.slide;
    if (n != null) { const i = S.steps.findIndex((x) => x.n === n); if (i >= 0) return i; }
    return Math.min(S.ui.present.index, Math.max(0, S.steps.length - 1));
  }
  function budget(st) { return (st.secs || 0) + (S.extra[st.n] || 0); }
  function onSlide() {
    if (S.pres && S.pres.slideRx && S.pres.slide != null) return Math.max(0, Math.floor((Date.now() - S.pres.slideRx) / 1000));
    return stepElapsed();
  }
  function ownerName(st) { const t = T().pm; return st.who === 'other' ? (st.speaker || '?') : st.who === 'shared' ? t.all : t.you; }
  function runOf(i) {   // a colleague's run of slides around i: [from, to] indexes
    let a = i, b = i; const sp = S.steps[i].speaker;
    while (a > 0 && S.steps[a - 1].who === 'other' && S.steps[a - 1].speaker === sp) a--;
    while (b < S.steps.length - 1 && S.steps[b + 1].who === 'other' && S.steps[b + 1].speaker === sp) b++;
    return [a, b];
  }
  /** Numbers in bold: the slide's own numbers and any figure in the text (P5). */
  function bold(text, nums) {
    let h = esc(text);
    const list = (nums || []).filter((x) => x && x.length > 1).sort((x, y) => y.length - x.length);
    for (const x of list) { const e = esc(x); if (h.includes(e)) h = h.split(e).join('\u0000' + e + '\u0001'); }
    h = h.replace(/(^|[^\u0000\w])(\d[\d.,:]*\s?(%|k|K|m|M|x|×)?)/g, (m, p, d) => p + '\u0000' + d + '\u0001');
    return h.replace(/\u0000/g, '<b>').replace(/\u0001/g, '</b>').replace(/<b>([^<]*)<b>/g, '<b>$1').replace(/<\/b>([^<]*)<\/b>/g, '$1</b>');
  }
  function timeLine() {
    const tl = S.pres && S.pres.timeline, t = T().pm;
    if (!tl || !tl.plan) return '';
    const el = tl.elapsed + Math.floor((Date.now() - (tl.rx || Date.now())) / 1000);
    const parts = [t.plan({ t: clock(tl.plan) }), t.elapsed({ t: clock(el) })];
    if (tl.behind != null && Math.abs(tl.behind) >= 30) parts.push(tl.behind > 0 ? t.behind({ t: clock(tl.behind) }) : t.ahead({ t: clock(-tl.behind) }));
    return `<div class="pm-time" id="pmTime">${esc(parts.join(' · '))}</div>`;
  }
  function adviceLine() {
    const tl = S.pres && S.pres.timeline;
    if (!tl || !tl.advice || !tl.advice.text) return '';
    return `<div class="pm-adv" role="status">${bold(tl.advice.text, [])} <span class="m">${esc(T().pm.updated({ t: clock(tl.elapsed) }))}</span></div>`;
  }
  function moveAskBlock() {
    const a = S.pres && S.pres.moveAsk, t = T().pm;
    if (!a) return '';
    return `<div class="pm-ask" role="alertdialog" aria-label="${esc(t.askMove({ n: a.n }))}"><div><b>${esc(t.askMove({ n: a.n }))}</b> ${a.topic ? esc(t.why({ topic: a.topic.toLowerCase() })) : ''}</div>
      <div class="ctl"><button class="btn1" type="button" data-act="move-yes">${esc(t.go)}</button><button class="btn3" type="button" data-act="move-no">${esc(t.no)}</button><span class="m">↩ esc</span></div></div>`;
  }
  function qaCard() {
    const t = T().pm;
    const c = S.cards.find((x) => x.kind === 'answer' && x.state === 'active' && Date.now() - x.at < 90000);
    if (!c) return '';
    return `<div class="pm-qa"><div class="top"><span class="kind k-answer">${esc(t.asked({ name: c.who || T().them }))}</span><button class="ghost" type="button" data-act="hide" data-id="${esc(c.id)}">${esc(t.hide)}</button></div>
      ${c.question ? `<div class="q">${esc(c.question)}</div>` : ''}<div class="a">${bold(c.say || '', [])}</div></div>`;
  }
  function rail(i) {
    const t = T().pm, out = [];
    for (let k = 0; k < S.steps.length; k++) {
      const st = S.steps[k];
      const state = k < i ? 'done' : k === i ? 'now' : 'todo';
      if (st.who === 'other') {
        const [a, b] = runOf(k);
        const inRun = i >= a && i <= b;
        const secs = S.steps.slice(a, b + 1).reduce((x, y) => x + budget(y), 0);
        const label = a === b ? `${st.n}` : `${S.steps[a].n}-${S.steps[b].n}`;
        out.push(`<button type="button" class="r ${inRun ? 'now' : b < i ? 'done' : 'todo'} other" data-act="slide-go" data-n="${S.steps[a].n}"><span class="n">${label}</span><span class="tt">${esc(st.speaker)} · ${esc(a === b ? st.title : t.slidesN({ n: b - a + 1 }))}</span><span class="d">${b < i ? '' : clock(secs)}</span></button>`);
        k = b; continue;
      }
      const th = S.thumbs[st.n];
      out.push(`<button type="button" class="r ${state}" data-act="slide-go" data-n="${st.n}" aria-current="${state === 'now'}">${th ? `<img alt="" src="${th}">` : ''}<span class="n">${st.n}</span><span class="tt">${esc(st.title)}</span><span class="d">${state === 'done' ? '' : clock(budget(st))}</span></button>`);
    }
    return `<nav class="pm-rail" aria-label="${esc(t.slides)}"><div class="cap">${esc(t.slides)}</div>${out.join('')}</nav>`;
  }
  function footer() {
    const t = T().pm, k = S.keys;
    const sync = S.syncA ? `<div class="pm-sync"><span>${esc(t.syncA({ app: S.syncA.app, n: S.syncA.n }))}</span><button class="link" type="button" data-act="stop-follow">${esc(t.stopFollowing)}</button></div>`
      : `<div class="pm-sync"><span>${esc(t.syncB)}</span></div>`;
    return `<div class="ctl"><button class="btn2" type="button" data-act="present-prev">${esc(t.prev)}</button><button class="btn1" type="button" data-act="present-next">${esc(t.nextBtn)}</button><kbd>${esc(k.prev)} ${esc(k.next)}</kbd></div>${sync}`;
  }
  function renderPresentation() {
    const el = $('present'), t = T(), pm = t.pm;
    if (!presenting()) { el.hidden = true; el.className = 'present'; return; }
    el.hidden = false;
    if (!S.steps.length) {   // P5 states: no deck yet
      el.className = 'present pm-empty';
      el.innerHTML = `<div class="step">${esc(pm.emptyTitle)}</div><div class="say">${esc(pm.emptyText)}</div><div class="ctl"><button class="btn2" type="button" data-act="attach-deck">${esc(pm.attach)}</button></div>`;
      return;
    }
    const i = curIdx(), st = S.steps[i], n = S.steps.length, nx = S.steps[i + 1];
    const compact = S.call.mode === 'compact', wide = !compact && $('app').clientWidth >= 560;
    el.className = 'present pm' + (wide ? ' wide' : '') + (compact ? ' compact' : '');
    let main = moveAskBlock();
    if (st.who === 'other') {   // a colleague's block: no tips, then the handoff card
      const [a, b] = runOf(i), mineNext = S.steps[b + 1];
      const left = S.steps.slice(i, b + 1).reduce((x, y) => x + budget(y), 0) - onSlide();
      const tl = S.pres && S.pres.timeline;
      main += `<div class="top"><span class="pm-k">${esc(pm.slideOf({ i: i + 1, n }))}</span></div>
        <div class="step">${esc(pm.colleague({ name: st.speaker }))}</div>
        <div class="meta">${esc(`${a === b ? st.n : S.steps[a].n + '-' + S.steps[b].n} · ${st.title}`)}</div>
        <div class="say">${esc(pm.colleagueHint({ name: st.speaker }))}</div>
        ${mineNext ? `<div class="meta">${esc(pm.turnIn({ t: clock(left) }))}${tl && tl.behind >= 30 ? ' · ' + esc(pm.behind({ t: clock(tl.behind) })) : ''}</div>` : ''}
        ${mineNext && i === b ? `<div class="pm-handoff"><span class="pm-k">${esc(pm.turnNext({ n: mineNext.n }))}</span><div class="step">${esc(mineNext.title)}</div>${(Array.isArray(mineNext.say) ? mineNext.say : [mineNext.say])[0] ? `<div class="say">${esc(pm.startWith({ line: (Array.isArray(mineNext.say) ? mineNext.say : [mineNext.say])[0] }))}</div>` : ''}<div class="meta">${clock(budget(mineNext))}</div></div>` : ''}
        ${qaCard()}`;
    } else {
      const left = budget(st) - onSlide();
      const say = Array.isArray(st.say) ? st.say : (st.say ? [String(st.say)] : []);
      const lines = compact ? say.slice(0, 1) : say;
      main += `<div class="top"><span class="pm-k">${esc(compact ? pm.ofShort({ i: i + 1, n }) : pm.slideOf({ i: i + 1, n }))} · ${esc(ownerName(st))}</span></div>
        <div class="step">${esc(st.title)}</div>
        <div class="pm-clock"><span class="clock ${left < 0 ? 'over' : ''}" id="pclock">${clock(left)}</span><span class="m" id="pclockLbl">${esc(left < 0 ? pm.overSlide : pm.left)}</span><button class="btn3" type="button" data-act="add30" data-n="${st.n}">${esc(pm.add30)}</button></div>
        ${timeLine()}${adviceLine()}
        <div class="say">${lines.map((x) => `<p>${bold(x, st.numbers)}</p>`).join('')}</div>
        ${compact ? '' : qaCard()}`;
    }
    if (!compact) {
      main += `<div class="pm-nx"><span>${esc(pm.now({ n: st.n }))}</span>${nx ? `<span>${esc(pm.next({ n: nx.n, owner: ownerName(nx) }))}</span>` : ''}</div>`;
      if (nx && nx.who === 'other' && st.who !== 'other') { const [a2, b2] = runOf(i + 1); const back = S.steps[b2 + 1]; main += `<div class="meta">${esc(pm.nextColleague({ name: nx.speaker, range: a2 === b2 ? `${nx.n}` : `${S.steps[a2].n}-${S.steps[b2].n}`, n: back ? back.n : '' }))}</div>`; }
    } else if (nx) main += `<div class="meta">${esc(pm.next({ n: nx.n, owner: ownerName(nx) }))}</div>`;
    main += footer();
    el.innerHTML = wide ? `${rail(i)}<div class="pm-main">${main}</div>` : `<div class="pm-main">${main}</div>`;
  }
  /** Previous / Next, a click on the rail or a shortcut: the window moves now, the recorder follows (inbox slide = n|manual). */
  function goSlide(n, source) {
    const i = S.steps.findIndex((x) => x.n === n); if (i < 0) return;
    S.ui.present.index = i; S.ui.present.running = true; S.ui.present.stepStart = Date.now();
    S.pres = Object.assign({}, S.pres, { slide: n, slideRx: Date.now(), moveAsk: null });
    if (feed) feed.setSlide(n);
    post('setting', { key: 'slide', value: n + '|' + (source || 'manual') });
    render();
  }
  function stepBy(d) { if (!S.steps.length) return; const i = Math.max(0, Math.min(S.steps.length - 1, curIdx() + d)); goSlide(S.steps[i].n, 'manual'); }
  function answerMove(yes) {
    const a = S.pres && S.pres.moveAsk; if (!a) return;
    if (feed) feed.answerMove(yes); else S.pres.moveAsk = null;
    post('setting', { key: 'slide_move', value: (yes ? 'yes|' : 'no|') + a.n });
    if (yes) { S.ui.present.stepStart = Date.now(); }
    render();
  }
  function add30(n) { S.extra[n] = (S.extra[n] || 0) + 30; post('setting', { key: 'slide_add30', value: String(n) }); render(); }
  let lastPresenting = null;
  function reportPresenting() { const p = presenting() && S.steps.length > 0; if (p !== lastPresenting) { lastPresenting = p; post('presenting', { on: p }); } }

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

  // ---------- 0.8.5 recording problems (P8; rules/recording.yaml) ----------
  function renderSys(on) {
    let el = $('sys');
    if (!el) { el = document.createElement('section'); el.id = 'sys'; el.className = 'sys'; el.setAttribute('role', 'alert'); const bar = document.querySelector('header.bar'); bar.parentNode.insertBefore(el, bar.nextSibling); }
    el.hidden = !on;
    if (!on) return;
    const t = T().sys, s = S.sys, no = s.kind === 'notRecording';
    const meter = (label, v) => `<div class="lv"><span>${esc(label)}</span><span class="bar"><i style="width:${Math.round(Math.max(0, Math.min(1, v)) * 100)}%"></i></span></div>`;
    el.innerHTML = `<div class="strip">${esc(no ? t.notRecording : t.noOther)}</div>
      <div class="body"><div class="step">${esc(no ? t.noAudio : t.noOtherTitle)}</div><div class="say">${esc(no ? t.noAudioWhy : t.noOtherWhy)}</div>
      <div class="levels">${meter(t.mic, s.mic)}${meter(t.call, s.call)}</div>
      <div class="ctl"><button class="btn1" type="button" data-act="${no ? 'sys-restart' : 'sys-check'}">${esc(no ? t.restart : t.check)}</button></div>
      <div class="meta">${esc(no ? t.noAudioFoot({ t: s.at || '' }) : t.noOtherFoot)}</div></div>`;
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
    return `<div class="brief">${b.goal ? `<p><b>${esc(b.goal)}</b></p>` : ''}${(b.sections || []).map((s) => `<h3>${esc(s.title)}</h3><ul>${s.items.map((i, k) => (s.fulls || [])[k]
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
  /** 0.8.5 (owner, back from 0.7): every voice of the call at the top of the transcript: named or not, what it
   *  said last, Team or Client in one click, and one-click names for the ones still unnamed. */
  function speakersSummary(sugBtns, unknown) {
    const t = T();
    const list = Object.entries(S.speakers).filter(([sid, sp]) => /^S\d+$/i.test(sid) && sp && (sp.name || (sp.seconds || 0) >= 2))
      .sort((a, b) => (+a[0].slice(1)) - (+b[0].slice(1)));
    const names = new Set(), rows = [];
    for (const [sid, sp] of list) {
      if (sp.name && names.has(sp.name)) continue;        // merged speakers show once
      if (sp.name) names.add(sp.name);
      const side = sp.side === 'client' ? 'client' : sp.side === 'team' ? 'team' : 'unknown';
      rows.push(`<div class="spk-row${sp.name ? '' : ' open'}">
        <button class="who ${side}" type="button" data-act="name" data-sid="${esc(sid)}">${esc(sp.name || sp.label || sid)}</button>
        <span class="q" title="${esc(sp.lastQuote || '')}">${sp.name ? '' : esc(t.notNamed) + (sp.lastQuote ? ': ' : '')}${sp.lastQuote ? '\u201c' + esc(sp.lastQuote) + '\u201d' : ''}</span>
        <span class="seg2 sm"><button type="button" data-act="spk-side" data-sid="${esc(sid)}" data-side="team" aria-pressed="${side === 'team'}">${esc(t.team)}</button><button type="button" data-act="spk-side" data-sid="${esc(sid)}" data-side="client" aria-pressed="${side === 'client'}">${esc(t.client)}</button></span>
        ${sp.name ? '' : `<div class="sugs">${sugBtns(sid, sp)}</div>`}
      </div>`);
    }
    if (!rows.length) return '';
    const unnamed = list.filter(([, sp]) => !sp.name).length;
    const open = S.ui.spkOpen == null ? !!unnamed : S.ui.spkOpen;
    return `<div class="spks"><button class="spks-h" type="button" data-act="spk-toggle" aria-expanded="${open}"><b>${esc(t.speakersH)}</b><span class="meta">${esc(t.namedOf({ n: rows.length - unnamed, m: rows.length }))}</span></button>${open ? rows.join('') : ''}</div>`;
  }
  function renderPane(root, tab, isSheet) {
    const t = T();
    const openN = S.onMe.filter((o) => !o.done).length;
    const tabs = ['transcript', 'onme', 'brief'];
    if (tab === 'brief' && S.ui.briefEdit && root.querySelector('#briefEdit')) return;   // the PM is typing
    if (tab === 'onme' && S.ui.onmeEdit && root.querySelector('#onmeEditInput')) return;   // 0.8.5: an On me line being reworded
    const old = root.querySelector('.panebody');
    const top = old ? old.scrollTop : 0;
    let body = '';
    if (tab === 'transcript') {
      const unknown = Object.entries(S.speakers).find(([sid, s]) => /^S\d+$/i.test(sid) && !s.name);
      const sugBtns = (sid, sp) => (sp.suggestions || []).map((x) => `<button class="sug" type="button" data-act="name-pick" data-sid="${esc(sid)}" data-name="${esc(x.name)}" title="${x.score == null ? esc(T().notByVoice) : Math.round(x.score * 100) + '%'}">${esc(x.name)}</button>`).join('');
      body = speakersSummary(sugBtns, unknown) +
        S.transcript.map((l, i) => {
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
          return `<div class="tl${gone ? ' gone' : ''}">${btn}<span class="tx">${esc(l.text)}</span><span class="hover-acts">${del}</span></div>`;
        }).join('');
    } else if (tab === 'onme') {
      body = S.onMe.length ? S.onMe.map((o) => S.ui.onmeEdit === o.id
        ? `<div class="onme-item editing"><input id="onmeEditInput" type="text" value="${esc(o.text)}" aria-label="${esc(t.edit)}"><button class="btn1" type="button" data-act="onme-save" data-id="${esc(o.id)}">${esc(t.save)}</button><button class="ghost" type="button" data-act="onme-cancel">${esc(t.cancel)}</button></div>`
        : `<div class="onme-item"><label><input type="checkbox" data-act="onme-toggle" data-id="${esc(o.id)}" ${o.done ? 'checked' : ''}><span><span class="${o.done ? 'struck' : ''}">${esc(o.text)}</span>${o.due ? `<br><span class="meta">${esc(o.due)}</span>` : ''}</span></label>
          <span class="hover-acts"><button class="ghost" type="button" data-act="onme-edit" data-id="${esc(o.id)}">${esc(t.edit)}</button><button class="ghost" type="button" data-act="onme-notmine" data-id="${esc(o.id)}">${esc(t.notMine)}</button></span></div>`).join('') : `<p class="meta">${esc(t.noItems)}</p>`;
    } else if (tab === 'brief') {
      body = renderBrief();
    }
    root.innerHTML = `
      ${isSheet ? `<button class="icon-btn close" type="button" data-act="close-sheet" aria-label="${esc(t.close)}">${ICON.x}</button>` : ''}
      <div class="tabs" role="tablist" ${isSheet ? 'style="margin-right:48px"' : ''}>${tabs.map((k) => `<button class="tab" role="tab" type="button" aria-selected="${k === tab}" data-act="${isSheet ? 'sheet-tab' : 'pane-tab'}" data-tab="${k}">${esc(k === 'onme' ? t.tabs.onme(openN) : t.tabs[k])}</button>`).join('')}</div>
      <div class="panebody">${body}</div>
      ${tab === 'transcript' ? `<div class="panefoot"><span>${esc(t.legend)}</span>${S.ui.follow ? `<span>${esc(t.following)}</span>` : `<button class="link" type="button" data-act="follow">${esc(t.jump)}</button>`}</div>` : ''}`;
    const pb = root.querySelector('.panebody');
    if (tab === 'transcript' && S.ui.follow) pb.scrollTop = pb.scrollHeight; else pb.scrollTop = top;
  }

  function renderMenu() {
    const m = $('menu'), t = T().menu, k = S.keys;
    m.hidden = !S.ui.menuOpen;
    if (!S.ui.menuOpen) return;
    // 0.8 (spec 3.7): pause and the microphone live in the top bar, not repeated here.
    const items = [
      (S.steps.length || S.call.presType) ? ['present', presenting() ? t.stopPresent : t.present, k.present] : null,
      ['compact', S.call.mode === 'compact' ? t.full : t.compact, k.compact],
      ['transcript', t.transcript, ''], ['brief', t.brief, ''],
      '-',
      ['clear-speakers', t.clearSpeakers, ''],
      ['switch-call', t.switchCall, ''], ['settings', t.settings, '⌘,']
    ].filter(Boolean);
    m.innerHTML = items.map((i) => i === '-' ? '<div class="sep"></div>' : `<button type="button" role="menuitem" data-act="menu" data-item="${i[0]}"><span>${esc(i[1])}</span><kbd>${esc(i[2])}</kbd></button>`).join('');
  }

  function tick() {
    const start = S.call.startedAt;
    if (start) {
      const s = Math.max(0, Math.floor((Date.now() - start) / 1000));
      const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
      $('timer').textContent = (h ? h + ':' + String(m).padStart(2, '0') : String(m).padStart(2, '0')) + ':' + String(sec).padStart(2, '0');
    }
    if (presenting() && S.steps.length) {
      const c = $('pclock'), st = S.steps[curIdx()];
      if (c && st) {
        const left = budget(st) - onSlide(); c.textContent = clock(left); c.classList.toggle('over', left < 0);
        const l = $('pclockLbl'); if (l) l.textContent = left < 0 ? T().pm.overSlide : T().pm.left;
      }
      const tl = S.pres && S.pres.timeline, te = $('pmTime');
      if (te && tl) { const h = timeLine(); const d = document.createElement('div'); d.innerHTML = h; if (d.firstChild) te.textContent = d.firstChild.textContent; }
    }
  }

  let lastToast = 0, toastTimer = null;
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
    const t = T(), l = S.transcript[+i], pop = $('pop');
    if (!l || !l.t) return;
    const r = anchor.getBoundingClientRect();
    pop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 270)) + 'px';
    const names = Array.from(new Set(Object.values(S.speakers).map((s) => s && s.name).filter((n) => n && n !== t.me && n !== t.them)));
    pop.innerHTML = `<label class="meta" for="lnName">${esc(t.name)}</label><input id="lnName" type="text" list="lnNames" value="${esc(S.ui.lineWho[lineKey(l)] || '')}">
      <datalist id="lnNames">${names.map((n) => `<option value="${esc(n)}">`).join('')}</datalist>
      <button class="btn1" type="button" id="lnSave">${esc(t.save)}</button>`;
    pop.hidden = false; placePop(pop, r);
    const input = pop.querySelector('#lnName'); input.focus();
    const save = () => {
      const name = input.value.replace(/\s+/g, ' ').replace(/\|/g, ' ').trim().slice(0, 60); if (!name) return;
      S.ui.lineWho[lineKey(l)] = name;
      post('setting', { key: 'line_who', value: l.t + '|' + String(l.text || '').slice(0, 40).replace(/\|/g, ' ') + '|' + name });
      pop.hidden = true; showToast({ text: t.lineWhoSaved, kind: 'ok', at: Date.now() }); render();
    };
    pop.querySelector('#lnSave').onclick = save;
    input.onkeydown = (e) => { if (e.key === 'Enter') save(); if (e.key === 'Escape') pop.hidden = true; e.stopPropagation(); };
  }

  function openNamePopover(sid, anchor) {
    const t = T(), sp = S.speakers[sid] || {}, pop = $('pop');
    const r = anchor.getBoundingClientRect();
    pop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 270)) + 'px';
    let side = sp.side || 'client';
    const sug = (sp.suggestions || []).map((x) => `<button class="sug" type="button" data-pick="${esc(x.name)}">${esc(x.name)}${x.score == null ? '' : ` <span class="m">${Math.round(x.score * 100)}%</span>`}</button>`).join('');
    const known = (S.knownNames || []).filter((n) => !(sp.suggestions || []).some((x) => x.name === n));
    pop.innerHTML = `${sug ? `<div class="sugs">${sug}</div>` : ''}<label class="meta" for="spName">${esc(t.name)}</label><input id="spName" type="text" list="spKnown" value="${esc(sp.name || '')}">
      <datalist id="spKnown">${known.map((n) => `<option value="${esc(n)}">`).join('')}</datalist>
      <div class="seg2"><button type="button" data-side="client" aria-pressed="${side === 'client'}">${esc(t.client)}</button><button type="button" data-side="team" aria-pressed="${side === 'team'}">${esc(t.team)}</button></div>
      <button class="btn1" type="button" id="spSave">${esc(t.save)}</button>`;
    pop.hidden = false; placePop(pop, r);
    const input = pop.querySelector('#spName'); input.focus();
    pop.querySelectorAll('[data-side]').forEach((b) => b.onclick = () => { side = b.dataset.side; pop.querySelectorAll('[data-side]').forEach((x) => x.setAttribute('aria-pressed', x === b)); });
    const save = () => {
      const name = input.value.replace(/\s+/g, ' ').trim().slice(0, 60); if (!name) return;
      S.speakers[sid] = Object.assign({}, sp, { name, side });
      if (feed) feed.speakers[sid] = Object.assign({}, feed.speakers[sid], { name, side });
      post('name-speaker', { speakerId: sid, name, side });
      pop.hidden = true; render();
    };
    pop.querySelector('#spSave').onclick = save;
    pop.querySelectorAll('[data-pick]').forEach((b) => b.onclick = () => { input.value = b.dataset.pick; if (S.rosterSide && S.rosterSide[b.dataset.pick]) side = S.rosterSide[b.dataset.pick]; save(); });
    input.onkeydown = (e) => { if (e.key === 'Enter') save(); if (e.key === 'Escape') pop.hidden = true; e.stopPropagation(); };
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
  const PAUSE = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="M5.5 3v10M10.5 3v10"/></svg>';
  const PLAY = '<svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 2.8v10.4L13 8z" fill="currentColor"/></svg>';
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
  function isWide() { return $('app').clientWidth >= 760; }
  // A window made wide with a sheet open: the sheet becomes the side pane (render() moves it).
  // 0.8.5: the presentation rail shows from 560 px, so a resize redraws it.
  let resizeT = null;
  window.addEventListener('resize', () => { if (S.ui.sheet && isWide()) { render(); return; } if (presenting()) { clearTimeout(resizeT); resizeT = setTimeout(render, 80); } });
  function openTab(tab) { if (isWide()) S.ui.paneTab = tab; else S.ui.sheet = tab; render(); }
  function cardKey(c) { return (c.card || '') + '|' + (c.t || '') + '|' + String((c.raw && c.raw.gist) || '').slice(0, 60); }

  document.addEventListener('toggle', (e) => {
    const d = e.target; if (!d || !d.dataset || !d.dataset.pt) return;
    if (d.open) S.ui.openPts[d.dataset.pt] = true; else delete S.ui.openPts[d.dataset.pt];
  }, true);
  document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-act]');
    if (!$('menu').hidden && !e.target.closest('#menu') && !e.target.closest('#moreBtn')) { S.ui.menuOpen = false; renderMenu(); }
    if (!$('pop').hidden && !e.target.closest('#pop') && !(b && (b.dataset.act === 'name' || b.dataset.act === 'line-who'))) $('pop').hidden = true;
    if (S.ui.delArm && !(b && b.dataset.act === 'line-del')) { S.ui.delArm = null; if (!b) render(); }
    if (!b) return;
    const act = b.dataset.act, id = b.dataset.id;
    const card = id && S.cards.find((c) => c.id === id);
    switch (act) {
      case 'said':
        if (card) { card.state = 'done'; if (feed) feed.mark(id, { state: 'done' }); post('said', { id, key: cardKey(card) }); }
        S.ui.heroOverride = null; break;
      case 'hide':
        if (card) { card.state = 'hidden'; if (feed) feed.mark(id, { state: 'hidden' }); post('hide', { id, key: cardKey(card) }); }
        S.ui.heroOverride = null; e.stopPropagation(); break;
      case 'pin':
        if (card) { card.pinned = !card.pinned; if (feed) feed.mark(id, { pinned: card.pinned }); post('pin', { id, pinned: card.pinned }); }
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
      case 'after': post('after', Object.assign({ item: b.dataset.item }, draftNow())); return;
      case 'commit-done': {
        if (!card || !card.commit) return;
        card.state = 'done'; if (feed) feed.commitDone(id);
        post('commitment-done', { id: card.commit.id, text: card.commit.text });
        e.stopPropagation(); break;
      }
      case 'agenda': {
        const a = S.agenda.find((x) => x.id === id); if (!a) return;
        const nextState = a.state === 'todo' ? 'now' : a.state === 'now' ? 'done' : 'todo';
        a.state = nextState; if (feed) feed.setAgendaState(id, nextState);
        post('agenda', { id, title: a.title, state: nextState });
        break;
      }
      case 'pane-tab': S.ui.paneTab = b.dataset.tab; S.ui.briefEdit = false; break;
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
        const unnamed = Object.entries(S.speakers).some(([sid, sp]) => /^S\d+$/i.test(sid) && sp && !sp.name && (sp.seconds || 0) >= 2);
        S.ui.spkOpen = !(S.ui.spkOpen == null ? unnamed : S.ui.spkOpen); render(); return;
      }
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
      case 'present-next': {
        const p = S.ui.present;
        if (!p.running && S.pres.slide == null) { p.running = true; p.stepStart = Date.now(); goSlide(S.steps[curIdx()].n, 'manual'); return; }
        stepBy(1); return;
      }
      case 'present-prev': stepBy(-1); return;
      case 'slide-go': goSlide(+b.dataset.n, 'manual'); return;
      case 'move-yes': answerMove(true); return;
      case 'move-no': answerMove(false); return;
      case 'add30': add30(+b.dataset.n); return;
      case 'stop-follow': S.syncA = null; post('stop-follow'); render(); return;
      case 'attach-deck': post('attach-deck'); return;
      case 'tips-lang': {
        const tl = S.tipsLang; if (!tl) return;
        const cur = tl.current || tl.meeting; tl.current = cur === 'uk' ? 'en' : 'uk';
        post('setting', { key: 'tips_lang', value: tl.current }); render(); return;
      }
      case 'sys-restart': post('sys', { item: 'restart' }); return;
      case 'sys-check': post('sys', { item: 'check' }); return;
      case 'menu': {
        const item = b.dataset.item; S.ui.menuOpen = false;
        if (item === 'compact') { S.call.mode = S.call.mode === 'compact' ? 'normal' : 'compact'; post('compact', { on: S.call.mode === 'compact' }); }
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
  document.addEventListener('keydown', (e) => {
    if (e.target.classList && e.target.classList.contains('row') && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); e.target.click(); }
    if (e.metaKey && (e.key === '=' || e.key === '+' || e.key === '-' || e.key === '0')) { e.preventDefault(); post('zoom', { step: e.key === '-' ? -1 : e.key === '0' ? 0 : 1 }); return; }
    if (e.metaKey && e.key === ',') { e.preventDefault(); post('menu', { item: 'settings' }); return; }
    const typing = e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA');
    if (!typing && S.pres && S.pres.moveAsk && presenting() && (e.key === 'Enter' || e.key === 'Escape')) { e.preventDefault(); answerMove(e.key === 'Enter'); return; }
    if (e.key === 'Escape') {
      if (S.ui.editing) { S.ui.editing = null; render(); return; }
      S.ui.menuOpen = false; S.ui.sheet = null; S.ui.heroOverride = null; $('pop').hidden = true; render();
    }
  });
  $('moreBtn').addEventListener('click', () => { S.ui.menuOpen = !S.ui.menuOpen; renderMenu(); });
  $('micBtn').addEventListener('click', () => toggleMute());
  $('pauseBtn').addEventListener('click', () => togglePause());
  $('bulbBtn').addEventListener('click', () => toggleProactive());
  $('onmeBtn').addEventListener('click', () => { if (isWide()) { S.ui.paneTab = 'onme'; } else { S.ui.sheet = S.ui.sheet === 'onme' ? null : 'onme'; } render(); });
  $('helpBtn').addEventListener('click', () => post('help'));
  $('ask').addEventListener('submit', (e) => {
    e.preventDefault();
    const v = $('askInput').value.trim(); if (!v) return;
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
      if (k === 'prev') stepBy(-1); else if (k === 'next') stepBy(1); else if (k === 'add30') add30(S.steps[curIdx()].n);
    },
    /** Sync A (app only): the slide number read from Keynote or PowerPoint; null when not following. */
    setFollow(f) { S.syncA = f && f.n ? { app: String(f.app || ''), n: +f.n } : null; if (S.syncA) goSlide(S.syncA.n, String(f.app || '').toLowerCase().includes('power') ? 'powerpoint' : 'keynote'); else render(); },
    setThumbs(t) { S.thumbs = t || {}; render(); },
    /** 0.8.5 (P7): the after-call screen: outcome, series, the follow-up draft. */
    setAfter(a) { S.after = a || null; render(); },
    /** 0.8.5: {meeting: 'uk', current: 'uk'}: the tips language and the meeting's. */
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
              presenting: q.get('mode') === 'presentation' },
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
        { title: 'Why a pilot', say: 'Five users for two weeks show whether the export saves the team an hour a day.', secs: 90 },
        { title: 'Plan and dates', say: 'Starts Monday, review on day 10.', secs: 120 },
        { title: 'What we need from you', say: 'Names by Friday, test accounts by Thursday.', secs: 60, canSkip: true } ]
    });
  }
})();
