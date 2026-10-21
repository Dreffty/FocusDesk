# Mejoras posibles de FocusDesk · auditoría del 21 de octubre de 2026

Sobre el commit `17a76b2`. No incluye lo ya arreglado allí (relevo entre tareas, reanudar tras reposo, rendimiento de
la agenda, ⌘N, soltar en el minuto, contador en 00:00, una sola cuenta atrás en Vorssaint, copias diarias).

**Cómo se hizo.** Seis auditores en paralelo (VoiceOver, accesibilidad visual, teclado, lo prometido frente a lo hecho,
uso diario, robustez) devolvieron 55 hallazgos citando código. La verificación automática no llegó a correr (límite de
sesión), así que **cada hallazgo se comprobó a mano contra el código**: los 55 se sostienen, con dos matices corregidos
abajo. Quitando duplicados quedan 35. Las dos áreas cuyo auditor no corrió (integraciones con el sistema y
rendimiento) se cubrieron a mano y añaden 4 más (marcadas ✚). Los contrastes son cálculos WCAG con los colores reales
de `Palette`.

Esfuerzo: **S** menos de una hora · **M** unas horas · **L** un día o más.

**Estado (21 de octubre, noche): las 39 hechas.** Las 5 altas en `599aef8`; el resto en `2c49dc2`, `fea494d` y
`bde3f39`, más los retoques del repaso final. Cómo se comprobó y qué no se pudo comprobar: `VALIDACION.md`. La
revisión de diseño con las guías de Apple que se hizo a la vez: `REVISION-DISENO.md`.

---

## Alta: rompen o engañan en el uso real

*Las cinco, hechas y comprobadas el 21 de octubre (ver `docs/VALIDACION.md`).*

### 1. Una tarea repetitiva que te saltas un día deja de avisar y de salir en Vorssaint para siempre · M · ✅ **hecho**
*Encontrado por tres auditores independientes.*
Una serie es una sola tarea cuyo `scheduledAt` es la ocurrencia actual, y solo avanza al confirmar **terminada**
(`AppModel.confirm`, rama `if completed`). Si un día no la haces, la cierras con «Sigue pendiente» o la cancelas, se
queda en el pasado: `ReminderPlan.make` y `CalendarProjection.make` exigen `scheduledAt > now`, así que ningún día
siguiente tiene aviso previo, aviso de inicio ni bloque en Calendar. Y la agenda sigue pintando los días siguientes
con el borde discontinuo, así que **parece programada sin estarlo**.
**Propuesta:** al arrancar y al cambiar de día en `tick()`, para cada serie no completada cuya ocurrencia ya pasó:
separar esa ocurrencia (`detachOccurrence`) para que quede en «Atrasadas», y avanzar la serie con
`nextOccurrence(after: now)`.

### 2. Posponer o arrastrar una ocurrencia mueve la serie entera · M · ✅ **hecho**
`snoozeTask` y `shift` guardan la tarea con el mismo `id`, y la hora de toda la serie sale de su `scheduledAt`. Pulsar
«Posponer 10 min» en el aviso de «Estudiar 9:00» deja la serie a las 9:10 para siempre; arrastrar el lunes al martes
pasa todas las semanas al martes.
**Propuesta:** cuando `repeatRule != .never`, separar la ocurrencia con `detachOccurrence` y aplicar el cambio solo a
la copia, como ya hace el editor con «solo esta ocurrencia».

### 3. Editar una serie desde una de sus ocurrencias la descoloca · M · ✅ **hecho**
*Dos auditores.* En `TaskEditor`, con la opción por defecto «toda la serie»: (a) abrir el viernes de una serie diaria
y cambiar solo el título hace que la serie empiece el viernes y desaparezcan hoy y mañana, porque se copia el
`scheduledAt` del borrador; (b) abrir una ocurrencia ya separada copia su `repeatRule = .never` a la serie, que deja
de repetirse, y quedan dos tareas iguales; (c) con «solo esta ocurrencia», si cambias la fecha, la exclusión se apunta
en la fecha nueva (`occurrenceDate: draft.scheduledAt`) y la original sigue saliendo.
**Propuesta:** guardar la fecha original al abrir el editor y pasarla como `occurrenceDate`; en «toda la serie», copiar
solo los campos editables conservando el inicio y la regla de la serie; abrir desde una ocurrencia con «solo esta» por
defecto.

