// SPDX-License-Identifier: AGPL-3.0-only
// Konuşana göre renkli altyazı: TV uygulaması (tv-webos/app.js; Samsung ve Android TV de bunu kullanır) ve OBS katmanı.
// node --test scripts/tv-speakers.test.js — tarayıcı gerekmez.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const sources = {
  tv: path.join(__dirname, '..', 'tv-webos', 'app.js'),
  obs: path.join(__dirname, '..', 'core', 'Sources', 'CouchSubsCore', 'Resources', 'obs-overlay.html'),
};

// En küçük sahte DOM: paintSpeakers yalnız metin düğümü ve span ekler.
function fakeDocument() {
  return {
    createTextNode: text => ({ text, color: null }),
    createElement: () => ({ style: {}, set textContent(value) { this.text = value; } }),
  };
}

function load(file) {
  const source = fs.readFileSync(file, 'utf8');
  const start = source.indexOf('  function speakerMap(list)');
  const end = source.indexOf('  function paintSpeakers(');
  const close = source.indexOf('\n  }\n', end) + 4;
  assert.ok(start > 0 && end > start && close > end, 'konuşan rengi işlevleri bulunamadı');
  const context = { document: fakeDocument() };
  vm.runInNewContext(source.slice(start, close) + '\nthis.api = { speakerMap, speakerSegments, paintSpeakers };', context);
  return context.api;
}

function element() {
  return {
    children: [],
    set textContent(value) { this.children = value ? [{ text: value, color: null }] : []; },
    appendChild(node) { this.children.push({ text: node.text, color: node.style ? node.style.color : null }); },
  };
}

for (const [name, file] of Object.entries(sources)) {
  const api = load(file);

  test(`${name}: geçersiz renk ve ad atlanır, alan yoksa renk yok`, () => {
    assert.equal(api.speakerMap(undefined), null);
    assert.equal(api.speakerMap('x'), null);
    const map = api.speakerMap([{ name: 'Mattia', color: '#90CAF9' }, { name: 'Kötü', color: 'red' },
      { name: '', color: '#FFFFFF' }, { name: 'Lucia', color: 'url(x)' }]);
    assert.deepEqual(JSON.parse(JSON.stringify(map)), { Mattia: '#90CAF9' });
    assert.deepEqual(JSON.parse(JSON.stringify(api.speakerSegments('Mattia: Selam.', null))), [{ text: 'Mattia: Selam.', color: null }]);
  });

  test(`${name}: ad ve cümlesi o konuşanın renginde, bölünmüş satırda renk sürer`, () => {
    const map = api.speakerMap([{ name: 'Mattia', color: '#90CAF9' }, { name: 'Lucia', color: '#F06292' }]);
    const segments = api.speakerSegments('Mattia: Bu işi bugün\nbitirmeliyiz.\nLucia: Tamam.', map);
    assert.deepEqual(JSON.parse(JSON.stringify(segments)), [
      { text: 'Mattia: Bu işi bugün\nbitirmeliyiz.\n', color: '#90CAF9' },
      { text: 'Lucia: Tamam.', color: '#F06292' },
    ]);
  });

  test(`${name}: ad yalnız satır başında aranır, adsız baş renksiz kalır`, () => {
    const map = api.speakerMap([{ name: 'ARTHUR', color: '#FFD54F' }]);
    const segments = api.speakerSegments('Dikkat et.\nARTHUR : Gidelim.\nSonra ARTHUR: değil', map);
    assert.deepEqual(JSON.parse(JSON.stringify(segments)), [
      { text: 'Dikkat et.\n', color: null },
      { text: 'ARTHUR : Gidelim.\nSonra ARTHUR: değil', color: '#FFD54F' },
    ]);
    assert.deepEqual(JSON.parse(JSON.stringify(api.speakerSegments('ARTHURO: Merhaba', map))),
      [{ text: 'ARTHURO: Merhaba', color: null }]);
  });

  test(`${name}: renkli parça span olarak yazılır, renksiz metne dokunulmaz`, () => {
    const map = api.speakerMap([{ name: 'Dutch', color: '#81C784' }]);
    const colored = element();
    colored.textContent = 'Dutch： Sakin ol.';
    api.paintSpeakers(colored, 'Dutch： Sakin ol.', map);
    assert.deepEqual(colored.children, [{ text: 'Dutch： Sakin ol.', color: '#81C784' }]);
    const plain = element();
    plain.textContent = 'Sakin ol.';
    api.paintSpeakers(plain, 'Sakin ol.', map);
    assert.deepEqual(plain.children, [{ text: 'Sakin ol.', color: null }]);
  });
}

// Yeni arayüz (style.nameOnly): konuşan rengi yalnız adı boyar, cümle yazı renginde kalır. Alan yoksa eski davranış.
test('tv: nameOnly açıkken yalnız ad renkli', () => {
  const source = fs.readFileSync(sources.tv, 'utf8');
  const start = source.indexOf('  function speakerMap(list)');
  const end = source.indexOf('  function paintSpeakers(');
  const close = source.indexOf('\n  }\n', end) + 4;
  const context = { document: fakeDocument() };
  vm.runInNewContext(source.slice(start, close) + '\nthis.api = { speakerMap, paintSpeakers };', context);
  context.speakerNameOnly = true;
  const map = context.api.speakerMap([{ name: 'Jason', color: '#4FD1C5' }]);
  const el = element();
  el.textContent = 'Jason: Tamam. Gidelim.';
  context.api.paintSpeakers(el, 'Jason: Tamam. Gidelim.', map);
  assert.deepEqual(el.children, [{ text: 'Jason:', color: '#4FD1C5' }, { text: ' Tamam. Gidelim.', color: null }]);
});
