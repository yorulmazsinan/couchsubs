// SPDX-License-Identifier: AGPL-3.0-only
// Ağ yok: süzgeç ve gönderimin D1'e kaç yazma yaptığı sahte bir veritabanıyla denenir. Çalıştırma: `npm test`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { accepts } from "../src/filter.js";
import worker, { key, resetStatsCache, STATS_KEY, gameName, titleId, unavailableFor, ownApp, QUOTA_BLOCK, SATURATED } from "../src/index.js";
import { GENERAL, jobPackId, nameJobs, runAutopack } from "../src/autopack.js";
import { gameKey, gameSlug } from "../src/games.js";

test("Türkçe arayüz, bozulmuş Türkçe, sistem yazısı ve yarım okumalar alınmaz", () => {
  for (const line of [
    "Oturum Açtı", "Oturum Aqtl", "Oturum Aqtl.", "Sifirlama Seqenekleri", "Sifirlama Seqenekleri.",
    "PS5 Sistemini Yeniden Baslat", "PS5 Sistemini Yeniden Baslat.", "Oyunu Kapat", "Ana Ekranda Tut",
    "Lütfen bekleyin..", "Ekran ve Video", "ilerlemenizi takip edin Kupalar", "Keşfet PS5 ile ilgili Öne Çıkanlar",
    "Ekran görüntüsü kaydedildi.", "Kupa kazandınız!", "John signed in.", "You've earned a trophy!",
    "Please do not quit or turn off your console while the Rockstar cloud save icon is showing.",
    "GO to the", "Take out the trash and the", "it Auto V's Story Mode.", "FREE MONTH OF GTA+", "PHOTO MODE SELECT",
    "Main menu", "Hold on", "HP 100/100 MP 25/50", "Okay.",
    // Kumanda ipuçları: tuş simgesi okunmamış ya da bozulmuş (GTA 6, RDR 2, Mafia havuz satırları).
    "Press to threaten the teller", "Use to select your binoculars", "Hold to open your loadout", "Press @ to open the map",
    "Press D to greet Joey", "Hold I LI to open your loadout", "Press RE to go back to your weapons and equipment",
    "Press (9 0 to stop focusing", "Release 2 and R2 to breathe out", "Hold + to look at Joey", "Press [RB] to take cover",
    "Use ⓁⓇ to steer the boat", "PRESS to VAULT over obstacles", "Press to heal.", "0 0 00 0 Press • to open the index",
  ]) assert.equal(accepts(line), false, line);
});

test("İngilizce oyun satırları alınır", () => {
  for (const line of [
    "Herr Müller will see you now.", "This place was designed in a hurry.", "Tell Sam I signed the deal.",
    "I lie to you, you lie to me.", "DON TORRISI WANTS YOU!", "Get down!", "Who's there?", "Line number 7 here",
    "We need to move before the cops show up", "Give me 50 dollars, Enzo.",
    "Press the button, Jason!", "Hold on to something.", "HOLD ON TO IT, LUCIA.", "Use it to open the door.",
    "Hold up, Floyd. I'm coming down there.", "Use a rope to climb down.", "Hold to your course, men.",
    "Jason: Press to the left", "Use me to get inside.", "Press on, we're almost there.",
  ]) assert.equal(accepts(line), true, line);
});

