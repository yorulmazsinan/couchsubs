// SPDX-License-Identifier: AGPL-3.0-only
// Kenar bildirimi (X, iki kişi, GTA 6): "Tam ekran" altyazı alanında sağ altta beliren mesaj önizlemesinin ve solda kayarak
// giren bildirimin çevirisi ekranın ortasına geliyordu. Bilgisayar artık bu kartları altyazı olarak değil, kendi yerlerinde
// okunan "auto-notice-<n>" alanları olarak gönderir (ScreenNotices; Mac, Windows, Android). Bu test TV sayfasında
// (tv-webos/index.html; Samsung ve Android TV de aynı sayfa) ve OBS katmanında (core/.../obs-overlay.html) gerçek Chromium
// ile bakar: oyundaki İngilizce kartların yerinde kırmızı dikdörtgenler durur, kayan kart için aynı alan üç kez (her
// karede yeni yeriyle) gelir. Ekran görüntüsünde tek bir kırmızı piksel kalmamalı (çeviri kartı yerinde örter) ve ekranın
// ortasına hiçbir şey çizilmemeli; yeri geçersiz (sıfır alanlı) blok hiç çizilmemeli.
// node --test scripts/tv-screen-notice.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER; ağ ve uygulama bağlantısı yok.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const tvRoot = path.join(__dirname, '..', 'tv-webos');
const obsPage = path.join(__dirname, '..', 'core', 'Sources', 'CouchSubsCore', 'Resources', 'obs-overlay.html');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

// Karttaki İngilizce yazıların karedeki yeri (Fixtures/screen-notice.json ile aynı): solda bildirim, sağ altta mesaj.
const LEFT = { left: 0.02, top: 0.40, right: 0.28, bottom: 0.43 };
const RIGHT = { left: 0.74, top: 0.86, right: 0.97, bottom: 0.925 };
const surface = { background: '#1e1e1e', foreground: '#ffffff', flat: true };
const look = { bold: false, condensed: false, align: 'left', upper: false };
const block = (text, box, line) => ({ text, box, line, surface, style: look });
const region = (id, text, box, line) => ({
  id, text, line,
  box: { left: Math.max(0, box.left - 0.01), top: Math.max(0, box.top - 0.35 * line),
    right: Math.min(1, box.right + 0.01), bottom: Math.min(1, box.bottom + 0.35 * line) },
  blocks: [block(text, box, line)],
});
const LEFT_TEXT = 'Lucia: Bu gece rıhtımda buluşalım.';
const RIGHT_TEXT = 'Jason: Neredesin?\nKulübün önünde bekliyorum.';
// Soldan kayarak giren kart: aynı alan her karede yeni yeriyle; son yeri LEFT.
const slides = [{ left: 0, top: 0.40, right: 0.12, bottom: 0.43 }, { left: 0, top: 0.40, right: 0.2, bottom: 0.43 }, LEFT];
const EVENTS = [
  ...slides.map(box => region('auto-notice-1', LEFT_TEXT, box, 0.03)),
  region('auto-notice-2', RIGHT_TEXT, RIGHT, 0.03),
  // Yeri geçersiz blok (sıfır alan) ortaya ya da başka bir yere çizilmez.
  { id: 'auto-notice-3', text: 'Geçersiz', box: { left: 0.5, top: 0.5, right: 0.5, bottom: 0.5 },
    blocks: [block('Geçersiz', { left: 0.5, top: 0.5, right: 0.5, bottom: 0.5 }, 0.03)] },
];

