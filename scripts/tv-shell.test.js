// SPDX-License-Identifier: AGPL-3.0-only
// TV kabuğu (tv-webos/shell.js, docs/tv-ince-kabuk.md): TV uygulaması sayfa kodunu eşleşmiş bilgisayardan/telefondan
// (GET /tv/app/manifest, /tv/app/<sürüm>/<dosya>) indirir, eşleşme anahtarıyla HMAC'i ve SHA-256 özetlerini doğrular,
// saklar ve yeniden açılınca onu çalıştırır; sunucu yoksa, doğrulama tutmazsa, kabuk arayüzü eskiyse ya da uzak sayfa
// açılamazsa paketteki yedekle açılır. İki bölüm:
//  - Node'da (vm, sahte DOM/ağ): akış, red nedenleri, sürüm/arayüz kuralları, ortak deneme dosyası (tv-app-bundle.json;
//    Mac/iPhone, Windows ve Android sunucularıyla aynı imza).
//  - Gerçek Chromium'da (varsa; CI'da şart): gerçek tv-webos sayfası yerel bir sunucudan daha yeni sürümü indirip
//    yeniden açılınca onunla çalışıyor; yanlış imza ve bozuk uzak sayfa yedeğe düşüyor.
// node --test scripts/tv-shell.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const repo = path.join(__dirname, '..');
const tvRoot = path.join(repo, 'tv-webos');
const SHELL = fs.readFileSync(path.join(tvRoot, 'shell.js'), 'utf8');
const FIXTURE = JSON.parse(fs.readFileSync(path.join(repo, 'core', 'Tests', 'CouchSubsCoreTests', 'Fixtures', 'tv-app-bundle.json'), 'utf8'));
const PATHS = ['index.html', 'style.css', 'i18n.js', 'app.js'];
const KEY = 'Q2xhdWRlS2V5MDEyMzQ1Ng';
const shellVersion = /var SHELL_VERSION = '([0-9.]+)';/.exec(SHELL)[1];

// Sunucunun yaptığının aynısı (TVAppBundle.swift / TvAppBundle.cs / TvAppBundle.kt).
function bundle(files, { key = KEY, signKey = key, shellApi, version } = {}) {
  const app = files['app.js'];
  version = version || /var APP_VERSION = '([0-9.]+)';/.exec(app)[1];
  shellApi = shellApi || Number(/var SHELL_API = ([0-9]+);/.exec(app)[1]);
  const list = PATHS.map(p => {
    const data = Buffer.from(files[p], 'utf8');
    return { path: p, size: data.length, sha256: crypto.createHash('sha256').update(data).digest('hex') };
  });
  let canonical = `couchsubs-tv-app/1\n${version}\n${shellApi}\n`;
  for (const f of list) canonical += `${f.path} ${f.size} ${f.sha256}\n`;
  const hmac = crypto.createHmac('sha256', Buffer.from(signKey, 'utf8')).update(canonical, 'utf8').digest('hex');
  return { manifest: { format: 1, version, shellApi, files: list, hmac }, files, version };
}

// --- Node'da sahte TV ---

function fakeNode(name, id) {
  return {
    nodeName: name.toUpperCase(), id: id || '', childNodes: [], attrs: {}, parentNode: null, text: '',
    get firstChild() { return this.childNodes[0] || null; },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'id') this.id = String(v); },
    appendChild(n) { return this.insertBefore(n, null); },
    insertBefore(n, ref) {
      if (n.parentNode) n.parentNode.removeChild(n);
      const at = ref ? this.childNodes.indexOf(ref) : -1;
      if (at < 0) this.childNodes.push(n); else this.childNodes.splice(at, 0, n);
      n.parentNode = this;
      if (n.nodeName === 'SCRIPT' && this.onScript) this.onScript(n);
      return n;
    },
    removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; },
    // Gövde işaretlemesinin üst düzey öğeleri (index.html biçimi: iki boşlukla girintili, kimlikli).
    set innerHTML(html) {
      this.childNodes = [];
      const re = /^ {2}<(\w+) id="([^"]+)"/gm;
      let m;
      while ((m = re.exec(html))) this.appendChild(fakeNode(m[1], m[2]));
    },
  };
}

