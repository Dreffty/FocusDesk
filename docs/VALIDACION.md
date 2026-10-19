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