// D1'in yalnız bu dosyadaki sorguları kadarını taklit eder; her çalışan yazma deyimini sayar.
function fakeDB() {
  const sightings = new Map(); // anahtar -> kurulumlar
  const lines = new Map();
  const db = {
    writes: 0, lines, quotas: new Map(), last: null, beforeQuotaRead: null,
    batchCalls: 0, failNextBatch: false, failBatchOnCall: null,
  };
  const quotaKey = (install, day) => `${install}\u001f${day}`;
  const run = (sql, args) => {
    if (sql.startsWith("SELECT count FROM quota")) return { count: db.quotas.get(quotaKey(args[0], args[1])) ?? 0 };
    if (sql.startsWith("SELECT key FROM lines WHERE key IN")) {
      db.reads = (db.reads ?? 0) + 1;
      const min = args[args.length - 1];
      return { results: args.slice(0, -1).filter((k) => {
        const row = lines.get(k);
        return row && (row.installs >= min || row.exported === 1);
      }).map((key) => ({ key })) };
    }
    if (sql.startsWith("SELECT")) {
      db.last = { sql, args };
      return { results: [] };
    }
    db.writes++;
    if (sql.startsWith("INSERT OR IGNORE INTO sightings")) {
      const [k, who] = args;
      const set = sightings.get(k) ?? new Set();
      const changes = set.has(who) ? 0 : 1;
      set.add(who);
      sightings.set(k, set);
      return { meta: { changes } };
    }
    if (sql.startsWith("INSERT INTO lines")) {
      // Havuza yalnız iki kurulumdan sonra girer; sayı güncel distinct sightings'dir.
      const [k, text, , , title = null, game = null] = args;
      const n = sightings.get(k)?.size ?? 0;
      if (n < 2) return { meta: { changes: 0 } };
      const row = lines.get(k);
      if (row && row.installs >= n) return { meta: { changes: 0 } };
      lines.set(k, row
        ? { ...row, installs: n, title: row.title ?? title, game: row.game ?? game }
        : { text, installs: n, title, game });
      return { meta: { changes: 1 } };
    }
    if (sql.startsWith("INSERT INTO quota")) {
      db.quotaWrites = (db.quotaWrites ?? 0) + 1;
      const key = quotaKey(args[0], args[1]);
      const delta = args[2];
      const expected = args[3];
      const used = db.quotas.get(key) ?? 0;
      if (args.length === 4 && used !== expected) return { meta: { changes: 0 } };
      db.quotas.set(key, used + delta);
      return { meta: { changes: 1 } };
    }
    if (sql.startsWith("UPDATE quota")) {
      const key = quotaKey(args[1], args[2]);
      db.quotas.set(key, (db.quotas.get(key) ?? 0) - args[0]);
      return { meta: { changes: 1 } };
    }
    throw new Error(sql);
  };
  db.prepare = (sql) => ({
    bind: (...args) => ({
      first: async () => {
        if (sql.startsWith("SELECT count FROM quota")) {
          const result = run(sql, args);
          await db.beforeQuotaRead?.();
          return result;
        }
        return run(sql, args);
      },
      run: async () => run(sql, args), all: async () => run(sql, args), sql, args,
    }),
  });
  // D1'de toplu yazma tek işlemdir: bir deyim hata verirse hiçbiri yazılmaz.
  db.batch = async (stmts) => {
    db.batchCalls++;
    if (db.failNextBatch || db.failBatchOnCall === db.batchCalls) {
      db.failNextBatch = false;
      db.failBatchOnCall = null;
      throw new Error("injected batch failure");
    }
    return stmts.map((s) => run(s.sql, s.args));
  };
  return db;
}

const keyOf = (text) => key(text);
const install = (n) => `00000000-0000-4000-8000-00000000000${n}`;
const post = (env, who, texts) => worker.fetch(new Request("https://pool.test/v1/lines", {
  method: "POST",
  body: JSON.stringify({ install: who, app: "0.1.0-beta.46", lines: texts.map((text) => ({ text })) }),
}), env);

test("gönderim süzer; tek kurulumun satırı havuza yazılmaz, ikinci kurulumda girer", async () => {
  const DB = fakeDB();
  const env = { DB };
  const reply = await post(env, install(1), ["Oturum Açtı", "Get down!", "Get down!", "Who is that over there?"]);
  assert.deepEqual(await reply.json(), { accepted: 2, recorded: 2, saturated: [] });
  // İki görülme + iki koşullu UPSERT + bir kota rezervasyonu; ilk kurulumda lines'a kayıt girmez.
  assert.equal(DB.lines.size, 0);

  // Aynı kurulum aynı satırları yeniden gönderirse yalnız görülme denemesi ve kota yazılır.
  DB.writes = 0;
  await post(env, install(1), ["Get down!", "Who is that over there?"]);
  // 2 idempotent sightings + 2 idempotent conditional UPSERT; kota bu dağıtımın ayırdığı paydan düşer (D1'e yazılmaz).
  assert.equal(DB.writes, 4);
  assert.equal(DB.lines.size, 0);

  // İkinci kurulum: satır havuza installs=2 ile girer; yalnız onun okuduğu satır.
  await post(env, install(2), ["Get down!"]);
  assert.deepEqual([...DB.lines.values()].map((l) => l.installs), [2]);

  // Üçüncü kurulum: sayaç bir artar.
  await post(env, install(3), ["Get down!"]);
  assert.deepEqual([...DB.lines.values()].map((l) => l.installs), [3]);
});

const postLines = (env, who, lines) => worker.fetch(new Request("https://pool.test/v1/lines", {
  method: "POST",
  body: JSON.stringify({ install: who, app: "CouchSubs Android 0.9.23", lines }),
}), env);

