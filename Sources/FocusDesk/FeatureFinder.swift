import AppKit
import FocusCore
import SwiftUI

// «Buscar función» (⌘K) and «Novedades»: two ways in to everything FocusDesk can do, so a feature is never lost just
// because its page was not open. Every entry lands where the feature lives; nothing here is a second copy of it.

// MARK: - The catalogue

struct FeatureEntry: Identifiable {
    let id: String
    let group: String
    let icon: String
    let title: String
    let detail: String
    /// Where the feature lives, or its shortcut.
    let location: String
    /// Other words people may type for it.
    let keywords: String
    let run: @MainActor (AppModel) -> Void
}

@MainActor
enum FeatureCatalog {
    static func entries(for model: AppModel) -> [FeatureEntry] {
        var all: [FeatureEntry] = []
        func add(_ group: String, _ icon: String, _ title: String, _ detail: String, _ location: String, _ keywords: String = "",
                 _ run: @escaping @MainActor (AppModel) -> Void) {
            all.append(FeatureEntry(id: group + "|" + title, group: group, icon: icon, title: title, detail: detail,
                                    location: location, keywords: keywords, run: run))
        }
        func page(_ target: AppPage) -> @MainActor (AppModel) -> Void { { $0.go(to: target) } }
        func settings(_ pane: SettingsSectionTab) -> @MainActor (AppModel) -> Void { { $0.showSettings?(pane) } }

        // Agenda
        add("Agenda", "plus", "Nueva tarea", "Planifica algo con hora y duración", "⌘N", "crear tarea planificar") { $0.editingTask = $0.newTaskDraft() }
        add("Agenda", AppPage.today.icon, "Hoy", "Tu siguiente paso y la agenda del día", "⌘1", "dia agenda inicio", page(.today))
        add("Agenda", AppPage.week.icon, "Semana", "Arrastra tareas entre días", "⌘2", "calendario", page(.week))
        add("Agenda", AppPage.history.icon, "Historial de sesiones", "Lo que has trabajado y sus notas", "⌘3", "sesiones pasado") {
            $0.historyShowsAudit = false
            $0.go(to: .history)
        }
        if let next = model.next, model.session == nil {
            add("Agenda", "play.fill", "Empezar «\(next.title)»", "La siguiente tarea de tu agenda", "⌃⌥⌘S", "empezar siguiente tarea") { $0.start(next) }
        }

        // Session
        if let session = model.session, session.endedAt == nil {
            add("Sesión", session.paused ? "play.fill" : "pause.fill", session.paused ? "Reanudar la sesión" : "Pausar la sesión",
                session.task.title, "⌃⌥⌘P", "pausa pausar reanudar") { $0.session?.paused == true ? $0.resume() : $0.pause() }
            add("Sesión", "checkmark", "He terminado", session.task.title, "⌃⌥⌘T", "terminar acabar sesion") { $0.finish() }
            add("Sesión", "plus", "Ampliar 10 minutos", session.task.title, "⌃⌥⌘A", "mas tiempo alargar") { $0.addTime() }
        }

        // Antidistracción
        add("Antidistracción", AppPage.blocking.icon, "Bloquear ahora", "Bloqueo rápido de 15 min al resto del día", "⌘4",
            "bloqueo rapido cuenta atras temporizador distracciones", page(.blocking))
        add("Antidistracción", "play.fill", "Bloquear 30 minutos ya", "\(model.quickBlockPreset?.label ?? "Redes y Shorts") · \(model.quickBlockProtection.label)",
            "⌃⌥⌘B", "bloquear ya media hora") { $0.startQuickBlockWithSavedChoice(minutes: 30) }
        add("Antidistracción", "clock.badge.checkmark", "Permitir una web unos minutos", "Una excepción que caduca sola", "Bloquear ahora",
            "excepcion temporal permitir dominio web", page(.blocking))
        add("Antidistracción", AppPage.rules.icon, "Reglas y límites", "Todas tus reglas y presupuestos", "⌘5", "reglas limites generales", page(.rules))
        for kind in GeneralRuleKind.galleryOrder {
            add("Antidistracción", kind.icon, "Nueva regla: \(kind.galleryTitle)", kind.galleryExample, "Reglas y límites",
                kind.label + " " + kind.shortLabel) { $0.openRuleTemplate(kind) }
        }
        for rule in model.workspace.generalRules {
            add("Tus reglas", rule.kind.icon, rule.name, "\(rule.kind.galleryTitle) · \(model.liveSummary(for: rule))", "Editar",
                "regla \(rule.kind.shortLabel)") { $0.editingGeneralRule = rule }
            if rule.kind == .pomodoro, (rule.activePomodoroDeadline?.remainingAfterPossibleReboot(wall: model.now) ?? 0) > 0 {
                add("Tus reglas", "forward.end", "Saltar fase de «\(rule.name)»", model.liveSummary(for: rule), "Pomodoro", "pomodoro fase saltar") {
                    $0.skipPomodoroPhase(rule)
                }
            }
            if model.canStartMicroPause(for: rule, at: model.now) {
                add("Tus reglas", "cup.and.saucer", "Micro-pausa de «\(rule.name)»",
                    "\(model.remainingMicroPausesToday(for: rule, at: model.now)) disponibles hoy · \(rule.microPauseMinutes) min", "Descansos",
                    "micropausa pausa soltar") { $0.startMicroPause(for: rule) }
            }
        }
        add("Antidistracción", "square.and.arrow.down", "Importar reglas", "Plantillas guardadas en un archivo JSON", "Reglas y límites",
            "importar json plantilla") { $0.importGeneralRules() }
        if !model.workspace.generalRules.isEmpty {
            add("Antidistracción", "square.and.arrow.up", "Exportar reglas", "Guarda tus reglas en un archivo JSON", "Reglas y límites",
                "exportar json copia plantilla") { $0.exportGeneralRules() }
        }
        add("Antidistracción", "list.bullet.rectangle", "Listas blancas y negras, subrutas y títulos",
            "Dentro de cada regla o tarea, en «Qué bloquea»", "Editor de regla", "lista blanca negra permitir solo subruta titulo ventana", page(.rules))
        add("Antidistracción", "asterisk", "Comodines y /regex/", "Escribe * ? o /expresión/ en «Qué bloquea»", "Editor de regla",
            "regex expresion regular comodin palabra completa", page(.rules))
        add("Antidistracción", "photo.on.rectangle", "Vídeos e imágenes en buscadores", "Pestañas de Google, Bing, DuckDuckGo…", "Editor de regla",
            "buscadores google imagenes videos", page(.rules))
        add("Antidistracción", "gamecontroller", "Bibliotecas de juegos", "Steam, Epic, Battle.net, Riot…", "Editor de regla",
            "juegos steam epic", page(.rules))
        add("Antidistracción", "lock.shield", "Proteger una tarea", "Código, espera o hasta el final, al editar la tarea", "Editor de tarea",
            "proteccion codigo espera desbloqueo") { $0.go(to: .today) }
        add("Agenda", "clock.arrow.2.circlepath", "Pomodoro dentro de una tarea", "Foco y descansos en la misma tarea, al editarla",
            "Editor de tarea", "pomodoro descanso foco ciclos") { $0.editingTask = $0.newTaskDraft() }
        add("Antidistracción", "folder.badge.minus", "Carpetas que distraen", "Series o descargas que se cierran durante una tarea", "Editor de tarea",
            "carpeta finder") { $0.go(to: .today) }

        // Descansos
        add("Descansos", AppPage.breaks.icon, "Descansos", "Pausas por uso continuo, micro-pausas y Pomodoro", "⌘6", "descanso pausa", page(.breaks))
        add("Descansos", "cup.and.saucer.fill", "Descansar ahora", "\(model.workspace.settings.continuousBreakDurationMinutes) min para la vista y estirar",
            "Descansos", "descanso pausa ahora") { $0.startContinuousBreakNow() }
        add("Descansos", "figure.walk", "Descanso tras uso continuo",
            model.workspace.settings.continuousBreakEnabled ? "Activado · cada \(model.workspace.settings.continuousWorkMinutes) min" : "Desactivado",
            "Descansos", "continuo uso vista estirar", page(.breaks))
        add("Descansos", "calendar.day.timeline.left", "Descansos habituales", "Comida, paseo… con aviso y cuenta atrás", "Descansos",
            "comida habitual descanso fijo", page(.breaks))

        // Historial
        add("Historial", "list.clipboard", "Registro de bloqueo", "Desbloqueos y cambios en tus reglas", "Historial",
            "auditoria registro log cambios desbloqueos") { $0.showAuditLog() }

        // Ajustes that change how blocking behaves sit next to the blocks; the rest open their pane.
        add("Ajustes", "capsule", "Píldora flotante con la cuenta atrás", "La cuenta atrás siempre a la vista", "Bloquear ahora",
            "pildora hud flotante contador", page(.blocking))
        add("Ajustes", "bell.badge", "Avisos a 5 y 1 min del final", "Antes de que se acabe un presupuesto o visita", "Bloquear ahora",
            "avisos notificaciones minutos", page(.blocking))
        add("Ajustes", "doc.on.clipboard", "Vaciar el portapapeles mientras bloquea", "Si copias algo bloqueado", "Bloquear ahora",
            "portapapeles copiar pegar", page(.blocking))
        add("Ajustes", "clock.arrow.circlepath", "Proteger el historial mientras bloquea", "Que no se pueda borrar en caliente", "Bloquear ahora",
            "historial borrar proteger", page(.blocking))
        add("Ajustes", "moon.zzz", "Corte de día", "A qué hora empieza tu día para los límites diarios", "Ajustes › Agenda",
            "medianoche hora reinicio dia", settings(.schedule))
        add("Ajustes", "bookmark.square", "Perfiles reutilizables", "Apps, webs y checklist en un clic", "Ajustes › Agenda", "perfil plantilla", settings(.schedule))
        add("Ajustes", "paintpalette", "Categorías y colores", "Las áreas de tus tareas", "Ajustes › Agenda", "categoria color area", settings(.schedule))
        add("Ajustes", "lock.shield", "Proteger una tarea antes de empezar", "Desde unos minutos antes de su hora", "Ajustes › General",
            "antes empezar margen", settings(.general))
        add("Ajustes", "moon.fill", "No molestar al bloquear apps", "Concentración de macOS durante las tareas estrictas", "Ajustes › General",
            "no molestar concentracion focus", settings(.general))
        add("Ajustes", "textformat.size", "Tamaño del texto", "Normal, grande o muy grande", "Ajustes › General", "letra fuente accesibilidad", settings(.general))
        add("Ajustes", "keyboard", "Atajo global", "Abrir FocusDesk desde cualquier app", "Ajustes › General", "atajo teclado global", settings(.general))
        add("Ajustes", "menubar.rectangle", "Contador en la barra de menús", "Mostrar u ocultar el tiempo arriba", "Ajustes › General",
            "barra menus contador", settings(.general))
        add("Ajustes", "macwindow.on.rectangle", "Vigilar ventanas de fondo", "Vídeos en otra pantalla o una esquina", "Ajustes › Privacidad",
            "ventanas fondo segundo monitor", settings(.privacy))
        add("Ajustes", "app.connected.to.app.below.fill", "Webs dentro de otras apps", "Discord, Slack, Notion y webs instaladas", "Ajustes › Privacidad",
            "pwa electron incrustada", settings(.privacy))
        add("Ajustes", "hand.raised", "Qué puede observar FocusDesk", "Títulos de ventana, dominios y exclusiones", "Ajustes › Privacidad",
            "privacidad titulos dominio", settings(.privacy))
        add("Ajustes", "arrow.clockwise.circle", "Volver a abrirse si la cierran", "Durante una sesión protegida", "Ajustes › Privacidad",
            "vigilante relanzar forzar cierre", settings(.privacy))
        add("Ajustes", "calendar.badge.clock", "Calendar y avisos", "Sincronización y notificaciones", "Ajustes › Conexiones",
            "calendario eventos notificaciones", settings(.connections))
        add("Ajustes", "internaldrive", "Datos y copias de seguridad", "Exportar, importar y recuperar", "Ajustes › Datos",
            "copia backup restaurar", settings(.data))

        // Ayuda
        add("Ayuda", "sparkle", "Novedades de FocusDesk", "Lo nuevo, con «Probar» para cada cosa", "Ayuda", "nuevo tutorial guia") { $0.showWhatsNew = true }
        add("Ayuda", "command", "Atajos de teclado", "Todos los atajos de FocusDesk", "Ayuda", "teclado shortcuts") { $0.showShortcutsHelp?() }
        return all
    }

