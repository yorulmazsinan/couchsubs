// SPDX-License-Identifier: AGPL-3.0-only
// LG TV (tv-webos/platform.js) ekran ölçüsü (#1098): LG 43LH590V'de (webOS 3.x) sayfa ekranın yalnız sol üst kısmına
// çiziliyordu. Ortak index.html'deki sabit width=1920 görünüm Android TV için (#7); ekran 1920'den dar ya da piksel oranı
// 1 değilse LG'de görünüm ekran genişliğinde açılır, sayfa CSS zoom ile 1920x1080 uzayına sığdırılır. 1920/oran 1 ekranda
// hiçbir şey değişmez. Gerçek sayfa başsız Chromium'da: bilgi paneli ve altyazı ekranın içinde kalır, tanı satırı ekran
// ölçüsünü yazar.
// Çalıştırma: node --test scripts/tv-webos-screen.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const tvRoot = path.join(__dirname, '..', 'tv-webos');
const code = fs.readFileSync(path.join(tvRoot, 'platform.js'), 'utf8');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

// platform.js'i Node'da yükler (ekran ölçüsü ve görünüm etiketi taklit).
function load(screen, ratio) {
  const meta = { content: 'width=1920', setAttribute(name, value) { if (name === 'content') this.content = value; } };
  const root = { style: {}, clientWidth: screen ? screen[0] : 1920, clientHeight: screen ? screen[1] : 1080 };
  const document = {
    hidden: false,
    documentElement: root,
    querySelector: (q) => (q === 'meta[name="viewport"]' ? meta : null),
    createElement: () => ({ style: {}, setAttribute() {}, addEventListener() {}, appendChild() {} }),
    addEventListener() {},
  };
  const window = {
    navigator: { userAgent: 'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 Chrome/38.0.2125.122 Safari/537.36' },
    PalmSystem: { deviceInfo: JSON.stringify({ platformVersion: '3.0.0', modelName: '43LH590V-ZE' }) },
    addEventListener() {},
    setTimeout: () => 0,
    clearTimeout() {},
    devicePixelRatio: ratio,
    innerWidth: root.clientWidth,
    innerHeight: root.clientHeight,
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  };
  if (screen) window.screen = { width: screen[0], height: screen[1] };
  window.window = window;
  window.document = document;
  const context = vm.createContext(Object.assign(window, { document, console, Date, Math, JSON, setTimeout: window.setTimeout,
    clearTimeout: window.clearTimeout, localStorage: window.localStorage }));
  vm.runInContext(code, context);
  return { platform: context.COUCHSUBS_PLATFORM, meta, root, window: context };
}

test('viewportPlan: 1920 ve oran 1 ekranda dokunulmaz, dar ya da oranlı ekranda 1920x1080 uzayına sığdırılır', () => {
  const { platform } = load([1920, 1080], 1);
  assert.deepEqual({ ...platform.viewportPlan(1920, 1080, 1) }, { content: null, zoom: 1 });
  assert.deepEqual({ ...platform.viewportPlan(3840, 2160, 1) }, { content: null, zoom: 1 });
  assert.deepEqual({ ...platform.viewportPlan(undefined, undefined, 1) }, { content: null, zoom: 1 });
  assert.deepEqual({ ...platform.viewportPlan(1280, 720, 1) }, { content: 'width=device-width', zoom: 0.6667 });
  assert.deepEqual({ ...platform.viewportPlan(960, 540, 2) }, { content: 'width=device-width', zoom: 0.5 });
  assert.deepEqual({ ...platform.viewportPlan(1280, 720, 1.5) }, { content: 'width=device-width', zoom: 0.6667 });
  // Oran 1 değil ama ekran 1920 genişlikte: sabit görünüm kalkar, ölçek gerekmez.
  assert.deepEqual({ ...platform.viewportPlan(1920, 1080, 2) }, { content: 'width=device-width', zoom: 1 });
});

test('1920 ekranda görünüm ve ölçek değişmez; tanı satırı ekranı yazar', () => {
  const { platform, meta, root, window } = load([1920, 1080], 1);
  assert.equal(meta.content, 'width=1920');
  assert.equal(root.style.zoom, undefined);
  assert.equal(window.COUCHSUBS_ZOOM, undefined);
  assert.match(platform.diagnostics(), /scr 1920x1080 dpr 1 vp 1920 iw 1920x1080/);
});

test('43LH590V gibi dar/oranlı ekranda görünüm ekran genişliğinde, sayfa yarı ölçekte; tanı satırı yazar', () => {
  const { platform, meta, root, window } = load([960, 540], 2);
  assert.equal(meta.content, 'width=device-width');
  assert.equal(root.style.zoom, '0.5');
  assert.equal(window.COUCHSUBS_ZOOM, 0.5);
  assert.match(platform.diagnostics(), /scr 960x540 dpr 2 vp device z 0\.5 iw 960x540/);
});

