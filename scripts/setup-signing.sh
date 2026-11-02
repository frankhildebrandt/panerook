#!/bin/bash
# Generate a personal signing identity. This does not create an Apple Developer ID.
set -euo pipefail
umask 077

directory="$HOME/Library/Application Support/PaneRook/Signing"
upload=0
existing=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --github) upload=1; shift ;;
    --github-only) upload=1; existing=1; shift ;;
    --directory)
      [[ $# -ge 2 ]] || { echo "--directory requires a path." >&2; exit 1; }
      directory="$2"; shift 2 ;;
    *) echo "Usage: $0 [--directory PATH] [--github|--github-only]" >&2; exit 1 ;;
  esac
done
if [[ "$directory" != /* ]]; then
  echo "The signing directory must be an absolute path outside the checkout." >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# Resolve symlinks and '..' even when the final directory does not exist yet.
directory="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$directory")"
if [[ "$directory/" == "$root/"* ]]; then
  echo "Keep signing keys outside the checkout." >&2
  exit 1
fi
if [[ "$upload" == 1 ]]; then
  # Verify access before creating keys; never regenerate keys to retry an upload.
  gh api repos/frankhildebrandt/panerook --jq .permissions.admin | /usr/bin/grep -qx true
fi

if [[ "$existing" == 0 ]]; then
  if [[ -e "$directory" ]]; then
    echo "Signing directory already exists; use --github-only to upload its identity." >&2
    exit 1
  fi
  mkdir -p "$directory"
  chmod 700 "$directory"
  /usr/bin/openssl rand -base64 48 > "$directory/certificate-password.txt"
  /usr/bin/openssl rand -base64 48 > "$directory/keychain-password.txt"
  cat > "$directory/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = PaneRook Private Signing (frankhildebrandt)
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
  /usr/bin/openssl req -new -newkey rsa:3072 -x509 -sha256 -days 3650 \
    -config "$directory/certificate.cnf" \
    -passout "file:$directory/certificate-password.txt" \
    -keyout "$directory/private-key.pem" -out "$directory/certificate.pem" 2> "$directory/generation.log"
  PANEROOK_P12_PASSWORD="$(cat "$directory/certificate-password.txt")" \
    /usr/bin/openssl pkcs12 -export -name "PaneRook Private Signing" \
    -inkey "$directory/private-key.pem" -in "$directory/certificate.pem" \
    -passin "file:$directory/certificate-password.txt" \
    -passout env:PANEROOK_P12_PASSWORD -out "$directory/certificate.p12"
  /usr/bin/openssl x509 -in "$directory/certificate.pem" -noout -fingerprint -sha1 \
    | /usr/bin/sed 's/.*=//; s/://g' > "$directory/identity.txt"

  keychain="$directory/signing.keychain-db"
  # A dedicated keychain avoids changing the login keychain or system trust.
  /usr/bin/security create-keychain -p "$(cat "$directory/keychain-password.txt")" "$keychain"
  /usr/bin/security set-keychain-settings -lut 21600 "$keychain"
  /usr/bin/security unlock-keychain -p "$(cat "$directory/keychain-password.txt")" "$keychain"
  /usr/bin/security import "$directory/certificate.p12" -k "$keychain" \
    -P "$(cat "$directory/certificate-password.txt")" -T /usr/bin/codesign
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$(cat "$directory/keychain-password.txt")" "$keychain" > /dev/null
fi

for file in certificate.p12 certificate-password.txt identity.txt; do
  [[ -s "$directory/$file" ]] || { echo "Missing $directory/$file" >&2; exit 1; }
done
if [[ "$upload" == 1 ]]; then
  /usr/bin/base64 -i "$directory/certificate.p12" | gh secret set PANEROOK_CERTIFICATE_BASE64 --repo frankhildebrandt/panerook
  gh secret set PANEROOK_CERTIFICATE_PASSWORD --repo frankhildebrandt/panerook < "$directory/certificate-password.txt"
  gh secret set PANEROOK_SIGNING_IDENTITY --repo frankhildebrandt/panerook < "$directory/identity.txt"
  echo "GitHub signing secrets configured for frankhildebrandt/panerook."
fi
echo "Signing identity: $(cat "$directory/identity.txt")"
echo "Private signing files: $directory"
echo "Back up this directory securely; it contains the signing key and its passwords."
