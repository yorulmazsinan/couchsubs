// SPDX-License-Identifier: AGPL-3.0-only
// Konuşma satırı hiçbir TV'de basık, dar ya da küçük çizilmez (#1255, #1259; TV uygulaması 0.9.107). Gerçek Chromium
// yerleşimiyle bir matris:
//  - sayfa çözünürlüğü 1280x720, 1920x1080, 3840x2160; cihaz piksel oranı 1, 1,5, 2, 3;
//  - yazı ölçeği %85, %100, %130 (cihazın yazı ölçeği ya da bilgisayarın yazı boyu; Android TV'de WebView'in textZoom'u
//    TvPage'de %100'e sabit, burada gelen yazı boyu çarpılarak denenir); küçük yazı boyu (20 px) da;
//  - Katman (body.overlay) ve Uygulama içinde; Android TV köprüsüyle ve köprüsüz (LG/Samsung ortak yolu);
//  - altyazı yolu (setLineText, "Örtsün" ve sabit) ve ekran yazısı olarak okunan replik (fitStyled, birebir öğe).
// Her durumda: yatay ölçek 1 (dönüşüm yok), font-stretch %100, letter-spacing normal, dar aile yok; yazı boyu sayfa
// yüksekliğinin %2,2'sinden küçük değil; harf başına genişlik en az 0,35 em (ezik çizimde, #1255 fotoğrafları, ~0,1 em);
// Katman ve Uygulama içinde altyazı kutusu birebir aynı ölçüde.
// node --test scripts/tv-overlay-subtitle-size.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const root = path.join(__dirname, '..', 'tv-webos');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

const LINES = ['Ne?', 'Lucia: Evet, belki.', 'Jason: Belki birazdan.', 'Alet çantanı göster bakalım.',
  'Lucia: Biliyor musun, şehre dönmek hoşuma gidiyor; burada iyi para kazanabiliriz bence.'];
const SIZES = [[1280, 720], [1920, 1080], [3840, 2160]];
const RATIOS = [1, 1.5, 2, 3];
const ZOOMS = [0.85, 1, 1.3];
const BASES = [46, 20];
const MIN_SHARE = 0.022;
// Oyundaki İngilizce satırın kutusu (altta ortada); ekran yazısı olarak okunan replik için dar özgün kutu.
const BOX = { left: 0.42, top: 0.86, right: 0.58, bottom: 0.9 };
const SCREEN_BOX = { left: 0.48, top: 0.86, right: 0.52, bottom: 0.885 };

