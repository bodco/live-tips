/* Pacenote 0.8 (F2): the feed adapter of the tips window.
 *
 * The recorder and the tips engine write an item stream (<stem>.app.tips.jsonl) that is shared with the
 * live-tips skill and its own window (live-transcriber). The app keeps pushing those raw items, the
 * recorder status, the transcript and the speakers through the same calls as before (addItems, setStatus,
 * addTranscript, setSpeakers, setPrepDoc, setPrep, setUpNext). This file turns them into the state of the
 * new window (LiveTips.setState, REDESIGN-SPEC 3.10). Pure logic, no DOM: tested with node in
 * app/Tests/feed.test.js.
 */
(function (root) {
  'use strict';

  // Emoji are never shown (the engine and the recorder still put them in headlines).
  const EMOJI = /[\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}\u{FE0F}\u{200D}\u{20E3}]/gu;
  function clean(s) { return String(s == null ? '' : s).replace(EMOJI, '').replace(/\s+/g, ' ').trim(); }
  function itemText(x) { return typeof x === 'string' ? x : (x && x.text) || ''; }

  /** "10:31:40" today, in ms; a time more than an hour ahead belongs to yesterday. */
  function hmsToMs(hms, now) {
    const m = /^(\d\d):(\d\d)(?::(\d\d))?$/.exec(String(hms || '').trim());
    if (!m) return now;
    const d = new Date(now);
    d.setHours(+m[1], +m[2], +(m[3] || 0), 0);
    let ms = d.getTime();
    if (ms - now > 3600000) ms -= 86400000;
    return ms;
  }

  const ASKS_RX = /^(.{1,48}?)\s+(?:asks|asked|wants to know|питає|запитує|питала|питав|просить)\s*[:,]?\s+(.+)$/i;
  const ROOM_RX = /^(?:room question|question from the room|питання із зали|питання залу|питання)\s*:\s*(.+)$/i;
  const TURN_RX = /(your turn|over to you|твоя черга|ваша черга|твій виступ|your speech)/i;
  const UNCHECKED_RX = /(call picture|unchecked|картин[аи] дзвінка|не перевірено)/i;

  function Feed(opts) {
    this.setState = opts.setState;
    this.tr = opts.tr || ((k) => k);
    this.now = opts.now || (() => Date.now());
    this.reset();
  }

  Feed.prototype.reset = function () {
    this.cards = [];            // newest last
    this.byId = {};
    this.edits = {};            // id -> {say} corrected in the window
    this.local = {};            // id -> {state, pinned} set in the window
    this.cardSeen = {};
    this.sit = null;
    this.onMeDone = {};
    this.agendaEngine = null;   // from the engine's "agenda" item (wins over the brief's checklist)
    this.agendaBrief = [];
    this.agendaManual = {};     // id -> state, set by a click on a segment
    this.facts = [];
    this.slides = null;
    this.outline = null;
    this.outlinePos = null;
    this.recap = '';
    this.status = {};
    this.heard = false;
    this.silentSince = null;
    this.speakers = {};
    this.transcript = [];
    this.channels = { me: null, them: null };
    this.brief = null;
    this.briefText = '';
    this.briefAt = '';
    this.prep = 'none';
    this.next = null;
    this.starting = 0;
    this.ending = false;
    this.title = '';
    this.renamed = false;
  };

  Feed.prototype.rename = function (t) { this.title = clean(t); this.renamed = true; this.emit(); };

  // ---------- cards ----------

  Feed.prototype.idOf = function (it) {
    if (it.uid) return 'u:' + it.uid;
    if (it.card) return 'c:' + it.card;
    return 'g:' + (it.kind || 'tip') + '|' + (it.t || '') + '|' + clean(it.gist).slice(0, 40);
  };

  Feed.prototype.kindOf = function (it) {
    const k = it.kind || 'tip', g = String(it.gist || '');
    if (k === 'answer' || k === 'fact' || k === 'card') return 'docs';
    if (k === 'speech') return 'turn';
    if (k === 'status') return 'neutral';
    if (k === 'wrapup') return 'neutral';
    if (/^\s*\u{1F50E}/u.test(g)) return 'docs';
    if (TURN_RX.test(g) || /^\s*\u{1F5E3}/u.test(g)) return 'turn';
    if (it.level === 'red' || it.level === 'orange' || /^\s*\u{1F198}/u.test(g)) return 'answer';
    return 'neutral';
  };

  Feed.prototype.toCard = function (it) {
    const kind = this.kindOf(it);
    const gist = clean(it.gist), phrase = clean(it.phrase);
    const items = (it.items || []).map((x) => clean(itemText(x))).filter(Boolean);
    let who = '', question = '', say = '', meta = '', source = '', unverified = false;
    if ((it.kind === 'answer' || it.kind === 'fact') && it.q != null) {
      const q = clean(it.q).replace(/^(find|знайди|пошук)\s*:\s*/i, '');
      const shorter = /^shorter\b|^коротше\b/i.test(q);
      meta = shorter ? this.tr('shorterMeta') : this.tr('searched', { q });
      say = phrase || gist;
      if (!phrase && items.length) { say = gist; }
    } else {
      let m;
      if ((m = ASKS_RX.exec(gist))) { who = clean(m[1]); question = clean(m[2]); say = phrase; }
      else if ((m = ROOM_RX.exec(gist))) { question = clean(m[1]); say = phrase; }
      else if (phrase) { question = gist; say = phrase; }
      else { say = gist; }
      if (!say) { say = question; question = ''; }
    }
    let note = clean(it.note);
    if (UNCHECKED_RX.test(note)) { unverified = true; note = ''; }
    note = note.replace(/^(sources?|джерела|джерело)\s*:\s*/i, '');
    source = note || (items.length && (kind === 'docs' || kind === 'answer') ? items[0] : '');
    const id = this.idOf(it);
    const c = {
      id, kind, who, question, say, source, meta, unverified,
      items: kind === 'turn' ? items : items.slice(source === items[0] ? 1 : 0, 4),
      at: hmsToMs(it.at || it.t, this.now()),
      state: 'active', pinned: false, partial: !!it.partial, late: !!it.late, card: it.card || '', t: it.t || '',
      raw: { kind: it.kind || 'tip', gist: it.gist || '', phrase: it.phrase || '', items: it.items || [] }
    };
    const ed = this.edits[id];
    if (ed) { if (ed.removed) return null; if (ed.say != null) c.say = ed.say; c.edited = true; }
    const loc = this.local[id];
    if (loc) { if (loc.state) c.state = loc.state; if (loc.pinned != null) c.pinned = loc.pinned; }
    return c;
  };

  Feed.prototype.put = function (c) {
    const old = this.byId[c.id];
    if (old) {
      // An update (the full tip after its gist, an edit) keeps the place, the pin and the state.
      c.at = Math.min(old.at, c.at);
      c.pinned = old.pinned; if (old.state !== 'active') c.state = old.state;
      this.cards[this.cards.indexOf(old)] = c;
    } else {
      this.cards.push(c);
      if (this.cards.length > 60) { const gone = this.cards.shift(); delete this.byId[gone.id]; }
    }
    this.byId[c.id] = c;
  };

  Feed.prototype.cardPasses = function (it) {
    const key = String(it.card || it.id || it.gist || '').toLowerCase().slice(0, 80), now = this.now();
    if (this.cardSeen[key] && now - this.cardSeen[key] < 10 * 60 * 1000) return false;   // the same card twice in 10 min
    if (this.sit && this.sit.mine === false && it.level !== 'red') return false;          // someone else's topic: quiet
    this.cardSeen[key] = now;
    return true;
  };

  // ---------- the item stream ----------

  Feed.prototype.addItems = function (items) {
    let changed = false;
    for (const it of items || []) {
      if (!it || typeof it !== 'object') continue;
      changed = this.addItem(it) !== false || changed;
    }
    if (changed) this.emit();
  };

  Feed.prototype.addItem = function (it) {
    const k = it.kind || 'tip';
    switch (k) {
      case 'retract': { const id = 'u:' + it.uid, c = this.byId[id]; if (c) { this.cards.splice(this.cards.indexOf(c), 1); delete this.byId[id]; } return true; }
      case 'question': return false;                      // heard-question lines are not shown (2026-10-26 review)
      case 'ask': return false;                           // echoes of what the PM typed: the field already shows it
      case 'ack': this.toast = { text: this.tr('applied'), kind: 'ok', at: this.now() }; return true;
      case 'notice': this.prep = 'ready'; this.toast = { text: this.tr('prepReady'), kind: 'ok', at: this.now() }; return true;
      case 'agenda':
        this.agendaEngine = (it.items || []).map((x, i) => {
          const text = clean(itemText(x)).replace(/^\u2713\s*/, '');
          const done = typeof x === 'string' ? /^\s*\u2713/.test(x) : !!(x && x.done);
          return { id: 'a' + i, title: text, done, cur: typeof x === 'object' && x && !!x.cur };
        });
        return true;
      case 'commitment_done': {
        // Pacenote 0.8 (rules/commitments.yaml > closing): an open commitment was said to be done. A quiet card
        // (never the hero); only the PM's Mark done closes it in the register.
        if (!it.id) return false;
        const id = 'k:' + it.id;
        if (this.byId[id]) return false;
        const mine = !it.owner || it.owner === 'me';
        this.put({
          id, kind: 'onme', quiet: true, who: mine ? '' : clean(it.owner), question: '', say: clean(it.text),
          source: '', meta: '', unverified: false, items: [], at: hmsToMs(it.at || it.t, this.now()), state: 'active', pinned: false,
          partial: false, late: false, card: '', t: it.t || '', commit: { id: String(it.id), text: clean(it.text), mine },
          raw: { kind: 'commitment_done', gist: it.gist || '', phrase: '', items: [] }
        });
        return true;
      }
      case 'risk': {
        // Pacenote 0.8 (rules/risks.yaml): a risk heard on the call is a quiet card in Earlier, never the main one.
        const id = 'r:' + clean(it.gist).toLowerCase().slice(0, 60);
        if (this.byId[id]) return false;
        this.put({
          id, kind: 'risk', quiet: true, who: clean(it.who), question: '', say: clean(String(it.gist || '').replace(/^\s*\S*\s*(risk|ризик)\s*:\s*/i, '')),
          source: '', meta: '', unverified: false, items: [], at: hmsToMs(it.at || it.t, this.now()), state: 'active', pinned: false,
          partial: false, late: false, card: '', t: it.t || '', raw: { kind: 'risk', gist: it.gist || '', phrase: '', items: [] }
        });
        return true;
      }
      case 'checklist':
        if (!this.agendaEngine) this.agendaBrief = (it.items || []).map((x, i) => ({ id: 'b' + i, title: clean(itemText(x)), done: false, cur: false }));
        return true;
      case 'facts': this.facts = it.facts || []; return false;
      case 'outline': this.outline = it.sections || []; return true;
      case 'outline_pos': this.outlinePos = it.cur; return true;
      case 'timeline': return false;
      case 'slides': this.slides = it; return true;
      case 'situation': this.situation(it); return true;
      case 'speaker_ask': {
        const sid = it.sid; if (!sid) return false;
        if (!this.speakers[sid]) this.speakers[sid] = { name: '', side: '', label: this.tr('speakerN', { n: String(sid).replace(/^S/i, '') }) };
        return true;
      }
      case 'speaker_auto': if (it.sid) { this.speakers[it.sid] = Object.assign({}, this.speakers[it.sid], { name: clean(it.name) }); } return true;
      case 'speakers_cleared': for (const s of Object.keys(this.speakers)) this.speakers[s].name = ''; return true;
      case 'wrapup':
        if (it.uid === 'call-picture') {   // the call summary is not a card any more: it feeds the finish card
          const items = (it.items || []).map((x) => clean(itemText(x)));
          this.recap = items.filter((x) => !/^(not said|не сказано|не прозвучало)/i.test(x)).join('; ');
          return true;
        }
        break;
      case 'card': if (!this.cardPasses(it)) return false; break;
      case 'fact': if (!it.q) return false; break;
      default: break;
    }
    const c = this.toCard(it);
    if (!c) return false;
    if (k === 'speech') c.id = 'u:speech';
    this.put(c);
    return true;
  };

  Feed.prototype.situation = function (s) {
    const wasTurn = !!(this.sit && (this.sit.asks || []).some((a) => a.type === 'update'));
    this.sit = s;
    const turn = (s.asks || []).some((a) => a.type === 'update');
    if (turn && !wasTurn) {
      // Your turn: the speech card (or a plain turn card) becomes the newest and the hero.
      const sp = this.byId['u:speech'];
      if (sp) { sp.at = this.now(); sp.state = 'active'; sp.kind = 'turn'; }
      else this.put({ id: 'turn:' + this.now(), kind: 'turn', who: '', question: clean(s.topic), say: this.tr('yourTurn'), source: '', meta: '', items: [],
                      at: this.now(), state: 'active', pinned: false, raw: { kind: 'turn' } });
    }
    const parts = [];
    for (const d of s.decisions || []) parts.push(clean(d));
    for (const a of s.actions || []) parts.push((a.from && a.from !== 'PM' ? clean(a.from) + ': ' : '') + clean(a.what) + (a.due ? ' (' + clean(a.due) + ')' : ''));
    if (parts.length) this.recap = parts.join('; ');
  };

  Feed.prototype.onMe = function () {
    const s = this.sit || {}, out = [];
    const norm = (x) => String(x || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
    const asks = (s.asks || []).filter((a) => a.type !== 'update');
    const askN = asks.map((a) => norm(a.what)).filter(Boolean);
    for (const a of asks) {
      const id = 'a:' + norm(a.what);
      out.push({ id, text: clean(a.what), due: clean(a.who), done: !!this.onMeDone[id], ask: true });
    }
    for (const a of s.actions || []) {
      const an = norm(a.what);
      if (an && askN.some((q) => q === an || (an.length > 12 && (q.includes(an) || an.includes(q))))) continue;
      if (a.from && a.from !== 'PM' && a.mine === false) continue;
      const id = 'm:' + an;
      out.push({ id, text: clean(a.what), due: clean(a.due), done: !!this.onMeDone[id] });
    }
    return out;
  };

  Feed.prototype.agenda = function () {
    const src = this.agendaEngine || this.agendaBrief || [];
    let cur = src.findIndex((a) => a.cur);
    if (cur < 0) cur = src.findIndex((a) => !a.done);
    return src.map((a, i) => {
      const manual = this.agendaManual[a.id];
      return { id: a.id, title: a.title, state: manual || (a.done ? 'done' : i === cur ? 'now' : 'todo') };
    });
  };

  Feed.prototype.presentation = function () {
    if (this.slides && Array.isArray(this.slides.slides) && this.slides.slides.length) {
      return this.slides.slides.map((sl) => {
        const body = sl.body || [];
        return { title: clean(sl.title), say: body.filter((b) => b.k === 'p').map((b) => clean(b.t)).join(' '),
                 secs: +sl.sec || 0, canSkip: body.some((b) => b.k === 's') };
      });
    }
    if (this.outline && this.outline.length) {
      return this.outline.map((s) => ({ title: clean(s.title), say: (s.points || []).slice(0, 3).map(clean).join('. '), secs: +s.sec || 0, canSkip: false }));
    }
    return [];
  };

  // ---------- status, transcript, speakers, brief, Up next ----------

  Feed.prototype.setStatus = function (s) {
    this.status = s || {};
    const st = this.status.state || '';
    if (st === 'recording' && this.status.system_audio === 'ok') this.heard = true;
    if (this.status.system_audio === 'silent') { if (!this.silentSince) this.silentSince = this.now(); } else this.silentSince = null;
    if (st === 'recording') this.starting = 0;
    if (this.status.title && !this.renamed) this.title = clean(this.status.title);
    this.emit();
  };

  Feed.prototype.alert = function () {
    const s = this.status, rec = s.state === 'recording', tr = this.tr;
    if (this.ending || s.state === 'stopping') return { text: tr('ending'), level: 'info' };
    if (s.state === 'stopped') return { text: tr('ended'), level: 'info' };
    if (s.state === 'loading_model' || this.starting) return { text: tr('starting'), level: 'info' };
    const streak = +s.mic_stall_streak || 0;
    if (rec && s.mic !== 'muted' && (s.mic === 'stalled' || streak >= 3)) return { text: tr('micStalled'), level: 'warn' };
    if (rec && this.heard && this.silentSince && this.now() - this.silentSince > 15000) return { text: tr('cantHear'), level: 'warn' };
    if (rec && s.asr_lag_s != null && s.asr_lag_s > 4) return { text: tr('asrBehind', { n: s.asr_lag_s }), level: 'warn' };
    if (rec && s.listener_age_s != null && s.listener_age_s > 75) return { text: tr('engineDeaf'), level: 'warn' };
    return null;
  };

  const TR_RX = /^\[(\d\d:\d\d:\d\d)\] (.+?)(?: \[(S\d+)\])? \(([\w+-]+)\): (.*)$/;
  Feed.prototype.addTranscript = function (lines) {
    for (const l of lines || []) {
      let m;
      if ((m = /^- (?:Канали|Channels): (.+?) = .*?, (.+?) = /.exec(l))) { this.channels = { me: m[1], them: m[2] }; continue; }
      if ((m = /^- (?:Канали|Channels): (.+?) = /.exec(l))) { this.channels.me = m[1]; continue; }
      m = TR_RX.exec(l); if (!m) continue;
      const sid = m[3] || (this.channels.me && m[2] === this.channels.me ? 'me' : /^(я|me|pm)$/i.test(m[2]) ? 'me' : 'other');
      if (!m[3] && sid === 'other' && !/^(співрозмовник|other)$/i.test(m[2])) {
        // An older line with a typed name and no cluster: the name is the speaker.
        const key = 'n:' + m[2];
        if (!this.speakers[key]) this.speakers[key] = { name: clean(m[2]), side: '' };
        this.transcript.push({ speakerId: key, text: m[5], t: m[1] });
        continue;
      }
      if (m[3] && !this.speakers[m[3]]) this.speakers[m[3]] = { name: '', side: '', label: this.tr('speakerN', { n: m[3].replace(/^S/i, '') }) };
      this.transcript.push({ speakerId: sid, text: m[5], t: m[1] });
    }
    if (this.transcript.length > 600) this.transcript = this.transcript.slice(-600);
    this.emit();
  };

  Feed.prototype.setSpeakers = function (d) {
    if (!d || typeof d !== 'object') return;
    const cl = d.clusters || {};
    for (const sid of Object.keys(cl)) {
      const c = cl[sid] || {};
      this.speakers[sid] = Object.assign({ label: this.tr('speakerN', { n: sid.replace(/^S/i, '') }) }, this.speakers[sid],
                                         { name: c.name ? clean(c.name) : '', side: c.side || (this.speakers[sid] || {}).side || '' });
    }
    for (const a of Object.keys(d.merged || {})) {
      const to = d.merged[a]; if (this.speakers[to]) this.speakers[a] = Object.assign({}, this.speakers[to]);
    }
    this.emit();
  };

  /** The preparation (.brief.md): goal, sections with bullets; its checklist is the agenda until the engine sends one. */
  Feed.prototype.setPrepDoc = function (p) {
    if (!p) return;
    this.briefText = String(p.text || '');
    this.briefAt = p.at || '';
    const b = { goal: '', sections: [] };
    let sec = null, checklist = [];
    for (const raw of this.briefText.split('\n')) {
      const line = raw.trim();
      let m;
      if ((m = /^\*\*(?:goal|мета|ціль)\s*:?\*\*\s*:?\s*(.+)$/i.exec(line))) { b.goal = clean(m[1].replace(/\*\*/g, '')); continue; }
      if ((m = /^#{2,3}\s+(.+)$/.exec(line))) { sec = { title: clean(m[1]), items: [] }; b.sections.push(sec); continue; }
      if ((m = /^[-*]\s+\[( |x|X)\]\s+(.+)$/.exec(line))) {
        const text = clean(m[2].replace(/\*\*/g, ''));
        checklist.push({ id: 'b' + checklist.length, title: text, done: m[1] !== ' ', cur: false });
        if (sec) sec.items.push(text);
        continue;
      }
      if ((m = /^[-*]\s+(.+)$/.exec(line)) && sec) sec.items.push(clean(m[1].replace(/\*\*/g, '')));
    }
    b.sections = b.sections.filter((s) => s.items.length);
    this.brief = b;
    if (checklist.length) this.agendaBrief = checklist;
    if (this.prep === 'none') this.prep = 'ready';
    this.emit();
  };

  Feed.prototype.setPrep = function (p) { if (p && p.state) { this.prep = p.state; this.emit(); } };

  Feed.prototype.setUpNext = function (list) {
    const u = (list || [])[0];
    this.next = u ? { id: u.id, title: clean(u.title), startsInMin: u.starts_in_min != null ? Math.max(0, Math.round(u.starts_in_min)) : null,
                      prepared: u.prep === 'ready', preparing: u.prep === 'running' } : null;
    this.emit();
  };

  // ---------- what the window did ----------

  Feed.prototype.mark = function (id, patch) {
    this.local[id] = Object.assign({}, this.local[id], patch);
    const c = this.byId[id]; if (c) Object.assign(c, patch);
  };
  Feed.prototype.edit = function (id, say) {
    this.edits[id] = { say };
    const c = this.byId[id]; if (c) { c.say = say; c.edited = true; }
    this.emit();
  };
  Feed.prototype.toggleOnMe = function (id, done) { this.onMeDone[id] = !!done; this.emit(); };
  Feed.prototype.setAgendaState = function (id, state) { this.agendaManual[id] = state; this.emit(); };
  /** The PM pressed Mark done on a commitment card. */
  Feed.prototype.commitDone = function (cardId) { const c = this.byId[cardId]; if (c) { c.state = 'done'; this.local[cardId] = Object.assign({}, this.local[cardId], { state: 'done' }); this.emit(); } };

  /** Prepared facts that match a typed question (shown at once, before Claude answers). */
  Feed.prototype.searchFacts = function (q) {
    const toks = (s) => (String(s || '').toLowerCase().match(/[\p{L}\p{N}'’]{3,}/gu) || []);
    const want = toks(q); if (!want.length) return [];
    return this.facts.map((f) => {
      const text = typeof f === 'string' ? f : [f.title, f.text, f.fact].filter(Boolean).join(': ');
      const have = toks(text);
      const score = want.filter((w) => have.some((h) => h.startsWith(w) || w.startsWith(h))).length / want.length;
      return { text: clean(text), source: clean(f.source || f.src || ''), score };
    }).filter((x) => x.score >= 0.5).sort((a, b) => b.score - a.score).slice(0, 2);
  };

  // ---------- state ----------

  Feed.prototype.state = function () {
    const s = this.status, st = s.state || '';
    const ready = st === 'standby' && !this.starting;
    const steps = this.presentation();
    const presenting = String(s.call_type || '') === 'presentation' && steps.length > 0;
    const briefLine = this.prep === 'ready' ? this.tr('briefReady', { at: this.briefAt })
      : this.prep === 'running' ? this.tr('briefPreparing') : this.prep === 'failed' ? this.tr('briefFailed') : this.tr('noBrief');
    return {
      call: {
        title: this.title || clean(s.title), state: ready ? 'ready' : st === 'stopped' ? 'ended' : 'live',
        startedAt: s.started_at ? Date.parse(s.started_at) : null, startsAt: '',
        paused: s.tips_paused === true || s.tips_paused === 'on' || s.tips_paused === 'true',
        micOff: s.mic === 'muted', minutesLeft: s.minutes_left != null ? +s.minutes_left : null,
        recap: this.recap, briefLine, alert: this.alert(), presentable: steps.length > 0, presenting
      },
      agenda: this.agenda(),
      cards: this.cards.map((c) => Object.assign({}, c)),
      onMe: this.onMe(),
      next: this.next,
      speakers: Object.assign({ me: { name: this.tr('me'), side: 'team' }, other: { name: this.tr('them'), side: 'client' } }, this.speakers),
      transcript: this.transcript.slice(-400),
      brief: this.brief, briefText: this.briefText,
      steps,
      toast: this.toast || null
    };
  };

  Feed.prototype.emit = function () { if (this.setState) this.setState(this.state()); };

  if (typeof module !== 'undefined' && module.exports) module.exports = { Feed, clean, hmsToMs };
  else root.PacenoteFeed = Feed;
})(this);
