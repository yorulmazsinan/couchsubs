import assert from "node:assert/strict";
import test from "node:test";
import {
  GENERAL, GENERAL_TITLE, JOB_NIGHTLY, LAST_HOUR_UTC, LINES_PER_RUN, NIGHTLY_LIMIT, PAGE, isFinalTick, jobPackId,
  computeStats, packBody, packTitle, parseReply, runAutopack,
  CLAUDE_LIMITS, CLAUDE_MODEL, CLAUDE_URL, limitsFor, translateClaude,
} from "../src/autopack.js";

test("malformed current-night state is rebuilt instead of stopping the scheduler", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  for (const invalid of [
    { night: "2026-11-20", translated: 0, done: [] },
    { night: "2026-11-20", queue: {}, translated: 0, done: [] },
    { night: "2026-11-20", queue: [], translated: -1, done: [] },
  ]) {
    const stored = new Map([
      ["auto/state.json", JSON.stringify(invalid)],
      ["index.json", JSON.stringify({ packs: [] })],
    ]);
    const env = {
      AI: {},
      PACKS: {
        get: async (name) => stored.has(name) ? { text: async () => stored.get(name) } : null,
        put: async (name, value) => { stored.set(name, value); },
      },
      DB: {
        prepare: () => ({
          bind: () => ({
            all: async () => ({ results: [] }),
            first: async () => ({ lines: 0 }),
          }),
        }),
      },
    };
    const result = await runAutopack(env, now);
    assert.equal(result.phase, "plan");
    assert.deepEqual(JSON.parse(stored.get("auto/state.json")).queue, []);
  }
});

test("general pool scans past separated game rows before applying the row limit", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  const state = {
    night: now.toISOString().slice(0, 10),
    queue: [{ titleId: GENERAL, game: null, lines: 350 }],
    namedGames: ["GTA 6"],
    translated: 0,
    done: [{ titleId: null, gameKey: "gta 6", game: "GTA 6", games: ["GTA 6"], built: true }],
  };
  const stored = new Map([
    ["auto/state.json", JSON.stringify(state)],
    ["index.json", JSON.stringify({ packs: [] })],
  ]);
  const rows = [
    ...Array.from({ length: 5_001 }, (_, i) => ({
      key: (0x1000000000000000n + BigInt(i)).toString(16).padStart(16, "0"),
      text: "Get in the car, Lucia.",
      game: "GTA 6",
      installs: 10,
      last_seen: "2026-11-20T03:00:00.000Z",
    })),
    ...Array.from({ length: 350 }, (_, i) => ({
      key: (0x2000000000000000n + BigInt(i)).toString(16).padStart(16, "0"),
      text: "Get in the car, Lucia.",
      game: null,
      installs: 2,
      last_seen: "2026-11-20T02:00:00.000Z",
    })),
  ];
  let generalQuery;
  const env = {
    AI: {
      run: async (_model, { messages }) => {
        const count = messages[1].content.split("\n").filter(Boolean).length;
        return {
          response: JSON.stringify({
            items: Array.from({ length: count }, (_, i) => ({ id: String(i), tr: "Arabaya bin, Lucia." })),
          }),
        };
      },
    },
    PACKS: {
      get: async (name) => name === "auto/known-keys.bin"
        ? { arrayBuffer: async () => new ArrayBuffer(0) }
        : stored.has(name) ? { text: async () => stored.get(name) } : null,
      put: async (name, value) => { stored.set(name, value); },
    },
    DB: {
      prepare: (sql) => ({
        bind: (...args) => ({
          all: async () => {
            generalQuery = { sql, args };
            const separated = sql.includes("json_each(?)") ? JSON.parse(args[1]) : [];
            const eligible = rows.filter((row) => !row.game || !separated.includes(row.game));
            eligible.sort((a, b) => b.installs - a.installs || (a.key < b.key ? -1 : 1));
            return { results: eligible.slice(0, 1_500) };
          },
        }),
      }),
    },
  };

  const result = await runAutopack(env, now);

  assert.equal(result.phase, "translate");
  assert.equal(result.looked, 200);
  assert.equal(result.translated, 200);
  assert.match(generalQuery.sql, /json_each\(\?\)/);
  assert.deepEqual(generalQuery.args, [2, JSON.stringify(["GTA 6"])]);
  const cache = JSON.parse(stored.get("auto/tr/GENEL.json"));
  const translatedKeys = Object.keys(cache.lines);
  assert.equal(translatedKeys.length, 200);
  assert.ok(translatedKeys.every((key) => key.startsWith("2")));
});


test("AI parser ignores malformed item collections and IDs without misassigning subtitles", async () => {

  const lines = [{ en: "Where are you going?" }, { en: "We have to leave now." }];
  for (const items of [null, {}, 42, true]) {
    const reply = { response: JSON.stringify({ items }) };
    assert.deepEqual([...parseReply(reply, lines)], [], `malformed items: ${JSON.stringify(items)}`);
  }
  for (const id of [null, "", " ", true, false, {}, -1, 1.5, "0abc"]) {
    const reply = { response: JSON.stringify({ items: [{ id, tr: "Yanlış satıra yazılmamalı." }] }) };
    assert.deepEqual([...parseReply(reply, lines)], [], `invalid id: ${JSON.stringify(id)}`);
  }
  const valid = { response: JSON.stringify({ items: [{ id: "0", tr: "Nereye gidiyorsun?" }, { id: 1, tr: "Hemen gitmeliyiz." }] }) };
  assert.deepEqual([...parseReply(valid, lines)], [[0, "Nereye gidiyorsun?"], [1, "Hemen gitmeliyiz."]]);
});