function bootTv({ storage, server, reloads = { count: 0 } }) {
  const writes = [];
  const head = fakeNode('head');
  const link = fakeNode('link');
  link.setAttribute('href', 'style.css');
  link.parentNode = head;
  head.childNodes.push(link);
  const body = fakeNode('body');
  const video = fakeNode('div', 'video-host');
  body.appendChild(video);
  body.appendChild(fakeNode('div', 'panel'));
  const shellTag = fakeNode('script');
  body.appendChild(shellTag);
  const all = (node, out) => { out.push(node); node.childNodes.forEach(c => all(c, out)); return out; };
  const context = {
    console, unescape, encodeURIComponent, JSON, Math, String, Number, Array, Date, Error, RegExp,
    localStorage: {
      getItem: k => (storage.has(k) ? storage.get(k) : null),
      setItem: (k, v) => { if (storage.full) throw new Error('QuotaExceededError'); storage.set(k, String(v)); },
      removeItem: k => storage.delete(k),
    },
    location: { reload() { reloads.count++; } },
    COUCHSUBS_PLATFORM: { backKey: 461 },
    XMLHttpRequest: function () {
      const xhr = this;
      xhr.open = (method, url) => { xhr.url = url; };
      xhr.overrideMimeType = () => {};
      xhr.send = () => {
        inflight++;
        setImmediate(() => {
          try {
            const reply = server ? server(xhr.url) : null;
            if (!reply) { if (xhr.onerror) xhr.onerror(); return; }
            xhr.status = reply.status;
            xhr.responseText = reply.body;
            xhr.onload();
          } finally { inflight--; }
        });
      };
    },
    document: {
      body, write: s => writes.push(s),
      createElement: name => fakeNode(name),
      createTextNode: text => ({ nodeName: '#text', text, childNodes: [] }),
      getElementById: id => all(body, []).find(n => n.id === id) || null,
      getElementsByTagName: name => name === 'head' ? [head] : all(head, []).concat(all(body, [])).filter(n => n.nodeName === name.toUpperCase()),
      querySelector: () => null,
    },
  };
  context.window = context;
  vm.createContext(context);
  body.onScript = node => { if (node.text) vm.runInContext(node.text, context, { filename: node.getAttribute('data-page') || 'page' }); };
  vm.runInContext(SHELL, context, { filename: 'shell.js' });
  return { context, writes, head, body, video, reloads, shell: context.COUCHSUBS_SHELL };
}

function serve(b, { tamper } = {}) {
  const requests = [];
  const handler = url => {
    requests.push(url);
    const u = new URL(url);
    if (u.searchParams.get('k') !== KEY) return { status: 401, body: '' };
    if (u.pathname === '/tv/app/manifest') return { status: 200, body: JSON.stringify(b.manifest) };
    const m = /^\/tv\/app\/([0-9.]+)\/([a-z0-9.]+)$/.exec(u.pathname);
    if (!m || m[1] !== b.version || !(m[2] in b.files)) return { status: 404, body: '' };
    return { status: 200, body: tamper && tamper[m[2]] !== undefined ? tamper[m[2]] : b.files[m[2]] };
  };
  handler.requests = requests;
  return handler;
}

// Sahte ağdaki bütün istekler (zincirdeki dosya istekleri dahil) bitene kadar bekler.
let inflight = 0;
const settle = async () => {
  for (let i = 0; i < 500; i++) {
    await new Promise(resolve => setTimeout(resolve, 10));
    if (inflight === 0) return;
  }
};

function remotePage(version, { started = true, shellApi = 1 } = {}) {
  return {
    'index.html': '<!doctype html>\n<html>\n<body>\n  <div id="video-host"></div>\n  <div id="panel"></div>\n  <div id="remote-marker"></div>\n' +
      '  <script src="app.js"></script>\n</body>\n</html>\n',
    'style.css': '#remote-marker { color: red; } /* ş */\n',
    'i18n.js': 'window.__i18n = "uzak — ğ";\n',
    'app.js': `(function () {\n  var APP_VERSION = '${version}';\n  var SHELL_API = ${shellApi};\n  window.__ran = APP_VERSION;\n` +
      (started ? '  window.COUCHSUBS_SHELL.started(APP_VERSION);\n' : '') + '})();\n',
  };
}

