# FocusDesk — diseño para revisión

Fecha: 20 de octubre de 2026. Nombre provisional: FocusDesk.
Estado: diseño; aplicación e integración todavía no implementadas ni probadas en uso real.

## 1. Para qué existe

Luis quiere preparar sus tareas y después trabajar sin tener que abrir continuamente un gestor. La aplicación le muestra lo siguiente, hace visible el tiempo disponible, le devuelve al entorno de trabajo cuando se distrae y reúne señales del resultado.

Ejemplo: «En diez minutos voy a grabar un vídeo; me doy una hora». Antes de empezar aparece una cuenta atrás. Durante la tarea solo se admiten las apps del perfil. Si termina en quince minutos, puede finalizar y preparar la siguiente tarea. Agotar la hora no significa haber terminado.

## 2. Decisiones confirmadas y propuestas

Confirmadas por Luis:

- macOS primero; aplicación independiente de ForgeDesk.
- Calendario propio y personalizable, con tareas y perfiles de trabajo.
- Observar aplicaciones activas, títulos de ventana y dominios, además de cambios en carpetas elegidas.
- Reunir evidencias y pedir confirmación para completar una tarea.
- Duración prevista obligatoria para cada sesión; permitir terminar antes.
- Mostrar tiempos en la Dynamic Island de Vorssaint mediante un calendario FocusDesk en Apple Calendar.
- En modo estricto, volver a la última aplicación permitida y registrar la interrupción.

Propuestas concretas que este documento deja para revisión:

- Conservación de detalle durante 30 días y de resúmenes hasta que Luis los borre.
- Pausa explícita, salida de emergencia y recuperación supervisada tras reiniciar.
- No adelantar automáticamente las tareas siguientes al terminar antes.
- Extensión de Brave en la fase de observación de dominios, para evitar clasificarlos a partir del título.
- Contador propio de respaldo cuando Vorssaint no pueda mostrar el tiempo.

## 3. Experiencia cotidiana

### Preparar el día

Una ventana de planificación muestra vistas diaria y semanal. Permite mover bloques, ajustar duración, asignar colores y categorías, configurar días laborables, descansos, repeticiones y antelación del aviso. Se distingue un horario de inicio de una fecha límite.

Cada tarea tiene título, duración prevista positiva, perfil y forma de comprobar el resultado. Puede tener checklist, carpeta de resultados y hora de inicio. Las tareas sin hora permanecen en una bandeja para empezar cuando haya hueco. Los solapamientos se señalan antes de guardar y no permiten dos sesiones activas simultáneas.

Las plantillas «Grabar vídeo», «Estudiar» y «Gestionar tienda» evitan repetir configuraciones. El modo estricto pertenece al perfil y puede desactivarse; el modo de aviso sigue disponible.

### Trabajar sin abrir el planificador

La app puede arrancar al iniciar sesión, con autorización del usuario. Vive en la barra de menús. Un atajo configurable abre un panel pequeño con tarea actual, tiempo y siguiente tarea. La ventana grande sirve para organizar, no es necesaria durante el trabajo.

La captura inicial será por texto. «En diez minutos…» describe el comportamiento deseado, no implica que ya exista reconocimiento de voz. Dictado o integración con VozLocal serán ampliaciones independientes.

Antes de la tarea llega un aviso configurable, por defecto diez minutos antes. En el momento de inicio aparece «Empezar / Posponer». El inicio automático puede activarse por tarea, solo si la sesión del Mac está desbloqueada y no hay otra tarea en marcha. Una tarea vencida durante el reposo no comienza retroactivamente ni genera tiempo trabajado.

Durante la sesión se ofrecen «He terminado», «Pausar» y «Ampliar». Al completar: se recoge la confirmación, se retira la restricción y se muestra la siguiente tarea con «Empezar ahora» o «Mantener horario». Las citas fijas conservan su hora.

## 4. Tiempos y estados