### 4. Los atajos de sesión solo funcionan con FocusDesk delante · M · ✅ **hecho**
*Dos auditores.* ⌃⌥⌘P, ⌃⌥⌘T y ⌃⌥⌘+ son atajos del menú (`buildMainMenu`): solo llegan si FocusDesk está activa. El
único atajo global es el de abrir (`GlobalHotKey`, un solo id). Durante una sesión estás en CapCut o Brave, que es
justo cuando quieres pausar o terminar. El README promete lo contrario.
**Propuesta:** registrar varios atajos en `GlobalHotKey` (ids distintos, leídos con `GetEventParameter`) para pausar,
terminar y ampliar, activos solo mientras hay sesión.

### 5. ✚ El permiso de avisos solo se pide en Ajustes, y si no vas nadie te lo dice · S · ✅ **hecho**
`reminders.request()` solo se llama desde Ajustes (`Editors.swift:644`), y Hoy no avisa de que estén desactivados.
Quien crea tareas sin pasar por Ajustes no recibe ningún aviso previo ni de inicio, que es la promesa central de la app.
**Propuesta:** pedirlo al guardar la primera tarea con hora, y mostrar en Hoy un aviso persistente con botón mientras
el estado sea `.notDetermined` o `.denied`.

---

## Media: fricción clara o riesgo

### 6. Avisos que piden acción se borran solos a los 7 segundos · S–M · ✅ **hecho**
`MainView.task(id: notice)` borra cualquier `notice` a los 7 s, aunque nadie lo haya visto. Afecta a: la sesión
recuperada tras un cierre inesperado (`init`, «Sesión recuperada en pausa»), que el diseño promete ofrecer; la pausa del
modo estricto porque no queda ninguna app permitida abierta, que además no ofrece botón para abrirla; y entrar en una
web fuera de la tarea, que solo sale en la ventana de FocusDesk (detrás de Brave) y no cuenta como interrupción.
**Propuesta:** separar confirmaciones (se pueden ir solas) de avisos que piden acción (persisten, como
`resumePrompt`). Usar `resumePrompt` también para la sesión recuperada; añadir un botón por cada app permitida en la
pausa estricta; mandar notificación y marcar interrupción para el dominio fuera de la lista.

### 7. «He terminado» no tiene vuelta atrás, y hay dos pulsaciones que tiran trabajo · S–M · ✅ **hecho**
Pulsar «He terminado» sin querer no se puede deshacer: solo queda «Sigue pendiente» y volver a empezar con la hora
completa. En la hoja de confirmación, «Cancelar sesión» cancela **sin preguntar** (en los controles de sesión sí
pregunta). Y ⌘N con el editor abierto sustituye el borrador por uno vacío, perdiendo lo escrito.
**Propuesta:** `WorkSession.reopen` y un botón «Volver a la sesión»; mismo `confirmationDialog` para cancelar; en
`newTask()`, no sustituir si `editingTask != nil` o la confirmación está abierta.

### 8. Un clic con un pequeño temblor mueve la tarea 5 minutos, y no hay deshacer · S + M · ✅ **hecho**
El arrastre del bloque empieza a 4 pt y redondea a pasos de 5 min: un clic con 3–7 pt de movimiento la desplaza 5
minutos y reprograma su aviso y su evento sin que se note. Nada se puede deshacer (⌘Z no hace nada).
**Propuesta (S):** exigir al menos medio paso (≈12 pt) antes de mover. **(M):** instantánea antes de cada cambio de
agenda, registrada en el `undoManager` de la ventana, con un botón «Deshacer» junto al aviso.