test('SHA-256 ve HMAC-SHA256 Node crypto ve ortak deneme dosyasıyla aynı', () => {
  const tv = bootTv({ storage: new Map() });
  const t = tv.shell._test;
  for (const n of [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 300000]) {
    const text = crypto.randomBytes(n).toString('base64') + (n % 2 ? 'çğış — İ 🎮' : '');
    assert.equal(t.sha256(text), crypto.createHash('sha256').update(text, 'utf8').digest('hex'), String(n));
  }
  assert.equal(t.hmac('k'.repeat(100), 'x'), crypto.createHmac('sha256', 'k'.repeat(100)).update('x').digest('hex'));
  for (const p of PATHS) assert.equal(t.sha256(FIXTURE.files[p]), FIXTURE.sha256[p], p);
  assert.equal(t.hmac(FIXTURE.key, FIXTURE.canonical), FIXTURE.hmac);
  const manifest = bundle(FIXTURE.files, { key: FIXTURE.key }).manifest;
  assert.equal(t.canonical(manifest), FIXTURE.canonical);
  assert.equal(manifest.hmac, FIXTURE.hmac);
  assert.equal(t.checkManifest(manifest, FIXTURE.key), '');
});

test('liste denetimi: yanlış anahtar, değiştirilmiş sürüm/özet ve bozuk biçim reddedilir', () => {
  const t = bootTv({ storage: new Map() }).shell._test;
  const good = () => JSON.parse(JSON.stringify(bundle(FIXTURE.files, { key: FIXTURE.key }).manifest));
  assert.equal(t.checkManifest(good(), 'AAAAAAAAAAAAAAAAAAAAAA'), 'hmac');
  const version = good(); version.version = '9.9.9';
  assert.equal(t.checkManifest(version, FIXTURE.key), 'hmac');
  const sum = good(); sum.files[3].sha256 = '0'.repeat(64);
  assert.equal(t.checkManifest(sum, FIXTURE.key), 'hmac');
  const api = good(); api.shellApi = 2;
  assert.equal(t.checkManifest(api, FIXTURE.key), 'hmac');
  const order = good(); order.files.reverse();
  assert.equal(t.checkManifest(order, FIXTURE.key), 'files');
  const path1 = good(); path1.files[0].path = '../index.html';
  assert.equal(t.checkManifest(path1, FIXTURE.key), 'files');
  const bad = good(); bad.version = '1.0/../../x';
  assert.equal(t.checkManifest(bad, FIXTURE.key), 'version');
  assert.equal(t.checkManifest({ format: 2 }, FIXTURE.key), 'format');
  assert.equal(t.checkManifest(null, FIXTURE.key), 'format');
});

test('yalnız yerel ağdaki IP adresleri', () => {
  const t = bootTv({ storage: new Map() }).shell._test;
  for (const ok of ['http://192.168.1.20:8787', 'http://10.0.0.5:8787/', 'http://172.16.4.4:8787', 'http://172.31.0.1',
    'http://169.254.10.1:8787', 'http://100.64.1.1:8787', 'http://127.0.0.1:8787', 'http://[fe80::1]:8787', 'http://[fd12::3]:8787']) {
    assert.ok(t.localServer(ok), ok);
  }
  for (const no of ['http://8.8.8.8:8787', 'http://172.32.0.1:8787', 'http://192.169.0.1', 'https://192.168.1.2:8787',
    'http://mac.local:8787', 'http://192.168.1.300:8787', 'http://[2001:db8::1]:8787', 'http://192.168.1.2:8787/x',
    'http://user@192.168.1.2', 'ftp://192.168.1.2', '', null]) {
    assert.equal(t.localServer(no), null, String(no));
  }
});

test('sunucu yoksa ya da sayfa sunmuyorsa paketteki sayfa açılır', async () => {
  const storage = new Map();
  const tv = bootTv({ storage, server: () => ({ status: 404, body: '' }) });
  assert.deepEqual(tv.writes, ['<script src="i18n.js"><\/script><script src="app.js"><\/script>']);
  assert.deepEqual({ ...tv.shell.page() }, { version: shellVersion, source: 'bundled' });
  tv.shell.connected('http://192.168.1.20:8787', KEY);
  await settle();
  assert.equal(tv.reloads.count, 0);
  assert.equal(storage.size, 0);
  // Anahtarsız (eşleşmemiş) ya da yerel olmayan sunucuya hiç sorulmaz.
  const asked = [];
  const other = bootTv({ storage, server: url => { asked.push(url); return null; } });
  other.shell.connected('http://192.168.1.20:8787', '');
  other.shell.connected('http://8.8.8.8:8787', KEY);
  await settle();
  assert.deepEqual(asked, []);
  assert.match(other.shell.status(), /not local/);
});

