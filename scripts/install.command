#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

# 1. Avoid installing a stale dist.noindex/FocusDesk.app by checking source modification times.
binary="dist.noindex/FocusDesk.app/Contents/MacOS/FocusDesk"
if [[ ! -x "$binary" ]] || [[ -n "$(find Sources Package.swift Resources -newer "$binary" 2>/dev/null)" ]]; then
  echo "Compilando versión actualizada antes de instalar…"
  ./build.command
fi

# 2. Verify candidate bundle before touching ~/Applications/FocusDesk.app
echo "Verificando firma, plist y prueba integrada del nuevo bundle…"
plutil -lint dist.noindex/FocusDesk.app/Contents/Info.plist >/dev/null
codesign --verify --deep --strict dist.noindex/FocusDesk.app
if [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' dist.noindex/FocusDesk.app/Contents/Info.plist)" != 'local.focusdesk.app' ]]; then
  echo "Error: CFBundleIdentifier inesperado en dist.noindex/FocusDesk.app."
  exit 1
fi

smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/focusdesk-install-verify.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT
smoke_out="$("$binary" --preview --preview-directory "$smoke_dir" --smoke-test)"
if [[ "$smoke_out" != PASS* ]]; then
  echo "Error: la verificación previa falló ($smoke_out). No se ha modificado la instalación actual."
  exit 1
fi

if pgrep -x FocusDesk >/dev/null; then
  echo 'Cierra FocusDesk con Comando+Q antes de instalar la nueva versión.'
  exit 1
fi

# Install where it already lives; otherwise /Applications, which is the Aplicaciones folder people actually
# look in (and Spotlight finds). ~/Applications is the fallback when /Applications is not writable.
if [[ -d "/Applications/FocusDesk.app" ]]; then
  install_root="/Applications"
elif [[ -d "$HOME/Applications/FocusDesk.app" ]]; then
  install_root="$HOME/Applications"
elif [[ -w "/Applications" ]]; then
  install_root="/Applications"
else
  install_root="$HOME/Applications"
fi
mkdir -p "$install_root"
target="$install_root/FocusDesk.app"
backup=""

# Two copies in the two Aplicaciones folders is how you end up running yesterday's build without noticing.
for other in "/Applications/FocusDesk.app" "$HOME/Applications/FocusDesk.app"; do
  if [[ "$other" != "$target" && -d "$other" ]]; then
    echo "Quitando la copia duplicada de $other"
    rm -rf "$other"
  fi
done

if [[ -d "$target" ]]; then
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)" != 'local.focusdesk.app' ]]; then
    echo 'La aplicación existente no es FocusDesk; no se ha modificado.'
    exit 1
  fi
  if codesign -dvvv "$target" 2>&1 | grep -q "Signature=adhoc"; then
    tccutil reset Calendar local.focusdesk.app 2>/dev/null || true
  fi
  mkdir -p "$PWD/.build/installed-backups"
  backup="$PWD/.build/installed-backups/FocusDesk-previous-$(date +%Y%m%d-%H%M%S).app"
  mv "$target" "$backup"
fi

# 3. Install and verify target; roll back automatically to previous backup if anything fails.
rollback() {
  echo "Error durante la instalación; restaurando la versión anterior…"
  rm -rf "$target"
  if [[ -n "$backup" && -d "$backup" ]]; then
    mv "$backup" "$target"
    echo "Versión anterior restaurada en $target"
  fi
}

if ! (ditto dist.noindex/FocusDesk.app "$target" && codesign --verify --deep --strict "$target"); then
  rollback
  exit 1
fi

# Without this the freshly installed bundle can stay invisible to Spotlight for a while.
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$lsregister" -f "$target" 2>/dev/null || true
mdimport "$target" 2>/dev/null || true

# One FocusDesk, not one per install: keep only the version just replaced, for going back, and tell macOS to
# forget it and the build copy so neither shows up in «Abrir con…» as another FocusDesk.
if [[ -n "$backup" && -d "$backup" ]]; then
  "$lsregister" -u "$backup" 2>/dev/null || true
  for old in "$PWD"/.build/installed-backups/FocusDesk-previous-*.app(N); do
    if [[ "$old" != "$backup" ]]; then
      "$lsregister" -u "$old" 2>/dev/null || true
      rm -rf "$old"
    fi
  done
fi
"$lsregister" -u "$PWD/dist.noindex/FocusDesk.app" 2>/dev/null || true

if [[ "${1:-}" != "--no-open" ]]; then
  open "$target" --args "$@"
fi
echo "Instalada y verificada: $target"
