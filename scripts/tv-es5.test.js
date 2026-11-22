// SPDX-License-Identifier: AGPL-3.0-only
// TV paketlerinin betikleri ES5 ile ayrıştırılır: 2015-2016 Samsung TV'lerin (Tizen 2.3-2.4) eski tarayıcısı ok
// fonksiyonu, let/const, şablon metni ve benzerini tanımaz; tek bir satır bütün sayfayı açılışta durdururdu (#761).
// acorn gerekir: COUCHSUBS_ACORN (acorn paketinin klasörü) ya da require('acorn'). CI kurar (tv-screen-tests.yml).
// Çalıştırma: npm install --no-save --prefix /tmp/acorn acorn@8.14.0 &&
//   COUCHSUBS_ACORN=/tmp/acorn/node_modules/acorn node --test scripts/tv-es5.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

let acorn = null;
try {
  acorn = require(process.env.COUCHSUBS_ACORN || 'acorn');
} catch (e) {
  acorn = null;
}

const root = path.join(__dirname, '..');
// Samsung paketine giren betikler (scripts/package-tizen.sh) ve LG/Android TV'nin platform betikleri.
const FILES = ['tv-webos/app.js', 'tv-webos/i18n.js', 'tv-webos/shell.js', 'tv-webos/config.js', 'tv-tizen/platform.js',
  'tv-webos/platform.js', 'tv-android/platform.js'];

test('TV betikleri ES5 ile ayrıştırılıyor (Tizen 2.3-2.4 tarayıcısı)', { skip: !acorn && 'acorn bulunamadı' }, () => {
  for (const name of FILES) {
    const file = path.join(root, name);
    if (!fs.existsSync(file)) continue;
    const code = fs.readFileSync(file, 'utf8');
    assert.doesNotThrow(() => acorn.parse(code, { ecmaVersion: 5, sourceType: 'script' }), name);
  }
});

test('ES5 denetimi gerçekten ES2015 sözdizimini yakalıyor', { skip: !acorn && 'acorn bulunamadı' }, () => {
  for (const code of ['var f = () => 1;', 'let a = 1;', 'var s = `x`;', 'var {a} = b;', 'class A {}']) {
    assert.throws(() => acorn.parse(code, { ecmaVersion: 5, sourceType: 'script' }), code);
  }
});

test('Tizen paketinin sayfası ES2015+ API\'sini korumasız çağırmıyor', () => {
  // Tizen 2.3'ün tarayıcısında olmayabilecek API'ler yalnız varlık denetimiyle kullanılır.
  const app = fs.readFileSync(path.join(root, 'tv-webos/app.js'), 'utf8');
  const platform = fs.readFileSync(path.join(root, 'tv-tizen/platform.js'), 'utf8');
  // Kabuk (shell.js) her TV'de ilk çalışan sayfa betiğidir: en eski tarayıcıya (Tizen 2.3, webOS 3 / Chrome 38) göre.
  const shell = fs.readFileSync(path.join(root, 'tv-webos/shell.js'), 'utf8');
  for (const [name, code] of [['app.js', app], ['tv-tizen/platform.js', platform], ['shell.js', shell]]) {
    for (const api of ['fetch(', 'Object.assign(', '.includes(', '.startsWith(', '.endsWith(', 'new Map(', 'new Set(',
      'Symbol(', 'new URL(', 'URLSearchParams', 'requestAnimationFrame(', '.classList']) {
      assert.ok(code.indexOf(api) < 0, name + ': ' + api);
    }
  }
  // Android 8'in WebView'i (Chrome 58; Play'den güncellenmeyen Philips/TPM171E gibi TV'lerde öyle kalır): Chrome 59 ve
  // sonrasında gelen API'ler sayfada ve Android TV platform betiğinde kullanılmaz. Çalışırken de denenir:
  // scripts/tv-live-page.js bunları silinmiş ortamda sayfayı gerçek sunucuya bağlar (TvPageEndToEndTests, tv-live-stale).
  const android = fs.readFileSync(path.join(root, 'tv-android/platform.js'), 'utf8');
  const i18n = fs.readFileSync(path.join(root, 'tv-webos/i18n.js'), 'utf8');
  for (const [name, code] of [['app.js', app], ['tv-android/platform.js', android], ['i18n.js', i18n], ['shell.js', shell]]) {
    for (const api of ['.flat(', '.flatMap(', 'Object.fromEntries', '.trimStart(', '.trimEnd(', '.finally(', 'globalThis',
      '.replaceAll(', '.matchAll(', 'ResizeObserver', 'AbortController', 'structuredClone', 'queueMicrotask',
      'Promise.allSettled', 'Promise.any', '.at(-']) {
      assert.ok(code.indexOf(api) < 0, name + ' (Android 8 WebView): ' + api);
    }
  }
  // Chrome 58'in tanımadığı CSS: tanınmayan kural yok sayılır, altyazı kutusu yanlış yere ya da görünmez çizilir.
  const css = fs.readFileSync(path.join(root, 'tv-webos/style.css'), 'utf8');
  for (const rule of ['clamp(', 'min(', 'max(', 'inset:', ':is(', ':where(', 'aspect-ratio', 'env(', ':focus-visible',
    'backdrop-filter', ':has(', '@container', 'dvh', 'color-mix(']) {
    assert.ok(css.indexOf(rule) < 0, 'style.css (Android 8 WebView): ' + rule);
  }
  // LG webOS 4.x (2018, ör. 55SK8500, #643): tarayıcı Chrome 53 ("cr53" tanıda). Chrome 54-58'de gelen API ve CSS LG
  // paketinde (app.js, i18n.js, tv-webos/platform.js, style.css) kullanılmaz.
  const webos = fs.readFileSync(path.join(root, 'tv-webos/platform.js'), 'utf8');
  for (const [name, code] of [['app.js', app], ['i18n.js', i18n], ['tv-webos/platform.js', webos], ['shell.js', shell]]) {
    for (const api of ['Object.values(', 'Object.entries(', 'Object.getOwnPropertyDescriptors', '.padStart(', '.padEnd(',
      '.append(', '.prepend(', '.replaceWith(', '.before(', '.after(', 'async function', 'await ', 'once: true',
      '.toggleAttribute(', '.getRootNode(']) {
      assert.ok(code.indexOf(api) < 0, name + ' (webOS 4, Chrome 53): ' + api);
    }
  }
  for (const rule of ['display: grid', 'display:grid', 'position: sticky', 'caret-color', 'font-display']) {
    assert.ok(css.indexOf(rule) < 0, 'style.css (webOS 4, Chrome 53): ' + rule);
  }
  // Array.from yalnız varlık denetimiyle.
  assert.ok(!/[^?]\s*Array\.from\(/.test(app.replace(/Array\.from \? Array\.from\(/g, '')), 'Array.from korumasız');
});
