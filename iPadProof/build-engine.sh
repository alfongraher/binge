#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
cmake="$PWD/tools/cmake/data/bin/cmake"
"$cmake" -S vendor/libtorrent-rasterbar-2.0.15 -B build-engine \
 -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
 -DBoost_NO_BOOST_CMAKE=ON -DBoost_INCLUDE_DIR="$PWD/vendor/boost_1_86_0" \
 -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
"$cmake" --build build-engine --parallel 4
python3 create_project.py
