// Pacenote 0.26.3: tests of the tips window in a real browser engine (app/Resources/tips: index.html + tips.js).
// feed.test.js covers the feed adapter; this file covers the window itself: what the PM clicks and sees.
// Run: node app/WebTests/tips-window.test.js   (Node 22+, no packages; needs Google Chrome or Chromium)
//   CHROME=<path to the browser>   another browser binary
//   TIPS_DIR=<folder>              test another copy of app/Resources/tips (the gate uses it to prove a test catches a bug)
//   PACENOTE_STRICT_WEB=1          a missing browser is a failure, not a skip (the gate sets it on the Mac)
// The page runs on its built-in demo data (opened outside the app). Native messages are caught by a stand-in for
// window.webkit.messageHandlers.liveTips, so the test sees what the window would send to Swift.
'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const TIPS = process.env.TIPS_DIR || path.join(__dirname, '../Resources/tips');
const STRICT = process.env.PACENOTE_STRICT_WEB === '1';
const CANDIDATES = [process.env.CHROME, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium', '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'];
const CHROME = CANDIDATES.find((p) => p && fs.existsSync(p));

let failures = 0, passed = 0;
async function test(name, fn) { try { await fn(); passed++; } catch (e) { failures++; console.log('FAIL', name, '\n ', e.message); } }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function launch() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-tips-'));
  const p = spawn(CHROME, ['--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + dir, '--no-first-run',
    '--no-default-browser-check', '--disable-gpu', '--allow-file-access-from-files', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
  return new Promise((resolve, reject) => {
    let err = '';
    const t = setTimeout(() => reject(new Error('browser did not start: ' + err.slice(-300))), 20000);
    p.stderr.on('data', (d) => {
      err += d;
      const m = err.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (m) { clearTimeout(t); resolve({ proc: p, port: new URL(m[1]).port, dir }); }
    });
  });
}

async function connect(port) {
  const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = list.find((x) => x.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  let id = 0; const wait = new Map(); const events = [];
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } else if (d.method) events.push(d);
  };
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const evaluate = async (expr) => {
    const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.result.exceptionDetails) throw new Error('page: ' + r.result.exceptionDetails.text + ' ' + JSON.stringify(r.result.exceptionDetails.exception || ''));
    return r.result.result.value;
  };
  return { ws, send, evaluate, events };
}

// What a check needs from the page, read in one call.
const SNAPSHOT = `(() => {
  const $ = (id) => document.getElementById(id);
  const pane = $('pane');
  return {
    askForm: !!$('ask') && $('ask').tagName === 'FORM',
    askInput: !!$('askInput'), askLbl: !!$('askLbl') && $('askLbl').textContent.trim().length > 0,
    paneTabs: pane ? pane.querySelectorAll('.tabs .tab').length : 0,
    paneBody: pane && pane.querySelector('.panebody') ? pane.querySelector('.panebody').textContent.trim().length : 0,
    paneClose: !!(pane && pane.querySelector('[data-act="pane-close"]')),
    selectedTab: (pane && pane.querySelector('.tab[aria-selected="true"]') || {}).dataset ? pane.querySelector('.tab[aria-selected="true"]').dataset.tab : null,
    paneOff: $('app').classList.contains('pane-off'),
    wide: $('app').clientWidth,
    posts: (window.__posts || []).map((m) => ({ action: m.action, on: m.on, where: m.where, msg: m.msg }))
  };
})()`;
const CATCH = `window.__posts = []; window.webkit = { messageHandlers: { liveTips: { postMessage: (m) => window.__posts.push(m) } } }; true`;

async function open(b, width) {
  await b.send('Emulation.setDeviceMetricsOverride', { width, height: 820, deviceScaleFactor: 1, mobile: false });
  await b.send('Page.navigate', { url: 'file://' + path.resolve(TIPS, 'index.html') });
  for (let i = 0; i < 50; i++) { await sleep(100); if (await b.evaluate('document.readyState') === 'complete') break; }
  await sleep(400);
  await b.evaluate(CATCH);             // after the demo data is in: the page keeps running as "in a browser"
}
const jsErrors = (b, s) => s.posts.filter((m) => m.action === 'jserror').map((m) => m.where + ': ' + m.msg)
  .concat(b.events.filter((e) => e.method === 'Runtime.exceptionThrown').map((e) => e.params.exceptionDetails.text))
  .concat(b.events.filter((e) => e.method === 'Runtime.consoleAPICalled' && JSON.stringify(e.params.args).includes('jserror'))
    .map((e) => JSON.stringify(e.params.args).slice(0, 200)));

(async () => {
  if (!CHROME) {
    console.log('tips window tests: no Chrome found' + (STRICT ? '' : ' (skipped)'));
    process.exit(STRICT ? 1 : 0);
  }
  const br = await launch();
  const b = await connect(br.port);
  await b.send('Page.enable'); await b.send('Runtime.enable');
  try {
    // Regression 20.11 (0.26.0-0.26.2): the inline question strip took the id of the question form, so the form was
    // emptied, render stopped on askLbl, and the side panel (Transcript, On me, Brief) stayed empty.
    await open(b, 1100);
    const s0 = await b.evaluate(SNAPSHOT);
    await test('wide window: the question form at the bottom is intact', () => {
      assert.ok(s0.askForm, 'form#ask exists'); assert.ok(s0.askInput, 'the question field exists'); assert.ok(s0.askLbl, 'the field has its label');
    });
    await test('wide window: the side panel has tabs, content and a Close button', () => {
      assert.ok(s0.paneTabs >= 2, 'tabs: ' + s0.paneTabs); assert.ok(s0.paneBody > 0, 'panel body is not empty'); assert.ok(s0.paneClose, 'Close button');
    });
    await test('wide window: no script errors after the first render', () => {
      assert.deepStrictEqual(jsErrors(b, s0), []);
    });
    await test('wide window: On me opens the On me tab, Close hides the panel', async () => {
      await b.evaluate(`document.getElementById('onmeBtn').click(); true`); await sleep(150);
      const s1 = await b.evaluate(SNAPSHOT);
      assert.strictEqual(s1.selectedTab, 'onme');
      await b.evaluate(`document.querySelector('#pane [data-act="pane-close"]').click(); true`); await sleep(150);
      const s2 = await b.evaluate(SNAPSHOT);
      assert.ok(s2.paneOff, 'panel hidden after Close');
      await b.evaluate(`document.getElementById('onmeBtn').click(); true`); await sleep(150);
      assert.ok(!(await b.evaluate(SNAPSHOT)).paneOff, 'On me shows the panel again');
    });

    // Narrow window: the panel asks the native side to widen the window, and to give the width back on Close.
    await open(b, 600);
    await test('narrow window: On me asks to widen the window, a second click gives the width back', async () => {
      await b.evaluate(`document.getElementById('onmeBtn').click(); true`); await sleep(150);
      const s1 = await b.evaluate(SNAPSHOT);
      assert.deepStrictEqual(s1.posts.filter((m) => m.action === 'transcript').map((m) => m.on), [true]);
      await b.evaluate(`document.getElementById('onmeBtn').click(); true`); await sleep(150);
      const s2 = await b.evaluate(SNAPSHOT);
      assert.deepStrictEqual(s2.posts.filter((m) => m.action === 'transcript').map((m) => m.on), [true, false]);
      assert.deepStrictEqual(jsErrors(b, s2), []);
    });
  } finally {
    try { b.ws.close(); } catch (e) {}
    br.proc.kill('SIGKILL');
  }
  console.log(`tips window tests: ${passed} passed, ${failures} failed`);
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.log('tips window tests: crashed:', e.message); process.exit(1); });
