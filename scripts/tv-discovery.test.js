// SPDX-License-Identifier: AGPL-3.0-only
// TV uygulamasının (tv-webos/app.js) altyazı kaynağını ağda bulma davranışı. Sayfa sahte TV, sahte ağ ve sahte saatle
// Node'da çalıştırılır. Çalıştırma: node --test scripts/tv-discovery.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..', 'tv-webos');
const sources = ['i18n.js', 'app.js'].map((name) => ({
  name,
  code: fs.readFileSync(path.join(root, name), 'utf8')
}));

// Sahte saat: zamanlayıcılar yalnız advance() ile ilerler.
function makeClock() {
  let now = 1000000;
  let seq = 0;
  const timers = new Map();
  function add(fn, ms, repeat) {
    const id = ++seq;
    timers.set(id, { fn, at: now + Math.max(0, ms || 0), every: repeat ? Math.max(1, ms || 0) : 0 });
    return id;
  }
  return {
    now: () => now,
    setTimeout: (fn, ms) => add(fn, ms, false),
    setInterval: (fn, ms) => add(fn, ms, true),
    clearTimeout: (id) => { timers.delete(id); },
    advance(ms) {
      const end = now + ms;
      for (;;) {
        let nextId = null, next = null;
        for (const [id, t] of timers) if (t.at <= end && (!next || t.at < next.at)) { next = t; nextId = id; }
        if (!next) break;
        now = next.at;
        if (next.every) next.at += next.every; else timers.delete(nextId);
        next.fn();
      }
      now = end;
    }
  };
}

function element() {
  const el = {
    className: '', textContent: '', innerHTML: '', style: {}, offsetHeight: 0,
    classList: { add() {}, remove() {}, contains: () => false, toggle() {} },
    children: [],
    appendChild(child) { el.children.push(child); },
    removeChild(child) { el.children = el.children.filter((c) => c !== child); },
    addEventListener() {}, setAttribute() {}, getAttribute: () => null,
    getBoundingClientRect: () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 })
  };
  return el;
}

// alive: CouchSubs'ın çalıştığı adresler ("http://ip:8787"). localIp: TV'nin söylediği kendi adresi (yoksa null).
// consolePort: platform.findConsolePort'un yanıtı ([port, ad, bağlı HDMI sayısı]); savedHdmi: kayıtlı giriş.
// resolution: verilirse platform videoResolution bildirir (Samsung gibi); her çağrıda bu değer callback'e gelir.
function startTv({ saved, alive, localIp, hasLocalAddress, consolePort, savedHdmi, resolution }) {
  const clock = makeClock();
  const storage = new Map();
  if (saved) storage.set('couchsubs.server', saved);
  if (savedHdmi) storage.set('couchsubs.hdmi', String(savedHdmi));
  const documentListeners = {};
  const elements = new Map();
  const opened = [];
  const streams = [];

  class FakeEventSource {
    constructor(url) {
      this.url = url;
      this.readyState = 0;
      this.closed = false;
      this.listeners = {};
      opened.push(url);
      streams.push(this);
      this.attempt();
    }
    attempt() {
      clock.setTimeout(() => {
        if (this.closed) return;
        if (alive.has(this.url.replace(/\/events$/, ''))) {
          this.readyState = 1;
          if (this.onopen) this.onopen({});
        } else {
          // Tarayıcı kendisi birkaç saniyede bir yeniden dener; her denemede onerror gelir.
          this.readyState = 0;
          if (this.onerror) this.onerror({});
          clock.setTimeout(() => this.attempt(), 3000);
        }
      }, 50);
    }
    addEventListener(name, fn) { (this.listeners[name] = this.listeners[name] || []).push(fn); }
    close() { this.closed = true; this.readyState = 2; }
  }

  class FakeXHR {
    open(method, url) { this.url = url; }
    send() {
      const base = this.url.replace(/\/hello$/, '');
      if (alive.has(base)) {
        clock.setTimeout(() => {
          this.status = 200;
          this.responseText = '{"app":"couchsubs"}';
          this.onload();
        }, 20);
      } else {
        clock.setTimeout(() => this.ontimeout(), this.timeout || 1200);
      }
    }
  }

  const platform = {
    backKey: 461,
    init() {},
    launchParams: () => null,
    onRelaunch() {},
    // TV görüntüyü kısa süre sonra verir (Samsung TVWindow'un yanıtı gibi).
    showHdmi(port, host, onStatus) { clock.setTimeout(() => onStatus('playing'), 30); },
    findConsolePort(cb) { clock.setTimeout(() => cb.apply(null, consolePort || [1, 'PS5']), 20); }
  };
  let resolutionCallback = null;
  if (resolution !== undefined) {
    platform.videoResolution = (cb) => { resolutionCallback = cb; clock.setTimeout(() => cb(resolution), 5); };
  }
  if (hasLocalAddress) platform.localAddress = (cb) => clock.setTimeout(() => cb(localIp || null), 10);

  const document = {
    hidden: false,
    documentElement: { clientHeight: 1080, clientWidth: 1920 },
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, element());
      return elements.get(id);
    },
    querySelectorAll: () => [],
    createElement: element,
    createTextNode: () => ({}),
    addEventListener(name, fn) { (documentListeners[name] = documentListeners[name] || []).push(fn); }
  };

  const FakeDate = class extends Date {};
  FakeDate.now = clock.now;

  const window = {
    COUCHSUBS_CONFIG: {},
    COUCHSUBS_PLATFORM: platform,
    EventSource: FakeEventSource,
    localStorage: {
      getItem: (k) => (storage.has(k) ? storage.get(k) : null),
      setItem: (k, v) => storage.set(k, String(v))
    },
    innerWidth: 1920,
    innerHeight: 1080,
    getComputedStyle: () => ({ visibility: 'visible', fontSize: '40px' })
  };
  const context = {
    window, document, navigator: { language: 'tr-TR' },
    XMLHttpRequest: FakeXHR, EventSource: FakeEventSource, Date: FakeDate, Math, JSON, String, Number, Object, Array,
    setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout,
    setInterval: clock.setInterval, clearInterval: clock.clearTimeout
  };
  window.window = window;
  window.document = document;
  vm.createContext(context);
  // Sayfadaki betikler window'un özelliklerine çıplak adla da erişir (window.t gibi atamalar dahil).
  context.window = new Proxy(window, {
    set(target, key, value) { target[key] = value; context[key] = value; return true; }
  });
  for (const s of sources) vm.runInContext(s.code, context, { filename: s.name });

  return {
    clock,
    saved: () => storage.get('couchsubs.server'),
    lastOpened: () => opened[opened.length - 1],
    element: (id) => document.getElementById(id),
    // Açık bağlantıya bilgisayardan olay gelir.
    emit(name, data) {
      const source = streams[streams.length - 1];
      for (const fn of source.listeners[name] || []) fn({ data: JSON.stringify(data) });
    },
    server: () => elements.get('st-server') && elements.get('st-server').textContent,
    savedHdmi: () => storage.get('couchsubs.hdmi'),
    // TV çözünürlük değişikliği bildirir (Samsung addVideoResolutionChangeListener).
    changeResolution(info) { resolutionCallback(info); },
    // Kumanda tuşu.
    key(keyCode) {
      for (const fn of documentListeners.keydown || []) fn({ keyCode, preventDefault() {} });
    }
  };
}

