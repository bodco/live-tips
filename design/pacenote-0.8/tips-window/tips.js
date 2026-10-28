/* Pacenote, tips window, Concept A "Focus". Reference implementation, v0.8.
 *
 * Native -> web:  window.LiveTips.setState(partialState)   (shallow merge; arrays replace)
 *                 window.LiveTips.setLang('en'|'uk'), window.LiveTips.setTheme('auto'|'light'|'dark')
 * Web -> native:  window.webkit.messageHandlers.liveTips.postMessage({action, ...payload})
 *
 * See README.md in this folder for the full state shape and action list.
 */
(function () {
  'use strict';

  // ---------- i18n (Ukrainian is ~20-30% longer; layout must survive it) ----------
  const STR = {
    en: {
      listening: 'Listening', paused: 'Paused', muted: 'Mic off',
      ctl: { micOn: 'Turn mic off', micOff: 'Turn mic on', pause: 'Pause listening', resume: 'Resume', resumeTip: 'Resume listening', proOn: 'Proactive tips: on', proOff: 'Proactive tips: off', group: 'Call controls' },
      onMe: 'On me', more: 'More', earlier: 'Earlier',
      agenda: (a, b) => `Agenda ${a} of ${b}`, notRaised: 'Not raised:', allRaised: 'All agenda items raised',
      kinds: { answer: 'Answer', turn: 'Your turn', onme: 'On me', docs: 'From docs', finish: 'Min left', neutral: 'Note', answered: 'Answered' },
      asked: (w) => `${w} asked`, now: 'now', ago: (m) => `${m}m`,
      saidIt: 'Said it', shorter: 'Shorter', hide: 'Hide', pin: 'Pin', unpin: 'Unpin',
      next: (t, m) => `${t} in ${m} min`, notPrepared: 'not prepared', ready: 'brief ready', prepare: 'Prepare', open: 'Open',
      ask: 'Ask about this project', help: 'Help',
      tabs: { transcript: 'Transcript', onme: (n) => `On me · ${n}`, brief: 'Brief' },
      newVoice: 'New voice:', name: 'Name', client: 'Client', team: 'Team', save: 'Save',
      legend: 'Client in purple, team in blue', following: 'Following live', jump: 'Jump to latest',
      menu: { pause: 'Pause listening', resume: 'Resume listening', mute: 'Turn mic off', unmute: 'Turn mic on',
        compact: 'Compact mode', full: 'Full window', present: 'Presentation mode', stopPresent: 'Stop presenting',
        transcript: 'Transcript', brief: 'Brief', settings: 'Call settings…', switchCall: 'Switch to next call…', clearSpeakers: 'Forget speaker names' },
      finishTitle: 'Before you close', recap: 'Recap:',
      present: { next: 'Next', prev: 'Back', start: 'Start', nextUp: (t, s) => `Next: ${t} (${s})`, canSkip: 'Can skip if short on time' },
      noItems: 'Nothing on you yet', close: 'Close',
      ready: 'Ready', startsAt: (t) => `starts ${t}`, readyTitle: 'Ready when you are', startListening: 'Start listening', openBrief: 'Open brief',
      listeningTitle: 'Listening', listeningSub: 'Tips show up here when they matter. Stuck? Press ⌃⌥H.', onDevice: 'Audio stays on this Mac'
    },
    uk: {
      listening: 'Слухаю', paused: 'Пауза', muted: 'Мікрофон вимкнено',
      ctl: { micOn: 'Вимкнути мікрофон', micOff: 'Увімкнути мікрофон', pause: 'Призупинити', resume: 'Продовжити', resumeTip: 'Продовжити слухати', proOn: 'Ініціативні підказки: увімк.', proOff: 'Ініціативні підказки: вимк.', group: 'Керування дзвінком' },
      onMe: 'На мені', more: 'Більше', earlier: 'Раніше',
      agenda: (a, b) => `Агенда ${a} з ${b}`, notRaised: 'Ще не підняли:', allRaised: 'Усі пункти агенди підняті',
      kinds: { answer: 'Відповідь', turn: 'Твоя черга', onme: 'На мені', docs: 'З документів', finish: 'хв лишилось', neutral: 'Нотатка', answered: 'Відповіли' },
      asked: (w) => `${w} питає`, now: 'щойно', ago: (m) => `${m} хв`,
      saidIt: 'Сказав', shorter: 'Коротше', hide: 'Сховати', pin: 'Закріпити', unpin: 'Відкріпити',
      next: (t, m) => `${t} за ${m} хв`, notPrepared: 'не підготовлено', ready: 'бриф готовий', prepare: 'Підготувати', open: 'Відкрити',
      ask: 'Запитай про проєкт', help: 'Допоможи',
      tabs: { transcript: 'Транскрипт', onme: (n) => `На мені · ${n}`, brief: 'Бриф' },
      newVoice: 'Новий голос:', name: 'Назвати', client: 'Клієнт', team: 'Команда', save: 'Зберегти',
      legend: 'Клієнт фіолетовим, команда синім', following: 'Слідкую наживо', jump: 'До останнього',
      menu: { pause: 'Призупинити', resume: 'Продовжити', mute: 'Вимкнути мікрофон', unmute: 'Увімкнути мікрофон',
        compact: 'Компактний режим', full: 'Повне вікно', present: 'Режим презентації', stopPresent: 'Завершити презентацію',
        transcript: 'Транскрипт', brief: 'Бриф', settings: 'Налаштування дзвінка…', switchCall: 'Перейти до наступного дзвінка…', clearSpeakers: 'Забути імена спікерів' },
      finishTitle: 'Перед завершенням', recap: 'Підсумок:',
      present: { next: 'Далі', prev: 'Назад', start: 'Почати', nextUp: (t, s) => `Далі: ${t} (${s})`, canSkip: 'Можна пропустити, якщо бракує часу' },
      noItems: 'Поки нічого на тобі', close: 'Закрити',
      ready: 'Готово', startsAt: (t) => `початок ${t}`, readyTitle: 'Можна починати', startListening: 'Почати слухати', openBrief: 'Відкрити бриф',
      listeningTitle: 'Слухаю', listeningSub: 'Підказки зʼявляться тут, коли будуть потрібні. Застряг? Натисни ⌃⌥H.', onDevice: 'Аудіо лишається на цьому Mac'
    }
  };

  // ---------- State ----------
  const S = {
    lang: 'en', theme: 'auto',
    call: { title: '', startedAt: Date.now(), paused: false, micOff: false, proactive: false, minutesLeft: null, mode: 'normal' },
    agenda: [], cards: [], onMe: [], next: null,
    transcript: [], speakers: {}, brief: null, presentation: null,
    ui: { paneTab: 'transcript', sheet: null, menuOpen: false, heroOverride: null, follow: true }
  };
  const T = () => STR[S.lang] || STR.en;
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  function post(action, payload) {
    const msg = Object.assign({ action }, payload || {});
    try { window.webkit.messageHandlers.liveTips.postMessage(msg); }
    catch (e) { console.log('[Pacenote →native]', msg); }
  }

  // ---------- Derivations ----------
  const ACTION_KINDS = ['answer', 'turn', 'finish'];
  function finishCard() {
    const left = S.call.minutesLeft;
    if (left == null || left > 5) return null;
    const missing = S.agenda.filter((a) => a.state === 'todo');
    return {
      id: '__finish', kind: 'finish', at: Date.now(), state: 'active',
      label: `${left} ${T().kinds.finish}`,
      question: missing.length ? `${T().notRaised} ${missing.map((m) => m.title).join(', ')}` : T().allRaised,
      say: S.call.recap ? `${T().recap} ${S.call.recap}` : '',
      source: ''
    };
  }
  function visibleCards() {
    const list = S.cards.filter((c) => c.state !== 'hidden').slice();
    const f = finishCard(); if (f) list.push(f);
    return list.sort((a, b) => b.at - a.at);
  }
  function pickHero(list) {
    if (S.ui.heroOverride) { const o = list.find((c) => c.id === S.ui.heroOverride); if (o) return o; }
    const pinned = list.find((c) => c.pinned && c.state === 'active'); if (pinned) return pinned;
    // A fresh direct question or your-turn beats everything (90 s), then the finish card, then the newest action.
    const fresh = list.find((c) => c.state === 'active' && (c.kind === 'answer' || c.kind === 'turn') && Date.now() - c.at < 90000); if (fresh) return fresh;
    const fin = list.find((c) => c.kind === 'finish'); if (fin) return fin;
    const action = list.find((c) => c.state === 'active' && ACTION_KINDS.includes(c.kind)); if (action) return action;
    return list.find((c) => c.state === 'active') || null;
  }
  function rel(at) { const m = Math.floor((Date.now() - at) / 60000); return m < 1 ? T().now : T().ago(m); }

  // ---------- Icons ----------
  const ICON = {
    doc: '<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true"><path d="M3 1.5h5l3 3v8H3z"/><path d="M8 1.5v3h3"/></svg>',
    cal: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true" style="color:var(--text-3)"><rect x="2" y="3" width="12" height="11" rx="2"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/></svg>',
    person: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true" style="color:var(--accent)"><circle cx="8" cy="5.5" r="2.5"/><path d="M3 14c.6-2.8 2.6-4.2 5-4.2s4.4 1.4 5 4.2"/></svg>',
    x: '<svg width="14" height="14" viewBox="0 0 14 14" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="M3 3l8 8M11 3l-8 8"/></svg>'
  };

  // ---------- Render ----------
  function render() {
    const t = T();
    document.documentElement.lang = S.lang;
    if (S.theme === 'auto') document.documentElement.removeAttribute('data-theme');
    else document.documentElement.setAttribute('data-theme', S.theme);

    const app = $('app');
    app.classList.toggle('compact', S.call.mode === 'compact');

    // header
    const isReady = S.call.state === 'ready';
    $('rec').classList.toggle('paused', !!S.call.paused);
    $('rec').classList.toggle('ready', isReady);
    $('timer').style.display = isReady ? 'none' : '';
    $('status').textContent = isReady ? `${t.ready}${S.call.startsAt ? ' · ' + t.startsAt(S.call.startsAt) : ''}` : S.call.paused ? t.paused : (S.call.micOff ? t.muted : t.listening);
    const openOnMe = S.onMe.filter((o) => !o.done).length;
    $('onmeLbl').textContent = t.onMe; $('onmeN').textContent = openOnMe;
    $('onmeBtn').setAttribute('aria-label', `${t.onMe}: ${openOnMe}`);
    $('onmeBtn').hidden = openOnMe === 0;
    $('moreBtn').setAttribute('aria-label', t.more);
    renderControls(isReady);

    // agenda
    const ag = $('agenda');
    ag.hidden = !S.agenda.length || S.call.mode === 'presentation' || isReady;
    if (S.agenda.length) {
      $('segs').innerHTML = S.agenda.map((a) => `<span class="seg ${a.state}"></span>`).join('');
      const now = S.agenda.find((a) => a.state === 'now');
      const doneN = S.agenda.filter((a) => a.state !== 'todo').length;
      $('agendaNow').innerHTML = `${esc(t.agenda(Math.max(doneN, 1), S.agenda.length))}${now ? ` · <b>${esc(now.title)}</b>` : ''}`;
      const missing = S.agenda.filter((a) => a.state === 'todo').map((a) => a.title);
      $('agendaMissing').textContent = missing.length ? `${t.notRaised} ${missing[0]}${missing.length > 1 ? ` +${missing.length - 1}` : ''}` : '';
    }

    // presentation or hero
    const list = visibleCards();
    const hero = S.call.mode === 'presentation' ? null : pickHero(list);
    renderPresentation();
    const showEmpty = renderEmpty(list);
    renderHero(showEmpty ? null : hero);
    renderEarlier(showEmpty ? [] : list.filter((c) => !hero || c.id !== hero.id));

    // next call (only within 10 minutes)
    const nx = $('next');
    if (S.next && S.next.startsInMin != null && S.next.startsInMin <= 10) {
      nx.hidden = false;
      nx.innerHTML = `${ICON.cal}<span class="t">${esc(t.next(S.next.title, S.next.startsInMin))} · ${S.next.prepared ? esc(t.ready) : `<span class="warn">${esc(t.notPrepared)}</span>`}</span>
        <button class="link" type="button" data-act="${S.next.prepared ? 'open-next' : 'prepare-next'}">${esc(S.next.prepared ? t.open : t.prepare)}</button>`;
    } else nx.hidden = true;

    $('askLbl').textContent = t.ask; $('askInput').placeholder = t.ask; $('helpLbl').textContent = t.help;

    renderPane($('pane'), S.ui.paneTab, false);
    if (S.ui.sheet) { $('sheet').hidden = false; renderPane($('sheet'), S.ui.sheet, true); } else $('sheet').hidden = true;
    renderMenu();
    tick();
  }

  const MARK = '<svg class="mark" viewBox="320 206 460 626" aria-hidden="true"><path d="M400 742V404C400 312 466 262 556 262C664 262 724 330 724 412C724 500 662 560 556 560H500" fill="none" stroke="currentColor" stroke-width="92" stroke-linecap="round" stroke-linejoin="round"/><circle cx="400" cy="752" r="70" fill="var(--brand)"/></svg>';
  // Returns true when an empty state is shown instead of cards.
  function renderEmpty(list) {
    const el = $('empty'), t = T();
    const isReady = S.call.state === 'ready';
    const nothing = S.call.mode === 'normal' && !list.some((c) => c.state !== 'hidden');
    if (!isReady && !nothing) { el.hidden = true; return false; }
    el.hidden = false;
    if (isReady) {
      el.innerHTML = `${MARK}<div class="t1">${esc(t.readyTitle)}</div>${S.call.briefLine ? `<div class="t2">${esc(S.call.briefLine)}</div>` : ''}
        <div class="ctl"><button class="help" type="button" data-act="start" style="height:36px">${esc(t.startListening)}</button><button class="btn2" type="button" data-act="open-brief" style="height:36px">${esc(t.openBrief)}</button></div>
        <div class="foot">${esc(t.onDevice)}</div>`;
    } else {
      el.innerHTML = `<div class="ring">${MARK}</div><div class="t1">${esc(t.listeningTitle)}</div><div class="t2">${esc(t.listeningSub)}</div>`;
    }
    return true;
  }

  // Mic, pause, proactive tips: always in the 48 px bar, state visible without opening anything.
  const SVG = {
    mic: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true"><rect x="5.5" y="1.8" width="5" height="8" rx="2.5"/><path d="M3 7.5a5 5 0 0 0 10 0M8 12.5v2"/></svg>',
    micOff: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true"><rect x="5.5" y="1.8" width="5" height="8" rx="2.5"/><path d="M3 7.5a5 5 0 0 0 10 0M8 12.5v2M2.5 2.5l11 11"/></svg>',
    pause: '<svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><rect x="4" y="3" width="2.6" height="10" rx="1" fill="currentColor"/><rect x="9.4" y="3" width="2.6" height="10" rx="1" fill="currentColor"/></svg>',
    play: '<svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="M3 1.8v8.4L10 6z" fill="currentColor"/></svg>',
    bulb: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5.6 10.5C4.4 9.6 3.6 8.3 3.6 6.8a4.4 4.4 0 0 1 8.8 0c0 1.5-.8 2.8-2 3.7v1.3H5.6z"/><path d="M6.2 14h3.6"/></svg>'
  };
  function setCtl(id, html, label, tip, pressed, cls) {
    const b = $(id);
    b.innerHTML = html; b.className = 'ctl-btn' + (cls ? ' ' + cls : '');
    b.setAttribute('aria-label', label); b.title = tip;
    if (pressed === null) b.removeAttribute('aria-pressed'); else b.setAttribute('aria-pressed', String(pressed));
  }
  function renderControls(isReady) {
    const c = T().ctl, k = S.keys || {};
    const tip = (label, key) => key ? `${label} (${key})` : label;
    $('micBtn').parentElement.hidden = isReady;
    $('micBtn').parentElement.setAttribute('aria-label', c.group);
    // Mic: pressed = mic off. Off reads as a red crossed-out mic.
    setCtl('micBtn', S.call.micOff ? SVG.micOff : SVG.mic, S.call.micOff ? c.micOff : c.micOn, tip(S.call.micOff ? c.micOff : c.micOn, k.mute || '⌃⌥M'), !!S.call.micOff, S.call.micOff ? 'is-off' : '');
    // Pause: paused turns the button into a visible Resume; the dot and the timer go grey.
    if (S.call.paused) setCtl('pauseBtn', SVG.play + `<span>${esc(c.resume)}</span>`, c.resumeTip, tip(c.resumeTip, k.pause || '⌃⌥P'), true, 'is-resume');
    else setCtl('pauseBtn', SVG.pause, c.pause, tip(c.pause, k.pause || '⌃⌥P'), false, '');
    // Proactive tips: on = blue tinted background.
    const pro = !!S.call.proactive;
    setCtl('proBtn', SVG.bulb, pro ? c.proOn : c.proOff, tip(pro ? c.proOn : c.proOff, k.proactive || ''), pro, pro ? 'is-on' : '');
    document.querySelector('.bar').classList.toggle('paused-call', !!S.call.paused);
  }

  function kindLabel(c) {
    if (c.kind === 'finish') return c.label;
    if (c.state === 'done' && c.kind === 'answer') return T().kinds.answered;
    return T().kinds[c.kind] || c.kind;
  }

  function renderHero(c) {
    const el = $('hero'), t = T();
    if (!c) { el.hidden = true; el.dataset.id = ''; return; }
    if (el.dataset.id !== c.id) { el.style.animation = 'none'; void el.offsetWidth; el.style.animation = ''; }
    el.hidden = false; el.dataset.id = c.id;
    el.classList.toggle('finish', c.kind === 'finish');
    const meta = [c.who ? t.asked(c.who) : '', rel(c.at)].filter(Boolean).join(' · ');
    el.innerHTML = `
      <div class="head"><span class="kind k-${c.kind === 'finish' ? 'onme' : c.kind}">${esc(kindLabel(c))}</span>${c.kind === 'finish' ? '' : `<span class="meta">${esc(meta)}</span>`}</div>
      ${c.question ? `<div class="q">${esc(c.question)}</div>` : ''}
      ${c.say ? `<div class="say">${esc(c.say)}</div>` : ''}
      ${c.source ? `<div class="src">${ICON.doc}${esc(c.source)}</div>` : ''}
      ${c.kind === 'finish' ? '' : `<div class="acts">
        <button class="ghost" type="button" data-act="said" data-id="${esc(c.id)}">${esc(t.saidIt)}</button>
        <button class="ghost" type="button" data-act="shorter" data-id="${esc(c.id)}">${esc(t.shorter)}</button>
        <button class="ghost" type="button" data-act="pin" data-id="${esc(c.id)}">${esc(c.pinned ? t.unpin : t.pin)}</button>
        <button class="ghost" type="button" data-act="hide" data-id="${esc(c.id)}">${esc(t.hide)}</button>
      </div>`}`;
  }

  function renderEarlier(list) {
    const t = T(), el = $('earlier');
    if (!list.length) { el.innerHTML = ''; return; }
    el.innerHTML = `<div class="h"><b>${esc(t.earlier)}</b><span>${list.length}</span></div>` + list.map((c) => {
      const text = c.kind === 'answer' && c.state === 'done' ? `${c.question || ''} ${c.say ? '· ' + c.say : ''}` : (c.say || c.question || '');
      return `<div class="row ${c.state === 'done' ? 'done' : ''}" role="button" tabindex="0" data-act="promote" data-id="${esc(c.id)}">
        <span class="kind k-${c.kind === 'finish' ? 'onme' : c.kind}">${esc(kindLabel(c))}</span>
        <span class="t">${esc(text)}</span>
        <span class="m">${esc(rel(c.at))}</span>
        <span class="hover-acts"><button class="ghost" type="button" data-act="pin" data-id="${esc(c.id)}">${esc(t.pin)}</button><button class="ghost" type="button" data-act="hide" data-id="${esc(c.id)}">${esc(t.hide)}</button></span>
      </div>`;
    }).join('');
  }

  function renderPresentation() {
    const el = $('present'), p = S.presentation, t = T();
    if (S.call.mode !== 'presentation' || !p || !p.steps || !p.steps.length) { el.hidden = true; return; }
    el.hidden = false;
    const st = p.steps[p.index] || p.steps[0];
    const left = (st.secs || 0) - (p.elapsedInStep || 0);
    const fmt = (s) => `${s < 0 ? '+' : ''}${Math.floor(Math.abs(s) / 60)}:${String(Math.abs(s) % 60).padStart(2, '0')}`;
    const nx = p.steps[p.index + 1];
    el.innerHTML = `
      <div class="top"><span class="kind k-turn">${p.index + 1} / ${p.steps.length}</span><span class="clock ${left < 0 ? 'over' : ''}">${fmt(left)}</span></div>
      <div class="step">${esc(st.title)}</div>
      <div class="say">${esc(st.say || '')}</div>
      ${st.canSkip ? `<div class="meta">${esc(t.present.canSkip)}</div>` : ''}
      ${nx ? `<div class="nx">${esc(t.present.nextUp(nx.title, fmt(nx.secs || 0)))}</div>` : ''}
      <div class="ctl"><button class="btn2" type="button" data-act="present-prev">${esc(t.present.prev)}</button><button class="btn1" type="button" data-act="present-next">${esc(p.running ? t.present.next : t.present.start)}</button></div>`;
  }

  function renderPane(root, tab, isSheet) {
    const t = T();
    const openN = S.onMe.filter((o) => !o.done).length;
    const tabs = ['transcript', 'onme', 'brief'];
    let body = '';
    if (tab === 'transcript') {
      const unknown = Object.entries(S.speakers).find(([, s]) => !s.name);
      body = (unknown ? `<div class="newvoice">${ICON.person}<span class="t">${esc(t.newVoice)} <b>${esc(unknown[1].label || unknown[0])}</b></span><button class="link" type="button" data-act="name" data-sid="${esc(unknown[0])}">${esc(t.name)}</button></div>` : '') +
        S.transcript.map((l) => {
          const sp = S.speakers[l.speakerId] || {};
          const cls = sp.side === 'client' ? 'client' : sp.side === 'team' ? 'team' : 'unknown';
          return `<div class="tl"><button class="who ${cls}" type="button" data-act="name" data-sid="${esc(l.speakerId)}">${esc(sp.name || sp.label || l.speakerId)}</button><span>${esc(l.text)}</span></div>`;
        }).join('');
    } else if (tab === 'onme') {
      body = S.onMe.length ? S.onMe.map((o) => `<label class="onme-item"><input type="checkbox" data-act="onme-toggle" data-id="${esc(o.id)}" ${o.done ? 'checked' : ''}><span><span style="${o.done ? 'text-decoration:line-through;color:var(--text-3)' : ''}">${esc(o.text)}</span>${o.due ? `<br><span class="meta">${esc(o.due)}</span>` : ''}</span></label>`).join('') : `<p class="meta">${esc(t.noItems)}</p>`;
    } else if (tab === 'brief' && S.brief) {
      const b = S.brief;
      body = `<div class="brief">${b.goal ? `<p><b>${esc(b.goal)}</b></p>` : ''}${(b.sections || []).map((s) => `<h3>${esc(s.title)}</h3><ul>${s.items.map((i) => `<li>${esc(i)}</li>`).join('')}</ul>`).join('')}</div>`;
    }
    root.innerHTML = `
      ${isSheet ? `<button class="icon-btn close" type="button" data-act="close-sheet" aria-label="${esc(t.close)}">${ICON.x}</button>` : ''}
      <div class="tabs" role="tablist" ${isSheet ? 'style="margin-right:48px"' : ''}>${tabs.map((k) => `<button class="tab" role="tab" type="button" aria-selected="${k === tab}" data-act="${isSheet ? 'sheet-tab' : 'pane-tab'}" data-tab="${k}">${esc(k === 'onme' ? t.tabs.onme(openN) : t.tabs[k])}</button>`).join('')}</div>
      <div class="panebody" id="${isSheet ? 'sheetBody' : 'paneBody'}">${body}</div>
      ${tab === 'transcript' ? `<div class="panefoot"><span>${esc(t.legend)}</span><span>${esc(S.ui.follow ? t.following : t.jump)}</span></div>` : ''}`;
    if (tab === 'transcript' && S.ui.follow) { const pb = root.querySelector('.panebody'); pb.scrollTop = pb.scrollHeight; }
  }

  function renderMenu() {
    const m = $('menu'), t = T().menu;
    m.hidden = !S.ui.menuOpen;
    if (!S.ui.menuOpen) return;
    const items = [
      ['compact', S.call.mode === 'compact' ? t.full : t.compact, '⌃⌥T'],
      ['present', S.call.mode === 'presentation' ? t.stopPresent : t.present, ''],
      ['transcript', t.transcript, ''], ['brief', t.brief, ''],
      '-',
      ['clear-speakers', t.clearSpeakers, ''],
      ['switch-call', t.switchCall, ''], ['settings', t.settings, '⌘,']
    ];
    m.innerHTML = items.map((i) => i === '-' ? '<div class="sep"></div>' : `<button type="button" role="menuitem" data-act="menu" data-item="${i[0]}"><span>${esc(i[1])}</span><kbd>${i[2]}</kbd></button>`).join('');
  }

  function tick() {
    const s = Math.max(0, Math.floor((Date.now() - (S.call.startedAt || Date.now())) / 1000));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    $('timer').textContent = (h ? h + ':' + String(m).padStart(2, '0') : String(m).padStart(2, '0')) + ':' + String(sec).padStart(2, '0');
  }

  // ---------- Speaker naming popover ----------
  function openNamePopover(sid, anchor) {
    const t = T(), sp = S.speakers[sid] || {}, pop = $('pop');
    const r = anchor.getBoundingClientRect();
    pop.style.left = Math.min(r.left, window.innerWidth - 270) + 'px';
    pop.style.top = (r.bottom + 6) + 'px';
    let side = sp.side || 'client';
    pop.innerHTML = `<label class="meta" for="spName">${esc(t.name)}</label><input id="spName" type="text" value="${esc(sp.name || '')}">
      <div class="seg2"><button type="button" data-side="client" aria-pressed="${side === 'client'}">${esc(t.client)}</button><button type="button" data-side="team" aria-pressed="${side === 'team'}">${esc(t.team)}</button></div>
      <button class="btn1" type="button" id="spSave">${esc(t.save)}</button>`;
    pop.hidden = false;
    const input = pop.querySelector('#spName'); input.focus();
    pop.querySelectorAll('[data-side]').forEach((b) => b.onclick = () => { side = b.dataset.side; pop.querySelectorAll('[data-side]').forEach((x) => x.setAttribute('aria-pressed', x === b)); });
    const save = () => {
      const name = input.value.trim(); if (!name) return;
      S.speakers[sid] = Object.assign({}, sp, { name, side });
      post('name-speaker', { speakerId: sid, name, side });
      pop.hidden = true; render();
    };
    pop.querySelector('#spSave').onclick = save;
    input.onkeydown = (e) => { if (e.key === 'Enter') save(); if (e.key === 'Escape') pop.hidden = true; };
  }

  // ---------- Events ----------
  document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-act]');
    if (!$('menu').hidden && !e.target.closest('#menu') && !e.target.closest('#moreBtn')) { S.ui.menuOpen = false; renderMenu(); }
    if (!$('pop').hidden && !e.target.closest('#pop') && !(b && b.dataset.act === 'name')) $('pop').hidden = true;
    if (!b) return;
    const act = b.dataset.act, id = b.dataset.id;
    const card = id && S.cards.find((c) => c.id === id);
    switch (act) {
      case 'said': if (card) card.state = 'done'; S.ui.heroOverride = null; post('said', { id }); break;
      case 'hide': if (card) card.state = 'hidden'; S.ui.heroOverride = null; post('hide', { id }); e.stopPropagation(); break;
      case 'pin': if (card) card.pinned = !card.pinned; post('pin', { id, pinned: card && card.pinned }); e.stopPropagation(); break;
      case 'shorter': post('shorter', { id }); break;
      case 'promote': S.ui.heroOverride = id; break;
      case 'pane-tab': S.ui.paneTab = b.dataset.tab; break;
      case 'sheet-tab': S.ui.sheet = b.dataset.tab; break;
      case 'close-sheet': S.ui.sheet = null; break;
      case 'name': openNamePopover(b.dataset.sid, b); return;
      case 'onme-toggle': { const o = S.onMe.find((x) => x.id === id); if (o) { o.done = b.checked; post('onme-toggle', { id, done: o.done }); } break; }
      case 'start': S.call.state = 'live'; S.call.startedAt = Date.now(); post('start'); break;
      case 'open-brief': if (isWide()) S.ui.paneTab = 'brief'; else S.ui.sheet = 'brief'; post('open-brief'); break;
      case 'ctl-mic': S.call.micOff = !S.call.micOff; post('mute', { micOff: S.call.micOff }); break;
      case 'ctl-pause': S.call.paused = !S.call.paused; post('pause', { paused: S.call.paused }); break;
      case 'ctl-proactive': S.call.proactive = !S.call.proactive; post('proactive', { on: S.call.proactive }); break;
      case 'prepare-next': post('prepare-next'); return;
      case 'open-next': post('open-next'); return;
      case 'present-next': post('present-next'); return;
      case 'present-prev': post('present-prev'); return;
      case 'menu': {
        const item = b.dataset.item; S.ui.menuOpen = false;
        if (item === 'compact') S.call.mode = S.call.mode === 'compact' ? 'normal' : 'compact';
        else if (item === 'present') S.call.mode = S.call.mode === 'presentation' ? 'normal' : 'presentation';
        else if (item === 'transcript' || item === 'brief') { if (isWide()) S.ui.paneTab = item; else S.ui.sheet = item; }
        else if (item === 'pause') S.call.paused = !S.call.paused;
        else if (item === 'mute') S.call.micOff = !S.call.micOff;
        post('menu', { item, mode: S.call.mode });
        break;
      }
      default: return;
    }
    render();
  });
  document.addEventListener('keydown', (e) => {
    if (e.target.classList && e.target.classList.contains('row') && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); e.target.click(); }
    if (e.key === 'Escape') { S.ui.menuOpen = false; S.ui.sheet = null; S.ui.heroOverride = null; $('pop').hidden = true; render(); }
  });
  $('moreBtn').addEventListener('click', () => { S.ui.menuOpen = !S.ui.menuOpen; renderMenu(); });
  $('onmeBtn').addEventListener('click', () => { if (isWide()) { S.ui.paneTab = 'onme'; } else { S.ui.sheet = S.ui.sheet === 'onme' ? null : 'onme'; } render(); });
  $('helpBtn').addEventListener('click', () => post('help'));
  $('ask').addEventListener('submit', (e) => { e.preventDefault(); const v = $('askInput').value.trim(); if (v) { post('ask', { text: v }); $('askInput').value = ''; } });
  document.addEventListener('scroll', (e) => {
    if (e.target && e.target.id === 'paneBody') { const pb = e.target; S.ui.follow = pb.scrollTop + pb.clientHeight >= pb.scrollHeight - 8; }
  }, true);
  function isWide() { return $('app').clientWidth >= 760; }
  setInterval(() => { tick(); }, 1000);
  setInterval(() => { render(); }, 30000); // refresh relative times

  // ---------- Public API ----------
  window.LiveTips = {
    setState(partial) {
      for (const k of Object.keys(partial || {})) {
        if (k === 'call' || k === 'speakers') S[k] = Object.assign({}, S[k], partial[k]);
        else S[k] = partial[k];
      }
      if (S.ui.heroOverride && !S.cards.some((c) => c.id === S.ui.heroOverride)) S.ui.heroOverride = null;
      render();
    },
    setLang(l) { S.lang = STR[l] ? l : 'en'; render(); },
    setTheme(th) { S.theme = th; render(); },
    _state: S
  };

  // ---------- Demo data when opened in a browser ----------
  const inApp = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liveTips);
  if (!inApp) {
    const now = Date.now(), min = 60000;
    const q = new URLSearchParams(location.search);
    window.LiveTips.setState({
      lang: q.get('lang') || 'en', theme: q.get('theme') || 'auto',
      call: { title: 'Orbit weekly with the client', state: q.get('state') === 'ready' ? 'ready' : 'live', startsAt: '12:18', briefLine: 'Brief ready · 3 agenda items · 1 thing on you', startedAt: q.get('state') === 'empty' ? now - 42000 : now - 32 * min - 14000, minutesLeft: Number(q.get('left') || 13), mode: q.get('mode') || 'normal', recap: 'export on Tuesday, our QA tests week one, names from you by Friday.' },
      agenda: [
        { id: 'a1', title: 'Export release date', state: 'done' },
        { id: 'a2', title: 'Who tests the pilot', state: 'now' },
        { id: 'a3', title: 'Test accounts', state: 'todo' }
      ],
      cards: q.get('state') ? [] : [
        { id: 'c5', kind: 'answer', who: 'Emily C.', question: 'Who tests the pilot?', say: 'Our QA covers the first week, then your team takes over.', source: 'Kick-off notes, 21 Oct: 5 pilot users, names by Friday', at: now - 10000, state: 'active' },
        { id: 'c4', kind: 'turn', say: 'Pilot plan: 5 users, 2 weeks, starts Monday', at: now - 2 * min, state: 'active' },
        { id: 'c3', kind: 'onme', say: 'Send the test account list today', at: now - 6 * min, state: 'active' },
        { id: 'c2', kind: 'docs', say: 'Pilot: 5 users, list from the client', source: 'kickoff-notes.md', at: now - 8 * min, state: 'active' },
        { id: 'c1', kind: 'answer', who: 'Emily C.', question: 'When is the export live?', say: 'Tuesday, after the review', at: now - 12 * min, state: 'done' }
      ],
      onMe: [
        { id: 'o1', text: 'Send the test account list', due: 'Today' },
        { id: 'o2', text: 'Add 2 support users to the pilot', due: 'This week' }
      ],
      next: { title: 'Team retro', startsInMin: 8, prepared: false },
      speakers: { s1: { name: 'Emily', side: 'client' }, s2: { name: 'You', side: 'team' }, s3: { name: 'David', side: 'client' }, s4: { label: 'Speaker 3' } },
      transcript: [
        { speakerId: 's1', text: 'When is the export live for our users?' },
        { speakerId: 's2', text: 'It is on dev now, production on Tuesday after the review.' },
        { speakerId: 's3', text: 'Good. And the test accounts, who sends those?' },
        { speakerId: 's2', text: 'I will send the list today.' },
        { speakerId: 's4', text: 'Can we add two people from support to the pilot?' },
        { speakerId: 's1', text: 'And who tests the pilot itself?' }
      ],
      brief: { goal: 'Agree the pilot plan and the export release date.', sections: [
        { title: 'Open from last call', items: ['Test accounts from the client (open)', 'Who tests the pilot (partly answered)'] },
        { title: 'Risks', items: ['Pilot slips if the test accounts are late'] }
      ] },
      presentation: { index: 0, running: false, elapsedInStep: 0, steps: [
        { title: 'Why a pilot', say: 'Five users for two weeks show whether the export saves the team an hour a day.', secs: 90 },
        { title: 'Plan and dates', say: 'Starts Monday, review on day 10.', secs: 120 },
        { title: 'What we need from you', say: 'Names by Friday, test accounts by Thursday.', secs: 60, canSkip: false }
      ] }
    });
  }
})();
