#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# Mac uygulamasına gömülen Samsung ve Android TV kurulum yardımcısını (windows/src/CouchSubs.TvHelper) Native AOT ile
# derler: dist/tv-helper/couchsubs-tv-helper (Apple Silicon ve Intel dilimleri tek evrensel dosyada). Ardından XML
# imzasının AOT ile çalıştığını sınar. Yalnız bir mimari için: TV_HELPER_RIDS="osx-arm64".
# --if-changed: yardımcı bu kaynaklardan derlenmişse (dist/tv-helper/source.sha256) yeniden derlenmez.
# --from DOSYA: derlemek yerine hazır yardımcıyı (CI'ın aynı commit'ten derlediği) alır, sınar ve damgalar.
set -e
setopt pipefail
cd "${0:A:h}/.."

OUT=dist/tv-helper
STAMP="$OUT/source.sha256"
RIDS=(${=TV_HELPER_RIDS:-osx-arm64 osx-x64})

# Yardımcının kaynakları: kendisi, kullandığı kitaplık (TizenSdb sürümü csproj'da), bu betik ve istenen mimariler.
# Eskiden yardımcı dist'te varsa hiç yeniden derlenmiyordu; beta.27, beta.29 ve beta.30'un Mac paketlerine düzeltmeden
# önceki yardımcı girdi ve Mac'te kayıtlı sertifikayla her Samsung kurulumu "EphemeralKeySet" hatasıyla durdu.
source_hash() {
  {
    find windows/src/CouchSubs.TvHelper windows/src/CouchSubs.TvInstall windows/Directory.Build.props scripts/build-tv-helper.sh \
         -type f -not -path '*/bin/*' -not -path '*/obj/*' -not -name '.DS_Store' -print0 \
      | sort -z | xargs -0 shasum -a 256
    print -r -- "$RIDS"
  } | shasum -a 256 | cut -d' ' -f1
}

HASH=$(source_hash)
if [[ "$1" == --if-changed && -x "$OUT/couchsubs-tv-helper" && -f "$STAMP" && "$(<"$STAMP")" == "$HASH" ]]; then
  echo "Yardımcı güncel: $OUT/couchsubs-tv-helper"
  exit 0
fi

rm -rf "$OUT" "$OUT"-osx-*(N)
if [[ "$1" == --from ]]; then
  # Başka yerde (CI) aynı kaynaktan derlenmiş yardımcıyı alır; aşağıdaki denetimlerden yine geçer. Kaynağın aynı
  # commit olduğunu çağıran doğrular (release-mac.sh).
  [[ -x "$2" ]] || { echo "Yardımcı yok: $2"; exit 1; }
  mkdir -p "$OUT" && cp "$2" "$OUT/couchsubs-tv-helper"
else
  SLICES=()
  for RID in $RIDS; do
    dotnet publish windows/src/CouchSubs.TvHelper -c Release -r "$RID" -o "$OUT-$RID" -nologo -v q
    [[ -x "$OUT-$RID/couchsubs-tv-helper" ]] || { echo "Yardımcı derlenemedi ($RID)."; exit 1; }
    SLICES+=("$OUT-$RID/couchsubs-tv-helper")
  done
  mkdir -p "$OUT"
  lipo -create "${SLICES[@]}" -output "$OUT/couchsubs-tv-helper"
  # Dilim klasörleri hata ayıklama sembolleriyle birlikte silinir; pakete yalnız evrensel dosya girer.
  rm -rf "$OUT"-osx-*(N)
fi
# Hata ayıklama sembolleri pakete girmesin.
rm -rf "$OUT"/*.dSYM(N) "$OUT"/*.dbg(N) "$OUT"/*.pdb(N)
[[ -x "$OUT/couchsubs-tv-helper" ]] || { echo "Yardımcı derlenemedi."; exit 1; }
# Homebrew'un kaynaktan derlenmiş .NET'i Homebrew kitaplıklarına bağlar; öyle bir dosya başka Mac'te açılmaz.
# Yayın derlemesi Microsoft'un .NET'iyle (actions/setup-dotnet) yapılır. Yerel sınama için ALLOW_LOCAL_LIBS=1.
if otool -L "$OUT/couchsubs-tv-helper" | grep -q /opt/homebrew && [[ -z "$ALLOW_LOCAL_LIBS" ]]; then
  echo "Yardımcı Homebrew kitaplıklarına bağlı; Microsoft'un .NET SDK'sıyla derleyin."; exit 1
fi
# Sınama bu Mac'in işlemcisindeki dilimle çalışır.
"$OUT/couchsubs-tv-helper" self-test | grep -q '"event":"done"' || { echo "Yardımcı sınaması başarısız."; exit 1; }
# Homebrew'a bağlı yerel deneme derlemesi pakete girmesin: damga yalnız dağıtılabilir yardımcıya yazılır.
otool -L "$OUT/couchsubs-tv-helper" | grep -q /opt/homebrew || print -r -- "$HASH" > "$STAMP"
echo "Hazır: $OUT/couchsubs-tv-helper ($(lipo -archs "$OUT/couchsubs-tv-helper"), $(du -h "$OUT/couchsubs-tv-helper" | cut -f1))"
