// SPDX-License-Identifier: AGPL-3.0-only
// GTA 6 telefonu (X, beta.79): telefonun çevirisi mesaj balonlarının üstünde, yerinde durur; altyazı telefonun üstüne
// binmez (tv-webos/app.js avoidPhone), telefonun yanına kayar. "Ekranı çevir"in yerinde balonları ("bubble") balonun
// genişliğinden taşmaz, yazı okunabilir boyda kalır (1080p'de en az 18 piksel), sığmayan Türkçe balonu biraz uzatır. Gerçek kare (testdata/frames/gta6-telefon-sohbet-1.jpg)
// arka planda, gerçek Chromium yerleşimiyle. Ekran görüntüsü: COUCHSUBS_SHOT_DIR verilirse oraya yazılır.
// node --test scripts/tv-phone-bubbles.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const root = path.join(__dirname, '..', 'tv-webos');
const frame = path.join(__dirname, '..', 'testdata', 'frames', 'gta6-telefon-sohbet-1.jpg');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

// Gerçek karenin balonları (Apple Vision okuması, testdata/frames/ocr/gta6-telefon-sohbet-1.json); renkler balonlardan.
const incoming = { background: '#f6efe8', foreground: '#2a2a2a' };
const outgoing = { background: '#d3dcf4', foreground: '#2a2a2a' };
const bubble = (text, box, surface) => ({ text, box: { left: box[0], top: box[1], right: box[2], bottom: box[3] }, line: 0.034, surface });
const phoneBlocks = [
  bubble('KARAVANIMA! Anladın mı?', [0.62339, 0.26597, 0.74873, 0.3314], incoming),
  bubble('O şeyleri senin için bıraktım', [0.63753, 0.44167, 0.78198, 0.50916], outgoing),
  bubble('Yeni mesaj', [0.64768, 0.59067, 0.75773, 0.62531], incoming),
  bubble('Sağ ol dostum! Başka bir şey bulursan, VE HERHANGİ BİR ŞEY DİYORUM, bana getir', [0.61984, 0.65581, 0.7722, 0.80731], incoming),
];

function slice(app, from, to) {
  const start = app.indexOf(from);
  const end = app.indexOf(to, start);
  assert.ok(start > 0 && end > start, 'TV işlevi bulunamadı: ' + from);
  return app.slice(start, end);
}

function page(script) {
  const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
  const fill = slice(app, '  function fillText(', '\n  }\n') + '\n  }\n';
  const screen = slice(app, '  var screenTimer = null;', '\n  // --- Ek alanlar');
  const regions = slice(app, '  var regionBoxes = {};', '\n  // Konum hem');
  const valid = slice(app, '  function validBox(box)', '\n  //');
  return `<!doctype html><meta charset="utf-8"><style>${fs.readFileSync(path.join(root, 'style.css'), 'utf8')}
    html, body { margin:0; width:1920px; height:1080px; overflow:hidden; background:#000 url('${pathToFileURL(frame).href}') 0 0 / 1920px 1080px no-repeat; }
    #subtitle { position:absolute; left:8%; right:8%; bottom:12%; text-align:center; }
    #result { display:none; }
    #subtitle-text { display:inline-block; font:40px sans-serif; color:#fff; background:rgba(0,0,0,.75); padding:4px 18px; }</style>
    <div id="regions" class="hidden"></div><div id="screen" class="hidden"></div>
    <div id="subtitle" class="hidden"><span id="subtitle-text"></span></div><pre id="result"></pre><script>
    function $(id) { return document.getElementById(id); }
    function hideSubtitle() {}
    var diag = { regions: 0, big: 0 };
    var SIDE_MIN = 0.05;
    ${valid}
    ${fill}
    ${screen}
    ${regions}
    function rect(el) { var r = el.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom }; }
    function overlaps(a, b) { return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom; }
    ${script}
    </script>`;
}

function run(html, extra) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-phone-test-'));
  try {
    const file = path.join(temp, 'test.html');
    fs.writeFileSync(file, html);
    const result = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1080',
      '--allow-file-access-from-files', ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
      '--user-data-dir=' + path.join(temp, 'profile'), ...extra, pathToFileURL(file).href],
    { encoding: 'utf8', timeout: 30000, windowsHide: true });
    assert.equal(result.status, 0, String(result.error || result.stderr));
    return result.stdout;
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

