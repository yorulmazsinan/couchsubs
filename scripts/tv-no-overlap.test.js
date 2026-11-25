// SPDX-License-Identifier: AGPL-3.0-only
// TV'de hiçbir iki çeviri kutusu üst üste binmez (X, beta.100, GTA 6 kalabalık sahne: "çeviriler üst üste", "görevlerin
// yarısı üst üste"; tv-webos/app.js avoidRegions). Sayfa (tv-webos/index.html; Samsung ve Android TV de aynı sayfa) gerçek
// Chromium'da sahte platform ve bağlantıyla açılır. Her yerleşimde (Örtsün, Üstünde, Altında, Sabit) ve 720p/1080p/4K'da:
// görev kutusu (kehribar, altyazının hemen üstünde), menü yanına yazma kutusu ve ikiz kutu altyazıya bitişik dururken
// aynı anda konuşan 2–3 kişinin replikleri art arda gelir (önceki satırlar yığılır) ve birleşik çok konuşanlı satır gelir.
// Altyazı yığını (son satır, önceki iki satır), örtü, görev kutusu ve ekran yazısı kutuları ölçülür: farklı kutuların hiçbiri
// kesişmez, hepsi ekranın içindedir; önceki satırlar kalkınca görev kutusu yerine yaklaşır.
// node --test scripts/tv-no-overlap.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
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

// Sahte platform ve bağlantı: TV'ye ya da ağa çıkılmaz. Olaylar sanal zamanda gelir (--virtual-time-budget).
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

// Görünen bütün çeviri kutuları: [grup, sol, üst, sağ, alt]. Altyazı yığını tek grup ('sub'), örtü ayrı ('cover').
const MEASURE = `
function __rect(group, el) {
  if (!el) return null;
  for (var node = el; node && node.nodeType === 1; node = node.parentNode) {
    var cs = getComputedStyle(node);
    if (cs.display === 'none' || cs.visibility === 'hidden') return null;
  }
  var r = el.getBoundingClientRect();
  if (!(r.width > 0) || !(r.height > 0)) return null;
  return [group, Math.round(r.left), Math.round(r.top), Math.round(r.right), Math.round(r.bottom), (el.textContent || '').slice(0, 24)];
}
function __measure() {
  var out = [];
  ['subtitle-text', 'subtitle-prev-text', 'subtitle-prev2-text'].forEach(function (id) {
    var r = __rect('sub', document.getElementById(id)); if (r) out.push(r);
  });
  var cover = __rect('cover', document.getElementById('subtitle-cover')); if (cover) out.push(cover);
  var regions = document.getElementById('regions').children;
  for (var i = 0; i < regions.length; i++) {
    var host = regions[i];
    var list = host.className.indexOf('region-blocks') >= 0 ? host.children : [host];
    for (var j = 0; j < list.length; j++) { var r = __rect('region' + i, list[j]); if (r) out.push(r); }
  }
  return { boxes: out, width: document.documentElement.clientWidth, height: document.documentElement.clientHeight,
    prev: getComputedStyle(document.getElementById('subtitle-prev')).display !== 'none',
    prev2: getComputedStyle(document.getElementById('subtitle-prev2')).display !== 'none' };
}
`;

