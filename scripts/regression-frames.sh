#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Gerçek kare gerileme seti: testdata/frames altındaki gerçek oyun karelerini (GTA 6, RDR2, Elden Ring, AC Shadows,
# GTA 6 telefonu ve haritası, pencere kaynağı varyantları) gerçek Apple Vision ile okur; altyazı seçimi → sabit sözlük
# (çeviri motoru yerine) → TV'deki örtme kutusu hattını, telefon/harita sınıflamasını ve telefon çevirisi senaryosunu
# koşar. Aynı kareleri önceki etiketin çekirdeğiyle de koşup karşılaştırır.
#
#   scripts/regression-frames.sh                 # bu çekirdek ↔ önceki etiket
#   scripts/regression-frames.sh --base v0.1.0-beta.74
#   scripts/regression-frames.sh --core v0.1.0-beta.76 --base v0.1.0-beta.74   # eski bir etiketi sına
#   scripts/regression-frames.sh --no-compare     # yalnız bu çekirdeğin özeti
#
# Önceki etiket: HEAD bir etiketse ondan önceki etiket, değilse HEAD'den ulaşılan son etiket. Önceki etiketin çekirdeği
# git archive ile ayrı bir klasöre açılır (çalışma ağacına dokunulmaz) ve aynı koşucu ona karşı derlenir.
#
# Kırmızı (çıkış 1): altyazı satırı yakalama oranı önceki etiketin altına düştü; ya da yanlış kabul arttı, telefon/harita
# sınıflaması, kutu örtme, telefon çevirisi senaryosu ya da ekran yazısı (menü sekmeleri, görev listesi; "Ekranı çevir",
# otomatik ekran yazısı ve hazır alanlar) geriledi. Sürüm iş akışı (release.yml) bu betiği zorunlu
# kapı olarak koşar. Yalnız macOS (Apple Vision); Android ve Windows aynı okumalarla (testdata/frames/ocr) kendi
# testlerinde koşar. Ekran yazısı ölçütünü Android ScreenFramesTest.kt testdata/frames/ocr/screen okumalarıyla koşar
# (kareler değişince yeniden kaydı: tools/frame-regression → frame-regression record-screen testdata/frames).

set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMES="$ROOT/testdata/frames"
TOOL="$ROOT/tools/frame-regression"
OUT="${REGRESSION_OUT:-$ROOT/build/regression-frames}"
BASE=""
CORE_REF=""
COMPARE=1
VERBOSE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --core) CORE_REF="$2"; shift 2 ;;
    --no-compare) COMPARE=0; shift ;;
    -v) VERBOSE="-v"; shift ;;
    *) echo "bilinmeyen seçenek: $1" >&2; exit 64 ;;
  esac
done

if [ "$(uname)" != "Darwin" ]; then
  echo "Bu set Apple Vision ister (macOS). Android/Windows aynı okumaları kendi testlerinde koşar." >&2
  exit 64
fi

mkdir -p "$OUT"

# Bir çekirdeği (klasör) koşucuyla derler ve kareleri koşar: run <ad> <çekirdek klasörü> <json>
run() {
  local name="$1" core="$2" json="$3" build="$OUT/build-$(echo "$1" | tr -c 'A-Za-z0-9.\n' '-')"
  echo "▸ $name çekirdeği derleniyor ($core)"
  if ! (cd "$TOOL" && COUCHSUBS_CORE="$core" swift build -Xswiftc -enable-testing --scratch-path "$build" >"$build.log" 2>&1); then
    tail -40 "$build.log" >&2
    echo "✗ $name çekirdeği koşucuyla derlenemedi (günlük: $build.log)" >&2
    return 1
  fi
  "$build/debug/frame-regression" run "$FRAMES" --core "$name" --json "$json" $VERBOSE
  echo
}

# Etiketin çekirdeğini ayrı klasöre açar: extract <etiket> → klasör yolu
extract() {
  local ref="$1" dir="$OUT/src-$(echo "$1" | tr -c 'A-Za-z0-9.\n' '-')"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$ROOT" archive "$ref" core | tar -x -C "$dir"
  echo "$dir/core"
}

if [ -n "$CORE_REF" ]; then
  git -C "$ROOT" rev-parse --verify --quiet "$CORE_REF^{commit}" >/dev/null || { echo "etiket yok: $CORE_REF" >&2; exit 64; }
  HEAD_NAME="$CORE_REF"
  HEAD_CORE="$(extract "$CORE_REF")"
  HEAD_COMMIT="$(git -C "$ROOT" rev-parse "$CORE_REF^{commit}")"
else
  HEAD_NAME="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo HEAD)"
  HEAD_CORE="$ROOT/core"
  HEAD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
fi

run "$HEAD_NAME" "$HEAD_CORE" "$OUT/head.json"

[ "$COMPARE" = 1 ] || exit 0

if [ -z "$BASE" ]; then
  # Etiketler sığ klonda yoksa getir (CI).
  if [ -z "$(git -C "$ROOT" tag -l 'v*' | head -1)" ]; then git -C "$ROOT" fetch --tags --quiet origin || true; fi
  if EXACT="$(git -C "$ROOT" describe --tags --exact-match "$HEAD_COMMIT" 2>/dev/null)"; then
    BASE="$(git -C "$ROOT" describe --tags --abbrev=0 "$EXACT^" 2>/dev/null || true)"
  else
    BASE="$(git -C "$ROOT" describe --tags --abbrev=0 "$HEAD_COMMIT" 2>/dev/null || true)"
  fi
fi
if [ -z "$BASE" ]; then
  echo "✗ Karşılaştırılacak önceki etiket bulunamadı (git fetch --tags?)." >&2
  exit 1
fi

if ! run "$BASE" "$(extract "$BASE")" "$OUT/base.json"; then
  echo "✗ Önceki etiket ($BASE) koşulamadı; karşılaştırma yapılamadı." >&2
  exit 1
fi

python3 "$ROOT/scripts/regression_frames_compare.py" "$OUT/base.json" "$OUT/head.json"
