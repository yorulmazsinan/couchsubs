// SPDX-License-Identifier: AGPL-3.0-only
// "Örtsün": Türkçe kutu oyundaki İngilizce altyazıyı her zaman tamamen örter mi, yazı boyu sabit kalıyor mu? X'te bildirildi:
// kısa çeviride kutu İngilizce altyazıdan dar kalıyor, kenarlarda "You s" ve "s car?" görünüyordu. TV sayfası
// (tv-webos/index.html; Samsung ve Android TV de aynı sayfayı kullanır) ve OBS katmanı (core/.../obs-overlay.html) gerçek
// Chromium'da açılır; oyun görüntüsü yerine beyaz zemin, İngilizce altyazının yerinde (iki satırlık kutu) kırmızı bir dikdörtgen
// durur. Ekran görüntüsünde tek bir kırmızı piksel kalmamalı. Yazı boyu hep seçilen boyda kalmalı: sığmayan satır küçülmez, daha çok
// satıra bölünür (X, beta.89: "Örtsün" + "Yazı kadar"da boy satırdan satıra değişiyordu).
// node --test scripts/tv-cover-pixels.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER; ağ ve uygulama bağlantısı yok.
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

// İki satırlık İngilizce altyazı ("You stole it? / Your mom's car?") ekranın ortasında, altta.
const ENGLISH = { left: 0.3, top: 0.8, right: 0.7, bottom: 0.9 };
const SHORT = 'Çaldın mı?';
const MEDIUM = 'Çaldın mı? Annenin arabası demiştin hani?';
const LONG = 'Annenin arabası demiştin hani, unuttun mu yoksa bu kadar çabuk? Ben her şeyi hatırlıyorum: gece yarısı ' +
  'garajdan çıkardık, farları kapalı sürdük, köşedeki benzinciye kadar kimse fark etmedi. Şimdi de bana bilmiyorum mu ' +
  'diyorsun? Polis kapıya gelince ne diyeceğiz, onu söyle bana hemen şimdi.';

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

// Görünen kırmızı (İngilizce altyazı) piksel sayısı.
function redPixels(image) {
  let red = 0;
  const { width, height, channels, pixels } = image;
  for (let i = 0; i < width * height * channels; i += channels) {
    if (pixels[i] > 200 && pixels[i + 1] < 40 && pixels[i + 2] < 40) red++;
  }
  return red;
}

function run(args, temp) {
  const result = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
    // LCD (alt piksel) yazı yumuşatması Linux'ta beyaz harflerin kenarına kırmızı saçak koyar; İngilizce altyazı sanılmasın.
    '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1080', '--disable-lcd-text',
    ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'), ...args],
  { encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024, windowsHide: true });
  assert.equal(result.status, 0, String(result.error || result.stderr));
  return result.stdout;
}

function result(stdout) {
  const match = stdout.match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
  assert.ok(match, 'Tarayıcı ölçüm üretmedi: ' + stdout.slice(-800));
  return JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
}

// --- TV sayfası ---

// Sahte platform ve bağlantı (tv-overlay-brightness.test.js ile aynı): TV'ye ya da ağa çıkılmaz.
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

function tvStyle(placement, fontSize, background) {
  return { fontSize: fontSize || 46, placement, background: background === undefined ? 100 : background, backgroundShape: 'box',
    stackPrevious: false };
}

// Olaylar bilgi paneli ve ipuçları kapandıktan sonra (30. sn) gelir; ekran görüntüsü 31. sn'de alınır.
function tvPage(temp, events) {
  for (const file of fs.readdirSync(tvRoot)) {
    if (/\.(js|css|png)$/.test(file) && file !== 'platform.js') fs.copyFileSync(path.join(tvRoot, file), path.join(temp, file));
  }
  fs.writeFileSync(path.join(temp, 'platform.js'), TV_PRELUDE);
  let html = fs.readFileSync(path.join(tvRoot, 'index.html'), 'utf8');
  const english = `left:${ENGLISH.left * 100}%;top:${ENGLISH.top * 100}%;width:${(ENGLISH.right - ENGLISH.left) * 100}%;` +
    `height:${(ENGLISH.bottom - ENGLISH.top) * 100}%`;
  html = html.replace('</head>', '<style>#video-host { background: #fff; }</style></head>');
  html = html.replace('<div id="video-host"></div>', `<div id="video-host"><div style="position:absolute;background:#f00;${english}"></div></div>`);
  html = html.replace('<script src="app.js"></script>', `<script src="app.js"></script><script>setTimeout(function () {
    ${events}
  }, 30000);</script>`);
  fs.writeFileSync(path.join(temp, 'index.html'), html);
  return pathToFileURL(path.join(temp, 'index.html')).href;
}

