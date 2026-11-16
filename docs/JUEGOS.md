# Reglas de juego: «primero estudio, luego partida»

Una regla de juego es una regla de tipo «Primero el trabajo» con un juego elegido. El estudio desbloquea partidas
(por defecto, 60 min de estudio por partida y 2 partidas al día) y FocusDesk nunca saca a nadie a mitad de partida.

## Cómo sabe FocusDesk cuándo acaba una partida

| Detección | Juegos | Cómo funciona |
|---|---|---|
| Exacta (Riot) | League of Legends | Riot abre un programa aparte (`GameClient` / `League of Legends.exe`) solo mientras dura la partida. Al cerrarse, la partida cuenta y se da 1 minuto de margen. |
| Exacta (Valorant, Windows) | Valorant | El cliente local de Riot (`lockfile` + `/chat/v4/presences`) indica si estás en `MENUS` o `INGAME`/`PREGAME`. |
| Exacta (Valve GSI) | Counter-Strike 2, Dota 2 | Game State Integration: FocusDesk instala `gamestate_integration_focusdesk.cfg` en Steam y recibe los estados del mapa en `127.0.0.1:47923` (con respaldo por tiempo si no hay eventos). |
| Por tiempo con prórroga | Fortnite, Warzone, Minecraft, Roblox, WoW, Cualquier juego, Otro juego | La partida empieza al abrir el juego, dura su tiempo típico y luego hay una prórroga (10 min por defecto). Al acabar la prórroga se cierra el juego. «He terminado», o cerrar el juego durante 2 minutos tras jugar al menos 5, la acaban antes. |

El código está en `Sources/FocusCore/Games.swift` (catálogo y decisiones, con tests en
`Tests/FocusCoreTests/GameTests.swift`), `Sources/FocusDesk/AppModel+Games.swift` (macOS) y `windows/FocusDesk.Windows/Core/Games.cs` (Windows).

## Añadir un juego

Añade una ficha a `GameCatalog.all` en `Sources/FocusCore/Games.swift` (y su equivalente en `windows/FocusDesk.Windows/Core/Games.cs`):

```swift
GameDefinition(
    id: "hearthstone",                 // único, en minúsculas
    name: "Hearthstone",
    icon: "rectangle.stack.fill",      // un símbolo de SF Symbols
    detection: .timed,
    typicalMatchMinutes: 15,           // lo que dura una partida normal
    bundleIDPrefixes: ["unity.blizzard entertainment.hearthstone"],
    nameKeywords: ["hearthstone"],     // nombre de la app, en minúsculas
    pathFragments: ["/hearthstone/"],  // trozo de la ruta de la app
    note: "Una línea que se enseña en el editor (opcional)."
)
```

Para saber el identificador de una app instalada en Mac:

```bash
defaults read "/Applications/Nombre.app/Contents/Info" CFBundleIdentifier
```

Después añade una línea al test `testCatalogRecognisesEachGame` comprobando que el juego se reconoce y ejecuta
`swift test`. La plantilla aparece sola en «Reglas › Juegos».
