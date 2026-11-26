#!/usr/bin/env bash
# Selects the Xcode whose iOS simulator runtime the shots use, and installs XcodeGen for the driver.
set -euo pipefail

xcode=/Applications/Xcode_27.2.app
[[ -d $xcode ]] || xcode=/Applications/Xcode.app
sudo xcode-select --switch "$xcode/Contents/Developer"
xcodebuild -version

# A release from July 2026, months old; its zip holds a universal binary and its templates.
version=2.46.0
dir="$RUNNER_TEMP/xcodegen"
mkdir -p "$dir"
curl -fsSL -o "$dir/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
unzip -q -o "$dir/xcodegen.zip" -d "$dir"
echo "$dir/xcodegen/bin" >> "$GITHUB_PATH"
"$dir/xcodegen/bin/xcodegen" --version
