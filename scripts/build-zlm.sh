#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/ZLMediaKit"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$ROOT/third_party"
  git clone --depth 1 https://github.com/ZLMediaKit/ZLMediaKit.git "$SRC"
  git -C "$SRC" config -f .gitmodules submodule.ZLToolKit.url https://github.com/ZLMediaKit/ZLToolKit.git
  git -C "$SRC" config -f .gitmodules submodule.3rdpart/media-server.url https://github.com/ireader/media-server.git
  git -C "$SRC" config -f .gitmodules submodule.3rdpart/jsoncpp.url https://github.com/open-source-parsers/jsoncpp.git
  git -C "$SRC" submodule sync
  git -C "$SRC" submodule update --init --depth 1 -- 3rdpart/ZLToolKit 3rdpart/media-server 3rdpart/jsoncpp
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
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "$SRC/build" --target mk_api -j "$(sysctl -n hw.ncpu)"
install_name_tool -id "@rpath/libmk_api.dylib" "$SRC/release/darwin/Release/libmk_api.dylib"
echo "libmk_api.dylib pronta"