// Gerçek sayfa: ekran 960x540 (oran 2) bildiren TV. Bilgi paneli ve en alttaki altyazı pencerenin içinde kalmalı;
// sabit 1920 görünümde (eski hâl) panel ve altyazı pencerenin dışına taşar.
function measure(screen, ratio, fixed) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-webos-screen-'));
  try {
    for (const file of fs.readdirSync(tvRoot)) {
      if (/\.(js|css|png)$/.test(file)) fs.copyFileSync(path.join(tvRoot, file), path.join(temp, file));
    }
    const prelude = `<script>
      Object.defineProperty(window, 'screen', { value: { width: ${screen[0]}, height: ${screen[1]} } });
      Object.defineProperty(window, 'devicePixelRatio', { value: ${ratio} });
      window.PalmSystem = { deviceInfo: '{"platformVersion":"3.0.0","modelName":"43LH590V-ZE"}' };
      window.EventSource = function () { this.addEventListener = function () {}; this.close = function () {}; };
    </script>`;
    let html = fs.readFileSync(path.join(tvRoot, 'index.html'), 'utf8').replace('<link rel="stylesheet"', prelude + '<link rel="stylesheet"');
    // Eski hâl: platform.js ekranı 1920x1080 sanar (sabit görünüm, ölçek yok).
    if (fixed) html = html.replace('<script src="platform.js"></script>',
      '<script>Object.defineProperty(window, "screen", { value: { width: 1920, height: 1080 } });</script><script src="platform.js"></script>');
    // app.js ağda bilgisayar arıyor (başsız Chromium'u meşgul eder); ölçülen yalnız platform.js'in ölçeği ve sayfanın CSS'i.
    html = html.replace('<script src="app.js"></script>', `<script>setTimeout(function () {
      var zoom = window.COUCHSUBS_ZOOM || 1;
      var panel = document.getElementById('panel').getBoundingClientRect();
      var sub = document.getElementById('subtitle');
      sub.className = ''; document.getElementById('subtitle-text').textContent = 'Altyazı en altta';
      var line = sub.getBoundingClientRect();
      var pre = document.createElement('pre'); pre.id = 'result';
      pre.textContent = btoa(unescape(encodeURIComponent(JSON.stringify({ zoom: zoom,
        meta: document.querySelector('meta[name="viewport"]').getAttribute('content'),
        root: document.documentElement.style.zoom || '',
        w: window.innerWidth, h: window.innerHeight,
        panel: [panel.left, panel.top, panel.right, panel.bottom], sub: [line.left, line.top, line.right, line.bottom],
        diag: window.COUCHSUBS_PLATFORM.diagnostics() }))));
      document.body.appendChild(pre);
    }, 1500);</script>`);
    fs.writeFileSync(path.join(temp, 'index.html'), html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=' + screen[0] + ',' + screen[1],
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
      '--allow-file-access-from-files', '--virtual-time-budget=3000', '--user-data-dir=' + path.join(temp, 'profile'), '--dump-dom',
      pathToFileURL(path.join(temp, 'index.html')).href], { encoding: 'utf8', timeout: 60000 });
    const match = (run.stdout || '').match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi: ' + (run.stderr || '').slice(-400));
    return JSON.parse(decodeURIComponent(escape(Buffer.from(match[1], 'base64').toString('binary'))));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

test('gerçek sayfa: 960x540 oran 2 bildiren TV\'de panel ve altyazı ekranın içinde', { skip: !browser && 'Chromium yok' }, () => {
  const got = measure([960, 540], 2, false);
  assert.equal(got.meta, 'width=device-width');
  assert.equal(got.zoom, 0.5);
  assert.match(got.diag, /scr 960x540 dpr 2 vp device z 0\.5/);
  for (const [name, box] of [['panel', got.panel], ['altyazı', got.sub]]) {
    assert.ok(box[0] >= -1 && box[2] <= got.w + 1, `${name} yatayda taşıyor: ${JSON.stringify(got)}`);
    assert.ok(box[1] >= -1 && box[3] <= got.h + 1, `${name} dikeyde taşıyor: ${JSON.stringify(got)}`);
  }
  // Eski hâl (sabit 1920 uzayı, ölçeksiz): 1920 uzayına göre çizilen bilgi paneli dar ekrana sığmıyordu.
  const old = measure([960, 540], 1, true);
  assert.equal(old.zoom, 1);
  assert.ok(old.panel[3] > old.h + 1, 'eski hâlde panel ekrandan taşmalıydı: ' + JSON.stringify(old));
});
