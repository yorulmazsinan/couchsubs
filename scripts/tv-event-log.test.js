// SPDX-License-Identifier: AGPL-3.0-only
// TV olay günlüğü (TV uygulaması 0.9.116): "son TV güncellemesinden sonra ekran sürekli göz kırpıyor, gidip geliyor"
// (beta.102-104) bildirimlerinde nedeni yalnız panelin fotoğrafından okuyorduk. Görüntüyü karartabilen her olay (HDMI'nin
// yeniden kurulması/açılması, sayfanın yenilenmesi, uygulamanın yeniden açılması, Android TV'de kapanma isteği) nedeniyle
// birlikte bilgisayarın/telefonun günlüğüne gider: GET /tvlog?m=<satır>&a=<kaç sn önce>. Aynı türden satır 15 sn'de bir,
// 10 dakikada en çok 20 satır; gönderilemeyen satır sayfa yenilense de bekler; eski bilgisayar (404) satırı atar.
// Android TV sayfası (scripts/tv-live-page.js) gerçek ağla sahte bir CouchSubs sunucusuna karşı çalışır.
// Çalıştırma: node --test scripts/tv-event-log.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { startPage } = require('./tv-live-page');

const ID = '0f8e7d6c-1111-2222-3333-444455556677';
const KEY = 'abcdefghijklmnopqrstuv';

function couchsubs({ legacy = false } = {}) {
  const lines = [];
  const streams = [];
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/hello') return res.end(JSON.stringify({ app: 'couchsubs', auth: 1, id: ID, tvs: streams.length }));
    if (url.pathname === '/pair' && url.searchParams.get('validate') === '1') {
      return res.end(JSON.stringify({ state: url.searchParams.get('k') === KEY ? 'valid' : 'expired' }));
    }
    if (url.pathname === '/tvlog' && url.searchParams.get('k') === KEY) {
      lines.push({ m: url.searchParams.get('m'), a: Number(url.searchParams.get('a')) });
      res.statusCode = legacy ? 404 : 204;
      return res.end();
    }
    if (url.pathname === '/events' && url.searchParams.get('k') === KEY) {
      res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8' });
      res.write('retry: 2000\n\n');
      streams.push(res);
      req.on('close', () => streams.splice(streams.indexOf(res), 1));
      return undefined;
    }
    res.statusCode = 404;
    return res.end();
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    address: 'http://127.0.0.1:' + server.address().port,
    lines,
    close() { for (const res of streams) res.destroy(); server.close(); }
  })));
}

async function until(condition, what, ms = 5000) {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(what + ' zamanında olmadı');
    await new Promise((r) => setTimeout(r, 20));
  }
}

function pageFor(address, extra = {}) {
  const keys = {};
  keys[address] = KEY;
  const identities = {};
  identities[ID] = KEY;
  return startPage(Object.assign({
    params: null, android8: true, port: 2,
    storage: Object.assign({ 'couchsubs.server': address, 'couchsubs.keys': JSON.stringify(keys),
      'couchsubs.server-identities': JSON.stringify(identities) }, extra.storage || {})
  }, extra.options || {}));
}

test('TV olayları nedeniyle bilgisayarın günlüğüne gider; aynı tür 15 sn\'de bir, atlananlar sayılır', async () => {
  const server = await couchsubs();
  // Uygulama tarafının satırları (MainActivity): sayfa açılmadan önce yazılmış kapanma isteği de gider.
  const events = ['exit intent (keeper, running) (12s ago)', 'activity start (launch with address)'];
  const page = pageFor(server.address, { options: { events } });
  try {
    await until(() => page.status() === 'bağlı', 'bağlanma');
    await until(() => server.lines.length >= 2, 'uygulamanın satırları', 15000);
    assert.equal(server.lines[0].m, 'exit intent (keeper, running) (12s ago)');
    assert.equal(server.lines[1].m, 'activity start (launch with address)');
    // HDMI döngüde yeniden kuruluyor: yalnız ilki hemen gider, gerisi sayılır.
    for (let i = 0; i < 10; i++) page.tvLog('hdmi rebuild (ev stalled blind ' + (60 + i) + 's #' + (i + 1) + ')');
    page.tvLog('page reload (stale 0.9.116>0.9.115)');
    await until(() => server.lines.length >= 4, 'yeni satırlar');
    await new Promise((r) => setTimeout(r, 300));
    const sent = server.lines.slice(2).map((l) => l.m);
    assert.deepEqual(sent, ['hdmi rebuild (ev stalled blind 60s #1)', 'page reload (stale 0.9.116>0.9.115)']);
    // Panelin tanı satırında da son olay görünür.
    assert.match(page.diag(), / · tv page reload \(stale 0\.9\.116>0\.9\.115\)/);
    assert.equal(page.stored('tvlog'), '[]', 'gönderilen satır bekleyenlerden silindi');
  } finally {
    page.close();
    server.close();
  }
});

test('bağlantı yokken yazılan satır sayfa yeniden açılınca gider; denetim karakteri ve uzun satır kırpılır', async () => {
  const server = await couchsubs();
  const pending = JSON.stringify([{ t: Date.now() - 42000, m: 'relaunch (webOS, rl 3)' }]);
  const page = pageFor(server.address, { storage: { 'couchsubs.tvlog': pending } });
  try {
    await until(() => server.lines.length >= 1, 'bekleyen satır');
    assert.equal(server.lines[0].m, 'relaunch (webOS, rl 3)');
    assert.ok(server.lines[0].a >= 41 && server.lines[0].a <= 60, 'satırın yaşı: ' + server.lines[0].a);
    page.tvLog('hdmi open 2\n(start)\u0000' + 'x'.repeat(400));
    await until(() => server.lines.length >= 2, 'kırpılan satır');
    assert.equal(server.lines[1].m.length, 160);
    assert.match(server.lines[1].m, /^hdmi open 2 \(start\) x+$/);
  } finally {
    page.close();
    server.close();
  }
});

test('eski bilgisayar /tvlog\'u tanımazsa (404) satır atılır, yeniden denenmez; bağlantı etkilenmez', async () => {
  const server = await couchsubs({ legacy: true });
  const page = pageFor(server.address);
  try {
    await until(() => page.status() === 'bağlı', 'bağlanma');
    page.tvLog('hdmi rebuild (resume blk #1)');
    await until(() => server.lines.length >= 1, 'satır');
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(server.lines.length, 1);
    assert.equal(page.stored('tvlog'), '[]');
    assert.equal(page.status(), 'bağlı');
    assert.doesNotMatch(page.diag(), / err /);
  } finally {
    page.close();
    server.close();
  }
});
