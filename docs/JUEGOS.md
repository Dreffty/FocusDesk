# Reglas de juego: «primero estudio, luego partida»

Una regla de juego es una regla de tipo «Primero el trabajo» con un juego elegido. El estudio desbloquea partidas
(por defecto, 60 min de estudio por partida y 2 partidas al día) y FocusDesk nunca saca a nadie a mitad de partida.

## Cómo sabe FocusDesk cuándo acaba una partida

| Detección | Juegos | Cómo funciona |
|---|---|---|
| Exacta | League of Legends | Riot abre un programa aparte (`GameClient`) solo mientras dura la partida. Al cerrarse, la partida cuenta y se da 1 minuto de margen. |
| Por tiempo con prórroga | El resto | El juego usa el mismo programa en el menú y en partida. La partida empieza al abrir el juego, dura su tiempo típico y luego hay una prórroga (10 min por defecto). Al acabar la prórroga se cierra el juego. «He terminado», o cerrar el juego durante 2 minutos tras jugar al menos 5, la acaban antes. |

El código está en `Sources/FocusCore/Games.swift` (catálogo y decisiones, con tests en
`Tests/FocusCoreTests/GameTests.swift`) y `Sources/FocusDesk/AppModel+Games.swift` (lo que pasa en el Mac).

## Añadir un juego

Añade una ficha a `GameCatalog.all` en `Sources/FocusCore/Games.swift`:

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

Para saber el identificador de una app instalada:

```bash
defaults read "/Applications/Nombre.app/Contents/Info" CFBundleIdentifier
```

Después añade una línea al test `testCatalogRecognisesEachGame` comprobando que el juego se reconoce y ejecuta
`swift test`. La plantilla aparece sola en «Reglas › Juegos».

## Detector exacto para otro juego

Solo merece la pena si el juego dice desde fuera cuándo está en partida. Candidatos conocidos:

- **Dota 2 y Counter-Strike 2**: Game State Integration de Valve, un fichero en la carpeta `cfg` del juego hace que
  este mande su estado a un servidor local. Pendiente.
- **Valorant** (solo Windows): el cliente de Riot publica en local si estás en el menú o en partida.
