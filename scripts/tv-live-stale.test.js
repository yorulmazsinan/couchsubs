// SPDX-License-Identifier: AGPL-3.0-only
// "TV'de bağlı, panelde sub 0; silip yükleyince düzeldi" (X @conmeyz, Philips 55PUS7303, Android 8). Android TV sayfası
// (scripts/tv-live-page.js, Android 8 WebView'ine göre kısıtlı) gerçek ağla iki CouchSubs sunucusuna karşı çalıştırılır:
// eski kurulumdan kalan kayıtlı adres (aynı bilgisayarın eski portu: aynı kimlik ve anahtar) hâlâ yanıt veriyor, çeviri ise
// yeni porttaki sunucuda. Sayfa eski adrese "bağlı" kalır, altyazı hiç gelmez. Bilgisayar/telefon çalışan uygulamaya
// adresini bildirince (AddressReceiver yayını, app.js applyParams) sayfa yeni adrese geçer ve altyazı gelir.
// Çalıştırma: node --test scripts/tv-live-stale.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { startPage } = require('./tv-live-page');

const ID = '0f8e7d6c-1111-2222-3333-444455556666';
const KEY = 'abcdefghijklmnopqrstuv';

// CouchSubs sunucusunun TV'nin kullandığı uçları: /hello, /pair?validate=1, /events?k=... (anahtar denetimli).
function couchsubs() {
  const streams = [];
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/hello') return res.end(JSON.stringify({ app: 'couchsubs', auth: 1, id: ID, tvs: streams.length }));
    if (url.pathname === '/pair' && url.searchParams.get('validate') === '1') {
      return res.end(JSON.stringify({ state: url.searchParams.get('k') === KEY ? 'valid' : 'expired' }));
    }
    if (url.pathname === '/events' && url.searchParams.get('k') === KEY) {
      res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8' });
      res.write('retry: 2000\n\n');
      streams.push(res);
      req.on('close', () => streams.splice(streams.indexOf(res), 1));
      return undefined;
    }
    res.statusCode = url.pathname === '/events' ? 401 : 404;
    return res.end();
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    address: 'http://127.0.0.1:' + server.address().port,
    tvs: () => streams.length,
    subtitle(text) {
      for (const res of streams) res.write('event: subtitle\ndata: ' + JSON.stringify({ text, duration: 4000 }) + '\n\n');
    },
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

test('kayıtlı eski adrese bağlı kalan TV altyazı almaz; adres bildirilince yeni sunucuya geçer', async () => {
  const stale = await couchsubs();
  const live = await couchsubs();
  // Eski kurulumun kalıntısı: kayıtlı adres, o adresin anahtarı ve kimliği.
  const keys = {};
  keys[stale.address] = KEY;
  const identities = {};
  identities[ID] = KEY;
  const page = startPage({
    params: null, android8: true, port: 2,
    storage: { 'couchsubs.server': stale.address, 'couchsubs.keys': JSON.stringify(keys),
      'couchsubs.server-identities': JSON.stringify(identities) }
  });
  try {
    await until(() => page.status() === 'bağlı' && stale.tvs() === 1, 'eski adrese bağlanma');
    // Belirti: TV "bağlı", çeviri yeni sunucuda, panelde sub 0.
    live.subtitle('Bu TV\'ye ulaşmıyor');
    await new Promise((r) => setTimeout(r, 300));
    assert.match(page.diag(), /^sub 0 /);
    assert.equal(live.tvs(), 0);

    // Bilgisayar çalışan uygulamaya adresini bildirir (anahtarsız: kimlik aynı, kayıtlı anahtar kullanılır).
    page.relaunch({ server: live.address });
    await until(() => live.tvs() === 1, 'yeni adrese geçme');
    await until(() => page.status() === 'bağlı', 'yeniden bağlı');
    assert.equal(page.stored('server'), live.address);
    live.subtitle('Merhaba, şimdi geliyor');
    await until(() => page.shown() === 'Merhaba, şimdi geliyor', 'altyazının çizilmesi');
    assert.match(page.diag(), /^sub 1 /);
    assert.doesNotMatch(page.diag(), / err /);
    await until(() => stale.tvs() === 0, 'eski bağlantının kapanması');
  } finally {
    page.close();
    stale.close();
    live.close();
  }
});
