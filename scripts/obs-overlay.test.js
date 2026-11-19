// SPDX-License-Identifier: AGPL-3.0-only
// OBS katmanının (core/Sources/CouchSubsCore/Resources/obs-overlay.html) gerçek Chromium yerleşimi.
// node --test scripts/obs-overlay.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER; ağ ve uygulama bağlantısı yok
// (EventSource sahte, olaylar test içinden verilir).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const overlay = path.join(__dirname, '..', 'core', 'Sources', 'CouchSubsCore', 'Resources', 'obs-overlay.html');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

// İki satıra bölünen (satır başına ~42 karakter) uzun çeviri; uygulamanın kendi penceresinde de iki satırdır.
const LONG = 'Bu bölgedeki bütün gizli belgeleri bulmadan güvenli bölgeye kesinlikle geri dönme.';
const box = (center, top = .85) => ({ left: center - .2, top, right: center + .2, bottom: top + .04 });
const cases = {
  fixed: { text: LONG },
  coverCenter: { text: LONG, box: box(.5) },
  coverRight: { text: LONG, box: box(.75) },
  above: { text: LONG, box: box(.5), placement: 'above' },
  coverBand: { text: LONG, box: box(.5), band: true },
};

function render(width, height) {
  const source = fs.readFileSync(overlay, 'utf8');
  // Sahte EventSource: katman bağlanınca dinleyiciler kaydedilir, test olayları kendisi verir.
  const stub = `<script>
    window.__listeners = {};
    window.EventSource = function () { this.addEventListener = function (n, f) { window.__listeners[n] = f; }; };
    function fire(name, data) { window.__listeners[name]({ data: JSON.stringify(data) }); }
  </script>`;
  const probe = `<pre id="result"></pre><script>
    var cases = ${JSON.stringify(cases)}, result = {};
    function measure() {
      var el = document.getElementById('line'), cs = getComputedStyle(el), b = el.getBoundingClientRect();
      var inner = el.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom);
      return { lines: Math.round(inner / parseFloat(cs.lineHeight)), wrapped: el.textContent.split('\\n').length,
        left: b.left, right: b.right, width: b.width };
    }
    for (var key in cases) {
      var c = cases[key];
      fire('style', { fontSize: 48, placement: c.placement || 'cover', backgroundShape: c.band ? 'band' : 'box' });
      fire('subtitle', { text: c.text, duration: 8000, box: c.box });
      result[key] = measure();
    }
    result.viewport = { width: innerWidth, height: innerHeight };
    document.getElementById('result').textContent = btoa(unescape(encodeURIComponent(JSON.stringify(result))));
  </script>`;
  const html = source.replace('<head>', '<head>' + stub).replace('</body>', probe + '</body>');
  assert.ok(html.includes('window.__listeners') && html.includes('id="result"'), 'katman sayfası beklenen biçimde değil');
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-obs-test-'));
  try {
    // Pencere çerçevesi yerine tam hedef çözünürlükte bir iframe (OBS tarayıcı kaynağının boyu).
    const encoded = Buffer.from(html, 'utf8').toString('base64');
    const page = `<!doctype html><iframe id="frame" style="border:0;width:${width}px;height:${height}px"></iframe>
      <pre id="result"></pre><script>
      var frame = document.getElementById('frame');
      frame.contentDocument.open();
      frame.contentDocument.write(decodeURIComponent(escape(atob('${encoded}'))));
      frame.contentDocument.close();
      document.getElementById('result').textContent = frame.contentDocument.getElementById('result').textContent;
      </script>`;
    const file = path.join(temp, 'test.html'); fs.writeFileSync(file, page);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking',
      '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1',
      '--window-size=' + width + ',' + height, ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
      '--user-data-dir=' + path.join(temp, 'profile'), '--dump-dom', pathToFileURL(file).href],
      { encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi: ' + run.stdout.slice(-1000));
    return JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
  } finally {
    assert.equal(path.dirname(temp), path.resolve(os.tmpdir()));
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');
// OBS'te tarayıcı kaynağının olağan boyları.
for (const [width, height] of [[1920, 1080], [1280, 720]]) {
  test('OBS katmanı: ' + width + '×' + height, { skip: !browser && 'Chrome/Edge bulunamadı' }, async t => {
    const r = render(width, height);
    assert.deepEqual(r.viewport, { width, height });
    for (const key of Object.keys(cases)) {
      await t.test(key + ': uygulamanın böldüğü satır sayısı korunur', () => {
        // Çeviri 2 satıra bölünür; tarayıcı kutuyu daraltıp bir kez daha bölerse OBS'te 3-4 satır olurdu.
        assert.equal(r[key].wrapped, 2, JSON.stringify(r[key]));
        assert.equal(r[key].lines, 2, JSON.stringify(r[key]));
      });
    }
    await t.test('örtü kutusu ekranın dışına taşmaz', () => {
      for (const key of ['coverCenter', 'coverRight']) {
        assert.ok(r[key].left >= -1 && r[key].right <= width + 1, key + ' ' + JSON.stringify(r[key]));
      }
    });
  });
}
