// SPDX-License-Identifier: AGPL-3.0-only
// Paket klasöründen (varsayılan: core/Sources/CouchSubsCore/Resources/packs) R2'ye yüklenecek index.json'u üretir.
// Kullanım: node scripts/build-index.mjs [paket-klasörü] [sürüm] > index.json
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";

const dir = process.argv[2] ?? new URL("../../../core/Sources/CouchSubsCore/Resources/packs", import.meta.url).pathname;
const version = Number(process.argv[3] ?? Math.floor(Date.now() / 1000));

const packs = readdirSync(dir)
  .filter((name) => name.endsWith(".json.gz"))
  .sort()
  .map((name) => {
    const data = readFileSync(join(dir, name));
    const parsed = JSON.parse(gunzipSync(data).toString("utf8"));
    const id = parsed.id ?? name.replace(/\.json\.gz$/, "");
    const entries = Object.keys(parsed.entries ?? parsed).length;
    return { id, title: parsed.title ?? id, version, sha256: createHash("sha256").update(data).digest("hex"), size: data.length, entries };
  });

process.stdout.write(JSON.stringify({ packs }, null, 2) + "\n");
