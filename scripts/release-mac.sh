#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# Sürümün imzalı ve Apple onaylı Mac paketini (zip, DMG, appcast.xml) bu Mac'te üretir.
# Anahtar zincirindeki Developer ID sertifikasını ve notarytool profilini (couchsubs) kullanır.
# Kullanım: release-mac.sh <sürümün Android TV APK'sı>
# TV_HELPER_RUN=<run id>: kurulum yardımcısını belirli bir release iş akışı çalışmasından al (verilmezse son başarılı).
set -e
setopt pipefail
cd "${0:A:h}/.."
[[ -f "$1" ]] || { echo "Kullanım: $0 <CouchSubs-androidtv.apk>"; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export ANDROID_APK="${1:A}"
export DEVELOPER_ID="Developer ID Application: ENMERA YAZILIM EGITIM REKLAM DANISMANLIK TICARET LIMITED SIRKETI (79N3CT6T46)"
export NOTARY_PROFILE=couchsubs

# Samsung/Android TV kurulum yardımcısı CI'dan alınır: bu Mac'teki Homebrew .NET'i dağıtılabilir Native AOT yardımcısı
# derleyemiyor, dist'te kalan eski yardımcı da beta.27, beta.29 ve beta.30'un ilk Mac paketine girip Samsung
# kurulumunu "EphemeralKeySet" hatasıyla bozdu. Yardımcının kaynakları CI'ın derlediği commit'le aynı olmalı.
SOURCES=(windows/src/CouchSubs.TvHelper windows/src/CouchSubs.TvInstall windows/Directory.Build.props)
[[ -z "$(git status --porcelain -- $SOURCES)" ]] || { echo "Yardımcının kaynaklarında commit'lenmemiş değişiklik var."; exit 1; }
RUN="${TV_HELPER_RUN:-$(gh run list --workflow release.yml --status success --limit 1 --json databaseId -q '.[0].databaseId')}"
[[ -n "$RUN" ]] || { echo "Başarılı release iş akışı bulunamadı."; exit 1; }
RUN_SHA=$(gh run view "$RUN" --json headSha -q .headSha)
git cat-file -e "$RUN_SHA^{commit}" 2>/dev/null || git fetch -q origin "$RUN_SHA"
git diff --quiet "$RUN_SHA" HEAD -- $SOURCES \
  || { echo "CI çalışması $RUN (${RUN_SHA[1,7]}) yardımcının başka kaynağından; o sürümün CI'ı bitince yeniden deneyin."; exit 1; }
CI=$(mktemp -d)
trap 'rm -rf "$CI"' EXIT
echo "Kurulum yardımcısı CI çalışması $RUN'dan (${RUN_SHA[1,7]}) alınıyor."
gh run download "$RUN" -n couchsubs-mac -D "$CI/zip"
ditto -x -k "$CI"/zip/*.zip "$CI/app"
./scripts/build-tv-helper.sh --from "$CI/app/CouchSubs.app/Contents/MacOS/couchsubs-tv-helper"

~/Projeler/Web/enmera/ekip/heavy-job.sh ./scripts/package-mac.sh
