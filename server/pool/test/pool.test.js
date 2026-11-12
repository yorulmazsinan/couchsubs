// SPDX-License-Identifier: AGPL-3.0-only
// Ağ yok: süzgeç ve gönderimin D1'e kaç yazma yaptığı sahte bir veritabanıyla denenir. Çalıştırma: `npm test`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { accepts } from "../src/filter.js";
import worker from "../src/index.js";

test("Türkçe arayüz, bozulmuş Türkçe, sistem yazısı ve yarım okumalar alınmaz", () => {
  for (const line of [
    "Oturum Açtı", "Oturum Aqtl", "Oturum Aqtl.", "Sifirlama Seqenekleri", "Sifirlama Seqenekleri.",
    "PS5 Sistemini Yeniden Baslat", "PS5 Sistemini Yeniden Baslat.", "Oyunu Kapat", "Ana Ekranda Tut",
    "Lütfen bekleyin..", "Ekran ve Video", "ilerlemenizi takip edin Kupalar", "Keşfet PS5 ile ilgili Öne Çıkanlar",
    "Ekran görüntüsü kaydedildi.", "Kupa kazandınız!", "John signed in.", "You've earned a trophy!",
    "Please do not quit or turn off your console while the Rockstar cloud save icon is showing.",
    "GO to the", "Take out the trash and the", "it Auto V's Story Mode.", "FREE MONTH OF GTA+", "PHOTO MODE SELECT",
    "Main menu", "Hold on", "HP 100/100 MP 25/50", "Okay.",
  ]) assert.equal(accepts(line), false, line);
});

test("İngilizce oyun satırları alınır", () => {
  for (const line of [
    "Herr Müller will see you now.", "This place was designed in a hurry.", "Tell Sam I signed the deal.",
    "I lie to you, you lie to me.", "DON TORRISI WANTS YOU!", "Get down!", "Who's there?", "Line number 7 here",
    "We need to move before the cops show up", "Give me 50 dollars, Enzo.",
  ]) assert.equal(accepts(line), true, line);
});

// D1'in yalnız bu dosyadaki sorguları kadarını taklit eder; her çalışan yazma deyimini sayar.
function fakeDB() {
  const sightings = new Set();
  const lines = new Map();
  const db = { writes: 0, lines, quota: 0 };
  const run = (sql, args) => {
    if (sql.startsWith("SELECT count FROM quota")) return { count: db.quota };
    db.writes++;
    if (sql.startsWith("INSERT OR IGNORE INTO sightings")) {
      const id = args.join("|");
      const changes = sightings.has(id) ? 0 : 1;
      sightings.add(id);
      return { meta: { changes } };
    }
    if (sql.startsWith("INSERT INTO lines")) {
      const [k, text] = args;
      const row = lines.get(k);
      lines.set(k, row ? { ...row, installs: row.installs + 1 } : { text, installs: 1 });
      return { meta: { changes: 1 } };
    }
    if (sql.startsWith("INSERT INTO quota")) {
      db.quota += args[2];
      return { meta: { changes: 1 } };
    }
    throw new Error(sql);
  };
  db.prepare = (sql) => ({
    bind: (...args) => ({ first: async () => run(sql, args), run: async () => run(sql, args), sql, args }),
  });
  db.batch = async (stmts) => stmts.map((s) => run(s.sql, s.args));
  return db;
}

const install = (n) => `00000000-0000-4000-8000-00000000000${n}`;
const post = (env, who, texts) => worker.fetch(new Request("https://pool.test/v1/lines", {
  method: "POST",
  body: JSON.stringify({ install: who, lines: texts.map((text) => ({ text })) }),
}), env);

test("gönderim süzer ve satır başına en çok iki yazma yapar", async () => {
  const DB = fakeDB();
  const env = { DB };
  const reply = await post(env, install(1), ["Oturum Açtı", "Get down!", "Get down!", "Who is that over there?"]);
  assert.deepEqual(await reply.json(), { accepted: 2, recorded: 2 });
  // 2 görülme + 2 satır + 1 kota.
  assert.equal(DB.writes, 5);
  assert.equal(DB.lines.size, 2);

  // Aynı kurulum aynı satırları yeniden gönderirse yalnız görülme denemesi ve kota yazılır.
  DB.writes = 0;
  await post(env, install(1), ["Get down!", "Who is that over there?"]);
  assert.equal(DB.writes, 3);
  assert.deepEqual([...DB.lines.values()].map((l) => l.installs), [1, 1]);

  // Başka kurulum: sayaç bir artar.
  await post(env, install(2), ["Get down!"]);
  assert.deepEqual([...DB.lines.values()].map((l) => l.installs), [2, 1]);
});
