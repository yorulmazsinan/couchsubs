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
// closeWhenHidden: platform arka planda bağlantıyı bırakmak istiyor mu (Samsung gibi).
// panelTips: panel ipucunun önceki açılışlarda kaç kez gösterildiği.
// hello: adrese göre /hello yanıtındaki kimlik ve bağlı TV sayısı ({ id, tvs }); verilmeyen adres eski sürüm gibi yalnız
// {"app":"couchsubs"} döner. savedId: TV'nin kayıtlı CouchSubs kimliği. params: başlatma parametreleri.
// auth: sunucunun eşleştirme durumu; storedKeys/identities: TV'de kayıtlı anahtarlar ve sunucu kimlikleri.
function startTv({ saved, alive, localIp, hasLocalAddress, consolePort, savedHdmi, resolution, closeWhenHidden, panelTips, hello, savedId, params,
                   auth = null, storedKeys = null, identities = null }) {
  const clock = makeClock();
  const storage = new Map();
  if (saved) storage.set('couchsubs.server', saved);
  if (savedId) storage.set('couchsubs.serverId', savedId);
  if (savedHdmi) storage.set('couchsubs.hdmi', String(savedHdmi));
  if (panelTips !== undefined) storage.set('couchsubs.panelTips', String(panelTips));
  if (storedKeys) storage.set('couchsubs.keys', JSON.stringify(storedKeys));
  if (identities) storage.set('couchsubs.server-identities', JSON.stringify(identities));
  const documentListeners = {};
  const requests = [];
  const elements = new Map();
  // index.html'de gizli başlayan öğeler.
  for (const id of ['panel-tip', 'source-tip', 'no-picture']) elements.set(id, Object.assign(element(), { className: 'hidden' }));
  let exits = 0;
  const opened = [];
  const streams = [];
  let relaunchCallback = null;

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
        const target = new URL(this.url);
        if (alive.has(target.origin) && (!auth || target.searchParams.get('k') === auth.key)) {
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

  const probes = [];
  class FakeXHR {
    open(method, url) { this.url = url; this.method = method; requests.push({ method, url }); }
    send() {
      probes.push(this.url);
      const target = new URL(this.url);
      const base = target.origin;
      if (alive.has(base)) {
        clock.setTimeout(() => {
          this.status = 200;
          let data = Object.assign({ app: 'couchsubs' }, (hello || {})[base]);
          if (auth && target.pathname === '/hello') data = Object.assign(data, { auth: 1, id: auth.id });
          if (auth && target.pathname === '/pair') {
            if (this.method === 'POST') {
              if (auth.reject) { this.status = 409; data = {}; }
              else data = { id: 'abcdefghijklmnopqrstuv', code: '123456' };
            } else if (target.searchParams.has('validate')) data = { state: target.searchParams.get('k') === auth.key ? 'valid' : 'expired' };
            else if (auth.expired) data = { state: 'expired' };
            else data = auth.approved ? { state: 'approved', key: auth.key } : { state: 'pending' };
          }
          this.responseText = JSON.stringify(data);
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
    exit() { exits++; },
    launchParams: () => params || null,
    onRelaunch(cb) { relaunchCallback = cb; },
    // TV görüntüyü kısa süre sonra verir (Samsung TVWindow'un yanıtı gibi).
    showHdmi(port, host, onStatus) { clock.setTimeout(() => onStatus('playing'), 30); },
    findConsolePort(cb) { clock.setTimeout(() => cb.apply(null, consolePort || [1, 'PS5']), 20); }
  };
  let resolutionCallback = null;
  if (resolution !== undefined) {
    platform.videoResolution = (cb) => { resolutionCallback = cb; clock.setTimeout(() => cb(resolution), 5); };
  }
  if (hasLocalAddress) platform.localAddress = (cb) => clock.setTimeout(() => cb(localIp || null), 10);
  if (closeWhenHidden) platform.closeWhenHidden = true;

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
    requests,
    storage,
    failStream: () => streams[streams.length - 1].onerror({}),
    lastOpened: () => opened[opened.length - 1],
    element: (id) => document.getElementById(id),
    // Açık bağlantıya bilgisayardan olay gelir.
    emit(name, data) {
      const source = streams[streams.length - 1];
      for (const fn of source.listeners[name] || []) fn({ data: JSON.stringify(data) });
    },
    server: () => elements.get('st-server') && elements.get('st-server').textContent,
    savedHdmi: () => storage.get('couchsubs.hdmi'),
    stored: (key) => storage.get('couchsubs.' + key),
    // Sorulan /hello adresleri (tarama ve kimlik sorusu).
    probed: () => probes.slice(),
    exits: () => exits,
    pickServer: (found, savedId) => window.__pickServer(found, savedId),
    // Bilgisayar açık uygulamayı yeniden açar (Samsung DEEP_LINK, parametreler PAYLOAD'da).
    relaunch(params) { relaunchCallback(params); },
    // Açık (kapatılmamış) bağlantılar.
    openStreams: () => streams.filter((s) => !s.closed),
    // TV uygulamayı arka plana atar ya da öne getirir.
    setHidden(hidden) {
      document.hidden = hidden;
      for (const fn of documentListeners.visibilitychange || []) fn({});
    },
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

// #469, #484: telefondan kurulan TV'de kayıtlı adres yoktur; TV kendi adresini de söyleyemezse eskiden hiçbir adres
// denenmiyor, TV "Ağda CouchSubs aranıyor…" ekranında kalıyordu.
test('kayıtlı adres yok ve TV adresini söyleyemiyorsa yaygın ev ağları taranır, telefon bulunur', () => {
  const phone = 'http://192.168.0.34:8787';
  const tv = startTv({
    alive: new Set([phone]), hello: { [phone]: { id: 'phone', tvs: 0 } },
    hasLocalAddress: true, localIp: null
  });
  tv.clock.advance(60000);
  assert.strictEqual(tv.lastOpened(), phone + '/events');
  assert.strictEqual(tv.saved(), phone);
  assert.strictEqual(tv.stored('serverId'), 'phone');
});

test('platform adres sormayı hiç bilmiyorsa (localAddress yok) ve kayıt yoksa da ev ağları taranır', () => {
  const phone = 'http://10.0.0.12:8787';
  const tv = startTv({ alive: new Set([phone]), hasLocalAddress: false });
  tv.clock.advance(90000);
  assert.strictEqual(tv.saved(), phone);
});

test('tahminli taramada CouchSubs bulunan ağda durulur, sonraki ağlar denenmez', () => {
  const phone = 'http://192.168.1.77:8787';
  const later = 'http://192.168.0.5:8787';
  const tv = startTv({ alive: new Set([phone, later]), hasLocalAddress: true, localIp: null });
  tv.clock.advance(60000);
  assert.strictEqual(tv.lastOpened(), phone + '/events');
  assert.ok(!tv.probed().some((url) => url.startsWith('http://192.168.0.')));
});

test('tahminli tarama sürerken telefon adresini başlatma parametresiyle verirse ona bağlı kalınır', () => {
  const phone = 'http://192.168.100.9:8787';
  const other = 'http://192.168.100.20:8787';
  const tv = startTv({
    alive: new Set([phone, other]), hello: { [phone]: { id: 'phone', tvs: 0 }, [other]: { id: 'other', tvs: 0 } },
    hasLocalAddress: true, localIp: null
  });
  tv.clock.advance(5000);
  tv.relaunch(JSON.stringify({ server: phone }));
  tv.clock.advance(180000);
  assert.strictEqual(tv.lastOpened(), phone + '/events');
  assert.strictEqual(tv.stored('serverId'), 'phone');
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

// GitHub #425: aynı ağda iki CouchSubs (iki bilgisayar/telefon) varken TV ilk yanıt verene bağlanıyordu.
const A = 'http://192.168.1.20:8787';
const B = 'http://192.168.1.50:8787';

test('iki CouchSubs varken kayıtlı kimlik ilk bulunandan önce gelir', () => {
  const tv = startTv({
    saved: 'http://192.168.1.109:8787', savedId: 'id-b',
    alive: new Set([A, B]), hello: { [A]: { id: 'id-a', tvs: 0 }, [B]: { id: 'id-b', tvs: 0 } },
    hasLocalAddress: true, localIp: '192.168.1.30'
  });
  tv.clock.advance(60000);
  assert.strictEqual(tv.lastOpened(), B + '/events');
  assert.strictEqual(tv.saved(), B);
});

test('ilk kez açılan TV, başka TV\'ye hizmet eden CouchSubs yerine boşta olana bağlanır ve kimliğini kaydeder', () => {
  const tv = startTv({
    alive: new Set([A, B]), hello: { [A]: { id: 'id-a', tvs: 1 }, [B]: { id: 'id-b', tvs: 0 } },
    hasLocalAddress: true, localIp: '192.168.1.30'
  });
  tv.clock.advance(60000);
  assert.strictEqual(tv.lastOpened(), B + '/events');
  assert.strictEqual(tv.stored('serverId'), 'id-b');
});

test('kendi CouchSubs\'ı kapalıyken başka TV\'ye hizmet eden CouchSubs\'a geçilmez', () => {
  const tv = startTv({
    saved: 'http://192.168.1.109:8787', savedId: 'id-b',
    alive: new Set([A]), hello: { [A]: { id: 'id-a', tvs: 1 } },
    hasLocalAddress: true, localIp: '192.168.1.30'
  });
  tv.clock.advance(120000);
  assert.ok(!tv.openStreams().some((s) => s.url === A + '/events'));
  assert.strictEqual(tv.saved(), 'http://192.168.1.109:8787');
  assert.strictEqual(tv.stored('serverId'), 'id-b');
});

test('kayıtlı kimlik varken iki yabancı CouchSubs arasından tahminle seçilmez', () => {
  const tv = startTv({
    saved: 'http://192.168.1.109:8787', savedId: 'id-c',
    alive: new Set([A, B]), hello: { [A]: { id: 'id-a', tvs: 0 }, [B]: { id: 'id-b', tvs: 0 } },
    hasLocalAddress: true, localIp: '192.168.1.30'
  });
  tv.clock.advance(120000);
  assert.strictEqual(tv.saved(), 'http://192.168.1.109:8787');
});

test('bilgisayarın başlatma parametresiyle verdiği CouchSubs\'ın kimliği kaydedilir', () => {
  const tv = startTv({
    savedId: 'id-a', params: { server: B },
    alive: new Set([A, B]), hello: { [A]: { id: 'id-a', tvs: 0 }, [B]: { id: 'id-b', tvs: 0 } },
    hasLocalAddress: true, localIp: '192.168.1.30'
  });
  tv.clock.advance(5000);
  assert.strictEqual(tv.lastOpened(), B + '/events');
  assert.strictEqual(tv.stored('serverId'), 'id-b');
  tv.clock.advance(120000);
  assert.strictEqual(tv.lastOpened(), B + '/events');
});

test('kendi CouchSubs\'ı kapalıyken boştaki tek CouchSubs kullanılır, kendisi yeni adreste dönünce ona geçilir', () => {
  const C = 'http://192.168.1.31:8787';
  const back = 'http://192.168.1.60:8787';
  const alive = new Set([C]);
  const tv = startTv({
    saved: 'http://192.168.1.109:8787', savedId: 'id-b',
    alive, hello: { [C]: { id: 'id-c', tvs: 0 }, [back]: { id: 'id-b', tvs: 0 } },
    hasLocalAddress: true, localIp: '192.168.1.30'
  });
  tv.clock.advance(60000);
  assert.strictEqual(tv.lastOpened(), C + '/events');
  // Kayıtlı kimlik değişmez: telefonla bilgisayar arasında geçen kullanıcıda da kendi bilgisayarı tercih edilir.
  assert.strictEqual(tv.stored('serverId'), 'id-b');
  alive.add(back);
  tv.clock.advance(120000);
  assert.strictEqual(tv.lastOpened(), back + '/events');
  assert.strictEqual(tv.saved(), back);
});

test('kimlik vermeyen eski CouchSubs sürümleri eskisi gibi bulunur', () => {
  const pick = startTv({ alive: new Set(), hasLocalAddress: false }).pickServer;
  assert.strictEqual(pick([{ address: A, id: null, tvs: null }], 'id-b').address, A);
  assert.strictEqual(pick([{ address: A, id: null, tvs: null }, { address: B, id: null, tvs: null }], null).address, A);
  assert.strictEqual(pick([], null), null);
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

// Alanda ayrı duran yazı grupları (başlık, ayrı sütundaki hedef) "blocks" ile kendi yerleriyle gelir; alt alta tek
// kutuda değil, her biri kendi İngilizce yazısının üstünde gösterilir.
test('ek alanın blokları kendi yerlerinde gösterilir, bloksuz olaya dönünce tek kutu kalır', () => {
  const tv = startTv({ saved: 'http://192.168.1.109:8787', alive: new Set(['http://192.168.1.109:8787']), hasLocalAddress: false });
  tv.clock.advance(1000);
  const host = tv.element('regions');
  const blocks = [
    { text: 'Demirciyi bul', box: { left: 0.7, top: 0.05, right: 0.95, bottom: 0.08 }, line: 0.03 },
    { text: 'Ahıra git', box: { left: 0.55, top: 0.2, right: 0.65, bottom: 0.23 }, line: 0.03 }
  ];
  tv.emit('region', { id: 'q', text: 'Demirciyi bul\nAhıra git', box: { left: 0.55, top: 0.05, right: 0.95, bottom: 0.23 }, blocks });
  assert.strictEqual(host.children.length, 1);
  assert.strictEqual(host.className, '');
  const group = host.children[0];
  assert.strictEqual(group.className, 'region-blocks');
  assert.deepStrictEqual(group.children.map((c) => c.textContent), ['Demirciyi bul', 'Ahıra git']);
  // Her blok kendi yazısının sol üstünde (pay 0.004), birleşik kutunun köşesinde değil.
  assert.strictEqual(group.children[0].style.left, (0.696 * 100) + '%');
  assert.strictEqual(group.children[1].style.left, (0.546 * 100) + '%');
  assert.strictEqual(group.children[1].style.top, (0.196 * 100) + '%');
  // Aynı alanın yeni blokları eskilerin yerine geçer, birikmez.
  tv.emit('region', { id: 'q', text: 'Ahıra git', box: blocks[1].box, blocks: [blocks[1]] });
  assert.strictEqual(host.children.length, 1);
  assert.deepStrictEqual(host.children[0].children.map((c) => c.textContent), ['Ahıra git']);
  // Bloksuz olay (tek grup ya da eski bilgisayar) eski tek kutuya döner.
  tv.emit('region', { id: 'q', text: 'Köprüyü geç', box: { left: 0.7, top: 0.05, right: 0.95, bottom: 0.1 } });
  assert.strictEqual(host.children.length, 1);
  assert.strictEqual(host.children[0].className, 'region');
  assert.strictEqual(host.children[0].textContent, 'Köprüyü geç');
  tv.emit('region', { id: 'q', text: 'Demirciyi bul\nAhıra git', box: blocks[0].box, blocks });
  tv.emit('region', { id: 'q', text: '' });
  assert.strictEqual(host.children.length, 0);
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

// Samsung arka plana attığı uygulamanın bağlantısını açık tutuyordu; bilgisayar TV uygulamasını bağlı sanıp yeniden
// açmıyor, altyazı ekrana gelmiyordu.
test('Samsung: arka plana düşen uygulama bağlantıyı kapatır, yeniden bağlanmaz; öne gelince bağlanır', () => {
  const tv = startTv({ saved: 'http://192.168.1.109:8787', alive: new Set(['http://192.168.1.109:8787']),
    hasLocalAddress: false, closeWhenHidden: true });
  tv.clock.advance(1000);
  assert.strictEqual(tv.openStreams().length, 1);
  tv.emit('subtitle', { text: 'Merhaba', duration: 60000 });
  assert.strictEqual(tv.element('subtitle').className, '');
  tv.setHidden(true);
  assert.strictEqual(tv.openStreams().length, 0);
  assert.strictEqual(tv.element('subtitle').className, 'hidden');
  // Bağlantı bekçisi ve tarama arka plandayken yeniden bağlanmaz.
  tv.clock.advance(120000);
  assert.strictEqual(tv.openStreams().length, 0);
  tv.setHidden(false);
  tv.clock.advance(1000);
  assert.strictEqual(tv.openStreams().length, 1);
  assert.strictEqual(tv.lastOpened(), 'http://192.168.1.109:8787/events');
});

test('arka plandayken yeni adres gelirse öne gelince o adrese bağlanılır', () => {
  const tv = startTv({ saved: 'http://192.168.1.109:8787',
    alive: new Set(['http://192.168.1.109:8787', 'http://192.168.1.39:8787']), hasLocalAddress: false, closeWhenHidden: true });
  tv.clock.advance(1000);
  tv.setHidden(true);
  // Bilgisayar uygulamayı yeni adresle açar; açılış olayı öne gelmeden önce gelebilir.
  tv.relaunch({ server: 'http://192.168.1.39:8787' });
  assert.strictEqual(tv.openStreams().length, 0);
  tv.setHidden(false);
  tv.clock.advance(1000);
  assert.strictEqual(tv.openStreams().length, 1);
  assert.strictEqual(tv.lastOpened(), 'http://192.168.1.39:8787/events');
  assert.strictEqual(tv.saved(), 'http://192.168.1.39:8787');
});

test('closeWhenHidden istemeyen platformda (LG, Android TV) arka plan bağlantıyı kapatmaz', () => {
  const tv = startTv({ saved: 'http://192.168.1.109:8787', alive: new Set(['http://192.168.1.109:8787']), hasLocalAddress: false });
  tv.clock.advance(1000);
  tv.setHidden(true);
  tv.clock.advance(60000);
  assert.strictEqual(tv.openStreams().length, 1);
  tv.setHidden(false);
  assert.strictEqual(tv.openStreams().length, 1);
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

test('panel kendiliğinden kapanınca ilk açılışta "Tamam: panel" ipucu çıkar; Tamam paneli açar', () => {
  const tv = startTv({ saved: 'http://192.168.1.42:8787', alive: new Set(['http://192.168.1.42:8787']) });
  tv.clock.advance(1000);
  assert.strictEqual(tv.element('panel').className, '');
  assert.strictEqual(tv.element('panel-tip').className, 'hidden');
  tv.clock.advance(8000);
  assert.strictEqual(tv.element('panel').className, 'hidden');
  assert.strictEqual(tv.element('panel-tip').className, '');
  assert.strictEqual(tv.stored('panelTips'), '1');
  tv.key(13);
  assert.strictEqual(tv.element('panel-tip').className, 'hidden');
  assert.strictEqual(tv.element('panel').className, '');
});

test('panel ipucu kendiliğinden kapanır, aynı açılışta bir daha çıkmaz', () => {
  const tv = startTv({ saved: 'http://192.168.1.42:8787', alive: new Set(['http://192.168.1.42:8787']) });
  tv.clock.advance(9000);
  assert.strictEqual(tv.element('panel-tip').className, '');
  tv.clock.advance(16000);
  assert.strictEqual(tv.element('panel-tip').className, 'hidden');
  tv.key(48); // 0: panel yeniden 8 sn açılır
  tv.clock.advance(9000);
  assert.strictEqual(tv.element('panel').className, 'hidden');
  assert.strictEqual(tv.element('panel-tip').className, 'hidden');
  assert.strictEqual(tv.stored('panelTips'), '1');
});

test('Geri yalnız panel ipucunu kapatır, uygulamadan çıkmaz', () => {
  const tv = startTv({ saved: 'http://192.168.1.42:8787', alive: new Set(['http://192.168.1.42:8787']) });
  tv.clock.advance(9000);
  tv.key(461);
  assert.strictEqual(tv.element('panel-tip').className, 'hidden');
  assert.strictEqual(tv.exits(), 0);
});

test('panel ipucu üç açılıştan sonra gösterilmez', () => {
  const tv = startTv({ saved: 'http://192.168.1.42:8787', alive: new Set(['http://192.168.1.42:8787']), panelTips: 3 });
  tv.clock.advance(9000);
  assert.strictEqual(tv.element('panel').className, 'hidden');
  assert.strictEqual(tv.element('panel-tip').className, 'hidden');
  assert.strictEqual(tv.stored('panelTips'), '3');
});

// webOS'ta TV'nin kendi adresi (#469): yeni webOS'un hizmeti yanıt vermezse eski webOS'unki (com.palm) sorulur.
function webosAddress(answers) {
  const clock = makeClock();
  const asked = [];
  class PalmServiceBridge {
    call(uri) {
      asked.push(uri);
      const reply = answers[uri];
      if (reply !== undefined) clock.setTimeout(() => this.onservicecallback(JSON.stringify(reply)), 50);
    }
  }
  const window = {};
  const context = { window, document: {}, PalmServiceBridge, setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout, JSON };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(root, 'platform.js'), 'utf8'), context, { filename: 'platform.js' });
  let result = 'yanıt yok';
  window.COUCHSUBS_PLATFORM.localAddress((ip) => { result = ip; });
  clock.advance(3000);
  return { result, asked };
}

const NEW_CM = 'luna://com.webos.service.connectionmanager/getStatus';
const OLD_CM = 'luna://com.palm.connectionmanager/getStatus';

test('webOS: yeni connectionmanager adres verirse eski sorulmaz (kablolu önce)', () => {
  const { result, asked } = webosAddress({
    [NEW_CM]: { wired: { state: 'connected', ipAddress: '192.168.1.5' }, wifi: { state: 'connected', ipAddress: '192.168.1.6' } }
  });
  assert.strictEqual(result, '192.168.1.5');
  assert.deepStrictEqual(asked, [NEW_CM]);
});

test('webOS: yeni hizmet hata dönerse ya da yanıtsız kalırsa eski webOS\'un com.palm.connectionmanager\'ı sorulur', () => {
  const failed = webosAddress({
    [NEW_CM]: { returnValue: false, errorText: 'Unknown method' },
    [OLD_CM]: { wired: { state: 'disconnected' }, wifi: { state: 'connected', ipAddress: '192.168.0.12' } }
  });
  assert.strictEqual(failed.result, '192.168.0.12');
  assert.deepStrictEqual(failed.asked, [NEW_CM, OLD_CM]);
  const silent = webosAddress({ [OLD_CM]: { wifi: { state: 'connected', ipAddress: '10.0.0.8' } } });
  assert.strictEqual(silent.result, '10.0.0.8');
});

test('webOS: iki hizmet de adres vermezse null, 3 sn içinde', () => {
  assert.strictEqual(webosAddress({}).result, null);
  assert.strictEqual(webosAddress({ [NEW_CM]: {}, [OLD_CM]: { returnValue: false } }).result, null);
});

const secureAddress = 'http://192.168.1.42:8787';
const secureKey = 'ABCDEFGHIJKLMNOPQRSTUV';
const secureId = 'ABCDEF0123456789ABCDEF0123456789';
test('yeni sunucu: insan onayından önce SSE açılmaz; kod ve uzun istek sırrı ayrıdır', () => {
  const auth = { key: secureKey, id: secureId, approved: false };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth });
  tv.clock.advance(1000);
  assert.strictEqual(tv.lastOpened(), undefined);
  assert.match(tv.element('pairing').textContent, /123456/);
  assert(!tv.element('pairing').textContent.includes('abcdefghijklmnopqrstuv'));
  auth.approved = true;
  tv.clock.advance(2000);
  assert.strictEqual(tv.lastOpened(), secureAddress + '/events?k=' + secureKey);
  assert(!tv.element('pairing').textContent.includes(secureKey));
});
test('reddedilen/süresi dolan istek anahtarsız SSE ye düşmez', () => {
  const auth = { key: secureKey, id: secureId, expired: true };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth });
  tv.clock.advance(5000);
  assert.strictEqual(tv.lastOpened(), undefined);
});
test('kayıtlı anahtar önce doğrulanır; yenilenmişse yeniden insan onayı istenir', () => {
  const auth = { key: secureKey, id: secureId };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth,
    storedKeys: { [secureAddress]: 'oldoldoldoldoldoldoldo1' } });
  tv.clock.advance(1000);
  assert.strictEqual(tv.lastOpened(), undefined);
  assert(tv.requests.some(r => r.method === 'POST'));
});
test('sunucu adresi değişse de aynı anahtar kimliğiyle tekrar onay gerekmez', () => {
  const auth = { key: secureKey, id: secureId };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth,
    identities: { [secureId]: secureKey } });
  tv.clock.advance(1000);
  assert.strictEqual(tv.lastOpened(), secureAddress + '/events?k=' + secureKey);
  assert(!tv.requests.some(r => r.method === 'POST'));
});
test('eşleşmiş TV anahtarlı bağlantıda ek alan bloklarını kendi yerlerinde gösterir', () => {
  const auth = { key: secureKey, id: secureId };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth, identities: { [secureId]: secureKey } });
  tv.clock.advance(1000);
  assert.strictEqual(tv.lastOpened(), secureAddress + '/events?k=' + secureKey);
  const blocks = [
    { text: 'Demirciyi bul', box: { left: 0.7, top: 0.05, right: 0.95, bottom: 0.08 }, line: 0.03 },
    { text: 'Ahıra git', box: { left: 0.55, top: 0.2, right: 0.65, bottom: 0.23 }, line: 0.03 }
  ];
  tv.emit('region', { id: 'q', text: 'Demirciyi bul\nAhıra git', box: { left: 0.55, top: 0.05, right: 0.95, bottom: 0.23 }, blocks });
  const group = tv.element('regions').children[0];
  assert.strictEqual(group.className, 'region-blocks');
  assert.deepStrictEqual(group.children.map((c) => c.textContent), ['Demirciyi bul', 'Ahıra git']);
});
test('anahtar yenilenince yanlış anahtarla sonsuz yeniden deneme yerine eşleştirme açılır', () => {
  const auth = { key: secureKey, id: secureId };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth, storedKeys: { [secureAddress]: secureKey } });
  tv.clock.advance(1000);
  auth.key = 'ZYXWVUTSRQPONMLKJIHGFE'; auth.id = '123456789ABCDEF0123456789ABCDEF0';
  tv.failStream();
  tv.clock.advance(6000);
  assert(tv.requests.some(r => r.method === 'POST'));
  assert.match(tv.element('pairing').textContent, /123456/);
});


