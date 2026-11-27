// SPDX-License-Identifier: AGPL-3.0-only
// #827: "Ekranı çevir" ve otomatik ekran yazısı aynı yazıyı çizerse TV'de yalnız biri görünür (tv-webos/app.js
// resolveLayers); çeviri kutusu her zeminde tam opaktır (özgün yazı arasından görünmez). Gerçek Chromium yerleşimiyle.
// node --test scripts/tv-screen-layers.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
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

// GTA 6 haritası: görev listesi satırı ve harita kartının açıklaması; zemin düz değil (harita).
const map = { background: '#1c2340', foreground: '#ffffff', flat: false };
const style = { bold: false, condensed: false, align: 'left', upper: false };
const block = (text, left, top, right, bottom) => ({ text, box: { left, top, right, bottom }, line: bottom - top, surface: map, style });

function render() {
  const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
  const start = app.indexOf('  var screenTimer = null;');
  const end = app.indexOf('\n  //', app.indexOf('  function hideScreen()', start));
  const regionStart = app.indexOf('  var regionBoxes = {};');
  const regionEnd = app.indexOf('\n  //', app.indexOf('  function hideRegions()', regionStart));
  const validStart = app.indexOf('  function validBox(box)');
  const validEnd = app.indexOf('\n  //', validStart);
  assert.ok(start > 0 && end > start && validStart > 0 && validEnd > validStart && regionStart > 0 && regionEnd > regionStart,
    'TV işlevleri bulunamadı');
  const fillStart = app.indexOf('  function fillText(');
  const fillEnd = app.indexOf('\n  }\n', fillStart) + 4;
  const needsFill = app.slice(start, end).indexOf('function fillText(') < 0 && app.slice(validStart, validEnd).indexOf('function fillText(') < 0 &&
    app.slice(regionStart, regionEnd).indexOf('function fillText(') < 0;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-layers-test-'));
  try {
    const html = `<!doctype html><meta charset="utf-8"><style>${fs.readFileSync(path.join(root, 'style.css'), 'utf8')}
      body { margin:0; background:#3040a0; }
      .english { position:absolute; color:#fff; font:28px sans-serif; white-space:nowrap; }</style>
      <div class="english" style="left:7.6%;top:24.5%">Find Donnie's Package</div>
      <div class="english" style="left:60%;top:50%">place in Key Lento.</div>
      <div id="regions" class="hidden"></div><div id="screen" class="hidden"></div><pre id="result"></pre><script>
      function $(id) { return document.getElementById(id); }
      function hideSubtitle() {}
      var diag = { regions: 0, big: 0 };
      ${app.indexOf('  var pageProbe = null;') >= 0 ? app.slice(app.indexOf('  var pageProbe = null;'), app.indexOf('\n  var server = null;')) : ''}
      ${app.slice(validStart, validEnd)}
      ${needsFill ? app.slice(fillStart, fillEnd) : ''}
      ${app.slice(start, end)}
      ${app.slice(regionStart, regionEnd)}
      function shown(el) { return getComputedStyle(el).visibility !== 'hidden'; }
      function blocks(id) { return Array.prototype.slice.call(regionBoxes[id].children).map(function (el) { return el.textContent + ':' + shown(el); }); }
      var result = {};
      var list = ${JSON.stringify(block('Donnie\'nin Paketini Bul', 0.074, 0.245, 0.25, 0.272))};
      var piece = ${JSON.stringify(block('Bulur', 0.15, 0.258, 0.19, 0.288))};
      var card = ${JSON.stringify(block('Kenton\'ın işi var. Key Lento\'daki evine uğra.', 0.595, 0.495, 0.855, 0.585))};
      var older = ${JSON.stringify(block('Kenton\'la tanıştın mı?', 0.6, 0.5, 0.85, 0.58))};
      var far = ${JSON.stringify(block('Para Kazan', 0.075, 0.185, 0.17, 0.21))};
      // Otomatik ekran yazısı: önce eski alan (kartın eski çevirisi ve satırın parçası), sonra yenisi aynı yerde.
      showRegion({ id: 'auto-1', text: 'x', box: older.box, blocks: [older, piece, far] });
      showRegion({ id: 'auto-2', text: 'y', box: list.box, blocks: [list] });
      result.afterNewRegion = blocks('auto-1');
      // Eski alan yerinde güncellenir (aynı yazı yeniden okundu, kutusu bir piksel oynadı): katman sırası değişmez, yeni alan
      // üstte kalır; iki alan her okumada birbirinin yerine geçmez (beta.106: telefon, görev ve ekran yazısı gidip geliyordu).
      for (var k = 0; k < 3; k++) {
        showRegion({ id: 'auto-1', text: 'x' + k, box: older.box, blocks: [older, piece, far] });
        showRegion({ id: 'auto-2', text: 'y' + k, box: list.box, blocks: [list] });
        showRegion({ id: 'auto-1', text: 'z' + k, box: older.box, blocks: [older, piece, far] });
      }
      result.afterUpdates = { auto1: blocks('auto-1'), auto2: blocks('auto-2') };
      // "Ekranı çevir" kartın yerini çizer: alttaki otomatik yazı gizlenir, başka yerdeki kalır.
      showScreen([card], 20000);
      result.withScreen = { auto1: blocks('auto-1'), auto2: blocks('auto-2') };
      var drawn = $('screen').children[0];
      result.screenBackground = getComputedStyle(drawn).backgroundColor;
      hideScreen();
      result.afterScreen = blocks('auto-1');
      // Görev satırı ekrandayken görevin kırpık okuması ("arch near the turbi") yeni otomatik alan olarak aynı yere gelir:
      // görevin Türkçesi gizlenmez, kırpık alan görünmez. Görev kalkınca otomatik alan görünür.
      var mission = ${JSON.stringify(block('Türbinin yakınında ara', 0.4, 0.86, 0.6, 0.89))};
      var cropped = ${JSON.stringify(block('Türbinin yakınında ara', 0.42, 0.86, 0.58, 0.89))};
      showRegion({ id: 'auto-mission', text: 'm', box: mission.box, blocks: [mission] });
      showRegion({ id: 'auto-9', text: 'c', box: cropped.box, blocks: [cropped] });
      result.mission = { mission: blocks('auto-mission'), cropped: blocks('auto-9') };
      showScreen([mission], 20000);
      result.missionUnderScreen = blocks('auto-mission');
      hideScreen();
      hideRegion('auto-mission');
      result.missionGone = blocks('auto-9');
      $('result').textContent = JSON.stringify(result);
      </script>`;
    const file = path.join(temp, 'test.html');
    fs.writeFileSync(file, html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1080',
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'),
      '--dump-dom', pathToFileURL(file).href], { encoding: 'utf8', timeout: 30000, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="result">([^<]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi');
    return JSON.parse(match[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&#39;/g, "'"));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

test('aynı yazıyı çizen katmanlardan yalnız biri görünür; kutu tam opak', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = render();
  // Yeni alan eskisinin yerine geçer: satırın parçası ("Bulur") gizlenir, kart ve uzaktaki satır kalır.
  assert.deepEqual(r.afterNewRegion, ["Kenton'la tanıştın mı?:true", 'Bulur:false', 'Para Kazan:true']);
  // Yerinde güncellenen eski alan yenisinin önüne geçmez (sıra sabit, gidip gelme yok).
  assert.deepEqual(r.afterUpdates.auto1, ["Kenton'la tanıştın mı?:true", 'Bulur:false', 'Para Kazan:true']);
  assert.deepEqual(r.afterUpdates.auto2, ["Donnie'nin Paketini Bul:true"]);
  // "Ekranı çevir" kartın yerini çizer: eski kart çevirisi gizlenir, uzaktaki satır ve yeni alan kalır.
  assert.deepEqual(r.withScreen.auto1, ["Kenton'la tanıştın mı?:false", 'Bulur:false', 'Para Kazan:true']);
  assert.deepEqual(r.withScreen.auto2, ["Donnie'nin Paketini Bul:true"]);
  // Düz olmayan zeminde de tam opak (önceden %94 opaktı, altındaki İngilizce seçiliyordu).
  assert.equal(r.screenBackground, 'rgb(28, 35, 64)');
  // Ekranı çevir kalkınca gizlenen otomatik yazı geri gelir.
  assert.deepEqual(r.afterScreen, ["Kenton'la tanıştın mı?:true", 'Bulur:false', 'Para Kazan:true']);
  // Görev satırı sonradan gelen otomatik ekran yazısının altında kalmaz; yalnız "Ekranı çevir" görevin önüne geçer.
  assert.deepEqual(r.mission, { mission: ['Türbinin yakınında ara:true'], cropped: ['Türbinin yakınında ara:false'] });
  assert.deepEqual(r.missionUnderScreen, ['Türbinin yakınında ara:false']);
  assert.deepEqual(r.missionGone, ['Türbinin yakınında ara:true']);
});
