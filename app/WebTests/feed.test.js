// Pacenote 0.8 (F2): tests of the tips window's feed adapter (app/Resources/tips/feed.js).
// Run: node app/WebTests/feed.test.js   (Node 18+, no packages)
'use strict';
const assert = require('assert');
const path = require('path');
const { Feed, clean, hmsToMs } = require(path.join(__dirname, '../Resources/tips/feed.js'));

let failures = 0, passed = 0;
function test(name, fn) { try { fn(); passed++; } catch (e) { failures++; console.log('FAIL', name, '\n ', e.message); } }

const tr = (k, p) => ({ searched: `You searched: ${p && p.q}`, speakerN: `Speaker ${p && p.n}`, me: 'Me', them: 'Other side',
  yourTurn: 'Your turn', briefReady: 'Brief ready', noBrief: 'No brief yet', applied: 'Applied', prepReady: 'Brief ready',
  cantHear: "Can't hear", micStalled: 'Mic stopped', asrBehind: 'Behind', starting: 'Starting', ending: 'Ending', ended: 'Ended',
  engineDeaf: 'Deaf', briefPreparing: 'Preparing', briefFailed: 'Failed', shorterMeta: 'Shorter' }[k] || k);
const NOW = new Date(2026, 9, 28, 10, 45, 0).getTime();
function make() { let last = null; const f = new Feed({ setState: (s) => { last = s; }, tr, now: () => NOW }); return { f, get: () => last }; }

// The demo the app shows with --prompter-demo (main.swift), as the engine writes it.
const DEMO = [
  { t: '10:30:00', kind: 'speech', uid: 'speech', level: 'info', gist: '\u{1F7E2} Your speech: since Monday', phrase: 'Two projects, short: the export is on dev, the pilot starts Monday.', items: ['Export: on dev, production Tuesday', 'Pilot: 5 users from Monday', 'Blocker: test accounts from the client', 'Ask: confirm the pilot list today'], engine: 'app' },
  { t: '10:31:10', kind: 'situation', topic: 'export release plan', owner: 'Dana', mine: true, floor: 'Dana', asks: [{ t: '10:31:05', who: 'Dana', what: 'send the test account list', type: 'request' }], actions: [{ what: 'send the test account list', due: 'today', from: 'Dana' }, { what: 'confirm the pilot users', due: 'Friday', from: 'PM' }], decisions: ['export goes to production on Tuesday'], speech_done: [0] },
  { t: '10:31:40', src: '10:31:36', kind: 'tip', level: 'red', gist: '\u{1F3AF} Dana asks: when is the export live?', phrase: 'It is on dev now; production on Tuesday after the review.', items: ['Review: Monday 15:00'], note: 'brief, 24.10', engine: 'app' },
  { t: '10:33:12', src: '10:33:08', kind: 'tip', level: 'orange', gist: '\u{1F7E0} Room question: who tests the pilot?', phrase: 'Our QA covers the first week, then the client team.', engine: 'app' },
  { t: '10:34:00', kind: 'answer', level: 'info', q: 'find: pilot users', gist: '\u{1F50E} Pilot: 5 users, list from the client', items: ['Kick-off notes 21.10: 5 users, names by Friday'], note: 'Sources: kickoff-notes.md', engine: 'app' },
  { t: '10:40:00', kind: 'wrapup', uid: 'call-picture', level: 'info', gist: '\u{1F4CB} Call summary', items: ['Decision: export goes to production on Tuesday', 'On me: send the test account list (today)', 'Not said from the speech: Blocker: test accounts from the client'], note: 'from the call picture, unchecked', engine: 'app' }
];

test('clean removes emoji and long spaces', () => {
  assert.strictEqual(clean('\u{1F3AF}  Dana asks: hi ✅'), 'Dana asks: hi');
  assert.strictEqual(clean('❓ Who?'), 'Who?');
});

test('hh:mm:ss is today, a time far ahead is yesterday', () => {
  assert.strictEqual(new Date(hmsToMs('10:31:40', NOW)).getHours(), 10);
  assert.ok(hmsToMs('23:50:00', NOW) < NOW);
});

