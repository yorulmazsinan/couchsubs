// SPDX-License-Identifier: AGPL-3.0-only
// LG TV (tv-webos/platform.js): HDMI görüntüsünün gözcüsü. Görüntü oyunun ortasında düşünce <video> yeniden kurulur;
// çalışan görüntüye dokunulmaz. <video>, zamanlayıcılar ve saat taklit edilir.
// Çalıştırma: node --test scripts/tv-webos-hdmi.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const code = fs.readFileSync(path.join(__dirname, '..', 'tv-webos', 'platform.js'), 'utf8');

function startTv(options = {}) {
  let clock = 1000000;
  let timers = [];
  let nextTimer = 1;
  const videos = [];
  const statuses = [];
  const listeners = {};

  class Element {
    constructor(tag) {
      this.tag = tag;
      this.children = [];
      this.listeners = {};
      this.attributes = {};
      this.parentNode = null;
      if (tag === 'video') {
        this.readyState = 0;
        this.videoWidth = 0;
        this.videoHeight = 0;
        this.currentTime = 0;
        this.paused = false;
        this.ended = false;
        this.error = null;
        this.plays = 0;
        this.loads = 0;
        // options.mediaFocus: TV'nin Chromium'u ses odağı özelliğini (webosMediaFocus) veriyor.
        if (options.mediaFocus) this.webosMediaFocus = false;
        videos.push(this);
      }
    }
    get firstChild() { return this.children[0] || null; }
    setAttribute(name, value) { this.attributes[name] = value; }
    removeAttribute(name) { delete this.attributes[name]; }
    addEventListener(name, fn) { (this.listeners[name] = this.listeners[name] || []).push(fn); }
    appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
    removeChild(child) {
      this.children = this.children.filter((c) => c !== child);
      child.parentNode = null;
      return child;
    }
    set innerHTML(value) { this.children.forEach((c) => { c.parentNode = null; }); this.children = []; }
    fire(name) { (this.listeners[name] || []).slice().forEach((fn) => fn({ type: name })); }
    play() { this.plays++; if (options.playResumes) this.paused = false; }
    pause() { this.paused = true; }
    load() { this.loads++; }
    // Sınamalar için: görüntü geldi.
    start() {
      this.readyState = 4;
      this.videoWidth = 1920;
      this.videoHeight = 1080;
      this.fire('loadeddata');
      this.fire('playing');
    }
  }

  const document = {
    hidden: false,
    createElement: (tag) => new Element(tag),
    addEventListener: (name, fn) => { (listeners[name] = listeners[name] || []).push(fn); },
    fire: (name) => (listeners[name] || []).forEach((fn) => fn({ type: name }))
  };
  const windowListeners = {};
  const window = {
    navigator: { userAgent: 'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 Chrome/79.0.3945.79 Safari/537.36' },
    PalmSystem: { deviceInfo: JSON.stringify({ platformVersion: '7.4.0', modelName: '55NANO756PA' }) },
    addEventListener: (name, fn) => { (windowListeners[name] = windowListeners[name] || []).push(fn); },
    // options.steps: varsayılan kapalı ses adımları (odak, TV sesini açma) açılır.
    ...(options.steps ? { COUCHSUBS_SOUND_STEPS: options.steps } : {}),
    // options.storage: TV'nin localStorage'ı (nesne; oturumlar arasında paylaşılır). Verilmezse localStorage yok.
    ...(options.storage ? { localStorage: {
      getItem: (k) => (Object.prototype.hasOwnProperty.call(options.storage, k) ? options.storage[k] : null),
      setItem: (k, v) => { options.storage[k] = String(v); },
      removeItem: (k) => { delete options.storage[k]; }
    } } : {})
  };
  class FakeDate { getTime() { return clock; } }
  // options.luna(uri, params): Luna hizmetinin yanıtı (nesne); verilmezse PalmServiceBridge yok.
  const calls = [];
  const sent = [];
  class PalmServiceBridge {
    call(uri, params) {
      calls.push(uri);
      sent.push({ uri, params: JSON.parse(params) });
      const reply = options.luna(uri, JSON.parse(params));
      if (reply) this.onservicecallback(JSON.stringify(reply));
    }
  }
  const context = {
    window, document, JSON, Math, Number, String, Date: FakeDate,
    ...(options.luna ? { PalmServiceBridge } : {}),
    setTimeout: (fn, ms) => { const id = nextTimer++; timers.push({ id, at: clock + (ms || 0), fn }); return id; },
    clearTimeout: (id) => { timers = timers.filter((t) => t.id !== id); }
  };
  vm.createContext(context);
  vm.runInContext(code, context, { filename: 'platform.js' });
  const platform = window.COUCHSUBS_PLATFORM;
  const host = new Element('div');

  const tv = {
    platform, document, window, videos, statuses, host, calls, sent,
    get video() { return videos[videos.length - 1]; },
    show(port) { platform.showHdmi(port || 3, host, (kind) => statuses.push(kind)); },
    // Saati ilerletir; her adımda (varsa) canlı görüntünün sayacı da ilerler.
    advance(ms, eachStep) {
      const end = clock + ms;
      while (true) {
        timers.sort((a, b) => a.at - b.at || a.id - b.id);
        const due = timers[0];
        if (!due || due.at > end) break;
        timers.shift();
        clock = Math.max(clock, due.at);
        if (eachStep) eachStep();
        due.fn();
      }
      clock = end;
    },
    hide() { document.hidden = true; document.fire('visibilitychange'); },
    unhide() { document.hidden = false; document.fire('visibilitychange'); },
    focus() { (windowListeners.focus || []).forEach((fn) => fn()); }
  };
  return tv;
}

// Sayacı ilerleyen sağlam görüntü: her denetimde currentTime biraz artar.
function ticking(tv) {
  return () => { if (tv.video && tv.video.readyState >= 2 && !tv.video.frozen) tv.video.currentTime += 1; };
}

test('webOS HDMI: sağlam görüntüye dokunulmaz (sayaç ilerlese de ilerlemese de)', () => {
  for (const moving of [true, false]) {
    const tv = startTv();
    tv.show(3);
    tv.video.start();
    tv.advance(10 * 60 * 1000, moving ? ticking(tv) : null);
    assert.strictEqual(tv.videos.length, 1, moving ? 'sayaç ilerlerken' : 'sayaç hiç ilerlemezken');
    assert.strictEqual(tv.video.attributes.src, undefined);
    assert.strictEqual(tv.video.children[0].attributes.src, 'ext://hdmi:3');
    assert.match(tv.platform.diagnostics(), /^hdmi playing rs4 1920x1080 t[+=] · snd on sx no · webOS 7\.4\.0 55NANO756PA cr79 · scr [^ ]+ dpr [0-9.]+ vp 1920 iw [0-9]+x[0-9]+ · mode in-app$/);
  }
});

test('webOS HDMI: hata olayında <video> 2 sn sonra yeniden kurulur, görüntü gelince durum yenilenir', () => {
  const tv = startTv();
  tv.show(3);
  const first = tv.video;
  first.start();
  tv.advance(20000, ticking(tv));
  first.error = { code: 4 };
  first.fire('error');
  assert.strictEqual(tv.statuses[tv.statuses.length - 1], 'inputError');
  tv.advance(1900);
  assert.strictEqual(tv.videos.length, 1, '2 sn dolmadan kurulmaz');
  tv.advance(600);
  assert.strictEqual(first.parentNode, null, 'eski <video> sayfadan çıkar');
  assert.strictEqual(first.loads, 1, 'eski boru hattı bırakılır');
  assert.strictEqual(tv.videos.length, 1, 'yeni <video> bırakmadan 1 sn sonra açılır');
  tv.advance(1000);
  assert.strictEqual(tv.videos.length, 2);
  assert.strictEqual(tv.video.children[0].attributes.src, 'ext://hdmi:3');
  assert.strictEqual(tv.host.children.length, 1);
  tv.video.start();
  assert.strictEqual(tv.statuses[tv.statuses.length - 1], 'playing');
  assert.match(tv.platform.diagnostics(), /hdmi playing .* · rebuilt 1 \(error\) · last error code 4/);
  // Eski <video>'nun geç gelen olayı yenisini etkilemez.
  first.fire('error');
  tv.advance(60000, ticking(tv));
  assert.strictEqual(tv.videos.length, 2);
});

