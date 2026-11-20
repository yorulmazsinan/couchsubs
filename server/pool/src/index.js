// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs subtitle pool (Cloudflare Worker + D1).
// POST /v1/lines   : uygulamalar paketlerde bulunmayan İngilizce satırları gönderir. Satırda isteğe bağlı olarak
//                    PS5'te o an çalışan oyunun kimliği (titleId, ör. "PPSA01234") ve adı (game) gelir. Kimlik
//                    yoksa ad uygulamanın paketten tanıdığı ya da kullanıcının seçtiği oyundur; kurulum başına bir
//                    "oy" (game_votes) yazılır, gece paketi en az iki kurulumun bildirdiği adla açılır.
//                    Üçüncü taraf uygulamalar X-CouchSubs-App-Key başlığıyla gönderir (APP_KEYS, aşağıda).
// GET  /v1/export  : (yönetici) en az N kurulumun gördüğü, henüz çevrilmemiş satırlar; `title=` ya da `game=` ile
//                    yalnız bir oyunun satırları.
// POST /v1/exported: (yönetici) çeviriye alınan anahtarları işaretler.
// GET  /v1/stats   : herkese açık sayılar.
// Cron (gece 03:07–04:57 UTC): havuzdan kendiliğinden oyun paketi (src/autopack.js).

import { accepts } from "./filter.js";
import { runAutopack } from "./autopack.js";
import { EXTRA_SUFFIX, gameKey } from "./games.js";

const MAX_LINES = 200;
const DAILY_LIMIT = 5000;
// D1 ücretsiz planda çağrı başına sorgu sınırı var; her deneme 2 sorgu. Yoğun çakışmada 503 busy dön, sorgu sınırına takılıp 500 verme.
const QUOTA_CAS_ATTEMPTS = 8;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TAG = /<[^<>]{0,40}>/g;
// PS5 oyun kimliği: dört harf, beş rakam, isteğe bağlı "_00" eki (PPSA01234, CUSA00419_00).
const TITLE_ID = /^[A-Z]{4}\d{5}(_\d{2})?$/;
const MAX_GAME = 120;

/** Geçerli PS5 oyun kimliği (büyük harfe çevrilmiş) ya da null. */
export function titleId(value) {
  const t = String(value ?? "").trim().toUpperCase();
  return TITLE_ID.test(t) ? t : null;
}

/** Oyun adı: denetim karakterleri ve fazla boşluk atılır, en çok 120 karakter; boşsa null. Ek paketin adındaki
 *  " (ek satırlar)" (paketten tanınan oyun bu adla gelir) atılır: satırlar asıl oyunun adıyla toplanır. */
export function gameName(value) {
  if (typeof value !== "string") return null;
  let t = value.replace(/\p{C}/gu, " ").replace(/\s+/g, " ").trim();
  const extra = EXTRA_SUFFIX.trim();
  if (t.endsWith(extra)) t = t.slice(0, -extra.length).trim();
  t = t.slice(0, MAX_GAME).trim();
  return t || null;
}

// Uygulamadaki anahtar işleviyle birebir aynı (core/.../GamePack, golden-vectors.json).
export function canon(s) {
  let t = s.replace(TAG, " ").normalize("NFKC").toLowerCase().normalize("NFD");
  t = t.replace(/\p{M}/gu, "").replace(/[^\p{L}\p{N}]/gu, " ");
  return t.split(/\s+/).filter(Boolean).join(" ");
}

export async function key(s) {
  const c = canon(s);
  if (!c) return "";
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(c));
  return [...new Uint8Array(d)].slice(0, 8).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const json = (body, status = 200, extra = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...extra } });

function isAdmin(req, env) {
  const h = req.headers.get("authorization") || "";
  return env.ADMIN_TOKEN && h === `Bearer ${env.ADMIN_TOKEN}`;
}

/** Gönderinin özeti: uygulama, platform, satır sayısı, oyun alanı taşıyan ve geçerli olan satırlar, kimlik biçimi
 *  ("PPSA99999" gibi; rakamlar 9 olur). Metin ve kurulum kimliği yazılmaz. */
