// SPDX-License-Identifier: AGPL-3.0-only
// Samsung TV paketinin (scripts/package-tizen.sh çıktısı) gerçek Chromium'da çizimi: ultrawide (3440x1440), 16:9
// (1920x1080) ve 4K (3840x2160) ekran, görünüm (viewport) etiketi dikkate alınarak (TV tarayıcısı gibi). #304: paketteki sabit
// "width=1920" görünümü Samsung'un uygulamayı 21:9 ekranda 16:9 kutuda tutmasına yol açıyordu.
// Çalıştırma: node --test scripts/tv-tizen-screen.test.js (Tarayıcı yolu: COUCHSUBS_TEST_BROWSER)
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const repo = path.join(__dirname, '..');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));
const shell = process.platform === 'win32' ? null : '/bin/sh';

// Chrome DevTools protokolü (--remote-debugging-pipe: fd 3 yazma, fd 4 okuma; iletiler \0 ile ayrılır).
function devtools(proc) {
  let id = 0, buffer = '';
  const waiting = new Map();
  proc.stdio[4].on('data', chunk => {
    buffer += chunk.toString('utf8');
    let end;
    while ((end = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, end));
      buffer = buffer.slice(end + 1);
      const pending = waiting.get(message.id);
      if (!pending) continue;
      waiting.delete(message.id);
      message.error ? pending.reject(new Error(JSON.stringify(message.error))) : pending.resolve(message.result);
    }
  });
  return (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const message = { id: ++id, method, params };
    if (sessionId) message.sessionId = sessionId;
    waiting.set(message.id, { resolve, reject });
    proc.stdio[3].write(JSON.stringify(message) + '\0');
  });
}

// extra.cssBounds: sahte TVWindow dikdörtgeni o anki sayfa ölçüsünde sınırlar (4K QN900A); extra.yellow: Sarı tuşa
// kaç kez basılacağı (her basıştan sonra ölçülür).
async function render(page, width, height, extra = {}) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-tizen-screen-'));
  const proc = spawn(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
    '--no-default-browser-check', '--hide-scrollbars', '--remote-debugging-pipe', '--user-data-dir=' + path.join(temp, 'profile'),
    ...(process.platform === 'linux' ? ['--no-sandbox'] : []), 'about:blank'],
  { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
  try {
    const send = devtools(proc);
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    // mobile: görünüm etiketi TV tarayıcısındaki gibi uygulanır; ekran fiziksel çözünürlükte.
    await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: true,
      screenWidth: width, screenHeight: height }, sessionId);
    await send('Page.enable', {}, sessionId);
    // extra.display: Tizen SystemInfo DISPLAY (platform.js paneli sayfa yüklenirken okur).
    if (extra.display) {
      await send('Page.addScriptToEvaluateOnNewDocument', { source: 'window.tizen = { systeminfo: { getPropertyValue: ' +
        'function (name, ok) { ok(name === "DISPLAY" ? ' + JSON.stringify(extra.display) + ' : { connected: [] }); } } };' }, sessionId);
    }
    await send('Page.navigate', { url: pathToFileURL(page).href }, sessionId);
    const expression = `new Promise(function (done) { setTimeout(function () {
      function box(el) { var b = el.getBoundingClientRect(); return { left: b.left, right: b.right, top: b.top, bottom: b.bottom }; }
      // Bilgi paneli (kumandada OK) açık çizilir: kullanıcının fotoğrafındaki sol üst kutu.
      document.getElementById('panel').className = '';
      // extra.tall: panel ekrandan uzun (uzun tanı satırları, #886); Yeşil ile yeniden açılır, app.js küçültür.
      if (${JSON.stringify(!!extra.tall)}) {
        var filler = document.createElement('div');
        filler.style.height = '600px';
        document.getElementById('panel').appendChild(filler);
        document.getElementById('panel').className = 'hidden';
        var green = new Event('keydown');
        Object.defineProperty(green, 'keyCode', { value: 404 });
        document.dispatchEvent(green);
      }
      // HDMI penceresi (#304): sahte TVWindow (getRect yok; Samsung belgesindeki gibi istenen dikdörtgeni geri verir).
      var rects = [];
      var cssBounds = ${JSON.stringify(!!extra.cssBounds)};
      window.tizen = { systeminfo: { getPropertyValue: function (name, ok) { ok({ connected: [{ type: 'HDMI', number: 1 }] }); } },
        tvwindow: { setSource: function (s, ok) { ok(); }, show: function (ok, fail, rect) {
          rects.push(rect.slice().concat(['@' + innerWidth]));
          if (cssBounds && String(rect[2]).indexOf('%') < 0 && parseFloat(rect[2]) > innerWidth) {
            return fail({ name: 'NotSupportedError' });
          }
          ok(rect.slice()); } } };
      function snapshot() {
        return {
          rects: rects.map(function (r) { return cssBounds ? r : r.slice(0, 4); }),
          viewport: document.querySelector('meta[name="viewport"]').getAttribute('content'),
          inner: [innerWidth, innerHeight],
          scale: visualViewport.scale,
          zoom: document.documentElement.style.zoom || '',
          panel: box(document.getElementById('panel')),
          subtitle: box(document.getElementById('subtitle')),
          keys: document.getElementById('keys').textContent,
        };
      }
      var shots = [];
      var presses = ${Number(extra.yellow || 0)};
      window.COUCHSUBS_PLATFORM.showHdmi(1, null, function () {});
      function next() {
        shots.push(snapshot());
        if (shots.length > presses) return done(JSON.stringify(presses ? shots : shots[0]));
        window.COUCHSUBS_PLATFORM.togglePicture(function () {});
        setTimeout(next, 800);
      }
      setTimeout(next, ${extra.cssBounds ? 800 : 0});
    }, 1500); })`;
    const { result } = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    return JSON.parse(result.value);
  } finally {
    proc.kill();
    await new Promise(resolve => proc.exitCode !== null ? resolve() : proc.once('exit', resolve));
    assert.equal(path.dirname(temp), path.resolve(os.tmpdir()));
    // Chrome'un yardımcı süreçleri ana süreç çıktıktan sonra da profile yazabiliyor (sayfa ağda CouchSubs ararken):
    // geçici klasör silinemezse test başarısız sayılmaz.
    try {
      fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    } catch (e) {
      if (e.code !== 'ENOTEMPTY' && e.code !== 'EBUSY') throw e;
    }
  }
}

