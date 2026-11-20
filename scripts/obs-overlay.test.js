// SPDX-License-Identifier: AGPL-3.0-only
// OBS katmanının (core/Sources/CouchSubsCore/Resources/obs-overlay.html) gerçek Chromium yerleşimi.
// node --test scripts/obs-overlay.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER; ağ ve uygulama bağlantısı yok
// (EventSource sahte, olaylar test içinden verilir).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const overlay = path.join(__dirname, '..', 'core', 'Sources', 'CouchSubsCore', 'Resources', 'obs-overlay.html');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

// İki satıra bölünen (satır başına ~42 karakter) uzun çeviri; uygulamanın kendi penceresinde de iki satırdır.
const LONG = 'Bu bölgedeki bütün gizli belgeleri bulmadan güvenli bölgeye kesinlikle geri dönme.';
const box = (center, top = .85) => ({ left: center - .2, top, right: center + .2, bottom: top + .04 });
const cases = {
  fixed: { text: LONG },
  coverCenter: { text: LONG, box: box(.5) },
  coverRight: { text: LONG, box: box(.75) },
  above: { text: LONG, box: box(.5), placement: 'above' },
  coverBand: { text: LONG, box: box(.5), band: true },
  // Canlı yayında görüldü: İngilizce satır geniş (ekranın %60'ı), çeviri 42 karakterle iki dar satıra bölününce kutu
  // yazıdan her yanda ~%20 genişti. Örtüde de kutu yazıya oturmalı (çeviri örtü genişliğinde tek satır).
  // Metin her yazı tipinde (Linux'taki geniş yazı tiplerinde de) tek satıra sığacak uzunlukta.
  coverFit: { text: 'Yerel bağımlılar katalitik konvertör bulabilir.',
    box: { left: .2, top: .85, right: .8, bottom: .89 }, fit: true },
  fixedFit: { text: 'Yerel bağımlılar ona katalitik konvertörü eksik bir araba bulabilirler.', placement: 'fixed', fit: true },
};