test('daha yeni ve doğrulanan sayfa saklanır, yeniden açılınca onunla çalışır; #video-host kabuğunki kalır', async () => {
  const storage = new Map();
  const b = bundle(remotePage('9.9.1'));
  const server = serve(b);
  const first = bootTv({ storage, server });
  first.shell.connected('http://192.168.1.20:8787', KEY);
  await settle();
  assert.equal(first.reloads.count, 1);
  assert.deepEqual(server.requests.map(u => new URL(u).pathname),
    ['/tv/app/manifest', '/tv/app/9.9.1/index.html', '/tv/app/9.9.1/style.css', '/tv/app/9.9.1/i18n.js', '/tv/app/9.9.1/app.js']);
  // Aynı sunucu kısa sürede yeniden sorulmaz.
  first.shell.connected('http://192.168.1.20:8787', KEY);
  await settle();
  assert.equal(server.requests.length, 5);

  const second = bootTv({ storage, server });
  assert.deepEqual(second.writes, [], 'paketteki sayfa da başlatıldı');
  assert.equal(second.context.__ran, '9.9.1');
  assert.equal(second.context.__i18n, 'uzak — ğ');
  assert.deepEqual({ ...second.shell.page() }, { version: '9.9.1', source: 'remote' });
  assert.match(second.shell.status(), /page 9\.9\.1 remote/);
  // Uzak gövde: kabuğun görüntü katmanı aynı düğüm, sonra uzak öğeler, betikler en sonda.
  const ids = second.body.childNodes.filter(n => n.nodeName !== 'SCRIPT').map(n => n.id);
  assert.deepEqual(ids, ['video-host', 'panel', 'remote-marker']);
  assert.equal(second.body.childNodes[0], second.video);
  // Paketteki style.css bağlantısı kalkar, uzak CSS eklenir.
  assert.equal(second.head.childNodes.some(n => n.nodeName === 'LINK'), false);
  const style = second.head.childNodes.find(n => n.nodeName === 'STYLE');
  assert.match(style.childNodes[0].text, /remote-marker/);
  // Sunucu aynı sürümü sunmaya devam ediyor: yeniden yükleme yok.
  second.shell.connected('http://192.168.1.20:8787', KEY);
  await settle();
  assert.equal(second.reloads.count, 0);
});

test('imza (HMAC) tutmazsa ya da dosya listedeki özetle uyuşmazsa hiçbir şey saklanmaz', async () => {
  for (const [name, server] of [
    ['başka anahtarla imzalı', serve(bundle(remotePage('9.9.2'), { signKey: 'AAAAAAAAAAAAAAAAAAAAAA' }))],
    ['dosya yolda değişmiş', serve(bundle(remotePage('9.9.2')), { tamper: { 'app.js': remotePage('9.9.2')['app.js'].replace('__ran', '__evil') } })],
    ['aynı boyda değişmiş', serve(bundle(remotePage('9.9.2')), { tamper: { 'i18n.js': remotePage('9.9.2')['i18n.js'].replace('uzak', 'UZAK') } })],
  ]) {
    const storage = new Map();
    const tv = bootTv({ storage, server });
    tv.shell.connected('http://192.168.1.20:8787', KEY);
    await settle();
    assert.equal(tv.reloads.count, 0, name);
    assert.equal(storage.has('couchsubs.shell.page'), false, name);
    assert.match(tv.shell.status(), /update rejected: (hmac|app\.js sha256|i18n\.js sha256)/, name);
    assert.equal(bootTv({ storage, server }).writes.length, 1, name + ': yedekle açılmadı');
  }
});

test('sayfa bu kabuktan yeni bir arayüz (SHELL_API) istiyorsa yüklenmez', async () => {
  const storage = new Map();
  const server = serve(bundle(remotePage('9.9.3', { shellApi: 2 })));
  const tv = bootTv({ storage, server });
  tv.shell.connected('http://192.168.1.20:8787', KEY);
  await settle();
  assert.equal(tv.reloads.count, 0);
  assert.equal(storage.has('couchsubs.shell.page'), false);
  assert.match(tv.shell.status(), /needs shell api 2/);
  assert.equal(server.requests.length, 1);
  // Elle saklanmış olsa da açılışta kullanılmaz.
  storage.set('couchsubs.shell.page', JSON.stringify({ version: '9.9.3', shellApi: 2, files: remotePage('9.9.3'), sizes: {} }));
  assert.equal(bootTv({ storage, server }).writes.length, 1);
});

