# FocusDesk

Tu plan del día y el tiempo de cada tarea, accesibles desde la barra de menús de macOS y el Dock.

## Abrir

Abre `/Applications/FocusDesk.app` con doble clic, búscala en Spotlight escribiendo **FocusDesk** (todo junto: «Focus Desk» con espacio no la encuentra) o usa su icono del Dock. La copia compilada también está en `dist.noindex/FocusDesk.app`. Cerrar su ventana deja la app funcionando en la barra. El atajo global (**Control + Opción + Comando + F** por defecto, configurable en **Ajustes**, que se abren con `⌘,` en su propia ventana) vuelve a abrir el planificador o el panel compacto. Para cerrarla completamente, usa **Salir** en su menú.

Requiere macOS 14 o posterior. La compilación para Apple Silicon utiliza firma estable local (`Apple Development`) cuando está disponible en el llavero (con respaldo ad-hoc `-`), conservando los permisos de macOS entre recompilaciones.

## Primer uso

1. Pulsa **Nueva tarea** (`⌘N`). Pon un objetivo, elige si tiene horario reservado o va a la **bandeja de pendientes sin hora**, añade opcionalmente una **fecha límite** independiente y define su duración.
2. Aplica uno de los **perfiles reutilizables** (*Grabar vídeo*, *Estudiar*, *Tienda*) o guarda tus propios perfiles con aplicaciones, dominios, modo estricto, duración habitual, checklist y carpeta de resultados.
3. Activa «Bloquear las apps que distraen» si quieres que FocusDesk oculte cualquier app que no esté en la lista y te devuelva a una permitida (si no hay ninguna abierta, la abre). Esas tareas pueden poner además **No molestar** mientras dura la sesión: en **Ajustes → General → No molestar al bloquear apps**, pulsa «Crear los atajos…» y añade en Atajos los dos que te propone (solo la primera vez). Puedes pausar o cancelar en cualquier momento desde la barra o la ventana. Mientras hay una sesión, **⌃⌥⌘P** (pausar o reanudar) y **⌃⌥⌘T** (He terminado) funcionan desde cualquier app, sin traer FocusDesk delante; sin sesión quedan libres para las demás apps.

**Un solo temporizador, siempre.** Si empiezas otra tarea mientras hay una en marcha, FocusDesk pregunta: «Tienes «A» en marcha. ¿La terminas y empiezas «B»?». Al aceptar, detiene la actual, te pide su resultado y arranca la nueva al confirmarlo, así nunca pierdes el tiempo ya trabajado. Empezar la tarea que ya está en marcha simplemente la reanuda si estaba en pausa.

**Si el Mac se duerme o se bloquea**, la sesión se pausa y al volver aparece un aviso que espera respuesta («¿Reanudamos?») y una notificación con acción **Reanudar**; el tiempo que el Mac estuvo bloqueado no cuenta como trabajado. Una sesión **protegida** no pregunta: al desbloquear sigue sola (preguntar era una salida gratis: bloquear, desbloquear y decir que no). Que solo se apague la pantalla no pausa nada: grabar, leer o estudiar ocurre sin tocar el teclado.
4. Al guardar tu primera tarea con hora, FocusDesk te pide permiso para avisarte (también puedes darlo en **Ajustes**). Si los avisos están desactivados, Hoy te lo dice con un botón para activarlos. Cuando llegue el aviso previo o de inicio, puedes pulsar **Empezar ahora** o **Posponer 10 min** directamente desde la notificación sin buscar la tarea en la ventana. Si el permiso está denegado, Ajustes ofrece un botón directo a la configuración de Notificaciones de macOS.
5. Pulsa **He terminado** (`⌃⌥⌘T`), aunque sobre tiempo. Revisa los archivos detectados, marca cuáles corresponden al resultado real, adjunta archivos manualmente si lo necesitas y elige cómo pasar a la siguiente tarea (**Mantener su horario**, **Empezar la siguiente** o **Descansar 10 min**).

Cerrar la pantalla o el bloqueo del Mac pausan la observación; el reposo de la pantalla por sí solo, no.

## Dónde está cada cosa

La barra lateral tiene dos mitades. **Agenda**: Hoy (`⌘1`), Semana (`⌘2`) e Historial (`⌘3`). **Antidistracción**, para lo que funciona aunque no tengas ninguna tarea en marcha:

- **Bloquear ahora** (`⌘4`): bloqueo rápido de 15 min al resto del día (también **⌃⌥⌘B**, 30 min), lo que está bloqueando en este momento con su acción (saltar fase, micro-pausa), permitir una web unos minutos y los interruptores de «Mientras bloquea» (avisos a 5 y 1 min, portapapeles, historial).
- **Reglas y límites** (`⌘5`): una galería con los siete tipos de regla (presupuesto de uso, Pomodoro, primero el trabajo, visitas contadas, cuenta atrás, horario y siempre activa), tus reglas agrupadas por lo que están haciendo, e importar o exportar en JSON.
- **Descansos** (`⌘6`): el descanso tras mucho rato seguido, las micro-pausas de tus reglas, los descansos del Pomodoro y los descansos habituales de la agenda.

Cada fila de Antidistracción enseña su estado en vivo (la cuenta atrás, cuántas reglas bloquean, cuánto falta para el descanso) y Hoy lo resume en una franja arriba. El **registro de bloqueo** (desbloqueos y cambios en tus reglas) está en Historial › Registro de bloqueo.

**Buscar función** (`⌘K`, arriba en la barra lateral) encuentra cualquier función o ajuste por su nombre o por lo que hace —«pomodoro», «portapapeles», «regex»— y te lleva a ella. Todo lo de Antidistracción tiene además su comando en el menú **Bloqueo**, así que el buscador de **Ayuda** de macOS también lo encuentra. Tras una actualización con funciones nuevas, FocusDesk las presenta una vez en **Novedades**, con un «Probar» para cada una; se puede volver a ver desde **Ayuda → Novedades de FocusDesk**.

## Cuando de verdad no quieres poder escaparte

Cada tarea decide, en **«Si quieres dejarlo a medias»**, cuánto cuesta abandonarla. Lo eliges al planificarla, con la cabeza fría, para el momento en que no la tengas:

- **Se puede parar** — como hasta ahora: pausas, cancelas o terminas cuando quieras.
- **Teclear un código** — para pausar, cancelar o terminar antes de tiempo hay que escribir a mano una cadena aleatoria (24 caracteres por defecto, configurable). No se puede pegar, y cada fallo da un código nuevo. Son los treinta segundos que suele durar el impulso.
- **Esperar unos minutos** — pedir el final arranca una espera; **la sesión sigue corriendo mientras tanto** y puedes cancelarla con un botón. Casi siempre se te pasan las ganas antes de que acabe.
- **Hasta el final** — no hay parada anticipada. Queda la **salida de emergencia**: 60 caracteres y una anotación con la fecha, visible en Ajustes.

Mientras una sesión protegida corre, **también cuesta lo mismo salir de FocusDesk** (⌘Q, el menú o el Dock): salir es la forma más corta de desactivar un bloqueo.

**Protegida antes de empezar.** A las 8:55, una tarea de las 9:00 aún no ha empezado y borrarla sería gratis: justo el momento en que gana el impulso. Por eso una tarea protegida se defiende **desde unos minutos antes de su hora** (10 por defecto, en Ajustes → General; «No protegerla antes» lo apaga) **hasta su hora de fin**, aunque no la hayas empezado. En ese margen, borrarla, retrasarla, pasarla a la bandeja o ablandarla (bajar su protección, acortarla, quitarle el inicio automático…) cuesta **lo mismo que pararla**: su código, su espera o la salida de emergencia. Adelantarla a una hora que aún tienes por delante, alargarla o endurecerla sigue libre (moverla más de 5 minutos al pasado es sacarla de su hora y también se cobra), y las tareas que «Se pueden parar» no cambian. En Hoy llevan el chip **«Ya protegida»**. Si la empiezas y la paras por su salida, después no se cobra otra vez; y el margen no se puede acortar mientras una tarea está dentro de él (sería la salida gratis: ponerlo a «No» y borrarla). Es el `activeProtectionRunUp` de FocusMe.

