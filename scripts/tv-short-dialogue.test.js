// SPDX-License-Identifier: AGPL-3.0-only
// Kısa konuşma satırı TV'de dar ve basık çizilmez (#1224, #1255, #1259; TV uygulaması 0.9.103). Gerçek Chromium yerleşimiyle:
//  - konuşma altyazısı (setLineText) çizildikten sonra yatay ölçeği 1, yazı tipi dar değil (önceki satırdan kalan dar aile
//    ve genişlik de temizlenir);
//  - ekran yazısı yolunda okunan kısa replik ("Ne?", "Yoldan çık.", "Lucia: Evet.") bilgisayar özgün yazıyı dar ölçse de
//    dar aileyle çizilmez ve sıkışmaz; menü etiketi eskisi gibi dar aileyle çizilir;
//  - Android TV'de sistem yazı tipi hiç dar geçmez (dar Roboto aynı sayfadaki altyazıya geçiyordu); birebir çizimde
//    yalnız gömülü ayrı dar aile (0.9.109).
// node --test scripts/tv-short-dialogue.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
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

const surface = { background: '#101010', flat: true, foreground: '#FFFFFF' };
const condensed = { align: 'center', bold: true, condensed: true, upper: false };
// Özgün kutu kısa İngilizce satırın kutusu: Türkçe biraz uzun, sığmak için sıkışma ya da küçülme ister.
const styled = text => ({ text, box: { left: 0.48, top: 0.86, right: 0.52, bottom: 0.885 }, line: 0.025,
  style: condensed, surface });
const exact = text => Object.assign(styled(text), { bg: '#101010', fg: '#FFFFFF', weight: 700, align: 'center',
  cover: { left: 0.48, top: 0.86, right: 0.52, bottom: 0.885 }, lineH: 0.025 });

