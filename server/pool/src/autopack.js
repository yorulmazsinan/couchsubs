// SPDX-License-Identifier: AGPL-3.0-only
// Havuzdan kendiliğinden oyun paketi (Cron Trigger, her gece 03:02–05:57 UTC arasında beş dakikada bir).
//
// Bir oyunun (title_id; kimlik yoksa src/games.js'teki anahtarıyla oyun adı) satırları en az MIN_INSTALLS farklı kurulumda aynı biçimde (aynı canon anahtarla) okunduysa
// tools/packs/poolpack.py'deki kurallarla temizlenir, Workers AI ile Türkçeye çevrilir ve R2'ye (couchsubs-packs kovası)
// `packs/pool-<oyun kimliği>.json.gz` olarak yazılır; index.json'a sürümü artırılarak girer. Uygulamalar paketi
// kendileri indirir (server/packs). Yeni kimlik bilgisi yoktur: D1, R2 ve Workers AI bu Worker'ın bağlarıdır.
//
// Elle hazırlanmış (uygulamayla gelen) paketler öncelikli: onlardaki anahtarlar (R2'de auto/known-keys.bin,
// scripts/build-known.mjs üretir) otomatik pakete hiç girmez, böylece iki paket aynı satırda çakışmaz; otomatik paket
// elle olanın eksiğini tamamlar.
//
// Workers Free planında çağrı başına CPU süresi 10 ms: iş küçük adımlara bölünür ve her tetiklemede bir adım yapılır
// (gecenin ilk tetiklemesi plan, sonrakiler oyun başına çeviri parçaları ve en son paket). Durum R2'de auto/state.json.

import { accepts } from "./filter.js";
import { STATS_KEY, canon, key } from "./index.js";
import { EXTRA_SUFFIX, gameKey, gameSlug } from "./games.js";

/** Bir satırın pakete girmesi için onu okuyan en az farklı kurulum sayısı. */
export const MIN_INSTALLS = 2;
/** Bir oyunun ilk paketi için en az çevrilmiş satır; paket bir kez çıktıktan sonra her yeni satır eklenir. */
export const MIN_LINES = 300;
/** Bir tetiklemede en çok bu kadar yeni satır çevrilir (CPU sınırı). */
export const LINES_PER_RUN = 200;
/** Bir gecede en çok bu kadar satır çevrilir.
 *  Hesap: Workers AI Free planı günde 10.000 nöron verir (UTC 00:00'da sıfırlanır). Önceki sınır 3000 satırı "10.000
 *  nöronun yarısından azı" saymıştı, yani en çok ~1,67 nöron/satır. 5000 satır × 1,67 = ~8.333 nöron: günlük sınırın
 *  %83'ü, %17 pay kalır (satır başına gerçek nöron panelden ölçülmeli; yüksek çıkarsa bu sayı düşürülür). Başka bir
 *  yapay zekâ kullanımı yoktur. 5000 satır gecede 200'lük en az 25 tetikleme ister; cron 36 tetikleme verir
 *  (plan 1 + çeviri ~25–30 + en son paket). */
export const NIGHTLY_LIMIT = 5000;
/** Bir D1 sorgusunda okunan satır sayfası ve bir tetiklemede en çok kaç sayfa gezilir. Sayfalar anahtar imleciyle
 *  (installs azalan, key artan) ilerler; "ilk 5000 satır" penceresi yoktur, büyük oyunun tamamı sırayla gezilir. */
export const PAGE = 1500;
export const MAX_PAGES = 3;
/** Bir tetiklemede en çok bu kadar çevrilebilir satıra bakılır (çöp ve bilinen satırlar çeviri bütçesini yemesin,
 *  ama CPU da sınırlı kalsın). */
export const MAX_LOOK = 500;
/** Bir oyun bir gecede en çok bu kadar satır çevirir; sonra paketi kurulup sıra sonrakine geçer. Dev bir oyun
 *  (GTA 6: yüz binlerce satır) bütün geceyi alıp öteki oyunları aç bırakmasın; her gece büyür, yeni sürüm çıkar. */