test('webOS HDMI: "oynatılıyor" görünürken sayaç durursa (siyah ekran) yeniden kurulur', () => {
  const tv = startTv();
  tv.show(3);
  const first = tv.video;
  first.start();
  tv.advance(60000, ticking(tv));
  assert.strictEqual(tv.videos.length, 1);
  // Görüntü katmanı düştü: <video> hâlâ "oynuyor" diyor ama kare ilerlemiyor.
  first.frozen = true;
  tv.advance(14000, ticking(tv));
  assert.strictEqual(tv.videos.length, 1, '15 sn dolmadan kurulmaz');
  tv.advance(12000, ticking(tv));
  assert.strictEqual(tv.videos.length, 2);
  assert.match(tv.platform.diagnostics(), /rebuilt 1 \(stalled\)/);
});

test('webOS HDMI: kare kaybolursa kurulur; düzelmezse denemeler seyrekleşir, dakikada en çok dört', () => {
  const tv = startTv();
  tv.show(3);
  tv.video.start();
  tv.advance(20000, ticking(tv));
  tv.video.readyState = 0;
  tv.video.videoWidth = 0;
  const before = tv.videos.length;
  tv.advance(60000);
  const firstMinute = tv.videos.length - before;
  assert.ok(firstMinute >= 2 && firstMinute <= 4, 'ilk dakikada ' + firstMinute + ' deneme');
  tv.advance(10 * 60000);
  const later = tv.videos.length - before - firstMinute;
  assert.ok(later >= 5 && later <= 12, 'sonraki 10 dakikada ' + later + ' deneme (dakikada bir civarı)');
  // Görüntü geri gelince durulur.
  tv.video.start();
  const settled = tv.videos.length;
  tv.advance(5 * 60000, ticking(tv));
  assert.strictEqual(tv.videos.length, settled);
});

test('webOS HDMI: bu girişte görüntü hiç gelmediyse en çok üç kez denenir', () => {
  const tv = startTv();
  tv.show(1);
  tv.advance(30 * 60000);
  assert.strictEqual(tv.videos.length, 4);
  // Kullanıcı başka giriş seçince sayaç baştan başlar.
  tv.show(2);
  tv.video.start();
  tv.advance(60000, ticking(tv));
  assert.strictEqual(tv.videos.length, 5);
});

test('webOS HDMI: duraklamış görüntü önce oynatılır, olmazsa yeniden kurulur', () => {
  const resumed = startTv({ playResumes: true });
  resumed.show(3);
  resumed.video.start();
  resumed.advance(20000, ticking(resumed));
  resumed.video.paused = true;
  resumed.video.fire('pause');
  resumed.advance(30000, ticking(resumed));
  assert.strictEqual(resumed.videos.length, 1);
  assert.strictEqual(resumed.video.plays, 1);

  const stuck = startTv();
  stuck.show(3);
  stuck.video.start();
  stuck.advance(20000, ticking(stuck));
  stuck.video.paused = true;
  stuck.advance(16000);
  assert.strictEqual(stuck.videos.length, 2);
  assert.match(stuck.platform.diagnostics(), /rebuilt 1 \(paused\)/);
});

test('webOS HDMI: stalled/emptied/abort olayları sağlam görüntüyü yeniden kurdurmaz', () => {
  const tv = startTv();
  tv.show(3);
  tv.video.start();
  tv.advance(20000, ticking(tv));
  for (const name of ['stalled', 'emptied', 'abort']) {
    tv.video.fire(name);
    tv.advance(10000, ticking(tv));
  }
  assert.strictEqual(tv.videos.length, 1);
  assert.match(tv.platform.diagnostics(), /ev abort · stall 1 ok/);
});

test('webOS HDMI: arka plandan dönünce sayaç ilerlemiyorsa yeniden kurulur, ilerliyorsa dokunulmaz', () => {
  const dead = startTv();
  dead.show(3);
  dead.video.start();
  dead.advance(20000);
  dead.hide();
  dead.advance(60000);
  assert.strictEqual(dead.videos.length, 1, 'arka plandayken kurulmaz');
  dead.unhide();
  dead.advance(5000);
  assert.strictEqual(dead.videos.length, 2);
  assert.match(dead.platform.diagnostics(), /rebuilt 1 \(resume\)/);

  const alive = startTv();
  alive.show(3);
  alive.video.start();
  alive.advance(20000, ticking(alive));
  alive.hide();
  alive.advance(60000);
  alive.unhide();
  alive.advance(30000, ticking(alive));
  assert.strictEqual(alive.videos.length, 1);
});

test('webOS HDMI: odak ve yeniden başlatılma sağlam görüntüye dokunmaz, bozuk görüntüyü birkaç saniyede kurar', () => {
  const tv = startTv();
  tv.show(3);
  tv.video.start();
  tv.advance(20000);
  tv.focus();
  tv.document.fire('webOSRelaunch');
  tv.advance(4000);
  assert.strictEqual(tv.videos.length, 1);
  tv.video.readyState = 0;
  tv.video.videoWidth = 0;
  tv.document.fire('webOSRelaunch');
  tv.advance(4000);
  assert.strictEqual(tv.videos.length, 2);
});

test('webOS HDMI: aynı giriş yeniden seçilince boru hattı bırakılıp baştan kurulur; çıkışta görüntü bırakılır', () => {
  const tv = startTv();
  tv.show(3);
  const first = tv.video;
  first.start();
  tv.show(3);
  assert.strictEqual(first.loads, 1);
  assert.strictEqual(tv.videos.length, 1, 'yeni <video> bırakmadan 1 sn sonra açılır');
  tv.advance(1000);
  assert.strictEqual(tv.videos.length, 2);
  assert.strictEqual(tv.host.children.length, 1);
  const second = tv.video;
  tv.show(2);
  assert.strictEqual(second.loads, 0, 'başka girişe geçerken eskisi gibi yalnız sayfadan çıkarılır');
  const third = tv.video;
  tv.platform.exit(true);
  assert.strictEqual(third.loads, 1);
  tv.advance(10 * 60000);
  assert.strictEqual(tv.videos.length, 3, 'çıkıştan sonra yeniden kurulmaz');
});

// <video>'ya yazılan ses özelliklerini kaydeder; kill verilirse yazıldığı an görüntüyü düşürür (webOS'un boru hattını
// askıya aldığı TV taklidi). throws: yazmak hata fırlatır.
function watchSound(video, { kill = [], throws = [] } = {}) {
  const touched = [];
  const values = { muted: false, defaultMuted: false, volume: 1, webosMediaFocus: false };
  const track = { on: false };
  for (const name of Object.keys(values)) {
    if (name === 'webosMediaFocus' && !('webosMediaFocus' in video)) continue;
    Object.defineProperty(video, name, {
      configurable: true,
      get: () => values[name],
      set: (value) => {
        touched.push(name);
        if (throws.includes(name)) throw new Error('not allowed');
        values[name] = value;
        if (kill.includes(name)) { video.readyState = 0; video.videoWidth = 0; }
      }
    });
  }
  const tracks = [{}];
  Object.defineProperty(tracks[0], 'enabled', {
    get: () => track.on,
    set: (value) => {
      touched.push('track');
      if (throws.includes('track')) throw new Error('not allowed');
      track.on = value;
      if (kill.includes('track')) { video.readyState = 0; video.videoWidth = 0; }
    }
  });
  video.audioTracks = tracks;
  return touched;
}

function lunaCalls(tv, part) { return tv.sent.filter((c) => c.uri.indexOf(part) >= 0); }