test('sunucudaki sayfa çalışandan yeni değilse indirilmez', async () => {
  const storage = new Map();
  const server = serve(bundle(remotePage(shellVersion)));
  const tv = bootTv({ storage, server });
  tv.shell.connected('http://192.168.1.20:8787', KEY);
  await settle();
  assert.equal(server.requests.length, 1);
  assert.equal(tv.reloads.count, 0);
});

test('açılışı bitirmeyen uzak sayfa bozuk sayılır: silinir, yeniden yüklenir, sonra yedekle açılır ve bir daha indirilmez', async () => {
  const storage = new Map();
  for (const page of [remotePage('9.9.4', { started: false }),
    Object.assign(remotePage('9.9.4'), { 'app.js': "var APP_VERSION = '9.9.4';\nvar SHELL_API = 1;\nvar x = ;\n" })]) {
    storage.clear();
    const server = serve(bundle(page));
    const first = bootTv({ storage, server });
    first.shell.connected('http://192.168.1.20:8787', KEY);
    await settle();
    assert.equal(first.reloads.count, 1);
    const broken = bootTv({ storage, server });
    assert.equal(broken.reloads.count, 1, 'bozuk sayfadan sonra yeniden yüklenmedi');
    assert.equal(storage.get('couchsubs.shell.bad'), '9.9.4');
    assert.equal(storage.has('couchsubs.shell.page'), false);
    const third = bootTv({ storage, server });
    assert.equal(third.writes.length, 1);
    third.shell.connected('http://192.168.1.20:8787', KEY);
    await settle();
    assert.equal(third.reloads.count, 0);
    assert.match(third.shell.status(), /failed before/);
  }
});

test('kabuk güncellenince (yedek saklanandan yeni) saklanan sayfa kullanılmaz; yer yoksa yeniden yüklenmez', async () => {
  const storage = new Map();
  const old = remotePage('0.9.1');
  const sizes = {};
  for (const p of PATHS) sizes[p] = Buffer.byteLength(old[p]);
  storage.set('couchsubs.shell.page', JSON.stringify({ version: '0.9.1', shellApi: 1, files: old, sizes }));
  assert.equal(bootTv({ storage }).writes.length, 1);
  // Boyu tutmayan (yarım) kayıt da kullanılmaz.
  const page = remotePage('9.9.5');
  storage.set('couchsubs.shell.page', JSON.stringify({ version: '9.9.5', shellApi: 1, files: page, sizes: Object.assign({}, sizes, { 'app.js': 1 }) }));
  assert.equal(bootTv({ storage }).writes.length, 1);

  const full = new Map();
  full.full = true;
  const tv = bootTv({ storage: full, server: serve(bundle(remotePage('9.9.6'))) });
  tv.shell.connected('http://192.168.1.20:8787', KEY);
  await settle();
  assert.equal(tv.reloads.count, 0);
  assert.match(tv.shell.status(), /storage full/);
});

test('sürümler aynı: kabuk, paketteki sayfa, webOS, Samsung ve Android TV; sayfanın istediği arayüz kabukta var', () => {
  const app = fs.readFileSync(path.join(tvRoot, 'app.js'), 'utf8');
  const appVersion = /var APP_VERSION = '([0-9.]+)';/.exec(app)[1];
  assert.equal(shellVersion, appVersion);
  assert.equal(JSON.parse(fs.readFileSync(path.join(tvRoot, 'appinfo.json'), 'utf8')).version, shellVersion);
  assert.match(fs.readFileSync(path.join(repo, 'tv-tizen', 'config.xml'), 'utf8'), new RegExp(`version="${shellVersion.replace(/\./g, '\\.')}" viewmodes`));
  assert.match(fs.readFileSync(path.join(repo, 'tv-android', 'app', 'build.gradle'), 'utf8'), new RegExp(`versionName '${shellVersion.replace(/\./g, '\\.')}'`));
  const pageApi = Number(/var SHELL_API = ([0-9]+);/.exec(app)[1]);
  const shellApi = Number(/var SHELL_API = ([0-9]+);/.exec(SHELL)[1]);
  assert.ok(pageApi >= 1 && pageApi <= shellApi);
  // Sayfa açılışını bitirdiğini kabuğa bildiriyor ve bağlanınca güncellemeyi soruyor.
  assert.match(app, /shell\.started\(APP_VERSION\);\n\}\)\(\);\s*$/);
  assert.match(app, /shell\.connected\(address, serverKey\(address\)\)/);
  // Sayfayı başlatan yalnız kabuk: index.html i18n.js/app.js'i doğrudan yüklemez; her paket kabuğu içerir.
  const html = fs.readFileSync(path.join(tvRoot, 'index.html'), 'utf8');
  assert.match(html, /<script src="platform.js"><\/script>\n(.*\n)*\s*<script src="shell.js"><\/script>/);
  assert.doesNotMatch(html, /src="(app|i18n)\.js"/);
  for (const file of ['scripts/package-tizen.sh', 'scripts/ios-tv-packages.sh', 'couchsubs-android/app/build.gradle',
    'tv-android/app/build.gradle', 'scripts/play-screenshots.sh']) {
    assert.match(fs.readFileSync(path.join(repo, file), 'utf8'), /shell\.js/, file);
  }
});

