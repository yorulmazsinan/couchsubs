#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# CouchSubs'ın macOS sürümünü derler ve dist/CouchSubs-<sürüm>-macos.zip olarak paketler.
# DEVELOPER_ID ("Developer ID Application: ... (TAKIM)") verilirse imzalar; NOTARY_PROFILE
# (xcrun notarytool store-credentials ile kaydedilmiş profil) da verilirse Apple'a onaylatır.
# Profil varsayılan anahtar zincirinde değilse NOTARY_KEYCHAIN ile yolu verilir (CI).
# Sürüm son v* etiketinden (APP_VERSION ile değiştirilebilir), yapı numarası commit sayısından gelir; Sparkle
# güncellemeleri yapı numarasıyla karşılaştırır. Onaylı pakette ayrıca dist/CouchSubs-macos.dmg ve, Sparkle anahtarı
# (SPARKLE_KEY, varsayılan ~/Library/Application Support/CouchSubs-release/sparkle-ed25519.pem) varsa,
# dist/appcast.xml çıkar.
set -e
setopt pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Eski (yalnız Apple Silicon) Remote Play kütüphanesi varsa evrensel olarak yeniden derlenir.
# Xcode 27'nin lipo'su -verify_arch'ta tek mimari kabul ediyor (ikisi birden her zaman "yok" diyordu); ayrı ayrı denetlenir.
universal() { [[ -f "$1" ]] && lipo "$1" -verify_arch arm64 && lipo "$1" -verify_arch x86_64; }
MAC_SLICE=(third-party/build/CChiaki.xcframework/macos-*/libCChiaki.a(N))
universal "${MAC_SLICE[1]}" || ./scripts/build-chiaki-macos.sh

./scripts/package-tv.sh
./scripts/package-tizen.sh
# Android TV APK'sı verilirse (CI: tv-android iş akışının çıktısı) uygulamaya gömülür.
[[ -n "$ANDROID_APK" ]] && ./scripts/bundle-android-apk.sh "$ANDROID_APK"
# Kaynağı değiştiyse (ya da damgasız eski bir derlemeyse) yeniden derlenir: dist'te kalan eski yardımcı pakete girmesin.
./scripts/build-tv-helper.sh --if-changed
# Yardımcılar da evrensel olmalı (önceden ya da CI'da yalnız Apple Silicon için hazırlanmış olabilir).
universal dist/tv-helper/couchsubs-tv-helper || ./scripts/build-tv-helper.sh
universal dist/tts/pocket-tts || ./scripts/fetch-pocket-tts.sh mac

BUILD="$PWD/build/mac"
rm -rf "$BUILD"
mkdir -p build
(cd mac && xcodegen generate --quiet)

