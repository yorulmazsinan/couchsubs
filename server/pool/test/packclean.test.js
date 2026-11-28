import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { buildEvidence, cleanPool, decodeEvidence, encodeEvidence, EMPTY_EVIDENCE } from "../src/packclean.js";
import { packBody } from "../src/autopack.js";

// tools/packs/packclean.py ile ortak deneme dosyası: aynı paketlerden aynı satırlar silinmeli.
const cases = JSON.parse(readFileSync(new URL("../../../tools/packs/fixtures/packclean-cases.json", import.meta.url), "utf8"));
const clone = (value) => JSON.parse(JSON.stringify(value));
const mains = cases.packs.filter((p) => !p.id.startsWith("pool-"));
const pools = cases.packs.filter((p) => p.id.startsWith("pool-"));

test("havuz paketi packclean.py ile aynı satırları siler (kanıt dosyası üzerinden)", () => {
  const evidence = decodeEvidence(encodeEvidence(buildEvidence(clone(mains))));
  const mainKeys = new Set(mains.flatMap((p) => [...Object.keys(p.entries), ...Object.keys(p.segments)]));
  for (const pack of pools) {
    const copy = clone(pack);
    const removed = cleanPool(copy, evidence, (k) => mainKeys.has(k));
    const expected = cases.removed.filter((r) => r.pack === pack.id).map(({ section, key, reason }) => ({ section, key, reason }));
    assert.deepEqual(removed.map(({ section, key, reason }) => ({ section, key, reason })), expected);
    assert.ok(expected.length > 0);
    // Kalan satırların Türkçesi (küfür dahil) aynen durur.
    for (const section of ["entries", "segments"]) {
      for (const [key, value] of Object.entries(copy[section])) assert.equal(value, pack[section][key]);
    }
  }
});

test("döküm paketinin kendi temizliği de packclean.py ile aynı", () => {
  for (const [i, pack] of mains.entries()) {
    const merged = { entries: {}, segments: {} };
    for (const section of ["entries", "segments"]) {
      for (const [key, value] of Object.entries(pack[section])) merged[section][`${i}:${key}`] = value;
    }
    const removed = cleanPool(merged, EMPTY_EVIDENCE).map(({ section, key, reason }) => ({ section, key: key.split(":")[1], reason }));
    const expected = cases.removed.filter((r) => r.pack === pack.id).map(({ section, key, reason }) => ({ section, key, reason }));
    assert.deepEqual(removed, expected);
  }
});

test("gecelik paket gövdesi bozuk satırı almaz, dökümdeki anahtarı atlar", () => {
  const evidence = buildEvidence(clone(mains));
  const pool = pools[0];
  const lines = {};
  for (const [key, tr] of Object.entries(pool.entries)) lines[key] = { k: key, en: `english ${key}`, tr };
  const known = new BigUint64Array([...Object.keys(mains[0].entries)].map((k) => BigInt("0x" + k)).sort((a, b) => (a < b ? -1 : 1)));
  const body = JSON.parse(packBody("pool-gta-6", "GTA 6", { lines }, known, null, evidence).body);
  const values = Object.values(body.entries);
  assert.ok(!values.includes("LOESERT Şuraya geç."));
  assert.ok(!values.includes("Arabaya gir."));
  assert.ok(values.includes("Siktir git o zaman! Boobie: Bu da kimdi amına koyayım?"));
  // Kanıt yoksa da (dosya inmedi) çalışır; yalnız havuzun kendi satırları kanıt sayılır.
  assert.ok(JSON.parse(packBody("pool-gta-6", "GTA 6", { lines }, known, null).body).entries);
});