// --- Gerçek Chromium ---

const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));
if (process.env.CI) assert.ok(browser, 'CI: kabuk testi için Chrome gerekli');

// Sahte platform: HDMI ve TV yok, sayfa bilgisayara kendisi bağlanmaz (kabuğa adresi test verir).
const PRELUDE = `window.COUCHSUBS_PLATFORM = {
  backKey: 461, init: function () {}, onRelaunch: function () {}, exit: function () {},
  launchParams: function () { return {}; },
  showHdmi: function (port, host, onStatus) { onStatus('playing'); },
  findConsolePort: function (callback) { callback(1, 'PS5'); },
  localAddress: function (callback) { callback(null); }
};
window.EventSource = function () { this.readyState = 0; };
window.EventSource.prototype.addEventListener = function () {};
window.EventSource.prototype.close = function () {};
// Sayfanın ağ taraması (sunucu arama) gerçek ağa çıkmaz; yalnız kabuğun test sunucusuna istekleri gider (askıdaki
// istekler tarayıcının sanal saatini durdurur).
(function () {
  var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) { this.__url = String(url); return open.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    if (this.__url.indexOf(window.__SHELL_SERVER + '/tv/app/') === 0) return send.apply(this, arguments);
    var xhr = this;
    setTimeout(function () { if (xhr.onerror) xhr.onerror(); }, 0);
  };
})();`;

function chrome(url, profile) {
  return new Promise((resolve, reject) => {
    const child = spawn(browser, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
      '--disable-background-networking', '--window-size=1920,1080', '--allow-file-access-from-files',
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + profile,
      '--virtual-time-budget=8000', '--dump-dom', url], { windowsHide: true });
    let out = '', err = '';
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { err += d; });
    const timer = setTimeout(() => child.kill(), 60000);
    child.on('error', reject);
    child.on('close', code => { clearTimeout(timer); code === 0 ? resolve(out) : reject(new Error(err)); });
  });
}

// Sunucuya bağlanınca sayfanın yaptığı gibi kabuğa adresi ve anahtarı verir; durumu DOM'a yazar.
const probe = port => `<script>setTimeout(function () {
  window.COUCHSUBS_SHELL.connected('http://127.0.0.1:${port}', '${KEY}');
}, 200);
setInterval(function () {
  var el = document.getElementById('shell-probe') || document.body.appendChild(document.createElement('pre'));
  el.id = 'shell-probe';
  el.textContent = JSON.stringify({ status: window.COUCHSUBS_SHELL.status(), page: window.COUCHSUBS_SHELL.page(),
    version: (document.getElementById('app-version') || {}).textContent,
    bad: localStorage.getItem('couchsubs.shell.bad') });
}, 100);</script>`;

