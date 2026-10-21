#!/bin/bash
# One-time setup: creates a self-signed code-signing certificate "Halu Local Signing" in the login
# Keychain. build.sh signs with it when it exists, so every rebuild keeps the same identity and
# macOS keeps Halu's permissions (microphone, calendars, Notes, Keychain) across updates.
set -euo pipefail

NAME="Halu Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout pass:halu
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P halu -T /usr/bin/codesign

echo "Created \"$NAME\". Rebuild with ./scripts/build.sh --install"