function render(cssWidth, cssHeight, ratio, android) {
  const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
  const slice = (from, to) => {
    const start = app.indexOf(from);
    const end = app.indexOf(to, start);
    assert.ok(start > 0 && end > start, 'TV işlevi bulunamadı: ' + from);
    return app.slice(start, end);
  };
  const surface = { background: '#101010', flat: true, foreground: '#FFFFFF' };
  const screenItems = LINES.slice(0, 4).map(text => ({ text, box: SCREEN_BOX, line: 0.025,
    style: { align: 'center', bold: true, condensed: true, upper: false }, surface }));
  const exactItems = LINES.slice(0, 4).map(text => Object.assign({}, screenItems[0], { text, bg: '#101010', fg: '#FFFFFF',
    weight: 700, align: 'center', cover: SCREEN_BOX, lineH: 0.025 }));
  const html = `<!doctype html><meta charset="utf-8"><style>${fs.readFileSync(path.join(root, 'style.css'), 'utf8')}</style>
    <body>
    <div id="subtitle" style="left:8%;right:8%"><span id="subtitle-text"></span></div>
    <div id="subtitle-cover" class="hidden"></div>
    <div id="regions" class="hidden"></div><div id="screen"></div><pre id="result"></pre><script>
    ${android ? 'window.AndroidTV = {};' : ''}
    function $(id) { return document.getElementById(id); }
    function hideSubtitle() {}
    function resolveLayers() {}
    function dimmedColor(id, color) { return color; }
    var diag = { regions: 0, big: 0 };
    var setApart = true, bandShape = false, placement = 'cover', currentBox = ${JSON.stringify(BOX)}, fontBase = 46;
    // Sayfa ölçüsü (app.js pageSize/pageRect, #1098).
    ${app.indexOf('  var pageProbe = null;') >= 0 ? app.slice(app.indexOf('  var pageProbe = null;'), app.indexOf('\n  var server = null;')) : ''}
    ${slice('  function validBox(box)', '\n  //')}
    ${slice('  function fillText(el, text, icons)', '\n  //')}
    ${slice('  function speakerMap(list)', '\n  var SUBTITLE_MAX_HEIGHT')}
    ${slice('  var screenTimer = null;', '\n  // --- Ek alanlar')}
    ${slice('  var COVER_PAD', '\n  function placeCover')}
    function scaleOf(el) {
      return Array.from(el.querySelectorAll('*')).concat([el]).reduce(function (least, node) {
        var m = (getComputedStyle(node).transform || '').match(/^matrix\\(([^,]+),[^,]+,[^,]+,([^,]+)/);
        return m ? Math.min(least, parseFloat(m[1]) / parseFloat(m[2])) : least;
      }, 1);
    }
    function textWidth(el) {
      var range = document.createRange();
      range.selectNodeContents(el);
      var rects = range.getClientRects(), widest = 0, total = 0;
      for (var i = 0; i < rects.length; i++) { widest = Math.max(widest, rects[i].width); total += rects[i].width; }
      return { widest: widest, total: total, rows: rects.length };
    }
    function look(el, line, extra) {
      var cs = getComputedStyle(el), r = el.getBoundingClientRect(), t = textWidth(el);
      var inner = el.querySelector('span') || el;
      return Object.assign({ line: line, text: el.textContent, width: Math.round(r.width * 10) / 10,
        height: Math.round(r.height * 10) / 10, font: parseFloat(getComputedStyle(inner).fontSize),
        family: cs.fontFamily, stretch: getComputedStyle(inner).fontStretch, spacing: getComputedStyle(inner).letterSpacing,
        scale: scaleOf(el), textWidth: t.total, rows: t.rows }, extra || {});
    }
    var page = { width: window.innerWidth, height: window.innerHeight };
    var result = { page: page, subtitle: [], screen: [] };
    var lines = ${JSON.stringify(LINES)};
    ${JSON.stringify(ZOOMS)}.forEach(function (zoom) {
      ${JSON.stringify(BASES)}.forEach(function (base) {
        ['cover', 'fixed'].forEach(function (where) {
          [false, true].forEach(function (overlay) {
            document.body.className = overlay ? 'overlay' : '';
            placement = where;
            lines.forEach(function (line) {
              setLineText('subtitle-text', line, false, Math.round(base * zoom), null);
              result.subtitle.push(look($('subtitle-text'), line, { zoom: zoom, base: base, where: where, overlay: overlay }));
            });
          });
        });
      });
    });
    document.body.className = '';
    var screenItems = ${JSON.stringify(screenItems)}, exactItems = ${JSON.stringify(exactItems)};
    screenItems.concat(exactItems).forEach(function (item, i) {
      showScreen([item], 20000);
      var el = $('screen').querySelector('.item');
      result.screen.push(look(el, item.text, { exact: i >= screenItems.length }));
    });
    $('result').textContent = btoa(unescape(encodeURIComponent(JSON.stringify(result))));
    </script>`;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-overlay-size-'));
  try {
    const file = path.join(temp, 'test.html');
    fs.writeFileSync(file, html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=' + ratio,
      '--window-size=' + cssWidth + ',' + cssHeight,
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'),
      '--dump-dom', pathToFileURL(file).href], { encoding: 'utf8', timeout: 60000, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi: ' + run.stdout.slice(-1000));
    return JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

const narrow = family => /Condensed|Narrow/i.test(family);

function checkLine(entry, pageHeight, where) {
  const info = `${where}: ${JSON.stringify(entry)}`;
  assert.equal(entry.scale, 1, 'yatayda sıkışmış ' + info);
  assert.equal(entry.stretch, '100%', info);
  assert.equal(entry.spacing, 'normal', info);
  assert.ok(!narrow(entry.family), 'dar aile ' + info);
  const floor = Math.round(pageHeight * MIN_SHARE);
  assert.ok(entry.font >= floor - 0.5, `yazı boyu alt sınırın (${floor}) altında ` + info);
  if (entry.textWidth > 0) {
    // Satırlara bölünen yazıda satır sonlarındaki boşluklar sayılmaz.
    const chars = Array.from(entry.text.replace(/\s+/g, ' ')).length - (entry.rows - 1);
    const perChar = entry.textWidth / chars / entry.font;
    assert.ok(perChar >= 0.35, `harf başına ${perChar.toFixed(2)} em: ezik ` + info);
  }
}

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');

for (const [width, height] of SIZES) {
  for (const ratio of RATIOS) {
    test(`${width}x${height} dpr ${ratio}: konuşma satırı basık, dar ya da küçük değil; Katman = Uygulama içinde`,
      { skip: !browser && 'Chromium bulunamadı' }, () => {
        for (const android of [true, false]) {
          const cssWidth = Math.round(width / ratio), cssHeight = Math.round(height / ratio);
          const { page, subtitle, screen } = render(cssWidth, cssHeight, ratio, android);
          const where = `${width}x${height} dpr ${ratio} ${android ? 'Android TV' : 'LG/Samsung'}`;
          for (const entry of subtitle) checkLine(entry, page.height, where + ' altyazı');
          for (const entry of screen) checkLine(entry, page.height, where + ' ekran yazısı');
          // Katman ile Uygulama içinde aynı satır birebir aynı kutu.
          const key = e => [e.zoom, e.base, e.where, e.line].join('|');
          const inApp = new Map(subtitle.filter(e => !e.overlay).map(e => [key(e), e]));
          for (const e of subtitle.filter(e => e.overlay)) {
            const a = inApp.get(key(e));
            assert.ok(a, key(e));
            // "Örtsün"de örtü katmanda bilerek biraz geniştir (OVERLAY_ZOOM): uzun satır başka yerden bölünebilir; yazı
            // boyu yine aynı.
            if (e.where === 'cover' && (e.rows > 1 || a.rows > 1)) {
              assert.equal(e.font, a.font, `${where} Katman yazı boyu ≠ Uygulama içinde: ${key(e)}`);
              continue;
            }
            assert.deepEqual({ w: e.width, h: e.height, f: e.font, t: e.text },
              { w: a.width, h: a.height, f: a.font, t: a.text }, `${where} Katman ≠ Uygulama içinde: ${key(e)}`);
          }
        }
      });
  }
}