function render(android) {
  const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
  const slice = (from, to) => {
    const start = app.indexOf(from);
    const end = app.indexOf(to, start);
    assert.ok(start > 0 && end > start, 'TV işlevi bulunamadı: ' + from);
    return app.slice(start, end);
  };
  const html = `<!doctype html><meta charset="utf-8"><style>${fs.readFileSync(path.join(root, 'style.css'), 'utf8')}</style>
    <div id="subtitle" style="left:0;right:0"><span id="subtitle-text"></span></div>
    <div id="regions" class="hidden"></div><div id="screen"></div><pre id="result"></pre><script>
    Object.defineProperty(window, 'innerWidth', { value: 1920 });
    Object.defineProperty(window, 'innerHeight', { value: 1080 });
    ${android ? 'window.AndroidTV = {};' : ''}
    function $(id) { return document.getElementById(id); }
    function hideSubtitle() {}
    function resolveLayers() {}
    function dimmedColor(id, color) { return color; }
    var diag = { regions: 0, big: 0 };
    var setApart = true, bandShape = false, placement = 'fixed', currentBox = null;
    // Sayfa ölçüsü (app.js pageSize/pageRect, #1098).
    ${app.indexOf('  var pageProbe = null;') >= 0 ? app.slice(app.indexOf('  var pageProbe = null;'), app.indexOf('\n  var server = null;')) : ''}
    ${slice('  function validBox(box)', '\n  //')}
    ${slice('  function fillText(el, text, icons)', '\n  //')}
    ${slice('  function speakerMap(list)', '\n  var SUBTITLE_MAX_HEIGHT')}
    ${slice('  var screenTimer = null;', '\n  // --- Ek alanlar')}
    // Yatay ölçek: öğenin ve alt öğelerinin dönüşüm matrisinde a/d (dönüşüm yoksa 1).
    function squeeze(el) {
      return Array.from(el.querySelectorAll('*')).concat([el]).reduce(function (least, node) {
        var m = (getComputedStyle(node).transform || '').match(/^matrix\\(([^,]+),[^,]+,[^,]+,([^,]+)/);
        return m ? Math.min(least, parseFloat(m[1]) / parseFloat(m[2])) : least;
      }, 1);
    }
    function look(el) {
      var cs = getComputedStyle(el);
      return { text: el.textContent, family: cs.fontFamily, stretch: cs.fontStretch, squeeze: squeeze(el) };
    }
    var result = { screen: [], subtitle: null };
    var items = ${JSON.stringify([styled('Ne?'), styled('Yoldan çık.'), styled('Lucia: Evet, hadi gidelim.'),
      styled('ŞARJÖRÜ DEĞİŞTİR'), exact('Ne?'), exact('Haritayı aç')])};
    items.forEach(function (item) {
      showScreen([item], 20000);
      var el = $('screen').querySelector('.item');
      result.screen.push(look(el));
    });
    // Önceki çizimden dar aile ve genişlik kalmış altyazı kutusu: kısa satır yeniden yazılınca olağan görünüşe döner.
    var sub = $('subtitle-text');
    sub.style.fontFamily = CONDENSED_FONT;
    sub.style.fontStretch = 'condensed';
    setLineText('subtitle-text', 'Ne?', false, 46, null);
    result.subtitle = look(sub);
    result.body = getComputedStyle(document.body).fontFamily;
    $('result').textContent = btoa(unescape(encodeURIComponent(JSON.stringify(result))));
    </script>`;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-short-dialogue-'));
  try {
    const file = path.join(temp, 'test.html');
    fs.writeFileSync(file, html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1280',
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'),
      '--dump-dom', pathToFileURL(file).href], { encoding: 'utf8', timeout: 30000, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi: ' + run.stdout.slice(-1000));
    return JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

const narrow = family => /Condensed|Narrow/i.test(family);

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');

test('kısa konuşma altyazısı çizildikten sonra yatay ölçeği 1, yazı tipi dar değil', { skip: !browser && 'Chromium bulunamadı' }, () => {
  for (const android of [false, true]) {
    const { subtitle, body } = render(android);
    assert.equal(subtitle.text, 'Ne?');
    assert.equal(subtitle.squeeze, 1, JSON.stringify(subtitle));
    assert.equal(subtitle.stretch, '100%', JSON.stringify(subtitle));
    assert.ok(!narrow(subtitle.family), JSON.stringify(subtitle));
    assert.equal(subtitle.family, body);
  }
});

test('ekran yazısı yolundaki kısa replik dar aile almaz ve sıkışmaz; menü etiketi dar kalır', { skip: !browser && 'Chromium bulunamadı' }, () => {
  const { screen } = render(false);
  const [ne, cik, lucia, label, exactNe, exactLabel] = screen;
  for (const line of [ne, cik, lucia, exactNe]) {
    assert.equal(line.squeeze, 1, JSON.stringify(line));
    assert.ok(!narrow(line.family), JSON.stringify(line));
  }
  // Menü etiketi ve birebir çizimdeki düğme yazısı özgün dar görünüşünü korur.
  assert.ok(narrow(label.family), JSON.stringify(label));
  assert.ok(narrow(exactLabel.family), JSON.stringify(exactLabel));
});

// Android TV (0.9.109): sistemin Roboto'su hiç dar genişliğe geçmez (fontStretch yok, Roboto Condensed yok). Birebir
// çizimdeki menü/kutu yazısı yalnız gömülü ayrı aileyi ("CouchSubs Condensed", Barlow Condensed) alır; konuşma satırı hiç.
test('Android TV: sistem yazı tipi dar geçmez; birebir çizimde yalnız gömülü dar aile', { skip: !browser && 'Chromium bulunamadı' }, () => {
  const { screen } = render(true);
  const [ne, cik, lucia, label, exactNe, exactLabel] = screen;
  for (const line of screen) {
    assert.notEqual(line.stretch, '75%', JSON.stringify(line));
    assert.ok(!/Roboto Condensed|Narrow/i.test(line.family), JSON.stringify(line));
  }
  for (const line of [ne, cik, lucia, label, exactNe]) assert.ok(!narrow(line.family), JSON.stringify(line));
  assert.ok(/CouchSubs Condensed/.test(exactLabel.family), JSON.stringify(exactLabel));
});