test('LG: kayıtlı adres yanıt vermezse aynı ağda yeni kaynak bulunur, kayıt güncellenir', () => {
  // webOS'ta TV kendi adresini söyleyemese de kayıtlı adresin ağı taranır.
  const tv = startTv({
    saved: 'http://192.168.1.109:8787',
    alive: new Set(['http://192.168.1.42:8787']),
    hasLocalAddress: true,
    localIp: null
  });
  tv.clock.advance(60000);
  assert.strictEqual(tv.lastOpened(), 'http://192.168.1.42:8787/events');
  assert.strictEqual(tv.saved(), 'http://192.168.1.42:8787');
  assert.strictEqual(tv.server(), 'http://192.168.1.42:8787');
});

test('platform adres söyleyemiyorsa (localAddress yok) da kayıtlı adresin ağı taranır', () => {
  const tv = startTv({
    saved: 'http://192.168.1.109:8787',
    alive: new Set(['http://192.168.1.7:8787']),
    hasLocalAddress: false
  });
  tv.clock.advance(60000);
  assert.strictEqual(tv.saved(), 'http://192.168.1.7:8787');
});

test('sürekli bağlantı hatası taramayı ertelemez (zamanlayıcı her hatada baştan kurulmaz)', () => {
  const tv = startTv({
    saved: 'http://192.168.1.109:8787',
    alive: new Set(['http://192.168.1.200:8787']),
    hasLocalAddress: true,
    localIp: '192.168.1.30'
  });
  // Üç hata ~6 sn, tarama ~3 sn sonra başlar; 254 adresin taranması ~13 sn sürer.
  tv.clock.advance(30000);
  assert.strictEqual(tv.saved(), 'http://192.168.1.200:8787');
});

test('TV başka ağa geçtiyse TV\'nin kendi ağı taranır', () => {
  const tv = startTv({
    saved: 'http://192.168.1.109:8787',
    alive: new Set(['http://10.0.0.7:8787']),
    hasLocalAddress: true,
    localIp: '10.0.0.5'
  });
  tv.clock.advance(60000);
  assert.strictEqual(tv.saved(), 'http://10.0.0.7:8787');
});

