# Validación de FocusDesk 0.1

Fecha: 20 de octubre de 2026. Mac Apple Silicon, macOS 26.5.2, Swift 6.3.3.

## Verificado

- `swift test`: nueve pruebas, cero fallos. Incluyen conservación de evidencias finales al guardar/cargar y finalización idempotente.
- `./build.command`: compilación de producción y creación de `dist/FocusDesk.app`.
- `codesign --verify --deep --strict dist/FocusDesk.app`: correcto.
- `plutil -lint dist/FocusDesk.app/Contents/Info.plist`: correcto.
- Ejecución real del binario con `--preview`, en una carpeta temporal independiente.
- Inspección visual de la ventana inicial y del editor mediante accesibilidad.
- Creación y guardado de una tarea desde la interfaz; aparece en la agenda.
- Inicio, pausa y reanudación desde la interfaz. El contador conserva el tiempo acumulado y el JSON de demostración refleja la pausa.
- Corrección del contraste de botones primarios después de la inspección visual; compilación de producción posterior correcta.

# Actualización 0.2 beta · 20 de octubre de 2026

## Comprobaciones iniciales 0.2

- 15 pruebas automatizadas superadas y prueba integrada `--preview --smoke-test` en PASS.
- Bundle instalado en `~/Applications/FocusDesk.app` y abierto con LaunchServices.
- Confirmación visual previa del usuario: «Sí, aparece el contador» para «Prueba de conexión · FocusDesk» en la isla superior de Vorssaint.

---

# Cierre de fiabilidad, uso diario y mantenimiento (Prioridades 1, 2 y 3) · 20 de octubre de 2026

## 1. Pruebas automatizadas verificadas (`swift test` — 25 pruebas, 0 fallos)

1. **Recordatorios y reposición automática (Puntos 1 y 8)**:
   - `testOldTasksDoNotStarveFutureRemindersAndZeroLeadDoesNotDuplicate`: tareas antiguas no agotan el cupo de 60 avisos; vinculación `taskID` y tipo (`before` / `start`).
   - `testReminderOrderingLimitAndActiveExclusion`: orden cronológico, límite de 60 y exclusión de la tarea en sesión activa.
   - `testReminderReplenishmentWhenBusyDayConsumesInitialReminders`: detección automática (`ReminderPlan.needsReplenishment`) cuando vencen los primeros avisos en una jornada con >60 recordatorios para incorporar las tareas posteriores sin editar ni reiniciar.
2. **Postergación inteligente de tareas vencidas, futuras y sin hora (Punto 2)**:
   - `testSnoozeOverdueTaskMovesToFutureAndFutureTaskShiftsRelativeToSchedule`: posponer una tarea atrasada 2 horas calcula la nueva fecha desde `now + 10 min` (quedando en el futuro); posponer una tarea futura desplaza su horario previsto.
3. **Modo estricto y prevención de bucles (Punto 3)**:
   - `testStrictRedirectTrackerPausesAfterConsecutiveFailuresOrMissingApp`: pausa inmediata si no hay ninguna app permitida abierta y pausa de seguridad tras 3 fallos consecutivos de activación, garantizando que siempre se pueda pausar o salir.
4. **Deduplicación de episodios de distracción (Punto 4)**:
   - `testContinuousDistractionCountsOnceUntilReturnToWork`: permanecer en una aplicación no permitida a través de múltiples revisiones periódicas, cambios de título o cambios entre apps no permitidas cuenta como **una sola interrupción**; volver a una app permitida y distraerse de nuevo cuenta como la segunda.
5. **Cola persistente de sincronización con Calendar (Punto 5)**:
   - `testPendingCalendarQueueCoalescesAndClearsOnVerification`: fusión (coalescing) por `taskID` de operaciones `.upsert` y `.remove` pendientes en `Workspace.pendingCalendarOps` y limpieza al verificar el estado.
   - `testCalendarProjectionTracksPauseResumeExtensionAndEarlyFinish`, `testOvertimeDoesNotInventFutureDeadlineAndUnstartedTaskDoesNotLookActive`, `testExternalCalendarEditsAreDetectedButFractionalSecondRoundingIsTolerated`.
6. **Recuperación, respaldos y compatibilidad de esquema (Puntos 6 y 18)**:
   - `testStorageRoundTripLegacySchemaCompatibilityAndBackupRecovery`: carga intacta del `workspace.json` real de la versión 0.2, protección frente a sobrescritura cuando el archivo principal está dañado y recuperación automática desde `workspace.backup.json`.
