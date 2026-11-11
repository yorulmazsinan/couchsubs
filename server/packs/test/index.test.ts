// SPDX-License-Identifier: AGPL-3.0-only
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { handle, type Env, type R2BucketLike } from "../src/index";
import { JWKS_URL, resetKeyCache, verifyIdToken } from "../src/firebase";
import { isEntitlementActive } from "../src/revenuecat";

const PROJECT = "couchsubs-test";
let privateKey: CryptoKey;
let publicJwk: JsonWebKey;
const now = () => Math.floor(Date.now() / 1000);

function b64url(bytes: Uint8Array | string): string {
  const data = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let binary = "";
  for (const b of data) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function token(claims: Record<string, unknown> = {}, kid = "key-1"): Promise<string> {
  const t = now();
  const header = b64url(JSON.stringify({ alg: "RS256", kid, typ: "JWT" }));
  const payload = b64url(JSON.stringify({
    aud: PROJECT, iss: `https://securetoken.google.com/${PROJECT}`, sub: "uid-123", iat: t - 10, auth_time: t - 10, exp: t + 3600,
    ...claims,
  }));
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", privateKey, new TextEncoder().encode(`${header}.${payload}`));
  return `${header}.${payload}.${b64url(new Uint8Array(signature))}`;
}

/** Google anahtarları ve RevenueCat yanıtı. */
function fakeFetch(entitlement: unknown): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url === JWKS_URL) return new Response(JSON.stringify({ keys: [{ ...publicJwk, kid: "key-1", alg: "RS256", use: "sig" }] }), {
      headers: { "cache-control": "public, max-age=600" },
    });
    if (url.startsWith("https://api.revenuecat.com/v1/subscribers/")) {
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer rc-secret");
      if (entitlement === "error") return new Response("{}", { status: 500 });
      return new Response(JSON.stringify(entitlement));
    }
    throw new Error(`unexpected fetch ${url}`);
  }) as typeof fetch;
}

const index = { packs: [{ id: "gta-v", title: "GTA V", version: 3, sha256: "ab".repeat(32), size: 5, entries: 2 }] };

function bucket(): R2BucketLike {
  const files: Record<string, { data: Uint8Array; meta?: Record<string, string> }> = {
    "index.json": { data: new TextEncoder().encode(JSON.stringify(index)) },
    "packs/gta-v.json.gz": { data: new Uint8Array([0x1f, 0x8b, 1, 2, 3]), meta: { sha256: "ab".repeat(32) } },
  };
  return {
    async get(key) {
      const file = files[key];
      if (!file) return null;
      return {
        body: new Blob([file.data]).stream(),
        size: file.data.length,
        httpEtag: '"etag"',
        customMetadata: file.meta,
        text: async () => new TextDecoder().decode(file.data),
      };
    },
  };
}

const env = (): Env => ({ PACKS: bucket(), FIREBASE_PROJECT_ID: PROJECT, REVENUECAT_SECRET: "rc-secret" });
const active = { subscriber: { entitlements: { packs: { expires_date: new Date(Date.now() + 86400000).toISOString() } } } };
const expired = { subscriber: { entitlements: { packs: { expires_date: new Date(Date.now() - 86400000).toISOString() } } } };

beforeAll(async () => {
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["sign", "verify"],
  )) as CryptoKeyPair;
  privateKey = pair.privateKey;
  publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
});

beforeEach(() => resetKeyCache());

const get = (path: string, auth?: string) =>
  new Request(`https://packs.example${path}`, { headers: auth ? { authorization: `Bearer ${auth}` } : {} });

describe("GET /v1/packs", () => {
  it("lists packs without sign-in", async () => {
    const response = await handle(get("/v1/packs"), env(), fakeFetch(active));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(index);
  });
});

describe("GET /v1/packs/:id", () => {
  it("streams the pack to a subscriber", async () => {
    const response = await handle(get("/v1/packs/gta-v", await token()), env(), fakeFetch(active));
    expect(response.status).toBe(200);
    expect(response.headers.get("x-pack-sha256")).toBe("ab".repeat(32));
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array([0x1f, 0x8b, 1, 2, 3]));
  });

  it("needs a token", async () => {
    expect((await handle(get("/v1/packs/gta-v"), env(), fakeFetch(active))).status).toBe(401);
  });

  it("refuses an expired subscription", async () => {
    const response = await handle(get("/v1/packs/gta-v", await token()), env(), fakeFetch(expired));
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "subscription_required" });
  });

  it("reports RevenueCat outages as retryable", async () => {
    const response = await handle(get("/v1/packs/gta-v", await token()), env(), fakeFetch("error"));
    expect(response.status).toBe(503);
  });

  it("rejects unknown packs and odd ids", async () => {
    expect((await handle(get("/v1/packs/yok", await token()), env(), fakeFetch(active))).status).toBe(404);
    expect((await handle(get("/v1/packs/..%2Findex.json", await token()), env(), fakeFetch(active))).status).toBe(404);
  });
});

describe("verifyIdToken", () => {
  it("accepts a valid token", async () => {
    expect(await verifyIdToken(await token(), PROJECT, fakeFetch(active))).toEqual({ uid: "uid-123", email: undefined });
  });

  it.each([
    ["wrong audience", { aud: "other" }],
    ["wrong issuer", { iss: "https://securetoken.google.com/other" }],
    ["expired", { exp: Math.floor(Date.now() / 1000) - 3600 }],
    ["issued in the future", { iat: Math.floor(Date.now() / 1000) + 3600 }],
    ["empty subject", { sub: "" }],
  ])("rejects %s", async (_name, claims) => {
    await expect(verifyIdToken(await token(claims), PROJECT, fakeFetch(active))).rejects.toThrow();
  });

  it("rejects an unknown key and a forged signature", async () => {
    await expect(verifyIdToken(await token({}, "key-2"), PROJECT, fakeFetch(active))).rejects.toThrow("unknown_key");
    const [h, p] = (await token()).split(".");
    const forged = `${h}.${b64url(JSON.stringify({ ...JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/"))), sub: "someone-else" }))}.${(await token()).split(".")[2]}`;
    await expect(verifyIdToken(forged, PROJECT, fakeFetch(active))).rejects.toThrow("bad_signature");
  });
});

describe("isEntitlementActive", () => {
  const nowMs = Date.parse("2026-11-11T12:00:00Z");
  it("maps RevenueCat subscriber bodies", () => {
    expect(isEntitlementActive({ subscriber: { entitlements: { packs: { expires_date: "2026-12-01T00:00:00Z" } } } }, "packs", nowMs)).toBe(true);
    expect(isEntitlementActive({ subscriber: { entitlements: { packs: { expires_date: null } } } }, "packs", nowMs)).toBe(true);
    expect(isEntitlementActive({ subscriber: { entitlements: { packs: { expires_date: "2026-11-01T00:00:00Z" } } } }, "packs", nowMs)).toBe(false);
    expect(isEntitlementActive({
      subscriber: { entitlements: { packs: { expires_date: "2026-11-10T00:00:00Z", grace_period_expires_date: "2026-11-15T00:00:00Z" } } },
    }, "packs", nowMs)).toBe(true);
    expect(isEntitlementActive({ subscriber: { entitlements: {} } }, "packs", nowMs)).toBe(false);
    expect(isEntitlementActive(null, "packs", nowMs)).toBe(false);
  });
});