test("yeterince kurulumun doğruladığı ya da çeviriye alınmış satırın yeni görülmesi D1'e yazılmaz", async () => {
  const DB = fakeDB();
  const env = { DB };
  for (let n = 1; n <= SATURATED; n++) await post(env, install(n), ["Get down!"]);
  assert.deepEqual([...DB.lines.values()].map((l) => l.installs), [SATURATED]);

  DB.writes = 0;
  const reply = await post(env, install(SATURATED + 1), ["Get down!"]);
  assert.deepEqual(await reply.json(), { accepted: 1, recorded: 0, saturated: [await keyOf("Get down!")] });
  assert.equal(DB.writes, 1, "yalnız yeni kurulumun günlük kota payı yazılır");
  assert.deepEqual([...DB.lines.values()].map((l) => l.installs), [SATURATED]);

  // Çeviriye alınmış (exported) satır da installs eşiğinin altındayken atlanır; doğrulanmamış satır yazılır.
  DB.lines.set("x", { text: "x", installs: 2, exported: 1 });
  const before = DB.writes;
  await post(env, install(SATURATED + 1), ["Who is that over there?"]);
  assert.equal(DB.writes - before, 2, "doğrulanmamış satır: görülme + koşullu UPSERT");
});

test("kota her istekte değil, pay bitince yazılır; günlük sınır yine aşılmaz", async () => {
  const DB = fakeDB();
  const env = { DB };
  const who = install(5);
  const day = new Date().toISOString().slice(0, 10);
  const batch = (i) => Array.from({ length: 10 }, (_, j) => ({ text: `Keep moving ${i} ${j} now.` }));
  for (let i = 0; i < 20; i++) assert.equal((await postLines(env, who, batch(i))).status, 200);
  // 20 istek × 10 satır = 200 satır: tek pay, tek kota yazımı.
  assert.equal(DB.quotaWrites, 1);
  assert.equal(DB.quotas.get(`${who}\u001f${day}`), QUOTA_BLOCK);

  // Sınıra yakın: kalan yer kadar kabul edilir, sonra 429.
  DB.quotas.set(`${who}\u001f${day}`, 4995);
  const many = Array.from({ length: 200 }, (_, j) => ({ text: `Hold the line ${j} please.` }));
  const near = await postLines(env, who, many);
  assert.equal(near.status, 200);
  assert.equal(DB.quotas.get(`${who}\u001f${day}`), 5000);
  let accepted = (await near.json()).accepted;
  for (let i = 0; i < 5; i++) {
    const r = await postLines(env, who, many);
    if (r.status === 200) accepted += (await r.json()).accepted;
    else assert.equal(r.status, 429);
  }
  assert.equal(DB.quotas.get(`${who}\u001f${day}`), 5000);
  assert.ok(accepted <= 5, `en çok 5 yer kalmıştı, ${accepted} kabul edildi`);
});

test("D1 günlük yazım sınırı ya da geçici hatası 500 değil 503 + Retry-After döner ve günlüğe yazılır", async () => {
  const DB = fakeDB();
  DB.prepare = () => ({ bind: () => ({
    first: async () => { throw new Error("D1_ERROR: Exceeded maximum daily rows written limit"); },
    run: async () => { throw new Error("x"); },
  }) });
  const logged = [];
  const original = console.error;
  console.error = (...args) => logged.push(args.join(" "));
  try {
    const reply = await postLines({ DB }, install(1), [{ text: "Get down!" }]);
    assert.equal(reply.status, 503);
    const wait = Number(reply.headers.get("retry-after"));
    assert.ok(wait >= 60 && wait <= 3600, String(wait));
    assert.equal(logged.length, 1);
    assert.match(logged[0], /Exceeded maximum daily rows written/);
  } finally {
    console.error = original;
  }
  assert.equal(unavailableFor(new Error("D1 DB is overloaded. Requests queued for too long.")), 60);
  assert.equal(unavailableFor(new Error("Network connection lost.")), 60);
  assert.equal(unavailableFor(new Error("injected batch failure")), 0);
});

test("eşzamanlı gönderimler günlük kota sınırını aşamaz", async () => {
  const DB = fakeDB();
  const who = install(7);
  const day = new Date().toISOString().slice(0, 10);
  DB.quotas.set(`${who}\u001f${day}`, 4990);
  let readers = 0;
  let releaseReads;
  const bothRead = new Promise((resolve) => { releaseReads = resolve; });
  DB.beforeQuotaRead = async () => {
    readers++;
    if (readers === 2) releaseReads();
    await bothRead;
  };

  const lines = Array.from({ length: 20 }, (_, i) => ({ text: `Keep moving ${i} now.` }));
  const replies = await Promise.all([
    postLines({ DB }, who, lines),
    postLines({ DB }, who, lines),
  ]);

  assert.deepEqual(replies.map((reply) => reply.status).sort(), [200, 429]);
  const accepted = replies.find((reply) => reply.status === 200);
  assert.deepEqual(await accepted.json(), { accepted: 10, recorded: 10, saturated: [] });
  assert.equal(DB.quotas.get(`${who}\u001f${day}`), 5000);
  assert.equal(DB.lines.size, 0); // tek kurulumun gördüğü satırlar havuza girmez
});