Las **reglas** con protección usan el mismo margen: un horario queda protegido desde esos minutos antes de empezar, y un presupuesto o una recompensa de «Primero el trabajo» cuando le quedan esos minutos. Así no se puede subir un presupuesto de 20 min a 720 en el minuto 19, ni apagar un horario a las 8:59. La regla de LoL viene con la app y vuelve sola al abrirla, así que no ofrece borrarse: su salida es desactivarla con su código.

**Las salidas que existen siempre.** Un bloqueo del que no se puede salir es una trampa, no un bloqueo:

- **Apagar, reiniciar o cerrar sesión funciona siempre**, también en «Hasta el final». FocusDesk deja pasar a macOS y guarda la sesión; al volver a abrirse sigue sola si aún le quedaba tiempo (si ya habría terminado, solo te la ofrece).
- **Cuando se acaba el tiempo**, la protección desaparece: Terminar ya no pide nada.
- **El código, la espera o «Emergencia»** (60 caracteres, solo en «Hasta el final»). Cada vez que FocusDesk dice que no, dice también dónde está la salida.
- **Último recurso, sin reiniciar nada:** Forzar salida (⌘⌥Esc, o ⌥+clic derecho en el icono del Dock). Ni el Dock ni esa ventana se bloquean nunca. Con el vigilante encendido, FocusDesk vuelve a abrirse y la sesión sigue; para apagarlo a mano: `launchctl bootout gui/$(id -u)/local.focusdesk.guard`. Si el vigilante está activado en Ajustes (una regla obligatoria 24/7 lo activa) y falta, FocusDesk lo instala al abrirse y te lo dice; apagarlo así sigue funcionando hasta el siguiente reinicio, y borrar además `~/Library/LaunchAgents/local.focusdesk.guard.plist` hasta la próxima vez que abras FocusDesk.

**La ley del trinquete.** Una sesión en marcha se puede endurecer, nunca aflojar: alargarla sí, acortarla no; subir la protección sí, bajarla no; quitar apps permitidas sí, añadirlas no; bloquear más carpetas sí, desbloquearlas no. Si intentas lo segundo, FocusDesk te dice exactamente qué campo lo impide en vez de descartar el cambio en silencio. Lo mismo vale para lo que rodea a la sesión: con una protegida en marcha no se apagan el vigilante, la vigilancia de ventanas ni la de webs dentro de apps, ni se restaura o recupera una copia (traería la sesión en pausa).

**Qué se bloquea, y cómo:**

- **Apps** — eliges si FocusDesk la **oculta** (nada se pierde), la **cierra** (como ⌘Q: puede preguntarte si guardas) o **fuerza su cierre** (para juegos y lanzadores que vuelven solos). Hay una lista fija de procesos del sistema —Finder, Dock, Ajustes, Terminal, las herramientas de accesibilidad— que como mucho se ocultan, pase lo que pase.
- **Ventanas en segundo plano** — un vídeo en una esquina o en el segundo monitor distrae aunque escribas en otra ventana. FocusDesk mira todas las ventanas visibles, no solo la que tiene el foco, y las oculta (nunca las cierra).
- **Webs de verdad** — además de avisar, una tarea puede **llevar esa pestaña a una página de bloqueo** (con el tiempo que queda y el nombre de la tarea) o **cerrar solo esa pestaña**. El resto del navegador sigue intacto. Volver con «Atrás» a la web bloqueada vuelve a bloquearla: mientras la tarea bloquea webs, FocusDesk mira la pestaña cada 5 segundos. Funciona en Safari, Brave, Chrome, Edge, Arc, Vivaldi, Opera y Chromium y, con el permiso de Accesibilidad, también en Firefox, Zen, Waterfox y DuckDuckGo, donde la dirección se lee de la barra. Tor Browser y Kagi no dejan leerla: si la tarea bloquea webs, FocusDesk avisa de que en ellos no puede.
- **Webs disfrazadas de app** — una página instalada como aplicación desde Chrome, Brave o Edge se juzga por el sitio que abre, no por su icono, y se oculta aunque la tarea no bloquee apps. Las de Safari («Añadir al Dock») no dejan leer su dirección: se avisa.
- **Webs dentro de otras apps** — páginas abiertas en Discord, Slack o Notion. Aquí **solo se avisa**: esas ventanas llevan conversaciones y documentos, y cerrarlas para matar un vídeo sería mal negocio.
- **Carpetas que distraen** — una carpeta de series, juegos o descargas, elegida por tarea o por perfil. Mientras dura la tarea, una ventana del Finder que la enseñe vuelve a la carpeta de arriba (las otras pestañas no se tocan), y una app que abra un archivo de dentro —una película en QuickTime, un cómic en Vista Previa— cierra esa ventana. Se mira la carpeta entera y todo lo que cuelga de ella, sin importar mayúsculas y siguiendo los enlaces. Las carpetas que el Mac necesita (tu carpeta de usuario, Aplicaciones, Sistema, Librería…) no se dejan bloquear. Para ver qué carpeta enseña el Finder, macOS te pide una vez que FocusDesk pueda controlarlo. Desbloquear una carpeta con la sesión en marcha lo impide el trinquete. Es el `getFinderLocation` de FocusMe.
- **Los ajustes que desarman el bloqueo** — si abres «Privacidad y seguridad», «Fecha y hora» o «Usuarios y grupos» con una sesión protegida, FocusDesk cierra esa ventana y te explica por qué. El resto de Ajustes del Sistema (Wi-Fi, sonido, pantallas) sigue disponible.

