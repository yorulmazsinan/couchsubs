#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# chiaki-ng'nin Remote Play kütüphanesini (libchiaki) macOS için statik derler: Apple Silicon (arm64) ve Intel (x86_64),
# ikisi tek "evrensel" kütüphanede birleşir. Çıktı: third-party/build/macos/{include,lib}; sonunda CChiaki.xcframework'e
# (varsa iOS dilimleriyle birlikte) eklenir.
#
# chiaki-ng kaynaklarına dokunulmaz: ağaç derleme klasörüne kopyalanır, third-party/patches oraya uygulanır.
# Homebrew'un hazır kütüphaneleri yalnız derleyen makinenin macOS'unu ve işlemcisini hedefler; bu yüzden OpenSSL, json-c,
# libevent ve miniupnpc kaynaktan, en eski desteklenen macOS'u hedefleyerek her mimari için ayrı derlenir.
# curl, nanopb, jerasure ve gf-complete chiaki-ng'nin alt modüllerinden gelir.
#
# Gerekenler: Xcode, Homebrew ile cmake ninja. İnternet (kaynak arşivleri ve Python protobuf paketi).
# Ayarlar: CHIAKI_SRC (chiaki-ng ağacı; varsayılan third-party/chiaki-ng), JOBS (paralel iş, varsayılan 4),
#          MAC_ARCHS ("arm64 x86_64").
set -e
cd "${0:A:h}/.."

ROOT="$PWD"
SRC="${CHIAKI_SRC:-$ROOT/third-party/chiaki-ng}"
WORK="$ROOT/third-party/build/macos-work"
OUT="$ROOT/third-party/build/macos"
VENV="$ROOT/third-party/build/venv"
JOBS="${JOBS:-4}"
ARCHS=(${=MAC_ARCHS:-arm64 x86_64})
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# En eski desteklenen macOS (mac/project.yml ile aynı). Hiçbir parça bundan yenisini istememeli; isterse uygulama eski
# macOS'ta açılışta kapanır (macOS 27'de derlenen Homebrew libevent'i 27'de gelen pipe2'yi çağırıyordu).
MIN="13.0"
OPENSSL_VERSION="3.5.4"
JSONC_TAG="json-c-0.18-20240915"

if [[ ! -f "$SRC/lib/CMakeLists.txt" ]]; then
  echo "HATA: chiaki-ng kaynağı yok: $SRC (git submodule update --init third-party/chiaki-ng ya da CHIAKI_SRC=...)" >&2
  exit 1
fi
if [[ ! -f "$SRC/third-party/nanopb/CMakeLists.txt" || ! -f "$SRC/third-party/curl/CMakeLists.txt" ]]; then
  git -C "$SRC" submodule update --init --depth 1 third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl
fi