test("autopack never replaces an absent or unreadable pack index", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  const job = { titleId: GENERAL, game: null, lines: 350 };
  const cache = {
    lines: Object.fromEntries(Array.from({ length: 300 }, (_, i) => {
      const k = (BigInt(i) + 1n).toString(16).padStart(16, "0");
      return [k, { k, en: "Get in the car, Lucia.", tr: "Arabaya bin, Lucia." }];
    })),
    skip: {}, fail: {},
  };
  for (const rawIndex of [
    null, "{broken json", JSON.stringify({ packs: null }),
    JSON.stringify({ packs: [
      { id: "pool-genel", version: 1 },
      { id: "pool-genel", version: 2 },
    ] }),
    JSON.stringify({ packs: [null] }),
  ]) {
    const state = { night: "2026-11-20", queue: [job], translated: 0, done: [] };
    const stored = new Map([
      ["auto/state.json", JSON.stringify(state)],
      ["auto/tr/GENEL.json", JSON.stringify(cache)],
    ]);
    if (rawIndex !== null) stored.set("index.json", rawIndex);
    const writes = [];
    const env = {
      AI: {},
      PACKS: {
        get: async (name) => name === "auto/known-keys.bin"
          ? { arrayBuffer: async () => new ArrayBuffer(0) }
          : stored.has(name) ? { text: async () => stored.get(name) } : null,
        put: async (name, value) => { writes.push(name); stored.set(name, value); },
      },
      DB: {
        prepare: () => ({ bind: () => ({ all: async () => ({ results: [] }) }) }),
      },
    };

    await assert.rejects(runAutopack(env, now), /index.*(missing|invalid|unavailable)/i);
    assert.deepEqual(writes, [], `index was ${rawIndex}: no package or index may be overwritten`);
    assert.deepEqual(JSON.parse(stored.get("auto/state.json")), state);
  }
});

test("autopack must not publish an empty pack when an existing translation cache is corrupted", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  const state = {
    night: "2026-11-20",
    queue: [{ titleId: GENERAL, game: null, lines: 350 }],
    translated: 0, done: [],
  };
  for (const cacheRaw of [
    "{broken", JSON.stringify({ lines: [], skip: {} }), JSON.stringify({ lines: null, skip: {} }),
    JSON.stringify({ lines: { "1111111111111111": null }, skip: {} }),
    JSON.stringify({ lines: { "1111111111111111": { k: "not-a-hash", en: "We must leave now.", tr: "?imdi gitmeliyiz." } }, skip: {} }),
  ]) {
    const stored = new Map([
      ["auto/state.json", JSON.stringify(state)],
      ["index.json", JSON.stringify({ packs: [{ id: "pool-genel", version: 1 }] })],
      ["auto/tr/GENEL.json", cacheRaw],
    ]);
    const writes = [];
    const env = {
      AI: {},
      PACKS: {
        get: async (name) => name === "auto/known-keys.bin"
          ? { arrayBuffer: async () => new ArrayBuffer(0) }
          : stored.has(name) ? { text: async () => stored.get(name) } : null,
        put: async (name, value) => { writes.push(name); stored.set(name, value); },
      },
      DB: {
        prepare: () => ({ bind: () => ({ all: async () => ({ results: [] }) }) }),
      },
    };
    const result = await runAutopack(env, now);
    assert.equal(result.phase, "waiting");
    assert.deepEqual(writes, [], "corrupt cache must not cause pack or index writes");
    assert.deepEqual(JSON.parse(stored.get("auto/state.json")), state);
  }
});

test("autopack waits rather than using a truncated manual-key index", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  const state = {
    night: "2026-11-20",
    queue: [{ titleId: GENERAL, game: null, lines: 350 }],
    translated: 0, done: [],
  };
  const malformed = [new Uint8Array(9).buffer];
  for (const bytes of malformed) {
    const stored = new Map([["auto/state.json", JSON.stringify(state)]]);
    const writes = [];
    const env = {
      AI: {},
      PACKS: {
        get: async (name) => name === "auto/known-keys.bin"
          ? { arrayBuffer: async () => bytes }
          : stored.has(name) ? { text: async () => stored.get(name) } : null,
        put: async (name, value) => { writes.push(name); stored.set(name, value); },
      },
      DB: {
        prepare: () => ({ bind: () => ({ all: async () => ({ results: [] }) }) }),
      },
    };
    const result = await runAutopack(env, now);
    assert.equal(result.phase, "waiting");
    assert.deepEqual(writes, []);
    assert.deepEqual(JSON.parse(stored.get("auto/state.json")), state);
  }
});

test("autopack preserves published translations when their R2 cache is missing", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  const state = { night: "2026-11-20", queue: [{ titleId: GENERAL, game: null, lines: 350 }], translated: 0, done: [] };
  const index = { packs: [{ id: "pool-genel", version: 4, entries: 350, sha256: "a".repeat(64) }] };
  const stored = new Map([
    ["auto/state.json", JSON.stringify(state)],
    ["index.json", JSON.stringify(index)],
    // A previous cache may disappear independently from the published pack in R2.
  ]);
  const writes = [];
  const env = {
    AI: {},
    PACKS: {
      get: async (name) => name === "auto/known-keys.bin"
        ? { arrayBuffer: async () => new ArrayBuffer(0) }
        : stored.has(name) ? { text: async () => stored.get(name) } : null,
      put: async (name, data) => { writes.push(name); stored.set(name, data); },
    },
    DB: { prepare: () => ({ bind: () => ({ all: async () => ({ results: [] }) }) }) },
  };

  const result = await runAutopack(env, now);
  assert.equal(result.phase, "waiting", "missing cache cannot be treated as an empty existing pack");
  assert.deepEqual(writes, [], "neither the existing pack nor its index may be overwritten");
  assert.deepEqual(JSON.parse(stored.get("index.json")), index);
  assert.deepEqual(JSON.parse(stored.get("auto/state.json")), state);
});

