// SPDX-License-Identifier: AGPL-3.0-only
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const script = fileURLToPath(new URL("../scripts/build-known.mjs", import.meta.url));
const defaultPacks = fileURLToPath(new URL("../../../core/Sources/CouchSubsCore/Resources/packs/", import.meta.url));

// Paketler depoda değil (özel R2, scripts/fetch-packs.py); inmemişse depo klasörü testi atlanır.
const havePacks = readdirSync(defaultPacks).some((name) => name.endsWith(".json.gz"));

test("build-known uses its default pack directory on all platforms", { skip: !havePacks && "gerçek paketler yok" }, () => {
  const options = { stdio: ["ignore", "pipe", "ignore"], maxBuffer: 16 * 1024 * 1024 };
  const explicit = execFileSync(process.execPath, [script, defaultPacks], options);
  const inferred = execFileSync(process.execPath, [script], options);

  assert.ok(explicit.length > 0);
  assert.deepStrictEqual(inferred, explicit);
});

test("build-known rejects non-64-bit manual keys rather than silently truncating them", () => {
  for (const invalid of ["10000000000000001", "1", "ghijklmnopqrstuv"]) {
    const dir = mkdtempSync(join(tmpdir(), "couchsubs-known-invalid-"));
    try {
      const pack = { format: 2, id: "test", title: "Test", entries: { [invalid]: "Example" }, segments: {} };
      writeFileSync(join(dir, "test.json.gz"), gzipSync(JSON.stringify(pack)));
      assert.throws(() => execFileSync(process.execPath, [script, dir], {
        stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1024 * 1024,
      }), undefined, "invalid key should fail: " + invalid);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});
