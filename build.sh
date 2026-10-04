#!/bin/zsh
# Builds "Phonon Dictation.app" with Apple's command line tools and installs it in ~/Applications.
set -euo pipefail
cd "${0:a:h}"

APP="build/Phonon Dictation.app"
PHONON="$PWD/.venv/bin/phonon"
[[ -x "$PHONON" ]] || { echo "Phonon is not installed in .venv; see README.md"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/PhononDictation"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.phonon-dictation</string>
  <key>CFBundleName</key><string>Phonon Dictation</string>
  <key>CFBundleExecutable</key><string>PhononDictation</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Phonon Dictation listens while you hold the dictation key.</string>
  <key>PhononCommand</key><string>$PHONON</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/"Phonon Dictation.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Phonon Dictation.app"
