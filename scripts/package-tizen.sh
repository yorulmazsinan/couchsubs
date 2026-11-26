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
cp tv-webos/app.js tv-webos/i18n.js tv-webos/config.js tv-webos/index.html tv-webos/style.css tv-webos/largeIcon.png "$OUT/"
cp tv-webos/icon.png "$OUT/panel-icon.png"
# Ekran yazısının gömülü dar yazı tipi ve lisansı (style.css @font-face).
mkdir -p "$OUT/fonts"
cp tv-webos/fonts/BarlowCondensed-Medium.ttf tv-webos/fonts/BarlowCondensed-Bold.ttf tv-webos/fonts/OFL.txt "$OUT/fonts/"
cp tv-tizen/platform.js tv-tizen/config.xml tv-tizen/icon.png "$OUT/"
# Panel başlığındaki küçük simge webOS'taki gibi icon.png adını kullanamaz: Tizen'in simgesi büyüktür.
# Samsung'un ürün API'leri (ekran koruyucuyu kapatmak için webapis.appcommon) platform.js'ten önce yüklenir.
# Görünüm ortak sayfadaki gibi sabit "width=1920" kalır: Samsung UHD TV'de web uygulamasının standart çözünürlüğü
# (0.9.55; config.xml'deki açıklama). Geniş yüzeyde görünümü platform.js genişletir. LG Full HD için sayfa açılırken
# görünümü değiştiren blok (#1098, yalnız PalmSystem'de çalışır) Samsung paketine girmez.
sed -e 's/src="icon.png"/src="panel-icon.png"/' \
    -e '/<!-- LG Full HD/,/<\/script>/d' \
    -e 's|  <script src="platform.js"></script>|  <script src="$WEBAPIS/webapis/webapis.js"></script>\n  <script src="platform.js"></script>|' \
    tv-webos/index.html > "$OUT/index.html"
# Masaüstü uygulamalarına gömülen imzasız paket: CouchSubs kurarken TV'ye özel sertifikayla imzalar.
# XML attributes are unordered. Read the widget's version rather than assuming
# it is immediately followed by the viewmodes attribute.
PY=$(command -v python3 || command -v python)
VERSION=$("$PY" - tv-tizen/config.xml <<'PYEOF'
import sys
import xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).getroot().attrib["version"])
PYEOF
)
mkdir -p "$DIST/tv-app"
TARGET="$DIST/tv-app/couchsubs-samsung_$VERSION.wgt"
# Building directly into the release directory after deleting its old WGT
# can destroy the last usable installer on a zip/write failure.
STAGED=$(mktemp "$DIST/tv-app/.couchsubs-samsung-XXXXXX")
trap 'rm -f "$STAGED"' EXIT
"$PY" - "$OUT" "$STAGED" <<'PYEOF'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for name in sorted(files):
            path = os.path.join(root, name)
            z.write(path, os.path.relpath(path, src).replace(os.sep, '/'))
PYEOF
mv -f "$STAGED" "$TARGET"
trap - EXIT
for old in "$DIST"/tv-app/couchsubs-samsung_*.wgt; do
  [ "$old" = "$TARGET" ] || rm -f "$old"
done
echo "İmzasız paket: $TARGET"
if [ -n "$TIZEN_PROFILE" ]; then
  tizen package -t wgt -s "$TIZEN_PROFILE" -o "$DIST/tv-tizen" -- "$OUT"
  ls "$DIST"/tv-tizen/*.wgt
else
  echo "İmzasız kaynak hazır: $OUT (imza için TIZEN_PROFILE verin)"
fi
