#!/bin/zsh
# Creates a self-signed code-signing certificate, "Phonon Dictation Local Signing",
# in your login keychain. build.sh signs the app with it, so macOS keeps the app's
# Microphone and Accessibility permissions across rebuilds. It is only used to sign
# this app on this Mac; delete it in Keychain Access to remove it.
set -euo pipefail
NAME="Phonon Dictation Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists."
  exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
password=$(uuidgen)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$work/key.pem" -out "$work/cert.pem" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/identity.p12" -passout "pass:$password"
security import "$work/identity.p12" -k ~/Library/Keychains/login.keychain-db -P "$password" -T /usr/bin/codesign
echo "Created \"$NAME\". Run ./build.sh to sign the app with it."