export function submitSummary(body, lines) {
  const ids = lines.map((l) => l?.titleId).filter((v) => v != null);
  const sample = ids.length ? String(ids[0]).slice(0, 16).replace(/\d/g, "9") : null;
  return {
    pool: "lines",
    app: String(body?.app ?? "").slice(0, 40),
    platform: String(body?.platform ?? "").slice(0, 20),
    lines: lines.length,
    titleId: ids.length,
    valid: lines.filter((l) => titleId(l?.titleId)).length,
    game: lines.filter((l) => typeof l?.game === "string" && l.game.trim()).length,
    sample,
  };
}

// Kota (kurulum başına günde DAILY_LIMIT satır) D1'de tutulur, ama her istekte yazılmaz: dağıtım (isolate) D1'den
// QUOTA_BLOCK satırlık bir pay ayırır ve sonraki istekleri bellekten karşılar. D1 sayacı yine DAILY_LIMIT'i aşamaz
// (aynı CAS); bir dağıtımın kullanılmadan kalan payı en çok QUOTA_BLOCK olduğundan sınır biraz erken dolabilir,
// hiçbir zaman geç değil. Kurulumlar günde ortalama ~35 satır gönderdiği için çoğu kurulum günde bir kota yazımı yapar.
export const QUOTA_BLOCK = 200;
const MAX_QUOTA_ENTRIES = 20000;
// D1 nesnesine bağlı: her veritabanının (testlerde her sahte DB'nin) kendi payı olur.
const quotaCache = new WeakMap();

function quotaMap(env) {
  let map = quotaCache.get(env.DB);
  if (!map) quotaCache.set(env.DB, (map = new Map()));
  return map;
}

/** İstek için yer ayırır: { room } ya da { status: 429 | 503 }. `install` kurulum kimliği ya da uygulamanın
 *  toplam sayacı ("app:<ad>"); quota tablosu ikisini de tutar (şema değişmez). */
async function reserveQuota(env, install, day, wanted, limit = DAILY_LIMIT) {
  const map = quotaMap(env);
  const id = `${install}|${day}`;
  const local = map.get(id) ?? 0;
  if (local >= wanted) {
    map.set(id, local - wanted);
    return { room: wanted };
  }
  const need = wanted - local;
  for (let attempt = 0; attempt < QUOTA_CAS_ATTEMPTS; attempt++) {
    const q = await env.DB.prepare("SELECT count FROM quota WHERE install=? AND day=?").bind(install, day).first();
    const used = q?.count || 0;
    const left = limit - used;
    if (left <= 0) {
      // D1 doldu; bu dağıtımda kalan pay varsa onu ver.
      if (local > 0 || (map.get(id) ?? 0) > 0) return { room: take(map, id, wanted) };
      return { status: 429 };
    }
    const grab = Math.min(left, Math.max(need, QUOTA_BLOCK));
    const result = await env.DB.prepare(
      "INSERT INTO quota(install,day,count) VALUES(?,?,?) " +
      "ON CONFLICT(install,day) DO UPDATE SET count=count+excluded.count WHERE quota.count=?"
    ).bind(install, day, grab, used).run();
    if (result.meta?.changes > 0) {
      if (map.size >= MAX_QUOTA_ENTRIES) map.clear();
      map.set(id, (map.get(id) ?? 0) + grab);
      return { room: take(map, id, wanted) };
    }
  }
  return { status: 503 };
}

/** Ayrılmış ama kullanılmayan yer bu dağıtımın payına geri döner (D1'e yazılmaz). */
function giveBack(env, install, day, n) {
  if (n <= 0) return;
  const map = quotaMap(env);
  const id = `${install}|${day}`;
  map.set(id, (map.get(id) ?? 0) + n);
}

function take(map, id, wanted) {
  const have = map.get(id) ?? 0;
  const room = Math.min(have, wanted);
  map.set(id, have - room);
  return room;
}

/** Yazım başarısız olunca: bu dağıtımın payı ve isteğin yeri D1'e geri verilir (nadir yol). Geri verme de başarısız
 *  olursa kota tutucu kalır. */
async function releaseQuota(env, install, day, room) {
  const map = quotaMap(env);
  const id = `${install}|${day}`;
  const back = room + (map.get(id) ?? 0);
  map.delete(id);
  if (back > 0) {
    await env.DB.prepare("UPDATE quota SET count=count-? WHERE install=? AND day=? AND count>=?")
      .bind(back, install, day, back).run().catch(() => {});
  }
}

