#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# chiaki-ng'nin Remote Play kütüphanesini (libchiaki) iPhone/iPad için statik derler: cihaz (iphoneos arm64) ve
# simülatör (iphonesimulator arm64). Çıktı: third-party/build/ios-{iphoneos,iphonesimulator}/{include,lib}; sonunda
# CChiaki.xcframework'e (varsa macOS dilimiyle birlikte) eklenir.
#
# chiaki-ng kaynaklarına dokunulmaz: ağaç derleme klasörüne kopyalanır, third-party/patches oraya uygulanır.
# Homebrew'un hazır kütüphaneleri macOS içindir; iOS için OpenSSL, json-c, libevent ve miniupnpc kaynaktan derlenir.
# curl, nanopb, jerasure ve gf-complete chiaki-ng'nin alt modüllerinden gelir.
#
# Gerekenler: Xcode, Homebrew ile cmake ninja protobuf (protoc). İnternet (kaynak arşivleri).
# Ayarlar: CHIAKI_SRC (chiaki-ng ağacı; varsayılan third-party/chiaki-ng), JOBS (paralel iş, varsayılan 4),
#          SLICES ("iphoneos iphonesimulator").
set -e
cd "${0:A:h}/.."

ROOT="$PWD"
SRC="${CHIAKI_SRC:-$ROOT/third-party/chiaki-ng}"
WORK="$ROOT/third-party/build/ios-work"
VENV="$ROOT/third-party/build/venv-ios"
JOBS="${JOBS:-4}"
SLICES=(${=SLICES:-iphoneos iphonesimulator})
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Uygulama iOS 16 ister; kütüphaneler daha eskiyi hedefleyebilir. chiaki-ng kendi CMakeLists'inde Apple için hedefi
# 13.0'a sabitliyor (CACHE FORCE); bağımlılıklar da aynı hedefle derlenir ki bağlayıcı uyarı vermesin.
MIN="13.0"
OPENSSL_VERSION="3.5.4"
JSONC_TAG="json-c-0.18-20240915"
PROTOC="${PROTOC:-$(command -v protoc)}"
[[ -x "$PROTOC" ]] || { echo "HATA: protoc yok (brew install protobuf)" >&2; exit 1; }

if [[ ! -f "$SRC/lib/CMakeLists.txt" ]]; then
  echo "HATA: chiaki-ng kaynağı yok: $SRC (git submodule update --init third-party/chiaki-ng ya da CHIAKI_SRC=...)" >&2
  exit 1
fi
if [[ ! -f "$SRC/third-party/nanopb/CMakeLists.txt" || ! -f "$SRC/third-party/curl/CMakeLists.txt" ]]; then
  git -C "$SRC" submodule update --init --depth 1 third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl
fi

