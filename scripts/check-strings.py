#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Mac ve iPhone/iPad uygulamalarındaki ekran metinlerini bulur ve Localizable.xcstrings'te Türkçesi olup olmadığını kontrol eder.
# Kullanım: python3 scripts/check-strings.py [--list]
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "mac" / "CouchSubs"
# iPhone/iPad uygulaması aynı katalogu kullanır (couchsubs-ios/project.yml).
SOURCE_DIRS = [SOURCES, ROOT / "couchsubs-ios" / "CouchSubs"]
CATALOG = SOURCES / "Resources" / "Localizable.xcstrings"

# Yerelleştirilen çağrılar: Text("…"), Button("…"), Label("…"), String(localized: "…"), title:/message:/text: "…" vb.
PATTERNS = [
    r'(?:Text|TextField|Button|Label|Link|Toggle|Section|Picker|GroupBox|confirmationDialog)\(\s*"((?:[^"\\]|\\.)*)"',
    r'String\(localized:\s*"((?:[^"\\]|\\.)*)"',
    r'(?:title|message|text):\s*"((?:[^"\\]|\\.)*)"',
    r'\?\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"',
]

def keys():
    found = set()
    for path in (p for d in SOURCE_DIRS for p in d.rglob("*.swift")):
        source = path.read_text()
        for pattern in PATTERNS:
            for match in re.findall(pattern, source):
                for key in (match if isinstance(match, tuple) else (match,)):
                    # SF Symbol adları (ör. "play.fill") ekran metni değildir.
                    if key and not re.fullmatch(r"[a-z0-9.]+", key) and "\\(" not in key:
                        found.add(key.replace('\\"', '"'))
    return found

def main():
    found = keys()
    if "--list" in sys.argv:
        print("\n".join(sorted(found)))
        return
    catalog = json.loads(CATALOG.read_text())["strings"]
    missing = sorted(k for k in found if k not in catalog or "tr" not in catalog[k].get("localizations", {}))
    if missing:
        print("Türkçesi eksik metinler:")
        print("\n".join("  " + k for k in missing))
        sys.exit(1)
    print(f"Tamam: {len(found)} metnin hepsinin Türkçesi var.")

main()