function measure(script) {
  const out = run(page(script), ['--dump-dom']);
  const match = out.match(/<pre id="result">([^<]+)<\/pre>/);
  assert.ok(match, 'Tarayıcı ölçüm üretmedi');
  return JSON.parse(match[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&#39;/g, "'"));
}

function shoot(script, name) {
  const dir = process.env.COUCHSUBS_SHOT_DIR;
  if (!dir) return;
  fs.mkdirSync(dir, { recursive: true });
  run(page(script), ['--virtual-time-budget=2000', '--screenshot=' + path.join(dir, name)]);
}

const subtitleOverPhone = `
  showRegion({ id: 'game-phone', text: 'x', box: { left: 0.6, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: ${JSON.stringify(phoneBlocks)} });
  $('subtitle-text').textContent = 'Telefonu bırak da şu işi bitirelim, Jason. Vaktimiz yok.';
  $('subtitle').style.left = '45%'; $('subtitle').style.right = '0'; $('subtitle').style.bottom = '22%';
  $('subtitle').className = '';
  var before = rect($('subtitle-text'));
  avoidRegions();
  var phone = phoneRect();
  var result = { before: overlaps(before, phone), after: overlaps(rect($('subtitle-text')), phone),
    sub: rect($('subtitle-text')), phone: phone };
  $('result').textContent = JSON.stringify(result);`;

test('altyazı telefonun çevirisinin üstüne binmez, telefonun yanına kayar', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = measure(subtitleOverPhone);
  assert.equal(r.before, true, 'deneme düzeni: altyazı önce telefonla çakışmalı');
  assert.equal(r.after, false, 'altyazı telefonla çakışıyor: ' + JSON.stringify(r));
  assert.ok(r.sub.left >= 0 && r.sub.right <= 1920 && r.sub.top >= 0 && r.sub.bottom <= 1080, 'altyazı ekran dışında');
  shoot(subtitleOverPhone, 'tv-phone-subtitle.png');
});

// "Ekranı çevir", kartsız (varsayılan): her mesaj kendi balonunun kutusunda (gerçek karenin okuma kutuları), balonun renginde.
const look = { bold: false, condensed: false, align: 'left', upper: false };
const screenBubble = (text, box, surface) => ({ text, box: { left: box[0], top: box[1], right: box[2], bottom: box[3] }, line: 0.033,
  surface: Object.assign({ flat: true }, surface), style: look, bubble: true });
const bubbles = [
  screenBubble('KARAVANIMA! Anladın mı?', [0.62339, 0.26597, 0.74873, 0.3314], incoming),
  screenBubble('Donnie\'nin Evi', [0.64826, 0.35917, 0.77326, 0.38243], incoming),
  screenBubble('O şeyleri senin için bıraktım', [0.63753, 0.44167, 0.78198, 0.50916], outgoing),
  screenBubble('Yeni mesaj', [0.64768, 0.59067, 0.75773, 0.62531], incoming),
  screenBubble('Sağ ol dostum! Başka bir şey bulursan, VE HERHANGİ BİR ŞEY DİYORUM, bana getir', [0.61984, 0.65581, 0.7722, 0.80731], incoming),
];
const inPlace = `
  showScreen(${JSON.stringify(bubbles)}, 20000);
  var list = Array.prototype.slice.call($('screen').children).map(function (el, i) {
    var r = rect(el), b = ${JSON.stringify(bubbles)}[i].box;
    return { text: el.textContent, font: parseFloat(getComputedStyle(el).fontSize), wide: el.scrollWidth > el.clientWidth + 1,
      left: r.left, right: r.right, top: r.top, bottom: r.bottom, boxBottom: b.bottom * 1080, boxRight: b.right * 1920,
      background: getComputedStyle(el).backgroundColor, bubble: el.className.indexOf('bubble') >= 0 };
  });
  $('result').textContent = JSON.stringify(list);`;

test('"Ekranı çevir" balonları yerinde: taşmaz, okunur boyda, balon rengiyle', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const list = measure(inPlace);
  assert.equal(list.length, bubbles.length);
  for (const [i, el] of list.entries()) {
    assert.equal(el.bubble, true, el.text);
    assert.equal(el.wide, false, 'yatayda taşıyor: ' + el.text);
    assert.ok(el.right <= el.boxRight + 0.004 * 1920 + 1, 'balonun sağından taşıyor: ' + el.text);
    assert.ok(el.font >= 18, 'yazı okunamayacak kadar küçük (' + el.font + ' px): ' + el.text);
    // Sığmayan Türkçe balonu biraz uzatır, sonraki balonun üstüne binmez.
    if (i + 1 < list.length) assert.ok(el.bottom <= list[i + 1].top + 1, 'sonraki balonun üstüne biniyor: ' + el.text);
    assert.ok(el.bottom - el.boxBottom <= 0.06 * 1080, 'balon çok uzadı: ' + el.text);
  }
  assert.equal(list[2].background, 'rgb(211, 220, 244)', 'giden balon kendi renginde');
  assert.equal(list[0].background, 'rgb(246, 239, 232)', 'gelen balon kendi renginde');
  shoot(inPlace, 'tv-phone-bubbles.png');
});
