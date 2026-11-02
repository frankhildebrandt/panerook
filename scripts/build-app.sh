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
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_path/PaneRook" "$bundle/Contents/MacOS/.PaneRook.new"
mv -f "$bundle/Contents/MacOS/.PaneRook.new" "$bundle/Contents/MacOS/PaneRook"
cp Resources/Info.plist "$bundle/Contents/.Info.plist.new"
mv -f "$bundle/Contents/.Info.plist.new" "$bundle/Contents/Info.plist"
cp Resources/PaneRook.icns "$bundle/Contents/Resources/.PaneRook.icns.new"
mv -f "$bundle/Contents/Resources/.PaneRook.icns.new" "$bundle/Contents/Resources/PaneRook.icns"
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
/usr/bin/codesign "${signing_options[@]}" "$bundle"
/usr/bin/codesign --verify --strict --all-architectures "$bundle"
echo "$bundle"
