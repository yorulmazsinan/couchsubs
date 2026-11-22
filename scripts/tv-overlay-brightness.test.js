// SPDX-License-Identifier: AGPL-3.0-only
// TV uygulaması (tv-webos/index.html, Samsung ve Android TV de aynı sayfayı kullanır) PS5 görüntüsünün üstünde kalıcı bir
// karartı bırakıyor mu? "Uygulama açıkken üst kısımda kararma / hafif karartı" bildirimleri (#771, Google Play, X). Sayfa
// gerçek Chromium'da sahte platform, sahte bağlantı ve HDMI yerine bembeyaz bir zeminle açılır; ekran görüntüsünün
// piksel ortalaması ölçülür. Boşta ve altyazı/ekran yazısı/ek alan kalktıktan sonra görüntünün her pikseli beyaz kalmalı.
// node --test scripts/tv-overlay-brightness.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const root = path.join(__dirname, '..', 'tv-webos');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

// Chromium'un ekran görüntüsü: 8 bit RGB/RGBA, taramasız PNG.
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
      assert.equal(body[8], 8, 'PNG bit derinliği');
      type = body[9];
      assert.equal(body[12], 0, 'taramalı PNG');
    } else if (name === 'IDAT') data.push(body);
    at += 12 + length;
  }
  const channels = type === 6 ? 4 : type === 2 ? 3 : 0;
  assert.ok(channels, 'PNG renk türü ' + type);
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

// Bir bölgenin ortalama parlaklığı (0-255) ve beyazdan sapan piksel oranı.
function brightness(image, fromY, toY) {
  let sum = 0, dark = 0, count = 0;
  const { width, channels, pixels } = image;
  for (let y = Math.floor(fromY * image.height); y < Math.floor(toY * image.height); y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * channels;
      const luma = 0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2];
      sum += luma;
      if (luma < 254) dark++;
      count++;
    }
  }
  return { mean: Math.round(sum / count * 100) / 100, dark: Math.round(dark / count * 10000) / 100 };
}

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

const top = (text, left, topY, right, bottom) => ({ text, box: { left, top: topY, right, bottom }, line: 0.03 });
// Sahneler: [ad, ekran görüntüsünün alındığı an (ms), sahnenin olayları].
const SCENES = {
  panel: [2000, ''],
  tip: [12000, ''],
  idle: [40000, ''],
  subtitle: [31000, `setTimeout(function () { __send('subtitle', { text: 'Bu bir deneme altyazısıdır.', duration: 8000 }); }, 30000);`],
  subtitleCleared: [40000, `setTimeout(function () { __send('subtitle', { text: 'Bu bir deneme altyazısıdır.', duration: 8000 }); }, 30000);
    setTimeout(function () { __send('clear', {}); }, 36000);`],
  screenCleared: [40000, `setTimeout(function () { __send('screen', { items: [${JSON.stringify(top('Görevi tamamla', .1, .05, .4, .09))}], duration: 20000 }); }, 30000);
    setTimeout(function () { __send('region', { id: 'q', text: 'Demirciyi bul', box: { left: .7, top: .05, right: .95, bottom: .09 } }); }, 30000);
    setTimeout(function () { __send('screen-clear', {}); __send('region-clear', {}); }, 33000);`],
  screenTop: [31000, `setTimeout(function () { __send('screen', { items: [${JSON.stringify(top('Görevi tamamla', .1, .05, .4, .09))}], duration: 20000 }); }, 30000);`],
};

function shoot(name) {
  const [at, events] = SCENES[name];
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-brightness-test-'));
  try {
    for (const file of fs.readdirSync(root)) {
      if (/\.(js|css|png)$/.test(file) && file !== 'platform.js') fs.copyFileSync(path.join(root, file), path.join(temp, file));
    }
    fs.writeFileSync(path.join(temp, 'platform.js'), PRELUDE);
    let html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
    // HDMI görüntüsü yerine bembeyaz zemin: oyunun en parlak sahnesi.
    html = html.replace('</head>', '<style>#video-host { background: #fff; }</style></head>');
    html = html.replace('<script src="shell.js"></script>', `<script src="shell.js"></script><script>${events}</script>`);
    fs.writeFileSync(path.join(temp, 'index.html'), html);
    const shot = path.join(temp, 'shot.png');
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1080',
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'),
      '--virtual-time-budget=' + at, '--screenshot=' + shot, pathToFileURL(path.join(temp, 'index.html')).href],
    { encoding: 'utf8', timeout: 60000, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const image = decodePng(fs.readFileSync(shot));
    return { top: brightness(image, 0, 0.25), middle: brightness(image, 0.25, 0.75), bottom: brightness(image, 0.75, 1),
      all: brightness(image, 0, 1) };
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

const WHITE = { mean: 255, dark: 0 };

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');
test('Boşta ve yazılar kalktıktan sonra PS5 görüntüsünün üstünde hiçbir karartı kalmaz', { skip: !browser && 'Chrome/Edge bulunamadı' }, (t) => {
  const r = {};
  for (const name of Object.keys(SCENES)) {
    r[name] = shoot(name);
    t.diagnostic(name + ' ' + JSON.stringify(r[name]));
  }
  // Açılışta bilgi paneli 8 sn sol üstte (bilerek), sonra ilk açılışlarda üstte ortada ipucu (15 sn).
  assert.ok(r.panel.top.dark > 5, JSON.stringify(r.panel));
  assert.ok(r.tip.top.dark > 0 && r.tip.top.dark < r.panel.top.dark, JSON.stringify(r.tip));
  // Panel ve ipucu kapandıktan sonra ekranın her pikseli görüntünün kendisi: yarı saydam zemin, gölge, filigran yok.
  assert.deepEqual(r.idle.all, WHITE);
  // Alttaki altyazı yalnız altı karartır; üst ve orta dokunulmaz.
  assert.deepEqual(r.subtitle.top, WHITE);
  assert.deepEqual(r.subtitle.middle, WHITE);
  assert.ok(r.subtitle.bottom.dark > 0, JSON.stringify(r.subtitle));
  // Üstteki ekran yazısı yalnız kendi yerini örter.
  assert.ok(r.screenTop.top.dark > 0 && r.screenTop.top.dark < 10, JSON.stringify(r.screenTop));
  assert.deepEqual(r.screenTop.bottom, WHITE);
  // "Temizle" gelince altyazı, ekran yazısı ve ek alanın zemini tümüyle kalkar.
  assert.deepEqual(r.subtitleCleared.all, WHITE);
  assert.deepEqual(r.screenCleared.all, WHITE);
});