test("ilk yazma toplu işlemi başarısızsa kota rezervasyonu geri alınır", async () => {
  const DB = fakeDB();
  const who = install(9);
  const day = new Date().toISOString().slice(0, 10);
  DB.quotas.set(`${who}\u001f${day}`, 12);
  DB.failNextBatch = true;

  const reply = await postLines({ DB }, who, [{ text: "Get down!" }]);
  assert.equal(reply.status, 500);
  assert.equal(DB.quotas.get(`${who}\u001f${day}`), 12);
});

test("atomik görülme ve satır batch'i başarısızsa kota rezervasyonu geri alınır", async () => {
  const DB = fakeDB();
  const who = install(4);
  const day = new Date().toISOString().slice(0, 10);
  DB.quotas.set(`${who}\u001f${day}`, 12);
  // İki aşama yerine görülme ve satır yazımı tek D1 batch transaction'ıdır.
  DB.failBatchOnCall = 1;

  const reply = await postLines({ DB }, who, [{ text: "Get down!" }]);
  assert.equal(reply.status, 500);
  assert.equal(DB.batchCalls, 1);
  assert.equal(DB.quotas.get(`${who}\u001f${day}`), 12);
});

test("oyun kimliği ve adı doğrulanır", () => {
  assert.equal(titleId("PPSA01234"), "PPSA01234");
  assert.equal(titleId(" cusa00419_00 "), "CUSA00419_00");
  assert.equal(titleId("PPSA1234"), null);
  assert.equal(titleId("x'; DROP TABLE lines;--"), null);
  assert.equal(titleId(undefined), null);
  assert.equal(gameName("  Grand Theft Auto VI \n"), "Grand Theft Auto VI");
  assert.equal(gameName("A\u0000B"), "A B");
  assert.equal(gameName("x".repeat(300)).length, 120);
  assert.equal(gameName(""), null);
  assert.equal(gameName(42), null);
  // Ek paketten tanınan oyun asıl adıyla toplanır.
  assert.equal(gameName("Marvel's Spider-Man 2 (ek satırlar)"), "Marvel's Spider-Man 2");
  assert.equal(gameName(" (ek satırlar)"), null);
});

test("satırın oyunu havuza giren (ikinci) kurulumdan alınır; ilk bilinen oyun kalır", async () => {
  const DB = fakeDB();
  const env = { DB };
  const reply = await postLines(env, install(1), [
    { text: "Get in the car, Lucia.", titleId: "PPSA12345", game: "Grand Theft Auto VI" },
    { text: "Who is that over there?" },
    { text: "Keep your head down.", titleId: "bogus", game: "" },
  ]);
  assert.deepEqual(await reply.json(), { accepted: 3, recorded: 3, saturated: [] });
  assert.equal(DB.lines.size, 0);

  await postLines(env, install(2), [{ text: "Get in the car, Lucia.", titleId: "PPSA12345", game: "GTA VI" }]);
  const first = [...DB.lines.values()][0];
  assert.equal(first.installs, 2);
  assert.deepEqual([first.title, first.game], ["PPSA12345", "GTA VI"]);

  // Üçüncü kurulum başka oyunla bildirir: sayaç artar, oyun değişmez.
  await postLines(env, install(3), [{ text: "Get in the car, Lucia.", titleId: "CUSA00419", game: "GTA V" }]);
  const again = [...DB.lines.values()][0];
  assert.equal(again.installs, 3);
  assert.equal(again.title, "PPSA12345");
});

test("dışa aktarma oyuna göre süzülür (yalnız yönetici)", async () => {
  const DB = fakeDB();
  const env = { DB, ADMIN_TOKEN: "t" };
  const get = (query, auth = "Bearer t") => worker.fetch(new Request(`https://pool.test/v1/export?${query}`, {
    headers: { authorization: auth },
  }), env);
  assert.equal((await get("title=PPSA12345", "Bearer x")).status, 401);

  await get("title=ppsa12345&min=1");
  assert.match(DB.last.sql, /title_id=\?/);
  assert.match(DB.last.sql, /SELECT key,text,installs,first_seen,title_id,game/);
  assert.deepEqual(DB.last.args, [1, "PPSA12345", 5000]);

  await get("game=Grand%20Theft_Auto");
  assert.match(DB.last.sql, /game LIKE \? ESCAPE/);
  assert.deepEqual(DB.last.args, [2, "%Grand Theft\\_Auto%", 5000]);

  // Süzgeçsiz istek eski sütunlarla (geçişten önce de çalışır).
  await get("");
  assert.doesNotMatch(DB.last.sql, /title_id|game/);
});

