// SPDX-License-Identifier: AGPL-3.0-only
// Android TV uygulamasının sayfası (tv-webos/i18n.js, tv-android/platform.js, tv-webos/app.js) Node'da, gerçek ağla:
// gerçek bir CouchSubs sunucusuna (Windows C#, Mac/iPhone Swift, Android telefon Kotlin) bağlanır, gelen olayları
// sayfanın kendi koduyla işler. Uçtan uca testlerde kullanılır: sunucuyu başlatan test bu betiği alt süreç olarak açar,
// altyazı gönderir ve panelin tanı satırını ("sub 1 · ...") bekler.
//
// Ortam Android 8'in WebView'ine (Chrome 58) göre kısıtlanır: Chrome 58'de olmayan yerleşik işlevler sayfa açılmadan
// silinir; sayfa onları korumasız çağırırsa hata tanı satırına ("err ...") düşer.
//
// Çalıştırma: node scripts/tv-live-page.js http://127.0.0.1:8787 <anahtar>
// Çıktı (satır satır): "status <bağlantı yazısı>", "diag <tanı satırı>", "shown <ekrandaki altyazı>", "exit".
// Standart girdi kapanınca ya da 60 sn sonra çıkar.
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const vm = require('node:vm');

// COUCHSUBS_TV_ROOT: başka bir sürümün klasörü (eski TV uygulamasını yeni sunucuyla denemek için; git archive ile çıkarılır).
const root = process.env.COUCHSUBS_TV_ROOT || path.join(__dirname, '..');
const SOURCES = ['tv-webos/i18n.js', 'tv-android/platform.js', 'tv-webos/app.js'];

// Android 8.0'ın WebView'i Chrome 58'dir (Play'den güncellenmeyen TV'lerde öyle kalır). Bunlar Chrome 59 ve sonrasında geldi.
const NEWER_THAN_CHROME_58 = [
  'Array.prototype.flat', 'Array.prototype.flatMap', 'Array.prototype.at', 'Object.fromEntries',
  'String.prototype.trimStart', 'String.prototype.trimEnd', 'String.prototype.replaceAll', 'String.prototype.matchAll',
  'String.prototype.at', 'Promise.prototype.finally', 'Promise.allSettled', 'Promise.any', 'globalThis.structuredClone',
  'globalThis.queueMicrotask', 'globalThis.AbortController', 'globalThis.ResizeObserver', 'globalThis.globalThis'
];

function element(id) {
  const el = {
    id, className: '', textContent: '', innerHTML: '', value: '', style: {}, offsetHeight: 0, offsetWidth: 0,
    scrollHeight: 0, scrollWidth: 0, clientHeight: 0, clientWidth: 0, children: [], childNodes: [], dataset: {},
    classList: { add() {}, remove() {}, contains: () => false, toggle() {} },
    appendChild(child) { el.children.push(child); el.childNodes.push(child); return child; },
    insertBefore(child) { el.children.push(child); el.childNodes.push(child); return child; },
    removeChild(child) { el.children = el.children.filter((c) => c !== child); el.childNodes = el.children.slice(); return child; },
    replaceChild(child) { return child; },
    addEventListener() {}, removeEventListener() {}, setAttribute() {}, getAttribute: () => null, removeAttribute() {},
    focus() {}, blur() {}, querySelector: () => null, querySelectorAll: () => [],
    getBoundingClientRect: () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }),
    getContext: () => ({ font: '', measureText: (text) => ({ width: String(text).length * 20 }) })
  };
  Object.defineProperty(el, 'firstChild', { get: () => el.children[0] || null });
  Object.defineProperty(el, 'lastChild', { get: () => el.children[el.children.length - 1] || null });
  return el;
}

