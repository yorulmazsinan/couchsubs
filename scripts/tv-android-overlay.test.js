// SPDX-License-Identifier: AGPL-3.0-only
// tv-android/platform.js, katman modu (beta.104, Vestel UA9600): katman penceresine hiçbir durum işareti çizilmez (eskiden
// bağlantı kopukken sağ üstte pembe nokta) ve bağlantı durumu Android'e bildirilir; Android uzun süre bağlantısız kalan
// katmanı kapatır (OverlayIdle.java). Çalıştırma: node --test scripts/tv-android-overlay.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const code = fs.readFileSync(path.join(__dirname, '..', 'tv-android', 'platform.js'), 'utf8');

function load(overlay) {
  const reports = [];
  const added = [];
  const styles = [];
  function FakeSource(url) {
    this.url = url;
    this.readyState = 0;
    this.listeners = {};
  }
  FakeSource.prototype.addEventListener = function (type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); };
  FakeSource.prototype.fire = function (type) { (this.listeners[type] || []).forEach((fn) => fn({ data: '{}' })); };
  FakeSource.prototype.close = function () { this.readyState = 2; };
  const window = {
    AndroidTV: { isOverlay: () => overlay, appVersion: () => '', connection: (open) => reports.push(open) },
    EventSource: FakeSource,
    addEventListener() {}
  };
  window.window = window;
  const document = {
    createElement: () => ({ style: {} }),
    head: { appendChild: (el) => styles.push(el.textContent || '') },
    body: { appendChild: (el) => added.push(el), className: '' },
    getElementById: () => null
  };
  vm.runInNewContext(code, { window, document, setTimeout, clearTimeout });
  window.COUCHSUBS_PLATFORM.init();
  return { window, reports, added, styles };
}

test('katman penceresine durum noktası ya da başka bir öğe eklenmez', () => {
  const { added, styles } = load(true);
  assert.deepStrictEqual(added, []);
  assert.ok(styles.every((css) => !/overlay-dot|border-radius|background/.test(css)), styles.join('\n'));
});

test('katmanda bağlantı açılınca ve kopunca Android\'e bildirilir', () => {
  const { window, reports } = load(true);
  assert.deepStrictEqual(reports, [false]);
  const source = new window.EventSource('http://pc:8787/events');
  source.readyState = 1;
  source.fire('open');
  assert.deepStrictEqual(reports, [false, true]);
  source.readyState = 0;
  source.fire('error');
  assert.deepStrictEqual(reports, [false, true, false]);
  source.readyState = 1;
  source.fire('open');
  source.close();
  assert.deepStrictEqual(reports, [false, true, false, true, false]);
});

test('tarama sırasında kapanan başka bir bağlantı açık olanı kopuk göstermez', () => {
  const { window, reports } = load(true);
  const main = new window.EventSource('http://pc:8787/events');
  main.readyState = 1;
  main.fire('open');
  const probe = new window.EventSource('http://other:8787/events');
  probe.readyState = 2;
  probe.fire('error');
  probe.close();
  assert.deepStrictEqual(reports, [false, true]);
});

test('uygulama içi modda bağlantı katmana bildirilmez', () => {
  const { window, reports, added } = load(false);
  const source = new window.EventSource('http://pc:8787/events');
  source.readyState = 1;
  source.fire('open');
  source.close();
  assert.deepStrictEqual(reports, []);
  assert.deepStrictEqual(added, []);
});