test("oyunu bilinmeyen satırlar ortak pakete sıralanır (oyunu bilinenlerden sonra)", async () => {
  const stored = new Map([["index.json", JSON.stringify({ packs: [] })]]);
  const env = {
    AI: {},
    PACKS: {
      get: async (name) => (stored.has(name) ? { text: async () => stored.get(name) } : null),
      put: async (name, value) => { stored.set(name, value); },
    },
    DB: {
      prepare: (sql) => ({
        bind: () => ({
          all: async () => ({ results: sql.includes("GROUP BY title_id") ? [{ title_id: "PPSA01234", game: "X", lines: 400 }] : [] }),
          first: async () => (sql.includes("title_id IS NULL") ? { lines: 350 } : null),
        }),
      }),
    },
  };
  const plan = await runAutopack(env, new Date("2026-11-20T03:07:00Z"));
  assert.equal(plan.queued, 2);
  const state = JSON.parse(stored.get("auto/state.json"));
  assert.deepEqual(state.queue.map((t) => t.titleId), ["PPSA01234", GENERAL]);
});

test("oyun adı anahtarı aynı oyunun farklı yazımlarını birleştirir", () => {
  for (const name of ["Grand Theft Auto VI", "GTA 6", "gta vi", "GTA6", "Grand Theft Auto VI™"]) assert.equal(gameKey(name), "gta 6", name);
  assert.equal(gameKey("Marvel's Spider-Man 2"), "marvels spider man 2");
  assert.equal(gameKey("The Witcher 3: Wild Hunt"), "witcher 3 wild hunt");
  assert.equal(gameKey("Call of Duty: Black Ops 7"), "cod black ops 7");
  assert.equal(gameKey(""), "");
  assert.equal(gameSlug("gta 6"), "gta-6");
});

test("kimliksiz oyun adları anahtara göre birleşir; tek kurulumun adı ayrı paket açmaz", () => {
  const rows = [{ game: "GTA 6", lines: 200 }, { game: "Grand Theft Auto VI", lines: 300 }, { game: "Yanlış Oyun", lines: 900 }];
  const jobs = nameJobs(rows, new Map([["gta 6", 3], ["yanlis oyun", 1]]));
  assert.equal(jobs.length, 1);
  assert.equal(jobs[0].game, "Grand Theft Auto VI");
  assert.equal(jobs[0].lines, 500);
  assert.deepEqual(jobs[0].games, ["GTA 6", "Grand Theft Auto VI"]);
  assert.equal(jobPackId(jobs[0]), "pool-gta-6");
});

test("Latin dışı oyunlar ayrı paket alır, karışık adlar ASCII adla çakışmaz", () => {
  const names = ["星の旅", "夜の旅", "GTA 6 海外"];
  const votes = new Map(names.map((name) => [gameKey(name), 2]));
  const jobs = nameJobs(names.map((game) => ({ game, lines: 320 })), votes);
  assert.equal(jobs.length, 3, "Latin dışı adlar sessizce elenmemeli");
  const ids = jobs.map(jobPackId);
  assert.equal(new Set(ids).size, 3);
  assert.ok(ids.every((id) => /^[a-z0-9][a-z0-9-]{0,63}$/.test(id)));
  assert.notEqual(jobPackId({ titleId: null, gameKey: gameKey("GTA 6 海外") }), "pool-gta-6");
});

test("uzun oyun adları sunucunun kabul ettiği paket kimliği sınırında kalır", () => {
  const id = jobPackId({ titleId: null, gameKey: "x".repeat(80) });
  assert.match(id, /^[a-z0-9][a-z0-9-]{0,63}$/);
});

test("uzun oyun adlarının paket kimlikleri son karakterde ayrışır", () => {
  const first = jobPackId({ titleId: null, gameKey: "x".repeat(79) + "a" });
  const second = jobPackId({ titleId: null, gameKey: "x".repeat(79) + "b" });
  assert.notEqual(first, second);
  assert.match(first, /^[a-z0-9][a-z0-9-]{0,63}$/);
  assert.match(second, /^[a-z0-9][a-z0-9-]{0,63}$/);
});

