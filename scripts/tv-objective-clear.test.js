// SPDX-License-Identifier: AGPL-3.0-only
// TV'de altyazı kutusu oyundaki görev satırını örtmez (X, beta.100–104, GTA 6: "Get in the speedboat", "Order Lucia a drink
// from a bartender" altyazı kutusunun altında yarım görünüyordu; tv-webos/app.js clearObjective). Kutular gerçek karenin
// (testdata/frames/gta6-854-gorev-3.jpg) okumasından: konuşma satırı ve hemen altındaki görev satırı. Sayfa gerçek Chromium'da
// sahte platform ve bağlantıyla açılır; her yerleşimde (Örtsün, Üstünde, Altında, Sabit) iki satıra bölünen Türkçe gelir.
// Görev satırının yeri gelince (altyazıda "keep" ya da sonradan "objective" olayı) altyazı ve örtüsü görev satırının ve
// yerindeki görev kutusunun üstünde kalır; örtü İngilizce satırı yine kaplar. Yer gelmezse (eski bilgisayar) eskisi gibi.
// node --test scripts/tv-objective-clear.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const root = path.join(__dirname, '..', 'tv-webos');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

const PRELUDE = `
window.COUCHSUBS_PLATFORM = {
  backKey: 461, init: function () {}, onRelaunch: function () {}, exit: function () {},
  launchParams: function () { return { server: 'http://192.0.2.1:47123' }; },
  showHdmi: function (port, host, onStatus) { onStatus('playing'); },
  findConsolePort: function (callback) { callback(1, 'PS5'); },
  localAddress: function (callback) { callback(null); }
};
window.XMLHttpRequest = function () { this.status = 0; this.responseText = ''; };
XMLHttpRequest.prototype.open = function () {};
XMLHttpRequest.prototype.send = function () {
  var xhr = this;
  setTimeout(function () {
    xhr.status = 200;
    xhr.responseText = JSON.stringify({ app: 'couchsubs', auth: 0, id: 'test' });
    if (xhr.onload) xhr.onload();
  }, 10);
};
window.EventSource = function () {
  var es = this;
  this.readyState = 1;
  this.listeners = {};
  window.__stream = this;
  setTimeout(function () { if (es.onopen) es.onopen(); }, 10);
};
EventSource.prototype.addEventListener = function (name, fn) { (this.listeners[name] = this.listeners[name] || []).push(fn); };
EventSource.prototype.close = function () { this.readyState = 2; };
window.__send = function (name, data) {
  var list = (window.__stream && window.__stream.listeners[name]) || [];
  for (var i = 0; i < list.length; i++) list[i]({ data: JSON.stringify(data) });
};
`;

const MEASURE = `
function __rect(el) {
  if (!el) return null;
  for (var node = el; node && node.nodeType === 1; node = node.parentNode) {
    var cs = getComputedStyle(node);
    if (cs.display === 'none' || cs.visibility === 'hidden') return null;
  }
  var r = el.getBoundingClientRect();
  if (!(r.width > 0) || !(r.height > 0)) return null;
  return [Math.round(r.left), Math.round(r.top), Math.round(r.right), Math.round(r.bottom)];
}
function __measure() {
  var mission = document.querySelector('#regions .region-blocks > *') || null;
  return { text: __rect(document.getElementById('subtitle-text')), cover: __rect(document.getElementById('subtitle-cover')),
    mission: __rect(mission), height: document.documentElement.clientHeight };
}
`;

// gta6-854-gorev-3: konuşma satırının ve görev satırının karedeki yeri (okuma kutuları, alan oranından kareye).
const english = { left: 0.2975, top: 0.8395, right: 0.8209, bottom: 0.9334 };
const objective = { left: 0.4749, top: 0.9422, right: 0.6371, bottom: 0.9682 };
const line = { duration: 6000, box: english,
  text: 'Biri özgür kalmaya çok sevinmiş, değil mi? Hadi bakalım, sürat teknesine binelim artık.' };
const mission = {
  id: 'auto-mission', text: '► Sürat teknesine bin', box: { left: 0.46, top: 0.933, right: 0.65, bottom: 0.977 }, line: 0.026,
  blocks: [{ text: '► Sürat teknesine bin', box: objective, line: 0.026, mission: true,
    surface: { background: '#7A4E00', foreground: '#FFFFFF', flat: true },
    style: { align: 'center', bold: false, condensed: false, upper: false } }],
};

