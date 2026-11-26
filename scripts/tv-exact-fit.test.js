// SPDX-License-Identifier: AGPL-3.0-only
// Yerinde birebir çizim (TV uygulaması 0.9.102, app.js placeExact / exactLayout). İki bölüm:
//  1. Saf yerleşim: ortak deneme dosyasının (core/Tests/CouchSubsCoreTests/Fixtures/text-paint.json → exact) vakaları
//     Mac/iPhone (ScreenFit.exact), Windows (ScreenFit.Exact) ve Android (ScreenFit.exact) ile aynı sonucu vermeli.
//  2. Gerçek Chromium çizimi: kutu opak, köşesiz, gölgesiz; degrade zemin; sağa yaslı ipucu listesi tek boyda ve sağ
//     kenarı (tuş simgesi tarafı) yerinde; uzun çeviri boş sola uzar; yazı hiçbir zaman "…" ile kesilmez ve kutusundan
//     taşmaz; görev kartının iki satırı özgün satır aralığında; alanları göndermeyen eski bilgisayarda eski çizim.
// node --test scripts/tv-exact-fit.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const root = path.join(__dirname, '..', 'tv-webos');
const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'core', 'Tests', 'CouchSubsCoreTests', 'Fixtures',
  'text-paint.json'), 'utf8'));
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

const exactSource = slice('  var EXACT_FONT = ', '  // Satırların düz metindeki başlangıcı');

test('OBS katmanı TV ile aynı birebir yerleşimi kullanır', () => {
  const obs = fs.readFileSync(path.join(__dirname, '..', 'core', 'Sources', 'CouchSubsCore', 'Resources', 'obs-overlay.html'), 'utf8');
  const shared = exactSource.replace('phoneColor(item.bg) && phoneColor(item.fg)', 'exactColor(item.bg) && exactColor(item.fg)');
  assert.ok(obs.indexOf(shared) >= 0, 'obs-overlay.html exactLayout TV app.js ile aynı olmalı');
  assert.match(obs, /placeExact\(node, exact\)/);
});

test('saf yerleşim ortak vakalarla aynı (ScreenFit.exact)', () => {
  const context = { validBox: () => null, phoneColor: () => false };
  vm.createContext(context);
  vm.runInContext(exactSource + '\nthis.exactLayout = exactLayout;', context);
  for (const vector of fixture.exact) {
    const items = vector.items.map(item => ({ text: item.text, left: item.box[0], top: item.box[1], right: item.box[2],
      bottom: item.box[3], growLeft: Math.min(item.box[0], item.grow ? item.grow[0] : item.box[0]),
      growRight: Math.max(item.box[2], item.grow ? item.grow[1] : item.box[2]), line: item.line,
      pitch: item.pitch || item.line, rows: item.rows || 1, align: item.align,
      group: typeof item.group === 'number' ? item.group : null }));
    const placed = JSON.parse(JSON.stringify(context.exactLayout(items, (text, size) => Array.from(text).length * vector.charWidth * size)));
    assert.equal(placed.length, vector.expect.length, vector.id);
    placed.forEach((p, i) => {
      const e = vector.expect[i], name = vector.id + ' ' + e.lines.join('|');
      assert.deepEqual(p.lines, e.lines, name);
      for (const key of ['left', 'top', 'width', 'height', 'fontSize', 'lineHeight', 'rowHeight']) {
        assert.ok(Math.abs(p[key] - e[key]) <= 0.05, `${name} ${key}: ${p[key]} ≠ ${e[key]}`);
      }
    });
  }
});

// 1920x1080 ekranda, harita ipuçları (kareye oranla) ve görev kartı.
const W = 1920, H = 1080;
const px = (l, t, r, b) => ({ left: l / W, top: t / H, right: r / W, bottom: b / H });
const hint = (text, l, t, r, extra) => Object.assign({ text: text, box: px(l, t, r, t + 38), line: 38 / H,
  cover: px(l - 2, t - 2, r + 2, t + 40), grow: px(1300, t - 2, r + 2, t + 40), group: 0,
  bg: '#0A6BEB', bg2: '#0E74F0', bgDir: 'h', fg: '#FFFFFF', weight: 700, upper: true, align: 'right', lineH: 38 / H,
  surface: { background: '#0A6BEB', foreground: '#FFFFFF', flat: true },
  style: { align: 'right', bold: true, condensed: true, upper: true } }, extra || {});
