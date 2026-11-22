// SPDX-License-Identifier: AGPL-3.0-only
// Eski TV uygulaması yeni bilgisayar/telefon sürümüyle: "TV'de test et" yazısı TV'de görünüyor, oyun altyazıları hiç
// görünmüyordu (Sinan Bey'in LG'si, anahtarsız geçiş bağlantısı, TV < 0.9.34). Eski TV sayfaları git geçmişinden
// çıkarılır (git archive) ve bugünkü sunucunun olaylarıyla (scripts/tv-live-page.js, gerçek ağ) çalıştırılır.
//
// Kanıt (bu test):
// - `subtitle` olayının bugünkü alanları (text, duration, box, at, replace, speakers) eski sayfalarda da yazıyı gösterir;
//   olay biçimi ve anahtar/imza farkı yok (anahtarsız bağlantıya da aynı olaylar gider).
// - 0.9.7'den önceki TV uygulamaları `clear` gelir gelmez satırı kaldırır. Oyundaki satır ekrandan ~1 sn'de kalkınca
//   (günlükte "kalktı: bölge boş okundu") çevirisi TV'de yalnız bir an görünür; deneme yazısı 8 sn ve `clear`sız olduğu
//   için görünür. Sunucu sürüm bildirmeyen bağlantılara `clear`ı satırın en az görünme süresi dolunca gönderir
//   (SubtitleServer.legacyClearHold: Mac/iPhone, Windows, Android aynı); bu testteki sunucu aynı kuralı uygular.
// - 0.9.19'dan önceki TV uygulamaları `region` olayını (ek alan, otomatik ekran yazısı, oyun telefonu) hiç tanımaz;
//   0.9.19-0.9.33 tanır. Sunucu bu iki grubu ayıramaz (ikisi de anahtarsız, sürümsüz bağlanır); `region` düz altyazı
//   olarak da gönderilseydi 0.9.19+ iki kez gösterirdi. Bu sürümlere çözüm sessiz güncellemedir (AppModel.tvAppReported).
//
// Git geçmişi yoksa (sığ klon) test atlanır. Çalıştırma: node --test scripts/tv-legacy-app.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { startPage } = require('./tv-live-page');

const repo = path.join(__dirname, '..');
// Sürüm → o sürümü getiren commit (tv-webos/appinfo.json).
const VERSIONS = { '0.9.3': '8f3d40ca', '0.9.16': '85c53178', '0.9.33': '00e39eb3' };

function extract(version) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-tv-' + version + '-'));
  try {
    const tar = execFileSync('git', ['-C', repo, 'archive', VERSIONS[version], 'tv-webos', 'tv-android/platform.js'],
      { stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 << 20 });
    execFileSync('tar', ['-x', '-C', dir], { input: tar });
    const info = JSON.parse(fs.readFileSync(path.join(dir, 'tv-webos/appinfo.json'), 'utf8'));
    assert.equal(info.version, version);
    return dir;
  } catch (error) {
    fs.rmSync(dir, { recursive: true, force: true });
    return null;
  }
}

const KEY = 'abcdefghijklmnopqrstuv';
const HOLD_MAX_MS = 5000;
const legacyClearHold = (text) => Math.min(HOLD_MAX_MS, 2000 + 60 * text.length);

// Bugünkü sunucunun TV'ye giden olayları; sürüm bildirmeyen (v'siz) bağlantılara `clear` tutularak gider.
function couchsubs({ holdLegacyClear }) {
  const streams = [];
  let holdUntil = 0;
  let generation = 0;
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/hello') return res.end(JSON.stringify({ app: 'couchsubs', auth: 1, id: 'legacy-test', tvs: streams.length, live: 1 }));
    // Bugünkü TV uygulaması kayıtlı anahtarını doğrulatır.
    if (url.pathname === '/pair') return res.end(JSON.stringify({ state: url.searchParams.get('k') === KEY ? 'valid' : 'expired' }));
    // Anahtarsız geçiş (SubtitleAccess.allowLegacyClients): eski TV anahtarsız bağlanır.
    if (url.pathname === '/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8' });
      res.write('retry: 2000\n\n');
      const stream = { res, legacy: !url.searchParams.get('v') };
      streams.push(stream);
      req.on('close', () => streams.splice(streams.indexOf(stream), 1));
      return undefined;
    }
    res.statusCode = 404;
    return res.end();
  });
  const frame = (event, data) => 'event: ' + event + '\ndata: ' + JSON.stringify(data) + '\n\n';
  const send = (event, data, only) => { for (const s of streams) if (!only || only(s)) s.res.write(frame(event, data)); };
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    address: 'http://127.0.0.1:' + server.address().port,
    tvs: () => streams.length,
    style() {
      send('style', { background: 90, backgroundShape: 'fit', bold: false, bottomPercent: 7, displayMode: 'inApp', fontSize: 46,
        placement: 'cover', setApart: true, stackPrevious: true, textColor: 'white' });
    },
    subtitle(data) {
      generation++;
      holdUntil = Date.now() + legacyClearHold(data.text);
      send('subtitle', Object.assign({ at: Date.now() }, data));
    },
    clear() {
      const wait = holdUntil - Date.now();
      if (!holdLegacyClear || wait <= 0) return send('clear', {});
      send('clear', {}, (s) => !s.legacy);
      const mine = generation;
      setTimeout(() => { if (mine === generation) send('clear', {}, (s) => s.legacy); }, wait);
      return undefined;
    },
    region(data) { send('region', data); },
    close() { for (const s of streams) s.res.destroy(); server.close(); }
  })));
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(condition, what, ms = 5000) {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(what + ' zamanında olmadı');
    await wait(20);
  }
}