test('discovery does not restart pairing while waiting for human approval', () => {
  const auth = { key: secureKey, id: secureId, approved: false };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth });
  tv.clock.advance(90000);
  assert.strictEqual(tv.lastOpened(), undefined);
  assert.strictEqual(tv.requests.filter(r => r.method === 'POST').length, 1);
  auth.approved = true;
  tv.clock.advance(2000);
  assert.strictEqual(tv.lastOpened(), secureAddress + '/events?k=' + secureKey);
});

test('süresi dolan eşleştirme kendiliğinden yeniden başlamaz, Tamam ile yeniden istenir', () => {
  const auth = { key: secureKey, id: secureId, expired: true };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth });
  tv.clock.advance(5000);
  assert.match(tv.element('pairing').textContent, /Tamam/);
  tv.clock.advance(60000);
  assert.strictEqual(tv.requests.filter(r => r.method === 'POST').length, 1);
  auth.expired = false; auth.approved = true;
  // Gerçek sayfada kaynak ipucu ve görüntü yok ekranı başta gizlidir.
  tv.element('source-tip').className = 'hidden';
  tv.element('no-picture').className = 'hidden';
  tv.key(13);
  tv.clock.advance(2000);
  assert.strictEqual(tv.requests.filter(r => r.method === 'POST').length, 2);
  assert.strictEqual(tv.lastOpened(), secureAddress + '/events?k=' + secureKey);
});

