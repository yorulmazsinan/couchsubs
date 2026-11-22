// SPDX-License-Identifier: AGPL-3.0-only
// tv-android/platform.js: uygulama içi modda Activity arka plana düşünce sayfaya "gizlendi" denir ve bağlantı bırakılır
// (closeWhenHidden); katman penceresinde bırakılmaz. Çalıştırma: node --test scripts/tv-android-background.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const code = fs.readFileSync(path.join(__dirname, '..', 'tv-android', 'platform.js'), 'utf8');

function load(overlay) {
  const calls = [];
  const window = {
    AndroidTV: { isOverlay: () => overlay, appVersion: () => '' },
    addEventListener() {},
    __pageHidden: (hidden) => calls.push(hidden)
  };
  window.window = window;
  vm.runInNewContext(code, { window, document: { createElement: () => ({ style: {} }), head: { appendChild() {} }, body: { appendChild() {}, className: '' }, getElementById: () => null } });
  return { window, calls };
}

test('uygulama içi modda arka plana düşüş sayfaya iletilir ve bağlantı bırakılır', () => {
  const { window, calls } = load(false);
  assert.strictEqual(window.COUCHSUBS_PLATFORM.closeWhenHidden, true);
  window.__onBackground(true);
  window.__onBackground(false);
  assert.deepStrictEqual(calls, [true, false]);
});

test('katman modunda bağlantı arka planda bırakılmaz', () => {
  const { window, calls } = load(true);
  assert.strictEqual(window.COUCHSUBS_PLATFORM.closeWhenHidden, false);
  window.__onBackground(true);
  assert.deepStrictEqual(calls, []);
});
