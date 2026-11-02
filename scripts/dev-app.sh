#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app_pid=""

stop_app() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""
  fi
}

trap stop_app EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot() {
  {
    # Hash contents so rapid edits, additions and deletions are all detected.
    # A file can disappear while saving; the next poll picks up the final state.
    find Sources Resources scripts -type f -exec shasum {} + 2>/dev/null || true
    shasum Makefile Package.swift Package.resolved 2>/dev/null || true
  } | LC_ALL=C sort | shasum
}

rebuild() {
  if ./scripts/build-app.sh debug; then
    stop_app
    ./build/PaneRook.app/Contents/MacOS/PaneRook &
    app_pid=$!
    echo "PaneRook started. Watching for changes (Ctrl-C to stop)."
  else
    echo "Build failed. Waiting for changes; any running app stays open." >&2
  fi
}

echo "Watching Sources/, Resources/, scripts/, Makefile and Package.swift/Package.resolved."
previous="$(snapshot)"
rebuild

while sleep 1; do
  current="$(snapshot)"
  if [[ "$current" != "$previous" ]]; then
    previous="$current"
    echo "Changes detected. Rebuilding PaneRook…"
    rebuild
  fi
done