# nanopb'nin kod üreteci Python'da protobuf paketini ister (protoc Homebrew'dan); sisteme dokunmamak için ayrı ortam.
if [[ ! -x "$VENV/bin/python3" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet protobuf
fi

mkdir -p "$WORK/archives"
# Kaynak ağacının kopyası: yamalar burada uygulanır, asıl chiaki-ng çalışma kopyası değişmez.
# Baştaki "/" yalnız chiaki-ng'nin kök klasörlerini dışarıda bırakır (curl'ün docs klasörü gerekiyor).
rsync -a --delete --exclude .git --exclude /gui --exclude /android --exclude /switch --exclude /steamdeck_native \
  --exclude /docs --exclude /doc --exclude /assets "$SRC/" "$WORK/chiaki/"
for p in "$ROOT"/third-party/patches/chiaki-*.patch; do
  if patch -d "$WORK/chiaki" -p1 -R -f -s --dry-run < "$p" >/dev/null 2>&1; then
    echo "Zaten uygulanmış: ${p:t}"
  else
    patch -d "$WORK/chiaki" -p1 -f -s < "$p"
    echo "Uygulandı: ${p:t}"
  fi
done

fetch() {
  local name=$1 url=$2 dir=$3
  [[ -d "$WORK/archives/$name" ]] && return
  curl -fsSL --retry 3 "$url" | tar -xz -C "$WORK/archives"
  mv "$WORK/archives/$dir" "$WORK/archives/$name"
}
fetch openssl "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION"
fetch json-c "https://codeload.github.com/json-c/json-c/tar.gz/refs/tags/$JSONC_TAG" "json-c-$JSONC_TAG"
fetch libevent https://codeload.github.com/libevent/libevent/tar.gz/refs/tags/release-2.1.12-stable libevent-release-2.1.12-stable
fetch miniupnp https://codeload.github.com/miniupnp/miniupnp/tar.gz/refs/tags/miniupnpc_2_3_3 miniupnp-miniupnpc_2_3_3

for sdk in $SLICES; do
  echo "=== $sdk ==="
  B="$WORK/$sdk"
  PREFIX="$B/prefix"
  OUT="$ROOT/third-party/build/ios-$sdk"
  SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)"
  if [[ $sdk == iphoneos ]]; then
    OSSL_TARGET=ios64-xcrun; MINFLAG="-mios-version-min=$MIN"
  else
    OSSL_TARGET=iossimulator-arm64-xcrun; MINFLAG="-mios-simulator-version-min=$MIN"
    grep -q '"iossimulator-arm64-xcrun"' "$WORK/archives/openssl/Configurations/15-ios.conf" || OSSL_TARGET=iossimulator-xcrun
  fi
  # Önceki derlemeler silinir; yalnız hazır OpenSSL kalır (en uzun süren parça, sürümü sabit).
  rm -rf "$B/chiaki" "$B"/build-*(N)
  mkdir -p "$B/openssl" "$PREFIX"

  # OpenSSL: yalnız kütüphaneler (uygulamalar, testler, paylaşımlı kütüphane yok).
  if [[ ! -f "$PREFIX/lib/libcrypto.a" || ! -f "$B/openssl/.done-$OPENSSL_VERSION" ]]; then
    (cd "$B/openssl" && "$WORK/archives/openssl/Configure" "$OSSL_TARGET" no-shared no-tests no-module no-async \
       --prefix="$PREFIX" --libdir=lib "$MINFLAG" $([[ $OSSL_TARGET == iossimulator-xcrun ]] && echo "-arch arm64") >/dev/null \
     && make -s -j"$JOBS" build_libs >/dev/null && make -s install_dev >/dev/null && touch ".done-$OPENSSL_VERSION")
  fi

  # Homebrew'un macOS kütüphaneleri yanlışlıkla bulunmasın; yalnız bu dilimin önekine ve SDK'ya bakılır.
  common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SYSROOT"
          -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN -DCMAKE_INSTALL_PREFIX="$PREFIX"
          -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX;$SYSROOT"
          -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH
          -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
          -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
          -DBUILD_SHARED_LIBS=OFF)
  dep() {
    local name=$1 src=$2; shift 2
    cmake -S "$src" -B "$B/build-$name" "${common[@]}" "$@" >/dev/null
    cmake --build "$B/build-$name" --target install --parallel "$JOBS" >/dev/null
  }
  dep json-c "$WORK/archives/json-c" -DBUILD_TESTING=OFF -DBUILD_APPS=OFF -DDISABLE_EXTRA_LIBS=ON -DBUILD_STATIC_LIBS=ON
  # pipe2 SDK'da görünür ama eski sürümlerde yok; Mac derlemesindeki gibi pipe() kullandırılır.
  dep libevent "$WORK/archives/libevent" -DEVENT__LIBRARY_TYPE=STATIC -DEVENT__DISABLE_OPENSSL=ON -DEVENT__DISABLE_MBEDTLS=ON \
    -DEVENT__DISABLE_TESTS=ON -DEVENT__DISABLE_SAMPLES=ON -DEVENT__DISABLE_BENCHMARK=ON -DEVENT__DISABLE_REGRESS=ON \
    -DEVENT__HAVE_PIPE2=0
  dep miniupnpc "$WORK/archives/miniupnp/miniupnpc" -DUPNPC_BUILD_STATIC=ON -DUPNPC_BUILD_SHARED=OFF -DUPNPC_BUILD_TESTS=OFF \
    -DUPNPC_BUILD_SAMPLE=OFF

  # pkg-config yalnız bu dilimin önekini görür.
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_PATH=""

  # Mac derlemesiyle aynı seçenekler: arayüz, komut satırı, ses ve FFmpeg kapalı (görüntü VideoToolbox ile çözülür).
  cmake -S "$WORK/chiaki" -B "$B/chiaki" "${common[@]}" \
    -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DPROTOC="$PROTOC" \
    -DPython3_EXECUTABLE="$VENV/bin/python3" -DPYTHON_EXECUTABLE="$VENV/bin/python3" \
    -DCHIAKI_ENABLE_GUI=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_TESTS=OFF \
    -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_PI_DECODER=OFF -DCHIAKI_LIB_ENABLE_OPUS=OFF \
    -DCHIAKI_ENABLE_SPEEX=OFF -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
    -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DCHIAKI_ENABLE_BOREALIS=OFF \
    -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DCURL_ZSTD=OFF -DCURL_BROTLI=OFF -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF \
    -DUSE_LIBRTMP=OFF -DCURL_DISABLE_LDAP=ON -DCURL_USE_OPENSSL=ON >/dev/null
  cmake --build "$B/chiaki" --target chiaki-lib --parallel "$JOBS" >/dev/null

  rm -rf "$OUT"
  mkdir -p "$OUT/include" "$OUT/lib"
  cp -R "$WORK/chiaki/lib/include/chiaki" "$OUT/include/"
  cp -R "$B/chiaki/lib/include/chiaki/"* "$OUT/include/chiaki/" 2>/dev/null || true
  find "$B/chiaki" -name "*.a" -exec cp {} "$OUT/lib/" \;
  cp "$PREFIX/lib/libcrypto.a" "$PREFIX/lib/libssl.a" "$PREFIX/lib/libjson-c.a" "$PREFIX/lib/libevent.a" \
     "$PREFIX/lib/libminiupnpc.a" "$OUT/lib/"

  # Her parça doğru platform için mi (cihaz: 2 = IOS, simülatör: 7 = IOSSIMULATOR)?
  want=$([[ $sdk == iphoneos ]] && echo 2 || echo 7)
  for lib in "$OUT"/lib/*.a; do
    platforms=$(otool -l "$lib" | awk '/platform/ {print $2}' | sort -u | tr '\n' ' ')
    [[ "$platforms" == "$want " ]] || { echo "HATA: $lib yanlış platform: $platforms (beklenen $want)" >&2; exit 1; }
  done
  ls "$OUT/lib"
done

"$ROOT/scripts/make-cchiaki-xcframework.sh"
