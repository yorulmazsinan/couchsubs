#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Samsung TV uygulamasını dist/tv-tizen/ altında toplar: ortak dosyalar tv-webos'tan, Tizen'e özgü olanlar
# tv-tizen'den gelir. TV'ye kurmak için Samsung sertifikasıyla imzalanmalıdır (docs/tv-samsung.md).
# TIZEN_PROFILE verilirse Tizen Studio'nun `tizen` aracıyla imzalı .wgt da üretir.
set -e
cd "$(dirname "$0")/.."
# COUCHSUBS_DIST: çıktı klasörü (testler geçici klasöre üretir; varsayılan dist).
DIST=${COUCHSUBS_DIST:-dist}
OUT=$DIST/tv-tizen/app
rm -rf "$DIST/tv-tizen"
mkdir -p "$OUT"
cp tv-webos/app.js tv-webos/i18n.js tv-webos/shell.js tv-webos/config.js tv-webos/index.html tv-webos/style.css tv-webos/largeIcon.png "$OUT/"
cp tv-webos/icon.png "$OUT/panel-icon.png"
cp tv-tizen/platform.js tv-tizen/config.xml tv-tizen/icon.png "$OUT/"
# Panel başlığındaki küçük simge webOS'taki gibi icon.png adını kullanamaz: Tizen'in simgesi büyüktür.
# Samsung'un ürün API'leri (ekran koruyucuyu kapatmak için webapis.appcommon) platform.js'ten önce yüklenir.
# Görünüm ortak sayfadaki gibi sabit "width=1920" kalır: Samsung UHD TV'de web uygulamasının standart çözünürlüğü
# (0.9.55; config.xml'deki açıklama). Geniş yüzeyde görünümü platform.js genişletir.
sed -e 's/src="icon.png"/src="panel-icon.png"/' \
    -e 's|  <script src="platform.js"></script>|  <script src="$WEBAPIS/webapis/webapis.js"></script>\n  <script src="platform.js"></script>|' \
    tv-webos/index.html > "$OUT/index.html"
# Masaüstü uygulamalarına gömülen imzasız paket: CouchSubs kurarken TV'ye özel sertifikayla imzalar.
VERSION=$(sed -n 's/.* version="\([0-9.]*\)" viewmodes.*/\1/p' tv-tizen/config.xml | head -1)
mkdir -p "$DIST/tv-app"
rm -f "$DIST"/tv-app/couchsubs-samsung_*.wgt
PY=$(command -v python3 || command -v python)
"$PY" - "$OUT" "$DIST/tv-app/couchsubs-samsung_$VERSION.wgt" <<'PYEOF'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for name in sorted(files):
            path = os.path.join(root, name)
            z.write(path, os.path.relpath(path, src).replace(os.sep, '/'))
PYEOF
echo "İmzasız paket: $DIST/tv-app/couchsubs-samsung_$VERSION.wgt"
if [ -n "$TIZEN_PROFILE" ]; then
  tizen package -t wgt -s "$TIZEN_PROFILE" -o "$DIST/tv-tizen" -- "$OUT"
  ls "$DIST"/tv-tizen/*.wgt
else
  echo "İmzasız kaynak hazır: $OUT (imza için TIZEN_PROFILE verin)"
fi