test("general fallback is scheduled while a voted game has not published its first pack", async () => {
  const stored = new Map([["index.json", JSON.stringify({ packs: [] })]]);
  const env = {
    PACKS: {
      get: async (path) => stored.has(path) ? { text: async () => stored.get(path) } : null,
      put: async (path, value) => { stored.set(path, value); },
    },
    AI: {},
    DB: {
      prepare: (sql) => ({
        bind: () => ({
          all: async () => ({
            results: sql.includes("FROM game_votes")
              ? [{ game_key: "named game", installs: 2 }]
              : sql.includes("GROUP BY game")
                ? [{ game: "Named Game", lines: 350 }]
                : [],
          }),
          first: async () => ({ lines: 350 }),
        }),
      }),
    },
  };
  const plan = await runAutopack(env, new Date("2026-11-20T03:07:00Z"));
  assert.equal(plan.phase, "plan");
  const state = JSON.parse(stored.get("auto/state.json"));
  assert.deepEqual(state.queue.map((job) => job.titleId ?? job.gameKey),
    ["named game", GENERAL], "the general job must remain queued until named publication succeeds");
});

test("general fallback includes named-game subtitles if that game's pack did not publish", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  const named = "Named Game";
  const stored = new Map([
    ["index.json", JSON.stringify({ packs: [] })],
    ["auto/state.json", JSON.stringify({
      night: "2026-11-20", queue: [{ titleId: GENERAL, game: null, lines: 350 }],
      namedGames: [named],
      done: [{ titleId: null, gameKey: "named game", game: named, games: [named], built: false, entries: 100 }],
      translated: 0,
    })],
  ]);
  const rows = [
    { key: "1111111111111111", text: "We must leave the tower before dawn.", game: named },
    { key: "2222222222222222", text: "We should finish the mission tonight.", game: null },
  ];
  let query;
  const env = {
    PACKS: {
      get: async (name) => name === "auto/known-keys.bin"
        ? { arrayBuffer: async () => new ArrayBuffer(0) }
        : stored.has(name) ? { text: async () => stored.get(name) } : null,
      put: async (name, value) => { stored.set(name, value); },
    },
    AI: {
      run: async (_model, { messages }) => ({
        response: JSON.stringify({
          items: messages[1].content.split("\n").filter(Boolean)
            .map((_, index) => ({ id: String(index), tr: "Bu ak?am g?revimizi bitirmeliyiz." })),
        }),
      }),
    },
    DB: {
      prepare: (sql) => ({
        bind: (...args) => ({
          all: async () => {
            query = { sql, args };
            const excluded = sql.includes("json_each(?)") ? JSON.parse(args[1]) : [];
            return { results: rows.filter((row) => !excluded.includes(row.game)) };
          },
        }),
      }),
    },
  };
  const result = await runAutopack(env, now);
  assert.equal(result.phase, "translate");
  assert.equal(result.translated, 2, "named lines should fall back when their own pack was not built");
  const cache = JSON.parse(stored.get("auto/tr/GENEL.json"));
  assert.deepEqual(Object.keys(cache.lines).sort(), rows.map((row) => row.key).sort());
});

test("long ASCII game names keep separate translation caches when their pack IDs differ", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  const shared = "the exceptionally long game title that shares a lengthy prefix ";
  const games = [shared + "alpha", shared + "beta"];
  const jobs = games.map((gameKey) => ({
    titleId: null, gameKey, game: gameKey, games: [gameKey], lines: 301,
  }));
  assert.notEqual(jobPackId(jobs[0]), jobPackId(jobs[1]));

  const stored = new Map([["index.json", JSON.stringify({ packs: [] })]]);
  const env = {
    PACKS: {
      get: async (name) => name === "auto/known-keys.bin"
        ? { arrayBuffer: async () => new ArrayBuffer(0) }
        : stored.has(name) ? { text: async () => stored.get(name) } : null,
      put: async (name, value) => { stored.set(name, value); },
    },
    AI: {
      run: async () => ({ response: JSON.stringify({ items: [{ id: "0", tr: "Hemen kap?ya ilerlemeliyiz." }] }) }),
    },
    DB: {
      prepare: () => ({
        bind: (...args) => ({
          all: async () => ({ results: [{
            key: args[0] === games[0] ? "1111111111111111" : "2222222222222222",
            text: "We must get to the gate right now.",
          }] }),
        }),
      }),
    },
  };
  for (const job of jobs) {
    stored.set("auto/state.json", JSON.stringify({
      night: "2026-11-20", queue: [job], namedGames: [job.game],
      translated: 0, done: [],
    }));
    const result = await runAutopack(env, now);
    assert.equal(result.phase, "translate");
    assert.equal(result.translated, 1);
  }
  const cacheFiles = [...stored.keys()].filter((name) => name.startsWith("auto/tr/name-"));
  assert.equal(cacheFiles.length, 2, "distinct published pack IDs must not share a translation cache");
  const cachedKeys = cacheFiles.map((name) => Object.keys(JSON.parse(stored.get(name)).lines));
  assert.deepEqual(cachedKeys.map((keys) => keys.length), [1, 1]);
});

