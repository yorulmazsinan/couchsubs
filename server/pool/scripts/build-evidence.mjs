// SPDX-License-Identifier: AGPL-3.0-only
// Elle hazırlanmış (döküm) paketin temizlik kanıtını yazar (src/packclean.js): gecelik havuz paketi, parçaları bu pakette
// zaten olan bozuk satırları (iki konuşmacının birleştiği, iki kez okunan, İngilizce büyük harf çöpü kalan) almaz.
// Elle paket değişince yeniden üretilip yüklenir (ad: auto/evidence/<elle paketin kimliği>.bin):
//   node scripts/build-evidence.mjs gta-6.json.gz > gta-6.bin
//   npx wrangler r2 object put couchsubs-packs/auto/evidence/gta-6.bin --file gta-6.bin --remote
// Kanıt yoksa havuz paketi yalnız kendi satırlarını kanıt sayar (daha az satır silinir).
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { buildEvidence, encodeEvidence } from "../src/packclean.js";

const files = process.argv.slice(2);
if (!files.length) throw new Error("Kullanım: node scripts/build-evidence.mjs <paket.json.gz>... > <kimlik>.bin");
const packs = files.map((file) => {
  const data = readFileSync(file);
  const pack = JSON.parse((data[0] === 0x1f && data[1] === 0x8b ? gunzipSync(data) : data).toString("utf8"));
  if (String(pack.id ?? "").startsWith("pool-")) throw new Error("Havuz paketi kanıt olamaz: " + file);
  if (!pack.entries || !Object.keys(pack.entries).length) throw new Error("Paket boş: " + file);
  return pack;
});
const bytes = encodeEvidence(buildEvidence(packs));
process.stderr.write(`${bytes.length} bayt\n`);
process.stdout.write(Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength));