function decodePng(buffer) {
  let at = 8, width = 0, height = 0, type = 0;
  const data = [];
  while (at < buffer.length) {
    const length = buffer.readUInt32BE(at);
    const name = buffer.toString('ascii', at + 4, at + 8);
    const body = buffer.subarray(at + 8, at + 8 + length);
    if (name === 'IHDR') {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      type = body[9];
    } else if (name === 'IDAT') data.push(body);
    at += 12 + length;
  }
  const channels = type === 6 ? 4 : 3;
  const raw = zlib.inflateSync(Buffer.concat(data));
  const stride = width * channels;
  const out = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const value = raw[y * (stride + 1) + 1 + x];
      const left = x >= channels ? out[y * stride + x - channels] : 0;
      const up = y ? out[(y - 1) * stride + x] : 0;
      const corner = y && x >= channels ? out[(y - 1) * stride + x - channels] : 0;
      let add = 0;
      if (filter === 1) add = left;
      else if (filter === 2) add = up;
      else if (filter === 3) add = (left + up) >> 1;
      else if (filter === 4) {
        const p = left + up - corner, pa = Math.abs(p - left), pb = Math.abs(p - up), pc = Math.abs(p - corner);
        add = pa <= pb && pa <= pc ? left : pb <= pc ? up : corner;
      }
      out[y * stride + x] = (value + add) & 255;
    }
  }
  return { width, height, channels, pixels: out };
}

// Kırmızı (görünen İngilizce kart) ve ekranın ortasındaki (%30–70) beyaz olmayan (çizilmiş) piksel sayısı.
function measure(image) {
  const { width, height, channels, pixels } = image;
  let red = 0, middle = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * channels;
      if (pixels[i] > 200 && pixels[i + 1] < 40 && pixels[i + 2] < 40) red++;
      const centre = x > width * 0.3 && x < width * 0.7 && y > height * 0.3 && y < height * 0.7;
      if (centre && (pixels[i] < 235 || pixels[i + 1] < 235 || pixels[i + 2] < 235)) middle++;
    }
  }
  return { red, middle };
}

function run(args, temp) {
  const result = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
    '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1080', '--disable-lcd-text',
    ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'), ...args],
  { encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024, windowsHide: true });
  assert.equal(result.status, 0, String(result.error || result.stderr));
  return result.stdout;
}

const rect = (box) => `left:${Math.round(box.left * 1920)}px;top:${Math.round(box.top * 1080)}px;` +
  `width:${Math.round((box.right - box.left) * 1920)}px;height:${Math.round((box.bottom - box.top) * 1080)}px`;
const english = [LEFT, RIGHT].map(box => `<div style="position:absolute;background:#f00;${rect(box)}"></div>`).join('');

