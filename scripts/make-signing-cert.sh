#!/bin/bash
# Creates the "Kabuk Code Signing" certificate in the login keychain, which build-app.sh signs
# with. Releases must keep being signed with the same certificate: with a new one, every user's
# macOS asks for Kabuk's permissions once more. Keep a backup of it (Keychain Access → Export).
set -euo pipefail
NAME="Kabuk Code Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in the keychain."
  exit 0
fi
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
# The system's LibreSSL writes a PKCS#12 file that `security import` can read; OpenSSL 3+ doesn't by default.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/cert.cnf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -out "$DIR/cert.p12" -passout "pass:$PASS"
security import "$DIR/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\"."
