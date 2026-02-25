#!/bin/bash
set -e

echo "=== Plex Screensaver Build & Install ==="

# Step 1: Kill any running screensaver processes
echo "[1/7] Killing screensaver processes..."
killall legacyScreenSaver 2>/dev/null || true
killall ScreenSaverEngine 2>/dev/null || true
killall WallpaperAgent 2>/dev/null || true
osascript -e 'quit app "System Settings"' 2>/dev/null || true
osascript -e 'quit app "System Preferences"' 2>/dev/null || true
sleep 1

# Step 2: Remove old installed screensaver
echo "[2/7] Removing old screensaver..."
rm -rf ~/Library/Screen\ Savers/PlexScreensaver.saver

# Step 3: Clean old build artifacts
echo "[3/7] Cleaning old builds..."
rm -rf ~/Library/Developer/Xcode/DerivedData/PlexScreensaver-*

# Step 4: Generate Xcode project
echo "[4/7] Generating Xcode project..."
cd "$(dirname "$0")"
xcodegen generate

# Step 5: Build
echo "[5/7] Building (Release)..."
xcodebuild -scheme PlexScreensaver -configuration Release build 2>&1 | tail -3

# Step 6: Install
echo "[6/7] Installing screensaver..."
SAVER_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "PlexScreensaver.saver" -type d 2>/dev/null | head -1)
if [ -z "$SAVER_PATH" ]; then
    echo "ERROR: Build failed — PlexScreensaver.saver not found"
    exit 1
fi
cp -R "$SAVER_PATH" ~/Library/Screen\ Savers/
echo "Installed from: $SAVER_PATH"

# Step 7: Verify and open
echo "[7/7] Verifying installation..."
ls -la ~/Library/Screen\ Savers/PlexScreensaver.saver/Contents/MacOS/
echo ""
echo "=== Done! Opening Screen Saver settings... ==="
open "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"