test('demo stream: cards, kinds, who and question, no emoji, no summary card', () => {
  const { f, get } = make();
  f.addItems(DEMO);
  const s = get();
  const kinds = s.cards.map((c) => c.kind);
  assert.deepStrictEqual(kinds, ['turn', 'answer', 'answer', 'docs']);
  const dana = s.cards.find((c) => c.who === 'Dana');
  assert.strictEqual(dana.question, 'when is the export live?');
  assert.strictEqual(dana.say, 'It is on dev now; production on Tuesday after the review.');
  assert.strictEqual(dana.source, 'brief, 24.10');
  const room = s.cards[2];
  assert.strictEqual(room.question, 'who tests the pilot?');
  const docs = s.cards[3];
  assert.strictEqual(docs.meta, 'You searched: pilot users');
  assert.strictEqual(docs.source, 'kickoff-notes.md');
  const all = JSON.stringify(s.cards.map((c) => [c.who, c.question, c.say, c.source, c.meta]));
  assert.ok(!/\p{Extended_Pictographic}/u.test(all), 'no emoji in card text');
  assert.ok(s.call.recap.includes('export goes to production on Tuesday'));
  assert.ok(!s.call.recap.includes('Not said'), 'the not-raised line is not part of the recap');
});

test('On me: an ask and the same action are shown once; the PM action stays', () => {
  const { f, get } = make();
  f.addItems(DEMO);
  const texts = get().onMe.map((o) => o.text);
  assert.deepStrictEqual(texts, ['send the test account list', 'confirm the pilot users']);
  f.toggleOnMe(get().onMe[1].id, true);
  assert.strictEqual(get().onMe[1].done, true);
});

test('a streamed gist is replaced by the full tip with the same uid, a retract removes it', () => {
  const { f, get } = make();
  f.addItems([{ t: '10:40:00', kind: 'tip', level: 'red', uid: 'x1', partial: true, gist: 'Emily asks: budget?' }]);
  f.addItems([{ t: '10:40:02', kind: 'tip', level: 'red', uid: 'x1', gist: 'Emily asks: budget?', phrase: 'Within the estimate, 120 hours.' }]);
  assert.strictEqual(get().cards.length, 1);
  assert.strictEqual(get().cards[0].say, 'Within the estimate, 120 hours.');
  f.addItems([{ kind: 'retract', uid: 'x1' }]);
  assert.strictEqual(get().cards.length, 0);
});

test('said, hide and an edit survive an update of the same card', () => {
  const { f, get } = make();
  f.addItems([{ t: '10:40:00', kind: 'tip', level: 'red', uid: 'y', gist: 'Q?', phrase: 'A.' }]);
  f.mark('u:y', { state: 'done' });
  f.edit('u:y', 'A, corrected.');
  f.addItems([{ t: '10:40:05', kind: 'tip', level: 'red', uid: 'y', gist: 'Q?', phrase: 'A again.' }]);
  assert.strictEqual(get().cards[0].state, 'done');
  assert.strictEqual(get().cards[0].say, 'A, corrected.');
});

test('your turn: the speech card becomes the newest turn card', () => {
  const { f, get } = make();
  f.addItems([DEMO[0]]);
  const before = get().cards[0].at;
  f.addItems([{ kind: 'situation', asks: [{ who: 'Dana', what: 'your update', type: 'update' }] }]);
  const sp = get().cards.find((c) => c.id === 'u:speech');
  assert.strictEqual(sp.kind, 'turn');
  assert.ok(sp.at >= before);
});

test('agenda: the engine wins over the brief checklist; cur is now, a manual state sticks', () => {
  const { f, get } = make();
  f.setPrepDoc({ text: '# Brief\n\n**Goal:** agree the plan.\n\n## Checklist\n- [ ] Release date\n- [x] Who tests\n', at: '09:40' });
  assert.deepStrictEqual(get().agenda.map((a) => a.state), ['now', 'done']);
  assert.strictEqual(get().brief.goal, 'agree the plan.');
  f.addItems([{ kind: 'agenda', items: [{ text: 'Release date', done: true }, { text: 'Pilot', cur: true }, 'Accounts'] }]);
  assert.deepStrictEqual(get().agenda.map((a) => a.state), ['done', 'now', 'todo']);
  f.setAgendaState('a2', 'done');
  assert.strictEqual(get().agenda[2].state, 'done');
});

