#!/bin/bash
set -euo pipefail

case "${1:-}" in
    ""|--no-open) ;;
    *) echo "Usage: $0 [--no-open]"; exit 2 ;;
esac

project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$project_dir/build"
app_dir="$build_dir/M5ScrollBoost.app"
contents_dir="$app_dir/Contents"
executable_dir="$contents_dir/MacOS"

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple's Swift toolchain is unavailable."
    /usr/bin/xcrun --find swiftc >&2 || true
    echo "Run: xcode-select --install"
    exit 1
fi

/bin/rm -rf "$app_dir"
/bin/mkdir -p "$executable_dir" "$contents_dir/Resources"
/bin/cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
/bin/cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"

/usr/bin/xcrun swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -module-cache-path "$build_dir/ModuleCache" \
    -target arm64-apple-macos14.0 \
    "$project_dir/Sources/M5ScrollBoost.swift" \
    -o "$executable_dir/M5ScrollBoost" \
    -framework AppKit \
    -framework CoreGraphics \
    -framework IOKit \
    -framework Metal \
    -framework SwiftUI

/usr/bin/codesign --force --deep --sign - "$app_dir"

echo
echo "Built: $app_dir"
if [[ "${1:-}" != "--no-open" ]]; then
    echo "Opening M5 Scroll Boost…"
    /usr/bin/open "$app_dir"
fi
