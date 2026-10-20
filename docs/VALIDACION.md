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

## Pendiente de validación real

- Conceder permisos y comprobar avisos de macOS, lectura de títulos y dominio de Brave.
- Probar la redirección de una app no permitida hacia una permitida durante una sesión estricta.
- Conectar Calendar y verificar cuentas atrás en Vorssaint; no se han creado calendarios ni eventos durante estas pruebas.
- Finalización y confirmación desde la interfaz, evidencias de una carpeta real, reposo/bloqueo y recuperación tras cierre inesperado. Las reglas de temporizador y almacenamiento sí tienen pruebas automatizadas.
- Inicio al iniciar sesión, exportación desde el diálogo y uso prolongado.

Hermes no pudo efectuar la revisión mecánica: NVIDIA respondió HTTP 410 para DeepSeek v4-pro y para el reintento con MiniMax M3, indicando que ambos modelos estaban retirados. No se ha usado salida de esos modelos como evidencia.

El alcance de esta entrega es una primera versión utilizable para validar el flujo. El documento de diseño contiene comportamientos futuros que aún no están implementados; README enumera los límites actuales.

# Actualización 0.2 beta · 20 de octubre de 2026

## Comprobaciones nuevas

- 15 pruebas automatizadas superadas (las 9 anteriores y 6 de planificación): avisos futuros pese a muchas tareas vencidas, aviso único con antelación cero, orden/límite de avisos, exclusión de sesión activa, repetición atrasada, proyección de pausa/reanudación/ampliación/final anticipado y detección de cambios externos.
- Prueba integrada dentro de la aplicación compilada: `--preview --smoke-test` produjo PASS para activación regular con Dock, NSStatusItem visible, creación/inicio/pausa/reanudación/ampliación/checklist, detección de un archivo nuevo, finalización, confirmación, recurrencia e historial persistente. Datos de prueba aislados.
- Bundle instalado en `~/Applications/FocusDesk.app` y abierto con LaunchServices, independiente del terminal. Firma local verificada.
- Usuario confirmó concesión de acceso y conexión de un calendario FocusDesk. Su identificador quedó guardado en los datos reales; no se han migrado ni borrado datos del usuario.
- Configuración de Vorssaint inspeccionada de solo lectura: isla y cuenta atrás previa activadas. El usuario confirmó después haber activado Tiempo restante.
- La última recompilación invalidó el permiso previo para el bundle con firma ad hoc: el chequeo real de Calendar devolvió BLOCKED. Se ha vuelto a solicitar sobre la versión final instalada, sin nuevas recompilaciones durante esta comprobación.

## Correcciones y mejoras

Dock, menú macOS, reapertura de ventana, contador del Dock, barra compacta con NSStatusItem, protección frente a dos instancias, instalación reproducible y conservación de la versión anterior. Temporizador en modo common para seguir actualizándose con menús abiertos. Arrastre de tareas entre días. Editor adaptable a pantallas pequeñas. Pausa ante fallo de escritura o falta de una app permitida abierta. No se anotan respuestas tardías de Brave tras desactivar su observación. Limpieza diaria del detalle antiguo.

El puente Calendar registra su última proyección, evita sobrescribir cambios externos y permite resolverlos explícitamente; recupera eventos propios sin ID local, preserva eventos trasladados/convertidos en series y no recrea automáticamente eventos borrados. Los avisos se serializan y comunican errores. Las tareas antiguas ya no agotan el cupo de avisos futuros.

Hermes: el intento con el modelo predeterminado no produjo respuesta y se detuvo; el único reintento con Kimi devolvió 404 de NVIDIA. Ningún resultado externo se usa como evidencia.

## Límites que permanecen

La lectura de títulos, Automatización de Brave, entrega visible de notificaciones, redirección estricta en uso real y representación visual en Vorssaint no quedan demostradas por las pruebas del núcleo ni por el smoke test. El puente de calendario no controla el Pomodoro de Vorssaint. Las webs se señalan pero no se bloquean. La beta se firma localmente: una recompilación puede exigir conceder permisos otra vez.

## Resultado de la comprobación real de Calendar

Tras renovar el permiso, `--verify-calendar` ejecutado desde la copia instalada devolvió **PASS**: creación y lectura de un evento real propio, protección ante cambio externo, resolución explícita, inicio, pausa/eliminación, reanudación/recreación, finalización anticipada y retirada del evento temporal. El informe se guarda en `~/Library/Application Support/FocusDesk/calendar-check.txt`. No se modificó ningún evento ajeno.

La tarea «Prueba de conexión · FocusDesk» quedó creada en los datos normales con identificador de evento y proyección guardados. La captura aportada por el usuario confirma calendario FocusDesk seleccionado en Vorssaint, acceso concedido, ambos contadores activados y el icono de FocusDesk en el Dock. Esa captura aún mostraba «No hay próximas citas» antes del envío de la prueba; se ha solicitado confirmación visual del contador después del envío.

Los binarios de `dist/FocusDesk.app` y `~/Applications/FocusDesk.app` coinciden por SHA-256. No se ha recompilado después de renovar el último permiso.

**Confirmación visual final del usuario:** «Sí, aparece el contador» para «Prueba de conexión · FocusDesk» en la isla superior. La integración Calendar/Vorssaint queda validada en este Mac para el envío y visualización del contador, además de las operaciones EventKit probadas. La redirección estricta, notificaciones visibles y lectura opcional de títulos/dominios siguen requiriendo pruebas de uso real.