test("unchanged cache re-publishes a pack whose R2 object disappeared", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  const k = "1111111111111111";
  const cache = { lines: { [k]: { k, en: "We need to leave right now.", tr: "Hemen gitmemiz gerekiyor." } }, skip: {}, fail: {} };
  const content = packBody("pool-genel", GENERAL_TITLE, cache, new BigUint64Array(), null).body;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(content));
  cache.contentSha = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const stored = new Map([
    ["auto/state.json", JSON.stringify({ night: "2026-11-20", queue: [{ titleId: GENERAL, game: null, lines: 350 }], translated: 0, done: [] })],
    ["auto/tr/GENEL.json", JSON.stringify(cache)],
    ["index.json", JSON.stringify({ packs: [{ id: "pool-genel", title: GENERAL_TITLE, version: 4 }] })],
  ]);
  const written = [];
  const env = {
    AI: {},
    PACKS: {
      get: async (name) => name === "auto/known-keys.bin"
        ? { arrayBuffer: async () => new ArrayBuffer(0) }
        : stored.has(name) ? { text: async () => stored.get(name) } : null,
      head: async (name) => stored.has(name) ? { key: name } : null,
      put: async (name, data) => { written.push(name); stored.set(name, data); },
    },
    DB: { prepare: () => ({ bind: () => ({ all: async () => ({ results: [] }) }) }) },
  };
  const outcome = await runAutopack(env, now);
  assert.equal(outcome.phase, "build");
  assert.equal(outcome.built, true, "pack must be re-published even when its input hash has not changed");
  assert.equal(outcome.version, 5);
  assert.ok(written.includes("packs/pool-genel.json.gz"));
  assert.equal(JSON.parse(stored.get("index.json")).packs[0].version, 5);

  // A later run with a real pack object and the same cache must remain unchanged.
  stored.set("auto/state.json", JSON.stringify({
    night: "2026-11-20", queue: [{ titleId: GENERAL, game: null, lines: 350 }],
    translated: 0, done: [],
  }));
  written.length = 0;
  const again = await runAutopack(env, now);
  assert.equal(again.unchanged, true, "existing package must retain normal no-op behavior");
  assert.equal(again.built, false);
  assert.equal(written.includes("packs/pool-genel.json.gz"), false);
  assert.equal(JSON.parse(stored.get("index.json")).packs[0].version, 5);
});

test("duplicate AI item IDs cannot overwrite a subtitle with an ambiguous translation", () => {
  const items = [{ en: "The gates are closing now." }, { en: "We have to leave immediately." }];
  const reply = { response: JSON.stringify({ items: [
    { id: "0", tr: "Kap?lar ?imdi kapan?yor." },
    { id: 0, tr: "Hemen gitmeliyiz." },
    { id: "1", tr: "Derhal ayr?lmam?z gerekiyor." },
  ] }) };
  assert.deepEqual([...parseReply(reply, items)],
    [[1, "Derhal ayr?lmam?z gerekiyor."]],
    "duplicated IDs must be discarded, leaving the independent translation untouched");
});

test("extra pool pack is titled '(ek satırlar)' only while the game's main pack is listed", () => {
  const spider = { titleId: null, gameKey: "marvels spider man 2", game: "Marvel's Spider-Man 2" };
  const main = { id: "marvels-spider-man-2", title: "Marvel’s Spider-Man 2", version: 1 };
  const own = { id: "pool-marvels-spider-man-2", title: "Marvel's Spider-Man 2", version: 2, auto: true };
  assert.equal(packTitle(spider, [main, own]), "Marvel's Spider-Man 2 (ek satırlar)");
  // Asıl paket yoksa ad aynı kalır: elle seçim bu paketi adıyla bulmaya devam etmeli.
  assert.equal(packTitle(spider, [own]), "Marvel's Spider-Man 2");
  // Başka bir otomatik paket asıl paket sayılmaz.
  assert.equal(packTitle(spider, [{ ...main, id: "pool-other", auto: true }, own]), "Marvel's Spider-Man 2");
  // Adın yazımı farklı olsa da anahtar aynıysa (Roma rakamı, kısaltma) asıl pakettir.
  const rdr = { titleId: null, gameKey: "rdr 2", game: "Red Dead Redemption II" };
  assert.equal(packTitle(rdr, [{ id: "red-dead-redemption-2", title: "Red Dead Redemption 2" }]),
    "Red Dead Redemption II (ek satırlar)");
  // Kimlikle toplanan paket: asıl paketin titleId'si de yeter.
  const byId = { titleId: "PPSA01234", game: "Some Game", lines: 400 };
  assert.equal(packTitle(byId, [{ id: "some-other-name", title: "Başka Ad", titleId: "PPSA01234" }]), "Some Game (ek satırlar)");
  assert.equal(packTitle(byId, []), "Some Game");
  assert.equal(packTitle({ titleId: GENERAL, game: null }, [main]), GENERAL_TITLE);
});