// 0.9.53, X'te LG OLED: güncellemeden sonra çeviriyi başlatınca ekran siyah. Ses adımları görüntü gelmeden yapılıyordu.
test('webOS HDMI: görüntü gelmeden ses adımı, ses ayarı okuma, odak yapılmaz (0.9.46 yolu)', () => {
  const tv = startTv({ mediaFocus: true, steps: { focus: true, tvUnmute: true },
    luna: () => ({ returnValue: true, volumeStatus: { volume: 10, muteStatus: false } }) });
  tv.show(2);
  const video = tv.video;
  const touched = watchSound(video);
  video.fire('loadedmetadata');
  video.fire('canplay');
  tv.advance(7000);
  assert.deepStrictEqual(touched, [], 'görüntü yokken <video>\'ya dokunulmaz');
  assert.strictEqual(lunaCalls(tv, 'com.webos.audio').length + lunaCalls(tv, 'settingsservice').length, 0);
  assert.match(tv.platform.diagnostics(), / sx wait · webOS/);
  assert.strictEqual(video.children[0].attributes.src, 'ext://hdmi:2');
  assert.strictEqual(video.autoplay, true);
});

test('webOS HDMI: istenirse ses adımları görüntü 3 sn geldikten sonra bir kez; odak ve TV sesini açma ayrıca istenir', () => {
  const tv = startTv({ mediaFocus: true, steps: {}, luna: (uri) => (uri.indexOf('settingsservice') >= 0
    ? { returnValue: true, settings: { soundOutput: 'external_arc' } }
    : { returnValue: true, volumeStatus: { volume: 14, muteStatus: true } }) });
  tv.show(2);
  const video = tv.video;
  const touched = watchSound(video);
  video.start();
  tv.advance(2900, ticking(tv));
  assert.deepStrictEqual(touched, [], 'hemen değil');
  tv.advance(200, ticking(tv));
  assert.deepStrictEqual(touched, ['muted', 'defaultMuted', 'track'], 'kapalı ses parçası açılır; odak istenmez');
  assert.strictEqual(video.webosMediaFocus, false);
  tv.advance(60000, ticking(tv));
  assert.strictEqual(lunaCalls(tv, '/setMuted').length, 0, 'TV sesi açılmaz (varsayılan kapalı)');
  assert.strictEqual(touched.length, 3, 'bir kez');
  assert.strictEqual(tv.videos.length, 1);
  assert.match(tv.platform.diagnostics(), / · snd on v100 tr1\/1 fixed 1 out external_arc tv 14 muted sx on · webOS/);
});

test('webOS HDMI: ses adımı görüntüyü düşürürse adımlar kapanır, <video> eski yolla kurulur ve bir daha dokunulmaz', () => {
  const tv = startTv({ steps: {}, luna: () => ({ returnValue: true }) });
  tv.show(3);
  const first = tv.video;
  watchSound(first, { kill: ['track'] });
  first.start();
  tv.advance(3500);
  assert.strictEqual(first.readyState, 0, 'taklit: ses parçasını açmak görüntüyü düşürdü');
  tv.advance(20000);
  assert.ok(tv.videos.length >= 2, 'gözcü yeniden kurdu');
  assert.match(tv.platform.diagnostics(), / sx off drop lost/);
  const second = tv.video;
  const touched = watchSound(second, { kill: ['track'] });
  second.start();
  tv.advance(10 * 60000, ticking(tv));
  assert.deepStrictEqual(touched, [], 'eski yol: ses adımı yok');
  assert.strictEqual(tv.videos.length, 2);
  assert.strictEqual(tv.statuses[tv.statuses.length - 1], 'playing');
});

test('webOS HDMI: siyah ekranda kullanıcı girişi yeniden seçerse ses adımları kapanır', () => {
  const tv = startTv({ steps: {} });
  tv.show(3);
  watchSound(tv.video);
  tv.video.start();
  tv.advance(4000);
  tv.show(3);
  const touched = watchSound(tv.video);
  tv.video.start();
  tv.advance(60000, ticking(tv));
  assert.deepStrictEqual(touched, []);
  assert.match(tv.platform.diagnostics(), / sx off reselect/);
});

test('webOS HDMI: görüntü hiç gelmezse adımlar kapanır (eski yol); hata fırlatan ses özelliği görüntüyü etkilemez', () => {
  const none = startTv({ steps: {} });
  none.show(1);
  none.advance(20000);
  assert.ok(none.videos.length >= 2);
  assert.match(none.platform.diagnostics(), / sx off nopic/);

  const strict = startTv({ mediaFocus: true, steps: { focus: true } });
  strict.show(2);
  const touched = watchSound(strict.video, { throws: ['muted', 'track', 'webosMediaFocus'] });
  strict.video.start();
  strict.advance(60000, ticking(strict));
  assert.ok(touched.includes('webosMediaFocus'), 'açıkça istenince odak denenir');
  assert.strictEqual(strict.videos.length, 1);
  assert.match(strict.platform.diagnostics(), /^hdmi playing .* mf err sx on · webOS/);
});

test('webOS HDMI: açıkça istenirse odak sınırlı sayıda, TV sesi kısık kalırsa bir kez açılır; yeniden açılış sayılır', () => {
  const state = { muted: false };
  const tv = startTv({ mediaFocus: true, steps: { focus: true, tvUnmute: true }, luna: (uri, params) => {
    if (uri.endsWith('/setMuted')) { state.muted = params.muted; return { returnValue: true }; }
    if (uri.indexOf('settingsservice') >= 0) return { returnValue: true, settings: {} };
    return { returnValue: true, volumeStatus: { volume: 20, muteStatus: state.muted } };
  } });
  tv.show(2);
  const video = tv.video;
  video.start();
  tv.advance(3100, ticking(tv));
  assert.strictEqual(video.webosMediaFocus, true);
  state.muted = true;
  tv.advance(2000, ticking(tv));
  assert.deepStrictEqual(lunaCalls(tv, '/setMuted').map((c) => c.params), [{ muted: false }]);
  for (let i = 0; i < 5; i++) {
    video.webosMediaFocus = false;
    video.fire('webosmediafocuschange');
  }
  assert.match(tv.platform.diagnostics(), / mf 0 .*tvmute unmuted sx on/);
  tv.document.fire('webOSRelaunch');
  tv.document.fire('webOSRelaunch');
  tv.advance(4000, ticking(tv));
  assert.match(tv.platform.diagnostics(), / · rl 2 · snd/);
  assert.strictEqual(tv.videos.length, 1);
});

// #643, LG 55SK8500PLA (webOS 05.50.70): görüntü geldi, 3 sn sonra ses adımları yapıldı, sonra <video> 'stalled' oldu
// ve siyah ekranda kaldı; TV sayacı ilerletmiyor (t=), <video> rs4 "oynuyor" dediği için hiçbir şey yapılmıyordu.
test('webOS HDMI #643: ses adımları varsayılanda hiç yapılmaz; ses ayarı/ses düzeyi okunmaz', () => {
  const tv = startTv({ mediaFocus: true, luna: () => ({ returnValue: false, errorText: 'denied' }) });
  tv.show(2);
  const video = tv.video;
  const touched = watchSound(video);
  video.start();
  tv.advance(10 * 60000);
  assert.deepStrictEqual(touched, [], '<video>\'nun ses özelliklerine dokunulmaz');
  assert.strictEqual(lunaCalls(tv, 'com.webos.audio').length, 0, 'getVolume/setMuted yok');
  assert.strictEqual(lunaCalls(tv, 'settingsservice').length, 0, 'ses ayarı okunmaz');
  assert.strictEqual(video.webosMediaFocus, false);
  assert.strictEqual(tv.videos.length, 1);
  assert.match(tv.platform.diagnostics(), /^hdmi playing rs4 1920x1080 t= · snd on v100 tr0\/1 sx no · webOS/);
});

