// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs game packs (Cloudflare Worker + R2). Paketler ücretsizdir: telefon uygulaması yeni ve güncellenen paketleri
// buradan indirir (uygulamayla gelenlerin üstüne). Hesap ya da giriş yoktur.
// GET /v1/packs     : paket listesi ve sürümleri (R2'deki index.json).
// GET /v1/packs/:id : paket dosyası (.json.gz), x-pack-sha256 başlığıyla.
// Kötüye kullanıma karşı IP başına basit sınır: saatte RATE_LIMIT indirme (Worker örneği başına, bellekte).

export interface R2ObjectLike {
  body: ReadableStream | null;
  size: number;
  httpEtag: string;
  customMetadata?: Record<string, string>;
  text(): Promise<string>;
}

export interface R2BucketLike {
  get(key: string, options?: { onlyIf?: { etagDoesNotMatch?: string } }): Promise<R2ObjectLike | null>;
}

export interface Env {
  PACKS: R2BucketLike;
}

export interface PackInfo {
  id: string;
  title: string;
  version: number;
  sha256: string;
  size: number;
  entries: number;
}

const PACK_ID = /^[a-z0-9][a-z0-9-]{0,63}$/;
const SHA256_HEX = /^[a-f0-9]{64}$/i;

/** Bozuk indeks girdileri istemcilerin kurulu paket kayıtlarını kaybetmesine neden olabilir. */
function validPack(value: unknown): value is PackInfo {
  if (!value || typeof value !== "object") return false;
  const pack = value as Record<string, unknown>;
  return typeof pack.id === "string" && PACK_ID.test(pack.id)
    && typeof pack.title === "string" && pack.title.trim().length > 0
    && Number.isSafeInteger(pack.version) && (pack.version as number) >= 0
    && typeof pack.sha256 === "string" && SHA256_HEX.test(pack.sha256)
    && Number.isSafeInteger(pack.size) && (pack.size as number) >= 0
    && Number.isSafeInteger(pack.entries) && (pack.entries as number) >= 0;
}

/** Bir IP'nin bir saatte indirebileceği paket dosyası (altı paketin tamamı birkaç kez sığar). */
export const RATE_LIMIT = 60;
const WINDOW_MS = 60 * 60 * 1000;

const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", ...extra } });

/** IP → bu penceredeki indirme sayısı. Örnek yeniden başlayınca sıfırlanır; amaç kaba kötüye kullanımı kesmek. */
export class RateLimiter {
  private readonly hits = new Map<string, { count: number; since: number }>();

  constructor(private readonly limit = RATE_LIMIT, private readonly windowMs = WINDOW_MS) {}

  /** İzin verilirse null, yoksa kaç saniye sonra yeniden denenebileceği. */
  take(ip: string, now: number): number | null {
    let entry = this.hits.get(ip);
    if (!entry || now - entry.since >= this.windowMs) {
      entry = { count: 0, since: now };
      this.hits.set(ip, entry);
    }
    if (entry.count >= this.limit) return Math.ceil((entry.since + this.windowMs - now) / 1000);
    entry.count++;
    // Bellek büyümesin: çok IP birikirse süresi geçenler atılır.
    if (this.hits.size > 10_000) for (const [key, value] of this.hits) if (now - value.since >= this.windowMs) this.hits.delete(key);
    return null;
  }
}

const limiter = new RateLimiter();

async function readIndex(env: Env): Promise<PackInfo[] | null> {
  try {
    const object = await env.PACKS.get("index.json");
    if (!object) return null;
    const parsed = JSON.parse(await object.text()) as { packs?: unknown };
    if (!Array.isArray(parsed?.packs) || !parsed.packs.every(validPack)) return null;
    // Aynı kimliğin birden çok sürümü, istemcinin hangi paketi indireceğini belirsizleştirir.
    if (new Set(parsed.packs.map((pack: PackInfo) => pack.id)).size !== parsed.packs.length) return null;
    return parsed.packs;
  } catch {
    return null;
  }
}

async function list(env: Env): Promise<Response> {
  const packs = await readIndex(env);
  // Eksik/bozuk index başarıyla boş liste gibi gönderilirse istemciler kurulu paketleri silebilir.
  if (packs === null) return json({ error: "index_unavailable" }, 503, { "cache-control": "no-store" });
  return json({ packs }, 200, { "cache-control": "public, max-age=300" });
}

async function download(request: Request, env: Env, id: string, rate: RateLimiter, now: number): Promise<Response> {
  if (!PACK_ID.test(id)) return json({ error: "not_found" }, 404);
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const retry = rate.take(ip, now);
  if (retry !== null) return json({ error: "rate_limited" }, 429, { "retry-after": String(retry) });

  const object = await env.PACKS.get(`packs/${id}.json.gz`);
  if (!object || !object.body) return json({ error: "not_found" }, 404);
  const headers: Record<string, string> = {
    "content-type": "application/gzip",
    "content-length": String(object.size),
    etag: object.httpEtag,
    // Havuzdan otomatik paketler her gece değişebilir: önbellek her seferinde ETag ile sorar (değişmediyse 304), eski
    // dosya listedeki yeni SHA-256'ya takılmaz.
    "cache-control": "public, no-cache",
  };
  const sha = object.customMetadata?.sha256;
  if (sha) headers["x-pack-sha256"] = sha;
  // If-None-Match zayıf ETag, virgülle ayrılmış liste veya mevcut kaynak için * içerebilir.
  const condition = request.headers.get("if-none-match");
  const matches = condition?.split(",").some((value) => {
    const tag = value.trim();
    return tag === "*" || tag.replace(/^W\//, "") === object.httpEtag;
  });
  if (matches) return new Response(null, { status: 304, headers });
  return new Response(object.body, { status: 200, headers });
}

export async function handle(request: Request, env: Env, rate: RateLimiter = limiter, now: number = Date.now()): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  if (url.pathname === "/v1/packs") return list(env);
  const match = /^\/v1\/packs\/([^/]+)$/.exec(url.pathname);
  if (match) {
    let id: string;
    try { id = decodeURIComponent(match[1]); }
    catch { return json({ error: "not_found" }, 404); }
    return download(request, env, id, rate, now);
  }
  return json({ error: "not_found" }, 404);
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env).catch(() => json({ error: "internal" }, 500));
  },
};
