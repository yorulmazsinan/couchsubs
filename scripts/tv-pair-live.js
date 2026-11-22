// SPDX-License-Identifier: AGPL-3.0-only
// TV uygulamasını (tv-webos/app.js) gerçek ağ üzerinden gerçek bir altyazı sunucusuna (Mac/iPhone SubtitleServer,
// Windows, Android) bağlar: eşleştirme isteği, onay ve altyazı akışı uçtan uca denenir (GitHub #737).
//
// Kullanım: node scripts/tv-pair-live.js <sunucu adresi> [app.js klasörü] [saniye]
//   Ortam: TV_ORIGIN (varsayılan "null": webOS'un paketli uygulaması), TV_KEY (TV'de kayıtlı anahtar),
//          TV_PARAMS (başlatma parametreleri JSON).
// Çıktı: her satır "olay: ..."; akış açılırsa "STREAM_OPEN", eşleştirme başarısızsa "PAIR_FAILED" yazılır ve çıkılır
// (0: akış açıldı, 2: eşleştirme tamamlanmadı, 3: süre doldu).
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const http = require('node:http');

const server = (process.argv[2] || '').replace(/\/+$/, '');
const dir = process.argv[3] || path.join(__dirname, '..', 'tv-webos');
const seconds = Number(process.argv[4] || 30);
const origin = process.env.TV_ORIGIN === undefined ? 'null' : process.env.TV_ORIGIN;
if (!server) { console.error('sunucu adresi gerekli'); process.exit(64); }

function log(line) { process.stdout.write(line + '\n'); }

// Tarayıcının XMLHttpRequest'i kadarı: yöntem, adres, zaman aşımı, durum, yanıt metni. Paketli TV uygulamasının
// gönderdiği Origin başlığı da gönderilir.
class LiveXHR {
  open(method, url) { this.method = method; this.url = url; this.status = 0; this.responseText = ''; }
  send(body) {
    const headers = origin ? { Origin: origin } : {};
    if (this.method === 'POST') headers['Content-Length'] = body ? Buffer.byteLength(body) : 0;
    let done = false;
    const finish = (fn) => { if (!done) { done = true; fn(); } };
    const req = http.request(this.url, { method: this.method, headers }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { text += chunk; });
      res.on('end', () => finish(() => {
        this.status = res.statusCode;
        this.responseText = text;
        log('xhr: ' + this.method + ' ' + new URL(this.url).pathname + new URL(this.url).search.replace(/k=[^&]+/, 'k=…') + ' -> ' + res.statusCode + ' ' + text.slice(0, 120));
        if (this.onload) this.onload();
      }));
    });
    req.on('error', (err) => finish(() => { log('xhr: ' + this.method + ' ' + this.url + ' HATA ' + err.message); if (this.onerror) this.onerror(err); }));
    if (this.timeout) req.setTimeout(this.timeout, () => { req.destroy(); finish(() => { log('xhr: zaman aşımı ' + this.url); if (this.ontimeout) this.ontimeout(); }); });
    req.end(body || undefined);
  }
}

// EventSource kadarı: açılınca onopen, adlı olaylar, kopunca onerror (tarayıcı gibi kendisi yeniden denemez; app.js
// zaten kendisi yeniden bağlanır).
class LiveEventSource {
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.listeners = {};
    const headers = origin ? { Origin: origin, Accept: 'text/event-stream' } : { Accept: 'text/event-stream' };
    this.req = http.get(url, { headers }, (res) => {
      log('events: ' + res.statusCode);
      if (res.statusCode !== 200) { this.readyState = 2; res.resume(); if (this.onerror) this.onerror({}); return; }
      this.readyState = 1;
      log('STREAM_OPEN');
      if (this.onopen) this.onopen({});
      let buffer = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        buffer += chunk;
        let at;
        while ((at = buffer.indexOf('\n\n')) >= 0) {
          const frame = buffer.slice(0, at); buffer = buffer.slice(at + 2);
          let name = 'message', data = '';
          for (const line of frame.split('\n')) {
            if (line.startsWith('event:')) name = line.slice(6).trim();
            else if (line.startsWith('data:')) data += line.slice(5).trim();
          }
          if (data) { log('event: ' + name + ' ' + data.slice(0, 120)); for (const fn of this.listeners[name] || []) fn({ data }); }
        }
      });
      res.on('end', () => { this.readyState = 2; if (this.onerror) this.onerror({}); });
    });
    this.req.on('error', () => { this.readyState = 2; if (this.onerror) this.onerror({}); });
  }
  addEventListener(name, fn) { (this.listeners[name] = this.listeners[name] || []).push(fn); }
  close() { this.readyState = 2; this.req.destroy(); }
}

