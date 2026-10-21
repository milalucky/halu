#!/bin/bash
# Builds Halu.app into ./build and, with --install, copies it to ~/Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/Halu.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Halu" "$APP/Contents/MacOS/Halu"
cp "$BIN/halu-hook" "$APP/Contents/MacOS/halu-hook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable identity (see setup-signing.sh) keeps macOS permissions across rebuilds; ad-hoc otherwise.
IDENTITY="-"
if security find-identity -p codesigning | grep -q "Halu Local Signing"; then
    IDENTITY="Halu Local Signing"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/halu-hook"
codesign --force --sign "$IDENTITY" "$APP"
echo "Signed with: $IDENTITY"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Halu || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Halu.app"
    cp -R "$APP" "$HOME/Applications/Halu.app"
    open "$HOME/Applications/Halu.app"
    echo "Installed to ~/Applications/Halu.app"
fi
