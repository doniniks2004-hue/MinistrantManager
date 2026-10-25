// Runs the page-side probe (the JavaScript in mobile-*/lib/core/offline/panel_probe.dart) in jsdom
// against pages that are drawn, hidden, a sign-in screen, or missing a style. jsdom has no layout, so
// boxes are stubbed: an element is "laid out" unless it carries data-nobox.
//
//   npm install jsdom@24.1.0 && node --test .github/scripts/panel_probe_test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { JSDOM } from 'jsdom';

const here = path.dirname(fileURLToPath(import.meta.url));
const dart = fs.readFileSync(path.join(here, '../../mobile-android/lib/core/offline/panel_probe.dart'), 'utf8');
const template = dart.match(/panelProbeTemplate = r'''\n([\s\S]*?)''';/)[1];

function specId(b64) { return createHash('sha256').update(b64.trim()).digest('hex').slice(0, 12); }
function encode(spec) { return Buffer.from(JSON.stringify(spec)).toString('base64'); }

// The same replacement buildPanelProbe() does.
function probe({ nav = 1, spec = null }) {
  const id = spec ? specId(encode(spec)) : '-';
  return template.replaceAll('__NAV__', String(nav)).replaceAll('__CHANNEL__', 'MM_Paint')
    .replaceAll('__SPEC_ID__', id).replaceAll('__SPEC__', spec ? JSON.stringify(spec) : 'null');
}

const SPEC = {
  path: '/public/dashboard.php',
  required: ['#panel'],
  forbidden: ['input[type=password]'],
  styles: [{ selector: 'body', property: 'background-color', not: 'rgba(0, 0, 0, 0)' }],
};
const GOOD = '<style>body{background-color:rgb(250,250,250)}</style><body><main id="panel"><p>Hello</p></main></body>';

// Runs the probe in a page; resolves with what the page posted, or null if it never did.
async function run(html, { frames = true, spec = SPEC, nav = 1, waitMs = 1800 } = {}) {
  const dom = new JSDOM(`<!doctype html><html><head><title>Panel</title></head>${html}`, {
    runScripts: 'outside-only', pretendToBeVisual: frames, // no frames = a page that is not being drawn
  });
  const w = dom.window;
  w.Element.prototype.getBoundingClientRect = function () {
    return this.hasAttribute('data-nobox') ? { width: 0, height: 0 } : { width: 360, height: 800 };
  };
  const posted = [];
  if (!frames) w.requestAnimationFrame = () => 0; // the browser has the function, but a page that is not drawn never calls back
  w.MM_Paint = { postMessage: (m) => posted.push(JSON.parse(m)) };
  await new Promise((r) => (w.document.readyState === 'complete' ? r() : w.addEventListener('load', r)));
  w.eval(probe({ nav, spec }));
  const t0 = Date.now();
  while (!posted.length && Date.now() - t0 < waitMs) await new Promise((r) => setTimeout(r, 20));
  const result = posted[0] ?? null;
  w.close();
  return { result, count: posted.length };
}

test('a drawn, visible page with the real panel and its styles: via=raf, verdict ok', async () => {
  const { result } = await run(GOOD);
  assert.equal(result.via, 'raf');
  assert.equal(result.verdict, 'ok');
  assert.equal(result.failed, '-');
  assert.equal(result.shown, 'visible');
  assert.equal(result.hidden, 0);
  assert.equal(result.nav, 1);
  assert.equal(result.spec, specId(encode(SPEC)));
});

test('the report names the load it belongs to', async () => {
  assert.equal((await run(GOOD, { nav: 42 })).result.nav, 42);
});

test('a page that gets no frames (hidden / in the background) reports ONLY through the fallback timer: via=timer', async () => {
  const { result } = await run(GOOD, { frames: false });
  assert.equal(result.via, 'timer', 'the app must not take this for a drawn frame');
});

test('it reports once, even though both the frames and the timer are armed', async () => {
  const { count } = await run(GOOD, { waitMs: 2200 });
  assert.equal(count, 1);
});

test('a sign-in screen: the forbidden element is showing, a required one is missing', async () => {
  const { result } = await run('<style>body{background-color:#fff}</style><body><form><input type="password"></form></body>');
  assert.equal(result.verdict, 'fail');
  assert.match(result.failed, /r0/);
  assert.match(result.failed, /f0/);
});

test('a forbidden element that is present but not shown does not fail the page', async () => {
  const { result } = await run(GOOD.replace('</body>', '<input type="password" style="display:none"></body>'));
  assert.equal(result.verdict, 'ok');
});

test('the panel present but display:none is not shown: required fails', async () => {
  const { result } = await run(GOOD.replace('<main id="panel">', '<main id="panel" style="display:none">'));
  assert.equal(result.verdict, 'fail');
  assert.match(result.failed, /r0/);
});

test('the panel inside a hidden parent is not shown', async () => {
  const { result } = await run(GOOD.replace('<main id="panel">', '<div style="visibility:hidden"><main id="panel">').replace('</main>', '</main></div>'));
  assert.equal(result.verdict, 'fail');
});

test('the panel with no layout box (zero size) is not shown', async () => {
  const { result } = await run(GOOD.replace('<main id="panel">', '<main id="panel" data-nobox>'));
  assert.equal(result.verdict, 'fail');
});

test('a page with stylesheets but WITHOUT the required style applied fails the style check, not only the count', async () => {
  const { result } = await run('<style>p{color:red}</style><body><main id="panel">x</main></body>');
  assert.equal(result.verdict, 'fail');
  assert.match(result.failed, /s0/);
  assert.ok(result.sheets >= 1, 'a stylesheet IS there: the count alone would have passed this page');
});

test('equals: the computed value must be exactly that', async () => {
  const spec = { required: ['#panel'], styles: [{ selector: 'body', property: 'background-color', equals: 'rgb(1, 2, 3)' }] };
  assert.equal((await run('<style>body{background-color:rgb(1,2,3)}</style><body><main id="panel">x</main></body>', { spec })).result.verdict, 'ok');
  assert.equal((await run('<style>body{background-color:rgb(9,9,9)}</style><body><main id="panel">x</main></body>', { spec })).result.verdict, 'fail');
});

test('a style check on an element that is not there fails', async () => {
  const spec = { required: ['#panel'], styles: [{ selector: '#nope', property: 'color', not: 'x' }] };
  const { result } = await run(GOOD, { spec });
  assert.equal(result.verdict, 'fail');
  assert.match(result.failed, /s0/);
});

test('titleContains', async () => {
  const spec = { required: ['#panel'], titleContains: 'Panel' };
  assert.equal((await run(GOOD, { spec })).result.verdict, 'ok');
  assert.equal((await run(GOOD, { spec: { ...spec, titleContains: 'Zaloguj' } })).result.verdict, 'fail');
});

test('a selector that is not valid CSS does not throw: the element counts as missing', async () => {
  const { result } = await run(GOOD, { spec: { required: ['#panel', '[[['] } });
  assert.equal(result.verdict, 'fail');
  assert.match(result.failed, /r1/);
});

test('no spec: the page still reports what it measured, with verdict none', async () => {
  const { result } = await run(GOOD, { spec: null });
  assert.equal(result.verdict, 'none');
  assert.equal(result.spec, '-');
  assert.equal(result.via, 'raf');
});

test('the report carries no page text: only the listed fields', async () => {
  const { result } = await run(GOOD);
  assert.deepEqual(Object.keys(result).sort(), ['at', 'failed', 'fcp', 'h', 'hidden', 'img', 'nav', 'ready', 'shown', 'sheets', 'spec', 'verdict', 'via', 'w'].sort());
});
