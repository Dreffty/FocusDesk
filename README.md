# FocusDesk

Tu plan del día y el tiempo de cada tarea, accesibles desde la barra de menús de macOS y el Dock.

## Abrir

Abre `/Applications/FocusDesk.app` con doble clic, búscala en Spotlight escribiendo **FocusDesk** (todo junto: «Focus Desk» con espacio no la encuentra) o usa su icono del Dock. La copia compilada también está en `dist/FocusDesk.app`. Cerrar su ventana deja la app funcionando en la barra. El atajo global (**Control + Opción + Comando + F** por defecto, configurable en **Ajustes**, que se abren con `⌘,` en su propia ventana) vuelve a abrir el planificador o el panel compacto. Para cerrarla completamente, usa **Salir** en su menú.

Requiere macOS 14 o posterior. La compilación para Apple Silicon utiliza firma estable local (`Apple Development`) cuando está disponible en el llavero (con respaldo ad-hoc `-`), conservando los permisos de macOS entre recompilaciones.

## Primer uso

1. Pulsa **Nueva tarea** (`⌘N`). Pon un objetivo, elige si tiene horario reservado o va a la **bandeja de pendientes sin hora**, añade opcionalmente una **fecha límite** independiente y define su duración.
2. Aplica uno de los **perfiles reutilizables** (*Grabar vídeo*, *Estudiar*, *Tienda*) o guarda tus propios perfiles con aplicaciones, dominios, modo estricto, duración habitual, checklist y carpeta de resultados.
3. Activa «Bloquear las apps que distraen» si quieres que FocusDesk oculte cualquier app que no esté en la lista y te devuelva a una permitida (si no hay ninguna abierta, la abre). Esas tareas pueden poner además **No molestar** mientras dura la sesión: en **Ajustes → General → No molestar al bloquear apps**, pulsa «Crear los atajos…» y añade en Atajos los dos que te propone (solo la primera vez). Puedes pausar o cancelar en cualquier momento desde la barra o la ventana. Mientras hay una sesión, **⌃⌥⌘P** (pausar o reanudar) y **⌃⌥⌘T** (He terminado) funcionan desde cualquier app, sin traer FocusDesk delante; sin sesión quedan libres para las demás apps.

**Un solo temporizador, siempre.** Si empiezas otra tarea mientras hay una en marcha, FocusDesk pregunta: «Tienes «A» en marcha. ¿La terminas y empiezas «B»?». Al aceptar, detiene la actual, te pide su resultado y arranca la nueva al confirmarlo, así nunca pierdes el tiempo ya trabajado. Empezar la tarea que ya está en marcha simplemente la reanuda si estaba en pausa.

**Si el Mac se duerme o se bloquea**, la sesión se pausa y al volver aparece un aviso que espera respuesta («¿Reanudamos?») y una notificación con acción **Reanudar**; el tiempo que el Mac estuvo bloqueado no cuenta como trabajado. Que solo se apague la pantalla no pausa nada: grabar, leer o estudiar ocurre sin tocar el teclado.
4. Al guardar tu primera tarea con hora, FocusDesk te pide permiso para avisarte (también puedes darlo en **Ajustes**). Si los avisos están desactivados, Hoy te lo dice con un botón para activarlos. Cuando llegue el aviso previo o de inicio, puedes pulsar **Empezar ahora** o **Posponer 10 min** directamente desde la notificación sin buscar la tarea en la ventana. Si el permiso está denegado, Ajustes ofrece un botón directo a la configuración de Notificaciones de macOS.
5. Pulsa **He terminado** (`⌃⌥⌘T`), aunque sobre tiempo. Revisa los archivos detectados, marca cuáles corresponden al resultado real, adjunta archivos manualmente si lo necesitas y elige cómo pasar a la siguiente tarea (**Mantener su horario**, **Empezar la siguiente** o **Descansar 10 min**).

Cerrar la pantalla o el bloqueo del Mac pausan la observación; el reposo de la pantalla por sí solo, no.

## Cuando de verdad no quieres poder escaparte

Cada tarea decide, en **«Si quieres dejarlo a medias»**, cuánto cuesta abandonarla. Lo eliges al planificarla, con la cabeza fría, para el momento en que no la tengas:

- **Se puede parar** — como hasta ahora: pausas, cancelas o terminas cuando quieras.
- **Teclear un código** — para pausar, cancelar o terminar antes de tiempo hay que escribir a mano una cadena aleatoria (24 caracteres por defecto, configurable). No se puede pegar, y cada fallo da un código nuevo. Son los treinta segundos que suele durar el impulso.
- **Esperar unos minutos** — pedir el final arranca una espera; **la sesión sigue corriendo mientras tanto** y puedes cancelarla con un botón. Casi siempre se te pasan las ganas antes de que acabe.
- **Hasta el final** — no hay parada anticipada. Queda la **salida de emergencia**: 60 caracteres y una anotación con la fecha, visible en Ajustes.

Mientras una sesión protegida corre, **también cuesta lo mismo salir de FocusDesk** (⌘Q, el menú o el Dock): salir es la forma más corta de desactivar un bloqueo.

**La ley del trinquete.** Una sesión en marcha se puede endurecer, nunca aflojar: alargarla sí, acortarla no; subir la protección sí, bajarla no; quitar apps permitidas sí, añadirlas no. Si intentas lo segundo, FocusDesk te dice exactamente qué campo lo impide en vez de descartar el cambio en silencio.

**Qué se bloquea, y cómo:**

- **Apps** — eliges si FocusDesk la **oculta** (nada se pierde), la **cierra** (como ⌘Q: puede preguntarte si guardas) o **fuerza su cierre** (para juegos y lanzadores que vuelven solos). Hay una lista fija de procesos del sistema —Finder, Dock, Ajustes, Terminal, las herramientas de accesibilidad— que como mucho se ocultan, pase lo que pase.
- **Ventanas en segundo plano** — un vídeo en una esquina o en el segundo monitor distrae aunque escribas en otra ventana. FocusDesk mira todas las ventanas visibles, no solo la que tiene el foco, y las oculta (nunca las cierra).
- **Webs de verdad** — además de avisar, una tarea puede **llevar esa pestaña a una página de bloqueo** (con el tiempo que queda y el nombre de la tarea) o **cerrar solo esa pestaña**. El resto del navegador sigue intacto. Funciona en Safari, Brave, Chrome, Edge, Arc, Vivaldi, Opera y Chromium.
- **Webs disfrazadas de app** — una página instalada como aplicación desde Chrome o Brave se juzga por el sitio que abre, no por su icono.
- **Webs dentro de otras apps** — páginas abiertas en Discord, Slack o Notion. Aquí **solo se avisa**: esas ventanas llevan conversaciones y documentos, y cerrarlas para matar un vídeo sería mal negocio.
- **Los ajustes que desarman el bloqueo** — si abres «Privacidad y seguridad», «Fecha y hora» o «Usuarios y grupos» con una sesión protegida, FocusDesk cierra esa ventana y te explica por qué. El resto de Ajustes del Sistema (Wi-Fi, sonido, pantallas) sigue disponible.

**Si insistes, cuesta más.** Cuatro intentos seguidos en pocos minutos y, durante un rato, FocusDesk cierra esas apps en vez de ocultarlas, y cierra las pestañas en vez de redirigirlas. Se puede desactivar por tarea.

**Trampas que ya no funcionan:**

- **Adelantar el reloj del Mac.** Las cuentas atrás van con un reloj del sistema que no se puede mover a mano; si detecta un salto, lo dice y sigue con el suyo.
- **Borrar o editar el archivo de datos con la app cerrada.** FocusDesk guarda una huella de la sesión protegida en el **Llavero**, fuera de sus datos. Si al abrirse falta esa sesión, te lo dice.
- **Matar el proceso.** En Ajustes → Privacidad puedes activar **«Volver a abrirse si lo matan durante una sesión»**: un elemento de inicio que relanza FocusDesk cuando sale de mala manera.
- **El permiso de Accesibilidad roto.** macOS a veces dice que el permiso está dado y no lo da de verdad. FocusDesk lo comprueba preguntándole al Dock, y si el bloqueo no puede actuar avisa en vez de fingir que protege.