async function withPage(version, holdLegacyClear, body) {
  const root = version === 'current' ? undefined : extract(version);
  if (root === null) return 'skip';
  const server = await couchsubs({ holdLegacyClear });
  const page = startPage({ root, params: { server: server.address, key: KEY }, port: 2 });
  try {
    await until(() => server.tvs() === 1, version + ' bağlanması');
    server.style();
    await body(server, page);
  } finally {
    page.close();
    server.close();
    if (root) fs.rmSync(root, { recursive: true, force: true });
  }
  return 'ok';
}

const GAME_LINE = { box: { bottom: 0.9, left: 0.25, right: 0.75, top: 0.85 }, duration: 3600, replace: true,
  speakers: [{ name: 'JASON', color: '#e6b422' }], text: 'JASON: Tamam. Sanırım bunu yapıyoruz.' };

for (const version of Object.keys(VERSIONS)) {
  test(version + ': bugünkü subtitle olayı (box, at, replace, speakers) eski TV sayfasında görünür', async (t) => {
    const result = await withPage(version, true, async (server, page) => {
      server.subtitle({ box: { bottom: 0.82, left: 0.3, right: 0.7, top: 0.75 }, duration: 8000, text: 'Bu bir deneme altyazısı.' });
      await until(() => page.shown() === 'Bu bir deneme altyazısı.', 'deneme yazısı');
      server.subtitle(GAME_LINE);
      await until(() => page.shown() === GAME_LINE.text, 'oyun satırı');
    });
    if (result === 'skip') t.skip('git geçmişi yok (sığ klon)');
  });
}

test('0.9.3: clear hemen giderse oyun satırı bir an görünüp kalkar (deneme yazısı clear almadığı için görünür)', async (t) => {
  const result = await withPage('0.9.3', false, async (server, page) => {
    server.subtitle(GAME_LINE);
    await until(() => page.shown() === GAME_LINE.text, 'oyun satırı');
    // Oyundaki satır ekrandan kalktı (günlükte "kalktı: bölge boş okundu, ekran temizlendi").
    server.clear();
    await wait(150);
    assert.equal(page.shown(), '', 'eski TV clear gelince satırı hemen kaldırır');
  });
  if (result === 'skip') t.skip('git geçmişi yok (sığ klon)');
});

test('0.9.3: sunucu clear\'ı tutunca oyun satırı okunacak kadar kalır; arada gelen satırın clear\'ı da tutulur', async (t) => {
  const result = await withPage('0.9.3', true, async (server, page) => {
    server.subtitle(GAME_LINE);
    await until(() => page.shown() === GAME_LINE.text, 'oyun satırı');
    server.clear();
    await wait(1500);
    assert.equal(page.shown(), GAME_LINE.text, '1,5 sn sonra satır hâlâ ekranda');
    await until(() => page.shown() === '', 'tutma süresinden sonra kalkma', legacyClearHold(GAME_LINE.text) + 1500);
    // Satır kalkmadan yeni satır: önceki satırın bekleyen clear'ı yeni satırı silmez.
    server.subtitle({ duration: 3000, text: 'Birinci' });
    server.clear();
    await wait(300);
    server.subtitle({ duration: 3000, text: 'İkinci satır' });
    server.clear();
    await wait(legacyClearHold('Birinci') - 200);
    assert.equal(page.shown(), 'İkinci satır', 'birincinin clear\'ı ikinciyi kaldırmadı');
  });
  if (result === 'skip') t.skip('git geçmişi yok (sığ klon)');
});

const REGION = { id: 'screen-text', text: 'Teçhizatını açmak için basılı tut', line: 0.03,
  box: { left: 0.05, top: 0.1, right: 0.3, bottom: 0.14 } };
const regionText = (page) => JSON.stringify(page.element('regions').children.map((c) => c.textContent || '').concat(
  ...page.element('regions').children.map((c) => (c.children || []).map((d) => d.textContent || ''))));

test('0.9.16 region olayını tanımaz; 0.9.33 ve bugünkü TV uygulaması gösterir', async (t) => {
  let skipped = false;
  for (const [version, shows] of [['0.9.16', false], ['0.9.33', true], ['current', true]]) {
    const result = await withPage(version, true, async (server, page) => {
      server.region(REGION);
      await wait(300);
      assert.equal(regionText(page).includes(REGION.text), shows, version);
    });
    if (result === 'skip') skipped = true;
  }
  if (skipped) t.skip('git geçmişi yok (sığ klon)');
});