test("unchanged extra pack is re-published with the new title once its main pack is listed", async () => {
  const now = new Date("2026-11-20T04:00:00Z");
  const job = { titleId: null, gameKey: "rdr 2", game: "Red Dead Redemption 2", games: ["Red Dead Redemption 2"], lines: 500 };
  const id = jobPackId(job);
  const k = "1111111111111111";
  const cache = { lines: { [k]: { k, en: "We need to leave right now.", tr: "Hemen gitmemiz gerekiyor." } }, skip: {}, fail: {} };
  // Önbellek, eski (eksiz) adla yazılmış paketin özetini taşıyor.
  const content = packBody(id, "Red Dead Redemption 2", cache, new BigUint64Array(), null).body;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(content));
  cache.contentSha = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const stored = new Map([
    ["auto/state.json", JSON.stringify({ night: "2026-11-20", queue: [job], translated: 0, done: [] })],
    ["auto/tr/name-rdr-2.json", JSON.stringify(cache)],
    [`packs/${id}.json.gz`, "old"],
    ["index.json", JSON.stringify({ packs: [
      { id, title: "Red Dead Redemption 2", version: 1, auto: true, game: "rdr 2" },
      { id: "red-dead-redemption-2", title: "Red Dead Redemption 2", version: 1 },
    ] })],
  ]);
  const env = {
    AI: {},
    PACKS: {
      get: async (name) => name === "auto/known-keys.bin"
        ? { arrayBuffer: async () => new ArrayBuffer(0) }
        : stored.has(name) ? { text: async () => stored.get(name) } : null,
      head: async (name) => stored.has(name) ? { key: name } : null,
      put: async (name, data) => { stored.set(name, data); },
    },
    DB: { prepare: () => ({ bind: () => ({ all: async () => ({ results: [] }) }) }) },
  };
  const outcome = await runAutopack(env, now);
  assert.equal(outcome.phase, "build");
  assert.equal(outcome.built, true);
  const packs = JSON.parse(stored.get("index.json")).packs;
  const extra = packs.find((p) => p.id === id);
  assert.equal(extra.title, "Red Dead Redemption 2 (ek satırlar)");
  assert.equal(extra.version, 2);
  assert.equal(packs.find((p) => p.id === "red-dead-redemption-2").title, "Red Dead Redemption 2");
});

test("night plan retitles a listed extra pack first, without translating", async () => {
  const id = "pool-rdr-2";
  const k = "1111111111111111";
  const cache = { lines: { [k]: { k, en: "We need to leave right now.", tr: "Hemen gitmemiz gerekiyor." } }, skip: {}, fail: {} };
  const content = packBody(id, "Red Dead Redemption 2", cache, new BigUint64Array(), null).body;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(content));
  cache.contentSha = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const stored = new Map([
    ["auto/tr/name-rdr-2.json", JSON.stringify(cache)],
    [`packs/${id}.json.gz`, "old"],
    ["index.json", JSON.stringify({ packs: [
      { id: "pool-gta-6", title: "Grand Theft Auto VI", version: 3, auto: true, game: "gta 6" },
      { id, title: "Red Dead Redemption 2", version: 1, auto: true, game: "rdr 2" },
      { id: "red-dead-redemption-2", title: "Red Dead Redemption 2", version: 1 },
    ] })],
  ]);
  const env = {
    AI: { run: async () => { throw new Error("retitle must not translate"); } },
    PACKS: {
      get: async (name) => name === "auto/known-keys.bin"
        ? { arrayBuffer: async () => new ArrayBuffer(0) }
        : stored.has(name) ? { text: async () => stored.get(name) } : null,
      head: async (name) => stored.has(name) ? { key: name } : null,
      put: async (name, data) => { stored.set(name, data); },
    },
    DB: {
      prepare: (sql) => ({
        bind: () => ({
          all: async () => {
            if (sql.includes("game_votes")) return { results: [{ game_key: "gta 6", installs: 5 }, { game_key: "rdr 2", installs: 5 }] };
            if (sql.includes("GROUP BY game ")) {
              return { results: [{ game: "Grand Theft Auto VI", lines: 90000 }, { game: "Red Dead Redemption 2", lines: 7533 }] };
            }
            if (sql.includes("GROUP BY title_id")) return { results: [] };
            throw new Error("unexpected rows query: " + sql);
          },
          first: async () => ({ lines: 10 }),
        }),
      }),
    },
  };
  const now = new Date("2026-11-20T03:07:00Z");
  const plan = await runAutopack(env, now);
  assert.equal(plan.phase, "plan");
  const state = JSON.parse(stored.get("auto/state.json"));
  assert.deepEqual(state.queue.map((q) => [q.gameKey ?? q.titleId, q.retitle === true]),
    [["rdr 2", true], ["gta 6", false]]);
  const step = await runAutopack(env, now);
  assert.equal(step.phase, "build");
  assert.equal(step.built, true);
  const extra = JSON.parse(stored.get("index.json")).packs.find((p) => p.id === id);
  assert.equal(extra.title, "Red Dead Redemption 2 (ek satırlar)");
  // Ertesi gece ad zaten doğru: yeniden yazma sırası açılmaz.
  await runAutopack(env, new Date("2026-11-21T03:07:00Z"));
  assert.equal(JSON.parse(stored.get("auto/state.json")).queue.some((q) => q.retitle), false);
});


// --- Sayfa sayfa gezinti, gecelik pay, her gece büyüyen paket ---

const hex = (i) => (0x3000000000000000n + BigInt(i)).toString(16).padStart(16, "0");
const lineText = (i) => `Get in the car number ${i}, Lucia.`;