// Bu kadar kurulumun gördüğü satır doğrulanmış sayılır (paket eşiği autopack MIN_INSTALLS = 2); yeni görülmesi yazılmaz.
export const SATURATED = 3;
// D1 bir sorguda en çok 100 bağlı değişken kabul eder.
const IN_CHUNK = 90;

/** Havuzda installs>=SATURATED olan ya da çeviriye alınmış anahtarlar (yalnız okuma). */
async function settledKeys(env, keys) {
  const settled = new Set();
  for (let i = 0; i < keys.length; i += IN_CHUNK) {
    const part = keys.slice(i, i + IN_CHUNK);
    const { results } = await env.DB.prepare(
      `SELECT key FROM lines WHERE key IN (${part.map(() => "?").join(",")}) AND (installs>=? OR exported=1)`
    ).bind(...part, SATURATED).all();
    for (const r of results ?? []) settled.add(r.key);
  }
  return settled;
}

// Üçüncü taraf uygulamalar havuza `X-CouchSubs-App-Key` başlığıyla katılır. Anahtarlar Worker secret'ında:
//   APP_KEYS = {"<anahtar>": {"name": "gametranslator", "daily": 20000}}
// Secret yoksa ya da bozuksa hiçbir anahtar geçerli değildir. Kendi istemcilerimiz anahtar göndermez; gövdedeki `app`
// alanı onları tanıtır: Mac/iOS/Windows sürüm numarası ("0.1.0", "0.1.0-beta.46"), Android "CouchSubs Android 1.2.3".
// `app` sahte gönderilebilir: bu bir düzen kuralıdır, kötüye kullanıma karşı asıl sınır kurulum ve uygulama kotalarıdır.
export const APP_HEADER = "x-couchsubs-app-key";
export const APP_DAILY_DEFAULT = 20000;
const OWN_APP = /^(?:CouchSubs(?: [\p{L}\p{N} ._+-]{0,60})?|\d{1,4}(?:\.\d{1,4}){0,3}(?:[-+][0-9A-Za-z.+-]{1,40})?)$/u;
const APP_NAME = /^[a-z0-9][a-z0-9._-]{0,39}$/;

/** Gövdedeki `app` bizim istemcilerimizden biri mi. */
export function ownApp(value) {
  return typeof value === "string" && OWN_APP.test(value.trim());
}

let appKeysCache = { raw: undefined, keys: new Map() };

/** APP_KEYS secret'ı: anahtar -> { name, daily }. Geçersiz kayıtlar atlanır. */
export function appKeys(env) {
  const raw = env.APP_KEYS;
  if (raw === appKeysCache.raw) return appKeysCache.keys;
  const keys = new Map();
  try {
    const parsed = typeof raw === "string" && raw ? JSON.parse(raw) : raw && typeof raw === "object" ? raw : {};
    for (const [k, v] of Object.entries(parsed ?? {})) {
      const name = String(v?.name ?? "").trim().toLowerCase();
      const daily = Number(v?.daily ?? APP_DAILY_DEFAULT);
      if (k.length < 16 || !APP_NAME.test(name) || !Number.isSafeInteger(daily) || daily < 1) continue;
      keys.set(k, { name, daily });
    }
  } catch {
    console.error(JSON.stringify({ error: "app_keys_invalid" }));
  }
  appKeysCache = { raw, keys };
  return keys;
}

/** İsteği gönderen uygulama: { name, daily } (üçüncü taraf), { own: true } ya da { status, error }. */
export function clientOf(req, body, env) {
  const key = req.headers.get(APP_HEADER);
  if (key != null && key !== "") {
    const app = appKeys(env).get(key.trim());
    return app ?? { status: 403, error: "app_key_invalid" };
  }
  if (ownApp(body?.app)) return { own: true };
  return { status: 403, error: "app_key_required" };
}

function untilMidnight() {
  const now = new Date();
  const midnight = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  return Math.max(60, Math.ceil((midnight - now.getTime()) / 1000));
}