test("kimliksiz oyun adı kurulum başına bir oy yazar", async () => {
  const DB = fakeDB();
  const votes = [];
  const batch = DB.batch;
  DB.batch = async (stmts) => {
    if (stmts.every((s) => s.sql.startsWith("INSERT OR IGNORE INTO game_votes"))) {
      votes.push(...stmts.map((s) => s.args));
      return stmts.map(() => ({ meta: { changes: 1 } }));
    }
    return batch(stmts);
  };
  await postLines({ DB }, install(1), [
    { text: "Get in the car, Lucia.", game: "Grand Theft Auto VI" },
    { text: "Keep your head down.", game: "GTA 6" },
    { text: "Who is that over there?", titleId: "PPSA12345", game: "Other" },
  ]);
  assert.deepEqual(votes, [["gta 6", install(1)]]);
});

test("export rejects negative and non-integer pagination before issuing SQL", async () => {
  const DB = fakeDB();
  const env = { DB, ADMIN_TOKEN: "t" };
  const get = (params) => worker.fetch(new Request(`https://pool.test/v1/export?${params}`, {
    headers: { authorization: "Bearer t" },
  }), env);
  for (const params of ["limit=-1", "limit=1.5", "limit=bogus", "min=bogus", "min=-5"]) {
    DB.last = null;
    const response = await get(params);
    assert.equal(response.status, 400, params);
    assert.equal(DB.last, null, `${params} must not execute a query`);
  }
  const valid = await get("limit=100000&min=3");
  assert.equal(valid.status, 200);
  assert.deepEqual(DB.last.args, [3, 20000]);
});

test("a failed line write does not silently lose its sighting on retry", async () => {
  const DB = fakeDB();
  const text = "Don't leave the engine running.";
  const first = await postLines({ DB }, install(1), [{ text }]);
  assert.equal(first.status, 200);
  assert.equal(DB.lines.size, 0);

  const original = DB.batch;
  let failWhenWritingLine = true;
  DB.batch = async (statements) => {
    if (failWhenWritingLine && statements.some((s) => s.sql.startsWith("INSERT INTO lines"))) {
      failWhenWritingLine = false;
      // D1.batch rejects the entire transaction if a statement fails.
      throw new Error("injected failure after sightings would otherwise commit");
    }
    return original(statements);
  };
  const failed = await postLines({ DB }, install(2), [{ text }]);
  assert.equal(failed.status, 500);
  assert.equal(DB.lines.size, 0);
  const retry = await postLines({ DB }, install(2), [{ text }]);
  assert.equal(retry.status, 200);
  assert.equal(DB.lines.size, 1, "retry must still publish a line seen by two distinct installs");
  assert.equal([...DB.lines.values()][0].installs, 2);
});

test("admin export endpoints reject methods outside their documented routes", async () => {
  const DB = fakeDB();
  const env = { DB, ADMIN_TOKEN: "t" };
  const invoke = (path, method, body) => worker.fetch(new Request("https://pool.test" + path, {
    method,
    headers: { authorization: "Bearer t" },
    ...(body ? { body: JSON.stringify(body) } : {}),
  }), env);

  for (const [path, method, body, allow] of [
    ["/v1/export", "POST", { keys: ["1234567890abcdef"] }, "GET"],
    ["/v1/exported", "GET", null, "POST"],
    ["/v1/export", "PATCH", { keys: [] }, "GET"],
  ]) {
    DB.last = null;
    const writes = DB.writes;
    const response = await invoke(path, method, body);
    assert.equal(response.status, 405, method + " " + path);
    assert.equal(response.headers.get("allow"), allow);
    assert.equal(DB.last, null, "wrong methods must not run a DB read");
    assert.equal(DB.writes, writes, "wrong methods must not mutate DB");
  }
  assert.equal((await invoke("/v1/export", "GET")).status, 200);
  assert.equal((await invoke("/v1/exported", "POST", { keys: [] })).status, 200);
});

test("exported endpoint rejects malformed JSON and missing keys rather than reporting success", async () => {
  const DB = fakeDB();
  const env = { DB, ADMIN_TOKEN: "t" };
  for (const body of ["{broken", "null", "{}", '{"keys":null}', '{"keys":"abc"}']) {
    const writes = DB.writes;
    const request = new Request("https://pool.test/v1/exported", {
      method: "POST",
      headers: { authorization: "Bearer t" },
      body,
    });
    const reply = await worker.fetch(request, env);
    assert.equal(reply.status, 400, "invalid export payload: " + body);
    assert.equal(DB.writes, writes, "invalid export must not run an update");
  }
  const valid = await worker.fetch(new Request("https://pool.test/v1/exported", {
    method: "POST", headers: { authorization: "Bearer t" },
    body: JSON.stringify({ keys: [] }),
  }), env);
  assert.equal(valid.status, 200);
  assert.deepEqual(await valid.json(), { marked: 0 });
});


