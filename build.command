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

# Detect stable Apple Development identity if available so TCC permissions persist across recompilations.
identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}')"
fi
if [[ -z "$identity" ]]; then
  identity="-"
  echo "Aviso: firmando en modo ad-hoc (-). Para conservar permisos TCC entre compilaciones, usa un certificado Apple Development."
else
  echo "Firmando con identidad estable: $identity"
fi

codesign --force --sign "$identity" "$bundle"
codesign --verify --deep --strict "$bundle"
plutil -lint "$bundle/Contents/Info.plist" >/dev/null
echo "App lista y verificada: $bundle"
