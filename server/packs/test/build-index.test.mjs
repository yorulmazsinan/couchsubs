// SPDX-License-Identifier: AGPL-3.0-only
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { gzipSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../scripts/build-index.mjs", import.meta.url));
const defaultPacks = fileURLToPath(new URL("../../../core/Sources/CouchSubsCore/Resources/packs/", import.meta.url));

// Paketler depoda değil (özel R2, scripts/fetch-packs.py); inmemişse depo klasörü testi atlanır.
const havePacks = readdirSync(defaultPacks).some(name => name.endsWith(".json.gz"));

describe("build-index.mjs", () => {
  it.skipIf(!havePacks)("uses the repository pack folder when no directory argument is supplied", () => {
    const expectedCount = readdirSync(defaultPacks).filter(name => name.endsWith(".json.gz")).length;
    expect(expectedCount).toBeGreaterThan(0);

    const output = execFileSync(process.execPath, [script], { encoding: "utf8" });
    const result = JSON.parse(output);

    expect(result.packs).toHaveLength(expectedCount);
  });
});

it.each(["invalid", "-1", "1.5", "Infinity"])("refuses invalid pack index version %s", (version) => {
  expect(() => execFileSync(process.execPath, [script, defaultPacks, version], {
    encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
  })).toThrow();
});

it("refuses an index whose advertised pack ID does not match its downloadable filename", () => {

  const dir = mkdtempSync(join(tmpdir(), "couchsubs-index-test-"));
  try {
    writeFileSync(join(dir, "expected-id.json.gz"), gzipSync(Buffer.from(JSON.stringify({
      format: 2, id: "different-id", title: "Mismatch", entries: { abcd: "Example" },
    }))));
    expect(() => execFileSync(process.execPath, [script, dir, "7"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    })).toThrow();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

it.each([
  ["invalid characters in package ID", "invalid_name", { format: 2, id: "invalid_name", title: "Game", entries: { abc: "Text" } }],
  ["blank package title", "valid-game", { format: 2, id: "valid-game", title: " ", entries: { abc: "Text" } }],
  ["non-object subtitle entries", "valid-game", { format: 2, id: "valid-game", title: "Game", entries: "not a map" }],
])("does not generate an index rejected by the pack API: %s", (_label, id, manifest) => {
  const dir = mkdtempSync(join(tmpdir(), "couchsubs-invalid-index-"));
  try {
    writeFileSync(join(dir, id + ".json.gz"), gzipSync(Buffer.from(JSON.stringify(manifest))));
    expect(() => execFileSync(process.execPath, [script, dir, "7"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    })).toThrow();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