async function submit(req, env) {
  let body;
  try { body = await req.json(); } catch { return json({ error: "json" }, 400); }
  const install = String(body?.install || "");
  if (!UUID.test(install) || !Array.isArray(body?.lines)) return json({ error: "bad_request" }, 400);
  const client = clientOf(req, body, env);
  if (client.status) return json({ error: client.error }, client.status);
  const lines = body.lines.slice(0, MAX_LINES);
  const day = new Date().toISOString().slice(0, 10);

  // Üçüncü taraf uygulamanın günlük toplamı (kurulum sınırına ek); aynı pay düzeniyle az yazımla sayılır.
  const appId = client.name ? `app:${client.name}` : null;
  let appRoom = lines.length;
  if (appId) {
    const app = await reserveQuota(env, appId, day, lines.length, client.daily);
    if (app.status === 429) return json({ error: "app_quota" }, 429, { "retry-after": String(untilMidnight()) });
    if (app.status) return json({ error: "busy" }, app.status, { "retry-after": "1" });
    appRoom = app.room;
  }
  const quota = await reserveQuota(env, install, day, appRoom);
  if (quota.status) {
    if (appId) giveBack(env, appId, day, appRoom);
    return json({ error: quota.status === 429 ? "quota" : "busy" }, quota.status,
      { "retry-after": quota.status === 429 ? "3600" : "1" });
  }
  const room = quota.room;
  if (appId) giveBack(env, appId, day, appRoom - room);

  const fresh = new Map();
  let entries = [];
  let recorded = 0;
  try {
    // Türkçe, PS5 sistem yazısı ve yarım okumalar hiç yazılmaz (eski sürümler süzmeden gönderiyor).
    // Aynı istekteki yinelenen anahtar bir kez sayılır.
    for (const l of lines.slice(0, room)) {
      const text = String(l?.text || "").trim().replace(/\s+/g, " ");
      if (!accepts(text)) continue;
      const c = canon(text);
      if (c.split(" ").length < 2) continue;
      const k = await key(text); // istemcinin anahtarına güvenmeyiz, yeniden hesaplarız
      // Oyun bilgisi isteğe bağlıdır (eski sürümler göndermez); geçersizse yok sayılır, satır yine alınır.
      if (!fresh.has(k)) fresh.set(k, { text, title: titleId(l?.titleId), game: gameName(l?.game) });
    }
    // Günlükte (wrangler tail) yalnız sayılar ve oyun kimliğinin biçimi: oyun bilgisinin gelip gelmediği görülsün.
    console.log(JSON.stringify({ ...submitSummary(body, lines), client: client.name ?? "couchsubs" }));

    // Günlük D1 yazma kotası için: kurulumun görülme kaydı (sightings) ile en az iki kurulumun gördüğü
    // satırın havuza eklenmesi (lines) aynı transaction içinde gerçekleşir. Tek kurulumda upsert etkisizdir;
    // aynı kurulum tekrar gönderince de idempotent upsert hiçbir satırı değiştirmez.
    const now = new Date().toISOString();
    entries = [...fresh];
    // Havuzda zaten SATURATED kurulumla doğrulanmış ya da çeviriye alınmış satırın yeni görülmesi hiçbir şeyi
    // değiştirmez (paket eşiği 2); görülme (2 satır yazımı) ve installs güncellemesi (3 satır yazımı) atlanır.
    // Toplu okuma ucuzdur ve yazım kotasına girmez.
    const settled = await settledKeys(env, entries.map(([k]) => k));
    const pending = entries.filter(([k]) => !settled.has(k));
    // Görülme ve satır güncellemesini tek D1 batch transaction'ında yap: ikinci adım hata
    // verirse yalnız sightings yazılı kalmamalı (yoksa tekrar göndermek satırı kalıcı olarak kaybettirir).
    // UPSERT, distinct sightings sayısına göre idempotenttir; aynı kurulum tekrar gönderince sayıyı artırmaz.
    // Değişiklik yapmayan INSERT OR IGNORE ve koşulu tutmayan UPSERT D1'de rows_written'a girmez (yerel D1'de
    // ölçüldü), bu yüzden aynı kurulumun yinelenen gönderimi zaten yazım harcamaz.
    const writes = [
      ...pending.map(([k]) =>
        env.DB.prepare("INSERT OR IGNORE INTO sightings(key,install) VALUES(?,?)").bind(k, install)),
      ...pending.map(([k, line]) =>
        env.DB.prepare(UPSERT).bind(k, line.text, now, now, line.title, line.game, k)),
    ];
    const results = writes.length ? await env.DB.batch(writes) : [];
    recorded = results.slice(0, pending.length).filter((r) => r?.meta?.changes > 0).length;
  } catch (error) {
    // Undo the reservation if filtering, hashing, or the atomic write batch fails. A failed compensation
    // leaves quota conservative rather than risking an over-limit counter.
    await releaseQuota(env, install, day, room);
    if (appId) await releaseQuota(env, appId, day, room);
    throw error;
  }
  await vote(env, install, entries);
  return json({ accepted: fresh.size, recorded });
}

