#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

if [[ "${1:-}" != "--skip-tests" ]]; then
  echo "Ejecutando tests unitarios de FocusCore..."
  swift test
fi

echo "Compilando y firmando FocusDesk.app..."
./build.command

app="dist.noindex/FocusDesk.app"
binary="$app/Contents/MacOS/FocusDesk"
dmg="dist.noindex/FocusDesk-macOS.dmg"

plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$app"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"
if [[ "$bundle_id" != "com.articdia.focusdesk" ]]; then
  echo "Error: CFBundleIdentifier inesperado ($bundle_id)."
  exit 1
fi

echo "Ejecutando smoke test de integración..."
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/focusdesk-dmg-smoke.XXXXXX")"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/focusdesk-dmg-stage.XXXXXX")"
trap 'rm -rf "$smoke_dir" "$stage_dir"' EXIT

smoke_out="$("$binary" --preview --preview-directory "$smoke_dir" --smoke-test)"
if [[ "$smoke_out" != PASS* ]]; then
  echo "Error: smoke test falló ($smoke_out)"
  exit 1
fi

echo "Preparando imagen .dmg..."
ditto "$app" "$stage_dir/FocusDesk.app"
ln -s /Applications "$stage_dir/Applications"

rm -f "$dmg"
hdiutil create \
  -volname "FocusDesk" \
  -srcfolder "$stage_dir" \
  -ov \
  -format UDZO \
  "$dmg"

dev_id="${CODESIGN_IDENTITY:-}"
if [[ -z "$dev_id" ]]; then
  dev_id="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ {print $2; exit}')"
fi

if [[ "$dev_id" == Developer\ ID\ Application:* ]]; then
  echo "Firmando $dmg con $dev_id..."
  codesign --force --timestamp --sign "$dev_id" "$dmg"

  notary_profile="${NOTARY_PROFILE:-}"
  if [[ -n "$notary_profile" ]]; then
    echo "Enviando a notarización con perfil '$notary_profile'..."
    xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    echo "DMG firmado, notarizado y grapado correctamente."
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    echo "Enviando a notarización con credenciales APPLE_ID..."
    xcrun notarytool submit "$dmg" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    echo "DMG firmado, notarizado y grapado correctamente."
  else
    echo "DMG firmado con Developer ID. Para notarizarlo: NOTARY_PROFILE=FocusDeskNotary ./scripts/make-dmg.command"
  fi
else
  echo "Aviso: no hay certificado Developer ID Application en el llavero todavía; .dmg creado sin notarizar."
fi

echo "DMG listo: $dmg"
shasum -a 256 "$dmg"
