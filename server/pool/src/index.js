// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs subtitle pool (Cloudflare Worker + D1).
// POST /v1/lines   : uygulamalar paketlerde bulunmayan İngilizce satırları gönderir. Satırda isteğe bağlı olarak
//                    PS5'te o an çalışan oyunun kimliği (titleId, ör. "PPSA01234") ve adı (game) gelir. Kimlik
//                    yoksa ad uygulamanın paketten tanıdığı ya da kullanıcının seçtiği oyundur; kurulum başına bir
//                    "oy" (game_votes) yazılır, gece paketi en az iki kurulumun bildirdiği adla açılır.
// GET  /v1/export  : (yönetici) en az N kurulumun gördüğü, henüz çevrilmemiş satırlar; `title=` ya da `game=` ile
//                    yalnız bir oyunun satırları.
// POST /v1/exported: (yönetici) çeviriye alınan anahtarları işaretler.
// GET  /v1/stats   : herkese açık sayılar.
// Cron (gece 03:07–04:57 UTC): havuzdan kendiliğinden oyun paketi (src/autopack.js).

import { accepts } from "./filter.js";
import { runAutopack } from "./autopack.js";
import { gameKey } from "./games.js";

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

/** Oyun adı: denetim karakterleri ve fazla boşluk atılır, en çok 120 karakter; boşsa null. */
export function gameName(value) {
  if (typeof value !== "string") return null;
  const t = value.replace(/\p{C}/gu, " ").replace(/\s+/g, " ").trim().slice(0, MAX_GAME).trim();
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

async function submit(req, env) {
  let body;
  try { body = await req.json(); } catch { return json({ error: "json" }, 400); }
  const install = String(body?.install || "");
  if (!UUID.test(install) || !Array.isArray(body?.lines)) return json({ error: "bad_request" }, 400);
  const lines = body.lines.slice(0, MAX_LINES);
  const day = new Date().toISOString().slice(0, 10);

  // Reserve capacity with compare-and-swap. The previous read-then-batch increment let concurrent
  // requests both spend the same remaining quota. Retry if another request changed the count first.
  let room;
  let reserved = false;
  for (let attempt = 0; attempt < QUOTA_CAS_ATTEMPTS; attempt++) {
    const q = await env.DB.prepare("SELECT count FROM quota WHERE install=? AND day=?").bind(install, day).first();
    const used = q?.count || 0;
    if (used >= DAILY_LIMIT) return json({ error: "quota" }, 429, { "retry-after": "3600" });
    room = Math.min(lines.length, DAILY_LIMIT - used);
    if (room === 0) {
      reserved = true;
      break;
    }
    const result = await env.DB.prepare(
      "INSERT INTO quota(install,day,count) VALUES(?,?,?) " +
      "ON CONFLICT(install,day) DO UPDATE SET count=count+excluded.count WHERE quota.count=?"
    ).bind(install, day, room, used).run();
    if (result.meta?.changes > 0) {
      reserved = true;
      break;
    }
  }
  if (!reserved) return json({ error: "busy" }, 503, { "retry-after": "1" });

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
    console.log(JSON.stringify(submitSummary(body, lines)));

    // D1'in günlük yazma kotası (ücretsiz 100.000 satır; tablo satırı ve her dizin girdisi ayrı sayılır) için: önce
    // görülme kaydı (sightings, WITHOUT ROWID: satır başına tek yazma). Bu kurulum satırı zaten bildirdiyse (changes 0)
    // hiçbir şeye dokunulmaz. Satır havuza (lines) yalnız ikinci farklı kurulumdan gelince yazılır: tek kurulumun
    // gördüğü satır havuza hiç girmez (paket ve dışa aktarım zaten en az iki kurulum ister). Kota satırı
    // istek başına tek yazmadır.
    const now = new Date().toISOString();
    entries = [...fresh];
    const seen = entries.length
      ? await env.DB.batch(entries.map(([k]) =>
        env.DB.prepare("INSERT OR IGNORE INTO sightings(key,install) VALUES(?,?)").bind(k, install)))
      : [];
    // Oyun bilgisi satırın ilk bilinen oyunudur: sonra gelen başka oyun üstüne yazmaz (COALESCE). Metin ve oyun
    // bilgisi, satırı havuza sokan (ikinci) kurulumun isteğinden alınır.
    const stmts = [];
    entries.forEach(([k, line], i) => {
      if (!(seen[i]?.meta?.changes > 0)) return;
      stmts.push(env.DB.prepare(UPSERT).bind(k, line.text, now, now, line.title, line.game, k));
    });
    recorded = stmts.length;
    if (stmts.length) await env.DB.batch(stmts);
  } catch (error) {
    // Undo the reservation if filtering, hashing, or either primary write fails. A failed compensation
    // leaves quota conservative rather than risking an over-limit counter.
    if (room > 0) {
      await env.DB.prepare("UPDATE quota SET count=count-? WHERE install=? AND day=? AND count>=?")
        .bind(room, install, day, room).run().catch(() => {});
    }
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
// sayacı bir artar. Tek kurulumda SELECT boş döner, yazma olmaz.
export const UPSERT =
  "INSERT INTO lines(key,text,installs,first_seen,last_seen,title_id,game) " +
  "SELECT ?,?,n,?,?,?,? FROM (SELECT COUNT(*) AS n FROM sightings WHERE key=?) WHERE n>=2 " +
  "ON CONFLICT(key) DO UPDATE SET installs=installs+1, last_seen=excluded.last_seen, " +
  "title_id=COALESCE(lines.title_id,excluded.title_id), game=COALESCE(lines.game,excluded.game)";

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
  const keys = Array.isArray(body?.keys) ? body.keys.slice(0, 20000) : [];
  for (let i = 0; i < keys.length; i += 100) {
    await env.DB.batch(keys.slice(i, i + 100).map((k) =>
      env.DB.prepare("UPDATE lines SET exported=1 WHERE key=?").bind(String(k))));
  }
  return json({ marked: keys.length });
}

// Dağıtımın bellek önbelleği: görülme tablosunu taramak okuma kotası harcar, herkese açık adres sık çağrılmasın.
let statsCache = { at: 0, body: null };
const STATS_TTL_MS = 10 * 60 * 1000;

async function stats(env) {
  if (statsCache.body && Date.now() - statsCache.at < STATS_TTL_MS) return json(statsCache.body);
  // lines yalnız en az iki kurulumun gördüğü satırları tutar; tüm satırlar ve kurulumlar sightings'ten sayılır.
  const seen = await env.DB.prepare(
    "SELECT COUNT(DISTINCT key) AS lines, COUNT(DISTINCT install) AS installs FROM sightings"
  ).first();
  const confirmed = await env.DB.prepare("SELECT COUNT(*) AS confirmed FROM lines WHERE installs>=2").first();
  statsCache = {
    at: Date.now(),
    body: { lines: seen?.lines ?? 0, confirmed: confirmed?.confirmed ?? 0, installs: seen?.installs ?? 0 },
  };
  return json(statsCache.body);
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      if (req.method === "POST" && url.pathname === "/v1/lines") return await submit(req, env);
      if (req.method === "GET" && url.pathname === "/v1/stats") return await stats(env);
      if (url.pathname === "/v1/export" || url.pathname === "/v1/exported") {
        if (!isAdmin(req, env)) return json({ error: "unauthorized" }, 401);
        return req.method === "POST" ? await markExported(req, env) : await exportLines(url, env);
      }
      if (url.pathname === "/") return new Response("CouchSubs subtitle pool\n");
      return json({ error: "not_found" }, 404);
    } catch (e) {
      return json({ error: "server_error" }, 500);
    }
  },

  async scheduled(event, env, ctx) {
    const result = await runAutopack(env, new Date(event.scheduledTime));
    console.log("autopack", JSON.stringify(result));
  },
};
