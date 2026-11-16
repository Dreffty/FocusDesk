#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
tag="v${1:-$version}"
dmg="dist.noindex/FocusDesk-macOS.dmg"

./scripts/make-dmg.command

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) no está instalado. Sube $dmg manualmente al release $tag."
  exit 1
fi

echo "Publicando release $tag en GitHub..."
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$dmg" --clobber
else
  gh release create "$tag" "$dmg" \
    --title "FocusDesk $tag" \
    --generate-notes
fi

echo "Release $tag publicado con $dmg"
