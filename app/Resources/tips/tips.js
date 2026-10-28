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
      saidIt: 'Said it', shorter: 'Shorter', hide: 'Hide', pin: 'Pin', unpin: 'Unpin', edit: 'Edit', save: 'Save', cancel: 'Cancel',
      unverified: 'Not verified against documents',
      next: (t, m) => `${t} in ${m} min`, notPrepared: 'not prepared', ready: 'brief ready', preparing: 'preparing', prepare: 'Prepare', open: 'Open',
      ask: 'Ask about this project', help: 'Help',
      tabs: { transcript: 'Transcript', onme: (n) => `On me · ${n}`, brief: 'Brief' },
      newVoice: 'New voice:', name: 'Name', client: 'Client', team: 'Team',
      legend: 'Client in purple, team in blue', following: 'Following live', jump: 'Jump to latest',
      menu: { pause: 'Pause listening', resume: 'Resume listening', mute: 'Turn mic off', unmute: 'Turn mic on',
        compact: 'Compact mode', full: 'Full window', present: 'Presentation mode', stopPresent: 'Stop presenting',
        transcript: 'Transcript', brief: 'Brief', settings: 'Call settings…', switchCall: 'Switch to next call…', clearSpeakers: 'Forget speaker names' },
      recap: 'Recap:',
      present: { next: 'Next', prev: 'Back', start: 'Start', nextUp: (t, s) => `Next: ${t} (${s})`, canSkip: 'Can skip if short on time' },
      doneQ: 'Done?', markDone: 'Mark done', onThem: 'On them', closed: 'Closed',
      noItems: 'Nothing on you yet', close: 'Close', noBriefYet: 'No brief for this call yet.',
      readyStatus: 'Ready', readyTitle: 'Ready when you are', startListening: 'Start listening', openBrief: 'Open brief',
      listeningTitle: 'Listening', listeningSub: (k) => `Tips show up here when they matter. Stuck? Press ${k}.`, onDevice: 'Audio stays on this Mac',
      searched: (o) => `You searched: ${o.q}`, shorterMeta: 'Shorter', applied: 'Settings applied', prepReady: 'The brief is ready',
      speakerN: (o) => `Speaker ${o.n}`, yourTurn: 'Your turn: give your update', me: 'Me', them: 'Other side',
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
      saidIt: 'Сказав', shorter: 'Коротше', hide: 'Сховати', pin: 'Закріпити', unpin: 'Відкріпити', edit: 'Виправити', save: 'Зберегти', cancel: 'Скасувати',
      unverified: 'Не звірено з документами',
      next: (t, m) => `${t} за ${m} хв`, notPrepared: 'не підготовлено', ready: 'бриф готовий', preparing: 'готується', prepare: 'Підготувати', open: 'Відкрити',
      ask: 'Запитай про проєкт', help: 'Допоможи',
      tabs: { transcript: 'Транскрипт', onme: (n) => `На мені · ${n}`, brief: 'Бриф' },
      newVoice: 'Новий голос:', name: 'Назвати', client: 'Клієнт', team: 'Команда',
      legend: 'Клієнт фіолетовим, команда синім', following: 'Слідкую наживо', jump: 'До останнього',
      menu: { pause: 'Призупинити', resume: 'Продовжити', mute: 'Вимкнути мікрофон', unmute: 'Увімкнути мікрофон',
        compact: 'Компактний режим', full: 'Повне вікно', present: 'Режим презентації', stopPresent: 'Завершити презентацію',
        transcript: 'Транскрипт', brief: 'Бриф', settings: 'Налаштування дзвінка…', switchCall: 'Перейти до наступного дзвінка…', clearSpeakers: 'Забути імена спікерів' },
      recap: 'Підсумок:',
      doneQ: 'Зроблено?', markDone: 'Позначити зробленим', onThem: 'На них', closed: 'Закрито',
      present: { next: 'Далі', prev: 'Назад', start: 'Почати', nextUp: (t, s) => `Далі: ${t} (${s})`, canSkip: 'Можна пропустити, якщо бракує часу' },
      noItems: 'Поки нічого на тобі', close: 'Закрити', noBriefYet: 'Брифу для цього дзвінка ще немає.',
      readyStatus: 'Готово', readyTitle: 'Можна починати', startListening: 'Почати слухати', openBrief: 'Відкрити бриф',
      listeningTitle: 'Слухаю', listeningSub: (k) => `Підказки зʼявляться тут, коли будуть потрібні. Застряг? Натисни ${k}.`, onDevice: 'Аудіо лишається на цьому Mac',
      searched: (o) => `Ви шукали: ${o.q}`, shorterMeta: 'Коротше', applied: 'Налаштування застосовано', prepReady: 'Бриф готовий',
      speakerN: (o) => `Спікер ${o.n}`, yourTurn: 'Твоя черга: розкажи свій апдейт', me: 'Я', them: 'Інша сторона',
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
    keys: { help: '⌃⌥H', pause: '⌃⌥P', mute: '⌃⌥M', compact: '⌃⌥T' },
    ui: { paneTab: 'transcript', sheet: null, menuOpen: false, heroOverride: null, follow: true, editing: null, briefEdit: false,
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
    if (!S.steps.length) return false;
    return S.ui.presentForced != null ? S.ui.presentForced : !!S.call.presenting;
  }
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
    $('moreBtn').setAttribute('aria-label', t.more);

    // agenda
    const ag = $('agenda');
    ag.hidden = !S.agenda.length || presenting() || isReady;
    if (S.agenda.length) {
      $('segs').innerHTML = S.agenda.map((a) => `<button type="button" class="seg ${a.state}" data-act="agenda" data-id="${esc(a.id)}" title="${esc(a.title)}" aria-label="${esc(a.title)}"></button>`).join('');
      const now = S.agenda.find((a) => a.state === 'now');
      const doneN = S.agenda.filter((a) => a.state !== 'todo').length;
      const pos = now ? S.agenda.indexOf(now) + 1 : Math.max(doneN, 1);
      $('agendaNow').innerHTML = `${esc(t.agenda(pos, S.agenda.length))}${now ? ` · <b>${esc(now.title)}</b>` : ''}`;
      const missing = S.agenda.filter((a) => a.state === 'todo').map((a) => a.title);
      $('agendaMissing').textContent = missing.length ? `${t.notRaised} ${missing[0]}${missing.length > 1 ? ` +${missing.length - 1}` : ''}` : '';
    }

    // Pacenote 0.8.6: after the call, the call page and the follow-up email draft (nothing is sent).
    const af = $('after');
    af.hidden = !ended;
    if (ended) af.innerHTML = `<span class="meta">${esc(t.afterCall)}</span>
      <button class="btn1" type="button" data-act="after" data-item="followup">${esc(t.followup)}</button>
      <button class="ghost" type="button" data-act="after" data-item="callpage">${esc(t.callPage)}</button>`;

    const list = visibleCards();
    const hero = presenting() ? null : pickHero(list);
    renderPresentation();
    const showEmpty = renderEmpty(list);
    renderHero(showEmpty ? null : hero);
    renderEarlier(showEmpty ? [] : list.filter((c) => (!hero || c.id !== hero.id) && (!presenting() || c.kind === 'answer')));

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
      el.innerHTML = `<div class="ring">${MARK}</div><div class="t1">${esc(S.call.state === 'ended' ? t.ended : t.listeningTitle)}</div>` +
        (S.call.state === 'ended' ? '' : `<div class="t2">${esc(t.listeningSub(S.keys.help))}</div>`);
    }
    return true;
  }

  function kindLabel(c) {
    if (c.kind === 'finish') return c.label;
    if (c.commit && !c.commit.mine) return T().onThem;
    if (c.state === 'done' && (c.kind === 'answer' || c.kind === 'turn')) return T().kinds.answered;
    return T().kinds[c.kind] || T().kinds.neutral;
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
    el.innerHTML = `
      <div class="head"><span class="kind k-${c.kind === 'finish' ? 'onme' : c.kind}">${esc(kindLabel(c))}</span>${c.kind === 'finish' ? '' : `<span class="meta"${c.unverified ? ` title="${esc(t.unverified)}"` : ''}>${esc(meta)}</span>`}</div>
      ${(c.commit ? t.doneQ : c.question) ? `<div class="q">${esc(c.commit ? t.doneQ : c.question)}</div>` : ''}
      ${c.say ? `<div class="say"${editing ? ' contenteditable="true" spellcheck="false"' : ''}>${esc(c.say)}</div>` : ''}
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
  function renderPresentation() {
    const el = $('present'), t = T(), p = S.ui.present;
    if (!presenting()) { el.hidden = true; return; }
    el.hidden = false;
    if (p.index >= S.steps.length) p.index = S.steps.length - 1;
    const st = S.steps[p.index] || S.steps[0];
    const left = (st.secs || 0) - stepElapsed();
    const nx = S.steps[p.index + 1];
    el.innerHTML = `
      <div class="top"><span class="kind k-turn">${p.index + 1} / ${S.steps.length}</span><span class="clock ${left < 0 ? 'over' : ''}" id="pclock">${fmtSecs(left)}</span></div>
      <div class="step">${esc(st.title)}</div>
      <div class="say">${esc(st.say || '')}</div>
      ${st.canSkip ? `<div class="meta">${esc(t.present.canSkip)}</div>` : ''}
      ${nx ? `<div class="nx">${esc(t.present.nextUp(nx.title, fmtSecs(nx.secs || 0)))}</div>` : ''}
      <div class="ctl"><button class="btn2" type="button" data-act="present-prev">${esc(t.present.prev)}</button><button class="btn1" type="button" data-act="present-next">${esc(p.running ? t.present.next : t.present.start)}</button></div>`;
  }

  function renderBrief() {
    const t = T(), b = S.brief;
    if (S.ui.briefEdit) {
      return `<textarea class="briefedit" id="briefEdit" spellcheck="false">${esc(S.briefText)}</textarea>
        <div class="ctl"><button class="btn1" type="button" data-act="brief-save">${esc(t.save)}</button><button class="btn2" type="button" data-act="brief-cancel">${esc(t.cancel)}</button></div>`;
    }
    if (!b) return `<p class="meta">${esc(t.noBriefYet)}</p>`;
    return `<div class="brief">${b.goal ? `<p><b>${esc(b.goal)}</b></p>` : ''}${(b.sections || []).map((s) => `<h3>${esc(s.title)}</h3><ul>${s.items.map((i) => `<li>${esc(i)}</li>`).join('')}</ul>`).join('')}</div>
      ${S.briefText ? `<div><button class="link" type="button" data-act="brief-edit">${esc(t.edit)}</button></div>` : ''}`;
  }

  function renderPane(root, tab, isSheet) {
    const t = T();
    const openN = S.onMe.filter((o) => !o.done).length;
    const tabs = ['transcript', 'onme', 'brief'];
    if (tab === 'brief' && S.ui.briefEdit && root.querySelector('#briefEdit')) return;   // the PM is typing
    const old = root.querySelector('.panebody');
    const top = old ? old.scrollTop : 0;
    let body = '';
    if (tab === 'transcript') {
      const unknown = Object.entries(S.speakers).find(([sid, s]) => /^S\d+$/i.test(sid) && !s.name);
      body = (unknown ? `<div class="newvoice">${ICON.person}<span class="t">${esc(t.newVoice)} <b>${esc(unknown[1].label || unknown[0])}</b></span><button class="link" type="button" data-act="name" data-sid="${esc(unknown[0])}">${esc(t.name)}</button></div>` : '') +
        S.transcript.map((l) => {
          const sp = S.speakers[l.speakerId] || {};
          const cls = sp.side === 'client' ? 'client' : sp.side === 'team' ? 'team' : 'unknown';
          const named = /^S\d+$/i.test(l.speakerId);
          const who = esc(sp.name || sp.label || l.speakerId);
          return `<div class="tl">${named ? `<button class="who ${cls}" type="button" data-act="name" data-sid="${esc(l.speakerId)}">${who}</button>` : `<span class="who ${cls}">${who}</span>`}<span>${esc(l.text)}</span></div>`;
        }).join('');
    } else if (tab === 'onme') {
      body = S.onMe.length ? S.onMe.map((o) => `<label class="onme-item"><input type="checkbox" data-act="onme-toggle" data-id="${esc(o.id)}" ${o.done ? 'checked' : ''}><span><span class="${o.done ? 'struck' : ''}">${esc(o.text)}</span>${o.due ? `<br><span class="meta">${esc(o.due)}</span>` : ''}</span></label>`).join('') : `<p class="meta">${esc(t.noItems)}</p>`;
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
    const items = [
      ['pause', S.call.paused ? t.resume : t.pause, k.pause],
      ['mute', S.call.micOff ? t.unmute : t.mute, k.mute],
      '-',
      ['compact', S.call.mode === 'compact' ? t.full : t.compact, k.compact],
      S.steps.length ? ['present', presenting() ? t.stopPresent : t.present, ''] : null,
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
    if (presenting()) {
      const c = $('pclock'), st = S.steps[S.ui.present.index];
      if (c && st) { const left = (st.secs || 0) - stepElapsed(); c.textContent = fmtSecs(left); c.classList.toggle('over', left < 0); }
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
  function openNamePopover(sid, anchor) {
    const t = T(), sp = S.speakers[sid] || {}, pop = $('pop');
    const r = anchor.getBoundingClientRect();
    pop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 270)) + 'px';
    pop.style.top = (r.bottom + 6) + 'px';
    let side = sp.side || 'client';
    pop.innerHTML = `<label class="meta" for="spName">${esc(t.name)}</label><input id="spName" type="text" value="${esc(sp.name || '')}">
      <div class="seg2"><button type="button" data-side="client" aria-pressed="${side === 'client'}">${esc(t.client)}</button><button type="button" data-side="team" aria-pressed="${side === 'team'}">${esc(t.team)}</button></div>
      <button class="btn1" type="button" id="spSave">${esc(t.save)}</button>`;
    pop.hidden = false;
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
    input.onkeydown = (e) => { if (e.key === 'Enter') save(); if (e.key === 'Escape') pop.hidden = true; e.stopPropagation(); };
  }

  // ---------- Actions ----------
  function setMode(mode) { S.call.mode = mode === 'compact' ? 'compact' : 'normal'; render(); }
  function togglePause() {
    S.call.paused = !S.call.paused;
    post('setting', { key: 'tips_paused', value: S.call.paused ? 'on' : 'off' });
    render();
  }
  function toggleMute() {
    S.call.micOff = !S.call.micOff;
    post('mute', { on: S.call.micOff });
    render();
  }
  function isWide() { return $('app').clientWidth >= 760; }
  function openTab(tab) { if (isWide()) S.ui.paneTab = tab; else S.ui.sheet = tab; render(); }
  function cardKey(c) { return (c.card || '') + '|' + (c.t || '') + '|' + String((c.raw && c.raw.gist) || '').slice(0, 60); }

  document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-act]');
    if (!$('menu').hidden && !e.target.closest('#menu') && !e.target.closest('#moreBtn')) { S.ui.menuOpen = false; renderMenu(); }
    if (!$('pop').hidden && !e.target.closest('#pop') && !(b && b.dataset.act === 'name')) $('pop').hidden = true;
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
      case 'promote': S.ui.heroOverride = id; break;
      case 'after': post('after', { item: b.dataset.item }); return;
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
        if (!p.running) { p.running = true; p.stepStart = Date.now(); }
        else if (p.index < S.steps.length - 1) { p.index++; p.stepStart = Date.now(); }
        post('present', { index: p.index, running: p.running });
        break;
      }
      case 'present-prev': {
        const p = S.ui.present; if (p.index > 0) { p.index--; p.stepStart = Date.now(); }
        post('present', { index: p.index, running: p.running });
        break;
      }
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
    if (e.key === 'Escape') {
      if (S.ui.editing) { S.ui.editing = null; render(); return; }
      S.ui.menuOpen = false; S.ui.sheet = null; S.ui.heroOverride = null; $('pop').hidden = true; render();
    }
  });
  $('moreBtn').addEventListener('click', () => { S.ui.menuOpen = !S.ui.menuOpen; renderMenu(); });
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
    togglePause, toggleMute, openTab,
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