Estados: programada → aviso previo → lista para empezar → activa ↔ pausada → pendiente de confirmar → completada o incompleta. Una activa puede pasar a tiempo extra sin completarse. Cancelar es una salida distinta de completar.

- La duración prevista se conserva aunque la sesión termine antes o se amplíe.
- Se registran inicio real, final real, tiempo de sesión, pausas e intervalos de actividad observada por separado.
- Llegar a cero avisa y muestra tiempo extra. El modo estricto continúa mientras la sesión esté activa, hasta terminar, pausar o salir explícitamente.
- «He terminado» detiene la sesión y la restricción inmediatamente; confirmar el resultado no puede dejar al usuario encerrado.
- Pausar detiene la observación y la redirección. Al reanudar se recalcula la fecha prevista de fin conservando el tiempo restante.
- Bloqueo de pantalla o reposo pausa la observación. Al volver se ofrece reanudar; ese intervalo nunca cuenta como actividad observada.
- Ausencia de teclado/ratón no demuestra inactividad: grabar vídeo, leer o estudiar puede ocurrir sin tocar el Mac. No se pausa automáticamente por ese motivo.
- Un cierre inesperado se conserva como sesión interrumpida. Al reiniciar se ofrece recuperar; no se activan restricciones silenciosamente.

## 5. Vorssaint y el calendario puente

### Evidencia disponible

En esta conversación se comprobó la instalación de Vorssaint 3.4.1 y se inspeccionó código público de su rama main. Su lector usa EventKit y reacciona a cambios del almacén de eventos. Su módulo de calendario puede mostrar una cuenta atrás al inicio y al final del evento. Esto es evidencia de código, no una prueba de extremo a extremo en el Mac.

No se encontró un contrato público para controlar externamente su temporizador en los puntos de integración revisados. No se presume que sus funciones internas sean una API.

### Diseño del puente

FocusDesk es la fuente del estado de las tareas. Mantiene sus datos en su propia base local y proyecta bloques en un calendario dedicado mediante EventKit. Conserva identificadores para actualizar el evento correcto sin duplicados ni modificar otros calendarios.

El asistente de configuración comprobará si hay una fuente local de calendario que permita escritura. No se promete que exista en todos los Macs: si falta, se informa y se ofrece elegir expresamente una fuente disponible, indicando si sincroniza. Nunca se elige iCloud silenciosamente.

Luis concede permisos de calendario a ambas apps y selecciona el calendario FocusDesk en Vorssaint, con cuenta atrás y tiempo restante habilitados. La interfaz propia de planificación sigue siendo la de FocusDesk; Apple Calendar sirve como puente.

- Al programar se crea o actualiza el evento con inicio y final previstos.
- Al iniciar tarde se actualiza la proyección según inicio real y duración.
- Al terminar antes se acorta el final del evento. La duración originalmente prevista queda en la base propia.
- Al ampliar se modifica el final del evento, sin desplazar automáticamente otras tareas.
- Al pausar se retira temporalmente el evento proyectado de esa sesión; al reanudar se recrea con el tiempo restante. El historial sigue en FocusDesk. Los identificadores se actualizan.
- Si hay cambios externos en un evento de FocusDesk, se presentan como conflicto a resolver. No se sobrescriben repetidamente sin avisar.
- Si falla EventKit, la sesión sigue funcionando y se muestra «Vorssaint sin sincronizar». Se reintenta sin duplicar eventos.

### Límites que afectan al producto

En el código revisado, la ventana de cuenta atrás es de 60 minutos. Para una sesión de 90 minutos, el final no aparecería durante los primeros 30 minutos. Al alcanzar el final, la cuenta atrás deja de ser elegible. Además, se elige el momento más próximo entre los eventos elegibles: otra tarea puede desplazar al contador actual. Otras actividades de la isla también requieren validación visual.

