// SPDX-License-Identifier: AGPL-3.0-only
// Samsung TV (tv-tizen/platform.js): ultrawide ekranda sayfa görünümü ve HDMI penceresi (#304). Sayfa sahte Tizen
// API'leriyle Node'da çalıştırılır; TV ya da tarayıcı gerekmez. Çalıştırma: node --test scripts/tv-tizen.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const tizenDir = path.join(__dirname, '..', 'tv-tizen');
const code = fs.readFileSync(path.join(tizenDir, 'platform.js'), 'utf8');

// innerWidth/innerHeight: uygulama yüzeyinin paketteki "width=device-width" görünümündeki ölçüsü.
function load(innerWidth, innerHeight) {
  const meta = { content: 'width=device-width', setAttribute(name, value) { if (name === 'content') this.content = value; } };
  const shown = [];
  const window = { innerWidth, innerHeight, addEventListener() {} };
  const tizen = {
    systeminfo: {
      getPropertyValue(name, ok) { ok({ connected: [{ type: 'HDMI', number: 1 }], disconnected: [] }); },
    },
    tvwindow: {
      setSource(source, ok) { ok(); },
      show(ok, fail, rect, type, z) { shown.push({ rect, type, z }); ok(); },
    },
  };
  const document = { querySelector: (q) => (q === 'meta[name="viewport"]' ? meta : null) };
  vm.runInNewContext(code, { window, document, tizen });
  return { platform: window.COUCHSUBS_PLATFORM, meta, shown };
}

test('16:9 TV (1080p ve 4K): görünüm 1920 piksel kalır', () => {
  assert.equal(load(1920, 1080).meta.content, 'width=1920');
  // Yuvarlama payı: 16:9'a yakın yüzey de değişmez.
  assert.equal(load(1920, 1079).meta.content, 'width=1920');
  // 16:10 ve 4:3 de geniş sayılmaz.
  assert.equal(load(1920, 1200).meta.content, 'width=1920');
});

test('21:9 ultrawide yüzey (Odyssey G8 3440x1440): sayfa 1080 piksel yükseklikte, ekran genişliğinde', () => {
  assert.equal(load(3440, 1440).meta.content, 'width=2580');
  // Eski görünümle ölçülen 1920x804 yüzey de aynı orana gelir.
  assert.equal(load(1920, 804).meta.content, 'width=2579');
  // 2560x1080 yüzey.
  assert.equal(load(1920, 810).meta.content, 'width=2560');
});

test('32:9 yüzey de geniş sayılır', () => {
  assert.equal(load(1920, 540).meta.content, 'width=3840');
});

test('viewportFor: geçersiz ölçüde dokunmaz, oranı korur', () => {
  const { platform } = load(1920, 1080);
  assert.equal(platform.viewportFor(0, 0), null);
  assert.equal(platform.viewportFor(undefined, 1080), null);
  assert.equal(platform.viewportFor(3440, 1440), 'width=2580');
  assert.equal(platform.viewportFor(5120, 1440), 'width=3840');
  assert.equal(platform.viewportFor(3840, 2160), null);
  assert.equal(platform.viewportFor(1440, 1080), null);
});

test('HDMI penceresi yüzeyin tamamını kaplar, sayfanın arkasında açılır', () => {
  for (const [w, h] of [[1920, 1080], [1920, 804]]) {
    const { platform, shown } = load(w, h);
    const statuses = [];
    platform.showHdmi(1, null, (s) => statuses.push(s));
    assert.deepEqual(statuses, ['loading', 'playing']);
    assert.equal(shown.length, 1);
    assert.deepEqual(JSON.parse(JSON.stringify(shown[0])), { rect: ['0', '0', '100%', '100%'], type: 'MAIN', z: 'BEHIND' });
  }
});

test('config.xml: yüzey ekranın tamamı (base_screen_resolution=fullscreen)', () => {
  const config = fs.readFileSync(path.join(tizenDir, 'config.xml'), 'utf8');
  assert.match(config, /<tizen:metadata key="http:\/\/tizen\.org\/metadata\/app_ui_type\/base_screen_resolution" value="fullscreen"\/>/);
});