// Sahte platform ve bağlantı (tv-cover-pixels.test.js ile aynı): TV'ye ya da ağa çıkılmaz.
const TV_PRELUDE = `
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

// Olaylar bilgi paneli ve ipuçları kapandıktan sonra (30. sn) gelir; ekran görüntüsü 31. sn'de alınır.
function tvShot() {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-notice-tv-'));
  try {
    for (const file of fs.readdirSync(tvRoot)) {
      if (/\.(js|css|png)$/.test(file) && file !== 'platform.js') fs.copyFileSync(path.join(tvRoot, file), path.join(temp, file));
    }
    fs.writeFileSync(path.join(temp, 'platform.js'), TV_PRELUDE);
    const events = EVENTS.map(data => `__send('region', ${JSON.stringify(data)});`).join('\n');
    let html = fs.readFileSync(path.join(tvRoot, 'index.html'), 'utf8');
    html = html.replace('</head>', '<style>#video-host { background: #fff; }</style></head>');
    html = html.replace('<div id="video-host"></div>', `<div id="video-host">${english}</div>`);
    html = html.replace('<script src="shell.js"></script>', `<script src="shell.js"></script><script>setTimeout(function () {
      ${events}
      var pre = document.createElement('pre'); pre.id = 'result';
      // Kesir olarak (görünümün boyuna göre): başsız Chromium'un --dump-dom görünümü 1080'den biraz kısa olabiliyor.
      var w = window.innerWidth, h = window.innerHeight;
      pre.textContent = btoa(JSON.stringify(Array.prototype.map.call(document.querySelectorAll('#regions .item'), function (el) {
        var r = el.getBoundingClientRect(); return [r.left / w, r.top / h, r.right / w, r.bottom / h];
      })));
      document.body.appendChild(pre);
    }, 30000);</script>`);
    fs.writeFileSync(path.join(temp, 'index.html'), html);
    const page = path.join(temp, 'frame.html');
    fs.writeFileSync(page, `<!doctype html><style>html,body{margin:0;overflow:hidden}</style>
      <iframe src="${pathToFileURL(path.join(temp, 'index.html')).href}" style="border:0;width:1920px;height:1080px"></iframe>`);
    const shot = path.join(temp, 'shot.png');
    run(['--virtual-time-budget=31000', '--screenshot=' + shot, pathToFileURL(page).href], temp);
    const dom = run(['--virtual-time-budget=31000', '--dump-dom', pathToFileURL(path.join(temp, 'index.html')).href], temp);
    const match = dom.match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi');
    return { ...measure(decodePng(fs.readFileSync(shot))), items: JSON.parse(Buffer.from(match[1], 'base64').toString('utf8')) };
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

// OBS sayfası saydam bir iframe'de, İngilizce kartların (kırmızı) üstünde; EventSource sahte, olaylar sayfanın içinden.
function obsShot() {
  const stub = `<script>
    window.__listeners = {};
    window.EventSource = function () { this.addEventListener = function (n, f) { window.__listeners[n] = f; }; };
    function fire(name, data) { window.__listeners[name]({ data: JSON.stringify(data) }); }
  </script>`;
  const events = `<script>${EVENTS.map(data => `fire('region', ${JSON.stringify(data)});`).join('\n')}</script>`;
  const html = fs.readFileSync(obsPage, 'utf8').replace('<head>', '<head>' + stub).replace('</body>', events + '</body>');
  const encoded = Buffer.from(html, 'utf8').toString('base64');
  const page = `<!doctype html><style>html,body{margin:0;background:#fff;overflow:hidden}</style>${english}
    <iframe id="frame" style="position:absolute;left:0;top:0;border:0;width:1920px;height:1080px;background:transparent" allowtransparency="true"></iframe>
    <script>
    var frame = document.getElementById('frame');
    frame.contentDocument.open();
    frame.contentDocument.write(decodeURIComponent(escape(atob('${encoded}'))));
    frame.contentDocument.close();
    </script>`;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-notice-obs-'));
  try {
    const file = path.join(temp, 'test.html');
    fs.writeFileSync(file, page);
    const shot = path.join(temp, 'shot.png');
    run(['--virtual-time-budget=2000', '--screenshot=' + shot, pathToFileURL(file).href], temp);
    return measure(decodePng(fs.readFileSync(shot)));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');
const skip = !browser && 'Chrome/Edge bulunamadı';

test('TV: kenar bildirimlerinin çevirisi kartın yerinde; ortaya bir şey çizilmez', { skip }, (t) => {
  const r = tvShot();
  t.diagnostic(JSON.stringify(r));
  assert.equal(r.red, 0, 'İngilizce kart görünüyor: ' + JSON.stringify(r));
  assert.equal(r.middle, 0, 'ekranın ortasına çizildi: ' + JSON.stringify(r));
  // Kayan kartın her karesi aynı alandır: yalnız son yeri çizilir; geçersiz blok çizilmez.
  assert.equal(r.items.length, 2, JSON.stringify(r.items));
  const [left, right] = r.items;
  const near = (a, b) => Math.abs(a - b) <= 0.01;
  assert.ok(near(left[0], LEFT.left) && near(left[1], LEFT.top) && left[2] < 0.5, 'sol kart kendi yerinde: ' + left);
  assert.ok(near(right[0], RIGHT.left) && near(right[1], RIGHT.top) && right[0] > 0.5, 'sağ alttaki kart kendi yerinde: ' + right);
});

test('OBS: kenar bildirimlerinin çevirisi kartın yerinde; ortaya bir şey çizilmez', { skip }, (t) => {
  const r = obsShot();
  t.diagnostic(JSON.stringify(r));
  assert.equal(r.red, 0, 'İngilizce kart görünüyor: ' + JSON.stringify(r));
  assert.equal(r.middle, 0, 'ekranın ortasına çizildi: ' + JSON.stringify(r));
});