Por tanto, este puente no garantiza un temporizador persistente y exclusivo para todas las duraciones, pausas y tiempo extra. Tampoco añade «He terminado» dentro de Vorssaint: ese botón vive en el panel o atajo de FocusDesk. No es una integración con su Pomodoro.

FocusDesk mantiene un contador en su barra de menús como respaldo. Si el requisito es verlo siempre dentro de la isla, incluso en esos casos, hará falta una integración adicional con Vorssaint. Ese requisito no se dará por satisfecho con el puente de calendario hasta probarlo.

## 6. Modo estricto sin cerrar aplicaciones

Se observa el cambio de aplicación en primer plano. Si la sesión activa es estricta y la aplicación está fuera del perfil, se intenta activar la última permitida y se registra una interrupción. No se suspende el proceso, no se cierra la aplicación y no se interrumpen sus tareas en segundo plano.

Las apps se identifican por bundle ID, no solo por nombre. Las herramientas necesarias del sistema, el panel de FocusDesk y los diálogos de permisos tienen excepciones explícitas para evitar bucles. Si no queda una app permitida disponible, se muestra el panel con una acción para abrir una elegida. Los fallos de redirección son visibles y no generan reintentos ilimitados.

Se agrupan cambios repetidos de un mismo episodio para no inflar interrupciones y se limita la frecuencia de avisos. Siempre hay una acción accesible para pausar o salir, sin marcar la tarea completada.

Esto es una ayuda de enfoque que Luis puede desactivar, no un bloqueo del sistema imposible de eludir.

## 7. Observación y evidencias

La observación solo ocurre durante sesiones activas. El permiso de Accesibilidad permitirá intentar leer el título de la ventana; algunas aplicaciones no lo exponen. La aplicación activa se obtiene mediante las interfaces de macOS. Un título ausente se registra como desconocido.

Para Brave se plantea una extensión pequeña que comunica dominio y cambios de pestaña activa a FocusDesk mediante mensajería nativa. Solo se atribuye actividad cuando Brave está en primer plano. No se usa el título como prueba del dominio. Sin conexión con la extensión, el dominio es desconocido y no genera sanciones basadas en una suposición.

En el primer alcance, la redirección estricta se aplica a aplicaciones. Los dominios permiten avisar y registrar; bloquear pestañas requiere implementar y probar esa capacidad por separado. Permitir Brave no impide por sí mismo navegar por webs de ocio.

Se observan metadatos de archivos únicamente en carpetas seleccionadas. Se compara el estado al inicio y al final y se filtran temporales y duplicados. Un archivo cambiado es una señal; no prueba autoría, calidad, publicación ni que sea el resultado correcto. Una exportación puede pertenecer a otro trabajo.

Ejemplos:

| Tarea | Señal automática | Confirmación de resultado |
|---|---|---|
| Grabar vídeo | Archivos nuevos en carpeta elegida; actividad compatible | «He grabado las tomas», con archivo opcional |
| Editar vídeo | Proyecto modificado o exportación detectada | Selección del vídeo final |
| Gestionar tienda | Tiempo en dominio de administración | Checklist de pedidos, mensajes y stock |
| Estudiar | Herramientas o documentos utilizados | Tema estudiado y ejercicios, o confirmación manual |

Grabar y editar son tareas diferentes. No se exige un mínimo de tiempo en CapCut para dar por grabado un vídeo. También se permite completar sin evidencia automática, indicando «confirmado por ti»; la falta de señal no equivale a incumplimiento.

No se capturan pantallas, contenidos de documentos ni pulsaciones. Se conserva el dominio, no la URL completa con rutas y parámetros. Los títulos pueden contener datos personales: se pueden excluir aplicaciones y borrar registros. Nada se envía a un modelo por defecto.

## 8. Arquitectura propuesta

SwiftUI y AppKit, con macOS 14 como mínimo propuesto. Base SwiftData independiente en Application Support/FocusDesk, con exportación y recuperación. No se comparte ni migra la base de ForgeDesk.