### 9. Lo atrasado queda al fondo, plegado y sin contar · S–M · ✅ **hecho**
La tarjeta «Atrasadas de otros días» va al final de Hoy y en un `DisclosureGroup` plegado; la insignia de Hoy no la
cuenta. Pasar una atrasada a hoy o a mañana obliga a abrir el editor.
**Propuesta:** ponerla arriba y desplegada cuando haya alguna, sumarla a la insignia, y añadir «Hoy en el primer hueco»
y «Mañana a la misma hora» a la fila.

### 10. Con la app abierta de un día para otro, Hoy sigue mostrando ayer · S · ✅ **hecho**
`selectedDate` solo se fija al arrancar. Por la mañana, Hoy enseña la agenda de ayer, y ⌘N o «Planificar una tarea»
crean la tarea **ayer**, ya atrasada y sin aviso.
**Propuesta:** en el cambio de día de `tick()` y al despertar, si se estaba mirando el día que acaba de terminar,
avanzar `selectedDate` a hoy.

### 11. Vista por horas: las solapadas se tapan, y las que acaban tras la medianoche desaparecen · M · ✅ **hecho**
Los bloques se dibujan a todo el ancho en un `ZStack`: dos tareas a la misma hora se tapan y la de abajo no se puede
pulsar ni arrastrar. `endHour` usa la hora suelta del final, así que una tarea de 23:00 a 00:30 calcula fin = 1 y la
rejilla corta a las 21:00: el bloque queda fuera.
**Propuesta:** agrupar las solapadas y repartir el ancho en columnas; calcular el fin en minutos desde el inicio del
día y recortar los bloques a las 24:00.

### 12. La checklist no sirve de prueba, y el resumen por app se pierde a los 30 días · S–M · ✅ **hecho**
`setCheck` exige `endedAt == nil`, así que en «¿Qué has conseguido?» solo ves «0 pasos» y no puedes marcarlos; el
historial no muestra qué pasos hiciste. `Workspace.prune` vacía `activities`, de donde salen los resúmenes por app, así
que «CapCut · 34 min» desaparece pasados los 30 días aunque el diseño promete conservar los resúmenes.
**Propuesta:** listar y permitir marcar los pasos al confirmar y guardarlos por texto en el registro; guardar
`appSummaries` y el total observado en `SessionRecord` antes de podar.

### 13. El menú Sesión siempre parece disponible y falla en silencio · S · ✅ **hecho**
No hay `validateMenuItem`: Pausar, He terminado y +10 min se ven activos sin sesión. `menuAddTenMinutes` compara
`session?.endedAt == nil`, que con **ninguna** sesión es cierto, y acaba reescribiendo el archivo y sincronizando
Calendar para nada.
**Propuesta:** `NSMenuItemValidation` en `AppDelegate`, título «Pausar»/«Reanudar» según el estado, y
`if let s = model.session, s.endedAt == nil`.

### 14. Dos de los atajos globales que ofrece Ajustes secuestran atajos de otras apps · S · ✅ **hecho**
`HotKeyPreset` incluye ⇧⌘F y ⌥⌘F. `RegisterEventHotKey` los captura en todo el Mac: con ⇧⌘F deja de funcionar
«Buscar en archivos» de VS Code y Xcode, sin ningún aviso.
**Propuesta:** dejar solo combinaciones de tres modificadores y migrar a ⌃⌥⌘F a quien tenga guardada una de las
quitadas.

### 15. Los avisos se amontonan y los entregados nunca se retiran · S · ✅ **hecho**
«Vuelve a tu tarea» se envía con un identificador nuevo cada vez: seis distracciones, seis banners con sonido. ✚ Además
nunca se llama a `removeDeliveredNotifications`: el «Es el momento · X» sigue en el Centro de Notificaciones después de
empezar, posponer o borrar esa tarea.
**Propuesta:** identificador fijo por sesión para que cada aviso de distracción sustituya al anterior, con un mínimo de
2–3 min entre sonidos; retirar los avisos entregados de una tarea al empezarla, posponerla o borrarla.