// 0.9.98 (X: LG ve Android TV'de "TV uygulaması açıkken ses yok, PS5'in kendi girişinde var"): ses adımları kapalıyken
// TV'nin ses çıkışı tanı satırına hiç yazılmıyordu. Açılışta, <video> yokken bir kez okunur; görüntü oynarken okunmaz.
test('webOS HDMI: ses çıkışı ve ses düzeyi açılışta bir kez okunur, görüntü oynarken okunmaz', () => {
  const tv = startTv({ mediaFocus: true, luna: (uri, params) => {
    if (uri.indexOf('settingsservice') >= 0) {
      const key = params.keys[0];
      return { returnValue: true, settings: { [key]: key === 'soundOutput' ? 'external_arc' : 'passThrough' } };
    }
    if (uri.indexOf('com.webos.audio/getVolume') >= 0) return { returnValue: true, volumeStatus: { volume: 12, muteStatus: false } };
    return null;
  } });
  tv.platform.init();
  assert.strictEqual(lunaCalls(tv, 'settingsservice').length, 2, 'soundOutput ve soundOutputDigital');
  assert.strictEqual(lunaCalls(tv, 'com.webos.audio/getVolume').length, 1);
  const before = lunaCalls(tv, 'com.webos.audio').length + lunaCalls(tv, 'settingsservice').length;
  tv.show(2);
  const video = tv.video;
  const touched = watchSound(video);
  video.start();
  tv.advance(10 * 60000);
  assert.deepStrictEqual(touched, [], '<video>\'nun ses özelliklerine dokunulmaz');
  assert.strictEqual(lunaCalls(tv, 'com.webos.audio').length + lunaCalls(tv, 'settingsservice').length, before,
    'görüntü oynarken ses okunmaz');
  assert.strictEqual(lunaCalls(tv, 'setMuted').length, 0);
  assert.strictEqual(video.webosMediaFocus, false);
  assert.match(tv.platform.diagnostics(), / · snd on v100 tr0\/1 out external_arc dig passThrough tv 12 sx no · webOS/);
});

test('webOS HDMI #643: görüntü gelip stalled olursa <video> eski yolla yeniden kurulur, ses adımı yok', () => {
  const tv = startTv({ luna: () => ({ returnValue: false }) });
  tv.show(2);
  const first = tv.video;
  watchSound(first);
  first.start();
  tv.advance(4000);
  first.fire('stalled');
  tv.advance(1400);
  assert.strictEqual(tv.videos.length, 1, '1,5 sn dolmadan kurulmaz');
  tv.advance(200);
  assert.strictEqual(first.parentNode, null);
  assert.strictEqual(first.loads, 1, 'eski boru hattı bırakıldı');
  assert.strictEqual(tv.videos.length, 1, 'yeni <video> bırakmadan 1 sn sonra açılır');
  tv.advance(1000);
  assert.strictEqual(tv.videos.length, 2, 'stalled sonrası yeniden kuruldu');
  const second = tv.video;
  assert.strictEqual(second.children[0].attributes.src, 'ext://hdmi:2');
  assert.strictEqual(second.children[0].attributes.type, 'service/webos-external');
  assert.strictEqual(second.autoplay, true);
  const touched = watchSound(second);
  second.start();
  assert.match(tv.platform.diagnostics(), / · rebuilt 1 \(ev stalled\) · ev stalled · stall 1 rebuilt · snd .* sx no · /);
  // 0.9.63'te (#643 panel: "rebuilt 1 (ev stalled) · ev stalled · stall 2 wait") 30 sn dolmadan gelen ikinci stalled
  // yalnız beklenirdi; TV sayacı ilerletmediği için ekran siyah kalıyordu. Artık gözcünün artan aralığıyla kurulur.
  tv.advance(10000);
  second.fire('stalled');
  tv.advance(1600);
  assert.strictEqual(tv.videos.length, 2);
  assert.match(tv.platform.diagnostics(), / · stall 2 wait · /);
  tv.advance(6000);
  assert.strictEqual(tv.videos.length, 3, 'ikinci stalled de yeniden kurdurur');
  assert.match(tv.platform.diagnostics(), /rebuilt 2 \(ev stalled\) · ev stalled · stall 2 rebuilt/);
  const third = tv.video;
  third.start();
  // 30 sn sonra yine stalled olursa beklemeden kurulur.
  tv.advance(40000);
  third.fire('stalled');
  tv.advance(2600);
  assert.strictEqual(tv.videos.length, 4);
  assert.match(tv.platform.diagnostics(), /rebuilt 3 \(ev stalled\) · ev stalled · stall 3 rebuilt/);
  tv.video.start();
  tv.advance(10 * 60000);
  assert.deepStrictEqual(touched, [], 'ses adımı hiç yapılmadı');
  assert.strictEqual(lunaCalls(tv, 'com.webos.audio').length + lunaCalls(tv, 'settingsservice').length, 0);
  assert.strictEqual(tv.videos.length, 4, 'sağlam görüntüye bir daha dokunulmaz');
  assert.strictEqual(tv.statuses[tv.statuses.length - 1], 'playing');
});

test('webOS HDMI #643: stalled denetimi ardından gelen odak ve yeniden başlatılma denetimiyle silinmez', () => {
  const tv = startTv();
  tv.show(2);
  tv.video.start();
  tv.advance(20000);
  tv.video.fire('stalled');
  tv.advance(500);
  tv.document.fire('webOSRelaunch');
  tv.focus();
  tv.advance(3000);
  assert.strictEqual(tv.videos.length, 2);
  assert.match(tv.platform.diagnostics(), /rebuilt 1 \(ev stalled\)/);
});

test('webOS HDMI #643: öne gelişin sıkı denetimi hemen ardından gelen webOSRelaunch ve odakla gevşemez', () => {
  const tv = startTv();
  tv.show(2);
  tv.video.start();
  tv.advance(20000);
  tv.hide();
  tv.advance(10000);
  // Bilgisayarın bekçisi PS tuşundan sonra uygulamayı öne getirir: görünürlük, webOSRelaunch ve odak art arda gelir.
  tv.unhide();
  tv.document.fire('webOSRelaunch');
  tv.focus();
  tv.advance(5000);
  assert.strictEqual(tv.videos.length, 2, 'sayacı ilerlemeyen görüntü öne gelişte yeniden kurulur');
  assert.match(tv.platform.diagnostics(), /rebuilt 1 \(resume\)/);
  tv.video.start();
  tv.advance(10 * 60000);
  assert.strictEqual(tv.videos.length, 2);
});

// Sağlam görüntü, sayacı ilerletmeyen TV (t=): her yeni <video> kurulduktan 3 sn sonra bir kez 'stalled' gönderir.
// Döndürür: kurulma anları (sn).
function stallOnEveryBuild(tv, seconds, from) {
  const built = [];
  let seen = tv.videos.length - 1;
  for (let t = from || 0; t < (from || 0) + seconds; t++) {
    if (tv.videos.length > seen) {
      seen = tv.videos.length;
      tv.video.start();
      tv.video.stallAt = t + 3;
      built.push(t);
    } else if (tv.video && tv.video.stallAt === t) {
      tv.video.fire('stalled');
    }
    tv.advance(1000);
  }
  return built;
}

test('webOS HDMI 0.9.73: her yeni <video>\'da stalled gönderen TV\'de sağlam görüntü dakikada bir yeniden kurulmaz', () => {
  const tv = startTv();
  tv.show(2);
  // 0.9.67-0.9.72: 0, 6, 16, 30, 52, 88, 154, 220… (~66 sn'de bir kararma ve HDR rozeti, sonsuza dek).
  const built = stallOnEveryBuild(tv, 30 * 60);
  assert.ok(built.length - 1 <= 3, 'stalled yüzünden kurma sayısı ' + (built.length - 1) + ': ' + built.join(','));
  assert.ok(built[built.length - 1] < 60, 'ilk dakikadan sonra dokunulmaz: ' + built.join(','));
  assert.match(tv.platform.diagnostics(), /rebuilt 3 \(ev stalled\) · ev stalled · stall 4 limit/);
});