function tvShot(events) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-cover-pixels-'));
  try {
    const shot = path.join(temp, 'shot.png');
    // TV ekranı gibi sabit 1920×1080 bir görünüm: başsız Chromium ekran görüntüsünü alırken pencereyi yeniden boyutlandırır,
    // sayfa doğrudan açılınca yerleşimden sonra görünümün yüksekliği değişiyordu (gerçek TV'de değişmez).
    const page = path.join(temp, 'frame.html');
    fs.writeFileSync(page, `<!doctype html><style>html,body{margin:0;overflow:hidden}</style>
      <iframe src="${tvPage(temp, events)}" style="border:0;width:1920px;height:1080px"></iframe>`);
    run(['--virtual-time-budget=31000', '--screenshot=' + shot, pathToFileURL(page).href], temp);
    return redPixels(decodePng(fs.readFileSync(shot)));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

function tvFonts() {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-cover-fonts-'));
  try {
    const send = (text, box) => `__send('subtitle', ${JSON.stringify({ text, duration: 8000, box })}); fonts.push(font());`;
    const events = `var fonts = [];
      function font() { return parseFloat(getComputedStyle(document.getElementById('subtitle-text')).fontSize); }
      __send('style', ${JSON.stringify(tvStyle('cover'))});
      ${send(SHORT, ENGLISH)} ${send(MEDIUM, ENGLISH)} ${send(LONG, ENGLISH)} ${send(SHORT, ENGLISH)} ${send(MEDIUM)}
      __send('style', ${JSON.stringify(tvStyle('cover', 52))});
      ${send(SHORT, ENGLISH)}
      var pre = document.createElement('pre'); pre.id = 'result';
      pre.textContent = btoa(JSON.stringify(fonts)); document.body.appendChild(pre);`;
    return result(run(['--virtual-time-budget=31000', '--dump-dom', tvPage(temp, events)], temp));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

// --- OBS katmanı ---

// OBS sayfası saydam bir iframe'de, İngilizce altyazının (kırmızı) üstünde; EventSource sahte, olaylar sayfanın içinden.
function obsRun(events, mode) {
  const stub = `<script>
    window.__listeners = {};
    window.EventSource = function () { this.addEventListener = function (n, f) { window.__listeners[n] = f; }; };
    function fire(name, data) { window.__listeners[name]({ data: JSON.stringify(data) }); }
  </script>`;
  const probe = `<pre id="result"></pre><script>
    var fonts = [];
    function font() { return parseFloat(getComputedStyle(document.getElementById('line')).fontSize); }
    ${events}
    document.getElementById('result').textContent = btoa(JSON.stringify(fonts));
  </script>`;
  // Ekran görüntüsü yerleşimi ölçer, belirme geçişini (0,15 sn) beklemez.
  const still = '<style>#line { transition: none !important; }</style>';
  const html = fs.readFileSync(obsPage, 'utf8').replace('<head>', '<head>' + stub + still).replace('</body>', probe + '</body>');
  // Piksel olarak, iframe'in (1920×1080) koordinatlarında: dış sayfanın görünümü (Linux'ta) 1080'den farklı olabiliyor.
  const english = `left:${Math.round(ENGLISH.left * 1920)}px;top:${Math.round(ENGLISH.top * 1080)}px;` +
    `width:${Math.round((ENGLISH.right - ENGLISH.left) * 1920)}px;height:${Math.round((ENGLISH.bottom - ENGLISH.top) * 1080)}px`;
  const encoded = Buffer.from(html, 'utf8').toString('base64');
  const page = `<!doctype html><style>html,body{margin:0;background:#fff;overflow:hidden}</style>
    <div style="position:absolute;background:#f00;${english}"></div>
    <iframe id="frame" style="position:absolute;left:0;top:0;border:0;width:1920px;height:1080px;background:transparent" allowtransparency="true"></iframe>
    <pre id="result"></pre><script>
    var frame = document.getElementById('frame');
    frame.contentDocument.open();
    frame.contentDocument.write(decodeURIComponent(escape(atob('${encoded}'))));
    frame.contentDocument.close();
    document.getElementById('result').textContent = frame.contentDocument.getElementById('result').textContent;
    </script>`;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-cover-obs-'));
  try {
    const file = path.join(temp, 'test.html');
    fs.writeFileSync(file, page);
    if (mode === 'shot') {
      const shot = path.join(temp, 'shot.png');
      run(['--virtual-time-budget=2000', '--screenshot=' + shot, pathToFileURL(file).href], temp);
      return redPixels(decodePng(fs.readFileSync(shot)));
    }
    return result(run(['--dump-dom', pathToFileURL(file).href], temp));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

const obsStyle = (placement, fontSize, background) => ({ fontSize: fontSize || 48, placement,
  background: background === undefined ? 100 : background, backgroundShape: 'box' });
const obsSend = (text, box) => `fire('subtitle', ${JSON.stringify({ text, duration: 60000, box })}); fonts.push(font());`;

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');
const skip = !browser && 'Chrome/Edge bulunamadı';

test('TV: kısa çeviri iki satırlık İngilizce altyazıyı tamamen örter (ekran görüntüsünde kırmızı yok)', { skip }, (t) => {
  const style = (placement) => `__send('style', ${JSON.stringify(tvStyle(placement))});`;
  const subtitle = (text, box) => `__send('subtitle', ${JSON.stringify({ text, duration: 8000, box })});`;
  const scenes = {
    short: style('cover') + subtitle(SHORT, ENGLISH),
    medium: style('cover') + subtitle(MEDIUM, ENGLISH),
    // Yeri gelmeyen satır son bilinen yeri örter.
    noBox: style('cover') + subtitle(SHORT, ENGLISH) + subtitle(MEDIUM),
    // Denetim: "Altında" seçiliyken İngilizce altyazı görünür; test kırmızıyı gerçekten görüyor.
    below: style('below') + subtitle(SHORT, ENGLISH),
  };
  const red = {};
  for (const [name, events] of Object.entries(scenes)) red[name] = tvShot(events);
  t.diagnostic(JSON.stringify(red));
  assert.ok(red.below > 10000, 'denetim sahnesinde İngilizce altyazı görünmeli: ' + JSON.stringify(red));
  assert.equal(red.short, 0, JSON.stringify(red));
  assert.equal(red.medium, 0, JSON.stringify(red));
  assert.equal(red.noBox, 0, JSON.stringify(red));
});

// X'te bildirildi (MertTurna19, TV): "Altyazının üstünü örtsün"de Türkçe zeminsiz/ince çiziliyor, İngilizce satır altından
// görünüyordu. Örtü "Zemin koyuluğu"nu izliyordu (#225); varsayılan %72'de ve kaydırıcı düşükken yarı saydamdı. Örtü her
// koyulukta (ve lacivert gibi renkli zeminde) tam opak olmalı; "Altında" (denetim) koyuluğu aynen kullanır.
test('TV: örtü her zemin koyuluğunda tam opak, İngilizce altyazı hiç görünmez (MertTurna19)', { skip }, (t) => {
  const subtitle = (text, box) => `__send('subtitle', ${JSON.stringify({ text, duration: 8000, box })});`;
  const red = {};
  for (const background of [1, 30, 72]) {
    const style = Object.assign(tvStyle('cover', 46, background), { backgroundColor: '#0E1A30' });
    red['cover' + background] = tvShot(`__send('style', ${JSON.stringify(style)});` + subtitle(SHORT, ENGLISH));
    red['medium' + background] = tvShot(`__send('style', ${JSON.stringify(style)});` + subtitle(MEDIUM, ENGLISH));
  }
  red.below = tvShot(`__send('style', ${JSON.stringify(tvStyle('below', 46, 30))});` + subtitle(SHORT, ENGLISH));
  t.diagnostic(JSON.stringify(red));
  assert.ok(red.below > 10000, 'denetim sahnesinde İngilizce altyazı görünmeli: ' + JSON.stringify(red));
  for (const [name, count] of Object.entries(red)) if (name !== 'below') assert.equal(count, 0, name + ': ' + JSON.stringify(red));
});

// Yeri hiç gelmeyen satır (telefondaki "Test" yazısı, PS5 ana ekranı): "Örtsün"de yazının kendi zemini de tam opak;
// başka yerleşimde koyuluk aynen geçerli.
test('TV: "Örtsün"de yeri bilinmeyen test yazısının zemini tam opak, başka yerleşimde koyuluk geçerli', { skip }, () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-cover-test-text-'));
  try {
    const events = `var out = {};
      function bg() { return getComputedStyle(document.getElementById('subtitle-text')).backgroundColor; }
      __send('style', ${JSON.stringify(tvStyle('cover', 46, 30))});
      __send('subtitle', ${JSON.stringify({ text: SHORT, duration: 8000 })}); out.cover = bg();
      out.thin = document.body.className.indexOf('thin-bg') >= 0;
      __send('style', ${JSON.stringify(tvStyle('fixed', 46, 30))});
      __send('subtitle', ${JSON.stringify({ text: MEDIUM, duration: 8000 })}); out.fixed = bg();
      var pre = document.createElement('pre'); pre.id = 'result';
      pre.textContent = btoa(JSON.stringify(out)); document.body.appendChild(pre);`;
    const m = result(run(['--virtual-time-budget=31000', '--dump-dom', tvPage(temp, events)], temp));
    assert.equal(m.cover, 'rgb(0, 0, 0)', JSON.stringify(m));
    assert.equal(m.thin, false, JSON.stringify(m));
    assert.equal(m.fixed, 'rgba(0, 0, 0, 0.3)', JSON.stringify(m));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
});

// X (beta.105): "Zeminsiz" seçen kullanıcı "Örtsün"de (varsayılan yerleşim) gri/siyah kutu görüyordu; #1378 örtüyü koyuluk
// 0'da da tam opak yapmıştı. "Zeminsiz" her yerleşimde zeminsiz: örtü çizilmez, yazının kendi zemini saydam, kontur eklenir.
test('TV: "Zeminsiz"de "Örtsün" kutu çizmez, yazı konturlu', { skip }, (t) => {
  const subtitle = (text, box) => `__send('subtitle', ${JSON.stringify({ text, duration: 8000, box })});`;
  const style = Object.assign(tvStyle('cover', 46, 0), { backgroundColor: '#2B2D33' });
  const red = tvShot(`__send('style', ${JSON.stringify(style)});` + subtitle(SHORT, ENGLISH));
  const below = tvShot(`__send('style', ${JSON.stringify(tvStyle('below', 46, 0))});` + subtitle(SHORT, ENGLISH));
  t.diagnostic(JSON.stringify({ red, below }));
  // Örtü yokken İngilizce (kırmızı) görünür; yalnız Türkçe yazının harfleri bir kısmını kapatır.
  assert.ok(red > below * 0.5, 'zeminsizde örtü çizilmemeli: ' + JSON.stringify({ red, below }));
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-cover-clear-'));
  try {
    const events = `var out = {};
      function bg(id) { return getComputedStyle(document.getElementById(id)).backgroundColor; }
      __send('style', ${JSON.stringify(style)});
      __send('subtitle', ${JSON.stringify({ text: SHORT, duration: 8000, box: ENGLISH })});
      out.cover = bg('subtitle-cover'); out.text = bg('subtitle-text');
      __send('subtitle', ${JSON.stringify({ text: MEDIUM, duration: 8000 })}); out.noBox = bg('subtitle-text');
      out.thin = document.body.className.indexOf('thin-bg') >= 0;
      var pre = document.createElement('pre'); pre.id = 'result';
      pre.textContent = btoa(JSON.stringify(out)); document.body.appendChild(pre);`;
    const m = result(run(['--virtual-time-budget=31000', '--dump-dom', tvPage(temp, events)], temp));
    assert.equal(m.cover, 'rgba(0, 0, 0, 0)', JSON.stringify(m));
    assert.equal(m.text, 'rgba(0, 0, 0, 0)', JSON.stringify(m));
    assert.equal(m.noBox, 'rgba(0, 0, 0, 0)', JSON.stringify(m));
    assert.equal(m.thin, true, JSON.stringify(m));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
});

test('TV: örtüde yazı boyu sabit, uzun satırda da küçülmez', { skip }, () => {
  const fonts = tvFonts();
  // Seçilen boy 46: 3 satıra sığmayan satır da 46 (daha çok satıra bölünür); boy ayarı değişince yeni boy.
  assert.deepEqual(fonts, [46, 46, 46, 46, 46, 52], JSON.stringify(fonts));
});

test('OBS: kısa çeviri iki satırlık İngilizce altyazıyı tamamen örter (ekran görüntüsünde kırmızı yok)', { skip }, (t) => {
  const style = (placement) => `fire('style', ${JSON.stringify(obsStyle(placement))});`;
  const red = {
    short: obsRun(style('cover') + obsSend(SHORT, ENGLISH), 'shot'),
    medium: obsRun(style('cover') + obsSend(MEDIUM, ENGLISH), 'shot'),
    noBox: obsRun(style('cover') + obsSend(SHORT, ENGLISH) + obsSend(MEDIUM), 'shot'),
    below: obsRun(style('below') + obsSend(SHORT, ENGLISH), 'shot'),
  };
  t.diagnostic(JSON.stringify(red));
  assert.ok(red.below > 10000, 'denetim sahnesinde İngilizce altyazı görünmeli: ' + JSON.stringify(red));
  assert.equal(red.short, 0, JSON.stringify(red));
  assert.equal(red.medium, 0, JSON.stringify(red));
  assert.equal(red.noBox, 0, JSON.stringify(red));
});

test('OBS: örtü her zemin koyuluğunda tam opak, İngilizce altyazı hiç görünmez (MertTurna19)', { skip }, (t) => {
  const red = {};
  for (const background of [1, 30, 72]) {
    const style = `fire('style', ${JSON.stringify(Object.assign(obsStyle('cover', 48, background), { backgroundColor: '#0E1A30' }))});`;
    red['cover' + background] = obsRun(style + obsSend(SHORT, ENGLISH), 'shot');
  }
  red.below = obsRun(`fire('style', ${JSON.stringify(obsStyle('below', 48, 30))});` + obsSend(SHORT, ENGLISH), 'shot');
  t.diagnostic(JSON.stringify(red));
  assert.ok(red.below > 10000, 'denetim sahnesinde İngilizce altyazı görünmeli: ' + JSON.stringify(red));
  for (const [name, count] of Object.entries(red)) if (name !== 'below') assert.equal(count, 0, name + ': ' + JSON.stringify(red));
});

test('OBS: "Zeminsiz"de "Örtsün" kutu çizmez (X, beta.105)', { skip }, (t) => {
  const style = `fire('style', ${JSON.stringify(Object.assign(obsStyle('cover', 48, 0), { backgroundColor: '#2B2D33' }))});`;
  const red = obsRun(style + obsSend(SHORT, ENGLISH), 'shot');
  const noBox = obsRun(style + obsSend(SHORT, ENGLISH) + obsSend(MEDIUM), 'shot');
  const below = obsRun(`fire('style', ${JSON.stringify(obsStyle('below', 48, 0))});` + obsSend(SHORT, ENGLISH), 'shot');
  t.diagnostic(JSON.stringify({ red, noBox, below }));
  assert.ok(red > below * 0.5, 'zeminsizde örtü çizilmemeli: ' + JSON.stringify({ red, noBox, below }));
  assert.ok(noBox > below * 0.5, 'zeminsizde örtü çizilmemeli: ' + JSON.stringify({ red, noBox, below }));
});

test('OBS: örtüde yazı boyu sabit, uzun satırda da küçülmez', { skip }, () => {
  const style = (size) => `fire('style', ${JSON.stringify(obsStyle('cover', size))});`;
  const fonts = obsRun(style() + obsSend(SHORT, ENGLISH) + obsSend(MEDIUM, ENGLISH) + obsSend(LONG, ENGLISH) +
    obsSend(SHORT, ENGLISH) + obsSend(MEDIUM) + style(54) + obsSend(SHORT, ENGLISH));
  // Seçilen boy 48 (1080p'de piksel): 3 satıra sığmayan satır da 48; boy ayarı değişince yeni boy.
  assert.deepEqual(fonts, [48, 48, 48, 48, 48, 54], JSON.stringify(fonts));
});

// X'te bildirildi (beta.89, TCL Android TV): "Üstünde" seçiliyken Türkçe satır İngilizce satırın üstüne biniyordu. Yeri
// gelmeyen satır sabit yüksekliğe (alttan %7) iniyor, alttaki İngilizce altyazıyı örtüyordu; katmanda (Android TV) büyütülmüş
// kutu TV resmi büyütmeyince İngilizce satırın içine düşüyordu. "Üstünde"de İngilizce altyazı (kırmızı) hiç örtülmemeli.
test('TV: "Üstünde" çeviri İngilizce altyazının üstünde ayrı durur (çakışma yok)', { skip }, (t) => {
  const style = (placement) => `__send('style', ${JSON.stringify(tvStyle(placement))});`;
  const subtitle = (text, box) => `__send('subtitle', ${JSON.stringify({ text, duration: 8000, box })});`;
  const overlay = 'document.body.className += " overlay";';
  const red = {
    below: tvShot(style('below') + subtitle(SHORT, ENGLISH)),
    above: tvShot(style('above') + subtitle(MEDIUM, ENGLISH)),
    // Yeri gelmeyen satır son bilinen yerin üstünde kalır.
    noBox: tvShot(style('above') + subtitle(SHORT, ENGLISH) + subtitle(MEDIUM)),
    overlay: tvShot(overlay + style('above') + subtitle(MEDIUM, ENGLISH)),
    long: tvShot(style('above') + subtitle(LONG, ENGLISH)),
  };
  t.diagnostic(JSON.stringify(red));
  assert.ok(red.below > 10000, 'denetim sahnesinde İngilizce altyazı görünmeli: ' + JSON.stringify(red));
  for (const name of ['above', 'noBox', 'overlay', 'long']) assert.equal(red[name], red.below, name + ': ' + JSON.stringify(red));
});

// "Üstünde": çevirinin kutusu (zemini) ile İngilizce satırın üst kenarı arasında boşluk kalır. beta.88'de 1080'de ~12 piksel
// (ekranın %1,2'si) idi; zemin İngilizce yazıya değiyormuş gibi görünüyordu (X, beta.90). Şimdi en az iki katı, çakışma yok.
test('TV: "Üstünde" çevirinin zemini ile İngilizce satır arasında boşluk var (beta.88 boşluğunun en az iki katı)', { skip }, () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-above-gap-'));
  try {
    const events = `__send('style', ${JSON.stringify(tvStyle('above'))});
      __send('subtitle', ${JSON.stringify({ text: MEDIUM, duration: 8000, box: ENGLISH })});
      var r = document.getElementById('subtitle-text').getBoundingClientRect();
      var pre = document.createElement('pre'); pre.id = 'result';
      pre.textContent = btoa(JSON.stringify({ bottom: r.bottom, height: innerHeight }));
      document.body.appendChild(pre);`;
    const m = result(run(['--virtual-time-budget=31000', '--dump-dom', tvPage(temp, events)], temp));
    const gap = ENGLISH.top * m.height - m.bottom;
    const beta88 = m.height * 0.012;
    assert.ok(gap >= 2 * beta88 - 1, 'boşluk ' + gap + ' px, beta.88: ' + beta88 + ' px');
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
});

// "Örtsün" + "Yazı kadar": 3 satıra sığmayan uzun çeviri de seçilen boyda, daha çok satıra bölünür ve İngilizceyi örter.
test('TV: örtüde uzun çeviri küçülmeden bölünür, İngilizce altyazı yine görünmez', { skip }, () => {
  const red = tvShot(`__send('style', ${JSON.stringify(tvStyle('cover'))});` +
    `__send('subtitle', ${JSON.stringify({ text: LONG, duration: 8000, box: ENGLISH })});`);
  assert.equal(red, 0);
});
