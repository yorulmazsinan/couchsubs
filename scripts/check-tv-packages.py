#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Uygulamaya konan TV paketlerinin sürümü kaynaktaki TV uygulamasıyla aynı mı.

iPhone build 39 (1.0.6) LG paketini son GitHub sürümünden (beta.79, TV 0.9.63) aldı; main'deki TV uygulaması 0.9.71'di.
Telefon TV'yi "TV uygulaması eski" diye güncelleyemedi. Bu denetim her mağaza/masaüstü derlemesinde paketlerin
sürümünü kaynakla karşılaştırır:
  - LG (.ipk): tv-webos/appinfo.json "version"
  - Samsung (.wgt): tv-tizen/config.xml version
  - Android TV (.apk): tv-android/app/build.gradle versionName

Kullanım: check-tv-packages.py <klasör> [--allow-missing apk,ipk,wgt]
  <klasör>: dist/tv-app (masaüstü, Mac App Store; dosya adlarında sürüm) ya da iPhone paketindeki tv/ klasörü
  (tv-packages.properties). Uyuşmazlık ya da eksik paket varsa 1 ile çıkar ve nedenini yazar.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source_versions(root: Path = ROOT) -> dict:
    webos = json.loads((root / "tv-webos" / "appinfo.json").read_text(encoding="utf-8"))["version"]
    config = (root / "tv-tizen" / "config.xml").read_text(encoding="utf-8")
    tizen = re.search(r'\sversion="([0-9.]+)"\s+viewmodes', config).group(1)
    gradle = (root / "tv-android" / "app" / "build.gradle").read_text(encoding="utf-8")
    android = re.search(r"versionName '([0-9.]+)'", gradle).group(1)
    return {"ipk": webos, "wgt": tizen, "apk": android}


def bundled_versions(directory: Path) -> dict:
    """Klasördeki paketlerin sürümleri ({"ipk": "0.9.71", ...}); bulunamayan tür yazılmaz."""
    found = {}
    props = directory / "tv-packages.properties"
    if props.is_file():
        values = dict(line.split("=", 1) for line in props.read_text(encoding="utf-8").splitlines() if "=" in line)
        if (directory / "couchsubs-lg.ipk").is_file():
            match = re.search(r"_([0-9.]+)_all\.ipk$", values.get("couchsubs-lg.ipk", ""))
            found["ipk"] = match.group(1) if match else "?"
        if (directory / "couchsubs-samsung.wgt").is_file():
            found["wgt"] = values.get("couchsubs-samsung.wgt.version", "?")
        if (directory / "couchsubs-androidtv.apk").is_file():
            found["apk"] = values.get("couchsubs-androidtv.apk.version", "?")
        return found
    patterns = {"ipk": r"_([0-9.]+)_all\.ipk$", "wgt": r"_([0-9.]+)\.wgt$", "apk": r"_([0-9.]+)\.apk$"}
    for kind, pattern in patterns.items():
        for path in sorted(directory.glob("*." + kind)):
            match = re.search(pattern, path.name)
            found[kind] = match.group(1) if match else "?"
    return found


NAMES = {"ipk": "LG (.ipk)", "wgt": "Samsung (.wgt)", "apk": "Android TV (.apk)"}


def problems(directory: Path, allow_missing=(), root: Path = ROOT) -> list:
    expected = source_versions(root)
    bundled = bundled_versions(directory)
    result = []
    for kind, want in expected.items():
        have = bundled.get(kind)
        if have is None:
            if kind not in allow_missing:
                result.append(f"{NAMES[kind]} paketi yok (kaynak {want})")
        elif have != want:
            result.append(f"{NAMES[kind]} paketi {have}, kaynaktaki TV uygulaması {want}")
    return result


def main(argv: list) -> int:
    if not argv or argv[0].startswith("-"):
        print("Kullanım: check-tv-packages.py <klasör> [--allow-missing apk,ipk,wgt]")
        return 2
    allow = ()
    if "--allow-missing" in argv:
        allow = tuple(argv[argv.index("--allow-missing") + 1].split(","))
    found = problems(Path(argv[0]), allow)
    for line in found:
        print("TV paketi uyuşmuyor: " + line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