### 16. Los conflictos con Apple Calendar solo se ven dentro de Ajustes · M · ✅ **hecho**
Si mueves o borras en Calendar el bloque de una tarea, FocusDesk no lo pisa (bien), pero no lo dice en Hoy, en la
tarea ni en la barra, y la cuenta atrás de Vorssaint simplemente no aparece.
**Propuesta:** sumar `calendar.issues` a la insignia de Ajustes y mostrar un chip «Calendar: revisar» en la fila y en
la sesión de la tarea afectada.

### 17. El inicio automático por tarea, prometido en el diseño, no existe · M · ✅ **hecho**
El documento de diseño lo prevé («puede activarse por tarea, solo si la sesión del Mac está desbloqueada y no hay otra
tarea en marcha»); no hay ningún `autoStart` en el código.
**Propuesta:** campo `autoStart` en la tarea y el perfil, con interruptor en el editor; en `tick()`, empezar si toca,
no hay sesión y la pantalla no está bloqueada.

### 18. Planificar el día obliga a corregir la hora de cada tarea nueva · S–M · ✅ **hecho**
Para otro día, todas las tareas nuevas salen a la hora de inicio de jornada, unas encima de otras. «+1h» suma sobre
`Date()`, así que en una tarea de mañana se la lleva a hoy. No se puede crear con doble clic en un hueco.
**Propuesta:** proponer el primer hueco libre del día; que «+1h» sume sobre `draft.scheduledAt`; doble clic en un hueco
abre el editor con esa hora.

### 19. Hoy no enseña lo trabajado ni dónde está de verdad la sesión · M · ✅ **hecho**
No hay un total de lo trabajado hoy. Una tarea prevista a las 9:00 que empezaste a las 10:20 y ampliaste se sigue
pintando de 9:00 a 10:00, así que no ves que ya pisa la siguiente.
**Propuesta:** `StatPill("Trabajado")` con el historial del día más la sesión activa; bloque «en directo» desde
`startedAt` hasta `CalendarProjection.deadline`.

### 20. El panel de la barra no sirve para apuntar nada · M · ✅ **hecho**
En plena sesión, apuntar «llamar al proveedor» obliga a abrir el planificador y rellenar el formulario entero. El panel
tampoco dice qué viene después.
**Propuesta:** campo «Apuntar en la bandeja…» en `MenuPanel` (crea una tarea sin hora con Intro) y una línea
«Después: título · hora» durante la sesión.

### 21. El historial no responde a «qué hice ayer», y se redibuja entero cada segundo · M · ✅ **hecho**
No agrupa por día ni da totales diarios. `HistoryPage` lee `model.now`, así que se reconstruye cada segundo, sin
`LazyVStack`, y el historial nunca se recorta.
**Propuesta:** agrupar por día con «Hoy», «Ayer» y totales; `LazyVStack` con «Mostrar más»; sacar `now` del cálculo.

---

## Accesibilidad

Hoy hay 58 iconos (`Image(systemName:)`) y 4 `accessibilityLabel` en toda la app, ninguna `accessibilityValue`,
`accessibilityAction`, `@FocusState` ni lectura de «Reducir movimiento».

### 22. VoiceOver: los botones de icono no dicen qué hacen ni sobre qué · M · ✅ **hecho**
*Matiz corregido:* VoiceOver no dice «botón» a secas, dice el nombre genérico del dibujo («lápiz», «cerrar»,
«reproducir»); `.help` solo llega como ayuda, tras una pausa. En las listas de Ajustes cada app, categoría, descanso o
perfil tiene una «x» idéntica, así que no sabes qué vas a borrar (y algunos se borran sin confirmar).
**Propuesta:** `Label("Pausar", systemImage: "pause.fill").labelStyle(.iconOnly)` (se ve igual, se lee bien) y, en
listas, `.accessibilityLabel("Quitar \(app.name)")`.

