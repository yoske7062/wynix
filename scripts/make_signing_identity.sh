#!/bin/bash
# Creates a self-signed code-signing identity (default "WYNIX Local Signing") in the login keychain.
# Signing every build with the same identity keeps Steamy's code identity stable, so macOS
# privacy permissions (TCC) granted once survive rebuilds. Ad-hoc signatures change on every
# build, which makes macOS ask again each time. Local only; not valid for distribution.
set -euo pipefail

NAME="${1:-WYNIX Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if /usr/bin/security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity already exists: $NAME"
  exit 0
fi

work="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
pass="$(/usr/bin/uuidgen)"
# -legacy: macOS's keychain only reads the older PKCS#12 encryption.
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
  -out "$work/identity.p12" -passout "pass:$pass" 2>/dev/null
/usr/bin/security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign
echo "Created identity: $NAME"
