# SPDX-License-Identifier: AGPL-3.0-only
# Boş oboe paketi: chiaki-ng'nin android/app hedefi yapılandırılırken aranır ama derlenmez (bkz. ../CMakeLists.txt).
if(NOT TARGET oboe::oboe)
	add_library(oboe::oboe INTERFACE IMPORTED)
endif()
set(oboe_FOUND TRUE)
