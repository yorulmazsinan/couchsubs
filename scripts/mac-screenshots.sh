#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# Mac uygulamasının ekran görüntüleri (docs/screenshots/mac): ScreenshotTests uygulamanın ekranlarını koyu görünümde,
# örnek verilerle birer pencerede açar ve pencereleri 2x PNG'ye çizer; pngquant varsa dosyalar küçültülür.
# Kullanım: scripts/mac-screenshots.sh [DerivedData klasörü]
set -euo pipefail
ROOT=${0:A:h:h}
OUT="$ROOT/docs/screenshots/mac"
DERIVED=${1:-$ROOT/build/screenshots}
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

(cd "$ROOT/mac" && xcodegen generate --quiet)
mkdir -p "$OUT"
# TEST_RUNNER_ ile başlayan değişken test sürecine öneki atılarak geçer.
TEST_RUNNER_COUCHSUBS_SCREENSHOTS="$OUT" xcodebuild test -project "$ROOT/mac/CouchSubs.xcodeproj" -scheme CouchSubs \
  -derivedDataPath "$DERIVED" -only-testing:CouchSubsTests/ScreenshotTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 > "$LOG" 2>&1 \
  || { tail -30 "$LOG"; exit 1; }
for file in "$OUT"/*.png; do
  if command -v pngquant >/dev/null; then pngquant --quality=80-98 --speed 1 --strip --force --output "$file" "$file"; fi
  echo "$file"
done
