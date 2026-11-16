#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

swift build -c release
# «.noindex»: Spotlight no mira dentro, así que la copia recién compilada no sale como una segunda FocusDesk
# al lado de la instalada (el mismo truco que usa Xcode con sus carpetas de compilación).
bundle="$PWD/dist.noindex/FocusDesk.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/FocusDesk "$bundle/Contents/MacOS/FocusDesk"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
fi

# Prefer Developer ID Application (for public distribution & notarization), then Apple Development, then ad-hoc.
identity="${CODESIGN_IDENTITY:-}"
is_developer_id=false
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ {print $2; exit}')"
fi
if [[ "$identity" == Developer\ ID\ Application:* ]]; then
  is_developer_id=true
elif [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}')"
fi

entitlements_flag=()
if [[ -f Resources/FocusDesk.entitlements ]]; then
  entitlements_flag=(--entitlements Resources/FocusDesk.entitlements)
fi

if [[ -z "$identity" ]]; then
  identity="-"
  echo "Aviso: firmando en modo ad-hoc (-). Para distribuir públicamente, instala un certificado Developer ID Application."
  codesign --force --sign "$identity" "$bundle"
elif [[ "$is_developer_id" == true ]]; then
  echo "Firmando para distribución pública con Hardened Runtime: $identity"
  codesign --force --options runtime --timestamp "${entitlements_flag[@]}" --sign "$identity" "$bundle"
else
  echo "Firmando con identidad de desarrollo: $identity"
  codesign --force "${entitlements_flag[@]}" --sign "$identity" "$bundle"
fi

codesign --verify --deep --strict "$bundle"
plutil -lint "$bundle/Contents/Info.plist" >/dev/null
echo "App lista y verificada: $bundle"
