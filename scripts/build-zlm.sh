#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/ZLMediaKit"
# L'API C e la semantica degli eventi cambiano tra versioni: si compila sempre questo commit (hash completo).
ZLM_COMMIT="${ZLM_COMMIT:-de04a56c2bc4279f06e583fcc62909cc04177231}"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin https://github.com/ZLMediaKit/ZLMediaKit.git
fi
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$ZLM_COMMIT" ]; then
  git -C "$SRC" fetch --depth 1 origin "$ZLM_COMMIT"
  # Gli URL dei submodule riscritti qui sotto lascerebbero .gitmodules modificato e bloccherebbero il checkout.
  git -C "$SRC" checkout -q -- .gitmodules 2>/dev/null || true
  git -C "$SRC" checkout -q --detach FETCH_HEAD
  git -C "$SRC" config -f .gitmodules submodule.ZLToolKit.url https://github.com/ZLMediaKit/ZLToolKit.git
  git -C "$SRC" config -f .gitmodules submodule.3rdpart/media-server.url https://github.com/ireader/media-server.git
  git -C "$SRC" config -f .gitmodules submodule.3rdpart/jsoncpp.url https://github.com/open-source-parsers/jsoncpp.git
  git -C "$SRC" submodule sync
  git -C "$SRC" submodule update --init --depth 1 -- 3rdpart/ZLToolKit 3rdpart/media-server 3rdpart/jsoncpp
  rm -rf "$SRC/build"
fi
# Una cache CMake già configurata per una sola architettura non diventa universal da sola.
CACHE="$SRC/build/CMakeCache.txt"
if [ -f "$CACHE" ] && ! grep -q 'CMAKE_OSX_ARCHITECTURES:STRING=arm64;x86_64' "$CACHE"; then
  rm -rf "$SRC/build"
fi
cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_WEBRTC=OFF \
  -DENABLE_OPENSSL=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_PLAYER=OFF \
  -DENABLE_SERVER=OFF \
  -DENABLE_SCTP=OFF \
  -DENABLE_OBJCOPY=OFF \
  -DENABLE_API=ON \
  -DENABLE_SRT=ON \
  -DENABLE_MP4=ON \
  -DENABLE_HLS=ON \
  -DENABLE_RTPPROXY=ON \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "$SRC/build" --target mk_api -j "$(sysctl -n hw.ncpu)"
install_name_tool -id "@rpath/libmk_api.dylib" "$SRC/release/darwin/Release/libmk_api.dylib"
echo "libmk_api.dylib pronta"