const mission = {
  id: 'auto-mission', text: '► Pazara git ve satıcıyla konuş', box: { left: 0.38, top: 0.735, right: 0.62, bottom: 0.775 }, line: 0.03,
  blocks: [{ text: '► Pazara git ve satıcıyla konuş', box: { left: 0.4, top: 0.74, right: 0.6, bottom: 0.77 }, line: 0.03, mission: true,
    surface: { background: '#7A4E00', foreground: '#FFFFFF', flat: true },
    style: { align: 'center', bold: false, condensed: false, upper: false } }],
};
// Menü yanına yazma (özgün etiketin solunda) ve ikiz kutu: ikisi de altyazı bölgesine taşar.
const beside = {
  id: 'auto-menu', text: 'KONUŞ', box: { left: 0.52, top: 0.83, right: 0.6, bottom: 0.87 }, line: 0.035,
  blocks: [{ text: 'KONUŞ', box: { left: 0.52, top: 0.83, right: 0.6, bottom: 0.87 }, line: 0.035, lineH: 0.035,
    cover: { left: 0.52, top: 0.83, right: 0.6, bottom: 0.87 }, fg: '#FFFFFF', bg: '#202020', weight: 700, upper: true, align: 'center',
    mode: 'beside', spot: { left: 0.42, top: 0.83, right: 0.5, bottom: 0.87 }, spotRoom: { left: 0.3, top: 0.83, right: 0.5, bottom: 0.87 },
    surface: { background: '#202020', foreground: '#FFFFFF', flat: false },
    style: { align: 'center', bold: true, condensed: true, upper: true } }],
};
const twin = {
  id: 'auto-note', text: 'Yeni mesaj', box: { left: 0.62, top: 0.86, right: 0.74, bottom: 0.9 }, line: 0.03,
  blocks: [{ text: 'Yeni mesaj', box: { left: 0.62, top: 0.86, right: 0.74, bottom: 0.9 }, line: 0.03, lineH: 0.03,
    cover: { left: 0.62, top: 0.86, right: 0.74, bottom: 0.9 }, bg: '#E2EBD2', fg: '#202020', weight: 400, upper: false, align: 'left',
    mode: 'twin', scale: 1, radius: 0.015, twinBox: { left: 0.45, top: 0.86, right: 0.6, bottom: 0.9 },
    spot: { left: 0.46, top: 0.865, right: 0.59, bottom: 0.895 }, spotRoom: { left: 0.46, top: 0.865, right: 0.59, bottom: 0.895 },
    surface: { background: '#E2EBD2', foreground: '#202020', flat: true }, style: { align: 'left', bold: false, condensed: false, upper: false } }],
};
// Aynı anda konuşan üç kişi: replikler art arda (yeri az farklı), sonra birleşik çok konuşanlı satır.
const speakers = [{ name: 'Satıcı', color: '#FFB040' }, { name: 'Şoför', color: '#40C0FF' }, { name: 'Çocuk', color: '#A0FF60' }];
const lines = [
  { text: 'Satıcı: Bugün her zamankinden mi istersin?', box: { left: 0.33, top: 0.79, right: 0.67, bottom: 0.83 } },
  { text: 'Şoför: Çek şu arabayı yoldan, adamım!', box: { left: 0.35, top: 0.84, right: 0.65, bottom: 0.88 } },
  { text: 'Çocuk: Şuradaki arabaya bak!', box: { left: 0.38, top: 0.89, right: 0.62, bottom: 0.93 } },
];
const joined = { text: 'Satıcı: Bugün her zamankinden mi istersin?\nŞoför: Çek şu arabayı yoldan, adamım!\nÇocuk: Şuradaki arabaya bak!',
  box: { left: 0.33, top: 0.79, right: 0.67, bottom: 0.93 } };

function scene(placement, withRegions) {
  const send = (at, name, data) => `setTimeout(function () { __send('${name}', ${JSON.stringify(data)}); }, ${at});`;
  return [
    send(2000, 'style', { placement, background: 80 }),
    withRegions ? send(2400, 'region', beside) : '',
    withRegions ? send(2450, 'region', twin) : '',
    withRegions ? send(2500, 'region', mission) : '',
    ...lines.map((line, i) => send(3000 + i * 200, 'subtitle', Object.assign({ duration: 6000, speakerNames: speakers }, line))),
    `setTimeout(function () { window.__stack = __measure(); }, 3500);`,
    send(3600, 'subtitle', Object.assign({ duration: 6000, speakerNames: speakers, replace: true }, joined)),
    `setTimeout(function () { window.__joined = __measure(); }, 3700);`,
    // Önceki satırlar solup kalkar (1,5 sn + 0,4 sn); son satır durur.
    `setTimeout(function () { window.__later = __measure(); }, 6000);`,
    `setTimeout(function () { document.getElementById('__result').textContent =
      JSON.stringify({ stack: window.__stack, joined: window.__joined, later: window.__later }); }, 6100);`,
  ].join('\n');
}