**Si insistes, cuesta más.** Cuatro intentos seguidos en pocos minutos y, durante un rato, FocusDesk cierra esas apps en vez de ocultarlas, y cierra las pestañas en vez de redirigirlas. Se puede desactivar por tarea.

**Trampas que ya no funcionan:**

- **Adelantar el reloj del Mac.** Las cuentas atrás van con un reloj del sistema que no se puede mover a mano; si detecta un salto, lo dice y sigue con el suyo.
- **Borrar o editar el archivo de datos con la app cerrada.** FocusDesk guarda una huella de la sesión protegida en el **Llavero**, fuera de sus datos. Si al abrirse falta esa sesión, te lo dice.
- **Matar el proceso o forzar la salida.** Al volver a abrirse, una sesión protegida que estaba en marcha sigue sola (antes volvía en pausa). En Ajustes → Privacidad puedes activar además **«Volver a abrirse si lo matan durante una sesión»**: un vigilante sin ventana (`FocusDesk --watcher`, lanzado por macOS al iniciar sesión) que la reabre en unos segundos. Solo actúa con una sesión protegida en marcha, nunca más de 3 veces en 3 minutos, y nunca mientras el Mac cierra sesión. Con él encendido, FocusDesk se abre también al iniciar sesión.
- **Dejar abierto un panel de FocusDesk** (Exportar, Importar…). Antes apagaba el bloqueo entero mientras siguiera abierto; ya no.
- **El permiso de Accesibilidad apagado o roto.** Sin él no funcionan el bloqueo por título, la protección de Ajustes del Sistema, la lectura de Firefox y Zen ni las webs dentro de otras apps. Si una sesión en marcha o una regla encendida lo necesita y falta, hay un aviso fijo arriba, con un botón, hasta que lo actives. Y macOS a veces dice que el permiso está dado y no lo da de verdad: FocusDesk lo comprueba preguntándole al Dock, y si el bloqueo no puede actuar avisa en vez de fingir que protege.

**Despierta mientras bloquea.** Durante una sesión que bloquea algo, FocusDesk le pide a macOS que no la adormezca (App Nap); si no, sus comprobaciones periódicas se retrasaban con la app en segundo plano.

**Hasta dónde llega, con honestidad.** FocusDesk no pide contraseña de administrador ni instala nada con permisos de root. Todo lo anterior vive en tu cuenta de usuario: añade fricción —que es lo que de verdad frena a un impulso— pero quien sepa usar la Terminal puede desmontarlo. No se vende como inviolable, porque no lo es.

Bloquear las apps que distraen oculta la app que no toca, devuelve el foco a una app permitida, vuelve a mirar al momento (los lanzadores y juegos que se ponen delante otra vez se ocultan de nuevo) y registra una sola interrupción por cada episodio continuo fuera del entorno de trabajo (volver a trabajar y salir de nuevo cuenta como otra). Finder, Ajustes del Sistema, FocusDesk, Vorssaint, los avisos y diálogos del sistema y las herramientas de accesibilidad siguen accesibles. Si una app permitida se cierra o falla su activación tras varios intentos, una sesión sin protección se pausa automáticamente para evitar bucles; una protegida no se pausa (era una salida gratis): oculta la app que no toca y te lleva a la ventana de FocusDesk. Un navegador permitido puede abrir cualquier web: los dominios se normalizan (aceptando URLs como `https://claude.ai/`), se señalan y registran, pero no se bloquean.

