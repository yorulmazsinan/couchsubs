// SPDX-License-Identifier: AGPL-3.0-only
// Çizim kipleri (TV uygulaması 0.9.109, app.js exactMode / exactInput / exactTwins / placeExact) gerçek Chromium'da:
//  - beside (Sinan Bey: "SELAMLA  GREET"; beta.100: menülerde de): kutu yok, özgün yazı açık kalır; Türkçe hemen solunda,
//    aynı satır ve aynı yazı boyunda, özgüne yaslı, okunurluk konturuyla; listede (group) bütün Türkçeler aynı boyda.
//  - twin (beta.100): özgün kutu örtülmez; aynı zemin, kenar çizgisi, yuvarlak köşe, kuyruk ve kişi resmiyle AYNI BOYDA
//    ikiz kutu yanında; yazı küçülmez, uzun Türkçe satır kırar ve kutu aşağı uzar.
//  - Alanları eksik/eski gönderi örtme kipinde çizilir (eski bilgisayar bozulmaz).
// node --test scripts/tv-exact-modes.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const root = path.join(__dirname, '..', 'tv-webos');
const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

function slice(from, to) {
  const start = app.indexOf(from);
  const end = app.indexOf(to, start);
  assert.ok(start > 0 && end > start, 'TV işlevi bulunamadı: ' + from);
  return app.slice(start, end);
}

const W = 1920, H = 1080;
const px = (l, t, r, b) => ({ left: l / W, top: t / H, right: r / W, bottom: b / H });
const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const base = (extra) => Object.assign({ line: 40 / H, lineH: 40 / H, fg: '#FFFFFF', weight: 700, upper: true, align: 'center',
  surface: { background: '#3A3A3A', foreground: '#FFFFFF', flat: false },
  style: { align: 'center', bold: true, condensed: true, upper: true } }, extra);
const items = [
  // 0) Yanına yazma: özgün "GREET" 1000-1100; Türkçe solunda (spot 880-980, boş alan 700'e kadar).
  base({ text: 'SELAMLA', box: px(1002, 502, 1098, 538), cover: px(1000, 500, 1100, 540), bg: '#3A3A3A', bgPat: true,
    mode: 'beside', spot: px(880, 500, 980, 540), spotRoom: px(700, 500, 980, 540) }),
  // 1-2) İkiz: özgün balon 1400-1800 x 800-960 (resim 1412-1435, ad, mesaj); ikiz solunda, aynı boyda (960-1360), üstte
  // pembe kenar çizgisi; mesaj uzun: satır kırılır, kutu aşağı uzar.
  { text: 'Jason', box: px(1480, 820, 1580, 860), line: 40 / H, lineH: 40 / H, cover: px(1478, 818, 1582, 862),
    bg: '#E2EBD2', fg: '#202020', weight: 700, upper: false, align: 'left', mode: 'twin', scale: 1, radius: 20 / H,
    tail: 'left', twinBox: px(960, 800, 1360, 960), spot: px(1038, 818, 1142, 862), spotRoom: px(1038, 818, 1342, 862),
    icon: { src: PNG, box: px(972, 812, 995, 835) }, edge: { color: '#E040A0', top: 4 / H, right: 0, bottom: 0, left: 0 },
    surface: { background: '#E2EBD2', foreground: '#202020', flat: true }, style: { align: 'left', bold: true, condensed: false, upper: false } },
  { text: 'Uyandın mı, iyi misin? Bu sabah seni aradım ama açmadın, her şey yolunda mı?', box: px(1420, 880, 1760, 920),
    line: 40 / H, lineH: 40 / H, cover: px(1418, 878, 1762, 922),
    bg: '#E2EBD2', fg: '#202020', weight: 400, upper: false, align: 'left', mode: 'twin', scale: 1, radius: 20 / H,
    tail: 'left', twinBox: px(960, 800, 1360, 960), spot: px(978, 878, 1322, 922), spotRoom: px(978, 878, 1342, 922),
    icon: { src: PNG, box: px(972, 812, 995, 835) }, edge: { color: '#E040A0', top: 4 / H, right: 0, bottom: 0, left: 0 },
    surface: { background: '#E2EBD2', foreground: '#202020', flat: true }, style: { align: 'left', bold: false, condensed: false, upper: false } },
  // 3) Eski gönderi (kip yok): örtme.
  base({ text: 'ESKİ', box: px(200, 300, 300, 340), cover: px(198, 298, 302, 342), bg: '#202020' }),
  // 4) Kip var ama spot eksik: örtme.
  base({ text: 'EKSİK', box: px(200, 400, 300, 440), cover: px(198, 398, 302, 442), bg: '#202020', mode: 'beside' }),
  // 5-6) Liste (sağa yaslı tuş listesi): Türkçeler solda tek sütunda, aynı boyda (biri dar alanda küçülse de grup birlikte).
  base({ text: 'ORTALA', box: px(1700, 600, 1800, 640), cover: px(1700, 600, 1800, 640), bg: '#0073F1', align: 'right', group: 7,
    mode: 'beside', spot: px(1500, 600, 1600, 640), spotRoom: px(1300, 600, 1600, 640) }),
  base({ text: 'HEDEF BELİRLE', box: px(1640, 660, 1800, 700), line: 44 / H, cover: px(1640, 660, 1800, 700), bg: '#0073F1',
    align: 'right', group: 7, mode: 'beside', spot: px(1440, 660, 1600, 700), spotRoom: px(1300, 660, 1600, 700) }),
];

