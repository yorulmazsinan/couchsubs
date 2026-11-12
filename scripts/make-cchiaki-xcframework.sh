#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# third-party/build altındaki hazır dilimlerden (macos, ios-iphoneos, ios-iphonesimulator) CChiaki.xcframework kurar.
# Her dilim klasöründe lib/*.a ve include/chiaki bulunur; olmayan dilim atlanır. Mac ve iOS derleme betikleri sonunda
# bunu çağırır, böylece biri ötekinin dilimini silmez.
set -e
cd "${0:A:h}/.."

ROOT="$PWD"
BUILD="$ROOT/third-party/build"
FW="$BUILD/CChiaki.xcframework"
STAGE="$BUILD/xcframework-stage"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

rm -rf "$STAGE"
args=()
for slice in macos ios-iphoneos ios-iphonesimulator; do
  dir="$BUILD/$slice"
  [[ -d "$dir/lib" && -d "$dir/include/chiaki" ]] || continue
  stage="$STAGE/$slice"
  mkdir -p "$stage/include"
  # Swift'ten "import CChiaki" ile kullanılmak üzere tek statik kütüphane + başlıklar + modül haritası.
  libtool -static -o "$stage/libCChiaki.a" "$dir"/lib/*.a
  cp -R "$dir/include/chiaki" "$stage/include/"
  {
    echo '#include <stdbool.h>'
    for h in common log session regist discovery controller video; do echo "#include \"chiaki/$h.h\""; done
  } > "$stage/include/CChiaki.h"
  cat > "$stage/include/module.modulemap" <<'MAP'
module CChiaki {
  umbrella header "CChiaki.h"
  export *
}
MAP
  args+=(-library "$stage/libCChiaki.a" -headers "$stage/include")
  echo "Dilim: $slice"
done

if (( ${#args} == 0 )); then
  echo "HATA: third-party/build altında hiç dilim yok (önce build-chiaki-macos.sh ya da build-chiaki-ios.sh)" >&2
  exit 1
fi
rm -rf "$FW"
xcodebuild -create-xcframework "${args[@]}" -output "$FW" >/dev/null
rm -rf "$STAGE"
echo "Hazır: $FW"