/** Kimliksiz gelen oyun adları: kurulum başına bir oy (istekte birkaç oyun olsa da en çok üç yazma). Tek kişinin
 *  yanlış seçimi paket açmasın diye autopack en az iki kurulumun oyladığı adı ayrı paket yapar. Tablo yoksa
 *  (migrate-2026-11-15-game-votes.sql çalışmadıysa) sessizce atlanır. */
async function vote(env, install, entries) {
  const keys = new Set();
  for (const [, line] of entries) {
    if (line.title || !line.game) continue;
    const k = gameKey(line.game);
    if (k) keys.add(k);
  }
  if (!keys.size) return;
  try {
    await env.DB.batch([...keys].slice(0, 3).map((k) =>
      env.DB.prepare("INSERT OR IGNORE INTO game_votes(game_key,install) VALUES(?,?)").bind(k, install)));
  } catch (e) {
    if (!/no such table/i.test(String(e?.message || e))) throw e;
  }
}

// Satırı görenlerin sayısı sightings'ten okunur (az önce yazılan görülme dahil); en az ikiyse lines'a girer ya da
// installs sayısı kesin distinct görülme sayısına eşitlenir. Tek kurulumda SELECT boş döner, yazma olmaz.
export const UPSERT =
  "INSERT INTO lines(key,text,installs,first_seen,last_seen,title_id,game) " +
  "SELECT ?,?,n,?,?,?,? FROM (SELECT COUNT(*) AS n FROM sightings WHERE key=?) WHERE n>=2 " +
  "ON CONFLICT(key) DO UPDATE SET installs=excluded.installs, last_seen=excluded.last_seen, " +
  "title_id=COALESCE(lines.title_id,excluded.title_id), game=COALESCE(lines.game,excluded.game) " +
  "WHERE lines.installs < excluded.installs";

async function exportLines(url, env) {
  const min = Number(url.searchParams.get("min") || 2);
  const requestedLimit = Number(url.searchParams.get("limit") || 5000);
  // SQLite LIMIT -1 sınırsızdır; geçersiz sayılar sorgu kotasını ve yanıt boyutunu aşmamalı.
  if (!Number.isSafeInteger(min) || min < 1 ||
      !Number.isSafeInteger(requestedLimit) || requestedLimit < 1) {
    return json({ error: "bad_request" }, 400);
  }
  const limit = Math.min(20000, requestedLimit);
  const all = url.searchParams.get("all") === "1";
  // Oyuna göre süzme yalnız geçişten sonra çalışır (title_id ve game sütunları); süzgeçsiz istek eskisi gibi.
  const title = titleId(url.searchParams.get("title"));
  const game = gameName(url.searchParams.get("game"));
  // A requested but invalid filter must not silently turn into an all-games export.
  if ((url.searchParams.has("title") && !title) || (url.searchParams.has("game") && !game)) {
    return json({ error: "bad_request" }, 400);
  }
  const where = ["installs>=?"];
  const args = [min];
  if (!all) where.push("exported=0");
  if (title) { where.push("title_id=?"); args.push(title); }
  if (game) { where.push("game LIKE ? ESCAPE '\\'"); args.push(`%${game.replace(/[\\%_]/g, "\\$&")}%`); }
  const cols = title || game ? "key,text,installs,first_seen,title_id,game" : "key,text,installs,first_seen";
  const r = await env.DB.prepare(
    `SELECT ${cols} FROM lines WHERE ${where.join(" AND ")} ORDER BY installs DESC LIMIT ?`
  ).bind(...args, limit).all();
  return json({ lines: r.results });
}

async function markExported(req, env) {
  const body = await req.json().catch(() => null);
  if (!Array.isArray(body?.keys) || !body.keys.every((k) =>
    typeof k === "string" && /^[0-9a-f]{16}$/i.test(k))) {
    return json({ error: "bad_request" }, 400);
  }
  const keys = body.keys.slice(0, 20000);
  let marked = 0;
  for (let i = 0; i < keys.length; i += 100) {
    const results = await env.DB.batch(keys.slice(i, i + 100).map((k) =>
      env.DB.prepare("UPDATE lines SET exported=1 WHERE key=? AND exported=0").bind(k.toLowerCase())));
    marked += results.reduce((sum, result) => sum + (result?.meta?.changes ?? 0), 0);
  }
  return json({ marked });
}