test('kayıtlı adres çalışıyorsa tarama yapılmaz ve kayıt değişmez', () => {
  const tv = startTv({
    saved: 'http://192.168.1.109:8787',
    alive: new Set(['http://192.168.1.109:8787', 'http://192.168.1.2:8787']),
    hasLocalAddress: true,
    localIp: '192.168.1.30'
  });
  tv.clock.advance(120000);
  assert.strictEqual(tv.lastOpened(), 'http://192.168.1.109:8787/events');
  assert.strictEqual(tv.saved(), 'http://192.168.1.109:8787');
});

// Ek alanlar: bilgisayar köşedeki yazıların (görev, telefon) çevirisini "region" olayıyla gönderir.
test('ek alanın çevirisi kendi yerinde küçük kutuda görünür, boş metin ve region-clear kaldırır', () => {
  const tv = startTv({ saved: 'http://192.168.1.109:8787', alive: new Set(['http://192.168.1.109:8787']), hasLocalAddress: false });
  tv.clock.advance(1000);
  const host = tv.element('regions');
  tv.emit('region', { id: 'q', text: 'Demirciyi bul', box: { left: 0.7, top: 0.05, right: 0.95, bottom: 0.1 }, line: 0.03 });
  assert.strictEqual(host.children.length, 1);
  assert.strictEqual(host.className, '');
  const box = host.children[0];
  assert.strictEqual(box.textContent, 'Demirciyi bul');
  // Sağ üstteki yazı: kutu sağa ve üste yaslanır.
  assert.ok(box.style.right.endsWith('%') && box.style.left === '');
  assert.ok(box.style.top.endsWith('%') && box.style.bottom === '');
  // Aynı alanın yeni çevirisi yeni kutu açmaz.
  tv.emit('region', { id: 'q', text: 'Ahıra git', box: { left: 0.7, top: 0.05, right: 0.95, bottom: 0.1 } });
  assert.strictEqual(host.children.length, 1);
  assert.strictEqual(host.children[0].textContent, 'Ahıra git');
  tv.emit('region', { id: 'p', text: 'Neredesin?', box: { left: 0.05, top: 0.7, right: 0.3, bottom: 0.8 } });
  assert.strictEqual(host.children.length, 2);
  assert.ok(host.children[1].style.left.endsWith('%') && host.children[1].style.bottom.endsWith('%'));
  tv.emit('region', { id: 'q', text: '' });
  assert.deepStrictEqual(host.children.map((c) => c.textContent), ['Neredesin?']);
  tv.emit('region-clear', {});
  assert.strictEqual(host.children.length, 0);
  assert.strictEqual(host.className, 'hidden');
});

test('yeri bilinmeyen ya da bozuk ek alan olayı bir şey göstermez', () => {
  const tv = startTv({ saved: 'http://192.168.1.109:8787', alive: new Set(['http://192.168.1.109:8787']), hasLocalAddress: false });
  tv.clock.advance(1000);
  tv.emit('region', { id: 'q', text: 'Merhaba' });
  tv.emit('region', { text: 'Kimliksiz', box: { left: 0.1, top: 0.1, right: 0.2, bottom: 0.2 } });
  assert.strictEqual(tv.element('regions').children.length, 0);
});

// #360: Samsung girişteki cihazın adını vermez; birden çok HDMI bağlıyken TV'nin o anki girişi seçiliyordu ve bilgisayar
// da TV'ye bağlıyken uygulama Xbox yerine bilgisayarın ekranını gösteriyordu.
const tr = { title: 'Konsol hangi HDMI girişinde?' };

test('birden çok HDMI bağlıyken tahmin edilen giriş kullanıcıya sorulur, görüntü gelince kutu kapanmaz', () => {
  const tv = startTv({ alive: new Set(), hasLocalAddress: false, consolePort: [2, 'HDMI 2', 2] });
  tv.clock.advance(1000);
  assert.strictEqual(tv.element('no-picture').className, '');
  assert.strictEqual(tv.element('no-picture-title').textContent, tr.title);
  assert.match(tv.element('no-picture-text').textContent, /HDMI 2 açıldı/);
  // "Hâlâ siyah mı" açıklaması bu kutuda gösterilmez.
  assert.strictEqual(tv.element('no-picture-help').style.display, 'none');
  // Açık olandan sonraki giriş (HDMI 3) seçili gelir; Tamam ile seçilir ve kaydedilir.
  tv.element('source-tip').className = 'hidden';
  tv.key(13);
  assert.strictEqual(tv.savedHdmi(), '3');
  assert.strictEqual(tv.element('no-picture').className, 'hidden');
});