// Tarayıcının EventSource'u kadarı: adlı olaylar, retry, kopunca yeniden bağlanma, readyState.
class NodeEventSource {
  constructor(url) {
    this.url = String(url);
    this.readyState = 0;
    this.listeners = {};
    this.retry = 3000;
    this.closed = false;
    this.connect();
  }
  connect() {
    if (this.closed) return;
    const request = http.get(this.url, { headers: { Accept: 'text/event-stream' } }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        this.fail(true);
        return;
      }
      this.readyState = 1;
      this.fire('open', {});
      let buffer = '';
      let name = '';
      let data = [];
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        buffer += chunk;
        let end;
        while ((end = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, end).replace(/\r$/, '');
          buffer = buffer.slice(end + 1);
          if (line === '') {
            if (data.length) this.fire(name || 'message', { data: data.join('\n') });
            name = '';
            data = [];
          } else if (line.charAt(0) === ':') {
            // yorum
          } else {
            const colon = line.indexOf(':');
            const field = colon < 0 ? line : line.slice(0, colon);
            const value = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '');
            if (field === 'event') name = value;
            else if (field === 'data') data.push(value);
            else if (field === 'retry' && /^\d+$/.test(value)) this.retry = Number(value);
          }
        }
      });
      response.on('end', () => this.fail(false));
      response.on('error', () => this.fail(false));
    });
    request.on('error', () => this.fail(false));
    this.request = request;
  }
  fail(fatal) {
    if (this.closed) return;
    this.readyState = fatal ? 2 : 0;
    this.fire('error', {});
    if (!fatal) setTimeout(() => this.connect(), this.retry);
  }
  fire(name, event) {
    if (this.closed) return;
    const handler = this['on' + name];
    if (typeof handler === 'function') handler.call(this, event);
    for (const fn of (this.listeners[name] || []).slice()) fn.call(this, event);
  }
  addEventListener(name, fn) { (this.listeners[name] = this.listeners[name] || []).push(fn); }
  removeEventListener(name, fn) { this.listeners[name] = (this.listeners[name] || []).filter((f) => f !== fn); }
  close() {
    this.closed = true;
    this.readyState = 2;
    if (this.request) this.request.destroy();
  }
}
NodeEventSource.prototype.CONNECTING = 0;
NodeEventSource.prototype.OPEN = 1;
NodeEventSource.prototype.CLOSED = 2;

class NodeXHR {
  open(method, url) { this.method = method; this.url = url; this.status = 0; this.responseText = ''; }
  setRequestHeader() {}
  abort() { if (this.request) this.request.destroy(); }
  send() {
    const request = http.request(this.url, { method: this.method }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => {
        this.status = response.statusCode;
        this.responseText = body;
        this.response = body;
        if (this.onload) this.onload();
      });
    });
    if (this.timeout) request.setTimeout(this.timeout, () => { request.destroy(); if (this.ontimeout) this.ontimeout(); });
    request.on('error', () => { if (this.onerror) this.onerror(); });
    request.end();
    this.request = request;
  }
}

/**
 * Sayfayı açar. options: server (adres), key (erişim anahtarı), port (HDMI girişi), android8 (yerleşikleri kısıtla).
 * storage: başlangıçtaki localStorage
 * (eski kurulumun kalıntısı). params: başlatma parametreleri (null: parametresiz). Dönen nesne: element(id), diag(),
 * status(), shown(), stored(), relaunch(params), close().
 */
