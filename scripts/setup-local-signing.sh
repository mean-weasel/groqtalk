#!/bin/bash
set -euo pipefail

CERT_NAME="GroqTalk Local Code Signing"
KEYCHAIN_NAME="groqtalk-codesign.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"
KEYCHAIN_PASSWORD="${LOCAL_SIGN_KEYCHAIN_PASSWORD:-groqtalk-local-codesign}"
P12_PASSWORD="groqtalk-local"
TMPDIR_TO_CLEAN=""

cleanup() {
  if [ -n "$TMPDIR_TO_CLEAN" ]; then
    rm -rf "$TMPDIR_TO_CLEAN"
  fi
}
trap cleanup EXIT

has_identity() {
  security find-identity -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -q "\"$CERT_NAME\""
}

keychain_search_list() {
  security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//' | awk '!seen[$0]++'
}

ensure_keychain_in_search_list() {
  local current updated
  current="$(keychain_search_list)"
  if printf "%s\n" "$current" | grep -qx "$KEYCHAIN_PATH"; then
    updated="$current"
  else
    updated="$(printf "%s\n%s\n" "$KEYCHAIN_PATH" "$current" | awk '!seen[$0]++')"
  fi
  # shellcheck disable=SC2086
  security list-keychains -d user -s $updated
}

delete_stale_login_certificates() {
  while security find-certificate -c "$CERT_NAME" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; do
    security delete-certificate -c "$CERT_NAME" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || break
  done
}

create_keychain() {
  if [ ! -f "$KEYCHAIN_PATH" ]; then
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
  fi
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  ensure_keychain_in_search_list
}

create_identity() {
  local tmpdir config
  tmpdir="$(mktemp -d)"
  TMPDIR_TO_CLEAN="$tmpdir"
  config="$tmpdir/openssl.cnf"

  cat > "$config" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $CERT_NAME

[v3_req]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$tmpdir/codesign.key" \
    -out "$tmpdir/codesign.crt" \
    -days 3650 \
    -config "$config" \
    -sha256 >/dev/null 2>&1

  openssl pkcs12 -legacy -export \
    -name "$CERT_NAME" \
    -inkey "$tmpdir/codesign.key" \
    -in "$tmpdir/codesign.crt" \
    -out "$tmpdir/codesign.p12" \
    -passout "pass:$P12_PASSWORD" >/dev/null 2>&1

  security import "$tmpdir/codesign.p12" \
    -k "$KEYCHAIN_PATH" \
    -P "$P12_PASSWORD" \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN_PATH" \
    "$tmpdir/codesign.crt" >/dev/null

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null
}

delete_stale_login_certificates
create_keychain

if has_identity; then
  echo "Local signing identity already exists: $CERT_NAME"
else
  create_identity
  echo "Created local signing identity: $CERT_NAME"
fi

security find-identity -p codesigning "$KEYCHAIN_PATH" | sed -n '1,12p'