    /// Every word typed has to appear somewhere in the entry, ignoring case and accents.
    static func search(_ query: String, in entries: [FeatureEntry]) -> [FeatureEntry] {
        let words = fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return entries }
        let scored: [(FeatureEntry, Int)] = entries.compactMap { entry in
            let title = fold(entry.title)
            let haystack = title + " " + fold(entry.detail + " " + entry.location + " " + entry.keywords + " " + entry.group)
            guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
            // Title matches first, then the rest in catalogue order.
            return (entry, words.allSatisfy { title.contains($0) } ? 0 : 1)
        }
        return scored.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
    }
}

// MARK: - ⌘K

struct FeatureFinderSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let results = FeatureCatalog.search(query, in: FeatureCatalog.entries(for: model))
        let total = FeatureCatalog.entries(for: model).count
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.app(16)).foregroundStyle(Palette.muted)
                TextField("Busca una función o un ajuste: pomodoro, portapapeles, regex…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.app(16))
                    .focused($fieldFocused)
                    .onSubmit { run(results) }
                    .onChange(of: query) { _, _ in selection = 0 }
                    .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                    .accessibilityLabel("Buscar función")
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.focus(.ghost, compact: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Rectangle().fill(Palette.stroke).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if results.isEmpty {
                            Text("Nada con «\(query)». Prueba con otra palabra, como «bloquear», «descanso» o «web».")
                                .font(.app(13))
                                .foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            if index == 0 || results[index - 1].group != entry.group {
                                Text(entry.group.uppercased())
                                    .font(.app(9, weight: .bold))
                                    .tracking(1.2)
                                    .foregroundStyle(Palette.muted)
                                    .padding(.horizontal, 10)
                                    .padding(.top, index == 0 ? 6 : 12)
                                    .padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            row(entry, selected: index == selection) {
                                selection = index
                                run(results)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, value in
                    guard results.indices.contains(value) else { return }
                    proxy.scrollTo(results[value].id, anchor: .center)
                }
            }

            Rectangle().fill(Palette.stroke).frame(height: 1)
            HStack(spacing: 14) {
                Text("↑↓ elegir")
                Text("↩ abrir")
                Text("esc cerrar")
                Spacer()
                Text(query.isEmpty ? "\(total) funciones y ajustes" : "\(results.count) de \(total)")
            }
            .font(.app(11))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .frame(width: 640, height: 540)
        .background(Palette.surface)
        .tint(Palette.mint)
        .onAppear { fieldFocused = true }
    }

    private func row(_ entry: FeatureEntry, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: entry.icon)
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Palette.mint)
                    .frame(width: 28, height: 28)
                    .background(Palette.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.app(13, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    Text(entry.detail).font(.app(11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(entry.location).font(.app(11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Palette.mint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.title). \(entry.detail). \(entry.location)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(_ step: Int, in results: [FeatureEntry]) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + step), results.count - 1)
    }

    /// Closes first: most entries open another sheet or a panel, and two sheets cannot be up at once.
    private func run(_ results: [FeatureEntry]) {
        guard results.indices.contains(selection) else { return }
        let entry = results[selection]
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            entry.run(model)
        }
    }
}

// MARK: - Novedades

enum WhatsNew {
    /// Bump when a release adds something worth showing; the sheet then appears once on the next launch.
    static let release = "2026-10-antidistraccion"
    private static let key = "FocusDesk.whatsNewSeen"

    static var pending: Bool { UserDefaults.standard.string(forKey: key) != release }
    static func markSeen() { UserDefaults.standard.set(release, forKey: key) }
}

struct WhatsNewSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct Area: Identifiable {
        let page: AppPage
        let items: [String]
        var id: String { page.rawValue }
    }

    private let areas = [
        Area(page: .blocking, items: ["Bloqueo en 1 clic: de 15 min al resto del día", "Permitir una web unos minutos", "Píldora flotante con la cuenta atrás"]),
        Area(page: .rules, items: ["Presupuesto: 20 min de Shorts al día", "Pomodoro que se reinicia si te distraes", "Primero el trabajo, luego el ocio",
                                   "Visitas contadas con enfriamiento", "Horarios de varios tramos"]),
        Area(page: .breaks, items: ["Un descanso tras mucho rato seguido", "Micro-pausas contadas en tus reglas", "Los descansos del Pomodoro, a la vista"]),
    ]

    private let extras = ["Listas blancas y negras", "Subrutas como youtube.com/shorts", "Comodines * ? y /regex/", "Vídeos e imágenes en buscadores",
                          "Bibliotecas de juegos", "Portapapeles vigilado", "Firefox y Zen", "Registro de cambios en Historial"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkle")
                    .font(.app(18, weight: .semibold))
                    .foregroundStyle(Palette.mint)
                    .frame(width: 40, height: 40)
                    .background(Palette.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("NOVEDADES").font(.app(10, weight: .bold)).tracking(1.4).foregroundStyle(Palette.mint)
                    Text("FocusDesk ahora también te protege fuera de las tareas")
                        .font(.app(22, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Lo nuevo vive en Antidistracción, en la barra lateral. Pulsa «Probar» y te llevo a cada cosa.")
                        .font(.app(13))
                        .foregroundStyle(Palette.muted)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(areas) { area in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: area.page.icon).foregroundStyle(Palette.mint)
                            Text(area.page.rawValue).font(.app(14, weight: .semibold))
                            Spacer(minLength: 4)
                            KeyHint(area.page.shortcut)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(area.items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(Palette.mint)
                                    Text(item).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.app(12))
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Probar") { open(area.page) }
                            .buttonStyle(.focus(.secondary, compact: true))
                            .accessibilityLabel("Probar \(area.page.rawValue)")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Y dentro de cada regla o tarea, en «Qué bloquea»:").font(.app(11)).foregroundStyle(Palette.muted)
                FlowChips(items: extras)
            }

            Rectangle().fill(Palette.stroke).frame(height: 1)
            HStack(spacing: 10) {
                Text("Para volver a verlo: Ayuda › Novedades, o busca cualquier función con ⌘K.")
                    .font(.app(11))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button("Ahora no") { dismiss() }
                    .buttonStyle(.focusSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Empezar por Bloquear ahora") { open(.blocking) }
                    .buttonStyle(FocusPrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 820)
        .background(Palette.surface)
        .tint(Palette.mint)
    }

    private func open(_ page: AppPage) {
        // The demo run shares the real app's preferences: it must not use up the real first showing.
        if !model.preview { WhatsNew.markSeen() }
        model.go(to: page)
        dismiss()
    }
}

/// Chips that wrap onto as many lines as they need.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.app(11))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Palette.fill, in: Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows.removeLast()
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows.append(row)
        }
        return rows
    }
}
