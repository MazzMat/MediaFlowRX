#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-/tmp/mfrx-release}"
APP="$DERIVED/Build/Products/Release/MediaFlowRX.app"
OUT="$ROOT/dist/MediaFlowRX.dmg"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Senza destinazione generica xcodebuild sceglie il Mac corrente e compila solo la sua architettura.
xcodebuild -project "$ROOT/MediaFlowRX.xcodeproj" -scheme MediaFlowRX -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=NO build

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/MediaFlowRX.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/dist"
rm -f "$OUT"
diskutil image create from --format UDZO --volumeName MediaFlowRX "$STAGE" "$OUT"
echo "DMG pronto: $OUT"