test('webOS HDMI 0.9.73: sınır dolunca kullanıcı girişi yeniden seçerse (siyah ekran) stalled yine kurdurur', () => {
  const tv = startTv();
  tv.show(2);
  stallOnEveryBuild(tv, 60);
  assert.match(tv.platform.diagnostics(), /stall 4 limit/);
  tv.show(2);
  tv.advance(1000);
  const again = stallOnEveryBuild(tv, 60);
  assert.ok(again.length >= 2, 'yeniden seçimden sonra stalled yine kurdurur');
});

test('webOS HDMI 0.9.73: sınır dolduktan 10 dk sonra gelen stalled yine kurdurur', () => {
  const tv = startTv();
  tv.show(2);
  stallOnEveryBuild(tv, 120);
  const before = tv.videos.length;
  tv.advance(10 * 60000);
  assert.strictEqual(tv.videos.length, before);
  tv.video.fire('stalled');
  tv.advance(3000);
  assert.strictEqual(tv.videos.length, before + 1);
});

const NOISE_KEY = 'couchsubs.hdmiStallNoise';

test('webOS HDMI 0.9.82 (#1055): her kurulumda stalled gönderen TV öğrenilir; sonra çeviri başında ve PS tuşundan dönüşte görüntü üç kez kararmaz', () => {
  const storage = {};
  // İlk oturum 0.9.73 gibi: üç kurma, sınır dolar; kullanıcı girişi yeniden seçmez (görüntü sağlam).
  const first = startTv({ storage });
  first.show(2);
  const built = stallOnEveryBuild(first, 5 * 60);
  assert.strictEqual(built.length - 1, 3, built.join(','));
  assert.strictEqual(storage[NOISE_KEY], '1', 'TV öğrenildi');

  // Sonraki çeviri: taze stalled görüntüye dokunmaz.
  const tv = startTv({ storage });
  tv.show(2);
  const again = stallOnEveryBuild(tv, 30 * 60);
  assert.deepStrictEqual(again, [0], 'yalnız ilk kurma: ' + again.join(','));
  assert.match(tv.platform.diagnostics(), /ev stalled · stall 1 noise/);

  // PS tuşu: TV konsolun girişine geçer, bekçi uygulamayı öne getirir. Sayacı ilerletmeyen TV'de öne gelişin sıkı
  // denetimi bir kez kurar; yeni <video>'nun taze stalled'ı yeniden kurdurmaz.
  for (let press = 0; press < 3; press++) {
    const before = tv.videos.length;
    tv.hide();
    tv.advance(8000);
    tv.unhide();
    tv.document.fire('webOSRelaunch');
    tv.focus();
    stallOnEveryBuild(tv, 3 * 60);
    assert.strictEqual(tv.videos.length - before, 1, 'PS tuşundan sonra en çok bir kurma (basış ' + (press + 1) + ')');
    tv.advance(12 * 60000);
  }
  assert.match(tv.platform.diagnostics(), /rebuilt 3 \(resume\) · ev stalled · stall \d+ noise/);
});

test('webOS HDMI 0.9.82: öğrenilmiş TV\'de oturmuş görüntüde gelen stalled yine kurdurur', () => {
  const storage = { [NOISE_KEY]: '1' };
  const tv = startTv({ storage });
  tv.show(2);
  tv.video.start();
  tv.advance(3000);
  tv.video.fire('stalled');
  tv.advance(5000);
  assert.strictEqual(tv.videos.length, 1, 'taze stalled');
  tv.advance(30000);
  tv.video.fire('stalled');
  tv.advance(3000);
  assert.strictEqual(tv.videos.length, 2, 'oyunun ortasındaki stalled (#643) yeniden kurdurur');
  assert.match(tv.platform.diagnostics(), /rebuilt 1 \(ev stalled\)/);
});

test('webOS HDMI 0.9.82: dokunulmayan stalled\'dan hemen sonra giriş yeniden seçilirse (siyah ekran) TV unutulur', () => {
  const storage = { [NOISE_KEY]: '1' };
  const tv = startTv({ storage });
  tv.show(2);
  stallOnEveryBuild(tv, 30);
  assert.strictEqual(tv.videos.length, 1);
  assert.match(tv.platform.diagnostics(), /stall 1 noise/);
  // Kullanıcı kumandada 2'ye basar: ekran siyahtı.
  tv.show(2);
  tv.advance(1000);
  assert.strictEqual(storage[NOISE_KEY], undefined, 'kayıt silindi');
  const built = stallOnEveryBuild(tv, 5 * 60);
  assert.strictEqual(built.length - 1, 3, 'taze stalled yine kurdurur: ' + built.join(','));
  assert.strictEqual(storage[NOISE_KEY], undefined, 'bu oturumda yeniden öğrenilmez');
});

test('webOS HDMI 0.9.82: sınır dolduktan sonra kullanıcı girişi yeniden seçerse TV öğrenilmez; arka plandayken karar verilmez', () => {
  const storage = {};
  const tv = startTv({ storage });
  tv.show(2);
  stallOnEveryBuild(tv, 60);
  tv.show(2);
  tv.advance(20 * 60000);
  assert.strictEqual(storage[NOISE_KEY], undefined);

  const other = {};
  const hidden = startTv({ storage: other });
  hidden.show(2);
  stallOnEveryBuild(hidden, 40);
  hidden.hide();
  hidden.advance(5 * 60000);
  assert.strictEqual(other[NOISE_KEY], undefined, 'arka plandayken saklanmaz');
  hidden.unhide();
  stallOnEveryBuild(hidden, 3 * 60);
  assert.strictEqual(other[NOISE_KEY], '1', 'öne gelip görüntü sağlam kalınca saklanır');
});

test('webOS HDMI 0.9.82: localStorage yoksa ya da hata verirse ilk oturum 0.9.73 gibi', () => {
  const tv = startTv();
  tv.show(2);
  const built = stallOnEveryBuild(tv, 5 * 60);
  assert.strictEqual(built.length - 1, 3);
  const broken = { };
  Object.defineProperty(broken, NOISE_KEY, { get() { throw new Error('quota'); }, set() { throw new Error('quota'); } });
  const tv2 = startTv({ storage: broken });
  tv2.show(2);
  assert.strictEqual(stallOnEveryBuild(tv2, 5 * 60).length - 1, 3);
});

// 0.9.87 (#1055, 0.9.84 + beta.89): öğrenme ilk oturumda sınır dolduktan sonra yazıldığı için ilk oturum hâlâ üç
// kurmaydı. Akışı ölçülebilen TV'de (kare sayacı ya da currentTime ilerliyor) 'stalled' akan görüntüyü kurdurmaz.
// Kare sayacını (webkitDecodedFrameCount) ilerleten, currentTime'ı ilerletmeyen sağlam görüntü.
function decoding(tv) {
  return () => {
    const v = tv.video;
    if (v && v.readyState >= 2 && !v.frozen) v.webkitDecodedFrameCount = (v.webkitDecodedFrameCount || 0) + 30;
  };
}

// stallOnEveryBuild gibi, ama her adımda eachStep çağrılır (sayaç ilerler).
function stallOnEveryBuildFlowing(tv, seconds, eachStep) {
  const built = [];
  let seen = tv.videos.length - 1;
  for (let t = 0; t < seconds; t++) {
    if (tv.videos.length > seen) {
      seen = tv.videos.length;
      tv.video.start();
      tv.video.stallAt = t + 3;
      built.push(t);
    } else if (tv.video && tv.video.stallAt === t) {
      tv.video.fire('stalled');
    }
    eachStep();
    tv.advance(1000, eachStep);
  }
  return built;
}