function element(id) {
  const el = {
    id, className: '', _text: '', innerHTML: '', style: {}, offsetHeight: 0, offsetWidth: 0, value: '',
    classList: { add() {}, remove() {}, contains: () => false, toggle() {} },
    children: [], childNodes: [], firstChild: null,
    appendChild(child) { el.children.push(child); return child; },
    insertBefore(child) { el.children.push(child); return child; },
    removeChild(child) { el.children = el.children.filter((c) => c !== child); },
    addEventListener() {}, removeEventListener() {}, setAttribute() {}, getAttribute: () => null, removeAttribute() {},
    play() { return { catch() {} }; }, pause() {}, load() {}, focus() {}, querySelector: () => null, querySelectorAll: () => [],
    getBoundingClientRect: () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 })
  };
  Object.defineProperty(el, 'textContent', {
    get() { return el._text; },
    set(value) {
      value = String(value);
      if ((id === 'pairing' || id === 'st-conn') && value !== el._text && value) log('ekran ' + id + ': ' + value);
      el._text = value;
    }
  });
  return el;
}

const storage = new Map();
if (process.env.TV_KEY) storage.set('couchsubs.keys', JSON.stringify({ [server]: process.env.TV_KEY }));
storage.set('couchsubs.server', server);
const elements = new Map();
for (const id of ['panel-tip', 'source-tip', 'no-picture', 'pairing']) elements.set(id, Object.assign(element(id), { className: 'hidden' }));
const documentListeners = {};
const document = {
  hidden: false,
  documentElement: { clientHeight: 1080, clientWidth: 1920 },
  body: element('body'),
  getElementById(id) { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); },
  querySelector: () => null,
  querySelectorAll: () => [],
  createElement: () => element(''),
  createTextNode: () => ({}),
  addEventListener(name, fn) { (documentListeners[name] = documentListeners[name] || []).push(fn); }
};
const platform = {
  backKey: 461,
  init() {},
  exit() { log('exit'); },
  launchParams: () => process.env.TV_PARAMS || null,
  onRelaunch() {},
  showHdmi(port, host, onStatus) { setTimeout(() => onStatus('playing'), 10); },
  findConsolePort(cb) { setTimeout(() => cb(1, 'PS5'), 10); }
};
const window = {
  COUCHSUBS_CONFIG: {},
  COUCHSUBS_PLATFORM: platform,
  EventSource: LiveEventSource,
  localStorage: { getItem: (k) => (storage.has(k) ? storage.get(k) : null), setItem: (k, v) => storage.set(k, String(v)), removeItem: (k) => storage.delete(k) },
  innerWidth: 1920,
  innerHeight: 1080,
  location: { href: 'file:///media/developer/apps/usr/palm/applications/com.couchsubs.tv/index.html', search: '' },
  getComputedStyle: () => ({ visibility: 'visible', fontSize: '40px' }),
  addEventListener() {},
  requestAnimationFrame: (fn) => setTimeout(fn, 16)
};
const context = {
  window, document, navigator: { language: 'tr-TR', userAgent: 'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 Chrome/38.0.2125.122 Safari/537.36' },
  XMLHttpRequest: LiveXHR, EventSource: LiveEventSource, Date, Math, JSON, String, Number, Object, Array, console,
  setTimeout, clearTimeout, setInterval, clearInterval, Image: function () { return element('img'); }
};
window.window = window;
window.document = document;
vm.createContext(context);
context.window = new Proxy(window, { set(target, key, value) { target[key] = value; context[key] = value; return true; } });

// Eşleştirme başarısız: TV'de "Eşleştirme tamamlanmadı" (pairRetry) yazısı çıktı. TV_AFTER_FAIL_MS verilirse o kadar
// daha beklenir (TV kendiliğinden yeni istek gönderiyor mu).
const afterFail = Number(process.env.TV_AFTER_FAIL_MS || 0);
const pairing = document.getElementById('pairing');
const timer = setInterval(() => {
  if (!/tamamlanmadı|did not finish/.test(pairing.textContent)) return;
  log('PAIR_FAILED');
  clearInterval(timer);
  setTimeout(() => process.exit(2), afterFail);
}, 50);
setTimeout(() => { log('TIMEOUT'); process.exit(3); }, seconds * 1000);
process.stdout.on('error', () => {});
for (const name of ['i18n.js', 'app.js']) vm.runInContext(fs.readFileSync(path.join(dir, name), 'utf8'), context, { filename: name });
// Akış açılınca başarı: biraz bekle (ilk olaylar) ve çık.
const check = setInterval(() => {
  const conn = document.getElementById('st-conn').textContent;
  if (/^(bağlı|connected)$/i.test(conn)) { log('CONNECTED'); clearInterval(check); clearInterval(timer); setTimeout(() => process.exit(0), 300); }
}, 50);