test('status: standby is ready, recording is live, problems become one alert', () => {
  const { f, get } = make();
  f.setStatus({ state: 'standby', title: 'Orbit weekly' });
  assert.strictEqual(get().call.state, 'ready');
  assert.strictEqual(get().call.title, 'Orbit weekly');
  f.setStatus({ state: 'recording', started_at: '2026-10-28T10:00:00+02:00', mic: 'muted', tips_paused: 'on' });
  assert.strictEqual(get().call.state, 'live');
  assert.strictEqual(get().call.micOff, true);
  assert.strictEqual(get().call.paused, true);
  f.setStatus({ state: 'recording', mic: 'stalled' });
  assert.strictEqual(get().call.alert.text, 'Mic stopped');
  f.rename('New name');
  f.setStatus({ state: 'recording', title: 'Old name' });
  assert.strictEqual(get().call.title, 'New name');
});

test('transcript: channels, clusters and unknown voices', () => {
  const { f, get } = make();
  f.addTranscript(['- Channels: Me = microphone, Other = system audio', '[10:31:02] Emily C. [S1] (en): When is the export live?',
                   '[10:31:09] Me (en): Tuesday.', '[10:31:20] Speaker 2 [S2] (en): Who tests?']);
  f.setSpeakers({ clusters: { S1: { name: 'Emily C.', side: 'client' } } });
  const s = get();
  assert.deepStrictEqual(s.transcript.map((l) => l.speakerId), ['S1', 'me', 'S2']);
  assert.strictEqual(s.speakers.S1.name, 'Emily C.');
  assert.strictEqual(s.speakers.S2.name, '');
  assert.strictEqual(s.speakers.me.name, 'Me');
});

test('presentation steps from slides; a skippable step', () => {
  const { f, get } = make();
  f.addItems([{ kind: 'slides', slides: [{ n: 1, title: 'Why', sec: 90, body: [{ k: 'p', t: 'Five users.' }, { k: 's', t: 'Skip if short.' }] }, { n: 2, title: 'Plan', sec: 120, body: [{ k: 'p', t: 'Monday.' }] }] }]);
  f.setStatus({ state: 'recording', call_type: 'presentation' });
  const s = get();
  assert.strictEqual(s.steps.length, 2);
  assert.strictEqual(s.steps[0].canSkip, true);
  assert.strictEqual(s.call.presenting, true);
});

test('prepared cards: the same card twice in 10 minutes is shown once', () => {
  const { f, get } = make();
  f.addItems([{ kind: 'card', card: 'c1', level: 'info', gist: '❓ Pilot size', phrase: '5 users' }]);
  f.addItems([{ kind: 'card', card: 'c1', level: 'info', gist: '❓ Pilot size', phrase: '5 users' }]);
  assert.strictEqual(get().cards.length, 1);
  assert.strictEqual(get().cards[0].kind, 'docs');
});

test('local facts match a typed question', () => {
  const { f } = make();
  f.addItems([{ kind: 'facts', facts: [{ title: 'Pilot', text: '5 users, names by Friday', source: 'kickoff-notes.md' }, 'Budget: 120 hours'] }]);
  const r = f.searchFacts('pilot users');
  assert.strictEqual(r[0].source, 'kickoff-notes.md');
});

test('Up next: the next call with minutes and readiness', () => {
  const { f, get } = make();
  f.setUpNext([{ id: 'n1', title: 'Team retro', prep: 'none', starts_in_min: 7.6 }]);
  assert.deepStrictEqual(get().next, { id: 'n1', title: 'Team retro', startsInMin: 8, prepared: false, preparing: false });
});