async function scenario(name, transform, options = {}) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-shell-'));
  const files = {};
  for (const p of PATHS) files[p] = fs.readFileSync(path.join(tvRoot, p), 'utf8');
  const remote = transform(files);
  const b = bundle(remote, options);
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    const cors = { 'Access-Control-Allow-Origin': req.headers.origin || '*', 'Cache-Control': 'no-store' };
    if (u.searchParams.get('k') !== KEY) { res.writeHead(401, cors); res.end(); return; }
    if (u.pathname === '/tv/app/manifest') { res.writeHead(200, { ...cors, 'Content-Type': 'application/json' }); res.end(JSON.stringify(b.manifest)); return; }
    const m = /^\/tv\/app\/([0-9.]+)\/([a-z0-9.]+)$/.exec(u.pathname);
    if (!m || m[1] !== b.version || !(m[2] in remote)) { res.writeHead(404, cors); res.end(); return; }
    res.writeHead(200, { ...cors, 'Content-Type': 'application/javascript; charset=utf-8' });
    res.end(remote[m[2]]);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    for (const file of fs.readdirSync(tvRoot)) {
      if (/\.(js|css|png)$/.test(file) && file !== 'platform.js') fs.copyFileSync(path.join(tvRoot, file), path.join(temp, file));
    }
    fs.writeFileSync(path.join(temp, 'platform.js'), `window.__SHELL_SERVER = 'http://127.0.0.1:${server.address().port}';\n` + PRELUDE);
    let html = fs.readFileSync(path.join(tvRoot, 'index.html'), 'utf8');
    // Kabuğun görüntü katmanında bir işaret: uzak gövde gelince de aynı düğüm kalmalı.
    html = html.replace('<div id="video-host"></div>', '<div id="video-host"><div id="hdmi-probe"></div></div>');
    html = html.replace('<script src="shell.js"></script>', '<script src="shell.js"></script>' + probe(server.address().port));
    fs.writeFileSync(path.join(temp, 'index.html'), html);
    const dom = await chrome(pathToFileURL(path.join(temp, 'index.html')).href, path.join(temp, 'profile'));
    const state = JSON.parse(/<pre id="shell-probe">([^<]*)<\/pre>/.exec(dom)[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&'));
    return { dom, state };
  } finally {
    server.close();
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

const bump = version => files => ({
  ...files,
  'app.js': files['app.js'].replace(/var APP_VERSION = '[0-9.]+';/, `var APP_VERSION = '${version}';`),
  'style.css': files['style.css'] + '\n#remote-marker { position: absolute; width: 10px; height: 10px; }\n',
  'index.html': files['index.html'].replace('<div id="panel">', '<div id="remote-marker"></div>\n  <div id="panel">'),
});

test('Chromium: gerçek sayfa bilgisayardan daha yeni sürümü indirir, yeniden açılınca onunla çalışır', { skip: !browser && 'Chrome bulunamadı', timeout: 120000 }, async () => {
  const { dom, state } = await scenario('güncelleme', bump('9.9.7'));
  assert.deepEqual(state.page, { version: '9.9.7', source: 'remote' }, JSON.stringify(state));
  assert.equal(state.version, '9.9.7');
  assert.match(dom, /id="remote-marker"/);
  // Görüntü katmanı kabuğunki (içindeki işaret duruyor), panel ve altyazı öğeleri uzak gövdeden.
  assert.match(dom, /<div id="video-host"><div id="hdmi-probe"><\/div><\/div>/);
  assert.match(dom, /id="subtitle-text"/);
  assert.match(dom, /<style id="page-style">/);
  assert.doesNotMatch(dom, /<link rel="stylesheet" href="style.css">/);
  // Sayfanın i18n'i uzak koddan: panel başlığı çevrilmiş.
  assert.doesNotMatch(dom, /<span data-i18n="panelTitle"><\/span>/);
});

test('Chromium: yanlış imzalı sayfa yüklenmez, paketteki sayfa çalışmaya devam eder', { skip: !browser && 'Chrome bulunamadı', timeout: 120000 }, async () => {
  const { dom, state } = await scenario('imza', bump('9.9.8'), { signKey: 'AAAAAAAAAAAAAAAAAAAAAA' });
  assert.deepEqual(state.page, { version: shellVersion, source: 'bundled' });
  assert.equal(state.version, shellVersion);
  assert.match(state.status, /update rejected: hmac/);
  assert.doesNotMatch(dom, /id="remote-marker"/);
});

test('Chromium: açılışta hata veren uzak sayfa yedeğe düşer', { skip: !browser && 'Chrome bulunamadı', timeout: 120000 }, async () => {
  const { dom, state } = await scenario('bozuk', files => {
    const next = bump('9.9.9')(files);
    return { ...next, 'app.js': next['app.js'].replace("var SHELL_API = 1;", "var SHELL_API = 1;\n  throw new Error('açılış hatası');") };
  });
  assert.equal(state.bad, '9.9.9', JSON.stringify(state));
  assert.deepEqual(state.page, { version: shellVersion, source: 'bundled' });
  assert.equal(state.version, shellVersion);
  assert.match(state.status, /failed before/);
  assert.doesNotMatch(dom, /id="remote-marker"/);
});
