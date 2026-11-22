#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# chiaki-takion-stats.patch'i sınar: bütün yamalar uygulanmış congestioncontrol.c, sahte saat ve sayaçlarla çalıştırılır
# (bkz. netlog_test.c). Yama değiştiğinde çalıştırılır.
#
# Kullanım: tools/chiaki-sim/netlog.sh
# Gerekenler: cc, patch; third-party/chiaki-ng (git submodule update --init third-party/chiaki-ng).
set -e
cd "$(dirname "$0")/../.."
SRC=${CHIAKI_SRC:-third-party/chiaki-ng}
[ -f "$SRC/lib/src/congestioncontrol.c" ] || { echo "chiaki-ng kaynağı yok: git submodule update --init third-party/chiaki-ng" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R "$SRC/lib" "$WORK/lib"
for p in third-party/patches/chiaki-*.patch; do
  patch -d "$WORK" -p1 -s -f < "$p"
done
cc -O1 -Wall -Werror -I "$WORK/lib/include" tools/chiaki-sim/netlog_test.c "$WORK/lib/src/congestioncontrol.c" -o "$WORK/netlog"
"$WORK/netlog"
