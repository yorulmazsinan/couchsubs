// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, it } from "vitest";
import { handle, RateLimiter, RATE_LIMIT, type Env, type R2BucketLike } from "../src/index";

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
        httpEtag: '"etag-1"',
        customMetadata: file.meta,
        text: async () => new TextDecoder().decode(file.data),
      };
    },
  };
}

const env = (): Env => ({ PACKS: bucket() });
const get = (path: string, headers: Record<string, string> = {}) =>
  new Request(`https://packs.example${path}`, { headers: { "cf-connecting-ip": "203.0.113.7", ...headers } });

describe("GET /v1/packs", () => {
  it("lists packs", async () => {
    const response = await handle(get("/v1/packs"), env(), new RateLimiter());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, max-age=3600");
    expect(await response.json()).toEqual(index);
  });
});

describe("GET /v1/packs/:id", () => {
  it("streams the pack without sign-in", async () => {
    const response = await handle(get("/v1/packs/gta-v"), env(), new RateLimiter());
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/gzip");
    expect(response.headers.get("x-pack-sha256")).toBe("ab".repeat(32));
    expect(response.headers.get("cache-control")).toBe("public, max-age=86400");
    expect(response.headers.get("etag")).toBe('"etag-1"');
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array([0x1f, 0x8b, 1, 2, 3]));
  });

  it("answers 304 when the cached copy is current", async () => {
    const response = await handle(get("/v1/packs/gta-v", { "if-none-match": '"etag-1"' }), env(), new RateLimiter());
    expect(response.status).toBe(304);
  });

  it("rejects unknown packs and odd ids", async () => {
    expect((await handle(get("/v1/packs/yok"), env(), new RateLimiter())).status).toBe(404);
    expect((await handle(get("/v1/packs/..%2Findex.json"), env(), new RateLimiter())).status).toBe(404);
    expect((await handle(get("/v1/other"), env(), new RateLimiter())).status).toBe(404);
  });

  it("only allows GET", async () => {
    const response = await handle(new Request("https://packs.example/v1/packs", { method: "POST" }), env(), new RateLimiter());
    expect(response.status).toBe(405);
  });

  it("limits downloads per IP", async () => {
    const rate = new RateLimiter(2, 60_000);
    const now = 1_000_000;
    expect((await handle(get("/v1/packs/gta-v"), env(), rate, now)).status).toBe(200);
    expect((await handle(get("/v1/packs/gta-v"), env(), rate, now)).status).toBe(200);
    const limited = await handle(get("/v1/packs/gta-v"), env(), rate, now + 1000);
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toBe("59");
    // Başka IP etkilenmez; pencere dolunca yeniden açılır.
    expect((await handle(get("/v1/packs/gta-v", { "cf-connecting-ip": "198.51.100.1" }), env(), rate, now)).status).toBe(200);
    expect((await handle(get("/v1/packs/gta-v"), env(), rate, now + 60_000)).status).toBe(200);
    // Liste sınıra sayılmaz.
    expect((await handle(get("/v1/packs"), env(), rate, now + 60_001)).status).toBe(200);
  });
});

describe("RateLimiter", () => {
  it("defaults to a generous hourly limit", () => {
    const rate = new RateLimiter();
    for (let i = 0; i < RATE_LIMIT; i++) expect(rate.take("ip", 0)).toBeNull();
    expect(rate.take("ip", 0)).toBe(3600);
  });
});