function render(list) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-modes-'));
  try {
    const html = `<!doctype html><meta charset="utf-8"><style>${fs.readFileSync(path.join(root, 'style.css'), 'utf8')}</style>
      <div id="regions" class="hidden"></div><div id="screen"></div><pre id="result"></pre><script>
      Object.defineProperty(window, 'innerWidth', { value: ${W} });
      Object.defineProperty(window, 'innerHeight', { value: ${H} });
      function $(id) { return document.getElementById(id); }
      function hideSubtitle() {}
      function resolveLayers() {}
      var diag = { regions: 0, big: 0 };
      var setApart = true;
      var fontBase = 46;
      ${slice('  function validBox(box)', '\n  //')}
      ${slice('  function fillText(el, text, icons)', '\n  //')}
      ${slice('  var screenTimer = null;', '\n  // --- Ek alanlar')}
      showScreen(${JSON.stringify(list || items)}, 20000);
      var out = Array.from($('screen').children).map(function (el) {
        var b = el.getBoundingClientRect(), cs = getComputedStyle(el);
        var lines = Array.from(el.querySelectorAll('.exact-line')).map(function (row) {
          var range = document.createRange();
          range.selectNodeContents(row);
          var r = range.getBoundingClientRect(), rb = row.getBoundingClientRect();
          return { text: row.textContent, left: r.left, right: r.right, top: rb.top, bottom: rb.bottom };
        });
        var img = el.querySelector('img'), tail = el.querySelector('.exact-tail');
        return { text: el.textContent, cls: el.className, left: b.left, top: b.top, right: b.right, bottom: b.bottom,
          bg: cs.backgroundColor, radius: cs.borderTopLeftRadius, bottomLeft: cs.borderBottomLeftRadius,
          shadow: cs.textShadow, font: parseFloat(cs.fontSize), lines: lines,
          img: img ? Object.assign({ radius: getComputedStyle(img).borderTopLeftRadius }, JSON.parse(JSON.stringify(img.getBoundingClientRect()))) : null,
          tail: !!tail };
      });
      $('result').textContent = btoa(unescape(encodeURIComponent(JSON.stringify(out))));
      </script>`;
    const file = path.join(temp, 'modes.html');
    fs.writeFileSync(file, html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=' + W + ',' + (H + 200),
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'), '--dump-dom',
      pathToFileURL(file).href], { encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi: ' + run.stdout.slice(-1000));
    return JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

function overlaps(a, l, t, r, b) { return a.right > l + 0.5 && a.left < r - 0.5 && a.bottom > t + 0.5 && a.top < b - 0.5; }

test('kipler: yanına yazma kutusuz ve özgünün solunda, liste aynı boyda, ikiz aynı boyda yanında, eski gönderi örtme', { skip: !browser && 'tarayıcı yok' }, () => {
  const drawn = render(); if (process.env.DUMP) console.log(JSON.stringify(drawn.map(e => [e.text, e.cls, e.lines.map(l => [l.text, l.left, l.right])])));
  // Sıra: ikiz panel önce, sonra öğeler.
  const panel = drawn.find(el => / twin/.test(el.cls) && !el.lines.length);
  assert.ok(panel, 'ikiz panel çizilir: ' + drawn.map(el => el.cls).join(' | '));
  assert.ok(drawn.indexOf(panel) < drawn.findIndex(el => el.text === 'Jason'), 'panel yazılardan önce');
  const beside = drawn.find(el => el.text === 'SELAMLA');
  const name = drawn.find(el => el.text === 'Jason');
  const message = drawn.find(el => el.text.indexOf('Uyandın mı') === 0);
  const old = drawn.find(el => el.text === 'ESKİ'), missing = drawn.find(el => el.text === 'EKSİK');

  // Yanına yazma.
  assert.equal(beside.bg, 'rgba(0, 0, 0, 0)', 'kutu yok: ' + beside.bg);
  assert.notEqual(beside.shadow, 'none', 'okunurluk konturu var');
  assert.ok(!overlaps(beside, 1000, 500, 1100, 540), 'özgün yazı açık kalır');
  assert.ok(beside.lines[0].right <= 980 + 1 && beside.lines[0].right >= 980 - 3, 'özgüne yaslı: ' + beside.lines[0].right);
  assert.ok(Math.abs(beside.top - 500) <= 1 && Math.abs(beside.bottom - 540) <= 1, 'aynı satır');
  assert.ok(Math.abs(beside.font - 0.95 * 40) <= 0.5, 'aynı yazı boyu: ' + beside.font);
  assert.equal(beside.lines[0].text, 'SELAMLA', 'büyük harf korunur');

  // İkiz.
  assert.equal(panel.bg, 'rgb(226, 235, 210)', 'özgün zemin rengi');
  assert.ok(parseFloat(panel.radius) >= 19, 'yuvarlak köşe: ' + panel.radius);
  assert.equal(panel.bottomLeft, '0px', 'kuyruklu köşe köşeli');
  assert.ok(panel.tail, 'kuyruk çizilir');
  assert.ok(Math.abs(panel.left - 960) <= 1, 'ikiz kutunun yerinde (özgünün solunda)');
  assert.ok(panel.right <= 1400, 'özgün balonu örtmez: ' + panel.right);
  assert.ok(Math.abs(panel.top - (800 - 4)) <= 1, 'kenar çizgisi kutunun dışında, üstte: ' + panel.top);
  assert.ok(panel.bottom > 960 + 20, 'uzun Türkçe: kutu aşağı uzar: ' + panel.bottom);
  assert.ok(panel.bottom >= message.lines[message.lines.length - 1].bottom, 'yazı panelin içinde');
  assert.ok(message.lines.length >= 2, 'satır kırılır (küçülmez)');
  assert.ok(panel.img && Math.abs(panel.img.left - 972) <= 1 && panel.img.radius === '50%', 'kişi resmi yuvarlak: ' + JSON.stringify(panel.img));
  for (const el of [name, message]) {
    assert.equal(el.bg, 'rgba(0, 0, 0, 0)', el.text + ': yazının kendi kutusu yok');
    assert.ok(!overlaps(el, 1400, 800, 1800, 960), el.text + ': özgün balon örtülmez');
    assert.ok(Math.abs(el.font - 0.95 * 40) <= 0.5, el.text + ': yazı özgün boyda (küçültme yok): ' + el.font);
  }

  // Liste: aynı boy, solda sağa yaslı tek sütun.
  const a = drawn.find(el => el.text === 'ORTALA'), b = drawn.find(el => el.text === 'HEDEF BELİRLE');
  assert.equal(a.font, b.font, 'listede aynı yazı boyu: ' + a.font + ' / ' + b.font);
  assert.ok(Math.abs(a.lines[0].right - b.lines[0].right) <= 2 && a.lines[0].right <= 1601, 'sağa yaslı tek sütun');
  for (const el of [a, b]) assert.equal(el.bg, 'rgba(0, 0, 0, 0)', el.text + ': arka plansız');

  // Eski/eksik gönderi: örtme.
  for (const el of [old, missing]) {
    assert.match(el.bg, /^rgb\(/, el.text + ': opak örtü');
    assert.ok(Math.abs(el.left - 198) <= 1, el.text + ': örtünün yerinde');
  }
});

// Sinan Bey (beta.100, 3419): ekranın sağ kenarındaki bildirimin ikizi ("- HARİTA GÜNCELLENDİ!") ekrandan taşıyordu.
// Türkçe sığmazsa ikiz panel yazısıyla birlikte sola kayar (TV 0.9.113); ekranın içinde kalır.
test('ikiz bildirim ekranın sağ kenarından taşmaz, yazısıyla birlikte sola kayar', { skip: !browser && 'tarayıcı yok' }, () => {
  const notice = { text: '- HARİTA GÜNCELLENDİ!', box: px(1752, 302, 1908, 338), line: 36 / H, lineH: 36 / H,
    cover: px(1750, 300, 1910, 340), bg: '#101010', fg: '#FFFFFF', weight: 700, upper: true, align: 'left', mode: 'twin',
    scale: 1, radius: 0, twinBox: px(1740, 350, 1916, 392), spot: px(1752, 352, 1908, 388), spotRoom: px(1752, 352, 1916, 388),
    surface: { background: '#101010', foreground: '#FFFFFF', flat: true }, style: { align: 'left', bold: true, condensed: false, upper: true } };
  const drawn = render([notice]);
  const panel = drawn.find(el => / twin/.test(el.cls) && !el.lines.length);
  const text = drawn.find(el => el.lines.length);
  assert.ok(panel && text, 'ikiz çizildi');
  assert.ok(panel.right <= W + 0.5 && panel.left >= 0, 'panel ekranın içinde: ' + panel.left + '-' + panel.right);
  for (const line of text.lines) assert.ok(line.right <= W + 0.5 && line.left >= -0.5, 'yazı ekranın içinde: ' + JSON.stringify(line));
  for (const line of text.lines) assert.ok(line.left >= panel.left - 0.5 && line.right <= panel.right + 0.5, 'yazı panelin içinde');
});