# nanopb'nin kod üreteci Python'da protobuf paketini ister (protoc grpcio-tools'tan); sisteme dokunmamak için ayrı ortam.
if [[ ! -x "$VENV/bin/python3" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet protobuf grpcio-tools
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

SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=$MIN

for arch in $ARCHS; do
  echo "=== macOS $arch ==="
  B="$WORK/$arch"
  PREFIX="$B/prefix"
  # Önceki derlemeler silinir; yalnız hazır OpenSSL kalır (en uzun süren parça, sürümü sabit).
  rm -rf "$B/chiaki" "$B"/build-*(N) "$B/lib"
  mkdir -p "$B/openssl" "$PREFIX"

  # OpenSSL: yalnız kütüphaneler (uygulamalar, testler, paylaşımlı kütüphane yok).
  if [[ ! -f "$PREFIX/lib/libcrypto.a" || ! -f "$B/openssl/.done-$OPENSSL_VERSION-$MIN" ]]; then
    rm -rf "$B/openssl" && mkdir -p "$B/openssl"
    (cd "$B/openssl" && "$WORK/archives/openssl/Configure" "darwin64-$arch-cc" no-shared no-tests no-module no-async \
       --prefix="$PREFIX" --libdir=lib "-mmacosx-version-min=$MIN" >/dev/null \
     && make -s -j"$JOBS" build_libs >/dev/null && make -s install_dev >/dev/null && touch ".done-$OPENSSL_VERSION-$MIN")
  fi

  # Homebrew'un kütüphaneleri (başka macOS, başka işlemci) yanlışlıkla bulunmasın; yalnız bu mimarinin önekine bakılır.
  common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$SYSROOT"
          -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN -DCMAKE_INSTALL_PREFIX="$PREFIX"
          -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
          -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF)
  dep() {
    local name=$1 src=$2; shift 2
    cmake -S "$src" -B "$B/build-$name" "${common[@]}" "$@" >/dev/null
    cmake --build "$B/build-$name" --target install --parallel "$JOBS" >/dev/null
  }
  dep json-c "$WORK/archives/json-c" -DBUILD_TESTING=OFF -DBUILD_APPS=OFF -DDISABLE_EXTRA_LIBS=ON -DBUILD_STATIC_LIBS=ON
  # pipe2 SDK'da görünür ama yalnız macOS 27'de var; denetimi atlatıp pipe() kullandırılır.
  dep libevent "$WORK/archives/libevent" -DEVENT__LIBRARY_TYPE=STATIC -DEVENT__DISABLE_OPENSSL=ON -DEVENT__DISABLE_MBEDTLS=ON \
    -DEVENT__DISABLE_TESTS=ON -DEVENT__DISABLE_SAMPLES=ON -DEVENT__DISABLE_BENCHMARK=ON -DEVENT__DISABLE_REGRESS=ON \
    -DEVENT__HAVE_PIPE2=0
  dep miniupnpc "$WORK/archives/miniupnp/miniupnpc" -DUPNPC_BUILD_STATIC=ON -DUPNPC_BUILD_SHARED=OFF -DUPNPC_BUILD_TESTS=OFF \
    -DUPNPC_BUILD_SAMPLE=OFF

  # pkg-config yalnız bu mimarinin önekini görür.
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_PATH=""

  # Arayüz, komut satırı, ses ve FFmpeg kapalı: yalnız bağlantı, kayıt ve görüntü akışı gerekiyor.
  cmake -S "$WORK/chiaki" -B "$B/chiaki" "${common[@]}" \
    -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DPython3_EXECUTABLE="$VENV/bin/python3" -DPYTHON_EXECUTABLE="$VENV/bin/python3" \
    -DCHIAKI_ENABLE_GUI=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_TESTS=OFF \
    -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_PI_DECODER=OFF -DCHIAKI_LIB_ENABLE_OPUS=OFF \
    -DCHIAKI_ENABLE_SPEEX=OFF -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
    -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DCHIAKI_ENABLE_BOREALIS=OFF \
    -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DCURL_ZSTD=OFF -DCURL_BROTLI=OFF -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF \
    -DUSE_LIBRTMP=OFF -DCURL_DISABLE_LDAP=ON -DCURL_USE_OPENSSL=ON >/dev/null
  cmake --build "$B/chiaki" --target chiaki-lib --parallel "$JOBS" >/dev/null

  mkdir -p "$B/lib"
  find "$B/chiaki" -name "*.a" -exec cp {} "$B/lib/" \;
  cp "$PREFIX/lib/libcrypto.a" "$PREFIX/lib/libssl.a" "$PREFIX/lib/libjson-c.a" "$PREFIX/lib/libevent.a" \
     "$PREFIX/lib/libminiupnpc.a" "$B/lib/"
done

# Mimariler tek evrensel kütüphanede birleşir (dosya adları her mimaride aynı).
rm -rf "$OUT"
mkdir -p "$OUT/include" "$OUT/lib"
cp -R "$WORK/chiaki/lib/include/chiaki" "$OUT/include/"
cp -R "$WORK/${ARCHS[1]}/chiaki/lib/include/chiaki/"* "$OUT/include/chiaki/" 2>/dev/null || true
for lib in "$WORK/${ARCHS[1]}"/lib/*.a; do
  inputs=()
  for a in $ARCHS; do inputs+=("$WORK/$a/lib/${lib:t}"); done
  lipo -create "${inputs[@]}" -output "$OUT/lib/${lib:t}"
done

# Her parça istenen mimarileri içermeli, macOS için olmalı (platform 1) ve MIN'den yeni macOS istememeli.
for lib in "$OUT"/lib/*.a; do
  for arch in $ARCHS; do
    lipo "$lib" -verify_arch $arch || { echo "HATA: $lib içinde $arch yok" >&2; exit 1; }
  done
  platforms=$(otool -l "$lib" | awk '/ platform / {print $2}' | sort -u | tr '\n' ' ')
  [[ "$platforms" == "1 " ]] || { echo "HATA: $lib yanlış platform: $platforms (beklenen 1)" >&2; exit 1; }
  newest=$(otool -l "$lib" | awk '/minos/ {print $2}' | sort -uV | tail -1)
  if [[ "$(printf '%s\n%s\n' "$newest" "$MIN" | sort -V | tail -1)" != "$MIN" ]]; then
    echo "HATA: $lib macOS $MIN'den yenisini ($newest) hedefliyor" >&2; exit 1
  fi
done
if nm -u "$OUT"/lib/*.a 2>/dev/null | grep -qx "_pipe2"; then echo "HATA: pipe2 hâlâ kullanılıyor" >&2; exit 1; fi

# Swift'ten "import CChiaki" ile kullanılmak üzere XCFramework (varsa iOS dilimleri de girer; bkz. build-chiaki-ios.sh).
"$ROOT/scripts/make-cchiaki-xcframework.sh"
ls "$OUT/lib"