/** Anahtar imlecini anlayan sahte D1 + R2. rows: { key, text, installs }. */
function pagedEnv({ rows, state, cache, packs = [], queries = [] }) {
  const stored = new Map([["index.json", JSON.stringify({ packs })]]);
  if (state) stored.set("auto/state.json", JSON.stringify(state));
  if (cache) stored.set("auto/tr/PPSA1.json", JSON.stringify(cache));
  const env = {
    AI: {
      run: async (_model, { messages }) => ({
        response: JSON.stringify({
          items: messages[1].content.split("\n").filter(Boolean).map((_, i) => ({ id: String(i), tr: "Arabaya bin, Lucia." })),
        }),
      }),
    },
    PACKS: {
      get: async (name) => name === "auto/known-keys.bin"
        ? { arrayBuffer: async () => new ArrayBuffer(0) }
        : stored.has(name) ? {
          text: async () => String(stored.get(name)),
          arrayBuffer: async () => stored.get(name),
        } : null,
      head: async (name) => stored.has(name) ? {} : null,
      put: async (name, value) => { stored.set(name, value); },
    },
    DB: {
      prepare: (sql) => ({
        bind: (...args) => ({
          all: async () => {
            queries.push({ sql, args });
            const cursor = sql.includes("installs<?") ? args.slice(-3) : null;
            const eligible = rows
              .filter((r) => !cursor || r.installs < cursor[0] || (r.installs === cursor[1] && r.key > cursor[2]))
              .sort((a, b) => b.installs - a.installs || (a.key < b.key ? -1 : 1));
            return { results: eligible.slice(0, PAGE) };
          },
        }),
      }),
    },
  };
  return { env, stored };
}

const bigRows = (n) => Array.from({ length: n }, (_, i) => ({ key: hex(i), text: lineText(i), installs: 2 + (i % 3) }));
const titledState = (extra = {}) => ({
  night: "2026-11-20", translated: 0, done: [], namedGames: [],
  queue: [{ titleId: "PPSA1", game: "Test Oyunu", lines: 9000, ...extra }],
});

test("big game is paged by key cursor: each run continues where the last stopped, nothing is translated twice", async () => {
  const queries = [];
  const { env, stored } = pagedEnv({ rows: bigRows(4000), state: titledState(), queries });
  const now = new Date("2026-11-20T03:12:00Z");
  const seen = new Set();
  for (let run = 0; run < 3; run++) {
    const result = await runAutopack(env, now);
    assert.equal(result.phase, "translate");
    assert.equal(result.translated, LINES_PER_RUN);
    for (const k of Object.keys(JSON.parse(stored.get("auto/tr/PPSA1.json")).lines)) seen.add(k);
    assert.equal(seen.size, (run + 1) * LINES_PER_RUN);
  }
  assert.equal(JSON.parse(stored.get("auto/state.json")).translated, 3 * LINES_PER_RUN);
  // İlk sorgu imleçsiz, sonrakiler imleçle; sorgu sınırı sabit sayfa (ilk-5000 penceresi yok).
  assert.ok(!queries[0].sql.includes("installs<?"));
  assert.ok(queries.slice(1).every((q) => q.sql.includes("installs<?")));
  assert.ok(queries.every((q) => q.sql.includes(`LIMIT ${PAGE}`)));
  const cache = JSON.parse(stored.get("auto/tr/PPSA1.json"));
  assert.ok(cache.cursor && typeof cache.cursor.k === "string");
  // Çöp ve bilinen satırlar skip'e yazılmaz (imleç zaten geride bırakır): önbellek küçük kalır.
  assert.equal(Object.keys(cache.skip).length, 0);
});

test("rows past the first window are reached: cursor goes beyond 5000 rows", async () => {
  // 7000 satır, ilk 6800'ü zaten çevrilmiş: eski sürüm yalnız ilk 5000'e bakıp "bitti" derdi.
  const rows = bigRows(7000);
  const ordered = [...rows].sort((a, b) => b.installs - a.installs || (a.key < b.key ? -1 : 1));
  const lines = {};
  for (const r of ordered.slice(0, 6800)) lines[r.key] = { k: r.key, en: r.text, tr: "Arabaya bin, Lucia." };
  const { env, stored } = pagedEnv({ rows, state: titledState(), cache: { lines, skip: {}, fail: {} } });
  const now = new Date("2026-11-20T03:12:00Z");
  let translated = 0;
  for (let run = 0; run < 6 && translated < 200; run++) {
    const result = await runAutopack(env, now);
    if (result.phase === "translate") translated += result.translated;
  }
  assert.equal(translated, 200);
  const cache = JSON.parse(stored.get("auto/tr/PPSA1.json"));
  const fresh = Object.keys(cache.lines).filter((k) => !(k in lines));
  assert.equal(fresh.length, 200);
  const tail = new Set(ordered.slice(6800).map((r) => r.key));
  assert.ok(fresh.every((k) => tail.has(k)));
});

test("a game stops at its nightly share, publishes its pack and hands the night to the next game", async () => {
  const rows = bigRows(9000);
  const lines = {};
  for (const r of rows.slice(0, 400)) lines[r.key] = { k: r.key, en: r.text, tr: "Arabaya bin, Lucia." };
  const { env, stored } = pagedEnv({
    rows, state: titledState({ did: JOB_NIGHTLY }), cache: { lines, skip: {}, fail: {} },
  });
  const result = await runAutopack(env, new Date("2026-11-20T03:12:00Z"));
  assert.equal(result.phase, "build");
  assert.equal(result.built, true);
  assert.equal(JSON.parse(stored.get("auto/state.json")).queue.length, 0);
  assert.equal(JSON.parse(stored.get("index.json")).packs[0].id, "pool-ppsa1");
});