export const JOB_NIGHTLY = 2000;
/** Gecenin son tetiklemesi (cron 2-57/5 UTC 03–05): çevrilen oyun bu gece büyüdüyse paketi kurup sürümü artırır. */
export const LAST_HOUR_UTC = 5;
export const LAST_MINUTE_UTC = 52;
export const BATCH = 40;
export const MODEL = "@cf/zai-org/glm-5.3-flash";
export const SOURCE = `CouchSubs havuzu (en az ${MIN_INSTALLS} oyuncu) + Workers AI (${MODEL})`;
/** Oyunu bilinmeyen satırların ortak paketi (title_id NULL). PS5'in keşif yanıtı çalışan oyunu bildirmediği için
 *  satırların çoğu oyunsuz gelir; uygulamalar sunucudaki her paketi indirdiğinden bu paket de herkese gider. Oyunu
 *  bilinen paketlerden sonra hazırlanır. */
export const GENERAL = "GENEL";
export const GENERAL_TITLE = "Ortak havuz (çeşitli oyunlar)";
/** Kimliksiz, yalnız adıyla gelen oyun ayrı paket için en az bu kadar farklı kurulumdan oy almalı (game_votes):
 *  tek kişinin yanlış seçimi paket açmasın. Oyu yetmeyen adın satırları ortak pakete gider. */
export const MIN_VOTERS = 2;
/** Bir ad grubunda en çok bu kadar yazım ("GTA 6", "Grand Theft Auto VI"…) sorguya girer. */
const MAX_VARIANTS = 20;

const STATE = "auto/state.json";
const KNOWN = "auto/known-keys.bin";
const cacheFile = (job) => {
  if (job.titleId) return `auto/tr/${job.titleId}.json`;
  // Long ASCII names can have the same truncated slug while their pack IDs differ.
  // Keep short ASCII cache paths compatible, but hash long and non-Latin identities.
  return `auto/tr/name-${jobPackId(job).slice(PACK_PREFIX.length)}.json`;
};