test('birden çok HDMI bağlı ve konsol bulunamadıysa da giriş sorulur', () => {
  const tv = startTv({ alive: new Set(), hasLocalAddress: false, consolePort: [null, null, 3] });
  tv.clock.advance(1000);
  assert.strictEqual(tv.element('no-picture').className, '');
  assert.strictEqual(tv.element('no-picture-title').textContent, tr.title);
});

test('tek HDMI bağlıyken ya da platform sayı bildirmezken giriş sorulmaz', () => {
  for (const consolePort of [[1, 'HDMI 1', 1], [3, 'PS5']]) {
    const tv = startTv({ alive: new Set(), hasLocalAddress: false, consolePort });
    tv.clock.advance(1000);
    assert.notStrictEqual(tv.element('no-picture').className, '');
  }
});

test('kayıtlı giriş varsa konsol aranmaz, giriş sorulmaz', () => {
  const tv = startTv({ alive: new Set(), hasLocalAddress: false, consolePort: [2, 'HDMI 2', 2], savedHdmi: 3 });
  tv.clock.advance(1000);
  assert.notStrictEqual(tv.element('no-picture').className, '');
});

test('0 tuşu kaydı unutup konsolu yeniden arar; birden çok HDMI bağlıysa giriş sorulur', () => {
  const tv = startTv({ alive: new Set(), hasLocalAddress: false, consolePort: [2, 'HDMI 2', 2], savedHdmi: 3 });
  tv.clock.advance(1000);
  tv.key(48);
  tv.clock.advance(1000);
  assert.strictEqual(tv.element('no-picture').className, '');
  // Sayı tuşuyla seçim kutuyu kapatır.
  tv.key(50);
  assert.strictEqual(tv.savedHdmi(), '2');
  assert.strictEqual(tv.element('no-picture').className, 'hidden');
});

// Samsung uygulama içinde PS5 görüntüsünü 1080p'ye düşürüyor mu: panel TV'nin bildirdiği çözünürlüğü gösterir.
test('Samsung: panelde HDMI görüntüsünün çözünürlüğü ve yenileme hızı görünür, değişince güncellenir', () => {
  const tv = startTv({ alive: new Set(), hasLocalAddress: false, savedHdmi: 1,
    resolution: { width: 3840, height: 2160, frequency: 60, aspectRatio: '16x9' } });
  tv.clock.advance(1000);
  assert.strictEqual(tv.element('row-resolution').style.display, '');
  assert.strictEqual(tv.element('st-resolution').textContent, '3840×2160 · 60 Hz');
  tv.changeResolution({ width: 1920, height: 1080, frequency: 59.94 });
  assert.strictEqual(tv.element('st-resolution').textContent, '1920×1080 · 59.94 Hz');
  tv.changeResolution({ width: 1920, height: 1080 });
  assert.strictEqual(tv.element('st-resolution').textContent, '1920×1080');
});

test('çözünürlük bildirmeyen ya da hata veren platformda satır gizli kalır', () => {
  for (const resolution of [undefined, null, { width: 0, height: 0, frequency: 0 }]) {
    const tv = startTv({ alive: new Set(), hasLocalAddress: false, savedHdmi: 1, resolution });
    tv.clock.advance(1000);
    assert.notStrictEqual(tv.element('row-resolution').style.display, '');
  }
});

// tv-tizen/platform.js: TVWindow API'si sahte tizen nesnesiyle çalıştırılır.
function tizenPlatform(tvwindow) {
  const context = { window: {}, tizen: { tvwindow }, JSON };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'tv-tizen', 'platform.js'), 'utf8'), context);
  return context.window.COUCHSUBS_PLATFORM;
}

test('Tizen: getVideoResolution değeri iletilir, değişiklik dinleyicisi bir kez kurulur', () => {
  let listeners = 0, change = null;
  const platform = tizenPlatform({
    getVideoResolution(ok) { ok({ width: 1920, height: 1080, frequency: 60 }); },
    addVideoResolutionChangeListener(fn) { listeners++; change = fn; return listeners; }
  });
  const seen = [];
  platform.videoResolution((info) => seen.push(info && info.width));
  platform.videoResolution((info) => seen.push(info && info.width));
  change({ width: 3840, height: 2160, frequency: 60 });
  assert.deepStrictEqual(seen, [1920, 1920, 3840]);
  assert.strictEqual(listeners, 1);
});

test('Tizen: TVWindow API yoksa ya da hata verirse çözünürlük null gelir, hata fırlatılmaz', () => {
  for (const tvwindow of [{}, { getVideoResolution(ok, fail) { fail(new Error('x')); } }]) {
    const seen = [];
    tizenPlatform(tvwindow).videoResolution((info) => seen.push(info));
    assert.deepStrictEqual(seen, [null]);
  }
});
