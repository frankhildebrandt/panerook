#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
requested_version="${1:-$version}"
requested_version="${requested_version#v}"
if [[ $# -gt 1 || "$requested_version" != "$version" ]]; then
  echo "Release version must match Resources/Info.plist ($version)." >&2
  exit 1
fi

identity="${PANEROOK_SIGNING_IDENTITY:--}"
timestamp="${PANEROOK_SIGNING_TIMESTAMP:-none}"
if [[ "$timestamp" != none && "$timestamp" != secure ]]; then
  echo "PANEROOK_SIGNING_TIMESTAMP must be none or secure." >&2
  exit 1
fi
if [[ -n "${PANEROOK_NOTARY_PROFILE:-}" && "$identity" == - ]]; then
  echo "Notarization requires a Developer ID Application signing identity." >&2
  exit 1
fi

./scripts/build-app.sh release universal
bundle="$PWD/build/PaneRook.app"
artifact="PaneRook-${version}-macOS-universal"
output="$PWD/build/release"
mkdir -p "$output"
staging="$(mktemp -d "$PWD/build/package-release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

staple() {
  local target="$1"
  local attempt status
  for attempt in 1 2 3 4; do
    if xcrun stapler staple "$target"; then
      xcrun stapler validate "$target"
      return
    else
      status=$?
    fi
    # The accepted ticket can briefly be unavailable from Apple's delivery service.
    if [[ "$status" != 68 && "$status" != 69 ]] || [[ "$attempt" == 4 ]]; then
      return "$status"
    fi
    echo "Apple ticket service unavailable (stapler $status); retrying ($attempt/3)." >&2
    sleep "$((5 * (2 ** (attempt - 1))))"
  done
}

notarize() {
  local submission="$1"
  local target="$2"
  local options=(--keychain-profile "$PANEROOK_NOTARY_PROFILE" --wait)
  if [[ -n "${PANEROOK_NOTARY_KEYCHAIN:-}" ]]; then
    options+=(--keychain "$PANEROOK_NOTARY_KEYCHAIN")
  fi
  xcrun notarytool submit "$submission" "${options[@]}"
  staple "$target"
}

if [[ -n "${PANEROOK_NOTARY_PROFILE:-}" ]]; then
  signature="$(/usr/bin/codesign --display --verbose=4 "$bundle" 2>&1)"
  if [[ "$signature" != *"Authority=Developer ID Application:"* ]]; then
    echo "Notarization requires an Apple-issued Developer ID Application certificate." >&2
    exit 1
  fi
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$bundle" "$staging/notarization.zip"
  notarize "$staging/notarization.zip" "$bundle"
fi
/usr/bin/codesign --verify --strict --all-architectures "$bundle"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$bundle" "$output/$artifact.zip"
mkdir "$staging/dmg"
/usr/bin/ditto "$bundle" "$staging/dmg/PaneRook.app"
ln -s /Applications "$staging/dmg/Applications"
/usr/bin/hdiutil create -volname PaneRook -srcfolder "$staging/dmg" \
  -fs HFS+ -format UDZO -ov "$output/$artifact.dmg"

if [[ "$identity" != - ]]; then
  signing_options=(--force --sign "$identity")
  if [[ -n "${PANEROOK_SIGNING_KEYCHAIN:-}" ]]; then
    signing_options+=(--keychain "$PANEROOK_SIGNING_KEYCHAIN")
  fi
  if [[ "$timestamp" == secure ]]; then
    signing_options+=(--timestamp)
  else
    signing_options+=(--timestamp=none)
  fi
  /usr/bin/codesign "${signing_options[@]}" "$output/$artifact.dmg"
  /usr/bin/codesign --verify --strict "$output/$artifact.dmg"
fi
if [[ -n "${PANEROOK_NOTARY_PROFILE:-}" ]]; then
  notarize "$output/$artifact.dmg" "$output/$artifact.dmg"
fi
/usr/bin/hdiutil verify "$output/$artifact.dmg"
(
  cd "$output"
  for extension in zip dmg; do
    /usr/bin/shasum -a 256 "$artifact.$extension" > "$artifact.$extension.sha256"
    /usr/bin/shasum -a 256 -c "$artifact.$extension.sha256"
  done
)
echo "$output/$artifact.zip"
echo "$output/$artifact.dmg"
