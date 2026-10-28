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

console.log(`feed tests: ${passed} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