// X @Eaglaris (20 Kas): çeviri sürmeden "TV'de test et"e basılınca sunucu eşleştirmeyi 409 ile reddediyordu; TV
// "Eşleştirme tamamlanmadı, Tamam'a basın" yazıyor, Tamam da aynı 409'a çıkıyordu. TV ne yapılacağını söyler, kendisi
// birkaç saniyede bir yeniden dener; bilgisayar onay penceresini açınca kod çıkar ve onayla bağlanır.
test('eşleştirmeye kapalı sunucu (409): yönlendirme gösterilir, kendiliğinden yeniden denenir, pencere açılınca kod çıkar', () => {
  const auth = { key: secureKey, id: secureId, reject: true };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth });
  tv.clock.advance(1000);
  assert.match(tv.element('pairing').textContent, /Çeviriyi başlat/);
  assert.doesNotMatch(tv.element('pairing').textContent, /Tamam/);
  assert.strictEqual(tv.lastOpened(), undefined);
  tv.clock.advance(6000);
  assert(tv.requests.filter(r => r.method === 'POST').length >= 2);
  assert.match(tv.element('pairing').textContent, /Çeviriyi başlat/);
  auth.reject = false;
  tv.clock.advance(6000);
  assert.match(tv.element('pairing').textContent, /123456/);
  auth.approved = true;
  tv.clock.advance(2000);
  assert.strictEqual(tv.lastOpened(), secureAddress + '/events?k=' + secureKey);
});