- PlannerCore: tareas, repeticiones, perfiles y reglas de transición con reloj inyectable para pruebas.
- SessionCoordinator: única autoridad sobre la sesión activa, temporizadores, recuperación y restricciones.
- CalendarBridge: proyección y reconciliación con EventKit, sin gobernar el estado real de la sesión.
- ActivityObserver: apps, títulos y conexión con Brave.
- FocusGuard: redirección limitada al alcance del perfil.
- EvidenceCollector: señales de archivos y resumen, sin decidir por sí solo el resultado.
- Presentation: barra de menús, notificaciones, panel rápido y planificador.

Entidades principales: TaskTemplate, TaskOccurrence, FocusProfile, WorkSession, ActivityInterval, Evidence, CompletionRecord y CalendarProjection. Las ocurrencias recurrentes tienen identidad propia para no completar toda una serie ni duplicarla al cambiar de fecha.

Los relojes separan fechas de agenda y duración transcurrida. El contador se calcula a partir de referencias temporales, no descontando un segundo por cada refresco de pantalla. Los datos de sesión y proyección se guardan de forma recuperable; una escritura fallida se muestra y nunca se presenta como éxito.

## 9. Construcción por etapas y pruebas de aceptación

### Etapa 1: probar la experiencia decisiva

Prototipo aislado con una tarea, duración obligatoria, cuenta atrás previa, evento puente y finalización anticipada. No exige construir antes un calendario completo.

Validar en el Mac: aviso previo; transición a sesión de una hora; terminar a los quince minutos; actualización visible en Vorssaint; sesión de 90 minutos; pausa; tiempo extra; eventos solapados; reposo y permisos denegados. Documentar lo que realmente muestra la isla y su latencia. No usar la existencia del evento como prueba de que se ve correctamente.

### Etapa 2: enfocar y recuperar

Perfiles, redirección, panel, persistencia y salida. Probar app permitida cerrada, cambio rápido de apps, diálogos del sistema, varios monitores, pantalla completa, fallo de activación y cierre inesperado. La tarea debe poder detenerse siempre y nunca perder documentos abiertos.

### Etapa 3: calendario y comprobación

Vistas diaria/semanal, recurrencia, mover y redimensionar bloques, checklist, carpetas de evidencia y extensión de Brave. Probar cambios de zona horaria, horario de verano, archivos ajenos, títulos ausentes, navegador sin conexión y conclusión manual sin señales.

Pruebas unitarias para estados, duración, recurrencia y reconciliación. Pruebas reales para permisos, EventKit, accesibilidad y visualización en Vorssaint. La integración solo se considera válida cuando haya evidencia de extremo a extremo.

### Criterio de utilidad

Luis puede planificar vídeo, tienda y estudio, y recorrer las tres tareas desde avisos, barra y atajo sin reabrir el planificador. Puede terminar pronto, recuperar una interrupción y entender qué se comprobó y qué confirmó él. La experiencia de temporizador en Vorssaint debe quedar demostrada con sus límites.

Fuera del primer alcance: iPhone, cuentas, nube propia, cierre forzoso de procesos, control del Pomodoro interno de Vorssaint, vigilancia continua y evaluación automática por IA de la calidad del trabajo.

## 10. Fuentes y estado de validación

- Instalación inspeccionada: /Applications/Vorssaint.app, versión 3.4.1.
- Código público inspeccionado: https://github.com/vorssaint/vorssaint-utils
- Lector: Sources/Vorssaint/Services/Notch/NotchCalendarService.swift.
- Reglas de 60 minutos y selección: Sources/Vorssaint/Services/Notch/NotchCalendarSupport.swift.
- Temporizador interno: Sources/Vorssaint/Services/Notch/NotchTimerService.swift.

La rama pública puede diferir del binario instalado. No se ha creado aún el calendario, cambiado ajustes, instalado una extensión, activado restricciones ni probado la integración. Este documento es la base revisable para esas pruebas e implementación.
