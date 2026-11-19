// SPDX-License-Identifier: AGPL-3.0-only
// Samsung TV paketinin (scripts/package-tizen.sh çıktısı) gerçek Chromium'da çizimi: ultrawide (3440x1440) ve 16:9
// (1920x1080) ekran, görünüm (viewport) etiketi dikkate alınarak (TV tarayıcısı gibi). #304: paketteki sabit
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

async function render(page, width, height) {
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
    await send('Page.navigate', { url: pathToFileURL(page).href }, sessionId);
    const expression = `new Promise(function (done) { setTimeout(function () {
      function box(el) { var b = el.getBoundingClientRect(); return { left: b.left, right: b.right, top: b.top, bottom: b.bottom }; }
      // Bilgi paneli (kumandada OK) açık çizilir: kullanıcının fotoğrafındaki sol üst kutu.
      document.getElementById('panel').className = '';
      // HDMI penceresi (#304): sahte TVWindow, '100%' için Samsung'un bildirdiği mantıksal dikdörtgen sayfa ölçüsüdür.
      var rects = [];
      window.tizen = { systeminfo: { getPropertyValue: function (name, ok) { ok({ connected: [{ type: 'HDMI', number: 1 }] }); } },
        tvwindow: { setSource: function (s, ok) { ok(); }, show: function (ok, fail, rect) {
          rects.push(rect.slice());
          ok(rect[2] === '100%' ? ['0px', '0px', innerWidth + 'px', innerHeight + 'px'] : rect); } } };
      window.COUCHSUBS_PLATFORM.showHdmi(1, null, function () {});
      done(JSON.stringify({
        rects: rects,
        viewport: document.querySelector('meta[name="viewport"]').getAttribute('content'),
        inner: [innerWidth, innerHeight],
        scale: visualViewport.scale,
        panel: box(document.getElementById('panel')),
        subtitle: box(document.getElementById('subtitle')),
      }));
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

    await t.test('paketteki görünüm device-width (Samsung 21:9 desteğinin şartı), ortak sayfa 1920 kalır', () => {
      assert.match(html, /<meta name="viewport" content="width=device-width">/);
      assert.doesNotMatch(html, /content="width=1920"/);
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
      // HDMI penceresi: '100%' 2580x1080 mantıksal kutu ekranın %75'iydi (son8); fiziksel ölçü (screen 3440x1440)
      // tarayıcıdan doğru okunur, pencere tam yükseklikte 16:9 ve ortada istenir.
      assert.deepEqual(r.rects, [['0', '0', '100%', '100%'], ['10px', '-180px', '2560px', '1440px']]);
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

    await t.test('telefon ve Android uygulamasının paketleri de aynı görünümü yazar', () => {
      for (const file of ['scripts/ios-tv-packages.sh', 'couchsubs-android/app/build.gradle']) {
        assert.match(fs.readFileSync(path.join(repo, file), 'utf8'),
          /'<meta name="viewport" content="width=1920">', '<meta name="viewport" content="width=device-width">'/, file);
      }
    });
  } finally {
    assert.equal(path.dirname(dist), path.resolve(os.tmpdir()));
    fs.rmSync(dist, { recursive: true, force: true });
  }
});