## Reglas: bloqueos que van solos

Una tarea bloquea mientras dura su sesión. Una **regla** bloquea sin ninguna tarea en marcha: la configuras una vez en **Reglas y límites** (`⌘5`) y actúa mientras FocusDesk esté abierta. Cada regla elige qué bloquea —apps, webs o rutas, palabras del título de la ventana, bibliotecas de juegos, carpetas— y cuándo:

- **Presupuesto de uso** — 20 min al día de YouTube y Shorts; agotados, queda bloqueado hasta el día siguiente.
- **Pomodoro** — 25 min de foco y 5 de descanso; con penalización, si te distraes el bloque vuelve a empezar.
- **Primero el trabajo** — tras 60 min de tareas, un rato de ocio de premio. Con *estudio verificado* también cuenta lo que estudias sin sesión, si hay actividad real y delante tienes una app o web marcada en **Ajustes › Qué cuenta como estudio** (o cualquier PDF). Lo que no está en esa lista no cuenta; lo que añades cuenta desde el día siguiente.
- **Visitas contadas** — 4 visitas al día de 5 min, con 30 min de enfriamiento entre una y otra.
- **Cuenta atrás** — un bloqueo guardado que lanzas cuando quieras.
- **Horario** — por días y tramos de hora.
- **Siempre activa** — hasta que la apagues.

**Se protegen igual que una tarea.** Mientras una regla con protección está actuando, apagarla, borrarla o aflojarla cuesta su código, su espera o la salida de emergencia; endurecerla es libre. Cambiar una lista nunca puede desbloquear lo bloqueado: de «Todas menos estas» a «Solo estas» solo se acepta si la lista nueva no queda vacía y no incluye nada de lo que estaba cerrado. Una regla **obligatoria 24/7** se protege siempre, no solo mientras bloquea, y activa el vigilante.

## Teclado, deshacer y apariencia

- **Deshacer y rehacer** (`⌘Z`, `⇧⌘Z`) cualquier cambio de la agenda: mover, alargar, posponer, borrar o editar una tarea. El menú Edición dice qué se va a deshacer.
- **La agenda se maneja sin ratón**: con Hoy delante, las flechas ↑↓ eligen tarea, `↩` la abre, `Espacio` la empieza, `⌥↑`/`⌥↓` la mueven 5 minutos, `⇧⌥↑`/`⇧⌥↓` cambian su duración, `⌫` la borra (pidiendo confirmación) y `Esc` quita la selección. Lo que se puede hacer con la tarea elegida está también en el menú **Tarea** (`⌘E` para editarla), y **Ayuda → Atajos de FocusDesk** los resume todos. `⌘1`, `⌘2` y `⌘3` van a Hoy, Semana e Historial, `⌘4`, `⌘5` y `⌘6` a Bloquear ahora, Reglas y límites y Descansos, y `⌘K` busca cualquier función; `⌘[` y `⌘]` pasan al día o a la semana anterior o siguiente, y `⌘T` vuelve a hoy. Con FocusDesk delante, **⌃⌥⌘A** amplía la sesión 10 minutos.
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

Se guardan en `~/Library/Application Support/FocusDesk/`: `workspace.json` con lo del día a día y `workspace.history.json` con el historial, cada uno con su copia automática (`*.backup.json`) y escritura atómica. Si nada cambió, no se escribe nada.

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
./dist.noindex/FocusDesk.app/Contents/MacOS/FocusDesk --preview
```

El chequeo integrado del flujo se ejecuta con `--preview --smoke-test`; imprime `PASS` o `FAIL`, guarda `smoke-report.txt` y devuelve código de salida distinto de cero (`1`) si falla. El chequeo optativo de EventKit se ejecuta con `--verify-calendar` (y `--quit-after-verify` para uso automatizado) y también devuelve código de salida `1` si imprime `FAIL` o `BLOCKED`.