// TV'nin kendi adresi (#484): Tizen sistem bilgisi adres vermezse Samsung ağ API'si sorulur.
function loadNetwork({ ethernet, wifi, samsung }) {
  const answer = (value) => (name, ok, fail) => {
    if (value === undefined) return fail(new Error('NotSupportedError'));
    ok({ ipAddress: value });
  };
  const tizen = {
    systeminfo: {
      getPropertyValue(name, ok, fail) {
        if (name === 'ETHERNET_NETWORK') return answer(ethernet)(name, ok, fail);
        if (name === 'WIFI_NETWORK') return answer(wifi)(name, ok, fail);
        ok({ connected: [], disconnected: [] });
      },
    },
  };
  const window = { innerWidth: 1920, innerHeight: 1080, addEventListener() {} };
  const document = { querySelector: () => null };
  const context = { window, document, tizen };
  if (samsung !== undefined) {
    context.webapis = { network: { getIp() { if (samsung instanceof Error) throw samsung; return samsung; } } };
  }
  vm.runInNewContext(code, context);
  return window.COUCHSUBS_PLATFORM;
}

function addressOf(platform) {
  let result = 'yanıt yok';
  platform.localAddress((ip) => { result = ip; });
  return result;
}

test('localAddress: Tizen sistem bilgisi adres verirse o kullanılır (kablolu önce)', () => {
  assert.equal(addressOf(loadNetwork({ ethernet: '192.168.1.40', wifi: '192.168.1.41', samsung: '10.0.0.2' })), '192.168.1.40');
  assert.equal(addressOf(loadNetwork({ ethernet: '', wifi: '192.168.1.41', samsung: '10.0.0.2' })), '192.168.1.41');
});

test('localAddress: sistem bilgisi adres vermezse Samsung ağ API\'si (webapis.network.getIp) sorulur', () => {
  assert.equal(addressOf(loadNetwork({ samsung: '192.168.0.23' })), '192.168.0.23');
  assert.equal(addressOf(loadNetwork({ ethernet: '', wifi: '', samsung: '192.168.0.23' })), '192.168.0.23');
});

test('localAddress: hiçbir yol adres vermezse null (app.js yaygın ev ağlarını tarar)', () => {
  assert.equal(addressOf(loadNetwork({})), null);
  assert.equal(addressOf(loadNetwork({ samsung: '' })), null);
  assert.equal(addressOf(loadNetwork({ samsung: '0.0.0.0' })), null);
  assert.equal(addressOf(loadNetwork({ samsung: new Error('SecurityError') })), null);
  assert.equal(loadNetwork({}).samsungIp(), null);
});

// Samsung TV'nin tanıdığı izinler ve hangi Tizen sürümünden beri olduğu (Samsung Smart TV API belgeleri: Tizen Web
// Device API, Samsung Product API, W3C). Tizen 2.4 (2016 TV'ler) listede olmayan ya da kendinden yeni izni içeren paketi
// sebep yazmadan "install failed[118]" ile reddeder (#497: http://tizen.org/privilege/power, Power API TV'de yok).
const TV_PRIVILEGES = {
  'http://tizen.org/privilege/tv.window': '2.3',
  'http://tizen.org/privilege/tv.inputdevice': '2.3',
  'http://tizen.org/privilege/tv.audio': '2.3',
  'http://tizen.org/privilege/tv.display': '2.3',
  'http://tizen.org/privilege/application.launch': '2.3',
  'http://tizen.org/privilege/internet': '2.3',
  'http://tizen.org/privilege/network.get': '2.3',
  'http://developer.samsung.com/privilege/network.public': '2.3',
};

function versionNumber(v) {
  const [major, minor = '0'] = v.split('.');
  return Number(major) * 100 + Number(minor);
}

test('config.xml: her izin Samsung TV\'de var ve paketin en düşük Tizen sürümünde de tanınıyor (#497)', () => {
  const config = fs.readFileSync(path.join(tizenDir, 'config.xml'), 'utf8').replace(/<!--[\s\S]*?-->/g, '');
  const required = (config.match(/required_version="([0-9.]+)"/) || [])[1];
  assert.equal(required, '2.4', '2016 Samsung TV\'ler (Tizen 2.4) kurabilmeli');
  const privileges = [...config.matchAll(/<tizen:privilege name="([^"]+)"\/>/g)].map((m) => m[1]);
  assert.ok(privileges.length > 0);
  for (const name of privileges) {
    assert.ok(name in TV_PRIVILEGES, `${name} Samsung TV izin listesinde yok; Tizen 2.4 paketi reddeder`);
    assert.ok(versionNumber(TV_PRIVILEGES[name]) <= versionNumber(required), `${name} Tizen ${required}'te yok`);
  }
  assert.ok(!privileges.includes('http://tizen.org/privilege/power'));
  // Ağ adresi yedeği (webapis.network.getIp) için gereken izin duruyor.
  assert.ok(privileges.includes('http://developer.samsung.com/privilege/network.public'));
});

test('platform.js: Samsung TV\'de olmayan Tizen Power API\'si çağrılmıyor (#497)', () => {
  assert.doesNotMatch(code, /tizen\.power/);
});
