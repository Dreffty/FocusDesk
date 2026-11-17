# FocusDesk para Windows

Versión nativa en C# / .NET 8 WPF con el mismo motor de reglas, estudio verificado y detectores de juego que FocusDesk para macOS.

- **Descarga directa para Windows (10 / 11 x64)**: [**Pulsa aquí para descargar FocusDesk-Windows-x64.exe**](https://github.com/Dreffty/FocusDesk/releases/latest/download/FocusDesk-Windows-x64.exe)

## Requisitos

- Windows 10 o Windows 11 (x64).
- Si descargas el ejecutable publicado ([`FocusDesk-Windows-x64.exe`](https://github.com/Dreffty/FocusDesk/releases/latest/download/FocusDesk-Windows-x64.exe)), **no necesitas instalar .NET ni dependencias adicionales**: guárdalo en una carpeta fija y ábrelo con doble clic.
- Para compilar desde código fuente: [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

## Compilar en Windows

```powershell
dotnet publish windows/FocusDesk.Windows/FocusDesk.Windows.csproj `
  -c Release `
  -r win-x64 `
  --self-contained true `
  -p:PublishSingleFile=true `
  -o dist-win
```

El ejecutable queda en `dist-win\FocusDesk.exe`.

## Detectores de juego incluidos

| Juego | Detección | Cómo funciona |
|---|---|---|
| **League of Legends** | Exacta | Distingue `LeagueClientUx.exe` / `RiotClientServices.exe` del proceso de partida (`League of Legends.exe`), espera a que acabe y da 60 s de margen. |
| **Valorant** | Exacta (Riot local) | Consulta el cliente local de Riot (`%LOCALAPPDATA%\Riot Games\Riot Client\Config\lockfile`, endpoint `/chat/v4/presences`) para distinguir `MENUS` de `INGAME`/`PREGAME`. |
| **Counter-Strike 2 y Dota 2** | Exacta (Valve GSI) | Servidor local en `127.0.0.1:47923` + instalación automática de `gamestate_integration_focusdesk.cfg` en las carpetas `cfg` de Steam (con respaldo por tiempo si no está configurado). |
| **Fortnite, Warzone, Minecraft, Roblox, WoW, Cualquier juego, Otro juego** | Por tiempo con prórroga | Cuenta desde que abres el juego hasta su duración típica, avisa y concede 10 min de prórroga antes de cerrarlo (o antes con «He terminado»). |

## Protección y datos

- Los datos se guardan en `%APPDATA%\FocusDesk\workspace.json`, historial en `workspace.history.json` y copias diarias en `backups\`.
- El testigo antimanipulación se cifra con DPAPI del usuario en `%LOCALAPPDATA%\FocusDesk\witness.dat`.
- El vigilante (`--watcher` en `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`) reabre FocusDesk si se cierra a la fuerza durante una regla o sesión protegida.
- Atajos globales: `Ctrl+Alt+Win+F` (abrir; se puede cambiar o apagar en Ajustes), `Ctrl+Alt+Win+P` (pausar/reanudar), `Ctrl+Alt+Win+T` (terminar).
- Dentro de la ventana: `Ctrl+K` busca cualquier acción, `Ctrl+N` crea una tarea, `Ctrl+Z` / `Ctrl+Y` deshacen y rehacen la agenda.
- La sesión se pausa sola al bloquear la pantalla, suspender o cambiar de usuario (el rato fuera no cuenta); una sesión protegida se reanuda sola al volver.
- Si los datos no se pueden leer, la app arranca en solo lectura y no escribe encima del archivo; en Ajustes puedes recuperar la copia automática.
- «Exportar al calendario (.ics)» en Semana es el equivalente del Calendario de macOS.
