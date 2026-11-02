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

./scripts/build-app.sh release universal
artifact="PaneRook-${version}-macOS-universal.zip"
output="$PWD/build/release"
mkdir -p "$output"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent build/PaneRook.app "$output/$artifact"
(
  cd "$output"
  /usr/bin/shasum -a 256 "$artifact" > "$artifact.sha256"
  /usr/bin/shasum -a 256 -c "$artifact.sha256"
)
echo "$output/$artifact"
