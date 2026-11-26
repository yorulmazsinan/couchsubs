#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# TV uygulamasını dist/tv-app/ altında paketler. Mac ve Windows uygulamaları bu paketi içerir;
# geliştirici modu açık TV'ye kendileri kurar.
set -e
cd "$(dirname "$0")/.."
# Do not delete the shared installer directory: Samsung WGT and Android APK
# are stored here too. Build the LG package off to the side first.
mkdir -p dist/tv-app
STAGED=$(mktemp -d dist/.tv-webos-XXXXXX)
trap 'rm -rf "$STAGED"' EXIT
ares-package tv-webos -o "$STAGED" -n
set -- "$STAGED"/*.ipk
[ "$#" -eq 1 ] && [ -f "$1" ] || { echo "LG IPK paketi oluşturulamadı" >&2; exit 1; }
# Zaman damgaları geçmişe çekilir: saati geride kalan TV paketi "ipk verified failed" (-5) ile reddeder.
# Windows'ta python3 Mağaza yönlendirmesi olabilir; gerçekten çalışan ilk yorumlayıcı seçilir.
PY=""
for candidate in python3 python py; do
  if "$candidate" -c "" >/dev/null 2>&1; then PY=$candidate; break; fi
done
[ -n "$PY" ] || { echo "python bulunamadı" >&2; exit 1; }
"$PY" scripts/normalize-ipk.py "$1"
TARGET="dist/tv-app/$(basename "$1")"
mv -f "$1" "$TARGET"
for old in dist/tv-app/*.ipk; do
  [ "$old" = "$TARGET" ] || rm -f "$old"
done
ls "$TARGET"
