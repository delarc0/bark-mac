#!/usr/bin/env bash
#
# Creates a local, self-signed "Bark Dev" code-signing certificate.
#
# OPTIONAL. Bark builds fine without it (install.sh falls back to ad-hoc
# signing). The only thing this buys you: a stable signing identity, so macOS
# keeps your Microphone and Accessibility grants when you rebuild Bark instead
# of forgetting them every time.
#
# Run it once, then run ./install.sh. It asks for your login password once
# (macOS requires that to trust a new code-signing certificate). Nothing leaves
# your Mac; this cert is not an Apple Developer account and cannot notarize.
#
#   ./scripts/create-signing-cert.sh

set -euo pipefail

CERT_NAME="Bark Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
  echo "'$CERT_NAME' code-signing identity already exists. Nothing to do."
  exit 0
fi

KEYCHAIN="$(security default-keychain | tr -d ' "')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/bark.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = Bark Dev
[ ext ]
basicConstraints   = critical, CA:FALSE
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
CNF

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/bark.key" -out "$TMP/bark.crt" -config "$TMP/bark.cnf" >/dev/null 2>&1

# OpenSSL 3.x needs -legacy so macOS Security can verify the PKCS#12 MAC;
# stock macOS ships LibreSSL, which neither has nor needs the flag.
LEGACY_FLAG=""
if openssl version 2>/dev/null | grep -q "^OpenSSL 3"; then
  LEGACY_FLAG="-legacy"
fi
openssl pkcs12 -export $LEGACY_FLAG -out "$TMP/bark.p12" \
  -inkey "$TMP/bark.key" -in "$TMP/bark.crt" -passout pass: >/dev/null 2>&1

echo "==> Importing into your login keychain"
security import "$TMP/bark.p12" -k "$KEYCHAIN" -P "" -A >/dev/null

echo "==> Trusting it for code signing (this is the login-password prompt)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/bark.crt"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
  echo "Done. '$CERT_NAME' is ready. Now run ./install.sh"
else
  echo "Something went wrong — '$CERT_NAME' is not showing up. Bark will still build ad-hoc." >&2
  exit 1
fi