test('a commitment said to be done: one quiet On me card, Mark done closes it here', () => {
  const { f, get } = make();
  const it = { kind: 'commitment_done', id: 'c-1a2b3c', text: 'Send the test account list', owner: 'me', t: '10:30:00', gist: 'On me · Done? Send the test account list' };
  f.addItems([it]); f.addItems([it]);
  const cs = get().cards.filter((c) => c.commit);
  assert.strictEqual(cs.length, 1);
  assert.strictEqual(cs[0].quiet, true);
  assert.strictEqual(cs[0].kind, 'onme');
  assert.strictEqual(cs[0].commit.id, 'c-1a2b3c');
  assert.strictEqual(cs[0].say, 'Send the test account list');
  f.commitDone(cs[0].id);
  assert.strictEqual(get().cards.find((c) => c.commit).state, 'done');
  f.addItems([{ kind: 'commitment_done', id: 'c-9', text: 'Share the spec', owner: 'Dana', t: '10:31:00' }]);
  const other = get().cards.find((c) => c.commit && c.commit.id === 'c-9');
  assert.strictEqual(other.commit.mine, false);
  assert.strictEqual(other.who, 'Dana');
});

test('a risk is one quiet card without the label in its text', () => {
  const { f, get } = make();
  const it = { kind: 'risk', level: 'info', t: '10:30:00', who: 'Dana', gist: 'Risk: if the API slips, the pilot moves a week' };
  f.addItems([it]); f.addItems([it]);
  const rs = get().cards.filter((c) => c.kind === 'risk');
  assert.strictEqual(rs.length, 1);
  assert.strictEqual(rs[0].quiet, true);
  assert.strictEqual(rs[0].say, 'if the API slips, the pilot moves a week');
});

// 0.8.5 (rules/presentation.yaml): the recorder writes the time line and the advice once; the window shows the advice
// text verbatim. The cases are the shared fixture the recorder's tests use (rules/fixtures/presentation-advice.json).
const FIX = require(path.join(__dirname, '../../rules/fixtures/presentation-advice.json'));
test('presentation: the advice from the shared fixture is shown verbatim, steps keep who, skip and short', () => {
  for (const c of FIX.cases.filter((x) => x.expect)) {
    for (const lang of ['en', 'uk']) {
      const { f, get } = make();
      f.addItems([{ kind: 'slides', slides: FIX.slides }]);
      const text = c.expect[lang];
      f.addItems([{ kind: 'timeline', t: '10:40:00', at: '10:40:00', text: '12:30 of 25:00 · ' + text, plan: 1500, elapsed: 750, behind: c.behind, slide: c.cur,
                    slide_el: 20, slide_sec: 120, advice: { kind: c.expect.kind, slides: c.expect.slides, text } }]);
      const st = get();
      assert.strictEqual(st.pres.timeline.advice.text, text, `case cur ${c.cur} behind ${c.behind} ${lang}`);
      assert.strictEqual(st.pres.slide, c.cur);
      assert.strictEqual(st.pres.slideRx, NOW - 20000);
    }
  }
  const { f, get } = make();
  f.addItems([{ kind: 'slides', slides: FIX.slides }]);
  const steps = get().steps;
  assert.strictEqual(steps.length, FIX.slides.length);
  const five = steps.find((x) => x.n === 5), six = steps.find((x) => x.n === 6);
  assert.strictEqual(five.who, 'other'); assert.ok(five.speaker);
  assert.strictEqual(six.canSkip, true);
  assert.ok(steps.find((x) => x.n === 3).short);
});

test('presentation: Move to slide N? is kept until answered or the slide moves', () => {
  const { f, get } = make();
  f.addItems([{ kind: 'slides', slides: FIX.slides }, { kind: 'move_ask', n: 3, topic: 'Results', section: 's3' }]);
  assert.deepStrictEqual(get().pres.moveAsk, { n: 3, topic: 'Results', section: 's3' });
  f.addItems([{ kind: 'outline_pos', cur: 's2', slide: 2 }]);
  assert.ok(get().pres.moveAsk === null);
  f.addItems([{ kind: 'move_ask', n: 3, topic: 'Results' }]);
  const a = f.answerMove(true);
  assert.strictEqual(a.n, 3); assert.strictEqual(get().pres.slide, 3); assert.strictEqual(get().pres.moveAsk, null);
  f.addItems([{ kind: 'outline_pos', cur: 's3', slide: 3, follow: 'keynote' }]);
  assert.strictEqual(get().pres.follow, 'keynote');
});