// Herkese açık sayılar D1'den istek başına hesaplanmaz: COUNT(DISTINCT) bütün sightings tablosunu tarar (milyonlarca
// satır; sorgu süre sınırını aşıp 503 veriyordu ve okuma kotasını yiyordu). Sayıları gece planının hemen ardından
// autopack (src/autopack.js computeStats) hesaplayıp R2'ye yazar; burası yalnız o özeti okur.
export const STATS_KEY = "auto/stats.json";
// Dağıtımın bellek önbelleği: özet günde bir değişir; hata ya da boş özet de kısa süre önbellekte durur.
let statsCache = { at: 0, ttl: 0, body: null };
export const STATS_TTL_MS = 10 * 60 * 1000;
export const STATS_ERROR_TTL_MS = 60 * 1000;
export const resetStatsCache = () => { statsCache = { at: 0, ttl: 0, body: null }; };

async function stats(env) {
  if (statsCache.body && Date.now() - statsCache.at < statsCache.ttl) return json(statsCache.body);
  let body = null;
  let ttl = STATS_TTL_MS;
  try {
    const object = await env.PACKS?.get(STATS_KEY);
    const snapshot = object ? JSON.parse(await object.text()) : null;
    if (snapshot && Number.isFinite(snapshot.lines) && Number.isFinite(snapshot.confirmed) && Number.isFinite(snapshot.installs)) {
      body = { lines: snapshot.lines, confirmed: snapshot.confirmed, installs: snapshot.installs, updated: snapshot.updated ?? null };
      if (snapshot.approx) body.approx = true;
    }
  } catch (e) {
    console.error(JSON.stringify({ error: "stats_read", message: String(e?.message || e).slice(0, 200) }));
  }
  // Özet henüz yok (ilk gece gelmedi) ya da okunamadı: önceki özet varsa o, yoksa sıfırlar; kısa süre sonra yeniden denenir.
  if (!body) { body = statsCache.body ?? { lines: 0, confirmed: 0, installs: 0, updated: null }; ttl = STATS_ERROR_TTL_MS; }
  statsCache = { at: Date.now(), ttl, body };
  return json(body);
}

// D1'in geçici hataları ve günlük sınırları: istemci sonra yeniden göndersin (503 + Retry-After). Günlük satır
// yazma/okuma sınırı UTC gece yarısı sıfırlanır; ötekiler kısa sürer.
const D1_LIMIT = /exceed|limit|quota/i;
const D1_TRANSIENT = /SQLITE_BUSY|overloaded|unavailable|timed? ?out|reset|network connection lost|internal error/i;

/** D1 hatası geçiciyse Retry-After saniyesi, değilse 0. */
export function unavailableFor(error) {
  const message = String(error?.message || error);
  if (D1_LIMIT.test(message)) return Math.min(3600, untilMidnight());
  return D1_TRANSIENT.test(message) ? 60 : 0;
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      if (req.method === "POST" && url.pathname === "/v1/lines") return await submit(req, env);
      if (req.method === "GET" && url.pathname === "/v1/stats") return await stats(env);
      if (url.pathname === "/v1/export" || url.pathname === "/v1/exported") {
        if (!isAdmin(req, env)) return json({ error: "unauthorized" }, 401);
        if (url.pathname === "/v1/export" && req.method === "GET") return await exportLines(url, env);
        if (url.pathname === "/v1/exported" && req.method === "POST") return await markExported(req, env);
        return json({ error: "method_not_allowed" }, 405,
          { allow: url.pathname === "/v1/export" ? "GET" : "POST" });
      }
      if (url.pathname === "/") return new Response("CouchSubs subtitle pool\n");
      return json({ error: "not_found" }, 404);
    } catch (e) {
      const message = String(e?.message || e);
      console.error(JSON.stringify({ error: "server_error", path: url.pathname, message: message.slice(0, 500) }));
      const wait = unavailableFor(e);
      if (wait) return json({ error: "unavailable" }, 503, { "retry-after": String(wait) });
      return json({ error: "server_error" }, 500);
    }
  },

  async scheduled(event, env, ctx) {
    const result = await runAutopack(env, new Date(event.scheduledTime));
    console.log("autopack", JSON.stringify(result));
  },
};