const items = [
  hint('ORTALA', 1672, 780, 1792),
  hint('2B GÖRÜNÜM', 1694, 832, 1792),
  hint('İŞARET EKLE', 1636, 884, 1792),
  // Uzun çeviri, solunda boş alan var: kutu sola uzar, yazı boyu grubunkiyle aynı kalır.
  hint('HEDEF BELİRLE BURAYA ŞİMDİ', 1736, 936, 1792),
  hint('ÇIK', 1700, 988, 1792),
  // Görev kartı açıklaması: iki satır, özgün satır aralığı 54 piksel; dikey degrade.
  { text: 'Kenton\'ın dalış noktasında hazine ararken bekârlık partisine göz kulak ol.', box: px(282, 292, 880, 384),
    line: 38 / H, rows: 2, cover: px(280, 290, 882, 386), bg: '#14285A', bg2: '#102050', bgDir: 'v', fg: '#FFFFFF',
    weight: 400, upper: false, align: 'left', lineH: 54 / H,
    surface: { background: '#14285A', foreground: '#FFFFFF', flat: true }, style: { align: 'left', bold: false, condensed: false, upper: false } },
  // Eski bilgisayar: yeni alanlar yok, eski çizim (köşeli değil, fitStyled).
  { text: 'ESKİ', box: px(100, 700, 160, 730), line: 30 / H,
    surface: { background: '#202020', foreground: '#FFFFFF', flat: true }, style: { align: 'left', bold: true, condensed: false, upper: true } },
  // #1264: ekranın ortasındaki görev yazısı ortalı; Türkçesi kısa: kutu örtü kadar (uzamaz), yazı ortada (sola kaymaz).
  { text: 'Mutfağa git', box: px(740, 1000, 1180, 1032), line: 32 / H, cover: px(738, 998, 1182, 1034),
    grow: px(600, 998, 1320, 1034), bg: '#202020', bg2: '#242424', bgDir: 'h', fg: '#FFFFFF', weight: 700, upper: false,
    align: 'center', lineH: 32 / H, surface: { background: '#202020', foreground: '#FFFFFF', flat: true },
    style: { align: 'center', bold: true, condensed: false, upper: false } },
  // #1266: tuş simgesi sağda (gönderici simgeyi örtüden çıkardı, hizayı sağa çevirdi): kısa çeviri simgeye yaslı, kutu
  // simgeye (örtünün sağına) hiç girmez.
  { text: 'SEÇ', box: px(1500, 700, 1600, 730), line: 30 / H, cover: px(1498, 698, 1602, 732), grow: px(1400, 698, 1602, 732),
    bg: '#303040', bg2: '#343444', bgDir: 'h', fg: '#FFFFFF', weight: 700, upper: true, align: 'right', lineH: 30 / H,
    surface: { background: '#303040', foreground: '#FFFFFF', flat: true }, style: { align: 'right', bold: true, condensed: false, upper: true } },
];

