// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs game packs (Cloudflare Worker + R2). Telefon uygulaması aboneler için paketleri buradan indirir; masaüstü
// uygulamaları paketleri kendi içinde taşımaya devam eder (ücretsiz).
// GET /v1/packs     : paket listesi ve sürümleri (herkese açık; R2'deki index.json).
// GET /v1/packs/:id : paket dosyası (.json.gz). Firebase ID token ("Authorization: Bearer …") ve RevenueCat'te etkin
//                     "packs" hakkı gerekir.

import { TokenError, verifyIdToken } from "./firebase";
import { RevenueCatError, hasEntitlement } from "./revenuecat";

/** Kullandığımız kadarıyla R2 (Workers türlerine bağımlı kalmamak için). */
export interface R2ObjectLike {
  body: ReadableStream | null;
  size: number;
  httpEtag: string;
  customMetadata?: Record<string, string>;
  text(): Promise<string>;
}

export interface R2BucketLike {
  get(key: string): Promise<R2ObjectLike | null>;
}

export interface Env {
  PACKS: R2BucketLike;
  FIREBASE_PROJECT_ID: string;
  REVENUECAT_SECRET: string;
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

const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", ...extra } });

async function readIndex(env: Env): Promise<PackInfo[]> {
  const object = await env.PACKS.get("index.json");
  if (!object) return [];
  const parsed = JSON.parse(await object.text()) as { packs?: PackInfo[] };
  return parsed.packs ?? [];
}

async function list(env: Env): Promise<Response> {
  return json({ packs: await readIndex(env) }, 200, { "cache-control": "public, max-age=3600" });
}

async function download(request: Request, env: Env, id: string, fetcher: typeof fetch): Promise<Response> {
  if (!PACK_ID.test(id)) return json({ error: "not_found" }, 404);
  const token = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!token) return json({ error: "unauthorized" }, 401);
  let uid: string;
  try {
    uid = (await verifyIdToken(token, env.FIREBASE_PROJECT_ID, fetcher)).uid;
  } catch (error) {
    if (error instanceof TokenError) return json({ error: "unauthorized", reason: error.message }, 401);
    throw error;
  }
  let entitled: boolean;
  try {
    entitled = await hasEntitlement(uid, env.REVENUECAT_SECRET, fetcher);
  } catch (error) {
    if (error instanceof RevenueCatError) return json({ error: "entitlement_unavailable" }, 503, { "retry-after": "60" });
    throw error;
  }
  if (!entitled) return json({ error: "subscription_required" }, 403);

  const object = await env.PACKS.get(`packs/${id}.json.gz`);
  if (!object || !object.body) return json({ error: "not_found" }, 404);
  const headers: Record<string, string> = {
    "content-type": "application/gzip",
    "content-length": String(object.size),
    etag: object.httpEtag,
    // Dosya kullanıcıya özel izinle verilir; ara önbellekte paylaşılmaz.
    "cache-control": "private, no-store",
  };
  const sha = object.customMetadata?.sha256;
  if (sha) headers["x-pack-sha256"] = sha;
  return new Response(object.body, { status: 200, headers });
}

export async function handle(request: Request, env: Env, fetcher: typeof fetch = fetch): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  if (url.pathname === "/v1/packs") return list(env);
  const match = /^\/v1\/packs\/([^/]+)$/.exec(url.pathname);
  if (match) return download(request, env, decodeURIComponent(match[1]), fetcher);
  return json({ error: "not_found" }, 404);
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env).catch(() => json({ error: "internal" }, 500));
  },
};
