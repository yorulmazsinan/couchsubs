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

function page(script, source) {
  const app = source || fs.readFileSync(path.join(root, 'app.js'), 'utf8');
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
    ${app.indexOf('  var pageProbe = null;') >= 0 ? app.slice(app.indexOf('  var pageProbe = null;'), app.indexOf('\n  var server = null;')) : ''}
    ${valid}
    ${fill}
    ${screen}
    ${regions}
    function rect(el) { var r = el.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom }; }
    function overlaps(a, b) { return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom; }
    ${script}
    </script>`;
}

function run(html, extra, screen) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-phone-test-'));
  try {
    const file = path.join(temp, 'test.html');
    fs.writeFileSync(file, html);
    const result = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=' + ((screen && screen.dpr) || 1),
      '--window-size=' + ((screen && screen.size) || '1920,1080'),
      '--allow-file-access-from-files', ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
      '--user-data-dir=' + path.join(temp, 'profile'), ...extra, pathToFileURL(file).href],
    { encoding: 'utf8', timeout: 30000, windowsHide: true });
    assert.equal(result.status, 0, String(result.error || result.stderr));
    return result.stdout;
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

function measure(script, source, screen) {
  const out = run(page(script, source), ['--dump-dom'], screen);
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

// Yanda Panel (varsayılan; X'te monitörle oynayan kullanıcı: balonların üstündeki çeviri kayıyor, küçük, kimin ne dediği
// belli olmuyor): telefon sağdaysa panel solunda, yuvarlak köşeli yarı saydam koyu kartta; üstte kişinin adı, karşı
// taraf solda krem, oyuncu sağda amber balon; sığmayan eski mesajlar düşer, son mesaj görünür kalır.
const cardStyle = { background: '#141518', foreground: '#F3EEE4' };
const part = (panel, text, box, surface) => ({ text, box: { left: box[0], top: box[1], right: box[2], bottom: box[3] }, line: 0.022,
  surface: Object.assign({ flat: true }, surface), style: look, panel });
const panelBlocks = (count) => [
  part('card', ' ', [0.31, 0.26, 0.592, 0.81], cardStyle),
  part('title', 'Lucia', [0.32, 0.27, 0.58, 0.30], cardStyle),
].concat(Array.from({ length: count }, (_, i) => i % 2
  ? part('mine', 'O şeyleri senin için bıraktım ' + i, [0.40, 0.32 + i * 0.01, 0.58, 0.33 + i * 0.01], { background: '#F5B83D', foreground: '#17181B' })
  : part('theirs', 'Sağ ol dostum! Başka bir şey bulursan bana getir ' + i, [0.32, 0.32 + i * 0.01, 0.52, 0.33 + i * 0.01], { background: '#F3EEE4', foreground: '#17181B' })));
test('telefon balonunun yarıçapı ekran yüksekliğiyle ölçeklenir ve yeniden kullanılan öğede güncellenir', { skip: !browser }, () => {
  const result = measure(`
    var result = [];
    [null, false, true].forEach(function (aligned) {
      var blocks = aligned === null ? ${JSON.stringify(phoneBlocks)} : ${JSON.stringify(panelBlocks(2))};
      if (aligned !== null) blocks[0].aligned = aligned;
      var target = blocks[aligned === null ? 0 : 2];
      var selector = aligned === null ? '.item.phone' : '.panel-row.theirs .panel-bubble';
      var region = { id: 'game-phone', text: 'x', box: blocks[0].box, blocks: blocks };
      var radii = [];
      [0.015, 0.01, null].forEach(function (radius) {
        if (radius === null) delete target.radius;
        else target.radius = radius;
        showRegion(region);
        radii.push(document.querySelector(selector).style.borderRadius);
      });
      result.push(radii);
    });
    $('result').textContent = JSON.stringify({ height: pageSize(true).height, values: result });`);
  for (const values of result.values) {
    assert.ok(Math.abs(parseFloat(values[0]) - 0.015 * result.height) < 0.001);
    assert.ok(Math.abs(parseFloat(values[1]) - 0.01 * result.height) < 0.001);
    assert.equal(values[2], '');
  }
});

const sidePanel = (count) => `
  showRegion({ id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: ${JSON.stringify(panelBlocks(count))} });
  var panel = document.querySelector('.phone-panel');
  var style = getComputedStyle(panel), messages = panel.querySelector('.panel-messages');
  var rows = Array.prototype.slice.call(panel.querySelectorAll('.panel-row')).map(function (row) {
    var bubble = row.querySelector('.panel-bubble');
    return { text: bubble.textContent, side: row.className, font: parseFloat(getComputedStyle(bubble).fontSize),
      background: getComputedStyle(bubble).backgroundColor, box: rect(bubble) };
  });
  $('result').textContent = JSON.stringify({ panel: rect(panel), radius: parseFloat(style.borderTopLeftRadius),
    background: style.backgroundColor, title: panel.querySelector('.panel-title').textContent, rows: rows,
    list: rect(messages), couch: !!panel.querySelector('.panel-couch'), loose: document.querySelectorAll('#regions .item').length });`;

test('Yanda Panel: sohbet telefonun yanında, kim ne dedi belli, son mesaj görünür', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = measure(sidePanel(4));
  assert.equal(r.loose, 0, 'panel parçaları ayrıca yerinde çizilmez');
  assert.ok(r.panel.right <= 0.6 * 1920, 'panel telefonun üstüne biniyor: ' + JSON.stringify(r.panel));
  assert.ok(r.radius >= 16, 'köşe yuvarlak değil');
  assert.match(r.background, /rgba\(20, 21, 24, 0\.88\)/, 'zemin yarı saydam koyu değil: ' + r.background);
  assert.equal(r.title, 'Lucia');
  assert.equal(r.couch, true);
  assert.equal(r.rows.length, 4);
  const theirs = r.rows.filter(row => row.side.indexOf('theirs') >= 0), mine = r.rows.filter(row => row.side.indexOf('mine') >= 0);
  assert.ok(theirs.every(t => t.box.left < mine[0].box.left), 'karşı taraf solda, oyuncu sağda değil');
  assert.ok(mine.every(m => m.box.right > r.panel.right - 0.03 * 1920), 'oyuncunun balonu sağa yaslı değil');
  assert.equal(mine[0].background, 'rgb(245, 184, 61)', 'oyuncunun balonu amber');
  assert.equal(theirs[0].background, 'rgb(243, 238, 228)', 'karşı tarafın balonu krem');
  for (let i = 0; i + 1 < r.rows.length; i++) assert.ok(r.rows[i].box.bottom <= r.rows[i + 1].box.top + 1, 'balonlar üst üste');
  assert.ok(r.rows.every(row => row.font >= 18), 'yazı okunamayacak kadar küçük');
  shoot(sidePanel(4), 'tv-phone-panel.png');

  const full = measure(sidePanel(30));
  assert.ok(full.rows.length < 30 && full.rows.length >= 3, 'sığmayan eski mesajlar düşmedi: ' + full.rows.length);
  assert.ok(full.rows[full.rows.length - 1].text.endsWith(' 29'), 'son mesaj görünmüyor');
  assert.ok(full.rows[full.rows.length - 1].box.bottom <= full.list.bottom + 1, 'son mesaj panelden taşıyor');
});

// X (22 Kas, GTA 6 telefonu: "yazılar sürekli oynuyor"): TV uygulaması 0.9.78 telefonun gönderisini yerinde günceller. Aynı
// gönderi hiçbir şeyi yeniden çizmez; yeni mesaj gelince panel ve mevcut balonlar aynı DOM düğümleri olarak kalır, yeni
// mesaj alta eklenir; balonların üstündeki çeviride de aynı yazının kutusu korunur, yalnız yeri güncellenir.
const inPlaceUpdate = `
  var blocks = ${JSON.stringify(panelBlocks(3))};
  var region = { id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: blocks };
  showRegion(region);
  var panel = document.querySelector('.phone-panel');
  var rows = Array.prototype.slice.call(panel.querySelectorAll('.panel-row'));
  rows.forEach(function (row, i) { row.couchsubsMark = i; });
  showRegion(JSON.parse(JSON.stringify(region)));
  var same = document.querySelector('.phone-panel') === panel && panel.querySelectorAll('.panel-row').length === 3 &&
    Array.prototype.every.call(panel.querySelectorAll('.panel-row'), function (row, i) { return row.couchsubsMark === i; });
  var more = JSON.parse(JSON.stringify(blocks));
  more.push({ text: 'Yeni mesaj', box: { left: 0.32, top: 0.40, right: 0.5, bottom: 0.41 }, line: 0.022,
    surface: { flat: true, background: '#F3EEE4', foreground: '#17181B' }, panel: 'theirs' });
  // Akışla çizilen mesajların kutusu biraz oynasa da satırlar yeniden yaratılmaz.
  more[2].box.top += 0.003; more[2].box.bottom += 0.003;
  showRegion({ id: 'game-phone', text: 'x', box: region.box, blocks: more });
  var after = Array.prototype.slice.call(document.querySelectorAll('.phone-panel .panel-row'));
  var appended = document.querySelector('.phone-panel') === panel && after.length === 4 &&
    after.slice(0, 3).every(function (row, i) { return row.couchsubsMark === i; }) && after[3].couchsubsMark === undefined &&
    after[3].textContent === 'Yeni mesaj';
  hideRegions();
  var bubble = { text: 'Yarın buluşalım.', box: { left: 0.62, top: 0.40, right: 0.75, bottom: 0.44 }, line: 0.03,
    surface: { background: '#F6EFE8', foreground: '#2A2A2A' } };
  showRegion({ id: 'game-phone', text: 'x', box: bubble.box, blocks: [bubble] });
  var first = document.querySelector('#regions .item');
  var moved = JSON.parse(JSON.stringify(bubble));
  moved.box.top = 0.30; moved.box.bottom = 0.34;
  showRegion({ id: 'game-phone', text: 'x', box: moved.box, blocks: [moved] });
  var kept = document.querySelectorAll('#regions .item').length === 1 && document.querySelector('#regions .item') === first &&
    Math.abs(parseFloat(first.style.top) - 30) < 0.5;
  $('result').textContent = JSON.stringify({ same: same, appended: appended, kept: kept });`;

test('telefonun gönderisi yerinde güncellenir: aynı gönderi yeniden çizilmez, yeni mesaj alta eklenir', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = measure(inPlaceUpdate);
  assert.equal(r.same, true, 'aynı gönderi paneli yeniden yarattı');
  assert.equal(r.appended, true, 'yeni mesajda mevcut balonlar yeniden yaratıldı ya da yeni mesaj alta eklenmedi');
  assert.equal(r.kept, true, 'balonun kutusu yeniden yaratıldı ya da yeri güncellenmedi');
});

// X (22 Kas, Sinan Bey: "her saniye şekli de hareketi de değişiyor"; TV uygulaması 0.9.105): panelin mesajları akışla
// çizilir; yalnız kutuları oynayan aynı içerik panele hiç dokunmaz (yeniden dizilmez, yazı boyu yeniden hesaplanmaz). Kartın
// yeri ya da bir mesajın yazısı değişince panel güncellenir.
const steadyPanel = `
  var region = { id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: ${JSON.stringify(panelBlocks(3))} };
  showRegion(region);
  var panel = document.querySelector('.phone-panel');
  var size = panel.style.fontSize;
  // İşaret: panel yeniden düzenlenirse yazı boyu yeniden yazılır, işaret silinir.
  panel.style.fontSize = '7px';
  var jitter = JSON.parse(JSON.stringify(region));
  jitter.blocks.forEach(function (b) { if (b.panel !== 'card') { b.box.top += 0.004; b.box.bottom += 0.004; b.box.left -= 0.002; } });
  showRegion(jitter);
  var untouched = document.querySelector('.phone-panel') === panel && panel.style.fontSize === '7px';
  var moved = JSON.parse(JSON.stringify(jitter));
  moved.blocks[0].box.left += 0.01; moved.blocks[0].box.right += 0.01;
  showRegion(moved);
  var follows = document.querySelector('.phone-panel') === panel && panel.style.fontSize === size &&
    Math.abs(parseFloat(panel.style.left) - 32) < 0.01;
  $('result').textContent = JSON.stringify({ untouched: untouched, follows: follows });`;

test('kutuları oynayan aynı panel içeriği yeniden dizilmez; kart kayınca panel izler', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = measure(steadyPanel);
  assert.equal(r.untouched, true, 'aynı içerik paneli yeniden düzenledi');
  assert.equal(r.follows, true, 'kart kayınca panel güncellenmedi');
});

// LG, beta.93: GTA 6 telefonunun Mesajlar ekranı (sohbet listesi). Bilgisayar listeyi sola yaslı not satırları olarak
// gönderir (style.align 'left'): kişi adı kalın ve çevrilmez, altında önizlemenin çevirisi, "Önerilen"/"Mesajlar" soluk
// kalın bölüm başlığı. TV (0.9.101) bunları ortalı küçük not değil, telefondaki sırayla sola yaslı liste olarak çizer; aynı
// liste art arda gelince (sallanan telefon) hiçbir satır yeniden yaratılmaz, değişen önizlemenin yalnız satırı yenilenir.
const noteInk = { background: '#141518', foreground: '#A9A59C' };
const listPart = (text, top, kind) => ({ text, box: { left: 0.32, top, right: 0.58, bottom: top + 0.02 }, line: 0.022,
  surface: Object.assign({ flat: true }, kind === 'heading' ? noteInk : cardStyle),
  style: { bold: kind !== 'preview', condensed: false, align: 'left', upper: false }, panel: 'note' });
const listBlocks = [
  part('card', ' ', [0.31, 0.26, 0.592, 0.81], cardStyle),
  listPart('Önerilen', 0.27, 'heading'), listPart('Cal', 0.30, 'name'), listPart('Posta kutunda. Kaçtın', 0.32, 'preview'),
  listPart('Brian', 0.35, 'name'), listPart('Tamam. Biraz para var...', 0.37, 'preview'), listPart('Mesajlar', 0.40, 'heading'),
  listPart('Donnie', 0.43, 'name'), listPart('Joey', 0.46, 'name'), listPart('Selam, ben Joey...', 0.48, 'preview'),
  listPart('Rusty Anchor', 0.52, 'name')];
const messageList = `
  var region = { id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: ${JSON.stringify(listBlocks)} };
  showRegion(region);
  var panel = document.querySelector('.phone-panel');
  var nodes = Array.prototype.slice.call(panel.querySelectorAll('.panel-row'));
  nodes.forEach(function (row, i) { row.couchsubsMark = i; });
  var card = rect(panel);
  var rows = nodes.map(function (row) {
    var bubble = row.querySelector('.panel-bubble'), style = getComputedStyle(bubble);
    return { text: bubble.textContent, cls: row.className, weight: parseInt(style.fontWeight, 10), align: style.textAlign,
      color: style.color, box: rect(bubble) };
  });
  // Sallanan telefon: kutular biraz oynar, içerik aynı.
  var again = JSON.parse(JSON.stringify(region));
  again.blocks.forEach(function (b, i) { if (i) { b.box.top += 0.002; b.box.bottom += 0.002; } });
  showRegion(again);
  var kept = document.querySelector('.phone-panel') === panel &&
    Array.prototype.every.call(panel.querySelectorAll('.panel-row'), function (row, i) { return row.couchsubsMark === i; }) &&
    panel.querySelectorAll('.panel-row').length === nodes.length;
  // Yalnız bir önizleme değişti: yalnız o satır yenilenir.
  var changed = JSON.parse(JSON.stringify(region));
  changed.blocks[9].text = 'Selam, ben Joey. Neredesin?';
  showRegion(changed);
  var after = Array.prototype.slice.call(panel.querySelectorAll('.panel-row'));
  var only = after.length === nodes.length && after.every(function (row, i) { return i === 8 ? row.couchsubsMark === undefined : row.couchsubsMark === i; });
  $('result').textContent = JSON.stringify({ card: card, rows: rows, kept: kept, only: only });`;

test('Mesajlar listesi sola yaslı liste: ad kalın, önizleme altında, başlıklar ayrı; aynı liste yeniden çizilmez', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = measure(messageList);
  assert.deepEqual(r.rows.map(row => row.text), listBlocks.slice(1).map(b => b.text), 'telefondaki sıra korunmadı');
  assert.ok(r.rows.every(row => row.cls.indexOf('list') >= 0 && row.align === 'left'), 'liste satırı ortalı: ' + JSON.stringify(r.rows));
  assert.ok(r.rows.every(row => row.box.left - r.card.left < 0.03 * 1920), 'liste satırı sola yaslı değil');
  const by = text => r.rows.find(row => row.text === text);
  for (const name of ['Cal', 'Brian', 'Donnie', 'Joey', 'Rusty Anchor', 'Önerilen', 'Mesajlar']) assert.ok(by(name).weight >= 700, name + ' kalın değil');
  assert.ok(by('Tamam. Biraz para var...').weight < 600, 'önizleme kalın');
  assert.equal(by('Mesajlar').color, 'rgb(169, 165, 156)', 'bölüm başlığı soluk değil');
  assert.ok(by('Tamam. Biraz para var...').box.top - by('Brian').box.bottom < 0.2 * 22 * 1.08, 'önizleme adın hemen altında değil');
  assert.ok(by('Cal').box.top - by('Önerilen').box.bottom > 0.3 * 22 * 1.08, 'başlıktan sonraki ad başlığa yapışık');
  for (let i = 0; i + 1 < r.rows.length; i++) assert.ok(r.rows[i].box.bottom <= r.rows[i + 1].box.top + 1, 'satırlar üst üste');
  assert.equal(r.kept, true, 'aynı liste satırları yeniden yarattı');
  assert.equal(r.only, true, 'değişen tek önizleme dışında satırlar yeniden yaratıldı');
  shoot(messageList, 'tv-phone-list.png');
});

// Hizalı panel (TV uygulaması 0.9.106; Sinan Bey'in beğendiği görünüm): bilgisayar zemine `aligned: true` koyar. Zemin
// kartı ve kanepe simgesi çizilmez; her Türkçe balon gönderilen kutusunda (telefondaki İngilizce balonuyla aynı
// yükseklikte), telefonun balon renginde %85 örtülü; gelen sola, giden sağa yaslı; kişi adı üstte küçük başlık. Gerçek
// yazı tahminden uzunsa alttaki balon en az kaydırmayla itilir, panel uzar. Aynı gönderi satırları yeniden yaratmaz,
// yeri değişen satır aynı düğümle kayar. Bayraksız gönderi (eski bilgisayar) eskisi gibi akışla çizilir (yukarıdaki testler).
const cream = { background: '#F0E8E0', foreground: '#282828' };
const blue = { background: '#D0D8F0', foreground: '#282828' };
const alignedBlocks = () => [
  Object.assign(part('card', ' ', [0.31, 0.26, 0.592, 0.81], cardStyle), { aligned: true }),
  part('title', 'Lucia', [0.323, 0.262, 0.579, 0.293], cardStyle),
  part('theirs', 'Neredesin?', [0.323, 0.30, 0.42, 0.335], cream),
  part('mine', 'Yoldayım, beş dakikaya oradayım.', [0.42, 0.42, 0.579, 0.455], blue),
  // Tahmin kısa: gerçek yazı üç satır tutar, alttaki balonun kutusuyla çakışır.
  part('theirs', 'Malzemeleri getir, sakın unutma, bu sefer gerçekten önemli, herkes bekliyor seni orada', [0.323, 0.50, 0.50, 0.535], cream),
  part('mine', 'Tamam', [0.50, 0.545, 0.579, 0.58], blue)];
const alignedPanel = `
  var region = { id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: ${JSON.stringify(alignedBlocks())} };
  showRegion(region);
  var panel = document.querySelector('.phone-panel');
  var nodes = Array.prototype.slice.call(panel.querySelectorAll('.panel-row'));
  nodes.forEach(function (row, i) { row.couchsubsMark = i; });
  var rows = nodes.map(function (row) {
    var bubble = row.querySelector('.panel-bubble'), style = getComputedStyle(bubble);
    return { text: bubble.textContent, cls: row.className, background: style.backgroundColor, color: style.color,
      font: parseFloat(style.fontSize), box: rect(bubble) };
  });
  var style = getComputedStyle(panel);
  var info = { cls: panel.className, background: style.backgroundColor, couch: !!panel.querySelector('.panel-couch'),
    list: !!panel.querySelector('.panel-messages'), panel: rect(panel), loose: document.querySelectorAll('#regions .item').length };
  // Aynı gönderi: hiçbir satır yeniden yaratılmaz.
  showRegion(JSON.parse(JSON.stringify(region)));
  var same = Array.prototype.every.call(panel.querySelectorAll('.panel-row'), function (row, i) { return row.couchsubsMark === i; });
  // Sohbet kaydı: kutular yukarı kayar; aynı düğümler yeni yerlerinde.
  var moved = JSON.parse(JSON.stringify(region));
  moved.blocks.forEach(function (b, i) { if (i > 2) { b.box.top -= 0.05; b.box.bottom -= 0.05; } });
  showRegion(moved);
  var after = Array.prototype.slice.call(panel.querySelectorAll('.panel-row'));
  var follows = document.querySelector('.phone-panel') === panel && after.length === nodes.length &&
    after.every(function (row, i) { return row.couchsubsMark === i; }) &&
    Math.abs(parseFloat(after[2].style.top) - Math.round((0.37 - 0.26) * window.innerHeight)) <= 1;
  $('result').textContent = JSON.stringify({ rows: rows, info: info, same: same, follows: follows, h: window.innerHeight, w: window.innerWidth });`;

test('hizalı panel: her balon İngilizce balonunun yüksekliğinde, zeminsiz; çakışan balon itilir, düğümler korunur', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = measure(alignedPanel);
  assert.equal(r.info.cls, 'phone-panel aligned');
  assert.equal(r.info.loose, 0, 'panel parçaları ayrıca yerinde çizilmez');
  assert.equal(r.info.couch, false, 'simge çizildi');
  assert.equal(r.info.list, false, 'akış listesi kuruldu');
  assert.equal(r.info.background, 'rgba(0, 0, 0, 0)', 'panelin zemini var: ' + r.info.background);
  assert.deepEqual(r.rows.map(row => row.text), ['Lucia', 'Neredesin?', 'Yoldayım, beş dakikaya oradayım.',
    alignedBlocks()[4].text, 'Tamam']);
  const blocks = alignedBlocks(), card = blocks[0].box;
  // Ekrandaki yer: panelin köşesinden, sayfanın görünen boyuyla (gönderilen kutu karenin oranıdır).
  const y = v => r.info.panel.top + (v - card.top) * r.h, x = v => r.info.panel.left + (v - card.left) * r.w;
  // Üst kenar gönderilen kutuda (±3 piksel): telefondaki İngilizce balonla aynı yükseklik.
  for (const i of [0, 1, 2, 3]) assert.ok(Math.abs(r.rows[i].box.top - y(blocks[i + 1].box.top)) <= 3, 'balon hizasız: ' + JSON.stringify(r.rows[i]));
  // Gelen sola (kutunun solu), giden sağa (kutunun sağı) yaslı.
  assert.ok(Math.abs(r.rows[1].box.left - x(blocks[2].box.left)) <= 3, 'gelen balon sola yaslı değil');
  assert.ok(Math.abs(r.rows[2].box.right - x(blocks[3].box.right)) <= 3, 'giden balon sağa yaslı değil');
  // Telefonun balon rengi, %85 örtü.
  assert.equal(r.rows[1].background, 'rgba(240, 232, 224, 0.85)');
  assert.equal(r.rows[2].background, 'rgba(208, 216, 240, 0.85)');
  assert.equal(r.rows[1].color, 'rgb(40, 40, 40)');
  // Kişi adı küçük başlık (balondan küçük).
  assert.ok(r.rows[0].cls.indexOf('title') >= 0 && r.rows[0].font < r.rows[1].font, 'başlık küçük değil');
  assert.ok(r.rows.slice(1).every(row => row.font >= 18) && r.rows[0].font >= 15, 'yazı okunamayacak kadar küçük');
  // Uzun balon tahminden uzun: "Tamam" en az kaydırmayla altına itilir (gönderilen 0,01 aralık korunur), panel uzar.
  const gap = Math.round((blocks[5].box.top - card.top) * r.h) - Math.round((blocks[4].box.bottom - card.top) * r.h);
  assert.ok(r.rows[3].box.bottom > y(blocks[4].box.bottom) + 10, 'deneme: uzun balon tahmini aşmadı');
  assert.ok(Math.abs(r.rows[4].box.top - (r.rows[3].box.bottom + gap)) <= 2, 'çakışan balon en az kaydırmayla itilmedi: ' + JSON.stringify(r.rows));
  for (let i = 0; i + 1 < r.rows.length; i++) assert.ok(r.rows[i].box.bottom <= r.rows[i + 1].box.top + 1, 'balonlar üst üste');
  assert.ok(r.info.panel.bottom >= r.rows[4].box.bottom - 1, 'panel uzamadı');
  assert.equal(r.same, true, 'aynı gönderi satırları yeniden yarattı');
  assert.equal(r.follows, true, 'kayan sohbette satırlar yeniden yaratıldı ya da yeni yerine geçmedi');
  shoot(alignedPanel, 'tv-phone-aligned.png');
});

// Eski TV ile yeni bilgisayar: 0.9.105 `aligned`'ı tanımaz; aynı hizalı gönderiyi eskisi gibi kartta akışla çizer, bütün
// mesajlar görünür (git geçmişindeki 0.9.105 sayfası; geçmiş yoksa atlanır). Yeni TV bayraksız gönderiyi (eski bilgisayar)
// yukarıdaki Yanda Panel testlerindeki gibi akışla çizer.
const oldApp = (() => {
  const r = spawnSync('git', ['show', '95200990:tv-webos/app.js'], { cwd: path.join(__dirname, '..'), encoding: 'utf8', maxBuffer: 1 << 26 });
  return r.status === 0 ? r.stdout : null;
})();
const oldTvAligned = `
  showRegion({ id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: ${JSON.stringify(alignedBlocks())} });
  var panel = document.querySelector('.phone-panel');
  var list = panel.querySelector('.panel-messages');
  $('result').textContent = JSON.stringify({ cls: panel.className, rows: panel.querySelectorAll('.panel-row').length,
    title: (panel.querySelector('.panel-title') || {}).textContent, fits: list.scrollHeight <= list.clientHeight + 1 });`;

test('eski TV (0.9.105) hizalı gönderiyi eskisi gibi akışla çizer', { skip: (!browser && 'Chromium/Chrome bulunamadı') || (!oldApp && 'git geçmişi yok') }, () => {
  const r = measure(oldTvAligned, oldApp);
  assert.equal(r.cls, 'phone-panel');
  assert.equal(r.title, 'Lucia');
  assert.equal(r.rows, 4, 'eski TV mesajları düşürdü');
  assert.equal(r.fits, true);
});

// Hizalı panel her TV'de aynı oranda (720p, 1080p, 4K; cihaz piksel oranı 1, 2, 3): balonların yeri ve yazı boyu ekrana
// oranla aynı, yazı yatayda sıkıştırılmaz (dar aile, harf aralığı yok). Panel gelirken solarak belirir; telefon kalkınca
// hemen silinmez, solarak kaybolur (PANEL_FADE_MS sonra kalkar).
const alignedScale = `
  showRegion({ id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: ${JSON.stringify(alignedBlocks())} });
  var panel = document.querySelector('.phone-panel');
  var w = window.innerWidth, h = window.innerHeight;
  var rows = Array.prototype.map.call(panel.querySelectorAll('.panel-bubble'), function (bubble) {
    var r = rect(bubble), style = getComputedStyle(bubble);
    return { left: r.left / w, top: r.top / h, right: r.right / w, font: parseFloat(style.fontSize) / h,
      stretch: style.fontStretch, spacing: style.letterSpacing, transform: getComputedStyle(bubble.parentNode).transform };
  });
  var fadeIn = getComputedStyle(panel).animationName;
  var host = panel.parentNode;
  hideRegion('game-phone');
  var leaving = host.parentNode === $('regions') && /leaving/.test(host.className) && !regionBoxes['game-phone'];
  $('result').textContent = JSON.stringify({ rows: rows, fadeIn: fadeIn, leaving: leaving, dpr: window.devicePixelRatio, h: h });`;

test('hizalı panel 720p, 1080p, 4K ve dpr 1/2/3 aynı oranda; sıkıştırma yok; solarak gelir ve gider', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const screens = [];
  for (const size of ['1280,720', '1920,1080', '3840,2160']) for (const dpr of [1, 2, 3]) screens.push({ size, dpr });
  // Başsız tarayıcının penceresi görünen alandan biraz yüksek: görünen alan TV gibi tam 16:9 olsun diye pencere uzatılır.
  const sixteenNine = screen => {
    const [w, h] = screen.size.split(',').map(Number);
    const first = measure(alignedScale, null, screen);
    if (first.h === h) return first;
    return measure(alignedScale, null, { size: w + ',' + (2 * h - first.h), dpr: screen.dpr });
  };
  const base = sixteenNine(screens[3]);
  assert.equal(base.fadeIn, 'phone-panel-in', 'panel solarak gelmiyor');
  assert.equal(base.leaving, true, 'telefon kalkınca panel solmadan silindi');
  for (const screen of screens) {
    const r = screen === screens[3] ? base : sixteenNine(screen);
    assert.equal(r.h, Number(screen.size.split(',')[1]), 'görünen alan 16:9 değil');
    assert.equal(r.dpr, screen.dpr, 'dpr uygulanmadı');
    assert.equal(r.rows.length, base.rows.length);
    r.rows.forEach((row, i) => {
      const ref = base.rows[i], tag = screen.size + '@' + screen.dpr + ' #' + i;
      assert.ok(Math.abs(row.left - ref.left) <= 0.004 && Math.abs(row.top - ref.top) <= 0.006, 'yer oranı farklı: ' + tag);
      assert.ok(Math.abs(row.font - ref.font) <= 0.0015, 'yazı boyu oranı farklı: ' + tag);
      assert.ok(row.font * r.h >= (i ? 18 : 15) * r.h / 1080 - 0.5, 'yazı alt sınırın altında: ' + tag);
      assert.equal(row.stretch, '100%', 'yazı yatayda sıkıştırıldı: ' + tag);
      assert.equal(row.spacing, 'normal', 'harf aralığı daraltıldı: ' + tag);
      assert.equal(row.transform, 'none', 'satır ölçeklendi: ' + tag);
    });
  }
});

// Telefon listesinin tek kartı (TV uygulaması 0.9.110; Sinan Bey, beta.100 3399): ad ve önizleme ayrı haplar değil,
// telefondaki satırın Türkçe kopyası tek kartta: avatar (oyundan kesilmiş resim), kalın ad, altında önizleme, rozet,
// seçili satırın çerçevesi. Kartın üstü gönderilen kutuda (İngilizce adın hizası), boyu en az telefondaki satır kadar;
// bölüm başlığı küçük başlık olarak kalır. Aynı gönderi düğümleri yeniden yaratmaz, kaydırılan liste aynı düğümlerle kayar.
// Ana ekran bileşeni aynı kart. Eski TV (0.9.105) kartı tanımaz; ad ve önizleme iki satır yerinde çizilir, kaybolmaz.
const avatarPng = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGM4YaMBRwzEcQDxwxLBXOwG1wAAAABJRU5ErkJggg==';
const badgePng = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGPQyHsGRwzEcQBd8hfBRQprogAAAABJRU5ErkJggg==';
const rowCard = { background: '#F4F1EC', foreground: '#17181B' };
const listRow = (name, preview, box, extra) => Object.assign(part('row', name + '\n' + preview, box, rowCard),
  { paragraphs: true, row: Object.assign({ name, preview, avatar: avatarPng }, extra || {}) });
const listCards = () => [
  Object.assign(part('card', ' ', [0.31, 0.26, 0.592, 0.81], cardStyle), { aligned: true }),
  Object.assign(part('note', 'Önerilen', [0.323, 0.262, 0.579, 0.302], { background: '#141518', foreground: '#A9A59C' }),
    { style: { align: 'left', bold: true, condensed: false, upper: false } }),
  listRow('Cal', '$ posta kutunda. Beni yine...', [0.323, 0.31, 0.579, 0.39], { badge: badgePng, selected: '#3A6FD8' }),
  listRow('Brian', 'Tamam. Biraz para var...', [0.323, 0.41, 0.579, 0.49], { badge: badgePng }),
  listRow('Donnie', '', [0.323, 0.51, 0.579, 0.59]),
  Object.assign(listRow('Hatırlatıcılar', '6 Bildirim', [0.323, 0.62, 0.579, 0.68], { widget: true }),
    { surface: { background: '#3A3F55', foreground: '#FFFFFF' } })];
const listCardsScript = `
  var region = { id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: ${JSON.stringify(listCards())} };
  showRegion(region);
  var panel = document.querySelector('.phone-panel');
  var nodes = Array.prototype.slice.call(panel.querySelectorAll('.panel-row'));
  nodes.forEach(function (row, i) { row.couchsubsMark = i; });
  var cards = Array.prototype.map.call(panel.querySelectorAll('.panel-card'), function (card) {
    var style = getComputedStyle(card), name = card.querySelector('.panel-card-name'), preview = card.querySelector('.panel-card-preview');
    var avatar = card.querySelector('.panel-avatar'), badge = card.querySelector('.panel-badge');
    return { box: rect(card), cls: card.className, background: style.backgroundColor, shadow: style.boxShadow,
      name: name ? name.textContent : null, nameWeight: name ? getComputedStyle(name).fontWeight : null,
      preview: preview ? preview.textContent : null, avatar: avatar ? rect(avatar) : null, badge: badge ? rect(badge) : null,
      pills: card.querySelectorAll('.panel-bubble').length };
  });
  var heading = panel.querySelector('.panel-row.note .panel-bubble');
  var info = { loose: document.querySelectorAll('#regions .item').length, heading: heading ? heading.textContent : null,
    headingFont: heading ? parseFloat(getComputedStyle(heading).fontSize) : 0, panel: rect(panel) };
  showRegion(JSON.parse(JSON.stringify(region)));
  var same = Array.prototype.every.call(panel.querySelectorAll('.panel-row'), function (row, i) { return row.couchsubsMark === i; });
  var moved = JSON.parse(JSON.stringify(region));
  moved.blocks.forEach(function (b, i) { if (i > 0) { b.box.top -= 0.04; b.box.bottom -= 0.04; } });
  showRegion(moved);
  var after = Array.prototype.slice.call(panel.querySelectorAll('.panel-row'));
  var follows = after.length === nodes.length && after.every(function (row, i) { return row.couchsubsMark === i; }) &&
    Math.abs(parseFloat(after[1].style.top) - Math.round((0.31 - 0.04 - 0.26) * window.innerHeight)) <= 1;
  $('result').textContent = JSON.stringify({ cards: cards, info: info, same: same, follows: follows, h: window.innerHeight, w: window.innerWidth });`;

test('Mesajlar listesi: her satır tek kart (avatar, kalın ad, önizleme, rozet, seçim), hizalı; bileşen kartı', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = measure(listCardsScript);
  const blocks = listCards(), card = blocks[0].box;
  assert.equal(r.info.loose, 0, 'kart parçaları ayrıca yerinde çizildi');
  assert.equal(r.cards.length, 4, 'her satır tek kart değil');
  assert.ok(r.cards.every(c => c.pills === 0), 'kartın içinde ayrı hap var');
  assert.deepEqual(r.cards.map(c => c.name), ['Cal', 'Brian', 'Donnie', 'Hatırlatıcılar']);
  assert.deepEqual(r.cards.map(c => c.preview), ['$ posta kutunda. Beni yine...', 'Tamam. Biraz para var...', null, '6 Bildirim']);
  assert.ok(r.cards.every(c => Number(c.nameWeight) >= 700), 'ad kalın değil');
  const y = v => r.info.panel.top + (v - card.top) * r.h;
  r.cards.forEach((c, i) => {
    const sent = blocks[i + 2].box;
    assert.ok(Math.abs(c.box.top - y(sent.top)) <= 3, 'kart hizasız: ' + i + ' ' + c.box.top + ' ' + y(sent.top));
    assert.ok(c.box.bottom - c.box.top >= (sent.bottom - sent.top) * r.h - 2, 'kart telefondaki satırdan kısa: ' + i);
    assert.ok(c.avatar && c.avatar.left >= c.box.left && c.avatar.right < c.box.left + (c.box.right - c.box.left) / 3, 'avatar solda değil: ' + i);
  });
  for (let i = 0; i + 1 < r.cards.length; i++) assert.ok(r.cards[i].box.bottom <= r.cards[i + 1].box.top + 1, 'kartlar üst üste');
  assert.equal(r.cards[0].background, 'rgba(244, 241, 236, 0.85)', 'satır kartı rengi');
  assert.ok(/58, 111, 216/.test(r.cards[0].shadow), 'seçili satırın çerçevesi yok: ' + r.cards[0].shadow);
  assert.equal(r.cards[1].shadow, 'none', 'seçili olmayan satırda çerçeve');
  assert.ok(r.cards[0].badge && r.cards[0].badge.right <= r.cards[0].box.right && r.cards[0].badge.left > r.cards[0].box.left + (r.cards[0].box.right - r.cards[0].box.left) / 2, 'rozet sağda değil');
  assert.equal(r.cards[2].badge, null);
  assert.ok(/widget/.test(r.cards[3].cls) && r.cards[3].background === 'rgba(58, 63, 85, 0.85)', 'bileşen kartı rengi');
  assert.equal(r.info.heading, 'Önerilen', 'bölüm başlığı küçük başlık değil');
  assert.equal(r.same, true, 'aynı liste kartları yeniden yarattı');
  assert.equal(r.follows, true, 'kaydırılan listede kartlar birlikte kaymadı');
  shoot(listCardsScript, 'tv-phone-list-cards.png');
});

const oldTvCards = `
  showRegion({ id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.26, right: 0.79, bottom: 0.81 }, blocks: ${JSON.stringify(listCards())} });
  $('result').textContent = JSON.stringify({ text: document.getElementById('regions').textContent });`;

test('eski TV (0.9.105) liste kartını tanımaz; ad ve önizleme yine görünür', { skip: (!browser && 'Chromium/Chrome bulunamadı') || (!oldApp && 'git geçmişi yok') }, () => {
  const r = measure(oldTvCards, oldApp);
  for (const text of ['Cal', '$ posta kutunda. Beni yine...', 'Brian', 'Hatırlatıcılar', '6 Bildirim']) {
    assert.ok(r.text.indexOf(text) >= 0, 'eski TV yazıyı düşürdü: ' + text);
  }
});

// Telefonun sohbet dışı ekranı (TV uygulaması 0.9.113; Sinan Bey, beta.100 3416–3425): makale başlığı, gövde ve uygulama
// satırları avatarsız kartlarda, telefon yazısıyla orantılı boyda (bilgisayar satırı en çok 0,03 gönderir; 3416'daki dev
// balon olmaz), kart yazı boyunda (avatar boyunda değil), başlık satır kırar, kartlar ekranın içinde ve üst üste binmez.
const bareCard = (name, preview, box) => Object.assign(part('row', [name, preview].filter(Boolean).join('\n'), box, rowCard),
  { paragraphs: true, line: 0.03, row: { name, preview } });
const appCards = () => [
  Object.assign(part('card', ' ', [0.31, 0.2, 0.592, 0.85], cardStyle), { aligned: true, line: 0.03 }),
  bareCard('Meclis sahil planını uzun tartışmalardan sonra onayladı', '', [0.323, 0.21, 0.579, 0.3]),
  bareCard('', 'Meclis salı geç saatte uzun süredir bekleyen planı onayladı.', [0.323, 0.33, 0.579, 0.42]),
  bareCard('Güç Seansı', 'Aşama 2/4', [0.323, 0.45, 0.579, 0.52]),
  bareCard('', 'Arka Plan', [0.323, 0.55, 0.579, 0.59])];
const appCardsScript = `
  showRegion({ id: 'game-phone', text: 'x', box: { left: 0.31, top: 0.2, right: 0.79, bottom: 0.85 }, blocks: ${JSON.stringify(appCards())} });
  var panel = document.querySelector('.phone-panel');
  var cards = Array.prototype.map.call(panel.querySelectorAll('.panel-card'), function (card) {
    var name = card.querySelector('.panel-card-name'), preview = card.querySelector('.panel-card-preview');
    return { box: rect(card), cls: card.className, avatar: !!card.querySelector('.panel-avatar'),
      name: name ? rect(name) : null, preview: preview ? rect(preview) : null,
      font: parseFloat(getComputedStyle(panel).fontSize) };
  });
  $('result').textContent = JSON.stringify({ cards: cards, w: window.innerWidth, h: window.innerHeight });`;

test('sohbet dışı ekran: avatarsız kartlar orantılı boyda, başlık satır kırar, ekranın içinde', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = measure(appCardsScript);
  assert.equal(r.cards.length, 4);
  assert.ok(r.cards.every(c => !c.avatar && /bare/.test(c.cls)), 'avatarsız kart');
  const font = r.cards[0].font;
  assert.ok(font <= 0.03 * r.h * 0.95 + 0.5 && font >= 20, 'yazı orantılı: ' + font);
  // Başlık satır kırar (tek satıra sıkışıp kesilmez) ve kartın içinde kalır.
  const title = r.cards[0];
  assert.ok(title.name.bottom - title.name.top > font * 1.6, 'başlık satır kırmadı');
  assert.ok(title.name.right <= title.box.right + 1 && title.name.bottom <= title.box.bottom + 1, 'başlık kartın dışında');
  // Tek satırlık kart avatar boyunda değil, yazı boyunda.
  const single = r.cards[3];
  assert.ok(single.box.bottom - single.box.top < font * 2.31, 'tek satırlık kart avatar boyunda: ' + (single.box.bottom - single.box.top));
  for (const c of r.cards) assert.ok(c.box.left >= 0 && c.box.right <= r.w && c.box.top >= 0 && c.box.bottom <= r.h, 'kart ekran dışında');
  for (let i = 0; i + 1 < r.cards.length; i++) assert.ok(r.cards[i].box.bottom <= r.cards[i + 1].box.top + 1, 'kartlar üst üste');
  shoot(appCardsScript, 'tv-phone-app-cards.png');
});

// X (@justwiever, beta-106, iki kez): telefonun yanındaki çeviri "küçük panel, okunmuyor". Bilgisayar artık panelin
// satırını altyazı boyunun ~%85'inde gönderir (ScreenPhoneCard.minLine 0,038; kart en az ekranın 0,34'ü). TV o satırla
// çizer: gerçek karedeki telefonun (gta6-telefon-sohbet-1; sağ el ve aynalanmış sol el, #1407) yanında yazı 1080p'de en
// az ~39, 4K'da ~78 piksel; balonlar kartın ve ekranın içinde, kenara sıkışmaz.
const readableBlocks = (left) => {
  const at = (x0, x1) => [left + x0, 0, left + x1, 0];
  const row = (kind, text, x0, x1, top, bottom, surface) => {
    const b = at(x0, x1);
    return Object.assign(part(kind, text, [b[0], top, b[2], bottom], surface), { line: 0.038 });
  };
  return [
    Object.assign(part('card', ' ', [left, 0.195, left + 0.34, 0.861], cardStyle), { aligned: true, line: 0.038 }),
    row('theirs', 'Neredesin adamım', 0.017, 0.2, 0.30, 0.37, cream),
    row('mine', 'Yoldayım, beş dakikaya oradayım', 0.051, 0.323, 0.40, 0.52, blue),
    row('theirs', 'Sağ ol dostum! Başka bir şey bulursan bana getir', 0.017, 0.289, 0.55, 0.67, cream)];
};
const readableScript = (left) => `
  showRegion({ id: 'game-phone', text: 'x', box: { left: 0.2, top: 0.195, right: 0.8, bottom: 0.861 }, blocks: ${JSON.stringify(readableBlocks(left))} });
  var panel = document.querySelector('.phone-panel');
  var bubbles = Array.prototype.map.call(panel.querySelectorAll('.panel-bubble'), function (bubble) {
    return { box: rect(bubble), font: parseFloat(getComputedStyle(bubble).fontSize) };
  });
  $('result').textContent = JSON.stringify({ bubbles: bubbles, panel: rect(panel), w: window.innerWidth, h: window.innerHeight });`;

test('telefon çevirisi okunur boyda: altyazının ~%85\'i, 1080p ve 4K, sağ ve sol el', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  for (const size of ['1920,1080', '3840,2160']) {
    for (const left of [0.257, 0.401]) {
      const r = measure(readableScript(left), null, { size, dpr: 1 });
      const tag = size + ' ' + left;
      assert.equal(r.bubbles.length, 3, tag);
      for (const b of r.bubbles) {
        assert.ok(b.font >= 46 * 0.85 * r.h / 1080 - 1, 'yazı küçük: ' + b.font + ' ' + tag);
        assert.ok(b.box.left >= r.panel.left - 1 && b.box.right <= r.panel.right + 1, 'balon kartın dışında: ' + tag);
        assert.ok(b.box.left >= 0 && b.box.right <= r.w, 'balon ekranın dışında: ' + tag);
      }
      assert.ok(r.panel.right - r.panel.left >= 0.34 * r.w - 2, 'kart dar: ' + tag);
    }
  }
});