test("pack grows every night: a touched game is published at the final tick and the version rises", async () => {
  const rows = bigRows(9000);
  const { env, stored } = pagedEnv({ rows, state: titledState() });
  // Yeterince satır çevrilsin (MIN_LINES) ama gecelik pay dolmasın.
  for (let run = 0; run < 2; run++) await runAutopack(env, new Date("2026-11-20T03:12:00Z"));
  assert.equal(JSON.parse(stored.get("index.json")).packs.length, 0);
  assert.equal((await runAutopack(env, new Date("2026-11-20T05:52:00Z"))).phase, "build");
  const first = JSON.parse(stored.get("index.json")).packs[0];
  assert.equal(first.id, "pool-ppsa1");
  assert.equal(first.version, 1);

  // Ertesi gece: plan R2'de aynı oyun için önbelleği bırakır; çeviri sürer, son tetiklemede sürüm 2.
  const day2 = new Date("2026-11-21T03:12:00Z");
  stored.set("auto/state.json", JSON.stringify({ ...titledState(), night: "2026-11-21" }));
  await runAutopack(env, day2);
  assert.equal((await runAutopack(env, new Date("2026-11-21T05:57:00Z"))).phase, "build");
  const second = JSON.parse(stored.get("index.json")).packs[0];
  assert.equal(second.version, 2);
  assert.ok(second.entries > first.entries);
});

test("a finished pass does not restart the same night and the next night starts from the top", async () => {
  const { env, stored } = pagedEnv({ rows: bigRows(320), state: titledState() });
  const now = new Date("2026-11-20T03:12:00Z");
  assert.equal((await runAutopack(env, now)).phase, "translate");
  assert.equal((await runAutopack(env, now)).phase, "translate");
  // 320 satır: ikinci turda gezinti biter (sayfa dolu değil); sonraki tetikleme paketi kurar, baştan başlamaz.
  const cache = JSON.parse(stored.get("auto/tr/PPSA1.json"));
  assert.equal(cache.cursor, null);
  assert.equal(cache.passNight, "2026-11-20");
  assert.equal((await runAutopack(env, now)).phase, "build");
});

test("night limit stays inside the Workers AI free daily allowance and the cron has enough runs", () => {
  // Önceki hesap: en çok ~1,67 nöron/satır; Free plan günde 10.000 nöron.
  assert.ok(NIGHTLY_LIMIT * (10_000 / 6_000) <= 10_000 * 0.9);
  assert.ok(JOB_NIGHTLY <= NIGHTLY_LIMIT);
  // 03:02–05:57 arası beş dakikada bir: 36 tetikleme; biri plan, biri paket.
  assert.ok((36 - 2) * LINES_PER_RUN >= NIGHTLY_LIMIT);
  assert.equal(isFinalTick(new Date("2026-11-20T05:52:00Z")), true);
  assert.equal(isFinalTick(new Date("2026-11-20T05:47:00Z")), false);
  assert.equal(LAST_HOUR_UTC, 5);
});


// --- Claude (Anthropic Messages API) ---

