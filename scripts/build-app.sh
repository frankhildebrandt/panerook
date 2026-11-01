#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  echo "Usage: $0 [debug|release]" >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
swift_options=(--cache-path "$PWD/.build/cache")
if [[ "${PANEROOK_DISABLE_BUILD_SANDBOX:-0}" == 1 ]]; then
  swift_options+=(--disable-sandbox)
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
# Mark the rebuilt application as changed so its bundle icon can be refreshed.
touch "$bundle"
/usr/bin/codesign --force --sign - "$bundle"
echo "$bundle"
