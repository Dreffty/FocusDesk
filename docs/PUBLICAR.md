# Publicar FocusDesk (macOS y Windows)

Identificador público de la app en macOS: `com.articdia.focusdesk`.

> Tu copia personal de FocusDesk vive separada en la carpeta hermana `FocusDesk Personal` con el identificador `local.focusdesk.app` y tu regla obligatoria de LoL intacta.

---

## 1. Conectar tu certificado «Developer ID Application» (cuando llegue el correo de Apple)

1. Abre **Xcode › Settings… (Ajustes) › Accounts**.
2. Selecciona tu Apple ID de pago y pulsa **Manage Certificates…**.
3. Pulsa **+** y elige **Developer ID Application** (NO «Apple Development», que solo sirve para tu propio Mac).
4. Comprueba en Terminal que ya aparece en el llavero:
   ```zsh
   security find-identity -v -p codesigning
   ```
   Deberías ver una línea con `"Developer ID Application: Tu Nombre (TEAM_ID)"`.

---

## 2. Guardar una sola vez las credenciales de notarización

1. Crea una contraseña específica para apps en <https://account.apple.com> (Inicio de sesión y seguridad › Contraseñas de aplicación).
2. Guarda el perfil en el llavero de tu Mac una única vez:
   ```zsh
   xcrun notarytool store-credentials "FocusDeskNotary" \
     --apple-id "tu-correo@ejemplo.com" \
     --team-id "M4GZ37V5M2" \
     --password "xxxx-xxxx-xxxx-xxxx"
   ```

---

## 3. Compilar, notarizar y crear el `.dmg`

Ejecuta:

```zsh
NOTARY_PROFILE=FocusDeskNotary ./scripts/make-dmg.command
```

El script realiza automáticamente todo el flujo:
1. Ejecuta `swift test`.
2. Compila en Release y firma `dist.noindex/FocusDesk.app` con `Developer ID Application`, `--options runtime` (Hardened Runtime) y `Resources/FocusDesk.entitlements`.
3. Ejecuta el smoke test integrado (`--preview --smoke-test`).
4. Crea `dist.noindex/FocusDesk-macOS.dmg` con enlace a `/Applications`.
5. Firma el `.dmg`, lo envía a `notarytool --wait`, grapa el ticket con `stapler staple` y muestra el hash `SHA-256`.

---

## 4. Publicar en GitHub Releases (Mac + Windows)

### Opción A: Automático con GitHub Actions (recomendado)
Al subir un tag `v1.0.0` a GitHub, `.github/workflows/release.yml` compila:
- `FocusDesk-macOS.dmg` (en `macos-15`)
- `FocusDesk-Windows-x64.exe` (en `windows-latest`, binario único autocontenido .NET 8)

y publica ambos en el Release. Si añades los secrets `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` y `APPLE_APP_PASSWORD` al repositorio, el workflow también firma y notariza la app de Mac en la nube.

### Opción B: Manual desde tu Mac
```zsh
./scripts/release.command 1.0.0
```

---

## 5. Homebrew Tap

La fórmula está preparada en `Casks/focusdesk.rb`. Cuando publiques el `.dmg` en GitHub Releases:
1. Actualiza `sha256` en `Casks/focusdesk.rb` con el valor impreso por `make-dmg.command`.
2. Copia `Casks/focusdesk.rb` a tu repositorio `articdia/homebrew-tap` para que cualquiera pueda instalarla con:
   ```zsh
   brew install --cask articdia/tap/focusdesk
   ```
