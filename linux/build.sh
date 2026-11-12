#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Linux sunucusunun Docker imajını derler: chiaki-ng alt modüllerini indirir, yamaları uygular, imajı kurar.
#   ./linux/build.sh            # → couchsubs-linux imajı
#   docker compose -f linux/compose.yml up -d
set -e
cd "$(dirname "$0")/.."
git submodule update --init --depth 1 third-party/chiaki-ng
git -C third-party/chiaki-ng submodule update --init --depth 1 third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl
sh scripts/patch-chiaki.sh
docker build -f linux/Dockerfile -t couchsubs-linux "$@" .
