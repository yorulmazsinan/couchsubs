// SPDX-License-Identifier: AGPL-3.0-only
// Ölçekli LG sayfasında (#1098, 43LH590V, webOS 3.x, TV uygulaması 0.9.115) her çizim ekranın içinde ve yerinde.
// platform.js ekranı 1920'den dar (ya da piksel oranı 1 değil) bildiren LG'de sayfayı CSS zoom ile 1920x1080 uzayına
// sığdırır. Bu TV'nin tarayıcısı Chromium 38: kök öğenin clientWidth/clientHeight'ı ve getBoundingClientRect zaten
// ölçekli uzayda (1920x1080) gelir, yeni Chromium ekran pikselinde verir. 0.9.115 ölçüleri bir kez daha zoom'a bölüyordu:
// TV'nin tanı satırı "scr 1280x720 … z 0.6667 iw 1920x1080", altyazı "y 159-244/1619.9" (sayfa 2880x1620 sanıldı);
// "Ekranı çevir"de ekranın sağı ve altı çevrilmiyor, oyunun altyazısının çevirisi ve telefon görünmüyordu.
//
// Gerçek sayfa (index.html, platform.js, i18n.js, app.js) başsız Chromium'da, sahte sunucuyla (XHR /hello, EventSource):
// 1280x720 ekran, piksel oranı 1 ve 2; hem yeni Chromium hem Chromium 38 ölçüleri (kök clientWidth ve dikdörtgenler
// ölçekli uzayda) taklit edilir. Ölçülen: "Ekranı çevir"in dört köşedeki kutuları, alttaki oyun altyazısının çevirisi
// (sabit, örtsün, üstünde, altında) ve telefon kartları ekranın içinde ve özgün yerlerinde. Eski app.js (0.9.116)
// Chromium 38 ölçüleriyle sağ ve alt köşeyi ekranın dışına çizer (hata yeniden üretilir).
// Çalıştırma: node --test scripts/tv-webos-zoom.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const tvRoot = path.join(__dirname, '..', 'tv-webos');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

const surface = { background: '#202020', flat: true, foreground: '#f0f0f0' };
const look = { align: 'left', bold: true, condensed: false, upper: false };
// Bugünkü bilgisayar/telefon birebir alanlarını gönderir (app.js isExact → placeExact): örtü özgün kutu kadar, uzama yok.
const item = (text, box, align) => {
  const b = { left: box[0], top: box[1], right: box[2], bottom: box[3] };
  const cover = { left: b.left - 0.001, top: b.top - 0.002, right: b.right + 0.001, bottom: b.bottom + 0.002 };
  return { text, box: b, line: 0.03, cover, grow: cover, group: 0, bg: '#202020', bg2: '#202020', bgDir: 'h', fg: '#F0F0F0',
    weight: 700, upper: false, align: align || 'left', lineH: 0.03, style: Object.assign({}, look, { align: align || 'left' }), surface };
};
// "Ekranı çevir": dört köşe (sağdakiler sağa yaslı).
const corners = [
  item('Sol üst köşe', [0.03, 0.04, 0.13, 0.075]),
  item('Sağ üst köşe', [0.87, 0.04, 0.97, 0.075], 'right'),
  item('Sol alt köşe', [0.03, 0.9, 0.13, 0.935]),
  item('Sağ alt köşe', [0.87, 0.9, 0.97, 0.935], 'right'),
];
// Oyunun altyazısı ekranın altında (iPhone günlüğündeki alan: 0.62-0.97).
const subtitleBox = { left: 0.3, top: 0.87, right: 0.7, bottom: 0.93 };
// GTA 6 telefonu (gerçek karenin balonları, scripts/tv-phone-bubbles.test.js).
const bubble = (text, box) => ({ text, box: { left: box[0], top: box[1], right: box[2], bottom: box[3] }, line: 0.034,
  surface: { background: '#f6efe8', foreground: '#2a2a2a' } });
