#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
architecture="${2:-native}"
if [[ "$configuration" != debug && "$configuration" != release ]] ||
   [[ "$architecture" != native && "$architecture" != universal ]] || [[ $# -gt 2 ]]; then
  echo "Usage: $0 [debug|release] [native|universal]" >&2
  exit 1
fi
identity="${PANEROOK_SIGNING_IDENTITY:--}"
timestamp="${PANEROOK_SIGNING_TIMESTAMP:-none}"
if [[ "$timestamp" != none && "$timestamp" != secure ]]; then
  echo "PANEROOK_SIGNING_TIMESTAMP must be none or secure." >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
swift_options=(--cache-path "$PWD/.build/cache")
if [[ "${PANEROOK_DISABLE_BUILD_SANDBOX:-0}" == 1 ]]; then
  swift_options+=(--disable-sandbox)
fi
if [[ "$architecture" == universal ]]; then
  swift_options+=(--arch arm64 --arch x86_64)
fi
swift build "${swift_options[@]}" -c "$configuration"
binary_path="$(swift build "${swift_options[@]}" -c "$configuration" --show-bin-path)"
bundle="$PWD/build/PaneRook.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Frameworks"
cp "$binary_path/PaneRook" "$bundle/Contents/MacOS/.PaneRook.new"
# SwiftPM also adds build-directory framework search paths. Bind the packaged
# executable directly to its re-signed copy, including for local signed builds.
/usr/bin/install_name_tool -change '@rpath/Sparkle.framework/Versions/B/Sparkle' \
  '@executable_path/../Frameworks/Sparkle.framework/Versions/B/Sparkle' "$bundle/Contents/MacOS/.PaneRook.new"
mv -f "$bundle/Contents/MacOS/.PaneRook.new" "$bundle/Contents/MacOS/PaneRook"
cp Resources/Info.plist "$bundle/Contents/.Info.plist.new"
if [[ -n "${PANEROOK_SPARKLE_PUBLIC_KEY:-}" ]]; then
  if [[ ! "$PANEROOK_SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
     [[ "$(printf '%s' "$PANEROOK_SPARKLE_PUBLIC_KEY" | /usr/bin/base64 -D | /usr/bin/wc -c | /usr/bin/tr -d '[:space:]')" != 32 ]]; then
    echo "PANEROOK_SPARKLE_PUBLIC_KEY must be a base64-encoded 32-byte Ed25519 public key." >&2
    exit 1
  fi
  /usr/bin/plutil -replace SUPublicEDKey -string "$PANEROOK_SPARKLE_PUBLIC_KEY" "$bundle/Contents/.Info.plist.new"
fi
mv -f "$bundle/Contents/.Info.plist.new" "$bundle/Contents/Info.plist"
cp Resources/PaneRook.icns "$bundle/Contents/Resources/.PaneRook.icns.new"
mv -f "$bundle/Contents/Resources/.PaneRook.icns.new" "$bundle/Contents/Resources/PaneRook.icns"
# SwiftPM links binary frameworks but does not assemble the application bundle.
# ditto preserves the versioned framework's symlinks and helper permissions.
sparkle_source=""
for candidate in "$binary_path/Sparkle.framework" "$PWD"/.build/artifacts/*/*/Sparkle.xcframework/macos-*/Sparkle.framework; do
  if [[ -d "$candidate" ]]; then
    sparkle_source="$candidate"
    break
  fi
done
if [[ -z "$sparkle_source" ]]; then
  echo "Sparkle.framework was not found in the SwiftPM build artifacts." >&2
  exit 1
fi
sparkle="$bundle/Contents/Frameworks/Sparkle.framework"
rm -rf "$sparkle"
/usr/bin/ditto "$sparkle_source" "$sparkle"
sparkle_license=""
for candidate in "$PWD"/.build/artifacts/*/Sparkle/LICENSE; do
  if [[ -f "$candidate" ]]; then
    sparkle_license="$candidate"
    break
  fi
done
if [[ -z "$sparkle_license" ]]; then
  echo "Sparkle's distribution license was not found in the SwiftPM artifacts." >&2
  exit 1
fi
cp "$sparkle_license" "$bundle/Contents/Resources/Sparkle-LICENSE.txt"
if [[ "$architecture" == universal ]]; then
  /usr/bin/lipo "$bundle/Contents/MacOS/PaneRook" -verify_arch arm64
  /usr/bin/lipo "$bundle/Contents/MacOS/PaneRook" -verify_arch x86_64
fi
# Mark the rebuilt application as changed so its bundle icon can be refreshed.
touch "$bundle"
signing_options=(--force --sign "$identity")
if [[ -n "${PANEROOK_SIGNING_KEYCHAIN:-}" ]]; then
  signing_options+=(--keychain "$PANEROOK_SIGNING_KEYCHAIN")
fi
if [[ "$identity" != - ]]; then
  signing_options+=(--options runtime)
fi
if [[ "$timestamp" == secure ]]; then
  signing_options+=(--timestamp)
else
  signing_options+=(--timestamp=none)
fi
# Sign nested code from the inside out, retaining the downloader sandbox rights.
# Do not use --deep when signing: each helper has its own entitlements.
/usr/bin/codesign "${signing_options[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
/usr/bin/codesign "${signing_options[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
/usr/bin/codesign "${signing_options[@]}" "$sparkle/Versions/B/Autoupdate"
/usr/bin/codesign "${signing_options[@]}" "$sparkle/Versions/B/Updater.app"
/usr/bin/codesign "${signing_options[@]}" "$sparkle"
/usr/bin/codesign "${signing_options[@]}" "$bundle"
/usr/bin/codesign --verify --deep --strict --all-architectures "$bundle"
echo "$bundle"
