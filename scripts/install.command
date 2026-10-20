#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if [[ ! -d dist/FocusDesk.app ]]; then ./build.command; fi
if pgrep -x FocusDesk >/dev/null; then
  echo 'Cierra FocusDesk con Comando+Q antes de instalar la nueva versión.'
  exit 1
fi
install_root="$HOME/Applications"
mkdir -p "$install_root"
target="$install_root/FocusDesk.app"
if [[ -d "$target" ]]; then
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")" != 'local.focusdesk.app' ]]; then
    echo 'La aplicación existente no es FocusDesk; no se ha modificado.'
    exit 1
  fi
  mkdir -p "$PWD/.build/installed-backups"
  backup="$PWD/.build/installed-backups/FocusDesk-previous-$(date +%Y%m%d-%H%M%S).app"
  mv "$target" "$backup"
fi
ditto dist/FocusDesk.app "$target"
codesign --verify --deep --strict "$target"
open "$target" --args "$@"
echo "Instalada: $target"