### 23. La casilla del entregable y los selectores no dicen su estado · S · ✅ **hecho**
La casilla de «¿Qué has conseguido?» es un botón con un icono: sin nombre de archivo y sin «marcada». `SelectableChipBody`
no añade `.isSelected`, así que días laborables, duración, perfil o sección de Ajustes se eligen a ciegas.
**Propuesta:** `Toggle(...).toggleStyle(.checkbox)` con el nombre del archivo; una línea
`.accessibilityAddTraits(selected ? .isSelected : [])` en `SelectableChipBody`.

### 24. La cuenta atrás y la barra de menús no se entienden con VoiceOver · S · ✅ **hecho**
Se oye «24:13» suelto (puede sonar a una hora del día) y luego «RESTANTE»; el anillo no existe para VoiceOver. El icono
de la barra tiene una etiqueta fija («FocusDesk · temporizador y tareas»): no dice tarea, tiempo ni pausa.
**Propuesta:** combinar en un elemento con etiqueta «Tiempo restante» y valor en palabras redondeado al minuto;
actualizar `setAccessibilityLabel` del botón de estado en `updateStatus()`.

### 25. La agenda se lee a trozos y mover una tarea exige arrastrar · M · ✅ **hecho**
Cada bloque se oye en piezas, después de quince horas vacías. No hay alternativa al arrastre para adelantar o retrasar.
En Semana, `WeekTaskCard` solo tiene `onTapGesture`: no se puede abrir con teclado ni con VoiceOver.
**Propuesta:** `.accessibilityElement(children: .combine)` en cada bloque y acciones con nombre («Adelantar 15
minutos», «Retrasar», «Alargar», «Acortar», «Empezar», «Editar»); `WeekTaskCard` como `Button`.

### 26. Los avisos no se anuncian a VoiceOver · S · ✅ **hecho**
Aparecen arriba, lejos del cursor, y se van solos.
**Propuesta:** `NSAccessibility.post(..., notification: .announcementRequested, ...)` al cambiar `notice`, `error` o
`resumePrompt`.

### 27. Contraste insuficiente en lo atenuado · S–M · ✅ **hecho**
*Matiz corregido:* el gris `muted` pasa (6,15:1 sobre surface); no pasan sus variantes. Medido:

| Texto | Contraste | Mínimo |
|---|---|---|
| Hora dentro de cada bloque (sobre su color al 20 %) | 3,7–4,1:1 | 4,5:1 |
| Horas fuera de jornada (`muted` al 40 %) | 2,05:1 | 4,5:1 |
| Filas y bloques completados (opacidad 0,5–0,55) | 2,0–2,8:1 | 4,5:1 |
| Bordes de tarjetas y campos (blanco al 7 %) | 1,21:1 | 3:1 |
| Color de categoría elegido usado como texto (un azul medio) | 2,65:1 | 4,5:1 |

**Propuesta:** `Palette.text` para la hora del bloque; marcar fuera de jornada y completadas con el fondo, no con la
opacidad del texto; bordes de al menos 3:1; usar el color de categoría para el punto y la barra, no para el texto.

### 28. Estados que solo se distinguen por el color · S · ✅ **hecho**
«Límite» vencido solo cambia a coral (el texto es el mismo); completada solo por el tachado; solapada en Semana, un
triángulo diminuto sin texto.
**Propuesta:** «Vencida · 21 oct 10:00» con icono propio, y etiquetas de accesibilidad «Completada» y «Solapada».

### 29. Letra fija de 9–10 pt en chips y estados · M · ✅ **hecho**
`Chip` usa 10 pt fijos; varias etiquetas en mayúsculas 9 pt; los iconos de los botones de 20 pt quedan en ~8 pt. Nada
responde a ningún ajuste del sistema.
**Propuesta:** mínimo 11 pt en `Chip`, `fieldLabelStyle` y `StatPill`; botones de icono de 24 pt.

### 30. «Aumentar contraste», «Reducir movimiento» y «Diferenciar sin color» no tienen efecto · M · ✅ **hecho**
Ningún `colorSchemeContrast`, `accessibilityReduceMotion` ni `accessibilityDifferentiateWithoutColor`. La app es
siempre oscura (cinco `.preferredColorScheme(.dark)`); seguir el sistema es decisión de producto (L).
**Propuesta:** leer esos tres entornos en `FocusButtonBody`, `Card` y `SelectableChipBody`; sin animaciones en la cuenta
atrás con «Reducir movimiento».

