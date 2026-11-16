# Implementación inicial autorizada

1. Núcleo Swift independiente: tareas, sesiones recuperables, pausa, tiempo extra, repetición diaria/semanal, evidencias e historial. Pruebas de reglas y persistencia.
2. App nativa: plan diario/semanal, editor, selector de aplicaciones y carpetas, barra de menús, panel global, notificaciones, ajustes y permisos.
3. Integraciones: calendario dedicado EventKit (fuente elegida), observación de app/título, redirección reversible, metadatos de archivos. Dominio Brave mediante Automatización opcional; desconocido ante cualquier fallo, nunca inferido del título.
4. Empaquetado .app, icono, compilación, pruebas y apertura real para revisión.

Decisión de implementación: v0.1 usa un documento Codable con esquema versionado y escritura atómica en Application Support/FocusDesk, separado de ForgeDesk. Hace posible un respaldo/exportación legible y no requiere una migración SwiftData antes de validar el flujo. La interfaz de almacenamiento puede sustituirse después.

No se activa observación ni redirección al arrancar. Calendar, notificaciones, inicio de sesión, dominios y Accesibilidad se habilitan desde controles explícitos. No se añaden eventos a otros calendarios. No hay instalación de extensiones ni cambios en Vorssaint.

La validación visual de Vorssaint y de permisos depende de concederlos en macOS. Una compilación correcta no prueba esas integraciones.