test('webOS HDMI 0.9.87 (#1055): kare sayacı ilerleyen TV\'de ilk oturumda da taze stalled sağlam görüntüyü kurdurmaz', () => {
  const storage = {};
  const tv = startTv({ storage });
  tv.show(2);
  const built = stallOnEveryBuildFlowing(tv, 5 * 60, decoding(tv));
  assert.deepStrictEqual(built, [0], 'ilk oturumda kurma yok: ' + built.join(','));
  assert.match(tv.platform.diagnostics(), /t\+ fr \d+ · ev stalled · stall 1 ok/);
  assert.strictEqual(storage['couchsubs.hdmiFlowCounter'], '1', 'akış ölçülebilir diye saklandı');
  assert.strictEqual(storage[NOISE_KEY], undefined, 'gürültü öğrenmesine gerek kalmadı');
});

test('webOS HDMI 0.9.87: currentTime\'ı ilerleten TV\'de ilk oturumda üç kurma yok; PS tuşundan dönüşte de kurulmaz', () => {
  const tv = startTv({ storage: {} });
  tv.show(2);
  const step = ticking(tv);
  assert.deepStrictEqual(stallOnEveryBuildFlowing(tv, 3 * 60, step), [0]);
  for (let press = 0; press < 3; press++) {
    tv.hide();
    tv.advance(8000);
    tv.unhide();
    tv.document.fire('webOSRelaunch');
    tv.focus();
    tv.video.fire('stalled');
    for (let s = 0; s < 60; s++) { step(); tv.advance(1000, step); }
  }
  assert.strictEqual(tv.videos.length, 1, 'akan görüntüye hiç dokunulmadı');
});

test('webOS HDMI 0.9.87: sayaç stalled\'dan 1,5 sn sonra değil ama birkaç sn içinde ilerlerse görüntü akıyordur', () => {
  const storage = { 'couchsubs.hdmiFlowCounter': '1' };
  const tv = startTv({ storage });
  tv.show(2);
  tv.video.start();
  tv.advance(3000);
  assert.match(tv.platform.diagnostics(), /t= flow/, 'önceki oturumdan biliniyor');
  tv.video.fire('stalled');
  tv.advance(2500);
  assert.strictEqual(tv.videos.length, 1, 'akışı bilinen TV\'de 1,5 sn sonra kurulmaz');
  tv.video.webkitDecodedFrameCount = 90;
  tv.advance(10000);
  assert.strictEqual(tv.videos.length, 1);
  assert.match(tv.platform.diagnostics(), /stall 1 ok/);
});

test('webOS HDMI 0.9.87: akan görüntü gerçekten donarsa (birkaç sn kare yok) stalled yine kurdurur', () => {
  const tv = startTv({ storage: {} });
  tv.show(2);
  const step = decoding(tv);
  tv.video.start();
  for (let s = 0; s < 30; s++) { step(); tv.advance(1000, step); }
  tv.video.frozen = true;
  tv.video.fire('stalled');
  tv.advance(3500);
  assert.strictEqual(tv.videos.length, 1, 'donma birkaç sn sürmeden kurulmaz');
  tv.advance(2000);
  assert.strictEqual(tv.videos.length, 2, 'donan görüntü yeniden kuruldu');
  assert.match(tv.platform.diagnostics(), /rebuilt 1 \(ev stalled\)/);
});

test('webOS HDMI 0.9.87: kare sayacı duran görüntü (siyah ekran) gözcü tarafından kurulur', () => {
  const tv = startTv();
  tv.show(2);
  const step = decoding(tv);
  tv.video.start();
  for (let s = 0; s < 30; s++) { step(); tv.advance(1000, step); }
  tv.video.frozen = true;
  tv.advance(30000);
  assert.strictEqual(tv.videos.length, 2);
  assert.match(tv.platform.diagnostics(), /rebuilt 1 \(stalled\)/);
});

test('webOS HDMI 0.9.94 (#1055): kare sayacı hep 0 olan TV\'de (t= fr 0) çeviri başında ve PS tuşundan dönüşte görüntü yeniden kurulmaz', () => {
  // LG 65UR91006LA webOS 33.31.75: getVideoPlaybackQuality var ama totalVideoFrames hep 0, currentTime hep 0.
  const tv = startTv({ storage: {} });
  tv.show(2);
  tv.video.webkitDecodedFrameCount = 0;
  tv.video.start();
  tv.advance(3000);
  tv.video.fire('stalled');
  tv.advance(30000);
  assert.strictEqual(tv.videos.length, 1, 'taze stalled kurdurmadı');
  for (let press = 0; press < 3; press++) {
    tv.hide();
    tv.advance(8000);
    tv.unhide();
    tv.document.fire('webOSRelaunch');
    tv.focus();
    tv.video.fire('stalled');
    tv.advance(60000);
  }
  assert.strictEqual(tv.videos.length, 1, 'PS tuşundan dönüşte (resume) kurulmadı');
  assert.match(tv.platform.diagnostics(), /hdmi playing rs4 1920x1080 t= fr 0 · ev stalled · stall \d+ blind/);
  assert.doesNotMatch(tv.platform.diagnostics(), /rebuilt/);

  // Gerçek hata olunca yine kurulur.
  tv.video.error = { code: 4 };
  tv.video.fire('error');
  tv.advance(5000);
  assert.strictEqual(tv.videos.length, 2, 'hata verince kuruldu');
});

// 0.9.111 (#1323): LG OLED55CS3VA webOS 43.21.96, kare sayacı hep 0 (t= fr 0). Panel: "ev stalled · stall 1 blind · rl 7",
// bg 5, "saver reply failed: The response is too late @2", bağlantı yok; "rebuilt" hiç yok.
const BLACK_KEY = 'couchsubs.hdmiBlindBlack';
const SAVER_REGISTER = 'luna://com.webos.service.tvpower/power/registerScreenSaverRequest';
const SAVER_RESPONSE = 'luna://com.webos.service.tvpower/power/responseScreenSaverRequest';

function blindTv(options = {}) {
  const tv = startTv({ storage: options.storage || {}, luna: options.luna });
  tv.show(2);
  tv.video.webkitDecodedFrameCount = 0;
  tv.video.start();
  return tv;
}

test('webOS HDMI #1323: geç gelen ekran koruyucu yanıtı, öne gelişler ve yeniden açılışlar görüntüyü kurdurmaz, sayfayı yenilemez', () => {
  const tv = blindTv({
    luna: (uri) => {
      if (uri === SAVER_REGISTER) return { returnValue: true, subscribed: true };
      if (uri === SAVER_RESPONSE) return { returnValue: false, errorCode: -1, errorText: 'The response is too late' };
      return null;
    }
  });
  tv.platform.init();
  tv.advance(3000);
  tv.video.fire('stalled');
  tv.advance(2 * 60000);
  for (let ask = 1; ask <= 2; ask++) {
    // TV boşta sayıp ekran koruyucuyu soruyor; yanıt geç kalıyor, TV ekran koruyucuya geçip sayfayı arkaya atıyor.
    tv.window.__screenSaverBridge.onservicecallback(JSON.stringify({ state: 'Active', timestamp: 1000 + ask }));
    tv.advance(500);
    tv.hide();
    tv.advance(20000);
    tv.unhide();
    tv.advance(60000);
  }
  // Telefonun bekçisi uygulamayı art arda yeniden açıyor (rl 7).
  for (let i = 0; i < 7; i++) {
    tv.document.fire('webOSRelaunch');
    tv.advance(5000);
  }
  tv.advance(5 * 60000);
  assert.match(tv.window.__screenSaverStatus, /reply failed: The response is too late @2 \(new\)/);
  assert.strictEqual(tv.videos.length, 1, 'görüntü yeniden kurulmadı');
  assert.strictEqual(tv.video.loads, 0, 'boru hattı bırakılmadı');
  assert.strictEqual(tv.host.children.length, 1);
  assert.doesNotMatch(tv.platform.diagnostics(), /rebuilt/);
  assert.match(tv.platform.diagnostics(), /t= fr 0 · ev stalled · stall 1 blind 3s · blind resume 2 · rl 7 · snd/);
});

