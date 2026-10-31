// Pacenote 0.8.6 (F): the speakers block of the call window, above the tabs (Transcript, On me, Brief). The same
// anatomy as the Speakers card of a transcribed file: a row of chips and an open card for an unnamed voice.
// Pure functions of the window state, shared by tips.js and app/WebTests/feed.test.js.
(function (root) {
  'use strict';
  /** 0.8.6 (F): the speakers above the tabs, the same anatomy as the Speakers card of a transcribed file: a row of
   *  chips (dot, name or Speaker N, minutes; an unnamed one tinted "to name") and, for an unnamed voice, an open card. */
  function listOf(S) {
    return Object.entries(S.speakers).filter(([sid, sp]) => /^S\d+$/i.test(sid) && sp && (sp.name || (sp.seconds || 0) >= 2))
      .sort((a, b) => (+a[0].slice(1)) - (+b[0].slice(1)));
  }
  function cardVoice(S, list) {
    const ok = (sid, sp) => !sp.name && (sp.seconds || 0) >= S.spkPrompt && !((S.ui.spkSnooze[sid] != null) && (sp.seconds || 0) < S.ui.spkSnooze[sid] + 60);
    if (S.ui.spkCard) { const sp = S.speakers[S.ui.spkCard]; if (sp && !sp.name) return S.ui.spkCard; }
    const f = list.find(([sid, sp]) => ok(sid, sp));
    return f ? f[0] : null;
  }
  function block(S, t, esc) {
    const list = listOf(S);
    if (!list.length) return '';
    const names = new Set(), chips = [];
    for (const [sid, sp] of list) {
      if (sp.name && names.has(sp.name)) continue;          // merged speakers show once
      if (sp.name) names.add(sp.name);
      const side = sp.side === 'client' ? 'client' : sp.side === 'team' ? 'team' : 'unknown';
      const m = Math.round((sp.seconds || 0) / 60);
      chips.push(`<button class="spk-chip ${sp.name ? '' : 'unnamed'}" type="button" data-act="${sp.name ? 'name' : 'spk-card'}" data-sid="${esc(sid)}"><span class="dot ${side}"></span><span class="nm">${esc(sp.name || sp.label || sid)}</span><span class="mn">${esc(t.mins({ m }))}</span>${sp.name ? '' : `<span class="tn">${esc(t.toName)}</span>`}</button>`);
    }
    const voice = cardVoice(S, list);
    const unnamed = list.some(([, sp]) => !sp.name);
    const open = S.ui.spkOpen == null ? !!voice : (S.ui.spkOpen && unnamed);
    let card = '';
    if (open && voice) {
      const sp = S.speakers[voice] || {}, side = sp.side === 'client' ? 'client' : sp.side === 'team' ? 'team' : '';
      const sug = (sp.suggestions || []).map((x) => `<button class="sug" type="button" data-act="name-pick" data-sid="${esc(voice)}" data-name="${esc(x.name)}"${x.score == null ? ` title="${esc(t.notByVoice)}"` : ''}>${esc(x.score == null ? x.name : t.soundsLike({ name: x.name, p: Math.round(x.score * 100) }))}</button>`).join('');
      const others = list.filter(([sid, x]) => sid !== voice && x.name).map(([sid, x]) => `<option value="${esc(sid)}">${esc(x.name)}</option>`).join('');
      card = `<div class="spk-card" data-sid="${esc(voice)}">
        <div class="spk-card-h"><b>${esc(sp.label || voice)}</b><span class="meta">${esc(t.secsSpoken({ s: Math.round(sp.seconds || 0) }))}</span></div>
        ${sp.lastQuote ? `<div class="q"><span class="meta">${esc(t.lastSaid)}</span> \u201c${esc(sp.lastQuote)}\u201d</div>` : ''}
        ${t.noClip ? `<div class="meta spk-noclip">${esc(t.noClip)}</div>` : ''}
        ${sug ? `<div class="sugs">${sug}</div>` : ''}
        <div class="spk-name-row"><input id="spkCardName" type="text" placeholder="${esc(t.typeName)}" aria-label="${esc(t.typeName)}" data-sid="${esc(voice)}">
          <span class="seg2 sm"><button type="button" data-act="spk-side" data-sid="${esc(voice)}" data-side="team" aria-pressed="${side === 'team'}">${esc(t.team)}</button><button type="button" data-act="spk-side" data-sid="${esc(voice)}" data-side="client" aria-pressed="${side === 'client'}">${esc(t.client)}</button></span></div>
        <div class="spk-more meta">${esc(t.more)} ${others ? `<select class="spk-same" data-sid="${esc(voice)}" aria-label="${esc(t.samePerson)}"><option value="">${esc(t.samePerson)}</option>${others}</select> · ` : ''}<button class="link" type="button" data-act="spk-notnow" data-sid="${esc(voice)}">${esc(t.notNow)}</button></div>
      </div>`;
    }
    return `<div class="spkbar${open && voice ? ' open' : ''}"><div class="spk-chips"><button class="spks-h" type="button" data-act="spk-toggle" aria-expanded="${!!(open && voice)}"><b>${esc(t.speakersH)}</b></button>${chips.join('')}</div>${card}</div>`;
  }
  const api = { list: listOf, cardVoice, block };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.PacenoteSpeakers = api;
})(this);