# GitHub Actions'ta etiket ortamdan gelir (sığ klonda git describe çalışmaz).
[[ "$GITHUB_REF_TYPE" == tag ]] && APP_VERSION="${APP_VERSION:-${GITHUB_REF_NAME#v}}"
APP_VERSION="${APP_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
VERSION_ARGS=(MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

SIGN_ARGS=(CODE_SIGN_IDENTITY="-")
if [[ -n "$DEVELOPER_ID" ]]; then
  TEAM="${DEVELOPER_ID##*\(}"; TEAM="${TEAM%\)}"
  # Xcode'un eklediği get-task-allow yetkisi olursa Apple onayı reddedilir.
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM"
             OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

# Yardımcılar uygulamaya kopyalanmadan önce kendi başına imzalanır (Apple onayı sıkılaştırılmış çalışma ister).
for HELPER in dist/tv-helper/couchsubs-tv-helper dist/tts/pocket-tts; do
  if [[ -n "$DEVELOPER_ID" ]]; then
    codesign --force --options runtime --timestamp -s "$DEVELOPER_ID" "$HELPER"
  else
    codesign --force -s - "$HELPER"
  fi
done

# XCODE_JOBS: bilgisayar yüklüyken derlemeyi hafifletmek için (verilmezse Xcode kendi seçer).
JOB_ARGS=()
[[ -n "$XCODE_JOBS" ]] && JOB_ARGS=(-jobs "$XCODE_JOBS")

xcodebuild -project mac/CouchSubs.xcodeproj -scheme CouchSubs -configuration Release \
  -derivedDataPath "$BUILD" "${JOB_ARGS[@]}" "${SIGN_ARGS[@]}" "${VERSION_ARGS[@]}" build > "$BUILD.log" 2>&1 \
  || { grep -E "error:" "$BUILD.log" | head -20; echo "Derleme başarısız, ayrıntı: $BUILD.log"; exit 1; }

APP="$BUILD/Build/Products/Release/CouchSubs.app"
[[ -d "$APP" ]] || { echo "Derleme başarısız."; exit 1; }
# En eski desteklenen macOS (mac/project.yml) ve mimariler: her program Apple Silicon ve Intel dilimini içermeli, o
# macOS'tan yenisini istememeli. 27 SDK'sıyla gelen pipe2/dup3 zorunlu istenirse uygulama eski macOS'ta açılışta kapanır
# (fikir: jardeux, #10). Translation çerçevesi macOS 15'te geldi; zayıf bağlanmazsa uygulama macOS 13/14'te açılmaz.
MIN_MACOS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")
for BIN in "$APP"/Contents/MacOS/*; do
  for ARCH in arm64 x86_64; do
    lipo "$BIN" -verify_arch $ARCH || { echo "$BIN içinde $ARCH dilimi yok (Apple Silicon ve Intel)."; exit 1; }
    NEWEST=$(otool -arch $ARCH -l "$BIN" | awk '/minos/ {print $2}' | sort -V | tail -1)
    if [[ -n "$NEWEST" && "$(printf '%s\n%s\n' "$NEWEST" "$MIN_MACOS" | sort -V | tail -1)" != "$MIN_MACOS" ]]; then
      echo "$BIN ($ARCH) macOS $NEWEST istiyor; en eski desteklenen macOS $MIN_MACOS."; exit 1
    fi
  done
  if dyld_info -imports "$BIN" | grep -E "[[:space:]]_(pipe2|dup3)[[:space:]]" | grep -qv weak-import; then
    echo "$BIN macOS $MIN_MACOS'te olmayan pipe2/dup3'ü istiyor; uygulama eski macOS'ta açılmaz."; exit 1
  fi
  if otool -L "$BIN" | grep "Translation.framework" | grep -qv weak; then
    echo "$BIN Translation çerçevesine zayıf bağlanmamış; uygulama macOS 13/14'te açılmaz."; exit 1
  fi
done
if [[ -n "$DEVELOPER_ID" ]]; then
  # Sparkle'ın iç yardımcıları da bizim kimliğimizle, sıkılaştırılmış çalışmayla imzalanır (Sparkle belgelerindeki
  # sıra: içten dışa), ardından uygulama yeniden mühürlenir.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  for ITEM in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
              "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    EXTRA=()
    [[ "$ITEM" == *Downloader.xpc ]] && EXTRA=(--preserve-metadata=entitlements)
    codesign --force --options runtime --timestamp "${EXTRA[@]}" -s "$DEVELOPER_ID" "$ITEM"
  done
  codesign --force --options runtime --timestamp --entitlements mac/CouchSubs/CouchSubs.entitlements -s "$DEVELOPER_ID" "$APP"
  codesign --verify --deep --strict "$APP" || { echo "İmza doğrulanamadı."; exit 1; }
fi
[[ -x "$APP/Contents/MacOS/couchsubs-tv-helper" ]] || { echo "TV kurulum yardımcısı pakette yok."; exit 1; }
[[ -x "$APP/Contents/MacOS/pocket-tts" ]] || { echo "Dublaj ses motoru (pocket-tts) pakette yok."; exit 1; }
# package-tv.sh dist/tv-app'i baştan kurar; APK yalnız ANDROID_APK verilince geri eklenir. Yerel deneme derlemesi için
# ALLOW_NO_APK=1 ile atlanır.
APKS=("$APP"/Contents/Resources/tv-app/*.apk(N))
if [[ -z "$ALLOW_NO_APK" ]] && (( ${#APKS} == 0 )); then
  echo "Android TV paketi (APK) uygulamada yok: ANDROID_APK=/yol/couchsubs-androidtv.apk ile çalıştırın."; exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/CouchSubs-$VERSION-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "$DEVELOPER_ID" && -n "$NOTARY_PROFILE" ]]; then
  KEYCHAIN_ARGS=()
  [[ -n "$NOTARY_KEYCHAIN" ]] && KEYCHAIN_ARGS=(--keychain "$NOTARY_KEYCHAIN")
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" "${KEYCHAIN_ARGS[@]}" --wait \
    | tee "$BUILD-notary.log"
  grep -q "status: Accepted" "$BUILD-notary.log" || { echo "Apple onayı reddedildi, ayrıntı: $BUILD-notary.log"; exit 1; }
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
  echo "İmzalandı ve onaylandı."
  # İlk kurulum için DMG: açınca "Uygulamalar klasörüne sürükle".
  DMG=dist/CouchSubs-macos.dmg
  STAGE="$BUILD-dmg"
  rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/CouchSubs.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname CouchSubs -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  codesign --force --timestamp -s "$DEVELOPER_ID" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" "${KEYCHAIN_ARGS[@]}" --wait | tee "$BUILD-notary-dmg.log"
  grep -q "status: Accepted" "$BUILD-notary-dmg.log" || { echo "DMG Apple onayı reddedildi, ayrıntı: $BUILD-notary-dmg.log"; exit 1; }
  xcrun stapler staple "$DMG"
  echo "Hazır: $DMG"

  # Sparkle appcast'i: güncelleme bu sürümün etiketindeki CouchSubs-macos.zip'i indirir, imzayı doğrular.
  SPARKLE_KEY="${SPARKLE_KEY:-$HOME/Library/Application Support/CouchSubs-release/sparkle-ed25519.pem}"
  OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
  if [[ -f "$SPARKLE_KEY" && -x "$OPENSSL" ]]; then
    # İmza Info.plist'teki açık anahtarla doğrulanır; yanlış anahtarla imzalanmış appcast güncellemeyi kırar.
    PUBLIC=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$APP/Contents/Info.plist")
    [[ "$("$OPENSSL" pkey -in "$SPARKLE_KEY" -pubout -outform DER | tail -c 32 | base64)" == "$PUBLIC" ]] \
      || { echo "Sparkle anahtarı uygulamadaki açık anahtarla eşleşmiyor."; exit 1; }
    SIGNATURE=$("$OPENSSL" pkeyutl -sign -inkey "$SPARKLE_KEY" -rawin -in "$ZIP" | base64)
    LENGTH=$(stat -f %z "$ZIP")
    PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
    PAGE="https://github.com/yorulmazsinan/couchsubs/releases/tag/v$APP_VERSION"
    {
      echo '<?xml version="1.0" encoding="utf-8"?>'
      echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
      echo '  <channel>'
      echo '    <title>CouchSubs</title>'
      echo '    <item>'
      echo "      <title>CouchSubs $APP_VERSION</title>"
      echo "      <pubDate>$PUBDATE</pubDate>"
      echo "      <sparkle:version>$BUILD_NUMBER</sparkle:version>"
      echo "      <sparkle:shortVersionString>$APP_VERSION</sparkle:shortVersionString>"
      echo "      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>"
      echo "      <link>$PAGE</link>"
      echo "      <sparkle:fullReleaseNotesLink>$PAGE</sparkle:fullReleaseNotesLink>"
      echo "      <enclosure url=\"https://github.com/yorulmazsinan/couchsubs/releases/download/v$APP_VERSION/CouchSubs-macos.zip\""
      echo "                 length=\"$LENGTH\" type=\"application/octet-stream\" sparkle:edSignature=\"$SIGNATURE\" />"
      echo '    </item>'
      echo '  </channel>'
      echo '</rss>'
    } > dist/appcast.xml
    echo "Hazır: dist/appcast.xml (sürüm $APP_VERSION, yapı $BUILD_NUMBER)"
  else
    echo "Uyarı: Sparkle anahtarı yok, appcast üretilmedi ($SPARKLE_KEY)."
  fi
elif [[ -n "$DEVELOPER_ID" ]]; then
  echo "Uyarı: imzalı ama Apple onaysız. İlk açılışta Sistem Ayarları › Gizlilik ve Güvenlik › Yine de Aç gerekir."
else
  echo "Uyarı: imzasız paket. İlk açılışta Sistem Ayarları › Gizlilik ve Güvenlik › Yine de Aç gerekir."
fi
echo "Hazır: $ZIP"