test('webOS HDMI #1323: olay akışı (stalled) taze görüntüde ve öne gelişin ardından dokunulmaz; oturmuş görüntüde bir kez kurdurur', () => {
  const tv = blindTv();
  // Yeni <video>'nun taze 'stalled'ı (#1055): dokunulmaz.
  tv.advance(3000);
  tv.video.fire('stalled');
  tv.advance(60000);
  assert.strictEqual(tv.videos.length, 1);
  // PS tuşundan dönüş ve hemen ardından gelen 'stalled': dokunulmaz.
  tv.hide();
  tv.advance(8000);
  tv.unhide();
  tv.advance(2000);
  tv.video.fire('stalled');
  tv.advance(60000);
  assert.strictEqual(tv.videos.length, 1, 'öne gelişin ardındaki stalled kurdurmadı');
  // Oyunun ortasında (uzaktan oynatma başlarken HDMI yeniden el sıkışır) gelen 'stalled': görüntü düştü, bir kez kurulur.
  tv.advance(60000);
  tv.video.fire('stalled');
  tv.advance(1000);
  assert.strictEqual(tv.videos.length, 1, 'hemen değil');
  tv.advance(3000);
  assert.strictEqual(tv.videos.length, 2, 'oturmuş görüntüde stalled kurdurdu');
  assert.match(tv.platform.diagnostics(), /rebuilt 1 \(ev stalled\)/);
  // Yeni <video>'nun taze 'stalled'ı yine dokunulmaz: döngü yok.
  tv.video.webkitDecodedFrameCount = 0;
  tv.video.start();
  tv.advance(3000);
  tv.video.fire('stalled');
  tv.advance(60000);
  assert.strictEqual(tv.videos.length, 2, 'yeni görüntünün taze stalled\'ı kurdurmadı');
  // 0.9.116: öğrenilmemiş TV'de oturum başına bir kez; oturmuş görüntünün ikinci 'stalled'ı dokunulmaz.
  tv.video.fire('stalled');
  tv.advance(5000);
  assert.strictEqual(tv.videos.length, 2, 'aynı oturumda ikinci kez kurulmadı');
  assert.match(tv.platform.diagnostics(), /stall \d+ blind \d+s/);
  // Görüntü gerçekten siyahtı: kullanıcı girişi yeniden seçer (TV öğrenilir, yeni oturum).
  tv.advance(30000);
  tv.show(2);
  tv.advance(2000);
  assert.strictEqual(tv.videos.length, 3, 'girişi yeniden seçmek kurdu');
  tv.video.webkitDecodedFrameCount = 0;
  tv.video.start();
  // Öğrenilmiş TV'de oturmuş görüntüde 10 dakikada en çok iki kez.
  for (let i = 0; i < 3; i++) {
    tv.advance(60000);
    tv.video.fire('stalled');
    tv.advance(5000);
    if (tv.video.readyState === 0) {
      tv.video.webkitDecodedFrameCount = 0;
      tv.video.start();
    }
  }
  assert.strictEqual(tv.videos.length, 4, 'öğrenilmiş TV: 10 dakikada iki (öncekiyle birlikte)');
  assert.match(tv.platform.diagnostics(), /blk/);
});