if (process.env.CI) assert.ok(browser, 'CI: Samsung çizim testi için Chrome gerekli');
const skip = (!browser && 'Chrome bulunamadı') || (!shell && 'sh yok (package-tizen.sh)');

test('Samsung paketi: ultrawide ve 16:9 ekranda sayfa ekranın tamamına çizilir', { skip, timeout: 120000 }, async t => {
  const dist = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-tizen-dist-'));
  try {
    const built = spawnSync(shell, [path.join(repo, 'scripts', 'package-tizen.sh')],
      { env: { ...process.env, COUCHSUBS_DIST: dist, TIZEN_PROFILE: '' }, encoding: 'utf8' });
    assert.equal(built.status, 0, built.stderr);
    const page = path.join(dist, 'tv-tizen', 'app', 'index.html');
    const html = fs.readFileSync(page, 'utf8');

    await t.test('paketteki görünüm ortak sayfadaki gibi sabit 1920 (Samsung UHD TV standart çözünürlüğü, 0.9.55)', () => {
      assert.match(html, /<meta name="viewport" content="width=1920">/);
      assert.doesNotMatch(html, /device-width/);
      assert.match(fs.readFileSync(path.join(repo, 'tv-webos', 'index.html'), 'utf8'), /<meta name="viewport" content="width=1920">/);
    });

    await t.test('3440x1440 (Odyssey G8): sayfa 2580x1080 görünümde, ekranın tamamında', async () => {
      const r = await render(page, 3440, 1440);
      assert.equal(r.viewport, 'width=2580');
      assert.deepEqual(r.inner, [2580, 1080]);
      // Bilgi paneli 16:9 kutunun içinde (soldan 440 + güvenli alan, fotoğraftaki gibi) değil, ekranın sol güvenli
      // alanında (1080p'deki 96 piksel, 1440 satırlık ekranda 128).
      assert.ok(Math.abs(r.panel.left * r.scale - 128) < 2, JSON.stringify(r));
      assert.ok(r.panel.right > r.panel.left, JSON.stringify(r));
      // Altyazı alanı tam genişlikte ortalanır.
      assert.ok(Math.abs((r.subtitle.left + r.subtitle.right) / 2 - 1290) < 2, JSON.stringify(r));
      // HDMI penceresi: 16:9 kutu sayfa (2580x1080) koordinatında, sınırlar içinde ve ortada istenir; 0.9.32'deki
      // ['10px','-180px','2560px','1440px'] alanın dışına taştığı için Samsung reddediyordu.
      // Ekran (3440x1440) sayfadan büyük: önce fiziksel ölçüde 16:9 kutu istenir. Bu sahte pencere her isteği kabul
      // ettiği için orada kalır; sayfa koordinatı kullanan TV bunu reddeder, kutu sayfada istenir (tv-tizen.test.js).
      assert.deepEqual(r.rects, [['0', '0', '100%', '100%'], ['440px', '0px', '2560px', '1440px']]);
    });

    await t.test('1920x1080 (16:9 TV): görünüm eskisi gibi 1920', async () => {
      const r = await render(page, 1920, 1080);
      assert.equal(r.viewport, 'width=1920');
      assert.deepEqual(r.inner, [1920, 1080]);
      assert.ok(Math.abs(r.panel.left - 96) < 2, JSON.stringify(r));
      assert.ok(Math.abs((r.subtitle.left + r.subtitle.right) / 2 - 960) < 2, JSON.stringify(r));
      // 16:9 TV'de HDMI penceresi eskisi gibi tek '100%' çağrısı.
      assert.deepEqual(r.rects, [['0', '0', '100%', '100%']]);
    });

    await t.test('8K/4K Samsung standart yüzeyde (QN900A, DISPLAY 7680x4320): tek 100% penceresi, Sarı listede', async () => {
      const r = await render(page, 1920, 1080, { cssBounds: true, display: { resolutionWidth: 7680, resolutionHeight: 4320 } });
      assert.deepEqual(r.rects, [['0', '0', '100%', '100%', '@1920']]);
      assert.equal(r.viewport, 'width=1920');
      assert.deepEqual(r.inner, [1920, 1080]);
      assert.equal(r.scale, 1);
      assert.equal(r.zoom, '');
      assert.match(r.keys, /(Sarı|Yellow)/);
    });

    await t.test('Ekranı 1920x1080 bildiren ultra geniş monitör (#304): Sarı listede, 21:9 tam genişlik denenir, sayfa 1920ye döner', async () => {
      const [full, wide] = await render(page, 1920, 1080, { cssBounds: true, yellow: 1,
        display: { resolutionWidth: 1920, resolutionHeight: 1080, physicalWidth: 154, physicalHeight: 87 } });
      const FULL = ['0', '0', '100%', '100%'];
      assert.deepEqual(full.rects, [[...FULL, '@1920']]);
      assert.match(full.keys, /(Sarı|Yellow)/);
      // 2560x1080 dikdörtgen alanın dışında (reddedilir), sonra '100%' 2560'lık görünümde; görünüm 1920'ye döner.
      assert.deepEqual(wide.rects.slice(1), [[...FULL, '@1920'], ['0px', '0px', '2560px', '1080px', '@1920'], [...FULL, '@2560']]);
      assert.equal(wide.viewport, 'width=1920');
      assert.deepEqual(wide.inner, [1920, 1080]);
      for (const side of ['left', 'right', 'top', 'bottom']) {
        assert.ok(Math.abs(wide.subtitle[side] - full.subtitle[side]) < 2, side + ' ' + JSON.stringify([full, wide]));
      }
    });

    // #886 (Odyssey G9 49", 32:9): bilgisayar/telefon ultra geniş monitöre paketi geniş yüzeyle kurar
    // (WideScreenPackage: config.xml'e base_screen_resolution=fullscreen, görünüm width=device-width). 0.9.27–0.9.54'te
    // olduğu gibi yüzey 32:9 açılır: PS5 görüntüsü 16:9 ortada, Sarı ile ekranın tamamı.
    const widePage = path.join(path.dirname(page), 'index-wide.html');
    fs.writeFileSync(widePage, html.replace('<meta name="viewport" content="width=1920">',
      '<meta name="viewport" content="width=device-width">'));
    const FULL = ['0', '0', '100%', '100%'];

    await t.test('Geniş yüzeyle kurulan paket 32:9 (3840x1080) ekranda: görüntü 16:9 ortada, Sarı ile ekranın tamamı', async () => {
      const [fit, fill] = await render(widePage, 3840, 1080, { yellow: 1 });
      assert.equal(fit.viewport, 'width=3840');
      assert.deepEqual(fit.inner, [3840, 1080]);
      assert.deepEqual(fit.rects, [FULL, ['960px', '0px', '1920px', '1080px']]);
      assert.match(fit.keys, /(Sarı|Yellow)/);
      // Sarı: '100%' (alanın tamamı, 3840x1080), 16:9 kutu istenmez.
      assert.deepEqual(fill.rects.slice(2), [FULL]);
      assert.ok(Math.abs((fill.subtitle.left + fill.subtitle.right) / 2 - 1920) < 2, JSON.stringify(fill));
      assert.ok(fill.panel.bottom <= 1080 + 1, JSON.stringify(fill));
    });

    await t.test('Geniş yüzeyle kurulan paket 5120x1440 ekranda da 3840x1080 görünümde, panel ekranın içinde', async () => {
      const r = await render(widePage, 5120, 1440);
      assert.equal(r.viewport, 'width=3840');
      assert.deepEqual(r.inner, [3840, 1080]);
      assert.ok(r.panel.bottom <= 1080 + 1 && r.panel.right <= 3840, JSON.stringify(r));
    });

    await t.test('Panel ekrandan uzunsa küçültülür, alt kenarı ekranın içinde kalır (16:9 ve 32:9)', async () => {
      for (const [p, w, h] of [[page, 1920, 1080], [widePage, 3840, 1080]]) {
        const r = await render(p, w, h, { tall: true });
        const height = r.inner[1];
        assert.ok(r.panel.bottom <= height - 50, JSON.stringify(r));
        assert.ok(Math.abs(r.panel.top - 54) < 2, JSON.stringify(r));
        assert.ok(r.panel.bottom - r.panel.top > height / 2, JSON.stringify(r));
      }
    });

    await t.test('telefon ve Android uygulamasının paketleri de görünümü değiştirmez', () => {
      for (const file of ['scripts/ios-tv-packages.sh', 'couchsubs-android/app/build.gradle']) {
        assert.doesNotMatch(fs.readFileSync(path.join(repo, file), 'utf8'), /device-width/, file);
      }
    });
  } finally {
    assert.equal(path.dirname(dist), path.resolve(os.tmpdir()));
    fs.rmSync(dist, { recursive: true, force: true });
  }
});
