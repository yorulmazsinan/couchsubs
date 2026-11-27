#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# Vestel Linux TV istemcisini (tv-vestel/, ARM Linux) dist/tv-app/couchsubs-vestel-tv olarak hazırlar; Mac uygulaması
# onu yalnız TV'ye kopyalanmak üzere taşır (Mac'te çalıştırılmaz). Kaynak: VESTEL_TV_CLIENT=/yol/hazır-ikili ya da Docker
# ile çapraz derleme. İkisi de yoksa uyarı verip atlar: uygulama "bu derlemede Vestel istemcisi yok" der, diğer TV'ler
# etkilenmez. package-tv.sh dist/tv-app'i baştan kurduğu için ondan SONRA çalıştırılır.
set -e
cd "${0:A:h}/.."
OUT=dist/tv-app/couchsubs-vestel-tv
mkdir -p dist/tv-app
if [[ -n "$VESTEL_TV_CLIENT" ]]; then
  cp "$VESTEL_TV_CLIENT" "$OUT"
elif command -v docker > /dev/null && docker info > /dev/null 2>&1; then
  docker build -q -t couchsubs-vestel-xc tv-vestel > /dev/null
  docker run --rm -v "$PWD/tv-vestel":/src -e OUT=out/couchsubs-vestel-tv couchsubs-vestel-xc /src/build.sh
  cp tv-vestel/out/couchsubs-vestel-tv "$OUT"
else
  echo "Uyarı: Docker yok ve VESTEL_TV_CLIENT verilmedi; Vestel Linux TV istemcisi pakete girmiyor."
  rm -f "$OUT"
  exit 0
fi
chmod 755 "$OUT"
file "$OUT" | grep -q 'ARM, EABI5' || { echo "HATA: $OUT ARM EABI5 Linux programı değil."; exit 1; }
echo "Vestel TV istemcisi: $OUT ($(shasum -a 256 "$OUT" | cut -d' ' -f1))"
