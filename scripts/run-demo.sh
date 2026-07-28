#!/usr/bin/env bash
# Build and launch CodeEditorViewDemo as a proper .app so macOS gives it key focus.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="$ROOT/Examples/CodeEditorViewDemo"
BUILD="$DEMO/.build/debug/CodeEditorViewDemo"
APP="$DEMO/.build/CodeEditorViewDemo.app"

echo "Building demo…"
cd "$DEMO"
swift build -c debug

# Minimal app bundle (required for reliable keyboard focus when not launched from Xcode).
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BUILD" "$APP/Contents/MacOS/CodeEditorViewDemo"
chmod +x "$APP/Contents/MacOS/CodeEditorViewDemo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>CodeEditorViewDemo</string>
	<key>CFBundleIdentifier</key>
	<string>dev.codeeditorview.demo</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>CodeEditorViewDemo</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

# Kill previous instances (binary or bundle).
pkill -x CodeEditorViewDemo 2>/dev/null || true
sleep 0.2

echo "Opening $APP"
open "$APP"
echo "Launched. Click the editor and type — the app should stay key-focused."