function render(width, height) {
  const source = fs.readFileSync(overlay, 'utf8');
  // Sahte EventSource: katman bağlanınca dinleyiciler kaydedilir, test olayları kendisi verir.
  const stub = `<script>
    window.__listeners = {};
    window.EventSource = function () { this.addEventListener = function (n, f) { window.__listeners[n] = f; }; };
    function fire(name, data) { window.__listeners[name]({ data: JSON.stringify(data) }); }
  </script>`;
  const probe = `<pre id="result"></pre><script>
    var cases = ${JSON.stringify(cases)}, result = {};
    function measure() {
      var el = document.getElementById('line'), cs = getComputedStyle(el), b = el.getBoundingClientRect();
      var inner = el.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom);
      var range = document.createRange(); range.selectNodeContents(el);
      var rects = Array.from(range.getClientRects());
      var textWidth = Math.max.apply(null, rects.map(function (r) { return r.right; })) -
        Math.min.apply(null, rects.map(function (r) { return r.left; }));
      return { lines: Math.round(inner / parseFloat(cs.lineHeight)), wrapped: el.textContent.split('\\n').length,
        left: b.left, right: b.right, width: b.width, textWidth: textWidth,
        padding: parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight) };
    }
    for (var key in cases) {
      var c = cases[key];
      fire('style', { fontSize: 48, placement: c.placement || 'cover', backgroundShape: c.band ? 'band' : 'box' });
      fire('subtitle', { text: c.text, duration: 8000, box: c.box });
      result[key] = measure();
    }
    var box = {left:.43,top:.42,right:.52,bottom:.45};
    var reply = {text:'Yanıt', box:box, line:.025, surface:{background:'#2575a4',foreground:'#ffffff'}};
    var next = {text:'Git', box:{left:.49,top:.52,right:.52,bottom:.55}, line:.025,
      surface:{background:['#ff0000'],foreground:'#ffffff'}};
    fire('region', {id:'mission', text:'Görev', box:box, blocks:[reply]});
    fire('region', {id:'game-phone', text:'Yanıt / Git', box:box, blocks:[reply,next]});
    fire('style', {fontSize:48, backgroundShape:'band'});
    var regions = document.getElementById('regions');
    result.phone = Array.from(regions.querySelectorAll('.phone')).map(function(el) {
      var b = el.getBoundingClientRect(), cs = getComputedStyle(el);
      return {text:el.textContent, left:b.left, top:b.top, bottom:b.bottom,
        width:b.width, background:cs.backgroundColor, color:cs.color};
    });
    result.mission = regions.querySelector('.region').textContent;
    fire('region', {id:'game-phone', text:'Eski olay', box:box});
    result.legacy = regions.lastElementChild.className + ' ' + regions.lastElementChild.textContent;
    fire('region', {id:'game-phone', text:''});
    result.afterPhone = regions.textContent;
    // Görev kutusu altyazıyı kendi yerinden kaydırır (üst üste binmesin); telefon katman sırasını ayrı sına.
    fire('style', {fontSize:48, placement:'cover', backgroundShape:'box'});
    fire('subtitle', {text:'Konuşma sürüyor.', duration:8000, box:box});
    var lineBox = document.getElementById('line').getBoundingClientRect();
    var missionBox = regions.querySelector('.region').getBoundingClientRect();
    result.apart = lineBox.bottom <= missionBox.top || lineBox.top >= missionBox.bottom;
    fire('region', {id:'mission', text:''});
    fire('subtitle', {text:'Konuşma sürüyor.', duration:8000, box:box});
    var line = document.getElementById('line');
    // Saydam yayında tıklama kapalıdır. Yalnız testte metinleri hedeflenebilir yapıp gerçek çizim sırasını oku.
    line.style.pointerEvents = 'auto';
    function layers() {
      regions.querySelectorAll('.phone, .region').forEach(function(el) { el.style.pointerEvents = 'auto'; });
      return document.elementsFromPoint(innerWidth * .475, innerHeight * .435)
        .filter(function(el) { return el === line || el.matches('#regions .phone, #regions .region'); })
        .map(function(el) { return el.textContent; });
    }
    fire('region', {id:'game-phone', text:'Yanıt', box:box, blocks:[reply]});
    result.phoneLayers = layers();
    fire('region', {id:'game-phone', text:'Eski telefon', box:box});
    result.legacyLayers = layers();
    fire('region', {id:'game-phone', text:''});
    result.closedLayers = layers();
    result.viewport = { width: innerWidth, height: innerHeight };
    document.getElementById('result').textContent = btoa(unescape(encodeURIComponent(JSON.stringify(result))));
  </script>`;
  const html = source.replace('<head>', '<head>' + stub).replace('</body>', probe + '</body>');
  assert.ok(html.includes('window.__listeners') && html.includes('id="result"'), 'katman sayfası beklenen biçimde değil');
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-obs-test-'));
  try {
    // Pencere çerçevesi yerine tam hedef çözünürlükte bir iframe (OBS tarayıcı kaynağının boyu).
    const encoded = Buffer.from(html, 'utf8').toString('base64');
    const page = `<!doctype html><iframe id="frame" style="border:0;width:${width}px;height:${height}px"></iframe>
      <pre id="result"></pre><script>
      var frame = document.getElementById('frame');
      frame.contentDocument.open();
      frame.contentDocument.write(decodeURIComponent(escape(atob('${encoded}'))));
      frame.contentDocument.close();
      document.getElementById('result').textContent = frame.contentDocument.getElementById('result').textContent;
      </script>`;
    const file = path.join(temp, 'test.html'); fs.writeFileSync(file, page);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking',
      '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1',
      '--window-size=' + width + ',' + height, ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
      '--user-data-dir=' + path.join(temp, 'profile'), '--dump-dom', pathToFileURL(file).href],
      { encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi: ' + run.stdout.slice(-1000));
    return JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
  } finally {
    assert.equal(path.dirname(temp), path.resolve(os.tmpdir()));
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');
// OBS'te tarayıcı kaynağının olağan boyları.
for (const [width, height] of [[1920, 1080], [1280, 720]]) {
  test('OBS katmanı: ' + width + '×' + height, { skip: !browser && 'Chrome/Edge bulunamadı' }, async t => {
    const r = render(width, height);
    assert.deepEqual(r.viewport, { width, height });
    for (const key of Object.keys(cases).filter(key => !cases[key].fit)) {
      await t.test(key + ': uygulamanın böldüğü satır sayısı korunur', () => {
        // Çeviri 2 satıra bölünür; tarayıcı kutuyu daraltıp bir kez daha bölerse OBS'te 3-4 satır olurdu.
        assert.equal(r[key].wrapped, 2, JSON.stringify(r[key]));
        assert.equal(r[key].lines, 2, JSON.stringify(r[key]));
      });
    }
    await t.test('arka plan yalnız yazıyı kaplar (örtüde de iki yanda boş siyah alan kalmaz)', () => {
      for (const key of ['fixedFit', 'coverCenter', 'above']) {
        const empty = r[key].width - r[key].padding - r[key].textWidth;
        assert.ok(empty <= 4, key + ' ' + JSON.stringify(r[key]));
      }
      // Örtüde kutu en az İngilizce satır kadar geniştir; ondan fazlası yalnız yazı kadardır.
      const cover = .6 * width;
      assert.ok(r.coverFit.width - r.coverFit.padding <= Math.max(cover, r.coverFit.textWidth) + 4, JSON.stringify(r.coverFit));
      assert.equal(r.coverFit.lines, 1, JSON.stringify(r.coverFit));
      // Örtü yine İngilizce satırı kaplar.
      assert.ok(r.coverFit.left <= .2 * width + 1 && r.coverFit.right >= .8 * width - 1, JSON.stringify(r.coverFit));
    });
    await t.test('örtü kutusu ekranın dışına taşmaz', () => {
      for (const key of ['coverCenter', 'coverRight']) {
        assert.ok(r[key].left >= -1 && r[key].right <= width + 1, key + ' ' + JSON.stringify(r[key]));
      }
    });
    await t.test('telefon mesajları kendi yerinde kalır; eski ve normal olaylar çalışır', () => {
      const [reply, next] = r.phone;
      assert.equal(reply.text, 'Yanıt');
      assert.equal(reply.background, 'rgb(37, 117, 164)');
      assert.equal(reply.color, 'rgb(255, 255, 255)');
      assert.equal(next.text, 'Git');
      assert.equal(next.background, 'rgb(36, 39, 42)');
      assert.ok(Math.abs(next.left - .489 * width) < 1);
      assert.ok(Math.abs(next.width - .032 * width) < 1);
      assert.ok(reply.bottom <= next.top);
      assert.equal(r.mission, 'Görev');
      assert.equal(r.apart, true, 'görev kutusu ile altyazı üst üste binmemeli');
      assert.equal(r.legacy, 'region Eski olay');
      assert.equal(r.afterPhone, 'Görev');
    });
    await t.test('çakışan telefon yazısı ana altyazının altında kalır', () => {
      // Görev kutusu kaldırıldı (altyazıyı kaydırmasın); telefon altyazının altında kalır.
      assert.deepEqual(r.phoneLayers, ['Konuşma sürüyor.', 'Yanıt']);
      assert.deepEqual(r.legacyLayers, ['Konuşma sürüyor.', 'Eski telefon']);
      assert.deepEqual(r.closedLayers, ['Konuşma sürüyor.']);
    });
  });
}