### 31. El modo estricto trata Utilidad VoiceOver como distracción · S · ✅ **hecho**
`FocusRules.systemExemptBundleIDs` exime Ajustes del Sistema, pero no las utilidades de accesibilidad.
**Propuesta:** añadir `com.apple.VoiceOverUtility` y similares (comprobar cada identificador en el Mac).

### 32. Faltan encabezados y nombres · S · ✅ **hecho**
`SectionHeader` no lleva `.isHeader` (el rotor de VoiceOver no salta por secciones); las insignias de la barra lateral
no tienen valor; el editor de la checklist y el selector de color no tienen nombre.

---

## Teclado

### 33. No se puede actuar sobre una tarea concreta sin ratón · L · ✅ **hecho**
Sin «tarea seleccionada» ni foco: abrir, empezar, posponer o borrar una tarea que no sea «la siguiente» exige ratón.
**Propuesta:** `selectedTaskID` + `.focusable()` en filas y bloques; ↑/↓ para recorrer, ↩ editar, espacio empezar, ⌫
borrar, ⌥↑/⌥↓ mover.

### 34. Formularios que no responden como esperas · S · ✅ **hecho**
`ProfileEditorSheet` no tiene atajos (Esc no cierra, Return no guarda). En la confirmación solo Return tiene tecla, y
marca «terminada». Return en el nombre de un perfil nuevo guarda **la tarea** y cierra el editor sin crear el perfil.
Tab en la checklist escribe un tabulador. Nada pone el cursor en el título al abrir el editor.
**Propuesta:** `.keyboardShortcut(.cancelAction/.defaultAction)` en el editor de perfiles; ⌥↩ para «Sigue pendiente»;
`.onSubmit` en el nombre del perfil; `@FocusState` con foco inicial en el título.

### 35. ⌘[ y ⌘] no cambian de semana en Semana · S · ✅ **hecho**
Avanzan un día; en Semana no se nota nada hasta la séptima pulsación.
**Propuesta:** saltar ±7 días en Semana, o añadir ⌥⌘[ y ⌥⌘].

---

## Robustez y rendimiento

### 36. Un solo dato ilegible bloquea toda la agenda · M · ✅ **hecho**
La lectura es todo o nada: un campo roto en una tarea deja la app en solo lectura, y la copia automática contiene lo
mismo.
**Propuesta:** decodificar tareas, historial y perfiles elemento a elemento, saltando y contando los rotos, con
respaldo del archivo original antes de seguir.

### 37. Fecha límite anterior al inicio, y mínimos de duración distintos · S · ✅ **hecho**
Se acepta un límite el martes para una tarea del jueves sin ningún aviso. La duración mínima es 1 min en el editor, 5 en
los menús y 10 al redimensionar; el `Stepper` baja de 5 a 1 y vuelve a 6, 11, 16…
**Propuesta:** chip «Termina después de su límite»; una sola constante `5...720` en todos los sitios.

### 38. ✚ Brave: un proceso nuevo cada 5 segundos · S–M · ✅ **hecho**
Con la lectura de dominios activa y Brave delante, `observe()` lanza un `osascript` cada 5 s y en cada activación
(unos 720 procesos por hora). La lectura de títulos por Accesibilidad va en el hilo principal con 0,15 s de espera.
**Propuesta:** leer el dominio solo al cambiar de app o de ventana y, como mucho, cada 15–30 s; leer títulos fuera del
hilo principal.

### 39. ✚ El reloj late cada segundo aunque no haya nada que contar · M · ✅ **hecho**
El temporizador de 1 s publica `now` y refresca Dock y barra siempre, también sin sesión y con la ventana cerrada.
**Propuesta:** latir a 1 Hz solo con sesión activa o con una tarea dentro de su aviso previo; si no, cada 30–60 s.
