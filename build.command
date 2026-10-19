#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release
bundle="$PWD/dist/FocusDesk.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/FocusDesk "$bundle/Contents/MacOS/FocusDesk"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$bundle"
echo "App lista: $bundle"