// how: 'keep' altyazıyla birlikte, 'event' altyazıdan sonra objective olayı, 'none' yer yok (eski bilgisayar).
function scene(placement, how, withMission) {
  const send = (at, name, data) => `setTimeout(function () { __send('${name}', ${JSON.stringify(data)}); }, ${at});`;
  const subtitle = how === 'keep' ? Object.assign({ keep: objective }, line) : line;
  return [
    send(2000, 'style', { placement, background: 80 }),
    withMission ? send(2400, 'region', mission) : '',
    send(3000, 'subtitle', subtitle),
    how === 'event' ? send(3200, 'objective', { box: objective }) : '',
    `setTimeout(function () { window.__shown = __measure(); }, 3400);`,
    how === 'event' ? send(3500, 'objective', {}) : '',
    `setTimeout(function () { window.__gone = __measure(); }, 3700);`,
    `setTimeout(function () { document.getElementById('__result').textContent =
      JSON.stringify({ shown: window.__shown, gone: window.__gone }); }, 3800);`,
  ].join('\n');
}

function render(placement, how, width = 1920, height = 1080, withMission = false) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-objective-test-'));
  try {
    for (const file of fs.readdirSync(root)) {
      if (/\.(js|css|png)$/.test(file) && file !== 'platform.js') fs.copyFileSync(path.join(root, file), path.join(temp, file));
    }
    fs.writeFileSync(path.join(temp, 'platform.js'), PRELUDE);
    let html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
    html = html.replace('<script src="app.js"></script>',
      `<script src="app.js"></script><pre id="__result"></pre><script>${MEASURE}${scene(placement, how, withMission)}</script>`);
    fs.writeFileSync(path.join(temp, 'index.html'), html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', `--window-size=${width},${height}`,
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'),
      '--virtual-time-budget=4200', '--dump-dom', pathToFileURL(path.join(temp, 'index.html')).href],
    { encoding: 'utf8', timeout: 60000, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="__result">([^<]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi');
    return JSON.parse(match[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&#39;/g, "'"));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

// Altyazının (ve örtüsünün) en alt kenarı.
const bottomOf = m => Math.max(m.text[3], m.cover ? m.cover[3] : -Infinity);

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');

for (const placement of ['cover', 'above', 'below', 'fixed']) {
  test(`altyazı görev satırını örtmez: ${placement}`, { skip: !browser && 'Chrome/Edge bulunamadı' }, (t) => {
    for (const how of ['keep', 'event']) {
      const r = render(placement, how);
      t.diagnostic(`${how} ${JSON.stringify(r)}`);
      const top = objective.top * r.shown.height;
      assert.ok(bottomOf(r.shown) <= top, `${placement}/${how}: altyazı görev satırına iniyor (${bottomOf(r.shown)} > ${top})`);
      assert.ok(r.shown.text[1] >= 0, `${placement}/${how}: ekranın dışına çıktı`);
      if (placement === 'cover') {
        // Örtü İngilizce satırın üst kenarını yine kaplar.
        assert.ok(r.shown.cover && r.shown.cover[1] <= english.top * r.shown.height + 1, `${placement}/${how}: örtü İngilizceyi açıkta bıraktı`);
      }
    }
  });
}

test('görev satırının yeri gelmezse (eski bilgisayar) yerleşim değişmez; yer kalkınca altyazı yerine döner',
  { skip: !browser && 'Chrome/Edge bulunamadı' }, () => {
    const old = render('cover', 'none');
    // Düzeltmeden önceki durum: iki satırlık Türkçe İngilizce satırın ortasına göre büyüyüp görev satırına iniyordu.
    assert.ok(bottomOf(old.shown) > objective.top * old.shown.height, `beklenen eski örtüşme yok: ${JSON.stringify(old.shown)}`);
    const moved = render('cover', 'event');
    assert.deepEqual(moved.gone.text, old.shown.text);
  });

test('yerindeki görev kutusu kaymaz, altyazı onun da üstünde kalır (720p, 1080p, 4K)', { skip: !browser && 'Chrome/Edge bulunamadı' }, () => {
  for (const [width, height] of [[1280, 720], [1920, 1080], [3840, 2160]]) {
    const r = render('cover', 'keep', width, height, true);
    assert.ok(r.shown.mission, `${width}: görev kutusu görünmüyor ${JSON.stringify(r.shown)}`);
    assert.ok(bottomOf(r.shown) <= r.shown.mission[1], `${width}: altyazı görev kutusuna iniyor ${JSON.stringify(r.shown)}`);
    // Görev kutusu kendi yerinde (görev satırının üstünde) durur, altyazıdan kaçıp kaymaz.
    assert.ok(Math.abs(r.shown.mission[3] - objective.bottom * r.shown.height) <= 0.03 * r.shown.height, `${width}: görev kutusu kaydı ${JSON.stringify(r.shown)}`);
  }
});

test('görev satırı altyazının üstündeyse altyazı kaymaz', { skip: !browser && 'Chrome/Edge bulunamadı' }, () => {
  const above = render('cover', 'none');
  const r = render('cover', 'keep');
  assert.ok(r.shown.text[3] < above.shown.text[3], 'altyazı görev satırının altındayken kaymalı');
});
