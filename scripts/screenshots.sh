#!/bin/bash
# Takes the README screenshots with made-up data (Halu --demo), never your own.
# Builds a copy named "Halu Demo" with its own bundle identifier, so its settings and data
# (Application Support/Halu-Demo) stay apart from yours and the Keychain is never asked.
# Your Halu is quit while it runs and started again at the end. Don't touch the mouse meanwhile.
set -euo pipefail
cd "$(dirname "$0")/.."

TABS=(today calendar tasks claude messages habits finance weather tools)
OUT="docs/screenshots"

scripts/build.sh
DEMO="build/Halu Demo.app"
rm -rf "$DEMO"
cp -R build/Halu.app "$DEMO"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.milana.halu.demo" "$DEMO/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Halu Demo" "$DEMO/Contents/Info.plist"
codesign --force --deep --sign - "$DEMO"

# A fresh demo every time.
rm -rf "$HOME/Library/Application Support/Halu-Demo"
defaults delete com.milana.halu.demo 2>/dev/null || true

pkill -x Halu || true
sleep 1

# The panel opens at the top centre of the main screen.
WIDTH=$(osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)')
X=$(( WIDTH / 2 - 380 ))
mkdir -p "$OUT"
# Halu Demo covers the screen with the desktop picture (only the wallpaper shows behind the glass),
# opens each tab in turn and writes its name to Halu-Demo/showing; each shot waits for that.
SHOWING="$HOME/Library/Application Support/Halu-Demo/showing"
open -n "$DEMO" --args --demo --open "$(IFS=,; echo "${TABS[*]}")"
for tab in "${TABS[@]}"; do
    for _ in $(seq 1 150); do
        [[ "$(cat "$SHOWING" 2>/dev/null)" == "$tab" ]] && break
        sleep 0.2
    done
    sleep 2
    screencapture -x -R "$X,0,760,480" "$OUT/$tab.png"
done

pkill -f "Halu Demo.app/Contents/MacOS/Halu" || true
open "$HOME/Applications/Halu.app"
echo "Saved to $OUT"
