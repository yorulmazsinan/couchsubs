#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# App Store sürümlerini arşivler ve App Store Connect'e (yalnız iç TestFlight) yükler. Ayrıntı: docs/app-store.md.
# Kullanım: release-appstore.sh ios|mac <yapı numarası> [--no-upload | --unsigned]
#   ios: couchsubs-ios (iPhone/iPad), mac: mac/CouchSubsAppStore (Mac App Store, sandbox'lı). İkisi de com.couchsubs.ios.
#   Yapı numarası her platformda bir öncekinden büyük olmalı (App Store Connect › TestFlight'ta son yapıya bakın).
#   --no-upload: yüklemeden dist/appstore/export-<platform> altına dışa aktarır.
#   --unsigned: Apple hesabı olmadan Release arşivinin derlendiğini ve (Mac) sandbox denetimlerini sınar; iOS imzasız,
#   Mac ad-hoc imzalı arşiv üretir, yüklemez. Bu arşiv App Store'a gönderilemez.
# İmza otomatik (takım 79N3CT6T46): Xcode › Settings › Accounts'ta Enmera'nın Apple hesabı açık olmalı.
# Sürüm (CFBundleShortVersionString) son v* etiketinin sayı kısmıdır (v0.1.0-beta.31 → 0.1.0); APP_VERSION ile değişir.
set -e
setopt pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

PLATFORM=$1
BUILD=$2
[[ ( "$PLATFORM" == ios || "$PLATFORM" == mac ) && "$BUILD" == <-> ]] || { echo "Kullanım: $0 ios|mac <yapı numarası> [--no-upload | --unsigned]"; exit 1; }
VERSION="${APP_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed -E 's/^v([0-9]+(\.[0-9]+){0,2}).*/\1/')}"
VERSION="${VERSION:-0.1.0}"
OUT=dist/appstore
ARCHIVE="$OUT/CouchSubs-$PLATFORM-$VERSION-$BUILD.xcarchive"
[[ "$3" == --unsigned ]] && ARCHIVE="$OUT/CouchSubs-$PLATFORM-$VERSION-$BUILD-unsigned.xcarchive"
mkdir -p "$OUT"

OPTIONS=scripts/appstore/ExportOptions.plist
EXPORT="$OUT/export-$PLATFORM"
if [[ "$3" == --no-upload ]]; then
  OPTIONS="$OUT/ExportOptions-export.plist"
  cp scripts/appstore/ExportOptions.plist "$OPTIONS"
  plutil -replace destination -string export "$OPTIONS"
fi

VERSION_ARGS=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD")
SIGN_ARGS=(-allowProvisioningUpdates DEVELOPMENT_TEAM=79N3CT6T46 CODE_SIGN_STYLE=Automatic)
if [[ "$3" == --unsigned && "$PLATFORM" == ios ]]; then
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
elif [[ "$3" == --unsigned ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
fi

if [[ "$PLATFORM" == ios ]]; then
  # Remote Play kütüphanesinin iPhone dilimi gerekir (scripts/build-chiaki-ios.sh).
  [[ -d third-party/build/CChiaki.xcframework/ios-arm64 ]] || { echo "CChiaki.xcframework'te iOS dilimi yok: scripts/build-chiaki-ios.sh"; exit 1; }
  (cd couchsubs-ios && xcodegen generate --quiet)
  # Apple multicast iznini onaylamadan önce TestFlight yapısı: COUCHSUBS_NO_MULTICAST=1 izni yetki dosyasından çıkarır;
  # PS5/TV ağda kendiliğinden bulunmaz, adres elle girilir.
  if [[ -n "${COUCHSUBS_NO_MULTICAST:-}" ]]; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.networking.multicast' couchsubs-ios/CouchSubs/CouchSubs.entitlements 2>/dev/null || true
    echo "Uyarı: multicast izni olmadan derleniyor."
  fi
  xcodebuild -project couchsubs-ios/CouchSubs.xcodeproj -scheme CouchSubs -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" "${SIGN_ARGS[@]}" "${VERSION_ARGS[@]}" archive \
    > "$OUT/archive-ios.log" 2>&1 || { grep -E "error:" "$OUT/archive-ios.log" | head -20; echo "Arşiv başarısız: $OUT/archive-ios.log"; exit 1; }
else
  # Mac App Store sürümü evrensel: Remote Play kütüphanesi, TV kurulum yardımcısı ve ses motoru iki mimariyi içermeli.
  # Xcode 27'nin lipo'su -verify_arch'ta tek mimari kabul ediyor; mimariler ayrı ayrı denetlenir.
  universal() { [[ -f "$1" ]] && lipo "$1" -verify_arch arm64 && lipo "$1" -verify_arch x86_64; }
  MAC_SLICE=(third-party/build/CChiaki.xcframework/macos-*/libCChiaki.a(N))
  universal "${MAC_SLICE[1]}" || { echo "CChiaki macOS dilimi evrensel değil: scripts/build-chiaki-macos.sh"; exit 1; }
  universal dist/tv-helper/couchsubs-tv-helper || { echo "dist/tv-helper evrensel değil: scripts/build-tv-helper.sh (Microsoft .NET SDK ile)"; exit 1; }
  universal dist/tts/pocket-tts || ./scripts/fetch-pocket-tts.sh mac
  ls dist/tv-app/*.ipk dist/tv-app/*.wgt dist/tv-app/*.apk >/dev/null || { echo "dist/tv-app eksik (package-tv.sh, package-tizen.sh, bundle-android-apk.sh)"; exit 1; }
  (cd mac && xcodegen generate --quiet)
  xcodebuild -project mac/CouchSubs.xcodeproj -scheme CouchSubsAppStore -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" "${SIGN_ARGS[@]}" "${VERSION_ARGS[@]}" \
    OTHER_SWIFT_FLAGS="-Xfrontend -warn-long-expression-type-checking=200" archive \
    > "$OUT/archive-mac.log" 2>&1 || { grep -E "error:" "$OUT/archive-mac.log" | head -20; echo "Arşiv başarısız: $OUT/archive-mac.log"; exit 1; }
  APP="$ARCHIVE/Products/Applications/CouchSubs.app"
  # Sandbox denetimi: uygulama sandbox'lı, gömülü programlar yalnız app-sandbox + inherit ile imzalı, Sparkle yok.
  codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" || { echo "Uygulama sandbox'lı değil."; exit 1; }
  for EXE in couchsubs-tv-helper pocket-tts; do
    codesign -d --entitlements :- "$APP/Contents/MacOS/$EXE" 2>/dev/null | grep -q "com.apple.security.inherit" \
      || { echo "$EXE sandbox'ı miras almıyor."; exit 1; }
  done
  [[ ! -e "$APP/Contents/Frameworks/Sparkle.framework" ]] || { echo "Sparkle Mac App Store paketine girmiş."; exit 1; }
fi
echo "Arşiv: $ARCHIVE"
[[ "$3" == --unsigned ]] && exit 0

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$EXPORT" -allowProvisioningUpdates \
  > "$OUT/export-$PLATFORM.log" 2>&1 || { tail -30 "$OUT/export-$PLATFORM.log"; echo "Dışa aktarma/yükleme başarısız: $OUT/export-$PLATFORM.log"; exit 1; }
if [[ "$3" == --no-upload ]]; then
  echo "Dışa aktarıldı: $EXPORT"
else
  echo "Yüklendi: CouchSubs $PLATFORM $VERSION ($BUILD). App Store Connect işledikten sonra iç TestFlight'ta görünür."
fi
