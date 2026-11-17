# Auditoría FocusDesk Windows vs Mac (17-nov-2026)

Revisión hecha **leyendo el código de las dos versiones** (Swift de `Sources/` frente a C# de `windows/`). No se ha podido
ejecutar nada de Windows: aquí no hay .NET ni un Windows. Cada hallazgo dice cómo de seguro es:

- **Confirmado**: lo he visto en el código de las dos versiones y no depende de cómo se comporte Windows.
- **Por probar en Windows**: el código lo sugiere, pero depende de un comportamiento del sistema que no he podido ejecutar.

Mac es la referencia. «Mac hace…» significa lo que hace el código de Mac hoy.

## Estado de los arreglos

Los 8 graves (W-01 a W-08) están **corregidos en el código, sin compilar ni probar en Windows** (aquí no hay .NET). Hay que
compilar y pasar el `--smoke-test` en un Windows o en el CI antes de fiarse. Además se han tocado, de paso:
W-09 (hora de verano: `FocusRules.FromLocal` y `NextOccurrence`), W-22 (importar guarda antes una copia de lo actual),
y una parte de «Huecos»: lista de **Atrasadas** en «Hoy», repeticiones dibujadas en «Semana» y botón **Recuperar copia automática** en Ajustes.

| ID | Qué se hizo |
|---|---|
| W-01 | La carga lee elemento a elemento (`LossyListConverter`); si no se puede leer el archivo entero, la app queda **en solo lectura**, guarda una copia del original en `backups/` y no escribe encima. Un fallo en el resto del arranque ya no tira datos cargados. |
| W-02 | `FocusRules.OwnProcessName` (nombre real del proceso) entra en las listas de exentos y de «nunca cerrar»; además se comparan PID (`IsOwnProcess`) al observar, minimizar/cerrar y matar. |
| W-03 | `RecoverAfterUncleanExit` ya no suma el tiempo cerrado; el apagado de Windows hace `Checkpoint` antes de guardar. Test del CI reescrito. |
| W-04 | `SystemEvents.SessionSwitch` y `PowerModeChanged` pausan la sesión (sin código); protegida: se reanuda sola al desbloquear. Respaldo por hueco de reloj (≥ 90 s) para suspensión «moderna». |
| W-05 | Procesos por nombre exacto (o nombre + `.`/`-`/`_`), `«cod»` ya no casa con `code`; el título de ventana solo cuenta para `javaw`/`java`. |
| W-06 | `Tick` mueve `SelectedDate` al día nuevo si estabas en el que acaba. |
| W-07 | `SeriesRoller` (port de Mac) al abrir, a medianoche y al confirmar/cancelar; `UpcomingOccurrences` para «Semana»; selector de días en «Días concretos»; error propio si no hay ningún día. |
| W-08 | «Activar Nm» e «Iniciar Pomodoro» pasan por `RestartLoosening` (el mismo trinquete que editar la regla) y piden código si acortan; el interruptor «Activar» ahora también arranca la cuenta atrás/Pomodoro como en Mac. |

Segunda tanda (también hecha, también sin compilar): W-10 a W-30 y los huecos de la sección 3, salvo **No molestar** (Windows no
permite activarlo desde una app) y la cuadrícula de horas con arrastrar y soltar (la agenda de Windows es una lista por día y semana con botones
«Mañana», «Bandeja» y «Programar hoy»). El calendario de Apple se sustituye por exportar un archivo `.ics`.
---

## 1. Lo grave (arreglar primero)

### W-01 · Un solo campo ilegible borra TODOS los datos · Confirmado
- **Windows**: `Core/AppEngine.cs:127-131` y `Core/Store.cs:56-76`. Si `workspace.json` no se puede leer entero (un valor de enumerado
  desconocido, un número donde va texto, un archivo de una versión futura), el constructor crea un `Workspace` vacío y
  el guardado automático de cada minuto (`AppEngine.cs:398-401`) **escribe encima del archivo bueno** y de su copia rodante.
- **Mac hace**: lee tarea a tarea (`LossyArray`, `Models.swift:1488`), se salta lo roto y guarda una copia `lectura-parcial`; si
  falla del todo se queda en solo lectura (`writable = false`) y conserva el archivo intacto.
- **Arreglo**: modo solo lectura cuando falla la carga + copia del original antes de tocar nada + lectura tolerante por elemento.

### W-02 · FocusDesk no se reconoce a sí mismo con el nombre del .exe que se descarga · Confirmado
- **Windows**: `Core/Models.cs:1156-1169` exime y protege solo el proceso llamado `focusdesk`. La release publica el archivo como
  `FocusDesk-Windows-x64.exe` (`release.yml`, paso «Copy-Item»), y en Windows el nombre del proceso es el del archivo. Con ese
  nombre, FocusDesk **no está exento de sí mismo**.
- **Efecto**: en una sesión «solo estas apps», la propia ventana de FocusDesk y sus diálogos de código se tratan como
  distracción. Con «Cerrar ventana» se cierra el diálogo de desbloqueo; con «Forzar cierre» FocusDesk se mata a sí mismo
  (`WindowsPlatform.cs:189-199`).
- **Mac hace**: se compara por identificador y por PID (`AppModel+Enforcement.swift:558`), nunca por el nombre del archivo.
- **Arreglo**: comparar con `Environment.ProcessId` y con la ruta del .exe actual, no con el texto «focusdesk».

### W-03 · El tiempo con FocusDesk cerrado cuenta como trabajado · Confirmado
- **Windows**: `Core/Models.cs:729-741` (`RecoverAfterUncleanExit`): al abrir tras un cierre brusco o un apagado suma
  `ahora − RunningSince` a lo trabajado (limitado a lo que queda). `RunningSince` es el último punto guardado (≤15 s antes del cierre),
  así que se acredita **todo** el rato que la app estuvo cerrada. El apagado normal de Windows también pasa por aquí
  (`App.xaml.cs:66-80` no pausa la sesión).
- **Efecto**: empiezas 2 h de estudio, apagas el PC, y al día siguiente la sesión figura como hecha. Eso desbloquea juegos en las
  reglas «primero estudio» que cuentan sesiones (`EffectiveWorkedSeconds`, `AppEngine.cs:256-268`).
- **Mac hace**: al cargar pone `runningSince = nil` y solo cuenta lo guardado en el último punto (`AppModel.swift:250`).
- **Ojo**: el test del CI (`SmokeCheck.cs:135-163`) comprueba justo esto con un `RunningSince` falso de hace 25 min, así que
  pasa y no avisa. Hay que reescribirlo.

### W-04 · La sesión no se pausa al bloquear la pantalla ni al suspender · Confirmado (bloqueo) / Por probar (suspensión)
- **Windows**: no hay ningún manejador de bloqueo, suspensión o cambio de usuario (búsqueda de `SessionSwitch`,
  `PowerModeChanged`, `SystemEvents` sin resultados). Con Win+L la cuenta atrás sigue; en suspensión, `TickCount64` probablemente
  también cuenta el rato dormido.
- **Mac hace**: `pauseForSystem()` al dormir, bloquear o cambiar de usuario, y ofrece reanudar (una sesión protegida se reanuda sola sin contar ese rato).

### W-05 · Juegos: el detector mata programas que no son el juego · Confirmado
- **Windows**: `Core/Games.cs:157` (Warzone usa `"cod"`) y `:75` (`proc.Contains(p)`): `Code.exe` (VS Code) contiene «cod». Además `:83`
  compara el **título de la ventana** («minecraft»), y `AppEngine.cs:1084` y `:564` se lo pasan a todas las apps. Con la regla
  de Warzone o Minecraft **bloqueando**, VS Code, o Chrome con una pestaña «Minecraft – Wikipedia», se cierra con
  `Kill(entireProcessTree)` (`WindowsActivity.TerminateProcesses`).
- **Mac hace**: compara identificador de app, nombre de la app y ruta; nunca el título de una ventana, y no usa «cod» suelto.
- **Arreglo**: coincidencia exacta de proceso (no `Contains`), quitar `"cod"`, y usar el título solo para `javaw`/`java` y nunca para navegadores.

### W-06 · «Hoy» se queda congelado en el día en que arrancó la app · Confirmado
- **Windows**: `AppEngine.SelectedDate` se pone al crear el motor y no se vuelve a tocar (solo se lee en `MainWindow.xaml.cs:379,492,576`).
  La app vive en la bandeja días enteros: a medianoche «Hoy» y «Semana» siguen enseñando el día de arranque.
- **Mac hace**: en `tick()` pasa `selectedDate` al día nuevo si estabas en el que acaba (`AppModel.swift:1998`); es un fallo que ya corrigieron.

### W-07 · Las tareas repetidas no se repiten solas, y «Días concretos» no se puede guardar · Confirmado
- **Windows**: la siguiente repetición solo se crea al marcar «Completada» (`AppEngine.cs:1432`). No existen las repeticiones proyectadas
  (`upcomingOccurrences`), ni `rollMissedSeries` (avanzar una serie atrasada), ni «solo esta ocurrencia». Si un día no la
  completas, la serie se queda en el pasado y desaparece de «Hoy» y de «Semana».
- «Días concretos» está en el desplegable (`Dialogs.cs:609`) pero **no hay selector de días**: `Valid` exige días (`Models.cs:464`), así
  que nunca se guarda y el error que sale habla de «objetivos de bloqueo».
- **Mac hace**: proyecta las repeticiones en la agenda, las avanza al abrir y a medianoche (`AppModel.swift:1181`), y tiene editor de días.

### W-08 · «Activar Nm» y «Iniciar Pomodoro» pueden acortar un bloqueo protegido sin pedir código · Confirmado
- **Windows**: `UI/MainWindow.xaml.cs:644` y `:650` llaman a `StartPomodoro()` / `StartCountdown()` directamente. Con una cuenta atrás
  activa de 3 h y «Activar 60m», queda 1 h. Sin código, sin trinquete.
- **Mac hace**: todo cambio de regla pasa por `passesGeneralRuleGate(.save(copy))` (`AppModel+Enforcement.swift:1841-1883`), y activar una cuenta
  atrás solo la reinicia si no quedaba tiempo.

---

## 2. Importante (rompe cosas o se aparta de Mac, sin llegar a pérdida de datos)

| ID | Qué | Dónde (Windows) | Qué hace Mac | Seguridad |
|---|---|---|---|---|
| W-09 | **Cambio de hora (CET/CEST)**: una tarea repetida cambia de hora local (09:00 → 08:00) porque `AddDays` conserva el desfase fijo; y el editor guarda cualquier fecha con el desfase de **hoy** (tras el 28-mar-2027 saldrían 1 h corridas). | `Models.cs:522-573`, `Dialogs.cs:804` | `Calendar.date(byAdding:)`: la hora de reloj no cambia | Confirmado |
| W-10 | **Sin válvula del modo estricto**: en «solo estas apps» sin ninguna abierta, a cada app que enfocas se le aplica Minimizar/Cerrar/**Forzar cierre** sin límite (riesgo de perder trabajo sin guardar). | `AppEngine.cs:996-1012` | `StrictRedirectTracker`: abre una app permitida, y a los 3 fallos pausa (sin protección) | Confirmado |
| W-11 | **Lee la barra de direcciones del navegador siempre**, aunque no haya sesión ni reglas (activa la accesibilidad de Chrome: más RAM y CPU). | `AppEngine.cs:967-994` | No hace nada si no hay sesión ni reglas (`observe()`, `guard activeSession != nil \|\| hasEnabledRules`) | Confirmado |
| W-12 | **Apps de la Tienda (UWP)** nunca se bloquean: `applicationframehost` está exento (Netflix, Prime, Xbox…). | `Models.cs:1158-1161` | n/a | Por probar |
| W-13 | **Guardia de «Configuración»**: el título de la ventana de Configuración no cambia por página, así que casi seguro no detecta «Hora», «Privacidad»…; y a la vez cierra cualquier ventana UWP cuyo título contenga «apps», «time», «date», «hora», «inicio». | `WindowsPlatform.cs:488-513` | Mira la fila seleccionada por Accesibilidad | Por probar |
| W-14 | **Vigilante de relanzado**: «instalado» solo mira que la clave no esté vacía; si mueves o actualizas el .exe, el arranque con Windows sigue apuntando a la ruta vieja y la pantalla dice «Vigilante: activo». | `WindowsPlatform.cs:645-653` | `RelaunchGuardPlan.isInstalledLocation` | Confirmado |
| W-15 | **Cerrar pestaña** con `SendKeys ^w`: si cambias de pestaña entre que se lee la web y se actúa, cierra otra. | `WindowsPlatform.cs:377,395` | AppleScript por pestaña concreta | Confirmado |
| W-16 | **Castigo (punisher)**: Windows endurece al **3.er** intento y con ventana fija; Mac al **4.º** con ventana deslizante de 3 min. | `Models.cs:619-647` | `Enforcement.swift:878-926` | Confirmado |
| W-17 | **Bloqueo de imágenes/vídeos en buscadores** mucho más flojo: faltan Google `/images` `/videohp` `/videos`, Brave Search, Ecosia, Yandex, Yahoo vídeos, Bing `ia=images`. | `Enforcement.cs:164-194` | `Enforcement.swift:1183-1231` | Confirmado |
| W-18 | **Tiempo restante de una regla «por horario»** sale como «hasta medianoche» (no hay rama `schedule` ni «por hora»). Se ve en la página de bloqueo y en los mensajes. | `Enforcement.cs:560-576` | `Enforcement.swift:2576-2649` | Confirmado |
| W-19 | **Espera para parar**: no existe `StopRequest` persistente ni la ventana de confirmación de 3 min; la espera es un diálogo que no sobrevive a cerrar la app. | `Dialogs.cs:387-450`, `Models.cs:594-617` (sin uso) | `Enforcement.swift:654-705` | Confirmado |
| W-20 | **Reinicio del PC** no se detecta bien: sin identificador de arranque (`bootID`); además el «Inicio rápido» de Windows no reinicia `TickCount64`. | `Models.cs:187-234` | `kern.bootsessionuuid` | Confirmado (diseño) / Por probar (Inicio rápido) |
| W-21 | **El testigo no protege**: solo anota una nota de auditoría. Si borras o editas `workspace.json` con la app cerrada, la regla protegida se pierde. | `AppEngine.cs:181-197` | Restaura las reglas protegidas desde el Llavero (`checkWitnessAtLaunch`) | Confirmado |
| W-22 | **Importar copia** pisa los datos sin guardar antes los actuales, y pide el código en vez de negarse. | `AppEngine.cs:1546-1555`, `MainWindow.xaml.cs:977` | `restoreBackup` hace copia previa y se niega mientras hay algo protegido | Confirmado |
| W-23 | **Perfiles por defecto** con protección «Código», redirección de webs y bloqueo de juegos ya puestos; Mac los trae vacíos (invariante de AGENTS.md: la versión pública arranca vacía). | `Models.cs:309-356` | `Models.swift:155-189` | Confirmado |
| W-24 | **Modo de lista por defecto invertido**: tareas, perfiles y reglas nuevas nacen como «bloquear las de la lista» en Windows y «permitir solo las de la lista» en Mac (campo ausente en un JSON = lectura contraria). | `Models.cs:299-300,395-396` | `Models.swift:144-145` | Confirmado |
| W-25 | **Marcar apps → modo estricto forzado**: escribir apps en el editor activa «estricto» aunque lo hayas desmarcado. | `Dialogs.cs:829` | El interruptor manda | Confirmado |
| W-26 | **URL de redirección sin `https://`** (p. ej. `notion.so`): Windows la ignora y usa la página local; Mac la normaliza. | `AppEngine.cs:1205`, `Models.cs:1383-1394` | `WebRules.normalizedRedirectURL` | Confirmado |
| W-27 | **«Hasta el final»** en Windows deja salir de cualquier cosa (pausar, terminar, borrar, apagar) con el código de 60 caracteres; Mac solo con el botón «Emergencia» de la sesión. | `Dialogs.cs:253-390` | `StopGate.decide` → `.refused` | Confirmado (diseño) |
| W-28 | **Valores por defecto de ajustes distintos**: portapapeles protegido y vigilante activados de fábrica en Windows (Mac los trae apagados). | `Models.cs:978,994` | `Models.swift:1380,1391` | Confirmado |
| W-29 | **Palabras bloqueadas** sensibles a tildes en Windows; Mac ignora mayúsculas y tildes. `AppAllowed` por subcadena («code» permite «codeblocks»). Una URL pegada con `https://sitio/ruta` conserva la ruta en Windows y solo el dominio en Mac. | `Models.cs:1214-1275,1435-1500` | `Models.swift:1854-2120` | Confirmado |
| W-30 | **Lista inicial de reglas** sin «X y Reddit» (la de límite de aperturas) y sin palabras de título en dos de ellas. | `Enforcement.cs:818-869` | `Enforcement.swift:2872-2950` | Confirmado |

---

## 3. Funciones que Mac tiene y Windows no (huecos, no fallos)

Calendario (Apple Calendar/EventKit) · bandeja con arrastrar y soltar · agenda con cuadrícula de día y semana · deshacer/rehacer ·
captura rápida · paleta ⌘K · panel compacto · **editor de perfiles** (hay `SaveProfile` pero ninguna pantalla que lo use) ·
categorías · **descansos programados** (la página «Descansos» solo los enseña: `EnforceBreaks` no se lee en ningún sitio) ·
**avisos de 5 y 1 min** antes del límite (`PreBlockRemindersEnabled` sin uso) · **posponer el descanso continuo** (hay contador de saltos, sin botón) ·
excepciones temporales (`TemporaryAllows` sin pantalla) · carpeta de resultado y archivos cambiados · **checklist visible y marcable en la
sesión** (solo se escribe, nunca se enseña ni se marca) · reabrir una sesión terminada por error · «Empezar la siguiente» y «Descansar 10 min» al confirmar ·
atajos configurables · texto grande · cuenta atrás en la barra de menús · No molestar · mantener el equipo despierto · aviso «Vuelve a tu tarea» ·
horario laboral, día de reinicio y margen previo (`RunUp`) editables · historial con búsqueda, filtros, borrar, exportar · restaurar copia
automática o diaria desde la app · saltar fase de Pomodoro, «terminar visita», reiniciar cuota · bloqueo de webs en navegadores en segundo plano / segundo monitor.

---

## 4. Detalles menores

- `StartDueAutoStartTasks` no comprueba pantalla bloqueada y marca la tarea como «ya lanzada» aunque `StartSession` falle (`AppEngine.cs:433-441`).
- `StartSession` no comprueba `Valid` ni `Completed`; lanzar un perfil inválido arranca la sesión aunque `SaveTask` lo rechace (`MainWindow.xaml.cs:787-794`).
- Editar una regla con el diálogo abierto puede pisar estado vivo (fase de Pomodoro, micro-pausa) con la copia de cuando se abrió (`Dialogs.cs:896-899,1509`).
- `RunningProcesses()` llama a `MainWindowHandle` de todos los procesos cada ~1,2 s con una regla de LoL activa: coste de CPU (`WindowsPlatform.cs:210-240`).
- «Activar» una regla de cuenta atrás o de Pomodoro desde el interruptor no la arranca (Mac sí); hace falta el otro botón.
- `NextOccurrence` diaria/semanal empieza siempre en el paso 1 y se rinde a los 400: una serie muy atrasada muere (`Models.cs:550-559`).
- `NextSuggestedTask` simplificado: ignora las tareas sin hora y la ventana «de −2 h a +90 min» (`Models.cs:1560-1566`).
- Sin recortes de rango al leer el JSON (Mac limita minutos, ciclos, etc. al decodificar).
- `ObserveForeground` crea una fila nueva de actividad por cada cambio de título en un navegador (Mac lo arregló con FD-07).
- Un solo `bloqueada.html` compartido para todas las páginas de bloqueo.

---

## 5. Qué NO he cubierto (y cómo cubrirlo)

- **No he ejecutado nada de Windows.** Los marcados «Por probar» necesitan un Windows 10/11 real.
- **No he leído línea a línea** la interfaz de Mac (`Views`, `Editors`, `ProtectionPages`: unas 9.000 líneas) ni `MainWindow.xaml`. Para la interfaz de Mac
  he sacado la lista de botones y controles y la he contrastado con lo que tiene Windows; puede haber matices de diseño que no aparecen aquí.
- **«Todas las combinaciones» no se puede cerrar leyendo.** Para eso hay que ejecutar. Lo más barato y fiable: llevar a C# los tests de
  `Tests/FocusCoreTests` (21 ficheros en Mac frente a 280 líneas de `SmokeCheck.cs` en Windows) usando **los mismos casos de entrada y salida**
  en un JSON compartido, y correrlos en el CI de Windows en cada commit (hoy el CI de Windows solo corre al publicar una versión con etiqueta).
- Calendario, Planning y el cuaderno de sincronización no aplican a Windows y no los he comparado.