// poolpack.py ile aynı: konuşmacı etiketi, Türkçe harf, yazı tanıma çöpü.
const LABEL = /^[-•\s]*([A-Z][A-Za-z .'’-]{1,28}?)\s*[•:]\s+(?=\S)/;
const TURKISH = /[ğĞşŞıİ]/u;
const OCR_JUNK = /[$#@|\\{}<>~^_=]|[\p{L}\p{N}_][%&*][\p{L}\p{N}_]/u;
// Üç ve daha çok sözcüklü satırda en az bir yaygın İngilizce sözcük: bozuk okunmuş Türkçe arayüz ("Yeni ipuqlarl Var
// Daha Fazlaslnl") Türkçe harf taşımadığı için ayrıca elenir.
const ENGLISH = new Set(("the a an to of and or but with for from my your his her their our at in on by is are was were be " +
  "i you he she it we they me him us them this that what who where when why how not no yes do did don't can can't will " +
  "won't just get got go have has had all there here now up out if so like know want need come one some about").split(" "));

const PACK_PREFIX = "pool-";
const MAX_PACK_ID_LENGTH = 64;

function hashPackSuffix(value) {
  let hash = 14695981039346656037n;
  for (const character of value) {
    hash = BigInt.asUintN(64, (hash ^ BigInt(character.codePointAt(0))) * 1099511628211n);
  }
  return hash.toString(36).padStart(13, "0");
}

function prefixedPackId(suffix, identity = suffix) {
  const full = `${PACK_PREFIX}${suffix}`;
  if (full.length <= MAX_PACK_ID_LENGTH) return full;

  // Kimlik biçimini 64 karakterde tutarken uzun oyun adlarının aynı pakete çarpışmasını önle.
  const hash = hashPackSuffix(identity);
  const prefixLength = MAX_PACK_ID_LENGTH - PACK_PREFIX.length - hash.length - 1;
  return `${PACK_PREFIX}${suffix.slice(0, prefixLength)}-${hash}`;
}

/** Oyun kimliğinden paket kimliği: "PPSA01234" → "pool-ppsa01234" (server/packs'in kimlik biçimine uyar). */
export function packId(titleId) {
  const identity = String(titleId);
  return prefixedPackId(identity.toLowerCase().replace(/[^a-z0-9]+/g, "-"), identity);
}

/** İşin paket kimliği: oyun kimliği varsa ondan, yoksa adın anahtarından ("gta 6" → "pool-gta-6"). */
export function jobPackId(job) {
  if (job.titleId) return packId(job.titleId);
  const identity = String(job.gameKey);
  const slug = gameSlug(identity);
  if (/^[a-z0-9 ]+$/.test(identity)) return prefixedPackId(slug, identity);

  // Non-Latin characters disappear from the ASCII slug, so hash the full key to avoid collisions.
  const hash = hashPackSuffix(identity);
  const maxSlug = MAX_PACK_ID_LENGTH - PACK_PREFIX.length - hash.length - 1;
  const safeSlug = (slug || "game").slice(0, maxSlug).replace(/-+$/, "");
  return `${PACK_PREFIX}${safeSlug}-${hash}`;
}

/** Kimliksiz satırların oyun adları ("game" sütunu, yazımına göre sayılmış) anahtara göre birleşir; en az MIN_VOTERS
 *  kurulumun oyladığı anahtarlar iş olur. Görünen ad en çok satırı olan yazımdır. */
export function nameJobs(rows, votes) {
  const groups = new Map();
  for (const r of rows) {
    const k = gameKey(r.game);
    if (!k || gameSlug(k) === "genel") continue;
    const g = groups.get(k) ?? { titleId: null, gameKey: k, game: r.game, best: 0, lines: 0, games: [] };
    g.lines += r.lines;
    if (g.games.length < MAX_VARIANTS) g.games.push(r.game);
    if (r.lines > g.best) { g.best = r.lines; g.game = r.game; }
    groups.set(k, g);
  }
  return [...groups.values()]
    .filter((g) => (votes.get(g.gameKey) ?? 0) >= MIN_VOTERS)
    .map(({ best, ...g }) => g)
    .sort((a, b) => b.lines - a.lines);
}

async function allRows(stmt) {
  try { return (await stmt.all()).results ?? []; } catch (e) {
    // Geçiş çalışmadıysa (game_votes ya da game sütunu yok) ad grupları yoktur.
    if (/no such (table|column)/i.test(String(e?.message || e))) return [];
    throw e;
  }
}

/** Havuz satırının çevrilecek gövdesi (konuşmacı etiketi atılmış) ya da pakete uygun değilse null. */
export function cleanLine(text) {
  const raw = String(text ?? "").replace(/\s+/g, " ").trim();
  if (!accepts(raw)) return null;
  const m = LABEL.exec(raw);
  const body = m ? raw.slice(m[0].length).trim() : raw;
  if (TURKISH.test(body)) return null;
  const visible = [...body.replace(/ /g, "")];
  const letters = visible.filter((ch) => /\p{L}/u.test(ch)).length;
  if (OCR_JUNK.test(body) || letters * 2 < visible.length) return null;
  const words = body.split(" ").filter((w) => /\p{L}/u.test(w)).length;
  if (words < 2 || body.length > 300) return null;
  const lower = body.toLowerCase().split(/[^a-z']+/).filter(Boolean);
  if (lower.length >= 3 && !lower.some((w) => ENGLISH.has(w))) return null;
  return { body, labelled: body !== raw };
}

/** Elle hazırlanmış paketlerin anahtarları: sıralı 64 bit sayılar (küçük uçlu). */
export function isKnown(known, hex) {
  if (!known || !hex) return false;
  const value = BigInt("0x" + hex);
  let low = 0, high = known.length;
  while (low < high) {
    const mid = (low + high) >>> 1;
    if (known[mid] < value) low = mid + 1; else high = mid;
  }
  return low < known.length && known[low] === value;
}

const SYSTEM = (game) =>
  "You translate video game subtitles from English into natural, colloquial Turkish for CouchSubs, an app that shows " +
  "Turkish subtitles on the TV while people play" + (game ? ` ${game}` : "") + ".\n" +
  "Rules:\n- Translate every line; keep character, place, gang, vehicle and brand names as they are.\n" +
  "- Dialogue: use 'sen' between characters unless the scene is clearly formal. Tutorial hints: short imperative.\n" +
  "- Keep the tone, slang and swearing level; keep ellipses and question marks.\n" +
  "- These lines were read from the TV with OCR; if a word is clearly damaged, translate the most likely original.\n" +
  "- One Turkish line per item, no notes. Output only JSON: {\"items\":[{\"id\":\"0\",\"tr\":\"...\"}]}";

/** Satırları Workers AI ile çevirir; id → Türkçe. Yanıt bozuksa boş. */
export async function translate(env, items, game) {
  const user = items.map((it, i) => `${i}\t${it.en}`).join("\n");
  let reply;
  try {
    reply = await env.AI.run(MODEL, {
      messages: [{ role: "system", content: SYSTEM(game) }, { role: "user", content: user }],
      max_tokens: 6000,
      chat_template_kwargs: { enable_thinking: false },
    });
  } catch (e) {
    console.log("autopack: çeviri hatası", String(e?.message || e));
    return new Map();
  }
  return parseReply(reply, items);
}

export function parseReply(reply, items) {
  let content = reply?.choices?.[0]?.message?.content ?? reply?.response;
  let parsed = content;
  if (typeof content === "string") {
    const text = content.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
    try { parsed = JSON.parse(text); } catch { return new Map(); }
  }
  const out = new Map();
  if (!Array.isArray(parsed?.items)) return out;
  const duplicates = new Set();
  for (const it of parsed.items) {
    const id = it?.id;
    if (typeof id !== "number" && !(typeof id === "string" && /^\d+$/.test(id))) continue;
    const i = Number(id);
    const tr = typeof it?.tr === "string" ? it.tr.replace(/\s+/g, " ").trim() : "";
    if (!Number.isSafeInteger(i) || !items[i] || !tr) continue;
    // Açıklama ya da birden çok satır yazmış, çok uzun ya da Türkçe değil: alınmaz.
    if (/[{}]/.test(tr) || tr.length > items[i].en.length * 3 + 40) continue;
    // Ambiguous AI IDs must not silently overwrite an earlier, different subtitle.
    if (duplicates.has(i)) continue;
    if (out.has(i)) {
      out.delete(i);
      duplicates.add(i);
      continue;
    }
    out.set(i, tr);
  }
  return out;
}

async function getJson(env, name) {
  const object = await env.PACKS.get(name);
  if (!object) return null;
  try { return JSON.parse(await object.text()); } catch { return null; }
}

// Kaybolan önbellek ilk çalıştırmada normaldir; mevcut ama bozuk önbelleği sıfırlamak mevcut paketi silebilir.
async function loadCache(env, job) {
  const object = await env.PACKS.get(cacheFile(job));
  if (!object) {
    // Yayınlanmış paketin önbelleği silindiyse sıfırdan oluşturmak mevcut çevirileri boş paketle değiştirir.
    const packs = await readIndex(env);
    if (packs.some((pack) => pack.id === jobPackId(job))) return null;
    return { lines: {}, skip: {}, fail: {} };
  }
  try {
    const cache = JSON.parse(await object.text());
    const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
    if (!record(cache) || !record(cache.lines) || !record(cache.skip)
      || (cache.fail != null && !record(cache.fail))) return null;
    // A parseable cache with a null line or malformed hash otherwise throws in
    // packBody/isKnown and stops the remaining nightly scheduler calls.
    if (!Object.entries(cache.lines).every(([pool, line]) =>
      /^[0-9a-f]{16}$/.test(pool) && record(line)
      && typeof line.k === "string" && /^[0-9a-f]{16}$/.test(line.k)
      && typeof line.en === "string" && line.en.trim().length > 0
      && typeof line.tr === "string" && line.tr.trim().length > 0)) return null;
    return cache;
  } catch { return null; }
}

const putJson = (env, name, value) =>
  env.PACKS.put(name, JSON.stringify(value), { httpMetadata: { contentType: "application/json" } });

async function loadKnown(env) {
  const object = await env.PACKS.get(KNOWN);
  if (!object) return null;
  const buffer = await object.arrayBuffer();
  // Yarım kalmış dosya (8'in katı olmayan boyut) bozuktur: elle hazırlanan çevirileri korumak için beklenir. Sıralama
  // her tetiklemede taranmaz (650 bin anahtar, Free planın 10 ms CPU sınırını aşar); dosyayı scripts/build-known.mjs
  // sıralı ve tekrarsız üretir.
  if (buffer.byteLength % 8 !== 0) return null;
  return new BigUint64Array(buffer);
}

async function sha256Hex(data) {
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function gzip(text) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

const sorted = (o) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));

/** Çeviri önbelleğinden paket gövdesi (elle hazırlanmış paketlerdeki anahtarlar hariç). */
export function packBody(id, title, cache, known, titleId = null) {
  const entries = {};
  const segments = {};
  for (const [pool, line] of Object.entries(cache.lines)) {
    if (isKnown(known, line.k)) continue;
    // Türkçesi İngilizcesiyle aynı (ad, ünlem): tam satır değil parça (build.py ile aynı).
    if (canon(line.tr) === canon(line.en)) segments[line.k] = line.tr; else entries[line.k] = line.tr;
    // Konuşmacı etiketli okunuş da aynı Türkçeye çıkar.
    if (pool !== line.k && !isKnown(known, pool)) segments[pool] = line.tr;
  }
  for (const k of Object.keys(segments)) if (k in entries) delete segments[k];
  const count = Object.keys(entries).length;
  // Oyun kimliği uygulamalara da gider: paketle tanınan oyun havuza kimliğiyle döner.
  const head = titleId ? { format: 2, id, title, titleId } : { format: 2, id, title };
  const body = JSON.stringify({ ...head, source: SOURCE, entries: sorted(entries), segments: sorted(segments) });
  return { body, count };
}

async function readIndex(env) {
  const index = await getJson(env, "index.json");
  // Eksik/bozuk indeks, boş bir indeks değildir: aksi halde sonraki paket mevcut listeyi siler.
  if (!Array.isArray(index?.packs)) throw new Error("autopack index unavailable or invalid");
  // An ambiguous or malformed index makes every client's pack list unavailable.
  // Never rewrite it or drop entries while trying to publish another pack.
  const ids = new Set();
  for (const pack of index.packs) {
    if (!pack || typeof pack !== "object" || typeof pack.id !== "string"
      || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(pack.id) || ids.has(pack.id)) {
      throw new Error("autopack index invalid or duplicate pack ID");
    }
    ids.add(pack.id);
  }
  return index.packs;
}

/** Paketin listedeki adı. Aynı oyunun elle hazırlanmış (auto olmayan) paketi listede varsa otomatik paket onun
 *  eksiğini tamamlar: adına " (ek satırlar)" eklenir ki listede iki kez aynı ad görünmesin. Ek, adın anahtarını da
 *  değiştirir; uygulamalar elle seçilen oyunu ada göre eşlediğinden (GamePacks.swift resolveLimit) seçim asıl pakete
 *  gider. Asıl paket yoksa ad değişmez: yalnız ek paketi olan oyunun seçimi bu paketi bulmaya devam eder. */
export function packTitle(job, packs) {
  if (job.titleId === GENERAL) return GENERAL_TITLE;
  const title = job.game || job.titleId;
  const id = jobPackId(job);
  const k = gameKey(title);
  const main = packs.some((p) => p && !p.auto && p.id !== id
    && ((k && typeof p.title === "string" && gameKey(p.title) === k) || (job.titleId && p.titleId === job.titleId)));
  return main ? title + EXTRA_SUFFIX : title;
}

async function buildPack(env, job, cache, known) {
  const id = jobPackId(job);
  const packs = await readIndex(env);
  // Ad gövdede de durduğundan ad değişince (asıl paket eklendi ya da kalktı) içerik özeti de değişir ve paket aynı
  // gece yeniden yazılır; listedeki ad böylece kendiliğinden güncellenir.
  const title = packTitle(job, packs);
  const { body, count } = packBody(id, title, cache, known, job.titleId === GENERAL ? null : job.titleId);
  const previous = packs.find((p) => p.id === id);
  if (!previous && count < MIN_LINES) return { id, built: false, entries: count };
  const contentSha = await sha256Hex(new TextEncoder().encode(body));
  if (previous && cache.contentSha === contentSha) {
    // The index may outlive an R2 object removed independently.
    // An unchanged source hash is only enough when the published file exists.
    const packKey = `packs/${id}.json.gz`;
    const published = env.PACKS.head
      ? await env.PACKS.head(packKey)
      : await env.PACKS.get(packKey);
    if (published) return { id, built: false, unchanged: true, entries: count };
  }
  const data = await gzip(body);
  const sha256 = await sha256Hex(data);
  // Önce dosya, sonra liste: liste hiçbir zaman olmayan dosyayı göstermez.
  await env.PACKS.put(`packs/${id}.json.gz`, data, {
    httpMetadata: { contentType: "application/gzip" }, customMetadata: { sha256 },
  });
  const fresh = await readIndex(env);
  const version = (fresh.find((p) => p.id === id)?.version ?? 0) + 1;
  const entry = { id, title, version, sha256, size: data.length, entries: count, auto: true };
  if (job.titleId) entry.titleId = job.titleId;
  else entry.game = job.gameKey;
  const list = fresh.filter((p) => p.id !== id).concat(entry).sort((a, b) => (a.id < b.id ? -1 : 1));
  await putJson(env, "index.json", { packs: list });
  cache.contentSha = contentSha;
  await putJson(env, cacheFile(job), cache);
  return { id, built: true, version, entries: count, size: data.length };
}

/** Herkese açık sayıların gecelik özeti (R2 auto/stats.json; GET /v1/stats yalnız bunu okur). Ağır sorgu (bütün
 *  sightings'i tarayan COUNT DISTINCT) yalnız burada, gecede bir kez ve kendi tetiklemesinde çalışır; süre sınırına
 *  takılırsa önceki özetteki sayılar korunur (approx işareti), tetiklemeyi ve gece işini düşürmez. */
export async function computeStats(env, now) {
  const previous = await getJson(env, STATS_KEY);
  let { lines, installs } = previous ?? {};
  let confirmed = previous?.confirmed;
  let approx = false;
  try {
    const seen = await env.DB.prepare(
      "SELECT COUNT(DISTINCT key) AS lines, COUNT(DISTINCT install) AS installs FROM sightings"
    ).first();
    lines = seen?.lines ?? lines;
    installs = seen?.installs ?? installs;
  } catch (e) {
    approx = true;
    console.log("autopack: özet (sightings) sayılamadı", String(e?.message || e));
  }
  try {
    const row = await env.DB.prepare("SELECT COUNT(*) AS confirmed FROM lines WHERE installs>=?").bind(MIN_INSTALLS).first();
    confirmed = row?.confirmed ?? confirmed;
  } catch (e) {
    approx = true;
    console.log("autopack: özet (lines) sayılamadı", String(e?.message || e));
  }
  // Hiç eski özet yoksa ve ağır sorgu başarısızsa: onaylanmış satırlar alt sınırdır.
  const out = {
    lines: Number.isFinite(lines) ? lines : (Number.isFinite(confirmed) ? confirmed : 0),
    confirmed: Number.isFinite(confirmed) ? confirmed : 0,
    installs: Number.isFinite(installs) ? installs : 0,
    updated: now.toISOString(),
  };
  if (approx) out.approx = true;
  await putJson(env, STATS_KEY, out);
  return out;
}

/** Gecenin son tetiklemesi mi (cron 2-57/5 UTC 03–05)? Çevrilen oyunun paketi en geç bu tetiklemede kurulur. */
export function isFinalTick(now) {
  return now.getUTCHours() > LAST_HOUR_UTC
    || (now.getUTCHours() === LAST_HOUR_UTC && now.getUTCMinutes() >= LAST_MINUTE_UTC);
}

/** Oyunun satırlarından imleçten sonraki bir sayfa: installs azalan, key artan (anahtar imleci; sabit sıra). */
async function fetchPage(env, job, separate, cursor) {
  const after = cursor ? " AND (installs<? OR (installs=? AND key>?))" : "";
  const cur = cursor ? [cursor.n, cursor.n, cursor.k] : [];
  const tail = ` ORDER BY installs DESC, key LIMIT ${PAGE}`;
  let sql, args;
  if (job.titleId === GENERAL) {
    if (separate.size) {
      // Oyuna ayrılan satırları sayfadan önce süz; aksi halde en çok okunan satırlar ortak havuzu aç bırakır.
      // Oyun adlarını JSON tek bir bağlı parametreyle taşıyarak D1 değişken sayısı sınırına takılmayız.
      sql = "SELECT key, text, installs FROM lines WHERE title_id IS NULL AND installs>=? " +
        "AND (game IS NULL OR game NOT IN (SELECT value FROM json_each(?)))" + after + tail;
      args = [MIN_INSTALLS, JSON.stringify([...separate]), ...cur];
    } else {
      sql = "SELECT key, text, installs FROM lines WHERE title_id IS NULL AND installs>=?" + after + tail;
      args = [MIN_INSTALLS, ...cur];
    }
  } else if (job.titleId) {
    sql = "SELECT key, text, installs FROM lines WHERE title_id=? AND installs>=?" + after + tail;
    args = [job.titleId, MIN_INSTALLS, ...cur];
  } else {
    const games = (job.games?.length ? job.games : [job.game]).slice(0, MAX_VARIANTS);
    sql = `SELECT key, text, installs FROM lines WHERE title_id IS NULL AND game IN (${games.map(() => "?").join(",")}) ` +
      "AND installs>=?" + after + tail;
    args = [...games, MIN_INSTALLS, ...cur];
  }
  return (await env.DB.prepare(sql).bind(...args).all()).results ?? [];
}

/** Bir adım: gecenin ilk çağrısında plan, sonra sıradaki oyunda çeviri parçası ya da paket. Sonucu döner ve yazar. */
export async function runAutopack(env, now = new Date()) {
  if (!env.PACKS || !env.AI) return { phase: "disabled" };
  const night = now.toISOString().slice(0, 10);
  let state = await getJson(env, STATE);
  // A parseable but incomplete R2 state must not stall every remaining run of this night.
  // Replanning is safe: per-game translation caches are persisted separately.
  const validJob = (job) => job && typeof job === "object" && !Array.isArray(job)
    && ((typeof job.titleId === "string" && job.titleId.length > 0)
      || (job.titleId == null && typeof job.gameKey === "string" && job.gameKey.length > 0));
  const validState = state && Array.isArray(state.queue) && state.queue.every(validJob)
    && Array.isArray(state.done) && Number.isSafeInteger(state.translated) && state.translated >= 0
    && (state.namedGames == null || (Array.isArray(state.namedGames)
      && state.namedGames.every((game) => typeof game === "string")));
  if (state?.night !== night || !validState) {
    const { results } = await env.DB.prepare(
      "SELECT title_id, MAX(game) AS game, COUNT(*) AS lines FROM lines WHERE title_id IS NOT NULL AND installs>=? " +
      "GROUP BY title_id ORDER BY lines DESC LIMIT 50"
    ).bind(MIN_INSTALLS).all();
    const packs = await readIndex(env);
    const titles = results.map((r) => ({ titleId: r.title_id, game: r.game, lines: r.lines }));
    // Kimliksiz ama adıyla gelen oyunlar: adın anahtarına göre birleşir, en az iki kurulumun oyladığı ayrı iş olur.
    const voted = await allRows(env.DB.prepare(
      "SELECT game_key, COUNT(*) AS installs FROM game_votes GROUP BY game_key HAVING COUNT(*)>=?"
    ).bind(MIN_VOTERS));
    const votes = new Map(voted.map((r) => [r.game_key, r.installs]));
    const named = votes.size ? nameJobs(await allRows(env.DB.prepare(
      "SELECT game, COUNT(*) AS lines FROM lines WHERE title_id IS NULL AND game IS NOT NULL AND installs>=? " +
      "GROUP BY game ORDER BY lines DESC LIMIT 300"
    ).bind(MIN_INSTALLS)), votes).slice(0, 30) : [];
    titles.push(...named);
    const general = await env.DB.prepare("SELECT COUNT(*) AS lines FROM lines WHERE title_id IS NULL AND installs>=?")
      .bind(MIN_INSTALLS).first();
    // Named jobs may fail to reach the cleaned MIN_LINES threshold. Keep a general job
    // scheduled until they have actually published; only then can their rows be excluded.
    titles.push({ titleId: GENERAL, game: null, lines: general?.lines ?? 0 });
    // Ham satır sayısı temizlikten önce: eşiğin altındaki oyun beklemeye kalır (paketi zaten varsa güncellenir).
    let queue = titles.filter((t) => t.lines >= MIN_LINES || packs.some((p) => p.id === jobPackId(t)));
    // Ortak paket, kendi paketi hazırlanan adların satırlarını almaz.
    const namedGames = named.filter((g) => queue.includes(g)).flatMap((g) => g.games);
    // Listedeki adı değişecek otomatik paket ("(ek satırlar)" eklenecek ya da kalkacak) çevirisiz, en başta yeniden
    // yazılır: büyük bir oyunun çevirisi bütün geceyi alıp sıra ona hiç gelmeyebilir.
    const retitle = queue.filter((t) => {
      const listed = packs.find((p) => p.id === jobPackId(t));
      return listed?.auto && listed.title !== packTitle(t, packs);
    });
    queue = retitle.map((t) => ({ ...t, retitle: true })).concat(queue.filter((t) => !retitle.includes(t)));
    state = { night, titles, queue, namedGames, translated: 0, done: [] };
    await putJson(env, STATE, state);
    // Plan yazıldıktan sonra gecelik özet: ağır sorgu çevirinin önüne geçmez, hatası geceyi düşürmez.
    let summary = null;
    try { summary = await computeStats(env, now); } catch (e) {
      console.log("autopack: özet yazılamadı", String(e?.message || e));
    }
    return { phase: "plan", titles: titles.length, queued: queue.length, stats: summary };
  }
  const job = state.queue[0];
  if (!job) return { phase: "idle", done: state.done };

  const known = await loadKnown(env);
  if (!known) return { phase: "waiting", reason: "auto/known-keys.bin yok" };
  const cache = await loadCache(env, job);
  if (!cache) return { phase: "waiting", reason: "auto/translation cache invalid" };
  cache.fail ??= {};
  // Exclude named rows only when their individual pack was actually published or
  // confirmed unchanged. An unbuilt named pack must fall back into the general pool.
  const published = new Set(state.done
    .filter((finished) => finished?.gameKey && (finished.built || finished.unchanged))
    .flatMap((finished) => finished.games?.length ? finished.games : [finished.game]));
  const separate = new Set((state.namedGames ?? []).filter((name) => published.has(name)));
  const want = Math.min(LINES_PER_RUN, NIGHTLY_LIMIT - state.translated, JOB_NIGHTLY - (job.did ?? 0));
  const todo = [];
  let looked = 0;
  let scanned = 0;
  // Gezinti ya da gecelik pay bitti, gecenin son tetiklemesi (bu gece çevrilen paket kurulur) ya da yalnız yeniden
  // adlandırma: çeviri yok, paket kurulur.
  let exhausted = job.retitle || cache.passNight === night || want <= 0
    || (isFinalTick(now) && cache.touched === night);
  // Anahtar imleci: installs azalan, key artan sırada kaldığımız yerden devam eder. İmlecin gerisindeki satırlara bu
  // geçişte bir daha bakılmaz, o yüzden atlananlar (bilinen, çöp) skip'e yazılmaz; önbellek ve D1 okuması küçük kalır.
  for (let page = 0; !exhausted && page < MAX_PAGES && todo.length < want && looked < MAX_LOOK; page++) {
    const rows = await fetchPage(env, job, separate, cache.cursor);
    let stopped = false;
    for (const r of rows) {
      if (todo.length >= want || looked >= MAX_LOOK) { stopped = true; break; }
      cache.cursor = { n: r.installs, k: r.key };
      scanned++;
      if (cache.lines[r.key] || cache.skip[r.key]) continue;
      looked++;
      const clean = cleanLine(r.text);
      const k = clean ? (clean.labelled ? await key(clean.body) : r.key) : "";
      if (!clean || !k || isKnown(known, k) || isKnown(known, r.key)) continue;
      todo.push({ pool: r.key, k, en: clean.body });
    }
    // Sayfa dolu değilse ve hepsi işlendiyse imleç sona ulaştı: gezinti bitti, sonraki geçiş baştan başlar.
    if (!stopped && rows.length < PAGE) {
      exhausted = true;
      cache.cursor = null;
      cache.skip = Object.fromEntries(Object.entries(cache.skip).filter(([, v]) => v === 2));
      cache.passNight = night;
    }
  }

  if (todo.length > 0) {
    for (let i = 0; i < todo.length; i += BATCH) {
      const chunk = todo.slice(i, i + BATCH);
      const got = await translate(env, chunk, job.game);
      chunk.forEach((line, j) => {
        const tr = got.get(j);
        if (tr) {
          cache.lines[line.pool] = { k: line.k, en: line.en, tr };
          delete cache.fail[line.pool];
        } else if ((cache.fail[line.pool] = (cache.fail[line.pool] || 0) + 1) >= 2) {
          // İki kez çevrilemeyen satır bırakılır (sonsuz döngü olmasın). 2 = bu geçişte kalıcı atla.
          cache.skip[line.pool] = 2;
          delete cache.fail[line.pool];
        }
      });
    }
    state.translated += todo.length;
    job.did = (job.did ?? 0) + todo.length;
    cache.touched = night;
    await putJson(env, cacheFile(job), cache);
    await putJson(env, STATE, state);
    return { phase: "translate", titleId: job.titleId, game: job.gameKey, looked, translated: todo.length };
  }

  // Yeni çevrilecek satır çıkmadı ama gezinti sürüyor (önbellekte olanlar atlandı): imleci kaydet, paket kurma.
  if (!exhausted && scanned > 0 && cache.cursor) {
    await putJson(env, cacheFile(job), cache);
    return { phase: "scan", titleId: job.titleId, game: job.gameKey, scanned };
  }

  // Çevrilecek yeni satır kalmadı (ya da gecenin sınırı doldu): paket.
  const result = await buildPack(env, job, cache, known);
  state.queue.shift();
  state.done.push({ ...job, ...result });
  await putJson(env, STATE, state);
  return { phase: "build", titleId: job.titleId, game: job.gameKey, ...result };
}