function startPage(options) {
  const elements = new Map();
  for (const id of ['panel', 'panel-tip', 'source-tip', 'no-picture', 'subtitle', 'waiting', 'pairing']) {
    elements.set(id, Object.assign(element(id), { className: 'hidden' }));
  }
  const storage = new Map(Object.entries(options.storage || {}));
  const sources = [];
  class TrackedSource extends NodeEventSource {
    constructor(url) { super(url); sources.push(this); }
  }
  const documentListeners = {};
  const shownPorts = [];
  const bridge = {
    // params: null ise uygulama kumandadan açıldı (parametresiz; kayıtlı adrese bağlanır).
    launchParams: () => (options.params === null ? '' : JSON.stringify(options.params || { server: options.server, key: options.key })),
    showHdmi(port) { shownPorts.push(port); },
    consolePort: () => options.port || 1,
    pickPort: () => (options.port || 1) + ':console',
    chooseInput() {},
    forgetInput() {},
    localAddress: () => '',
    exit() {},
    isOverlay: () => false,
    setDisplayMode() {},
    diagnostics: () => 'mode inApp · tv available · Philips 55PUS7303 · Android 8.0.0 (26)',
    appVersion: () => '',
    // options.events: uygulama tarafının (MainActivity, TvEvents) bekleyen olay satırları; sayfa alınca boşalır.
    takeEvents: () => (options.events ? options.events.splice(0).join('\n') : '')
  };
  const document = {
    hidden: false,
    documentElement: { clientHeight: 1080, clientWidth: 1920, style: {} },
    head: element('head'),
    body: element('body'),
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, element(id));
      return elements.get(id);
    },
    querySelector: () => null,
    querySelectorAll: () => [],
    createElement: (tag) => element(tag),
    createTextNode: (text) => ({ textContent: String(text), nodeValue: String(text) }),
    addEventListener(name, fn) { (documentListeners[name] = documentListeners[name] || []).push(fn); },
    removeEventListener() {},
    dispatchEvent(event) { for (const fn of documentListeners[event.type] || []) fn(event); return true; }
  };
  const timers = new Set();
  const track = (fn) => (cb, ms) => { const id = fn(cb, ms); timers.add(id); return id; };
  const window = {
    AndroidTV: bridge,
    COUCHSUBS_CONFIG: {},
    EventSource: TrackedSource,
    Audio: function Audio() { return { play() {}, pause() {}, load() {}, addEventListener() {} }; },
    localStorage: {
      getItem: (k) => (storage.has(k) ? storage.get(k) : null),
      setItem: (k, v) => storage.set(k, String(v)),
      removeItem: (k) => storage.delete(k)
    },
    navigator: { language: 'tr-TR', userAgent: 'Mozilla/5.0 (Linux; Android 8.0.0) Chrome/58.0.3029.125 Safari/537.36' },
    location: { href: 'file:///android_asset/tv/index.html', protocol: 'file:' },
    innerWidth: 1920,
    innerHeight: 1080,
    devicePixelRatio: 1,
    getComputedStyle: () => ({ visibility: 'visible', fontSize: '46px', fontWeight: '400', fontFamily: 'sans-serif',
      lineHeight: '56px', paddingTop: '0px', paddingBottom: '0px', paddingLeft: '0px', paddingRight: '0px' }),
    addEventListener() {},
    removeEventListener() {},
    requestAnimationFrame: undefined
  };
  const context = {
    window, document, navigator: window.navigator, location: window.location, localStorage: window.localStorage,
    XMLHttpRequest: NodeXHR, EventSource: TrackedSource,
    Event: function Event(type) { this.type = type; },
    setTimeout: track(setTimeout), clearTimeout, setInterval: track(setInterval), clearInterval, console
  };
  window.window = window;
  window.document = document;
  window.XMLHttpRequest = NodeXHR;
  vm.createContext(context);
  if (options.android8) {
    vm.runInContext(NEWER_THAN_CHROME_58.map((name) => 'try { delete ' + name + '; } catch (e) {}').join('\n'), context);
  }
  // Sayfadaki betikler window'un özelliklerine çıplak adla da erişir (window.t gibi atamalar dahil).
  context.window = new Proxy(window, {
    set(target, key, value) { target[key] = value; context[key] = value; return true; },
    get(target, key) { return key in target ? target[key] : context[key]; }
  });
  for (const [key, value] of Object.entries(window)) if (!(key in context)) context[key] = value;
  // options.root: başka bir sürümün klasörü (eski TV uygulaması; git archive ile çıkarılır). Yoksa COUCHSUBS_TV_ROOT ya da bu depo.
  for (const name of SOURCES) {
    vm.runInContext(fs.readFileSync(path.join(options.root || root, name), 'utf8'), context, { filename: name });
  }
  const text = (id) => document.getElementById(id).textContent;
  return {
    element: (id) => document.getElementById(id),
    diag: () => text('st-diag'),
    status: () => text('st-conn'),
    shown: () => (elements.get('subtitle').className === 'hidden' ? '' : rawText(document.getElementById('subtitle-text'))),
    shownPorts: () => shownPorts.slice(),
    stored: (key) => storage.get('couchsubs.' + key),
    // Bilgisayar/telefon çalışan uygulamaya adresini bildirdi (am start'ın onNewIntent'i ya da AddressReceiver yayını).
    relaunch: (params) => context.window.__onRelaunch(JSON.stringify(params)),
    // Sayfanın TV olay günlüğüne satır yazar (platform.js'lerin yaptığı gibi).
    tvLog: (text) => context.window.COUCHSUBS_TVLOG(text),
    close() {
      for (const id of timers) { clearTimeout(id); clearInterval(id); }
      for (const source of sources) source.close();
    }
  };
}

function rawText(el) {
  if (el.rawText !== undefined) return String(el.rawText);
  return el.textContent || '';
}

module.exports = { startPage, NodeEventSource, NEWER_THAN_CHROME_58 };

if (require.main === module) {
  const [server, key] = process.argv.slice(2);
  const page = startPage({ server, key, port: 2, android8: true });
  const last = {};
  const report = () => {
    for (const [name, value] of [['status', page.status()], ['diag', page.diag()], ['shown', page.shown()]]) {
      if (value !== last[name]) {
        last[name] = value;
        process.stdout.write(name + ' ' + String(value).replace(/\n/g, ' / ') + '\n');
      }
    }
  };
  const ticker = setInterval(report, 50);
  const finish = () => {
    clearInterval(ticker);
    report();
    process.stdout.write('exit\n');
    process.exit(0);
  };
  process.stdin.on('end', finish);
  process.stdin.on('close', finish);
  process.stdin.resume();
  setTimeout(finish, 60000).unref();
}