test("mark-exported reports only newly marked stored lines, not requested key count", async () => {
  const stored = new Map([["1111111111111111", false], ["2222222222222222", true]]);
  const sqls = [];
  const DB = {
    prepare: (sql) => ({
      bind: (key) => ({ sql, key }),
    }),
    batch: async (statements) => statements.map(({ sql, key }) => {
      sqls.push(sql);
      const newlyMarked = stored.get(key) === false;
      if (newlyMarked) stored.set(key, true);
      return { meta: { changes: newlyMarked ? 1 : 0 } };
    }),
  };
  const env = { DB, ADMIN_TOKEN: "t" };
  const postKeys = async (keys) => worker.fetch(new Request("https://pool.test/v1/exported", {
    method: "POST",
    headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({ keys }),
  }), env);
  const result = await postKeys(["1111111111111111", "1111111111111111", "2222222222222222", "3333333333333333"]);
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { marked: 1 }, "duplicates, already exported and unknown keys are not newly marked");
  assert.equal(stored.get("1111111111111111"), true);
  assert.ok(sqls.every((sql) => /exported=0/.test(sql)), "only previously unexported records can be counted");
  const repeat = await postKeys(["1111111111111111"]);
  assert.deepEqual(await repeat.json(), { marked: 0 }, "an idempotent retry should not report another mark");
});


test("mark-exported refuses malformed individual hash keys before executing SQL", async () => {
  let writes = 0;
  const env = {
    ADMIN_TOKEN: "t",
    DB: {
      prepare: (sql) => ({ bind: (key) => ({ sql, key }) }),
      batch: async (statements) => {
        writes += statements.length;
        return statements.map(() => ({ meta: { changes: 1 } }));
      },
    },
  };
  for (const keys of [[null], [42], [{}], [true], [""], ["123"], ["not-a-hash"]]) {
    const reply = await worker.fetch(new Request("https://pool.test/v1/exported", {
      method: "POST",
      headers: { authorization: "Bearer t", "content-type": "application/json" },
      body: JSON.stringify({ keys }),
    }), env);
    assert.equal(reply.status, 400, JSON.stringify(keys));
    assert.equal(writes, 0, "invalid hashes must not touch D1");
  }
});

test("admin export rejects explicitly invalid game filters instead of exporting all games", async () => {
  const DB = fakeDB();
  const env = { DB, ADMIN_TOKEN: "t" };
  for (const query of ["title=invalid", "title=", "title=12345", "game=%00", "game=",
    "title=PPSA12345&game=%00"]) {
    DB.last = null;
    const response = await worker.fetch(new Request("https://pool.test/v1/export?" + query, {
      headers: { authorization: "Bearer t" },
    }), env);
    assert.equal(response.status, 400, query + " must be rejected");
    assert.equal(DB.last, null, "invalid filter must not execute an unfiltered SQL query");
  }
  const normal = await worker.fetch(new Request("https://pool.test/v1/export?title=ppsa12345", {
    headers: { authorization: "Bearer t" },
  }), env);
  assert.equal(normal.status, 200);
  assert.match(DB.last.sql, /title_id=\?/);
});

const APP_KEY = "gt-0123456789abcdef";
const postApp = (env, who, lines, { app = "GameTranslator 1.6.6", key } = {}) =>
  worker.fetch(new Request("https://pool.test/v1/lines", {
    method: "POST",
    headers: key ? { "X-CouchSubs-App-Key": key } : {},
    body: JSON.stringify({ install: who, app, lines }),
  }), env);

test("kendi istemcilerimizin app alanı tanınır, başkası tanınmaz", () => {
  for (const app of ["0.1.0", "0.1.0-beta.46", "1.2.3", "CouchSubs Android 0.9.23", "CouchSubs Android 1.0.0-beta.42"]) {
    assert.equal(ownApp(app), true, app);
  }
  for (const app of ["GameTranslator 1.6.6", "", "couchsubs", "CouchSubsX 1.0", undefined, 7]) {
    assert.equal(ownApp(app), false, String(app));
  }
});

test("anahtarsız üçüncü taraf uygulama 403 alır ve hiçbir şey yazılmaz", async () => {
  const DB = fakeDB();
  for (const env of [{ DB }, { DB, APP_KEYS: "bozuk json" }]) {
    const reply = await postApp(env, install(1), [{ text: "Get down!" }]);
    assert.equal(reply.status, 403);
    assert.deepEqual(await reply.json(), { error: "app_key_required" });
  }
  const wrong = await postApp({ DB, APP_KEYS: JSON.stringify({ [APP_KEY]: { name: "gametranslator" } }) },
    install(1), [{ text: "Get down!" }], { key: "yanlis-anahtar-0000" });
  assert.equal(wrong.status, 403);
  assert.deepEqual(await wrong.json(), { error: "app_key_invalid" });
  assert.equal(DB.writes, 0);
  assert.equal(DB.batchCalls, 0);
});