test('eski sunucu (auth bildirmeyen, ör. Android telefon beta.62): yeni TV eşleştirme istemeden anahtarsız bağlanır', () => {
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]) });
  tv.clock.advance(1000);
  assert.strictEqual(tv.lastOpened(), secureAddress + '/events');
  assert(!tv.requests.some(r => r.method === 'POST'));
});

// X @Eaglaris (beta.56, Android TV): TV'de 6 haneli kod hiç görünmedi, bilgisayarda onaylayınca bağlandı. Kod bekleme
// kutusunun (#waiting) içindeydi: katman modunda o kutu hep gizli, panel açılınca da gizleniyor ve adres bilindiği için
// geri gelmiyordu. Kod artık kendi katmanında, panelin ve kutuların üstünde; onay gelene kadar görünür.
test('eşleştirme kodu panel açılıp kapansa da onaya kadar görünür kalır, onayla kalkar', () => {
  const auth = { key: secureKey, id: secureId, approved: false };
  const tv = startTv({ saved: secureAddress, alive: new Set([secureAddress]), auth });
  tv.clock.advance(1000);
  assert.match(tv.element('pairing').textContent, /123456/);
  assert.strictEqual(tv.element('pairing').className, '');
  tv.element('source-tip').className = 'hidden';
  tv.element('no-picture').className = 'hidden';
  // Panel kendiliğinden kapanır, yeşil tuşla açılıp kapanır: bekleme kutusu gizli kalsa da kod görünür.
  tv.clock.advance(10000);
  tv.key(404);
  tv.key(404);
  assert.strictEqual(tv.element('waiting').className, 'hidden');
  assert.strictEqual(tv.element('pairing').className, '');
  assert.match(tv.element('pairing').textContent, /123456/);
  auth.approved = true;
  tv.clock.advance(2000);
  assert.strictEqual(tv.lastOpened(), secureAddress + '/events?k=' + secureKey);
  assert.strictEqual(tv.element('pairing').className, 'hidden');
  assert.strictEqual(tv.element('pairing').textContent, '');
});

test('eşleştirme kodu bekleme kutusunun dışında, panelin üstünde ve katman modunda gizlenmiyor', () => {
  const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  const waiting = html.slice(html.indexOf('<div id="waiting"'), html.indexOf('</div></div>', html.indexOf('<div id="waiting"')));
  assert(html.includes('<div id="pairing"'));
  assert(!waiting.includes('id="pairing"'), 'kod bekleme kutusunun içinde');
  const css = fs.readFileSync(path.join(root, 'style.css'), 'utf8');
  const zIndex = (selector) => Number(new RegExp(selector + '\\s*\\{[^}]*z-index:\\s*(\\d+)').exec(css)[1]);
  assert(zIndex('#pairing') > zIndex('#panel'));
  assert(zIndex('#pairing') > zIndex('#no-picture'));
  const android = fs.readFileSync(path.join(__dirname, '..', 'tv-android', 'platform.js'), 'utf8');
  const hidden = /style\.textContent = '([^']*)display: none/.exec(android)[1];
  assert(!hidden.includes('#pairing'), 'katman modu kodu gizliyor');
  assert(hidden.includes('#waiting'));
});