test('presentation: a Presentation call without a deck is still presentable (empty state)', () => {
  const { f, get } = make();
  f.setStatus({ state: 'recording', call_type: 'presentation' });
  assert.strictEqual(get().call.presType, true);
  assert.strictEqual(get().call.presenting, false);
  assert.strictEqual(get().call.presentable, true);
});

test('recording problems: a system state after 30 s, cleared by itself (rules/recording.yaml)', () => {
  const { f, get } = make();
  f.setStatus({ state: 'recording', system_audio: 'ok', mic_silent_s: 2, call_silent_s: 29, mic_level: 0.3, call_level: 0 });
  assert.strictEqual(get().sys, null);
  f.setStatus({ state: 'recording', system_audio: 'silent', mic_silent_s: 2, call_silent_s: 31, mic_level: 0.3, call_level: 0 });
  assert.strictEqual(get().sys.kind, 'cantHear'); assert.strictEqual(get().call.alert, null);
  f.setStatus({ state: 'recording', system_audio: 'silent', mic_silent_s: 40, call_silent_s: 45, mic_level: 0, call_level: 0 });
  assert.strictEqual(get().sys.kind, 'notRecording'); assert.ok(/^\d\d:\d\d$/.test(get().sys.at));
  f.setStatus({ state: 'recording', system_audio: 'ok', mic_silent_s: 0, call_silent_s: 0, mic_level: 0.2, call_level: 0.1 });
  assert.strictEqual(get().sys, null);
});

test('speakers: the voice library suggestions of a speaker_ask are kept for one-click naming', () => {
  const { f, get } = make();
  f.setSpeakers({ clusters: { S4: { name: null, seconds: 19 } }, roster: [{ name: 'Anton S.', side: 'team' }] });
  f.addItems([{ kind: 'speaker_ask', sid: 'S4', quote: 'hello', suggestions: [{ name: 'Anton S.', score: 0.85 }, { name: 'Low', score: 0.3 }], known: ['Anton S.', 'a.sorokin', 'Olena S.'] }]);
  const st = get();
  assert.deepStrictEqual(st.speakers.S4.suggestions, [{ name: 'Anton S.', score: 0.85 }]);
  assert.strictEqual(st.rosterSide['Anton S.'], 'team');
  assert.deepStrictEqual(st.knownNames, ['Anton S.', 'Olena S.']);
});

test('brief: numbered points, paragraphs, wrapped lines and tables are kept (each point keeps its sentences)', () => {
  const { f, get } = make();
  f.setPrepDoc({ text: '# Live Brief: X\n\n**Goal:** agree the plan.\n\n## Previous meetings\n1. Export scope agreed. Emily asked\n   for test accounts.\nA paragraph about risks.\n\n## Table\n| Who | What |\n|---|---|\n| Ann | Deck |\n\n## Checklist\n- [ ] Confirm the date\n', at: '09:40' });
  const b = get().brief;
  assert.strictEqual(b.goal, 'agree the plan.');
  assert.deepStrictEqual(b.sections[0].items, ['Export scope agreed. Emily asked for test accounts.', 'A paragraph about risks.']);
  assert.deepStrictEqual(b.sections[1].items, ['Who · What', 'Ann · Deck']);
  assert.strictEqual(get().agenda[0].title, 'Confirm the date');
});

test('speech: a point keeps its full text; a "> " line under a brief point joins it', () => {
  const { f, get } = make();
  f.addItems([{ kind: 'speech', t: '10:00:00', at: '10:00:00', gist: 'Your speech', phrase: 'Short update.', items: ['Done', { text: '1. Release on Tuesday', full: 'The release goes out on Tuesday after the smoke test.' }] }]);
  const c = get().cards.find((x) => x.kind === 'turn');
  assert.deepStrictEqual(c.items, ['Done', '1. Release on Tuesday']);
  assert.deepStrictEqual(c.fulls, ['', 'The release goes out on Tuesday after the smoke test.']);
  f.setPrepDoc({ text: '## My update\n1. Release on Tuesday\n   > After the smoke test.\n', at: '09:40' });
  assert.deepStrictEqual(get().brief.sections[0].items, ['Release on Tuesday After the smoke test.']);
});

console.log(`feed tests: ${passed} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