function render() {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-exact-'));
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
      // Sayfa ölçüsü (app.js pageSize/pageRect, #1098).
      ${app.indexOf('  var pageProbe = null;') >= 0 ? app.slice(app.indexOf('  var pageProbe = null;'), app.indexOf('\n  var server = null;')) : ''}
      ${slice('  function validBox(box)', '\n  //')}
      ${slice('  function fillText(el, text, icons)', '\n  //')}
      ${slice('  var screenTimer = null;', '\n  // --- Ek alanlar')}
      showScreen(${JSON.stringify(items)}, 20000);
      var out = Array.from($('screen').children).map(function (el) {
        var b = el.getBoundingClientRect(), cs = getComputedStyle(el);
        var lines = Array.from(el.querySelectorAll('.exact-line')).map(function (row) {
          var range = document.createRange();
          range.selectNodeContents(row);
          var r = range.getBoundingClientRect(), rb = row.getBoundingClientRect();
          return { text: row.textContent, left: r.left, right: r.right, top: rb.top, bottom: rb.bottom };
        });
        return { text: el.textContent, cls: el.className, left: b.left, top: b.top, right: b.right, bottom: b.bottom,
          bg: cs.backgroundColor, image: cs.backgroundImage, radius: cs.borderTopLeftRadius, shadow: cs.textShadow,
          font: parseFloat(cs.fontSize), overflow: cs.textOverflow, lines: lines };
      });
      $('result').textContent = btoa(unescape(encodeURIComponent(JSON.stringify(out))));
      </script>`;
    const file = path.join(temp, 'exact.html');
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

test('gerçek çizim: opak köşesiz kutu, degrade, tek boy grup, boş alana uzama, kesilmeyen yazı', { skip: !browser && 'tarayıcı yok' }, () => {
  const drawn = render();
  const exact = drawn.filter(el => el.cls.indexOf('exact') >= 0);
  assert.equal(exact.length, 8, 'yeni alanlı sekiz öğe birebir çizilir');
  const old = drawn.find(el => el.text === 'ESKİ');
  assert.ok(old && old.cls.indexOf('exact') < 0, 'yeni alansız öğe eski yolda');
  for (const el of exact) {
    assert.match(el.bg, /^rgb\(/, `${el.text}: zemin opak (${el.bg})`);
    assert.equal(el.radius, '0px', `${el.text}: köşe yuvarlatma yok`);
    assert.equal(el.shadow, 'none', `${el.text}: gölge yok`);
    assert.match(el.image, /linear-gradient/, `${el.text}: degrade zemin`);
    assert.ok(el.text.indexOf('…') < 0 && el.overflow !== 'ellipsis', `${el.text}: kesilmez`);
    for (const line of el.lines) {
      assert.ok(line.left >= el.left - 1 && line.right <= el.right + 1, `${el.text}: satır kutudan taşmaz ${JSON.stringify(line)}`);
      assert.ok(line.bottom <= el.bottom + 1, `${el.text}: satır kutunun altına taşmaz`);
    }
  }
  const hints = exact.slice(0, 5);
  // Grup tek yazı boyunda; uzun çeviri yüzünden tek bir öğe küçülmez.
  assert.equal(new Set(hints.map(el => el.font)).size, 1, 'ipuçları tek boyda: ' + hints.map(el => el.font).join(', '));
  // Sağ kenar (tuş simgesi tarafı) yerinde: örtünün sağı (1794).
  for (const el of hints) assert.ok(Math.abs(el.right - 1794) <= 1, `${el.text}: sağ kenar yerinde (${el.right})`);
  // Uzun çeviri boş sola uzar, tek satırda kalır, boş alanın dışına taşmaz.
  const long = hints[3];
  assert.ok(long.left < 1734 - 20, 'uzun çeviri sola uzar: ' + long.left);
  assert.ok(long.left >= 1300 - 1, 'boş alanın dışına taşmaz');
  assert.equal(long.lines.length, 1, 'boş alan varken satır kırılmaz');
  assert.equal(long.lines[0].text, 'HEDEF BELİRLE BURAYA ŞİMDİ');
  // Kısa çeviri kutusunu büyütmez: örtü kutusu kadar.
  assert.ok(Math.abs(hints[4].left - 1698) <= 1, 'kısa çeviri örtüde kalır: ' + hints[4].left);
  // Görev kartı: iki satır, aralık özgün (54 px); yazı kutudan taşmaz.
  const card = exact[5];
  assert.equal(card.lines.length, 2, 'görev kartı iki satır: ' + card.lines.map(l => l.text).join(' / '));
  // Sığmayan açıklama önce biraz küçülür (en çok %20): satır aralığı yazı boyuyla aynı oranda, özgün oranda kalır.
  const gap = card.lines[1].top - card.lines[0].top;
  assert.ok(gap <= 54 + 1 && gap >= 54 * 0.8 - 1, 'satır aralığı özgün: ' + gap);
  assert.ok(Math.abs(gap / card.font - 54 / (0.95 * 38)) <= 0.03, 'aralık/yazı boyu özgün oranda: ' + gap / card.font);
  assert.ok(card.bottom - card.top <= 96 + 1, 'kart kutusu aşağı uzamaz (sığdı)');
  assert.ok(Math.abs(card.top - 290) <= 1 && Math.abs(card.left - 280) <= 1, 'görev kartı örtünün yerinde');
  // #1264: ortalı görev yazısı: kutu örtüden uzun değil, yazının ortası örtünün ortasında.
  const mission = exact[6];
  assert.ok(Math.abs(mission.left - 738) <= 1 && Math.abs(mission.right - 1182) <= 1, 'kutu örtü kadar: ' + mission.left + '-' + mission.right);
  const middle = (mission.lines[0].left + mission.lines[0].right) / 2;
  assert.ok(Math.abs(middle - 960) <= 2, 'yazı ortada (sola kaymaz): ' + middle);
  // #1266: kısa çeviri sağdaki simgeye yaslı; kutu örtünün sağını (simge tarafı) aşmaz.
  const select = exact[7];
  assert.ok(select.right <= 1602 + 1 && Math.abs(select.right - 1602) <= 1, 'kutu simgeye girmez: ' + select.right);
  assert.ok(select.lines[0].right >= 1602 - 4, 'yazı simgeye yaslı: ' + select.lines[0].right);
});
