// SPDX-License-Identifier: AGPL-3.0-only
// TV'nin alındısı: LG + iPhone'da 20-25 dk sonra telefon "Bağlı" diyor ama altyazı TV'ye gelmiyordu (TV uygulaması
// askıya alınmış, soket açık). Yeni bilgisayar/telefon akışı `link` olayıyla kimliğini bildirir; TV her ping'de
// /ack?c=<kimlik> gönderir (alındı kesilirse bilgisayar/telefon bağlantıyı kapatıp yeniden bağlanır). Bilgisayar/telefon
// kimliği tanımazsa (404) TV beklemeden yeniden bağlanır. `link` göndermeyen eski sürüme alındı gitmez.
// Android TV sayfası (scripts/tv-live-page.js) gerçek ağla sahte bir CouchSubs sunucusuna karşı çalışır.
// Çalıştırma: node --test scripts/tv-ack.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { startPage } = require('./tv-live-page');

const ID = '0f8e7d6c-1111-2222-3333-444455556677';
const KEY = 'abcdefghijklmnopqrstuv';

function couchsubs({ link }) {
  const streams = [];
  const acks = [];
  let opened = 0;
  let known = new Set();
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/hello') return res.end(JSON.stringify({ app: 'couchsubs', auth: 1, id: ID, tvs: streams.length }));
    if (url.pathname === '/pair' && url.searchParams.get('validate') === '1') {
      return res.end(JSON.stringify({ state: url.searchParams.get('k') === KEY ? 'valid' : 'expired' }));
    }
    if (url.pathname === '/ack' && url.searchParams.get('k') === KEY) {
      acks.push(url.searchParams.get('c'));
      res.statusCode = known.has(url.searchParams.get('c')) ? 204 : 404;
      return res.end();
    }
    if (url.pathname === '/events' && url.searchParams.get('k') === KEY) {
      opened++;
      res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8' });
      res.write('retry: 2000\n\n');
      if (link) {
        const id = 'link' + opened;
        known.add(id);
        res.write('event: link\ndata: ' + JSON.stringify({ id }) + '\n\n');
      }
      streams.push(res);
      req.on('close', () => streams.splice(streams.indexOf(res), 1));
      return undefined;
    }
    res.statusCode = 404;
    return res.end();
  });
  const pings = setInterval(() => { for (const res of streams) res.write(': ping\n\nevent: ping\ndata: {}\n\n'); }, 100);
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    address: 'http://127.0.0.1:' + server.address().port,
    acks,
    opened: () => opened,
    forget() { known = new Set(); },
    close() { clearInterval(pings); for (const res of streams) res.destroy(); server.close(); }
  })));
}

async function until(condition, what, ms = 5000) {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(what + ' zamanında olmadı');
    await new Promise((r) => setTimeout(r, 20));
  }
}

function pageFor(address) {
  const keys = {};
  keys[address] = KEY;
  const identities = {};
  identities[ID] = KEY;
  return startPage({
    params: null, android8: true, port: 2,
    storage: { 'couchsubs.server': address, 'couchsubs.keys': JSON.stringify(keys),
      'couchsubs.server-identities': JSON.stringify(identities) }
  });
}

test('TV her ping\'de alındı gönderir; bilgisayar akışı tanımazsa hemen yeniden bağlanır', async () => {
  const server = await couchsubs({ link: true });
  const page = pageFor(server.address);
  try {
    await until(() => page.status() === 'bağlı' && server.opened() === 1, 'bağlanma');
    await until(() => server.acks.filter((c) => c === 'link1').length >= 3, 'alındılar');
    // Bilgisayar/telefon bağlantıyı kopmuş saydı (ya da yeniden açıldı): alındıya 404.
    server.forget();
    await until(() => server.opened() === 2, 'yeniden bağlanma', 3000);
    await until(() => server.acks.includes('link2'), 'yeni akışın alındısı');
    assert.doesNotMatch(page.diag(), / err /);
  } finally {
    page.close();
    server.close();
  }
});

test('link göndermeyen eski bilgisayar/telefon sürümüne alındı gitmez', async () => {
  const server = await couchsubs({ link: false });
  const page = pageFor(server.address);
  try {
    await until(() => page.status() === 'bağlı', 'bağlanma');
    await new Promise((r) => setTimeout(r, 500));
    assert.equal(server.acks.length, 0);
    assert.equal(server.opened(), 1);
  } finally {
    page.close();
    server.close();
  }
});
