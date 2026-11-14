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
    appendChild() {}, removeChild() {}, addEventListener() {}, setAttribute() {}, getAttribute: () => null,
    getBoundingClientRect: () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 })
  };
  return el;
}

// alive: CouchSubs'ın çalıştığı adresler ("http://ip:8787"). localIp: TV'nin söylediği kendi adresi (yoksa null).
function startTv({ saved, alive, localIp, hasLocalAddress }) {
  const clock = makeClock();
  const storage = new Map();
  if (saved) storage.set('couchsubs.server', saved);
  const elements = new Map();
  const opened = [];

  class FakeEventSource {
    constructor(url) {
      this.url = url;
      this.readyState = 0;
      this.closed = false;
      opened.push(url);
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
    addEventListener() {}
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
    showHdmi() {},
    findConsolePort(cb) { cb(1, 'PS5'); }
  };
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
    addEventListener() {}
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
    server: () => elements.get('st-server') && elements.get('st-server').textContent
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
