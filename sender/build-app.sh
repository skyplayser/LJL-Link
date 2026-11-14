#!/bin/zsh
# Builds "LJL Link.app" (Apple silicon and Intel) for the club's USB stick. Ad-hoc signed: a stick written by
# LJ Link carries no quarantine flag, so Gatekeeper does not stop it (concept 8). Usage: build-app.sh [out dir]
set -e
cd "${0:A:h}"
OUT="${1:-.build/app}"
APP="$OUT/LJL Link.app"
VERSION=$(grep -o 'version = "[^"]*"' Sources/LJLLinkApp/Model.swift | head -1 | cut -d'"' -f2)
# One build per architecture, then one universal file (the Command Line Tools cannot build both at once).
# Intel first: the last build decides where .build/release points, and that should stay this Mac's own.
swift build -c release --product LJLLinkApp --triple x86_64-apple-macosx14.0 >/dev/null
swift build -c release --product LJLLinkApp --triple arm64-apple-macosx14.0 >/dev/null
BIN=.build/LJLLinkApp-universal
lipo -create -output "$BIN" .build/arm64-apple-macosx/release/LJLLinkApp .build/x86_64-apple-macosx/release/LJLLinkApp
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LJL Link"
cp Resources/AppIcon.icns Resources/Logo.png Resources/MenuIcon.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LJL Link</string>
  <key>CFBundleDisplayName</key><string>LJL Link</string>
  <key>CFBundleIdentifier</key><string>dev.ljlinkpro.sender</string>
  <key>CFBundleExecutable</key><string>LJL Link</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Finds LJ Link in the booth and the chat of the suite programs in this network.</string>
  <key>NSBonjourServices</key><array><string>_ljlink._tcp</string></array>
  <key>NSScreenCaptureUsageDescription</key><string>Reads only the time display in Serato's window, so the waveform in LJ Link runs along.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP ($(lipo -archs "$APP/Contents/MacOS/LJL Link"))"
