// SPDX-License-Identifier: AGPL-3.0-only
// Görev/ekran yazısı kutusu ile altyazı üst üste binmez (tv-webos/app.js avoidRegions): görev satırı altyazıya bitişik
// olduğunda görev kutusu yalnız gerektiği kadar, aralarında küçük bir boşlukla kayar. Altyazının yeri hiç değişmez.
// node --test scripts/tv-screen-text-apart.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
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

function render() {
  const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
  const start = app.indexOf('  var AVOID_GAP');
  const end = app.indexOf('\n  function hideRegions()', start);
  const hideStart = app.indexOf('  function hideSubtitle(reason)');
  const hideEnd = app.indexOf('\n  }\n', hideStart) + 4;
  assert.ok(start > 0 && end > start && hideStart > 0, 'avoidRegions/hideSubtitle bulunamadı');
  const html = `<!doctype html><meta charset="utf-8"><style>${fs.readFileSync(path.join(root, 'style.css'), 'utf8')}
    #subtitle { position:absolute; left:20%; right:20%; bottom:8%; text-align:center; }</style>
    <div id="subtitle"><span id="subtitle-text">Lucia: Bunu bir daha yapmayacağız.</span></div>
    <div id="subtitle-cover" class="hidden"></div><div id="regions"></div><pre id="result"></pre><script>
    function $(id) { return document.getElementById(id); }
    var regionBoxes = {}, MISSION_ID = 'auto-mission';
    var hideTimer = null, shownAt = 0, diag = {};
    function renderDiag() {}
    function hidePrevious() {}
    ${app.indexOf('  var pageProbe = null;') >= 0 ? app.slice(app.indexOf('  var pageProbe = null;'), app.indexOf('\n  var server = null;')) : ''}
    ${app.slice(start, end)}
    ${app.slice(hideStart, hideEnd)}
    function box(id, left, top, w, h) {
      var el = document.createElement('div');
      el.className = 'region';
      el.textContent = 'Arabaya bin.';
      el.style.left = left + 'px'; el.style.top = top + 'px'; el.style.width = w + 'px'; el.style.height = h + 'px';
      $('regions').appendChild(el);
      regionBoxes[id] = el;
      return el;
    }
    var result = {};
    var sub = $('subtitle-text');
    var before = sub.getBoundingClientRect();
    result.before = { top: before.top, bottom: before.bottom };
    // Görev satırı altyazının hemen altında, onunla üst üste.
    var mission = box('auto-mission', 700, Math.round(before.bottom - 10), 520, 40);
    avoidRegions();
    var after = sub.getBoundingClientRect(), m = mission.getBoundingClientRect();
    result.below = { subBottom: after.bottom, missionTop: m.top, shift: after.top - before.top,
      missionShift: m.top - Math.round(before.bottom - 10) };
    // Görev kutusu altyazının üstünde başlarsa yukarı kayar.
    var upper = box('auto-upper', 700, Math.round(before.top - 30), 520, 40);
    avoidRegions();
    var u = upper.getBoundingClientRect();
    result.above = { missionBottom: u.bottom, subTop: sub.getBoundingClientRect().top };
    // Altyazı kalkınca kayan görev kutusu kendi yerine döner (eskiden bir sonraki altyazıya dek kayık kalıyordu).
    $('subtitle').className = '';
    avoidRegions();
    hideSubtitle('clear');
    result.missionBack = mission.getBoundingClientRect().top - Math.round(before.bottom - 10);
    result.upperBack = upper.getBoundingClientRect().top - Math.round(before.top - 30);
    $('subtitle').className = '';
    $('regions').removeChild(mission); delete regionBoxes['auto-mission'];
    $('regions').removeChild(upper); delete regionBoxes['auto-upper'];
    avoidRegions();
    result.back = sub.getBoundingClientRect().top - before.top;
    // Yatayda ayrı duran kutu altyazıyı kaydırmaz.
    box('auto-side', 10, Math.round(before.top), 100, 40);
    avoidRegions();
    result.side = sub.getBoundingClientRect().top - before.top;
    $('result').textContent = JSON.stringify(result);
    </script>`;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-apart-test-'));
  try {
    const file = path.join(temp, 'test.html');
    fs.writeFileSync(file, html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1080',
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'),
      '--dump-dom', pathToFileURL(file).href], { encoding: 'utf8', timeout: 30000, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="result">([^<]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi');
    return JSON.parse(match[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&'));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');
test('görev kutusu ile altyazı üst üste binmez', { skip: !browser && 'Chrome/Edge bulunamadı' }, () => {
  const r = render();
  // Altyazı yerinde kalır; görev kutusu altyazının altına kayar, arada küçük bir boşluk kalır, gereğinden fazla kaymaz.
  assert.equal(r.below.shift, 0);
  assert.ok(r.below.missionShift > 0, JSON.stringify(r));
  assert.ok(r.below.subBottom <= r.below.missionTop - 4, JSON.stringify(r));
  assert.ok(r.below.missionTop - r.below.subBottom <= 12, JSON.stringify(r));
  assert.ok(r.above.missionBottom <= r.above.subTop - 4, JSON.stringify(r));
  assert.equal(r.missionBack, 0, JSON.stringify(r));
  assert.equal(r.upperBack, 0, JSON.stringify(r));
  assert.equal(r.back, 0);
  assert.equal(r.side, 0);
});