**Hasta dónde llega, con honestidad.** FocusDesk no pide contraseña de administrador ni instala nada con permisos de root. Todo lo anterior vive en tu cuenta de usuario: añade fricción —que es lo que de verdad frena a un impulso— pero quien sepa usar la Terminal puede desmontarlo. No se vende como inviolable, porque no lo es.

Bloquear las apps que distraen oculta la app que no toca, devuelve el foco a una app permitida, vuelve a mirar al momento (los lanzadores y juegos que se ponen delante otra vez se ocultan de nuevo) y registra una sola interrupción por cada episodio continuo fuera del entorno de trabajo (volver a trabajar y salir de nuevo cuenta como otra). Finder, Ajustes del Sistema, FocusDesk, Vorssaint, los avisos y diálogos del sistema y las herramientas de accesibilidad siguen accesibles. Si una app permitida se cierra o falla su activación tras varios intentos, la sesión se pausa automáticamente para evitar bucles y conservar el control. Un navegador permitido puede abrir cualquier web: los dominios se normalizan (aceptando URLs como `https://claude.ai/`), se señalan y registran, pero no se bloquean.

## Teclado, deshacer y apariencia

- **Deshacer y rehacer** (`⌘Z`, `⇧⌘Z`) cualquier cambio de la agenda: mover, alargar, posponer, borrar o editar una tarea. El menú Edición dice qué se va a deshacer.
- **La agenda se maneja sin ratón**: con Hoy delante, las flechas ↑↓ eligen tarea, `↩` la abre, `Espacio` la empieza, `⌥↑`/`⌥↓` la mueven 5 minutos, `⇧⌥↑`/`⇧⌥↓` cambian su duración, `⌫` la borra (pidiendo confirmación) y `Esc` quita la selección. Lo que se puede hacer con la tarea elegida está también en el menú **Tarea** (`⌘E` para editarla), y **Ayuda → Atajos de FocusDesk** los resume todos. `⌘1`, `⌘2` y `⌘3` van a Hoy, Semana e Historial; `⌘[` y `⌘]` pasan al día o a la semana anterior o siguiente, y `⌘T` vuelve a hoy. Con FocusDesk delante, **⌃⌥⌘A** amplía la sesión 10 minutos.
- **Apuntar rápido**: el campo del panel de la barra de menús manda una tarea a la bandeja sin hora con solo escribir y pulsar `↩`, sin abrir la ventana. Doble clic en un hueco vacío de la vista por horas crea una tarea a esa hora.
- **Claro u oscuro**: FocusDesk sigue la apariencia de macOS, y respeta «Aumentar contraste» y «Reducir movimiento».
- **Tamaño del texto**: Ajustes → General → Normal, Grande o Muy grande. Ahí también decides si el contador aparece en la barra de menús.

## Vorssaint y Apple Calendar

En Ajustes, concede acceso a Calendario y selecciona dónde crear o conectar el calendario **FocusDesk**.

En Vorssaint, activa su integración Calendar de Dynamic Island, las cuentas atrás y el tiempo restante, y selecciona FocusDesk. FocusDesk proyecta el inicio y el final previsto; al pausar elimina la proyección activa y al reanudar la recalcula. Al terminar antes, actualiza el final real.

- **Cola persistente de sincronización**: si Calendar falla temporalmente al pausar, terminar, posponer o eliminar una tarea, la operación se guarda en `pendingCalendarOps` con reintentos automáticos limitados y estado visible en la barra lateral y Ajustes hasta verificar que el evento en EventKit refleja el estado real, sin dejar contadores antiguos ni duplicar eventos.
- **Una sola cuenta atrás en la isla**: mientras una sesión está en marcha, FocusDesk retira de Calendar los bloques de las tareas que empezarían antes de que esa sesión termine. Vorssaint muestra el momento elegible más próximo, así que esas tareas le robarían el contador a lo que estás haciendo. Siguen en tu agenda de FocusDesk y vuelven a Calendar en cuanto la sesión acaba o se pausa.
- **Límite conocido de Vorssaint 3.4.1**: la cuenta atrás aparece durante los últimos 60 minutos antes del inicio/final y desaparece al vencer. Este puente no controla su Pomodoro. El contador de FocusDesk sigue disponible en el Dock y la barra, también durante sesiones de 90 minutos y tiempo extra.

