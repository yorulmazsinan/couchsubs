// SPDX-License-Identifier: AGPL-3.0-only
// TV altyazı kutusu yalnız yazıyı kaplar (tv-webos/app.js fitBox; Samsung ve Android TV de bu sayfayı kullanır).
// Tarayıcı bölünmüş satırı sığdıramayıp yeniden kırınca inline-block kutu en geniş hâline açılıyor, iki yanda boş siyah
// alan kalıyordu. node --test scripts/tv-subtitle-box.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
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
  const start = app.indexOf('  function fitBox(el)');
  const end = app.indexOf('\n  }\n', start) + 4;
  assert.ok(start > 0 && end > start, 'fitBox bulunamadı');
  // İkinci satır kutuya sığmıyor: tarayıcı onu kendisi yeniden kırar (uygulamanın ölçümü tutmadığında olduğu gibi).
  const text = 'Yerel bağımlılar ona katalitik\nkonvertörü eksik bir araba bulabilirlerdi ama kimse bunu bilmiyordu sanırım.';
  const html = `<!doctype html><meta charset="utf-8"><style>${fs.readFileSync(path.join(root, 'style.css'), 'utf8')}</style>
    <div id="subtitle" style="left:0;right:0;width:1000px"><span id="subtitle-text"></span></div><pre id="result"></pre><script>
    function $(id) { return document.getElementById(id); }
    var bandShape = false;
    ${app.indexOf('  var pageProbe = null;') >= 0 ? app.slice(app.indexOf('  var pageProbe = null;'), app.indexOf('\n  var server = null;')) : ''}
    ${app.slice(start, end)}
    function measure(el) {
      var range = document.createRange(); range.selectNodeContents(el);
      var rects = Array.from(range.getClientRects()), cs = getComputedStyle(el);
      return { box: el.getBoundingClientRect().width, lines: rects.length,
        text: Math.max.apply(null, rects.map(function (r) { return r.right; })) - Math.min.apply(null, rects.map(function (r) { return r.left; })),
        padding: parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight) };
    }
    var el = $('subtitle-text');
    el.style.whiteSpace = 'pre-line';
    el.textContent = ${JSON.stringify(text)};
    var result = { before: measure(el) };
    fitBox(el);
    result.after = measure(el);
    bandShape = true;
    fitBox(el);
    result.band = measure(el);
    bandShape = false;
    el.textContent = 'Kısa satır.';
    fitBox(el);
    result.short = measure(el);
    result.shortWidth = el.style.width;
    $('result').textContent = JSON.stringify(result);
    </script>`;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-box-test-'));
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
test('TV altyazı kutusu yazıya oturur', { skip: !browser && 'Chrome/Edge bulunamadı' }, () => {
  const r = render();
  // Önce: kutu en geniş hâlinde, yazıdan belirgin geniş.
  assert.ok(r.before.box - r.before.padding - r.before.text > 20, JSON.stringify(r.before));
  // Sonra: kutu en uzun satır + iç boşluk; satır sayısı değişmez.
  assert.ok(r.after.box - r.after.padding - r.after.text <= 4, JSON.stringify(r.after));
  assert.equal(r.after.lines, r.before.lines);
  // Bantta kutu bilerek geniş kalır (genişlik verilmez).
  assert.ok(Math.abs(r.band.box - r.before.box) <= 1, JSON.stringify(r.band));
  // Zaten yazıya oturan kısa satıra genişlik yazılmaz.
  assert.equal(r.shortWidth, '');
});
