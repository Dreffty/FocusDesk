# Revisión de diseño: FocusDesk · 21 de octubre de 2026

Hecha con la skill [apple-design](https://github.com/dickwu/apple-design-skill), que aplica las guías de interfaz de
Apple (HIG). Se leyeron antes de citar: `accessibility.md`, `layout.md`, `typography.md`, `color.md`,
`designing-for-macos.md`, `dark-mode.md`, `sidebars.md`, `settings.md`, `feedback.md`, `undo-and-redo.md`,
`motion.md`, `keyboards.md` y `the-menu-bar.md`.

**Qué se revisó.** Capturas reales de la app, dibujadas por ella misma con `--preview --snapshots <carpeta>` (en
claro, en oscuro y con el texto al 130 %), más el código. Los contrastes se calcularon con WCAG a partir de los
valores de color, no estimados de una imagen.

## Resumen

Una app de escritorio para planificar el día y trabajar una tarea cada vez. Su **tesis** es «ahora, solo esto»: la
cuenta atrás de la sesión en curso, siempre a la vista (en la ventana, la barra de menús, el Dock y la isla de
Vorssaint). Ese es su **elemento firma**, y le pertenece de verdad al producto.

Valoración **antes**: *Critical issues* (fallos de accesibilidad y varias convenciones de macOS rotas). **Después**
de los cambios de esta revisión: sin hallazgos críticos ni altos abiertos.

## Críticos (resueltos)

- **Contraste insuficiente.** Las horas fuera de la jornada estaban a 2,05:1, las tareas completadas a 2,0–2,8:1, los
  bordes de los campos a 1,21:1 y la hora dentro de cada bloque a 3,7–4,1:1.
  *Por qué:* `accessibility.md › Vision`: «Up to 17 pts · All · 4.5:1».
  *Arreglo:* paleta nueva con papeles definidos, variantes clara, oscura y de «Aumentar contraste», y las cifras
  de la tabla de abajo. Las completadas ya no se desvanecen enteras: se desaturan.
- **Textos de 8 y 9 pt.** Por debajo del mínimo de macOS.
  *Por qué:* `accessibility.md › Vision`, tabla: «macOS · 13 pt · 10 pt».
  *Arreglo:* todas las fuentes pasan por `Font.app`, que impone 10 pt como mínimo.
- **No había forma de agrandar el texto.**
  *Por qué:* `accessibility.md › Vision`: «Support larger text sizes… either through custom UI, or by adopting
  Dynamic Type»; y `typography.md › Desktop`: «macOS doesn't support Dynamic Type».
  *Arreglo:* Ajustes › General › Tamaño del texto (Normal, Grande, Muy grande). La barra lateral y la confirmación
  se ensanchan con él, y nada se corta al 130 %.
- **Avisos con temporizador.** Se borraban solos a los 7 segundos.
  *Por qué:* `accessibility.md › Cognitive`: «Minimize use of time-boxed interface elements… Prefer dismissing views
  with an explicit action».
  *Arreglo:* se van con su ✕, con el aviso siguiente o al cambiar de página.
- **Estados solo por color, y un color con dos significados.** «Vencida» solo cambiaba a coral; el coral era a la
  vez la categoría «Contenido» y el color de aviso; «Tienda» usaba el mismo verde que el acento y la sesión.
  *Por qué:* `color.md › Best practices`: «Avoid using the same color to mean different things», y `accessibility.md
  › Vision`: «Convey information with more than color alone».
  *Arreglo:* avisos en ámbar con icono propio, «Vencida · fecha» en palabras, «Tienda» en turquesa (migrada solo si
  conservaba el verde antiguo), línea de «ahora» en rojo como en Calendario.
- **VoiceOver.** 58 iconos y 4 etiquetas; casillas y selectores sin estado; la cuenta atrás leída como «24:13».
  *Arreglo:* nombres en todos los botones de icono (con el elemento en las listas: «Borrar categoría Tienda»),
  rasgo «seleccionado», cuenta atrás en palabras redondeada al minuto, bloques de la agenda como un solo elemento
  con acciones con nombre («Adelantar 15 minutos»…), anuncios de los avisos y encabezados para el rotor.

## Mejoras (resueltas)

- **Alta · Siempre oscura.** *Por qué:* `dark-mode.md › Best practices`: «Avoid offering an app-specific
  appearance setting… In rare cases, consider using only a dark appearance», casos raros como reproductores
  inmersivos; un planificador no lo es. *Arreglo:* sigue la apariencia del sistema, sin interruptor propio.
- **Alta · Ajustes como página de la barra lateral.** *Por qué:* `settings.md › Desktop`: ventana propia desde
  Ajustes… del menú de la app, con barra de pestañas fija, título que sigue a la pestaña, minimizar y ampliar
  atenuados, y vuelta a la última pestaña. *Arreglo:* exactamente eso, con ⌘,.
- **Alta · Menús.** Edición iba después de los menús propios; faltaban Ventana y Ayuda, y en el menú de la app
  Servicios, Ocultar otros y Mostrar todo. *Por qué:* `the-menu-bar.md › Anatomy` y «Provide a Window menu even if
  your app has only one window». *Arreglo:* orden estándar, elementos que se desactivan en vez de fallar en
  silencio («Always show the same set of menu items… disable the action instead of hiding it»).
- **Alta · Deshacer.** No existía. *Por qué:* `undo-and-redo.md › Desktop`: «Place undo and redo commands in the Edit
  menu and support the standard keyboard shortcuts». *Arreglo:* ⌘Z y ⇧⌘Z de varios pasos, con el nombre de la
  acción en el menú; un paso antiguo nunca revierte un cambio posterior.
- **Alta · Acción crítica abajo en la barra lateral.** La sesión y su «Terminar» estaban en el borde inferior.
  *Por qué:* `sidebars.md › Desktop`: «Avoid putting critical information or actions at the bottom of a sidebar».
  *Arreglo:* suben bajo «Nueva tarea».
- **Media · Atajo con un carácter no universal.** ⌃⌥⌘+ necesita Mayúsculas en muchos teclados. *Por qué:*
  `keyboards.md`: «avoid using an additional modifier with characters that aren't available on all keyboards».
  *Arreglo:* ⌃⌥⌘A (Ampliar).
- **Media · Comandos solo en la ventana.** *Por qué:* `designing-for-macos.md › Best practices`: «Use the menu bar to
  give people easy access to all the commands». *Arreglo:* menú Tarea con todas las acciones sobre la tarea
  elegida, y menú en el icono del Dock.
- **Media · Peso light en la cuenta atrás.** *Por qué:* `typography.md`: «In general, avoid light font weights».
  *Arreglo:* regular.
- **Media · Animación cada segundo.** *Por qué:* `motion.md`: «avoid adding motion to UI interactions that occur
  frequently» y «Make motion optional». *Arreglo:* con «Reducir movimiento», la cuenta atrás y el anillo dejan de
  animarse.
- **Media · Bloques solapados ilegibles.** Visto en las capturas: con cuatro tareas a la vez, «Gra…», «Edit…» y un
  chip cortado en «⚠ S». *Arreglo (juicio propio, sin guía concreta):* diseño compacto en columnas estrechas (hora y
  título en dos líneas; una sola para los bloques cortos).
- **Baja · El contador en la barra de menús, impuesto.** *Por qué:* `the-menu-bar.md › Menu bar extras`: «Let
  people — not your app — decide whether to put your menu bar extra in the menu bar». *Arreglo:* Ajustes › General.

## Paleta y contrastes

| Papel | Oscuro | Claro | Peor caso (fondo / superficie / elevado) |
|---|---|---|---|
| Texto | `#EDF2F5` | `#1B1F24` | 14,2:1 · 14,8:1 |
| Secundario | `#99A6AD` | `#58606A` | 6,4:1 · 5,7:1 |
| Acento (acciones, sesión) | `#38A169` | `#137345` | 10,9:1 · 5,3:1 |
| Aviso | `#FAC74D` | `#8C5200` | 10,1:1 · 5,7:1 |
| Destructivo | `#FF8080` | `#BF2626` | 6,6:1 · 5,3:1 |
| Borde de campo | blanco 36 % | negro 42 % | 3,3:1 · 3,0:1 (mínimo para controles: 3:1) |
| Texto sobre el acento | fondo | blanco | 13,0:1 · 5,9:1 |

Con «Aumentar contraste», todos los textos superan 7,4:1 y los bordes de campo 7:1. Los colores de categoría, que
cada uno elige, se aclaran u oscurecen al usarse como texto hasta llegar a 4,8:1.

## Notas de oficio

- **Punto de vista.** La cuenta atrás es la firma, y la paleta silenciosa a su alrededor la deja ser lo único que
  grita. El lema «Menos ruido. Más foco.» cuadra con eso.
- **¿Plantilla?** El fondo casi negro con un único acento verde se parece a uno de los tres estilos genéricos que la
  skill señala. Aquí tiene una razón de producto (concentración), y con el modo claro deja de ser lo único que
  hay, así que no se ha tocado la identidad.
- **Una cosa que quitar:** la etiqueta «RESTANTE» bajo la cuenta atrás ya la dice el anillo; se mantiene por
  VoiceOver y por quien no lea el anillo. Queda como decisión de Luis.

## Lo que funciona y hay que conservar

- Una sola sesión a la vez, con relevo explícito: coherente con «ahora, solo esto».
- Los avisos de sistema con acciones (Empezar, Posponer, Reanudar) para no tener que abrir la ventana.
- Las tarjetas de sesión, el anillo y el panel de la barra: la misma información en tres tamaños.

## Notas de plataforma

- **Atajos con ⌃.** `keyboards.md` desaconseja Control como modificador. Se mantiene en ⌃⌥⌘ a sabiendas: son
  atajos globales, que tienen que funcionar con cualquier app delante sin pisar los atajos de esa app, y tres
  modificadores es lo que evita choques. Es un compromiso con nombre, no un descuido.
- **Panel de la barra.** `the-menu-bar.md` prefiere un menú a un popover en los iconos de la barra «unless the app
  functionality you want to expose is too complex for a menu». Aquí hay una cuenta atrás en vivo y un campo para
  apuntar tareas, que un menú no puede alojar bien; se mantiene el popover.

## Sin comprobar

- Con VoiceOver activado de verdad, ni con «Aumentar contraste» real del sistema: las capturas fuerzan la
  apariencia, pero nadie ha escuchado la app con el lector de pantalla.
- La navegación con teclado de la agenda: está programada y su lógica comprobada, pero sin pulsar teclas reales.