7. **Reloj monotónico independiente de la hora del sistema (Punto 7)**:
   - `testMonotonicDurationIsImmuneToSystemClockChanges`: adelantar el reloj del sistema +2 h o atrasarlo -1 h durante una sesión activa mantiene intacta la duración medida mediante el tiempo monotónico (`uptime`).
8. **Perfiles reutilizables y normalización de dominios (Puntos 9 y 15)**:
   - `testProfileApplicationPreservesCustomTitleAndAppliesConfig`: aplica categoría, duración, modo estricto, apps, dominios normalizados, carpeta y checklist conservando el título personalizado.
   - `testDomainMatchingAndURLNormalization`: convierte entradas como `https://claude.ai/` o `http://www.chatgpt.com/c/123?q=1` en `claude.ai, chatgpt.com` e identifica entradas sin formato de dominio válido.
9. **Tareas sin horario, fecha límite, repeticiones avanzadas y elección de siguiente tarea (Puntos 11, 12 y 13)**:
   - `testUnscheduledTasksAndSmartNextTaskSelectionPrioritizesUpcomingTodayOverAncientOverdue`: las tareas en la bandeja sin hora no generan eventos ni avisos de inicio hasta programarse; la sugerencia de «siguiente tarea» prioriza tareas próximas de hoy frente a tareas olvidadas de días anteriores.
   - `testWeekdaysAndCustomDaysRecurrencePreviewAndSingleOccurrenceDetach` y `testLateRecurrenceSkipsMissedDaysButKeepsWallTime` y `testRecurrenceHasOwnIdentityAndKeepsWallTimeAcrossDST`: repetición en días laborables y días concretos (ej. L, X, V), vista anticipada de ocurrencias futuras en la semana y separación (`detachOccurrence`) para editar una sola ocurrencia sin alterar la serie.
10. **Evidencias e intervalos de actividad observada (Puntos 16 y 17)**:
    - `testActivityIntervalDurationAndAppSummaries`, `testNoObservationDuringPauseOrAfterFinish`, `testEvidenceIgnoresUnchangedAndDeletedFiles`, `testDetailRetentionKeepsSummary`.

## 2. Prueba integrada en el bundle compilado (`--preview --smoke-test`)

Ejecutada sobre `dist/FocusDesk.app/Contents/MacOS/FocusDesk --preview --smoke-test` y automáticamente dentro de `./scripts/install.command` antes de actualizar `~/Applications/FocusDesk.app`:

- **Resultado**: `PASS: Dock regular; status item visible; profiles & domain normalization; notification actions; overdue snooze; unscheduled inbox; start/pause/resume/extend; selective & manual evidence; confirm & recurrence; cancel session; auto-backup recovery.`
- **Código de salida**: devuelve `0` en `PASS` y `1` si imprime `FAIL` (verificado durante el desarrollo), permitiendo automatizar tanto `--smoke-test` como `--verify-calendar`.

## 3. Estabilización de firma, instalador y conservación de datos reales (Punto 19)

- **Firma estable**: `./build.command` detecta y firma el bundle con el certificado `Apple Development: tu-correo@ejemplo.com (M4GZ37V5M2)` (Team ID `M4GZ37V5M2`), generando un requisito designado estable en lugar de un hash ad-hoc efímero.
- **Instalador seguro (`./scripts/install.command`)**:
  1. Comprueba las fechas de modificación de `Sources/`, `Package.swift` y `Resources/` frente a `dist/FocusDesk.app` y recompila automáticamente si `dist` es más antiguo.
  2. Verifica `Info.plist`, firma (`codesign --verify --deep --strict`) y ejecuta `--preview --smoke-test` antes de tocar `~/Applications/FocusDesk.app`.
  3. Guarda la versión previa en `.build/installed-backups/` y restaura automáticamente ese respaldo si falla la copia o la verificación posterior.
- **Datos reales verificados**: `/Users/dreffty/Library/Application Support/FocusDesk/workspace.json` conserva la tarea existente «Prueba de conexión · FocusDesk» (`id: 99912E1A-20CF-4918-A22F-BD9B8B42DE7A`), el `calendarEventID` y el `calendarID` conectado (`80D4ACAD-AF3C-4D99-B828-258CAA5DD149`), además de generar `workspace.backup.json`.

## 4. Comprobaciones pendientes de interacción en sesión de usuario

