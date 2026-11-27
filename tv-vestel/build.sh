#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Konteyner içinde çalışır (Dockerfile'daki arm-linux-gnueabi). Vestel Linux TV istemcisini derler ve
# TV'nin ABI'sine uyduğunu denetler: ARM EABI5 soft-float, /lib/ld-linux.so.3, glibc <= 2.18.
set -e
cd /src
CC=arm-linux-gnueabi-gcc; READELF=arm-linux-gnueabi-readelf
OUT=${OUT:-out/couchsubs-vestel-tv}
mkdir -p "$(dirname "$OUT")"
$CC -Idfb-include -Os -o "$OUT" src/subtitle_client.c src/sse.c src/pair.c -ldl
$READELF -h "$OUT" | grep -q 'soft-float' || { echo "HATA: soft-float degil"; exit 1; }
L=$($READELF -l "$OUT" | sed -n 's/.*interpreter: \(.*\)]/\1/p')
[ "$L" = "/lib/ld-linux.so.3" ] || { echo "HATA: yukleyici $L"; exit 1; }
if $READELF --version-info "$OUT" | grep -oE 'GLIBC_2\.[0-9]+' | awk -F. '$2>18{f=1} END{exit !f}'; then
  echo "HATA: glibc 2.18'den yeni sembol"; exit 1
fi
echo "Hazir: $OUT"
