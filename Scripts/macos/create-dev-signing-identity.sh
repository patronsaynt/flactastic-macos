#!/usr/bin/env bash
# Creates a self-signed code-signing identity ("FLACtastic Development") in
# the login keychain. Run once per Mac.
#
# Why: ad-hoc signatures change with every build, so macOS treats each
# rebuild as a different app and forgets privacy grants such as Local
# Network access (needed for library sync and network speakers). Signing
# every build with this one certificate gives the app a stable identity,
# so those grants survive rebuilds.
#
# The certificate is only trusted on this Mac and only for code signing.
# It's not a Developer ID: builds signed with it still aren't notarized
# for distribution.
#
# Usage: create-dev-signing-identity.sh
# Remove: delete "FLACtastic Development" in Keychain Access (login keychain,
#         My Certificates).

set -euo pipefail

IDENTITY_NAME="FLACtastic Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✅ \"$IDENTITY_NAME\" already exists in the login keychain — nothing to do."
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "▶ Generating key and certificate (valid 10 years)..."
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
    -config "$WORK_DIR/cert.cnf" >/dev/null 2>&1

# The keychain only imports PKCS#12 using older ciphers. OpenSSL 3 needs
# -legacy for that; macOS's bundled LibreSSL already defaults to them.
P12_PASS="flactastic-dev"
LEGACY_FLAG=""
if openssl version | grep -q "^OpenSSL 3"; then LEGACY_FLAG="-legacy"; fi
openssl pkcs12 -export $LEGACY_FLAG -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -name "$IDENTITY_NAME" -out "$WORK_DIR/identity.p12" -passout "pass:$P12_PASS"

echo "▶ Importing into the login keychain (codesign may use the key)..."
security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

echo "▶ Trusting it for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem"

echo
security find-identity -v -p codesigning | grep "$IDENTITY_NAME" || {
    echo "⚠️  The identity was imported but isn't listed as valid for code signing."
    echo "   Open Keychain Access → login → My Certificates → \"$IDENTITY_NAME\""
    echo "   → Trust → Code Signing: Always Trust."
    exit 1
}
echo "✅ Done. package-macos.sh will now sign builds as \"$IDENTITY_NAME\"."
echo "   The first launch of a build signed this way asks for Local Network"
echo "   access once; later rebuilds keep the grant."