- **Renovación única de permisos tras pasar de firma ad-hoc a certificado `Apple Development`**: al sustituir la firma `adhoc` previa por el certificado estable `Apple Development`, macOS TCC requiere confirmar una vez el permiso de Calendario para la nueva identidad estable (a partir de esa concesión, las siguientes recompilaciones con el mismo certificado `Apple Development` conservan el permiso). Una vez concedido, ejecutar `open /Users/dreffty/Applications/FocusDesk.app --args --verify-calendar` ejecuta la batería real de EventKit (bloque de 90 min, evento competidor, conflicto externo, pausa/reanudación, cola pendiente ante fallo temporal, final anticipado y limpieza).
- **Validación visual e interactiva en el Mac**:
  - Pulsar las acciones **Empezar ahora** y **Posponer 10 min** desde el banner de notificación de macOS con la ventana cerrada y tras reposo.
  - Observar en la isla de Vorssaint una sesión de 90 minutos (confirmando el límite de los últimos 60 minutos de Vorssaint 3.4.1 mientras el contador de FocusDesk sigue visible en barra y Dock).
  - Probar el modo estricto cambiando entre pantalla completa, varios escritorios/monitores y el navegador Brave con permiso de Automatización.

---

# Revisión de uso real: un solo temporizador, reposo y rendimiento · 20 de octubre de 2026

Revisión a partir del uso de usuario, no del código recién escrito. Se buscaron los fallos que no se ven
en la primera pasada y sí al usar la app.

## Hallazgos corregidos

1. **«Empezar» no hacía nada con una sesión en marcha, y no avisaba.** `AppModel.start` salía por `guard session == nil`
   en silencio. Se llegaba ahí desde la acción **Empezar ahora** del aviso de otra tarea —que sí suena durante la
   sesión, porque `ReminderPlan.make` solo excluye la tarea de la sesión actual— y desde **Sesión › Empezar siguiente
   tarea (⌃⌥⌘S)**. Consecuencia: creías haber cambiado de tarea y seguías cronometrando la anterior.
   Ahora hay un **relevo explícito**: «Tienes «A» en marcha. ¿La terminas y empiezas «B»?». Al aceptar se detiene A,
   se pide su resultado y B queda en cola para empezar al confirmar, así nunca se tira el tiempo ya trabajado.
   Empezar la tarea que ya está en marcha la reanuda si estaba en pausa. Ningún camino queda en silencio.
2. **El reposo o el bloqueo pausaban la sesión sin avisar al volver.** No existía observador de
   `com.apple.screenIsUnlocked` y `didWake` no ofrecía reanudar. El aviso «Sesión en pausa por reposo» lo borraba la
   interfaz a los 7 s, con el Mac bloqueado y nadie delante: al volver solo quedaba «Pausa» en la barra de menús.
   Ahora al despertar o desbloquear aparece un aviso que **espera respuesta** («¿Reanudamos?» · Reanudar / Terminar)
   y una notificación con acción **Reanudar**. Una pausa pedida por el usuario no dispara ese aviso.
3. **El reposo de pantalla ya no pausa.** `screensDidSleepNotification` llega por falta de teclado y ratón, justo el
   caso que el diseño dice que no debe pausar (grabar, leer, estudiar). Se pausa con reposo real del Mac, pantalla
   bloqueada o cambio de usuario. Si el Mac se bloquea al dormir la pantalla —configuración habitual— el caso
   sigue cubierto por `screenIsLocked`.
4. **El planificador recalculaba las repeticiones una vez por segundo.** `model.now` se publica en cada tic, así que se
   reevaluaban `TodayPage` y las siete `WeekDayColumn`, cada una proyectando las series con `upcomingOccurrences`, que
   recorría ocurrencia a ocurrencia desde el `scheduledAt` original: el coste crecía con la antigüedad de la serie.
   Medido con 8 tareas repetitivas, vista Semana, por redibujado:

   | Antigüedad de la serie | Antes | Después |
   |---|---|---|
   | 7 días | 17,3 ms | 6,5 ms |
   | 30 días | 32,0 ms | 4,7 ms |
   | 90 días | 85,3 ms | 3,7 ms |
   | 180 días | 165,6 ms | 3,3 ms |
   | 365 días | 331,2 ms | 3,2 ms |

   `upcomingOccurrences` ahora salta directamente a la ventana pedida y el coste deja de crecer. Además
   `tasksForDay` se cachea por día y el caché se vacía al cambiar el workspace, no al avanzar el reloj.
5. **⌘N abría un borrador distinto que el botón «Nueva tarea».** El menú usaba `FocusTask()` (hoy +10 min) y el botón
   `newTaskDraft()` (respeta el día que estás mirando y el inicio de jornada). El atajo lo gana el menú, así que
   `newTaskDraft` nunca se ejecutaba por teclado. Ahora los dos usan `newTaskDraft()`.
6. **Guardado cada 15 s durante toda la sesión.** El checkpoint reescribía el workspace completo dos veces (archivo
   principal + copia rodante). Pasa a 60 s: un cierre inesperado cuesta como mucho el último minuto y el disco
   recibe cuatro veces menos escrituras.