const phone = { id: 'game-phone', text: 'x', box: { left: 0.6, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: [
  bubble('KARAVANIMA! Anladın mı?', [0.62339, 0.26597, 0.74873, 0.3314]),
  bubble('O şeyleri senin için bıraktım', [0.63753, 0.44167, 0.78198, 0.50916]),
  bubble('Yeni mesaj', [0.64768, 0.59067, 0.75773, 0.62531]),
  bubble('Sağ ol dostum! Başka bir şey bulursan, bana getir', [0.61984, 0.65581, 0.7722, 0.80731]),
] };

// screen: TV'nin bildirdiği ekran (CSS pikseli), ratio: piksel oranı, legacy: Chromium 38 ölçüleri, source: app.js metni.
function render(screen, ratio, legacy, source, view) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-webos-zoom-'));
  try {
    for (const file of fs.readdirSync(tvRoot)) {
      if (/\.(js|css|png)$/.test(file)) fs.copyFileSync(path.join(tvRoot, file), path.join(temp, file));
    }
    if (source) fs.writeFileSync(path.join(temp, 'app.js'), source);
    fs.writeFileSync(path.join(temp, 'config.js'), 'window.COUCHSUBS_CONFIG = { server: "http://192.0.2.10:8787" };');
    const prelude = `<script>
      Object.defineProperty(window, 'screen', { value: { width: ${screen[0]}, height: ${screen[1]} } });
      Object.defineProperty(window, 'devicePixelRatio', { value: ${ratio} });
      window.PalmSystem = { deviceInfo: '{"platformVersion":"3.0.0","modelName":"43LH590V-ZE"}' };
      window.PalmServiceBridge = function () { this.call = function () {}; this.cancel = function () {}; };
      try { localStorage.clear(); } catch (e) {}
      // Gerçek (ekran pikseli) dikdörtgen: ölçüm bununla yapılır.
      window.TRUE_RECT = Element.prototype.getBoundingClientRect;
      // Sahte sunucu: /hello CouchSubs der (anahtarsız), diğer istekler boş yanıt.
      window.XMLHttpRequest = function () {
        var xhr = this;
        xhr.status = 0; xhr.responseText = '';
        xhr.open = function (method, url) { xhr.url = url; };
        xhr.send = function () {
          setTimeout(function () {
            xhr.status = 200;
            xhr.responseText = /\\/hello/.test(xhr.url) ? '{"app":"couchsubs","auth":0}' : '{}';
            if (xhr.onload) xhr.onload();
          }, 0);
        };
        xhr.setRequestHeader = function () {};
        xhr.abort = function () {};
      };
      window.EventSource = function (url) {
        var source = this;
        source.listeners = {};
        source.readyState = 1;
        source.addEventListener = function (name, fn) { (source.listeners[name] = source.listeners[name] || []).push(fn); };
        source.close = function () { source.readyState = 2; };
        source.fire = function (name, data) {
          (source.listeners[name] || []).forEach(function (fn) { fn({ data: JSON.stringify(data) }); });
        };
        window.STREAM = source;
        setTimeout(function () { if (source.onopen) source.onopen(); }, 0);
      };
    </script>`;
    // Chromium 38 (LG webOS 3.x) ölçüleri: CSS zoom'lu sayfada dikdörtgenler ölçekli uzayda (TV'nin tanı satırı: altyazı
    // "y 159-244", fotoğrafta ekranın ~%13'ünde; kök clientWidth ise görünüm genişliği, "iw 1920x1080").
    const legacyShim = `<script>(function () {
      var zoom = window.COUCHSUBS_ZOOM || 1;
      if (zoom === 1) return;
      function scaled(r) {
        return { left: r.left / zoom, top: r.top / zoom, right: r.right / zoom, bottom: r.bottom / zoom,
          width: r.width / zoom, height: r.height / zoom, x: r.left / zoom, y: r.top / zoom };
      }
      Element.prototype.getBoundingClientRect = function () { return scaled(window.TRUE_RECT.call(this)); };
      var rangeRects = Range.prototype.getClientRects;
      Range.prototype.getClientRects = function () {
        var list = rangeRects.call(this), out = [];
        for (var i = 0; i < list.length; i++) out.push(scaled(list[i]));
        return out;
      };
    })();</script>`;
    const probe = `<script>setTimeout(function () {
      var W = window.innerWidth, H = window.innerHeight;
      function rect(el) { var r = window.TRUE_RECT.call(el); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom }; }
      function wait(ms, fn) { setTimeout(fn, ms); }
      var out = { W: W, H: H, zoom: window.COUCHSUBS_ZOOM || 1, connected: !!window.STREAM, subtitles: {} };
      var es = window.STREAM;
      if (!es) { finish(); return; }
      es.fire('style', { placement: 'fixed', fontSize: 46, background: 80 });
      es.fire('screen', { items: ${JSON.stringify(corners)}, duration: 60000 });
      wait(200, function () {
        out.corners = Array.prototype.slice.call(document.querySelectorAll('#screen .item')).map(function (el) {
          var r = rect(el); r.text = el.textContent;
          // Yazı boyu ekran pikselinde (sayfa uzayındaki boy x ölçek).
          r.font = parseFloat(getComputedStyle(el.querySelector('.exact-line') || el).fontSize) * (window.COUCHSUBS_ZOOM || 1);
          return r;
        });
        es.fire('screen-clear', {});
        es.fire('region', ${JSON.stringify(phone)});
        wait(200, function () {
          out.phone = Array.prototype.slice.call(document.querySelectorAll('#regions .item, #regions .region-blocks > *'))
            .filter(function (el) { return el.textContent && el.className.indexOf('phone-panel') < 0; })
            .map(function (el) { var r = rect(el); r.text = el.textContent; return r; });
          es.fire('region-clear', {});
          var modes = ['fixed', 'cover', 'above', 'below'];
          (function next(i) {
            if (i >= modes.length) { finish(); return; }
            es.fire('style', { placement: modes[i], fontSize: 46, background: 80 });
            es.fire('subtitle', { text: 'Zaman dalgası çekirdeği dengelendi.', duration: 60000, box: ${JSON.stringify(subtitleBox)} });
            wait(200, function () {
              var cover = document.getElementById('subtitle-cover');
              out.subtitles[modes[i]] = { text: rect(document.getElementById('subtitle-text')),
                cover: cover.className === 'hidden' ? null : rect(cover),
                hidden: document.getElementById('subtitle').className === 'hidden' };
              es.fire('clear', {});
              next(i + 1);
            });
          })(0);
        });
      });
      function finish() {
        var row = document.getElementById('st-platform');
        out.diag = row ? row.textContent : '';
        out.error = (document.getElementById('st-error') || {}).textContent || '';
        var pre = document.createElement('pre'); pre.id = 'result';
        pre.textContent = btoa(unescape(encodeURIComponent(JSON.stringify(out))));
        document.body.appendChild(pre);
      }
    }, 1500);</script>`;
    let html = fs.readFileSync(path.join(tvRoot, 'index.html'), 'utf8')
      .replace('<meta charset="utf-8">', '<meta charset="utf-8">' + prelude)
      .replace('<script src="app.js"></script>', (legacy ? legacyShim : '') + '<script src="app.js"></script>' + probe);
    fs.writeFileSync(path.join(temp, 'index.html'), html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=' + ratio,
      '--window-size=' + (view || screen).join(','), ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
      '--allow-file-access-from-files', '--virtual-time-budget=6000', '--user-data-dir=' + path.join(temp, 'profile'), '--dump-dom',
      pathToFileURL(path.join(temp, 'index.html')).href], { encoding: 'utf8', timeout: 60000, windowsHide: true });
    const match = (run.stdout || '').match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi: ' + (run.stderr || '').slice(-400));
    return JSON.parse(decodeURIComponent(escape(Buffer.from(match[1], 'base64').toString('binary'))));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

// Kutu ekranın içinde mi (bir piksel pay).
const inside = (r, W, H) => r.left >= -1 && r.top >= -1 && r.right <= W + 1 && r.bottom <= H + 1 && r.right > r.left && r.bottom > r.top;

// Bütün çizimlerin sorunları (boşsa her şey ekranın içinde ve yerinde).
function problems(got) {
  const out = [];
  const { W, H } = got;
  // Yerinde: özgün kutunun kenarından en çok ekranın %3'ü (yatayda) / %4'ü (dikeyde) uzakta.
  const near = (value, expected, size, share) => Math.abs(value - expected) <= size * share;
  if (!got.connected) return ['sahte sunucuya bağlanmadı: ' + got.error];
  if ((got.corners || []).length !== corners.length) out.push('köşe kutusu sayısı ' + (got.corners || []).length);
  (got.corners || []).forEach((r, i) => {
    const box = corners[i].box, right = corners[i].style.align === 'right';
    if (!inside(r, W, H)) out.push(`köşe "${r.text}" ekranın dışında: ${JSON.stringify(r)}`);
    if (!near(r.top, box.top * H, H, 0.04)) out.push(`köşe "${r.text}" üst kenarı ${Math.round(r.top)}, beklenen ~${Math.round(box.top * H)}`);
    const edge = right ? r.right : r.left, want = (right ? box.right : box.left) * W;
    if (!near(edge, want, W, 0.03)) out.push(`köşe "${r.text}" yan kenarı ${Math.round(edge)}, beklenen ~${Math.round(want)}`);
    // Yazı özgün satırın boyunda (satır yüksekliğinin ~%95'i); ölçü yanlış ölçeklenirse sığmıyor sanılıp küçülür.
    const nominal = corners[i].line * H * 0.95;
    if (!(r.font >= nominal * 0.8)) out.push(`köşe "${r.text}" yazısı küçüldü: ${r.font.toFixed(1)} / ${nominal.toFixed(1)}`);
  });
  if (!(got.phone || []).length) out.push('telefon kartı çizilmedi');
  (got.phone || []).forEach((r) => {
    const source = phone.blocks.find(b => b.text === r.text);
    if (!inside(r, W, H)) out.push(`telefon "${r.text}" ekranın dışında: ${JSON.stringify(r)}`);
    if (source && !near(r.left, source.box.left * W, W, 0.03)) out.push(`telefon "${r.text}" sol kenarı ${Math.round(r.left)}, beklenen ~${Math.round(source.box.left * W)}`);
    if (source && !near(r.top, source.box.top * H, H, 0.04)) out.push(`telefon "${r.text}" üst kenarı ${Math.round(r.top)}, beklenen ~${Math.round(source.box.top * H)}`);
  });
  for (const [mode, sub] of Object.entries(got.subtitles || {})) {
    if (sub.hidden) { out.push(`altyazı (${mode}) gizli`); continue; }
    if (!inside(sub.text, W, H)) out.push(`altyazı (${mode}) ekranın dışında: ${JSON.stringify(sub.text)}`);
    // Altta kalır: çevirinin üst kenarı ekranın üst yarısına çıkmaz.
    if (!(sub.text.top > H * 0.5)) out.push(`altyazı (${mode}) altta değil: ${JSON.stringify(sub.text)}`);
    if (mode === 'cover') {
      if (!sub.cover) out.push('örtü çizilmedi');
      else {
        if (!inside(sub.cover, W, H)) out.push('örtü ekranın dışında: ' + JSON.stringify(sub.cover));
        // Örtü oyundaki İngilizce satırı kaplar.
        if (!(sub.cover.left <= subtitleBox.left * W + 1 && sub.cover.right >= subtitleBox.right * W - 1 &&
              sub.cover.top <= subtitleBox.top * H + 1 && sub.cover.bottom >= subtitleBox.bottom * H - 1)) {
          out.push('örtü İngilizce satırı kaplamıyor: ' + JSON.stringify(sub.cover));
        }
      }
    }
  }
  return out;
}

const cases = [
  { name: '1280x720 oran 1, Chromium 38 (43LH590V)', screen: [1280, 720], ratio: 1, legacy: true },
  { name: '1280x720 oran 2, Chromium 38', screen: [1280, 720], ratio: 2, legacy: true },
  { name: '1280x720 oran 1, yeni Chromium', screen: [1280, 720], ratio: 1, legacy: false },
  { name: '1280x720 oran 2, yeni Chromium', screen: [1280, 720], ratio: 2, legacy: false },
  // Görünüm değişikliği tutmazsa (43LH590V'de 0.9.115): görünüm 1920 kalır, sayfa ölçeklenir; yerler yine ekrana göre.
  { name: 'ekran 1280x720 bildiren ama görünümü 1920 kalan TV, Chromium 38', screen: [1280, 720], ratio: 1, legacy: true, window: [1920, 1080] },
  { name: '1920x1080 oran 1 (ölçek yok)', screen: [1920, 1080], ratio: 1, legacy: false },
];

for (const c of cases) {
  test(`ölçekli LG sayfası ${c.name}: köşe kutuları, alttaki altyazı ve telefon ekranın içinde ve yerinde`,
    { skip: !browser && 'Chromium yok' }, () => {
      const got = render(c.screen, c.ratio, c.legacy, null, c.window);
      if (c.screen[0] < 1920) {
        assert.equal(got.zoom, 0.6667);
        // Tanı satırı sayfanın uzayını, görünümün sayfa açılırken alındığını, görünüm alanını ve sağ alt köşeyi yazar.
        assert.match(got.diag, new RegExp(`pg ${Math.round(got.W / 0.6667)}x${Math.round(got.H / 0.6667)} r `), got.diag);
        assert.match(got.diag, new RegExp(`early in ${got.W}x${got.H} br \\S+`), got.diag);
      }
      assert.deepEqual(problems(got), [], JSON.stringify(got));
    });
}

test('eski app.js (0.9.116) Chromium 38 ölçüleriyle köşe yazılarını küçültür (ölçü zoom\'a iki kez bölünüyordu)',
  { skip: !browser && 'Chromium yok' }, () => {
    const old = spawnSync('git', ['show', '5d524446:tv-webos/app.js'], { cwd: path.join(__dirname, '..'), encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    if (old.status !== 0) return; // sığ klon: eski sürüm yok
    const got = render([1280, 720], 1, true, old.stdout);
    const issues = problems(got);
    if (process.env.ZOOM_DEBUG) console.log(JSON.stringify(got.corners));
    assert.ok(issues.some(p => /yazısı küçüldü/.test(p)), 'eski hâlde köşe yazıları küçülmeliydi: ' + issues.join('\n'));
  });
