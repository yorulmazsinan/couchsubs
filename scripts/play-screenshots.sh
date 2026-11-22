#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# Google Play için Android TV ekran görüntüleri (1920×1080): TV uygulamasının gerçek sayfası (tv-webos + tv-android/platform.js)
# Chrome'da, Android köprüsü ve bilgisayar bağlantısı taklit edilerek çizilir (scripts/play-screenshot-harness.js).
# HDMI görüntüsü TV'de sayfanın altındaki ayrı katmandadır ve ekran görüntüsüne girmez; arka plan bu yüzden düz koyudur.
# Çıktı: tv-android/fastlane/metadata/android/<dil>/images/tvScreenshots/
# Kullanım: ~/Projeler/Web/enmera/ekip/heavy-job.sh ./scripts/play-screenshots.sh   (depo kökünden)
set -e
cd "${0:A:h}/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "$CHROME" ]] || { echo "Chrome yok: CHROME=/yol/chrome ile verin."; exit 1; }

PAGE=$(mktemp -d)
PROFILE=$(mktemp -d)
trap 'rm -rf "$PAGE" "$PROFILE"' EXIT
cp tv-webos/{app.js,i18n.js,shell.js,config.js,style.css,icon.png,largeIcon.png} tv-android/platform.js "$PAGE/"
cp scripts/play-screenshot-harness.js "$PAGE/harness.js"
# Taklit köprü platform.js'ten önce yüklenir.
sed 's|<script src="platform.js"></script>|<script src="harness.js"></script><script src="platform.js"></script>|' \
  tv-webos/index.html > "$PAGE/index.html"

typeset -A LANGS=(tr-TR tr en-US en)
STATES=(demo stacked waiting panel)
for locale lang in ${(kv)LANGS}; do
  OUT="tv-android/fastlane/metadata/android/$locale/images/tvScreenshots"
  rm -rf "$OUT"
  mkdir -p "$OUT"
  i=1
  for state in $STATES; do
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1920,1080 \
      --user-data-dir="$PROFILE" --allow-file-access-from-files --default-background-color=0E0F13FF \
      --virtual-time-budget=2500 --screenshot="$PWD/$OUT/$i-$state.png" \
      "file://$PAGE/index.html?lang=$lang&state=$state" >/dev/null 2>&1
    echo "$OUT/$i-$state.png"
    i=$((i + 1))
  done
done
