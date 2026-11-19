#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
bundle=".build/Notch Focus.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 "$binary_dir/NotchFocus" "$bundle/Contents/MacOS/NotchFocus"
install -m 644 Info.plist "$bundle/Contents/Info.plist"
ditto "$binary_dir/NotchFocus_NotchFocus.bundle" "$bundle/Contents/Resources/NotchFocus_NotchFocus.bundle"
codesign --force --sign - --identifier dev.felipecesar.NotchFocus "$bundle"
printf '%s\n' "$PWD/$bundle"
