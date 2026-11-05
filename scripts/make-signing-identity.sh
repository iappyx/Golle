#!/bin/bash
# One-time: creates a self-signed code-signing identity "Golle Local Signing" in the login keychain.
# Signing every build with the same identity keeps Keychain access (the Touch ID unlock key)
# valid across rebuilds (ad-hoc signatures change with every build).
set -euo pipefail
NAME="Golle Local Signing"

if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
LEGACY=""
openssl pkcs12 -help 2>&1 | grep -q -- "-legacy" && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout pass:golle
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P golle -T /usr/bin/codesign
echo "Created \"$NAME\"."
