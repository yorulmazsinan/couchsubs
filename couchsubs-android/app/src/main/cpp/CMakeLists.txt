# SPDX-License-Identifier: AGPL-3.0-only
# couchsubs-jni: libchiaki (third-party/chiaki-ng, değiştirilmeden) + Android MediaCodec görüntü çözücü.
# Seçenekler Mac/Windows'la aynı (scripts/build-chiaki-macos.sh, windows/native/CMakeLists.txt): yalnız PS5 arama,
# uyandırma, kayıt ve görüntü akışı. Ses, kol, arayüz ve FFmpeg kapalı.
cmake_minimum_required(VERSION 3.20)
project(couchsubs_jni C CXX)

set(CHIAKI_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../third-party/chiaki-ng" CACHE PATH "chiaki-ng kaynakları")

foreach(off CHIAKI_ENABLE_GUI CHIAKI_ENABLE_CLI CHIAKI_ENABLE_TESTS CHIAKI_ENABLE_FFMPEG_DECODER
		CHIAKI_ENABLE_PI_DECODER CHIAKI_LIB_ENABLE_OPUS CHIAKI_ENABLE_SPEEX CHIAKI_ENABLE_SETSU
		CHIAKI_ENABLE_STEAMDECK_NATIVE CHIAKI_ENABLE_STEAM_SHORTCUT CHIAKI_ENABLE_BOREALIS
		BUILD_SHARED_LIBS USE_NGHTTP2 USE_LIBIDN2 CURL_ZSTD CURL_BROTLI CURL_USE_LIBPSL CURL_USE_LIBSSH2
		USE_LIBRTMP CURL_ZLIB)
	set(${off} OFF CACHE STRING "" FORCE)
endforeach()
set(CURL_DISABLE_LDAP ON CACHE BOOL "" FORCE)
# Android'de sistem OpenSSL, json-c ve miniupnpc yok: chiaki-ng'nin kendi dış proje tarifleriyle kaynaktan derlenir.
foreach(on CHIAKI_LIB_OPENSSL_EXTERNAL_PROJECT CHIAKI_LIB_JSONC_EXTERNAL_PROJECT CHIAKI_LIB_MINIUPNPC_EXTERNAL_PROJECT
		CHIAKI_ENABLE_ANDROID)
	set(${on} ON CACHE STRING "" FORCE)
endforeach()
# CHIAKI_ENABLE_ANDROID libevent'i devre dışı bırakır ama chiaki-ng'nin eski Android uygulamasını da (android/app) ekler;
# o, oboe'yu arar. Hiç derlemediğimiz o hedef için boş bir oboe paketi verilir (bkz. oboe-stub/).
set(oboe_DIR "${CMAKE_CURRENT_SOURCE_DIR}/oboe-stub" CACHE PATH "" FORCE)

add_subdirectory("${CHIAKI_SOURCE_DIR}" chiaki EXCLUDE_FROM_ALL)

add_library(couchsubs-jni SHARED couchsubs-jni.c video-decoder.c video-decoder.h)
target_link_libraries(couchsubs-jni PRIVATE chiaki-lib log mediandk android)
set_target_properties(couchsubs-jni PROPERTIES C_VISIBILITY_PRESET hidden)
target_compile_options(couchsubs-jni PRIVATE -Wall)
