# FocusDesk — Guía para agentes y colaboradores

FocusDesk es una aplicación nativa de agenda, bloqueo de distracciones y reglas «primero estudio, luego partida» para **macOS** (`Sources/`) y **Windows** (`windows/FocusDesk.Windows/`).

## Estructura del código

- `Sources/FocusCore/`: núcleo puro de macOS en Swift sin UI ni dependencias de AppKit. Toda regla de negocio, persistencia, trinquete y detector puro vive aquí y debe tener tests en `Tests/FocusCoreTests/`.
  - `Models.swift`: `Workspace`, `FocusTask`, `FocusProfile`, `WorkSession`, `SessionRecord`, `Settings`, `FocusRules`.
  - `Enforcement.swift`: `GeneralBlockRule`, trinquetes (`loosening`), `UnlockChallenge`, `DistractionPunisher`, `StudyActivityVerifier`, `ClipboardGuardRules`, `LeagueMatchRules`.
  - `Games.swift`: `GameCatalog`, `GameMatchDetection` (`.exactLeague`, `.exactValveGSI`, `.timed`), `TimedMatchPlanner`, `ValveGSI`.
  - `Store.swift`: `WorkspaceStore` (guardado atómico + `.history.json` + copias rodantes + copias diarias).
  - `Planning.swift`: diseño de bloques en agenda y proyección a Calendario.
  - `Preferences.swift`: `AppPreferences` (separa preferencias de `--preview`).
- `Sources/FocusDesk/`: interfaz SwiftUI/AppKit de macOS e integración con el sistema.
  - `AppModel.swift`, `AppModel+Enforcement.swift`, `AppModel+Games.swift` (incluye `ValveGSIServer` en `127.0.0.1:47923`).
  - `Guardian.swift`: testigo en Llavero (`KeychainWitness`), `AccessibilityProbe`, `SystemSettingsGuard`, `RelaunchGuard` y modo `--watcher`.
  - `Views.swift`, `ProtectionPages.swift`, `GameViews.swift`, `Editors.swift`.
- `windows/FocusDesk.Windows/`: versión completa de Windows en C# / .NET 8 WPF con el mismo esquema de `workspace.json` (`%APPDATA%\FocusDesk\workspace.json`) y los 4 detectores (`exactLeague`, `exactValorant`, `exactValveGSI`, `timed`).

## Invariantes que no se deben romper

1. **Los trinquetes nunca aflojan una regla/sesión protegida activa**: cualquier ampliación de código o cambio en `GeneralBlockRule` / `WorkSession` debe pasar `GeneralBlockRule.loosening` y `FocusRules.ratchet`.
2. **La versión pública arranca vacía y todo se puede borrar**: `GeneralBlockRule.defaults` y `Workspace.init(from:)` no deben insertar reglas obligatorias ni imborrables (`canBeDeleted == true`). Las reglas de juego se crean desde las plantillas de `GameCatalog.all`.
3. **Reloj resistente a cambios de hora**: las cuentas atrás críticas usan `TrustedDeadline` (hora del sistema + reloj monotónico tras reinicio).
4. **Identificador público de macOS**: `com.articdia.focusdesk`. No reintroducir `local.focusdesk.app` como identificador principal.
5. **Compatibilidad de datos**: cualquier campo nuevo en `Codable` debe usar `decodeIfPresent` con valor por defecto para no romper archivos existentes.

## Cómo añadir un juego nuevo

1. Añade una ficha en `GameCatalog.all` en `Sources/FocusCore/Games.swift` y en `windows/FocusDesk.Windows/Core/Games.cs`.
2. Añade un caso en `testCatalogRecognisesEachGame` en `Tests/FocusCoreTests/GameTests.swift`.
3. Documenta si usa detección exacta o por tiempo en `docs/JUEGOS.md`.

## Comandos de verificación

- Tests unitarios (macOS): `swift test`
- Compilar app macOS: `./build.command`
- Generar `.dmg` firmado y ejecutar `--smoke-test`: `./scripts/make-dmg.command`
- Compilar Windows (en Windows o CI): `dotnet publish windows/FocusDesk.Windows/FocusDesk.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true`

## GentleMerge

Al trabajar en este repositorio, consulta `.gentlemerge/HANDOFF.md` (`gentlemerge brief`), reclama los archivos que vayas a editar (`gentlemerge claim`) y libéralos al terminar (`gentlemerge release`).
