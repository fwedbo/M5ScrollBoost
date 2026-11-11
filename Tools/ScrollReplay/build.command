#!/bin/bash
set -euo pipefail
case "${1:-}" in
    ""|--no-open) ;;
    *) echo "Usage: $0 [--no-open]"; exit 2 ;;
esac
helper_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$helper_dir/../../build/ScrollReplay"
app_dir="$build_dir/ScrollReplay.app"
mkdir -p "$app_dir/Contents/MacOS" "$build_dir/ModuleCache"
cp "$helper_dir/Info.plist" "$app_dir/Contents/Info.plist"
xcrun swiftc -O -parse-as-library -swift-version 5 \
    -module-cache-path "$build_dir/ModuleCache" \
    "$helper_dir/ScrollReplay.swift" -o "$app_dir/Contents/MacOS/ScrollReplay" \
    -framework AppKit -framework ApplicationServices
codesign --force --sign - "$app_dir"
echo "Built: $app_dir"
if [[ "${1:-}" != "--no-open" ]]; then
    open "$app_dir"
fi