/** Sahte fetch: Claude yanıtını taklit eder, istekleri kaydeder. */
function claudeFetch({ calls = [], reply } = {}) {
  return async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, headers: init.headers, body });
    if (reply) return reply(body);
    const ids = body.messages[0].content.split("\n").filter(Boolean).map((l) => l.split("\t")[0]);
    return new Response(JSON.stringify({
      stop_reason: "end_turn",
      content: [{ type: "text", text: JSON.stringify({ items: ids.map((id) => ({ id, tr: "Arabaya bin, Lucia." })) }) }],
      usage: { input_tokens: 10, output_tokens: 10, cache_read_input_tokens: 0 },
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
}

test("Claude limits fit the cron and the per-run subrequest budget", () => {
  assert.ok((36 - 2) * CLAUDE_LIMITS.linesPerRun >= CLAUDE_LIMITS.nightly);
  assert.ok(CLAUDE_LIMITS.jobNightly <= CLAUDE_LIMITS.nightly);
  // Workers Free: istek başına 50 alt istek. Çeviri istekleri + en çok 3 D1 sayfası + ~8 R2 işi.
  assert.ok(Math.ceil(CLAUDE_LIMITS.linesPerRun / CLAUDE_LIMITS.batch) + 3 + 8 <= 50);
  assert.ok(CLAUDE_LIMITS.maxLook >= CLAUDE_LIMITS.linesPerRun);
  assert.ok(3 * PAGE >= CLAUDE_LIMITS.maxLook);
  assert.equal(limitsFor({ ANTHROPIC_API_KEY: "k" }), CLAUDE_LIMITS);
  assert.equal(limitsFor({ AI: {} }).linesPerRun, LINES_PER_RUN);
});

test("Claude request uses the secret, Haiku without thinking and a cached system prompt", async (t) => {
  const calls = [];
  t.mock.method(globalThis, "fetch", claudeFetch({ calls }));
  const items = [{ en: "Get in the car, Lucia." }, { en: "Where's Essex?" }];
  const got = await translateClaude({ ANTHROPIC_API_KEY: "sk-test" }, items, "Grand Theft Auto VI");
  assert.deepEqual([...got.entries()], [[0, "Arabaya bin, Lucia."], [1, "Arabaya bin, Lucia."]]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, CLAUDE_URL);
  assert.equal(calls[0].headers["x-api-key"], "sk-test");
  assert.equal(calls[0].headers["anthropic-version"], "2023-06-01");
  assert.equal(calls[0].body.model, CLAUDE_MODEL);
  assert.deepEqual(calls[0].body.thinking, { type: "disabled" });
  assert.deepEqual(calls[0].body.system[0].cache_control, { type: "ephemeral" });
  assert.match(calls[0].body.system[0].text, /Grand Theft Auto VI/);
  assert.equal(calls[0].body.output_config.format.type, "json_schema");
  assert.equal(calls[0].body.messages[0].content, "0\tGet in the car, Lucia.\n1\tWhere's Essex?");
});

test("Claude errors and unfinished replies translate nothing instead of guessing", async (t) => {
  const items = [{ en: "Get in the car, Lucia." }];
  const env = { ANTHROPIC_API_KEY: "sk-test" };
  t.mock.method(globalThis, "fetch", claudeFetch({ reply: () => new Response("overloaded", { status: 529 }) }));
  assert.equal((await translateClaude(env, items, null)).size, 0);
  t.mock.method(globalThis, "fetch", claudeFetch({
    reply: () => new Response(JSON.stringify({ stop_reason: "max_tokens", content: [{ type: "text", text: "{\"items\":[" }] })),
  }));
  assert.equal((await translateClaude(env, items, null)).size, 0);
  t.mock.method(globalThis, "fetch", async () => { throw new Error("network"); });
  assert.equal((await translateClaude(env, items, null)).size, 0);
});

test("with the Claude secret the night runs on Claude, in larger runs, without Workers AI", async (t) => {
  const calls = [];
  t.mock.method(globalThis, "fetch", claudeFetch({ calls }));
  const { env, stored } = pagedEnv({ rows: bigRows(4000), state: titledState() });
  env.AI = { run: async () => { throw new Error("Workers AI must not be used"); } };
  env.ANTHROPIC_API_KEY = "sk-test";
  const result = await runAutopack(env, new Date("2026-11-20T03:12:00Z"));
  assert.equal(result.phase, "translate");
  assert.equal(result.translated, CLAUDE_LIMITS.linesPerRun);
  assert.equal(calls.length, CLAUDE_LIMITS.linesPerRun / CLAUDE_LIMITS.batch);
  assert.equal(Object.keys(JSON.parse(stored.get("auto/tr/PPSA1.json")).lines).length, CLAUDE_LIMITS.linesPerRun);
});

test("without Workers AI binding the Claude secret alone enables the night", async (t) => {
  t.mock.method(globalThis, "fetch", claudeFetch());
  const { env } = pagedEnv({ rows: bigRows(10), state: titledState() });
  delete env.AI;
  assert.equal((await runAutopack(env, new Date("2026-11-20T03:12:00Z"))).phase, "disabled");
  env.ANTHROPIC_API_KEY = "sk-test";
  assert.notEqual((await runAutopack(env, new Date("2026-11-20T03:12:00Z"))).phase, "disabled");
});


// --- Herkese açık sayıların gecelik özeti ---

function statsEnv({ heavy, confirmed = 7, previous = null }) {
  const stored = new Map();
  if (previous) stored.set("auto/stats.json", JSON.stringify(previous));
  const sqls = [];
  return {
    sqls, stored,
    env: {
      PACKS: {
        get: async (name) => stored.has(name) ? { text: async () => stored.get(name) } : null,
        put: async (name, value) => { stored.set(name, value); },
      },
      DB: {
        prepare: (sql) => {
          sqls.push(sql);
          const run = async () => /COUNT\(DISTINCT/.test(sql)
            ? (typeof heavy === "function" ? heavy() : heavy)
            : { confirmed };
          return { first: run, bind: () => ({ first: run }) };
        },
      },
    },
  };
}

test("nightly summary stores the distinct counts in R2", async () => {
  const { env, stored } = statsEnv({ heavy: { lines: 1000, installs: 40 }, confirmed: 600 });
  const out = await computeStats(env, new Date("2026-11-20T03:02:00Z"));
  assert.deepEqual(JSON.parse(stored.get("auto/stats.json")), out);
  assert.equal(out.lines, 1000);
  assert.equal(out.confirmed, 600);
  assert.equal(out.installs, 40);
  assert.equal(out.updated, "2026-11-20T03:02:00.000Z");
  assert.equal(out.approx, undefined);
});

test("summary keeps the previous distinct counts when the heavy query times out", async () => {
  const previous = { lines: 900, confirmed: 500, installs: 30, updated: "2026-11-19T03:02:00.000Z" };
  const { env } = statsEnv({ heavy: () => { throw new Error("D1 query timed out"); }, confirmed: 650, previous });
  const out = await computeStats(env, new Date("2026-11-20T03:02:00Z"));
  assert.equal(out.lines, 900);
  assert.equal(out.installs, 30);
  assert.equal(out.confirmed, 650);
  assert.equal(out.approx, true);
});

test("summary without any history falls back to confirmed lines as the lower bound", async () => {
  const { env } = statsEnv({ heavy: () => { throw new Error("timed out"); }, confirmed: 321 });
  const out = await computeStats(env, new Date("2026-11-20T03:02:00Z"));
  assert.deepEqual([out.lines, out.confirmed, out.installs, out.approx], [321, 321, 0, true]);
});

test("night plan writes the summary and a summary failure cannot stop the plan", async () => {
  const stored = new Map([["index.json", JSON.stringify({ packs: [] })]]);
  const env = {
    AI: {},
    PACKS: {
      get: async (name) => stored.has(name) ? { text: async () => stored.get(name) } : null,
      put: async (name, value) => {
        if (name === "auto/stats.json") throw new Error("R2 put failed");
        stored.set(name, value);
      },
    },
    DB: { prepare: () => ({ first: async () => ({ lines: 1, installs: 1 }), bind: () => ({
      all: async () => ({ results: [] }), first: async () => ({ lines: 0, confirmed: 0 }),
    }) }) },
  };
  const result = await runAutopack(env, new Date("2026-11-20T03:02:00Z"));
  assert.equal(result.phase, "plan");
  assert.equal(result.stats, null);
});