7. **Menores.** «Programar en el día seleccionado» creaba la tarea a la hora de inicio de jornada aunque ya hubiera
   pasado (a las 14:00 con jornada desde las 9, la dejaba a las 09:00 de hoy, ya atrasada): ahora usa el siguiente
   hueco de 5 minutos. Soltar un bloque en la rejilla horaria respeta el minuto donde sueltas, en pasos de 5, en vez
   de encajar siempre en `:00`. El contador pasa por `00:00` antes de mostrar tiempo extra. El texto de la vista por
   horas y las ayudas de los bloques ya no prometen arrastrar las ocurrencias proyectadas de una serie, que no son
   arrastrables.

## Cómo se comprobó

- `swift test`: **32 pruebas, 0 fallos** (25 previas + 7 nuevas en `Tests/FocusCoreTests/RegressionTests.swift`:
  equivalencia de la proyección según la antigüedad de la serie, ocurrencia separada en ventana lejana, el contador
  pasando por `00:00`, ausencia de avisos para la tarea en sesión, una sola cuenta atrás proyectada durante la
  sesión, copia diaria con poda, y el minuto exacto al soltar un bloque).
- `./build.command`: compilación de producción, firma estable y `plutil -lint` correctos.
- `--preview --smoke-test` dentro del bundle real, en **PASS**, ampliado con dos bloques nuevos:
  - Relevo: se ofrece al empezar una segunda tarea (por la acción del aviso, el camino que estaba roto), rechazarlo
    no toca la sesión en marcha, aceptarlo la detiene y encola la nueva, confirmar el resultado arranca la encolada y
    deja la anterior registrada como completada, y empezar la que ya corre la reanuda.
  - Reposo: se publican `com.apple.screenIsLocked` y `com.apple.screenIsUnlocked` de verdad; el bloqueo pausa, el
    desbloqueo ofrece reanudar, el tiempo bloqueado **no** cuenta como trabajado y una pausa del usuario no se
    reporta como pausa del sistema.
- Medición de rendimiento con un binario aparte contra `FocusCore`, antes y después (tabla de arriba).

## Cierre de los tres puntos que quedaban abiertos

8. **Una sola cuenta atrás en la isla de Vorssaint.** Mientras una sesión está activa, `CalendarProjection.make`
   deja de proyectar las tareas cuyo inicio cae antes del final previsto de esa sesión: Vorssaint elige el momento
   elegible más próximo, así que esas tareas le quitaban el contador a lo que de verdad estabas haciendo. Las que
   empiezan después del final conservan su bloque, y al pausar o terminar la sesión vuelven todas. Una tarea que
   nunca tuvo evento devuelve `unchanged`, así que no se genera trasiego innecesario en Calendar. El botón
   «Aplicar horario» de resolución de conflictos sigue imponiéndose, porque lo pide el usuario a mano.
9. **Copias de seguridad con fecha.** `workspace.backup.json` refleja lo que se está escribiendo, así que recupera un
   archivo dañado pero no un guardado erróneo. Ahora se crea además `backups/daily-AAAA-MM-DD.json`, una copia por
   día de uso, tanto al arrancar como al cruzar la medianoche con la app abierta, conservando las 14 más recientes
   (antes nada limpiaba `backups/`). Se restauran con el flujo ya existente de Ajustes.
10. **Soltar en el minuto exacto, ahora comprobable.** El cálculo salió de la clausura de la vista a
   `FocusRules.dropMinute(offset:rowHeight:step:)`, con pruebas de los extremos (fuera de la fila, altura cero, `NaN`)
   y un barrido que comprueba que todo resultado es un minuto válido en pasos de 5 y nunca desborda a la hora
   siguiente. Era el único de los tres puntos visuales que podía cerrarse sin mirar la pantalla.

## Fuera de esta revisión

- **No se pudo manejar la ventana a mano**: se pidió dos veces el permiso para controlar la app y se denegó las dos.
  La capa visual está revisada leyendo el código y ejercitada por el chequeo integrado, que afirma sobre el mismo
  estado al que se enlazan la interfaz (`handoffRequest`, `resumePrompt`, `showCompletion`), pero **nadie ha visto
  con los ojos** el diálogo de relevo ni el aviso de reanudar. Queda un repaso de 30 segundos para el usuario:
  empezar una tarea, empezar otra y comprobar el diálogo; bloquear la pantalla y desbloquearla para ver el aviso.
- La supresión de bloques competidores durante una sesión se comprueba por unidad, no contra EventKit real: el modo
  demostración no escribe en Calendar. Pendiente de confirmar en la isla con una sesión real y una tarea solapada.