## Qué incluye la versión 0.2 beta

- **Agenda personalizable y vista por horas**: categorías y colores propios, días laborables, horario de jornada y bloques de descanso. Vista de día por horas donde puedes arrastrar bloques verticalmente para cambiar su hora, arrastrar su borde inferior para ajustar la duración y ver solapamientos en vivo.
- **Tareas sin horario y fecha límite**: bandeja de pendientes sin hora independiente de la fecha límite (*«Preparar guion, antes del viernes»*), arrastrables al calendario cuando decidas programarlos.
- **Postergación inteligente**: posponer una tarea atrasada o sin hora calcula la nueva hora desde el momento actual (`ahora + 10 min`); posponer una tarea futura desplaza su horario previsto, actualizando su aviso y su evento en Calendar.
- **Repeticiones que no se pierden**: si un día no haces una tarea repetitiva, la serie pasa sola a su siguiente día (al abrir la app o al cambiar de día) y el día perdido queda como una tarea atrasada, una sola por serie. Posponer, arrastrar, alargar o mandar a la bandeja un bloque de una serie cambia solo ese día; para cambiar la serie entera, edítala. Al editar desde un día concreto, el editor propone «solo esta ocurrencia».
- **Repeticiones ampliadas y vista previa**: repetición diaria, semanal, días laborables (L–V) y días concretos (ej. L, X, V). Muestra las próximas ocurrencias en la agenda antes de completar la actual y permite elegir entre editar toda la serie o separar una única ocurrencia.
- **Reloj monotónico de sesión**: la duración trabajada se mide con el reloj monotónico del sistema (`systemUptime`), por lo que cambiar la hora del Mac no añade ni quita minutos de trabajo. Incluye cancelación de sesión diferenciada de tarea completada e incompleta.
- **Reposición automática de avisos**: si un día supera el límite del sistema de 60 avisos pendientes, FocusDesk repone automáticamente los siguientes conforme se consumen los primeros o al despertar del reposo.
- **Evidencias y privacidad**: distinción entre señal automática de carpeta (ignorando temporales y avisando si un archivo se modificó hace menos de 2 s) y archivos confirmados o adjuntados manualmente, con botones para abrir o mostrar en Finder. Historial con búsqueda, filtros por área/estado/fecha, desglose de tiempo de sesión frente a actividad observada por app, borrado de sesiones individuales y lista de aplicaciones excluidas de la lectura de títulos.
- **Respaldo y recuperación de extremo a extremo**: ninguna operación muestra «terminada» o «guardada» si falla la escritura en disco; ofrece reintento en memoria, copia rodante automática (`workspace.backup.json`), importación/restauración validada con respaldo previo automático y recuperación sin editar archivos manualmente.

## Datos

Se guardan en `~/Library/Application Support/FocusDesk/workspace.json`, con escritura atómica y copia automática `workspace.backup.json`.

En `backups/` hay además **una copia con fecha por cada día de uso** (`daily-AAAA-MM-DD.json`, se conservan las 14 últimas), más los respaldos previos a cada restauración. La copia automática refleja lo que se está guardando, así que te protege de un archivo dañado; las copias diarias son a las que puedes volver si un día guardas algo que no querías. Se restauran desde **Ajustes → Restaurar copia**.

## Desarrollo y comprobación

```sh
swift test
./build.command
# Con la app cerrada: verifica el nuevo bundle, respalda la versión previa e instala en /Applications
# (donde ya esté instalada; quita la copia duplicada de la otra carpeta Aplicaciones)
./scripts/install.command
```

Para explorar con datos separados:

```sh
./dist/FocusDesk.app/Contents/MacOS/FocusDesk --preview
```

El chequeo integrado del flujo se ejecuta con `--preview --smoke-test`; imprime `PASS` o `FAIL`, guarda `smoke-report.txt` y devuelve código de salida distinto de cero (`1`) si falla. El chequeo optativo de EventKit se ejecuta con `--verify-calendar` (y `--quit-after-verify` para uso automatizado) y también devuelve código de salida `1` si imprime `FAIL` o `BLOCKED`.