test("anahtarlı uygulama aynı süzgeç ve eşikle kabul edilir, uygulama adıyla günlüğe yazılır", async () => {
  const DB = fakeDB();
  const env = { DB, APP_KEYS: JSON.stringify({ [APP_KEY]: { name: "gametranslator", daily: 1000 } }) };
  const logged = [];
  const original = console.log;
  console.log = (line) => logged.push(String(line));
  try {
    const first = await postApp(env, install(1), [{ text: "Oturum Açtı" }, { text: "Get down!" }], { key: APP_KEY });
    assert.equal(first.status, 200);
    assert.deepEqual(await first.json(), { accepted: 1, recorded: 1, saturated: [] });
    assert.equal(DB.lines.size, 0, "tek kurulum havuza girmez");
    await postApp(env, install(2), [{ text: "Get down!" }], { key: APP_KEY });
    assert.deepEqual([...DB.lines.values()].map((l) => l.installs), [2]);
  } finally {
    console.log = original;
  }
  assert.ok(logged.some((l) => JSON.parse(l).client === "gametranslator" && JSON.parse(l).app === "GameTranslator 1.6.6"));
});

test("uygulamanın günlük toplam sınırı kurulum sınırına ek olarak uygulanır", async () => {
  const DB = fakeDB();
  const env = { DB, APP_KEYS: JSON.stringify({ [APP_KEY]: { name: "gametranslator", daily: 15 } }) };
  const day = new Date().toISOString().slice(0, 10);
  const lines = (n, tag) => Array.from({ length: n }, (_, j) => ({ text: `Hold the line ${tag} ${j} please.` }));
  const a = await postApp(env, install(1), lines(10, "a"), { key: APP_KEY });
  assert.deepEqual(await a.json(), { accepted: 10, recorded: 10, saturated: [] });
  const b = await postApp(env, install(2), lines(10, "b"), { key: APP_KEY });
  assert.deepEqual(await b.json(), { accepted: 5, recorded: 5, saturated: [] });
  const c = await postApp(env, install(3), lines(10, "c"), { key: APP_KEY });
  assert.equal(c.status, 429);
  assert.deepEqual(await c.json(), { error: "app_quota" });
  assert.ok(Number(c.headers.get("retry-after")) >= 60);
  assert.equal(DB.quotas.get(`app:gametranslator\u001f${day}`), 15);
  assert.equal(DB.quotaWrites, 3, "uygulama sayacı bir kez, iki kurulum birer kez");
  // Kendi istemcilerimiz uygulama sınırından etkilenmez.
  assert.equal((await postLines(env, install(4), lines(10, "d"))).status, 200);
});


test("GET /v1/stats reads the nightly R2 summary and never touches D1", async () => {
  resetStatsCache();
  let dbCalls = 0;
  const env = {
    DB: { prepare: () => { dbCalls++; throw new Error("D1 must not be used"); } },
    PACKS: { get: async (name) => name === STATS_KEY
      ? { text: async () => JSON.stringify({ lines: 10, confirmed: 4, installs: 3, updated: "2026-11-20T03:02:00.000Z" }) }
      : null },
  };
  const res = await worker.fetch(new Request("https://pool.test/v1/stats"), env);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { lines: 10, confirmed: 4, installs: 3, updated: "2026-11-20T03:02:00.000Z" });
  assert.equal(dbCalls, 0);
});

test("GET /v1/stats answers 200 with zeros before the first nightly summary and caches the miss briefly", async () => {
  resetStatsCache();
  let reads = 0;
  const env = { DB: {}, PACKS: { get: async () => { reads++; return null; } } };
  const first = await worker.fetch(new Request("https://pool.test/v1/stats"), env);
  assert.equal(first.status, 200);
  assert.deepEqual(await first.json(), { lines: 0, confirmed: 0, installs: 0, updated: null });
  await worker.fetch(new Request("https://pool.test/v1/stats"), env);
  assert.equal(reads, 1);
});

test("GET /v1/stats answers 200 with zeros when R2 fails", async () => {
  resetStatsCache();
  const ok = { DB: {}, PACKS: { get: async () => ({ text: async () => JSON.stringify({ lines: 5, confirmed: 2, installs: 1 }) }) } };
  assert.equal((await (await worker.fetch(new Request("https://pool.test/v1/stats"), ok)).json()).lines, 5);
  resetStatsCache();
  const broken = { DB: {}, PACKS: { get: async () => { throw new Error("R2 down"); } } };
  const res = await worker.fetch(new Request("https://pool.test/v1/stats"), broken);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).lines, 0);
});
