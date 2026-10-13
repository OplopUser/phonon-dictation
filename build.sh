#!/bin/zsh
# Builds "Phonon Dictation.app" with Apple's command line tools and installs it in ~/Applications.
set -euo pipefail
cd "${0:a:h}"

APP="build/Phonon Dictation.app"
PHONON="$PWD/.venv/bin/phonon"
[[ -x "$PHONON" ]] || { echo "Phonon is not installed in .venv; see README.md"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Spoken cues for when recording starts and stops, in the Mac's default voice.
say -r 240 -o "$APP/Contents/Resources/start.aiff" "Start"
say -r 240 -o "$APP/Contents/Resources/stop.aiff" "Stop"

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

# Sign with the local certificate (see scripts/create-signing-identity.sh) so
# macOS keeps the Microphone and Accessibility permissions across rebuilds.
IDENTITY="Phonon Dictation Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP" || {
    echo "Signing failed. If the error is errSecInternalComponent, your login keychain is probably locked: unlock it (open Keychain Access) and run ./build.sh again."
    exit 1
  }
else
  echo "No \"$IDENTITY\" certificate: signing ad hoc, so macOS will ask for permissions again after every rebuild."
  codesign --force --sign - "$APP"
fi

# Replace the installed app, restarting it if it is running.
running=false
if pgrep -xq PhononDictation; then
  running=true
  osascript -e 'quit app "Phonon Dictation"'
  while pgrep -xq PhononDictation; do sleep 0.2; done
fi
mkdir -p ~/Applications
rm -rf ~/Applications/"Phonon Dictation.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Phonon Dictation.app"
if $running; then open ~/Applications/"Phonon Dictation.app"; fi