function render(placement, width, height, withRegions = true) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-no-overlap-test-'));
  try {
    for (const file of fs.readdirSync(root)) {
      if (/\.(js|css|png)$/.test(file) && file !== 'platform.js') fs.copyFileSync(path.join(root, file), path.join(temp, file));
    }
    fs.writeFileSync(path.join(temp, 'platform.js'), PRELUDE);
    let html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
    html = html.replace('<script src="app.js"></script>',
      `<script src="app.js"></script><pre id="__result"></pre><script>${MEASURE}${scene(placement, withRegions)}</script>`);
    fs.writeFileSync(path.join(temp, 'index.html'), html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', `--window-size=${width},${height}`,
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'),
      '--virtual-time-budget=6500', '--dump-dom', pathToFileURL(path.join(temp, 'index.html')).href],
    { encoding: 'utf8', timeout: 60000, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="__result">([^<]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi');
    return JSON.parse(match[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&#39;/g, "'"));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

function meets(a, b) {
  return Math.min(a[3], b[3]) - Math.max(a[1], b[1]) > 1 && Math.min(a[4], b[4]) - Math.max(a[2], b[2]) > 1;
}

// Farklı grupların kutuları kesişmez; altyazı yığınının satırları birbirine binmez; örtü yalnız altyazının altındadır.
function assertApart(m, label) {
  const boxes = m.boxes;
  for (let i = 0; i < boxes.length; i++) {
    const a = boxes[i];
    assert.ok(a[2] >= -1 && a[4] <= m.height + 1, `${label}: ekran dışında ${JSON.stringify(a)} (${m.height})`);
    for (let j = i + 1; j < boxes.length; j++) {
      const b = boxes[j];
      if (a[0] === b[0] && a[0] !== 'sub') continue;
      if ((a[0] === 'cover' && b[0] === 'sub') || (a[0] === 'sub' && b[0] === 'cover')) continue;
      assert.ok(!meets(a, b), `${label}: üst üste ${JSON.stringify(a)} ${JSON.stringify(b)}`);
    }
  }
}

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');

for (const placement of ['cover', 'above', 'below', 'fixed']) {
  test(`hiçbir iki çeviri kutusu üst üste binmez: ${placement}, 1080p`, { skip: !browser && 'Chrome/Edge bulunamadı' }, (t) => {
    const r = render(placement, 1920, 1080);
    t.diagnostic(JSON.stringify(r));
    // Üç kişinin replikleri art arda geldi: önceki iki satır yığında.
    assert.ok(r.stack.prev && r.stack.prev2, 'önceki satırlar yığılmadı');
    assert.equal(r.stack.boxes.filter(b => b[0] === 'sub').length, 3);
    assert.ok(r.stack.boxes.some(b => b[0] !== 'sub' && b[0] !== 'cover' && b[5].indexOf('Pazara') >= 0), 'görev kutusu görünmüyor');
    assertApart(r.stack, placement + ' yığın');
    assertApart(r.joined, placement + ' birleşik');
    assertApart(r.later, placement + ' sonra');
    // Önceki satırlar kalkınca görev kutusu daha yukarıda durmaz (yerine yaklaşır ya da yerinde kalır).
    const missionTop = m => m.boxes.find(b => b[5].indexOf('Pazara') >= 0)[2];
    assert.ok(!r.later.prev && !r.later.prev2, 'önceki satırlar kalkmadı');
    assert.ok(Math.abs(missionTop(r.later) - 0.74 * 1080) <= Math.abs(missionTop(r.stack) - 0.74 * 1080) + 1,
      `görev kutusu geri dönmedi: ${missionTop(r.stack)} → ${missionTop(r.later)}`);
  });
}

for (const [width, height] of [[1280, 720], [3840, 2160]]) {
  test(`hiçbir iki çeviri kutusu üst üste binmez: Örtsün ve Üstünde, ${width}×${height}`, { skip: !browser && 'Chrome/Edge bulunamadı' }, () => {
    for (const placement of ['cover', 'above']) {
      const r = render(placement, width, height);
      assertApart(r.stack, `${placement} ${width} yığın`);
      assertApart(r.joined, `${placement} ${width} birleşik`);
      assertApart(r.later, `${placement} ${width} sonra`);
    }
  });
}

test('birleşik çok konuşanlı satır: her konuşan kendi satırında, adı kendi renginde', { skip: !browser && 'Chrome/Edge bulunamadı' }, () => {
  const r = render('fixed', 1920, 1080, false);
  const sub = r.joined.boxes.filter(b => b[0] === 'sub');
  assert.equal(sub.length, 1, JSON.stringify(r.joined));
  // Üç satır yüksekliğinde (her konuşan ayrı satır): satır yüksekliği yazı boyunun ~1,2 katı, en az 46 px.
  assert.ok(sub[0][4] - sub[0][2] >= 3 * 46, JSON.stringify(sub));
});
