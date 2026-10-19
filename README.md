# FocusDesk

Tu plan del día y el tiempo de cada tarea, accesibles desde la barra de menús de macOS.

## Abrir

Abre `dist/FocusDesk.app` con doble clic. Cerrar su ventana deja la app funcionando en la barra. El atajo **Control + Opción + Comando + F** vuelve a abrirla. Para cerrarla completamente, usa **Salir** en su menú.

Requiere macOS 14 o posterior. La compilación incluida es para Apple Silicon, firmada localmente; no es una distribución notarizada.

## Primer uso

1. Pulsa **Nueva tarea**. Pon un objetivo, inicio y duración. Las plantillas Vídeo, Estudiar y Tienda son editables.
2. Elige las aplicaciones necesarias. Activa «Volver a una app permitida» si quieres redirección al distraerte. Puedes pausar desde la barra en cualquier momento.
3. Opcionalmente añade una checklist y una carpeta concreta de resultados. Se comparan fechas y tamaños de archivos, sin leer su contenido.
4. En **Ajustes**, activa las notificaciones. Cuando llegue el aviso, inicia la sesión desde la barra o el planificador.
5. Pulsa **He terminado**, aunque sobre tiempo. Revisa las señales de actividad y confirma si la tarea quedó terminada o pendiente.

El modo estricto devuelve el foco a una app permitida y registra la interrupción. Finder, Ajustes del Sistema, FocusDesk, Vorssaint y diálogos esenciales siguen accesibles. No suspende procesos ni cierra documentos. Un navegador permitido puede abrir cualquier web: los dominios se señalan, no se bloquean.

## Vorssaint y Apple Calendar

En Ajustes, concede acceso a Calendario y selecciona dónde crear el calendario **FocusDesk**. Una fuente de iCloud, Exchange u otra cuenta puede sincronizar sus eventos fuera del Mac; el resto de datos de FocusDesk permanece local.

En Vorssaint, activa su integración Calendar de Dynamic Island, las cuentas atrás y el tiempo restante, y selecciona FocusDesk. FocusDesk proyecta el inicio y el final previsto; al pausar elimina la proyección activa y al reanudar la recalcula. Al terminar antes, actualiza el final real.

**Límite conocido de Vorssaint 3.4.1:** la cuenta atrás aparece durante los últimos 60 minutos antes del inicio/final y desaparece al vencer. Otros eventos pueden competir por ese espacio. Este puente no controla su Pomodoro. El contador de FocusDesk sigue disponible, también durante el tiempo extra.

Edita los bloques desde FocusDesk: esta primera versión exporta eventos en una dirección y puede reemplazar cambios manuales realizados sobre esos mismos eventos en Calendar. Comprueba que el horario aparece correctamente antes de confiar en el puente. La integración con permisos concedidos y su presentación en Vorssaint están pendientes de validación real.

## Qué incluye la versión 0.1

- Agenda diaria y semanal, edición de horario por formulario y avisos de solapamiento.
- Sesión única con cuenta atrás, pausa, reanudación, ampliación y tiempo extra. Agotar el reloj nunca completa una tarea.
- Pausa al bloquear o suspender el Mac. Tras reiniciar, una sesión se recupera en pausa; el cierre inesperado puede perder hasta 15 segundos desde el último guardado.
- Repetición diaria/semanal: se crea la siguiente ocurrencia al completar la actual, conservando su hora local. Si completas una tarea atrasada, la siguiente puede seguir en el pasado y tendrás que reprogramarla.
- Observación de aplicaciones durante sesiones activas. Títulos opcionales con Accesibilidad y dominio de Brave mediante Automatización. Los permisos se activan desde Ajustes.
- Historial con confirmación personal, interrupciones y señales de archivos creados/modificados. Sin garantía de autoría, calidad o tarea realmente completada.
- Exportación JSON e inicio al iniciar sesión, opcional.

La primera versión no incluye arrastrar bloques, importar ediciones de Calendar, detección de conflictos externos, entrada por voz, bloqueo de webs, sincronización móvil ni reconocimiento automático del resultado de un vídeo. La siguiente tarea mantiene su horario y empieza cuando la inicias.

## Datos

Se guardan en `~/Library/Application Support/FocusDesk/workspace.json`, con escritura atómica y permisos de archivo privados. No se lee ni migra ForgeDesk. La aplicación no incorpora un servicio de IA ni envía tu actividad a un servidor.

Los títulos y dominios pueden contener información personal. El detalle de actividad se limpia al abrir la app si supera 30 días; los resúmenes, notas y nombres de archivos permanecen. Puedes borrar el detalle y exportar una copia desde Ajustes. Si el documento no se puede leer, se conserva intacto y la app impide sobrescribirlo.

## Desarrollo y comprobación

```sh
swift test
./build.command
```

Para explorar con datos separados, cierra primero la app normal y ejecuta:

```sh
./dist/FocusDesk.app/Contents/MacOS/FocusDesk --preview
```

Cada demostración usa una carpeta temporal nueva. No programa notificaciones. No habilites permisos o integraciones desde la demostración; son ajustes reales de macOS.

Estructura: `Sources/FocusCore` contiene las reglas y almacenamiento; `Sources/FocusDesk`, la interfaz e integraciones. El diseño previsto está en `docs/superpowers/specs` y el alcance inicial en `docs/plans`.

### Validación

Nueve pruebas automatizadas cubren temporizadores, finalización anticipada, recurrencia durante cambio de hora, dominios, evidencias, solapamientos, retención y persistencia. La compilación de producción y firma local están verificadas. Las comprobaciones manuales y límites concretos se registran en `docs/VALIDACION.md`.