// 0.9.116 (beta.102-104): "son TV güncellemesinden sonra ekran sürekli göz kırpıyor, gidip geliyor". 0.9.111'de sağlam
// görüntüde de 'stalled' gönderen akışı görünmeyen TV, oyun boyunca her 10 dakikada iki kez yeniden kuruluyordu.
test('webOS HDMI 0.9.116: sağlam görüntüde düzenli stalled gönderen TV oyun boyunca göz kırpmaz (oturumda en çok bir kurma)', () => {
  const storage = {};
  const lines = [];
  const tv = blindTv({ storage });
  tv.window.COUCHSUBS_TVLOG = (text) => lines.push(text);
  // İki saat, her 2 dakikada bir 'stalled' (görüntü sağlam; kullanıcı hiçbir şey yapmıyor).
  for (let minute = 0; minute < 120; minute += 2) {
    tv.advance(2 * 60000);
    tv.video.fire('stalled');
    tv.advance(5000);
    if (tv.video.readyState === 0) {
      tv.video.webkitDecodedFrameCount = 0;
      tv.video.start();
    }
  }
  tv.advance(60000);
  // 0.9.111-0.9.115: 10 dakikada iki, iki saatte 24 kurma.
  assert.strictEqual(tv.videos.length, 2, 'iki saatte yalnız bir kez yeniden kuruldu');
  assert.strictEqual(storage[BLACK_KEY], undefined, 'TV öğrenilmedi');
  // Her kurma nedeniyle günlüğe yazılır.
  const rebuilds = lines.filter((l) => /^hdmi rebuild/.test(l));
  assert.strictEqual(rebuilds.length, 1);
  assert.match(rebuilds[0], /^hdmi rebuild \(ev stalled blind \d+s #1\)$/);
  // Girişin yeniden seçilmesi (yeniden açma) de yazılır.
  tv.show(2);
  assert.strictEqual(lines[lines.length - 1], 'hdmi open 2 (same input reselected)');
});

test('webOS HDMI 0.9.116: öğrenilmiş TV\'de öne geliş döngüsü (PS/CEC, bekçi) görüntüyü durmadan yeniden kurmaz', () => {
  const storage = { [BLACK_KEY]: '1' };
  const lines = [];
  const tv = blindTv({ storage });
  tv.window.COUCHSUBS_TVLOG = (text) => lines.push(text);
  tv.advance(60000);
  // Konsol TV'yi her 20 sn'de kendi girişine geçiriyor, bekçi uygulamayı geri getiriyor (10 dakika).
  for (let i = 0; i < 30; i++) {
    tv.hide();
    tv.advance(3000);
    tv.unhide();
    tv.document.fire('webOSRelaunch');
    tv.advance(4000);
    if (tv.video.readyState === 0) {
      tv.video.webkitDecodedFrameCount = 0;
      tv.video.start();
    }
    tv.advance(13000);
  }
  const resumes = lines.filter((l) => /^hdmi rebuild \(resume/.test(l)).length;
  // 5 dakikada en çok üç: 10 dakikada en çok altı (eskiden her öne gelişte, 30).
  assert.ok(resumes >= 1 && resumes <= 6, 'öne gelişte kurma sınırlı: ' + resumes);
  assert.match(tv.platform.diagnostics(), /blind loop \d+/);
  assert.ok(lines.some((l) => /^hdmi resume skipped \(blind loop \d+\)$/.test(l)));
  assert.ok(lines.some((l) => /^relaunch \(webOS, rl \d+\)$/.test(l)));
  // Tek öne geliş (seyrek PS tuşu) eskisi gibi kurulur.
  tv.advance(10 * 60000);
  const before = tv.videos.length;
  tv.hide();
  tv.advance(3000);
  tv.unhide();
  tv.advance(5000);
  assert.strictEqual(tv.videos.length, before + 1, 'seyrek öne gelişte kuruldu');
});

test('webOS HDMI #1323: öne gelişte kararan TV kullanıcı girişi yeniden seçince öğrenilir; sonra öne gelişte kurulur', () => {
  const storage = {};
  const tv = blindTv({ storage });
  tv.advance(60000);
  tv.hide();
  tv.advance(10000);
  tv.unhide();
  tv.advance(5000);
  assert.strictEqual(tv.videos.length, 1, '0.9.94 gibi dokunulmadı');
  assert.match(tv.platform.diagnostics(), /blind resume 1/);
  // Ekran siyah: kullanıcı kumandada 2'ye basar.
  tv.advance(30000);
  tv.show(2);
  tv.advance(2000);
  assert.strictEqual(storage[BLACK_KEY], '1', 'TV saklandı');
  assert.match(tv.platform.diagnostics(), /blk/);

  // Sonraki açılış: öne gelişte görüntü bir kez yeniden kurulur, taze stalled yine dokunulmaz.
  const next = blindTv({ storage });
  next.advance(3000);
  next.video.fire('stalled');
  next.advance(60000);
  assert.strictEqual(next.videos.length, 1, 'taze stalled kurdurmadı');
  next.hide();
  next.advance(10000);
  next.unhide();
  next.advance(5000);
  assert.strictEqual(next.videos.length, 2, 'öne gelişte kuruldu');
  assert.match(next.platform.diagnostics(), /rebuilt 1 \(resume\)/);
});

test('webOS HDMI #1323: girişi yeniden seçmeyen TV (#1055, 65UR91006LA) öğrenilmez; uzun süre sonra yeniden seçim de saymaz', () => {
  const storage = {};
  const tv = blindTv({ storage });
  for (let press = 0; press < 3; press++) {
    tv.advance(60000);
    tv.hide();
    tv.advance(8000);
    tv.unhide();
    tv.document.fire('webOSRelaunch');
    tv.advance(60000);
  }
  assert.strictEqual(tv.videos.length, 1);
  tv.advance(10 * 60000);
  tv.show(2);
  tv.advance(2000);
  assert.strictEqual(storage[BLACK_KEY], undefined);
});

test('webOS HDMI #643: ses adımları açıkken stalled olursa adımlar kapanır, yeni <video>\'ya dokunulmaz', () => {
  const tv = startTv({ steps: {}, luna: () => ({ returnValue: true }) });
  tv.show(2);
  const first = tv.video;
  const before = watchSound(first);
  first.start();
  tv.advance(3500);
  assert.ok(before.length > 0, 'açıkça istendiği için adımlar yapıldı');
  first.fire('stalled');
  tv.advance(3000);
  assert.strictEqual(tv.videos.length, 2);
  const touched = watchSound(tv.video);
  tv.video.start();
  tv.advance(10 * 60000);
  assert.deepStrictEqual(touched, []);
  assert.match(tv.platform.diagnostics(), / sx off stalled · /);
});

test('webOS HDMI #643: görüntü gelmeden gelen stalled yeniden kurdurmaz (gözcüye bırakılır)', () => {
  const tv = startTv();
  tv.show(2);
  tv.video.fire('stalled');
  tv.advance(3000);
  assert.strictEqual(tv.videos.length, 1);
  assert.match(tv.platform.diagnostics(), / · stall 1 nopic · /);
});

// 0.9.54, X'te LG OLED C2: PS5 soundbar üzerinden bağlı (soundbar TV'nin eARC girişinde, HDMI 2), çeviri başlayınca
// siyah ekran; PS5 doğrudan TV'ye takılınca düzeliyor. Giriş listesi (getAllInputStatus, LG belgelerinde yok) yalnız
// 0.9'dan beri okunan alanlarla sıralanır: konsol, sinyalli başka cihaz, sinyalli ses cihazı, sinyalsizler (aday değil).
function inputs(...list) {
  return list.map(([port, label, activate, extra]) => Object.assign({ id: 'HDMI_' + port, port, label, activate }, extra || {}));
}

test('webOS giriş sırası: konsol önce; soundbar/AV cihazı adıyla görünen giriş sinyalli cihazların sonunda', () => {
  const { platform } = startTv();
  const order = (devices) => JSON.parse(JSON.stringify(platform.rankInputs(devices).map((d) => [d.port, d.rank])));
  // PS5 HDMI 3'te, soundbar HDMI 2'de (eARC): PS5, sonra soundbar.
  assert.deepStrictEqual(order(inputs([1, 'HDMI 1', false], [2, 'Soundbar', true], [3, 'HDMI 3', true, { spdSourceDeviceInfo: 'GAME' }])),
    [[3, 0], [2, 3], [1, 4]]);
  // Soundbar PS5'i geçiriyor ve SPD'de GAME bildiriyorsa (görüntü HDMI 2'den geliyor) konsol odur.
  assert.deepStrictEqual(order(inputs([1, 'HDMI 1', true], [2, 'LG Sound Bar', true, { spdSourceDeviceInfo: 'GAME' }])),
    [[2, 0], [1, 2]]);
  // Konsol adı yok: sinyalli cihazlar giriş sırasıyla, ses cihazları (ad ya da SPD ürün adı) sonda.
  assert.deepStrictEqual(order(inputs([1, 'AV Receiver', true], [2, 'HDMI 2', true], [3, 'HDMI 3', true, { spdProductDescription: 'HW-Q990B' }], [4, 'HDMI 4', true])),
    [[2, 2], [4, 2], [1, 3], [3, 3]]);
  // Dinlenme modundaki PS5 (sinyalsiz, etiketi kalmış) sinyalli başka cihazdan önce.
  assert.deepStrictEqual(order(inputs([1, 'HDMI 1', true], [4, 'PS5', false])), [[4, 1], [1, 2]]);
  // HDMI olmayan girişler, eksik alanlar.
  assert.deepStrictEqual(order([{ id: 'COMP_1', port: 1, activate: true }, { id: 'HDMI_2' }, null]), [[2, 4]]);
});

test('webOS findConsolePort: seçilen giriş, adı ve görüntü gelmezse sırayla denenecek adaylar', () => {
  const reply = { devices: inputs([1, 'HDMI 1', false], [2, 'Soundbar', true], [3, 'PS5', true]) };
  const tv = startTv({ luna: (uri) => (uri.endsWith('/getAllInputStatus') ? reply : null) });
  let result = null;
  tv.platform.findConsolePort((...args) => { result = JSON.parse(JSON.stringify(args)); });
  assert.deepStrictEqual(result, [3, 'PS5', null, [3, 2]]);
  assert.strictEqual(tv.platform.inputLabel(2), 'Soundbar');
  assert.strictEqual(tv.platform.inputLabel(4), '');
  // Hiçbiri sinyalli değil ve konsol yok: bulunamadı (eskisi gibi).
  reply.devices = inputs([1, 'HDMI 1', false], [2, 'HDMI 2', false]);
  tv.platform.findConsolePort((...args) => { result = JSON.parse(JSON.stringify(args)); });
  assert.deepStrictEqual(result, [null, null, null, []]);
});

// LG siyah ekran (X, 27 Kas; LG C6 2026, webOS 26 ve güncellemeden sonra başka LG'ler; günlük yoktu): HDMI katmanının
// durumu, TV'nin sürümü/modeli ve görüntü modu bilgisayarın/telefonun günlüğüne gider.
test('webOS HDMI günlüğü: açılışta TV satırı (webOS, model, mod), ilk kare, hata, görüntüsüz giriş ve arkaya düşme yazılır', () => {
  const tv = startTv();
  const lines = [];
  tv.window.COUCHSUBS_TVLOG = (text) => lines.push(text);
  tv.advance(2100);
  const system = lines.filter((l) => /^tv /.test(l));
  assert.strictEqual(system.length, 1, JSON.stringify(lines));
  assert.match(system[0], /^tv webOS 7\.4\.0 55NANO756PA cr79 · mode in-app · scr /);
  assert.match(tv.platform.diagnostics(), / · webOS 7\.4\.0 55NANO756PA cr79 · scr .* · mode in-app$/);

  // Görüntüsüz giriş: 8 sn'den sonra <video> başına bir kez.
  tv.show(2);
  tv.advance(14000);
  const none = lines.filter((l) => /^hdmi no picture 2 rs0 /.test(l));
  assert.strictEqual(none.length, 1, JSON.stringify(lines));

  tv.show(3);
  tv.advance(500);
  tv.video.start();
  assert.ok(lines.some((l) => /^hdmi picture 3 1920x1080 rs4 ready after \d+ms$/.test(l)), JSON.stringify(lines));
  assert.strictEqual(lines.filter((l) => /^hdmi picture /.test(l)).length, 1, 'yalnız ilk kare');

  tv.video.error = { code: 3 };
  tv.video.fire('error');
  assert.ok(lines.includes('hdmi error 3 code 3'), JSON.stringify(lines));

  tv.hide();
  tv.hide();
  tv.unhide();
  assert.deepStrictEqual(lines.filter((l) => /^page /.test(l)), ['page hidden (hdmi playing)', 'page visible']);
});
