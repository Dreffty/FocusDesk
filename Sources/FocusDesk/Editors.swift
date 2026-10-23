import AppKit
import FocusCore
import ServiceManagement
import SwiftUI

struct TaskEditor: View {
    @ObservedObject var model: AppModel
    @State var draft: FocusTask
    @Environment(\.dismiss) private var dismiss
    @State private var folderWarning: String?
    @State private var saveProfileName = ""
    @State private var showSaveProfile = false
    @State private var editSingleOccurrenceOnly = false
    /// The date the editor was opened with. The occurrence to detach is this one even if the user moves it.
    @State private var originalOccurrenceDate: Date?
    @State private var seriesKind: AppModel.SeriesEditKind = .notInSeries
    /// The title gets the cursor when the editor opens; the checklist hands focus on with Tab.
    @FocusState private var focusedField: EditorField?
    private enum EditorField: Hashable { case title, profileName, checklist }

    private var belongsToSeries: Bool { seriesKind != .notInSeries }

    private var domainParse: (valid: [String], invalid: [String]) {
        FocusRules.parseDomains(draft.domains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dale un espacio.").font(.app(26, weight: .semibold, design: .rounded))
                    Text("Un objetivo claro. Un tiempo concreto.").font(.app(12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(FocusIconButtonStyle(size: 30))
                    .help("Cerrar")
                    .accessibilityLabel("Cerrar")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Reusable Profiles (Item 9)
                    Card(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("Perfiles y plantillas reutilizables", icon: "bookmark.fill") {
                                Button {
                                    saveProfileName = draft.title.isEmpty ? "Nuevo perfil" : draft.title
                                    showSaveProfile.toggle()
                                } label: {
                                    Label(showSaveProfile ? "Ocultar" : "Guardar como perfil", systemImage: "bookmark.badge.plus")
                                }
                                .buttonStyle(.focus(.ghost, compact: true))
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(model.workspace.profiles) { profile in
                                        Button {
                                            applyProfile(profile)
                                        } label: {
                                            HStack(spacing: 5) {
                                                Circle()
                                                    .fill(Palette.category(profile.category, in: model.workspace.settings.categories))
                                                    .frame(width: 6, height: 6)
                                                Text(profile.name)
                                                Text("\(profile.minutes)m").opacity(0.75)
                                            }
                                        }
                                        .buttonStyle(SelectableChipStyle(selected: draft.profileID == profile.id))
                                    }
                                }
                            }
                            if showSaveProfile {
                                HStack(spacing: 8) {
                                    // Return here saves the profile, not the whole task (it used to close the editor).
                                    TextField("Nombre del perfil (ej. Grabar vídeo)", text: $saveProfileName)
                                        .textFieldStyle(.roundedBorder)
                                        .focused($focusedField, equals: .profileName)
                                        .onSubmit { saveDraftAsProfile() }
                                    Button("Guardar perfil") { saveDraftAsProfile() }
                                        .buttonStyle(FocusPrimaryButton(compact: true))
                                }
                            }
                        }
                    }

                    if belongsToSeries {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Image(systemName: "repeat.circle").foregroundStyle(Palette.mint)
                                Picker("Cambio en tarea repetitiva", selection: $editSingleOccurrenceOnly) {
                                    Text("Editar toda la serie").tag(false)
                                    Text("Editar solo esta ocurrencia (\((originalOccurrenceDate ?? draft.scheduledAt).formatted(date: .abbreviated, time: .omitted)))").tag(true)
                                }.pickerStyle(.segmented)
                            }
                            Text(seriesHint).font(.app(10)).foregroundStyle(Palette.muted)
                        }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // Objective & Schedule (Items 10, 11, 12)
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("¿QUÉ VAS A HACER?").fieldLabelStyle()
                                TextField("Ej. Grabar el vídeo de mañana", text: $draft.title)
                                    .font(.app(15))
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .title)
                            }

                            HStack {
                                Toggle("Reservar horario en la agenda", isOn: $draft.isScheduled).toggleStyle(.switch)
                                Spacer()
                                if draft.isScheduled {
                                    Toggle("Cita fija (no desplazar)", isOn: $draft.isFixedAppointment)
                                        .toggleStyle(.checkbox)
                                        .font(.app(10))
                                        .foregroundStyle(Palette.muted)
                                } else {
                                    Chip("Bandeja de pendientes sin hora", icon: "tray", color: Palette.mint)
                                }
                            }

                            HStack(alignment: .top, spacing: 18) {
                                if draft.isScheduled {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("CUÁNDO EMPIEZA").fieldLabelStyle()
                                        DatePicker("Inicio", selection: $draft.scheduledAt).labelsHidden()
                                        HStack(spacing: 6) {
                                            Button("Ahora +10m") { draft.scheduledAt = Date().addingTimeInterval(600) }
                                                .buttonStyle(.focus(.secondary, compact: true))
                                            // From the time already chosen: on a task for tomorrow it used to jump to today.
                                            Button("+1h") { draft.scheduledAt = draft.scheduledAt.addingTimeInterval(3600) }
                                                .buttonStyle(.focus(.ghost, compact: true))
                                        }
                                    }
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("FECHA LÍMITE · OPCIONAL").fieldLabelStyle()
                                    HStack {
                                        Toggle("Antes de", isOn: Binding(
                                            get: { draft.dueDate != nil },
                                            set: { enabled in
                                                draft.dueDate = enabled ? (Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date().addingTimeInterval(86400)) : nil
                                            }
                                        )).labelsHidden()
                                        if let due = draft.dueDate {
                                            DatePicker("Fecha límite", selection: Binding(
                                                get: { due },
                                                set: { draft.dueDate = $0 }
                                            ), displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                                            if draft.isScheduled && due < draft.end {
                                                Chip("Termina después de su límite", icon: "exclamationmark.triangle.fill", color: Palette.warning)
                                            }
                                        } else {
                                            Text("Sin fecha límite").font(.app(10)).foregroundStyle(Palette.muted)
                                        }
                                    }
                                }
                                Spacer()
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("DURACIÓN").fieldLabelStyle()
                                    // Same range and steps as every other duration control (it went 5 → 1 → 6 → 11 before).
                                    Stepper("\(draft.minutes) min", value: $draft.minutes, in: FocusRules.minutesRange, step: 5)
                                    HStack(spacing: 6) {
                                        ForEach([15, 30, 60, 90], id: \.self) { minutes in
                                            Button("\(minutes)m") { draft.minutes = minutes }
                                                .buttonStyle(SelectableChipStyle(selected: draft.minutes == minutes))
                                                .accessibilityLabel("\(minutes) minutos")
                                        }
                                    }
                                    .fixedSize()
                                }
                            }

                            Divider().overlay(Palette.stroke)

                            HStack(spacing: 20) {
                                Picker("Área", selection: $draft.category) {
                                    let names = model.workspace.settings.categories.map(\.name)
                                    ForEach(names.contains(draft.category) ? names : names + [draft.category], id: \.self) { Text($0) }
                                }
                                if draft.isScheduled {
                                    Picker("Repetición", selection: $draft.repeatRule) {
                                        ForEach(RepeatRule.allCases, id: \.self) { Text($0.label).tag($0) }
                                    }
                                }
                            }

                            if draft.isScheduled && draft.repeatRule == .customDays {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("DÍAS DE LA SEMANA").fieldLabelStyle()
                                    HStack(spacing: 6) {
                                        ForEach([(2, "Lun"), (3, "Mar"), (4, "Mié"), (5, "Jue"), (6, "Vie"), (7, "Sáb"), (1, "Dom")], id: \.0) { day, label in
                                            let active = draft.repeatDays.contains(day)
                                            Button(label) {
                                                if active { draft.repeatDays.remove(day) } else { draft.repeatDays.insert(day) }
                                            }
                                            .buttonStyle(SelectableChipStyle(selected: active))
                                            .accessibilityLabel(fullDayNameFor(day))
                                        }
                                    }
                                    if draft.repeatDays.isEmpty {
                                        Text("Selecciona al menos un día para la repetición.").font(.app(10)).foregroundStyle(Palette.warning)
                                    }
                                }
                            }

                            if draft.isScheduled {
                                Toggle("Empezar sola a su hora", isOn: $draft.autoStart)
                                    .toggleStyle(.switch)
                                    .help("Si el Mac está desbloqueado y no hay otra sesión en marcha, la sesión empieza sola a la hora prevista.")
                            }

                            if draft.isScheduled {
                                HStack {
                                    Stepper("Avisar \(draft.leadMinutes) minutos antes", value: $draft.leadMinutes, in: 0...60, step: 5)
                                    Spacer()
                                    if model.workspace.tasks.contains(where: { FocusRules.overlaps(draft, $0) }) {
                                        Chip("Coincide con otra tarea", icon: "exclamationmark.triangle", color: Palette.warning)
                                    }
                                }
                            }

                            if draft.minutes > 60 {
                                Text("Vorssaint mostrará el final solo durante los últimos 60 minutos. El contador de FocusDesk seguirá visible.").font(.app(10)).foregroundStyle(Palette.muted)
                            }
                        }
                    }

                    // Workspace Apps & Domains
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("Tu espacio de trabajo", icon: "macwindow") {
                                Button { chooseApps() } label: { Label("Elegir apps", systemImage: "plus") }
                                    .buttonStyle(.focus(.secondary, compact: true))
                            }
                            if draft.apps.isEmpty {
                                Text("Sin selección: se admiten todas las apps. Añade las necesarias para distinguir distracciones.").font(.app(12)).foregroundStyle(Palette.muted)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                                    ForEach(draft.apps) { app in
                                        HStack(spacing: 8) {
                                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                                            Text(app.name).font(.app(10, weight: .medium)).lineLimit(1)
                                            Spacer(minLength: 4)
                                            Button {
                                                draft.apps.removeAll { $0.id == app.id }
                                            } label: {
                                                Image(systemName: "xmark")
                                            }
                                            .accessibilityLabel("Quitar \(app.name)")
                                            .help("Quitar \(app.name) de esta tarea")
                                            .buttonStyle(FocusIconButtonStyle(size: 20))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Palette.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    }
                                }
                            }
                            Toggle("Bloquear las apps que distraen", isOn: $draft.strict).toggleStyle(.switch)
                            Text("Si abres una app que no está en la lista, FocusDesk la oculta y te devuelve a una permitida\(model.workspace.settings.focusDuringStrict ? "; además pone No molestar mientras dura la sesión" : ""). \(draft.protection == .none ? "Puedes pausar en cualquier momento." : "Para parar antes de tiempo, lo que elijas abajo en «Si quieres dejarlo a medias».") Finder, Ajustes, FocusDesk, diálogos del sistema y Vorssaint siguen accesibles.").font(.app(10)).foregroundStyle(Palette.muted)
                            if draft.strict && draft.apps.isEmpty {
                                Text("Elige al menos una app permitida para poder bloquear las demás.").font(.app(10)).foregroundStyle(Palette.warning)
                            }

                            Divider().overlay(Palette.stroke)

                            // Domain Validation & Normalization (Item 15)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("DOMINIOS PARA ESTA TAREA · OPCIONAL").fieldLabelStyle()
                                    Spacer()
                                    if !draft.domains.isEmpty && FocusRules.normalizeDomains(draft.domains) != draft.domains {
                                        Button("Normalizar URLs") {
                                            draft.domains = FocusRules.normalizeDomains(draft.domains)
                                        }.buttonStyle(.focus(.ghost, compact: true))
                                    }
                                }
                                TextField("chatgpt.com, claude.ai (se aceptan URLs como https://claude.ai/)", text: $draft.domains)
                                    .textFieldStyle(.roundedBorder)
                                if !domainParse.invalid.isEmpty {
                                    Text("Entradas no reconocidas como dominio (se ignorarán): \(domainParse.invalid.joined(separator: ", "))")
                                        .font(.app(10))
                                        .foregroundStyle(Palette.warning)
                                } else if !domainParse.valid.isEmpty {
                                    Text("Dominios activos: \(domainParse.valid.joined(separator: ", "))")
                                        .font(.app(10))
                                        .foregroundStyle(Palette.mint)
                                }
                                Picker("Si abres otra web", selection: $draft.webBlockAction) {
                                    ForEach(WebBlockAction.allCases, id: \.self) { action in
                                        Text(action.label).tag(action)
                                    }
                                }
                                .pickerStyle(.radioGroup)
                                if draft.webBlockAction != .warn && domainParse.valid.isEmpty {
                                    Text("Para bloquear webs hace falta decir cuáles sí. Sin lista, se bloquearía todo.")
                                        .font(.app(10))
                                        .foregroundStyle(Palette.warning)
                                } else {
                                    Text(webHint).font(.app(10)).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    }

                    // How firmly this session defends itself
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("Si quieres dejarlo a medias", icon: "lock.shield")
                            Text("Lo decides ahora, con la cabeza fría, para el momento en que no la tengas.")
                                .font(.app(11))
                                .foregroundStyle(Palette.muted)
                            Picker("Protección", selection: $draft.protection) {
                                ForEach(SessionProtection.allCases, id: \.self) { level in
                                    Text(level.label).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Text(draft.protection.explanation).font(.app(11)).foregroundStyle(Palette.muted)

                            if draft.protection == .challenge {
                                Stepper("Código de \(draft.unlockChars) caracteres", value: $draft.unlockChars, in: UnlockChallenge.lengthRange, step: 4)
                                    .font(.app(12))
                                Text(draft.unlockChars >= 32 ? "Teclearlo cuesta cerca de un minuto. Suficiente para que se pase el impulso." : "Unos \(max(10, draft.unlockChars * 2)) segundos de teclear sin poder pegar.")
                                    .font(.app(10))
                                    .foregroundStyle(Palette.muted)
                            }
                            if draft.protection == .delay {
                                Stepper("Esperar \(draft.stopDelayMinutes) minutos", value: $draft.stopDelayMinutes, in: 1...60)
                                    .font(.app(12))
                                Text("La sesión sigue durante la espera: muchas veces se te pasan las ganas antes de que acabe.")
                                    .font(.app(10))
                                    .foregroundStyle(Palette.muted)
                            }
                            if draft.protection == .forced {
                                Text("Queda la salida de emergencia: 60 caracteres y una anotación en el historial. Úsala si de verdad pasa algo.")
                                    .font(.app(10))
                                    .foregroundStyle(Palette.warning)
                            }

                            if draft.strict {
                                Divider().overlay(Palette.stroke)
                                Text("QUÉ HACER CON LAS APPS QUE NO TOCAN").fieldLabelStyle()
                                Picker("Acción", selection: $draft.blockAction) {
                                    ForEach(AppBlockAction.allCases, id: \.self) { action in
                                        Text(action.label).tag(action)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                Text(draft.blockAction.explanation).font(.app(10)).foregroundStyle(Palette.muted)
                            }

                            Divider().overlay(Palette.stroke)
                            Toggle("Endurecer si insistes", isOn: $draft.punisherEnabled).toggleStyle(.switch)
                            Text("Tras cuatro intentos seguidos en pocos minutos, durante un rato FocusDesk cierra esas apps en vez de ocultarlas.")
                                .font(.app(10))
                                .foregroundStyle(Palette.muted)
                            Toggle("Proteger los ajustes que desarman el bloqueo", isOn: $draft.guardSystemPanes).toggleStyle(.switch)
                            Text("Cierra «Privacidad y seguridad», «Fecha y hora» y «Usuarios y grupos» mientras dura la sesión. El resto de Ajustes del Sistema sigue a mano.")
                                .font(.app(10))
                                .foregroundStyle(Palette.muted)
                        }
                    }

                    // Checklist & Output Folder
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("Cómo sabrás que has terminado", icon: "checkmark.circle")
                            Text("Checklist: un paso por línea").font(.app(10)).foregroundStyle(Palette.muted)
                            TextEditor(text: $draft.checklist)
                                .focused($focusedField, equals: .checklist)
                                // Tab moves on instead of typing a tab character; ⇧Tab goes back to the title.
                                .onKeyPress(.tab, phases: .down) { press in
                                    focusedField = press.modifiers.contains(.shift) ? .title : nil
                                    return .handled
                                }
                                .font(.app(13))
                                .frame(height: 76)
                                .accessibilityLabel("Checklist, un paso por línea")
                                .padding(6)
                                .background(Palette.elevated.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke))
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Carpeta de resultados").font(.app(12, weight: .medium))
                                    Text(draft.folder ?? "Opcional. Solo se comparan metadatos; también podrás adjuntar un archivo al terminar.")
                                        .font(.app(10))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button("Elegir carpeta…") { chooseFolder() }
                                    .buttonStyle(.focus(.secondary, compact: true))
                                if draft.folder != nil {
                                    Button("Quitar") { draft.folder = nil }
                                        .buttonStyle(.focus(.ghost, compact: true))
                                }
                            }
                            if let folderWarning { Text(folderWarning).font(.app(10)).foregroundStyle(Palette.warning) }
                        }
                    }
                }.padding(.trailing, 6)
            }

            HStack {
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.focusSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Guardar tarea") {
                    model.saveEdited(
                        draft,
                        originalOccurrenceDate: originalOccurrenceDate ?? draft.scheduledAt,
                        onlyThisOccurrence: belongsToSeries && editSingleOccurrenceOnly
                    )
                    if model.error == nil { dismiss() }
                }
                .buttonStyle(FocusPrimaryButton())
                .keyboardShortcut(focusedField == .profileName ? nil : .defaultAction)
                .disabled(!draft.valid || model.readOnly || model.busy)
            }
        }
        .padding(24)
        .frame(width: 700, height: min(780, (NSScreen.main?.visibleFrame.height ?? 820) - 70))
        .onAppear {
            focusedField = .title
            guard originalOccurrenceDate == nil else { return }
            originalOccurrenceDate = draft.scheduledAt
            seriesKind = model.seriesEditKind(for: draft)
            // Opened from one occurrence (a future one, or one already detached), the safe default is to change that
            // one only. Opened from the series itself, the default stays "toda la serie".
            switch seriesKind {
            case .projected, .detached: editSingleOccurrenceOnly = true
            case .head, .notInSeries: editSingleOccurrenceOnly = false
            }
        }
        .background(Palette.background)
        .tint(Palette.mint)
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !draft.apps.contains(where: { $0.id == id }) else { continue }
            draft.apps.append(AllowedApp(id: id, name: url.deletingPathExtension().lastPathComponent, path: url.path))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.folder = url.path
        folderWarning = "Elige una carpeta concreta del proyecto; se revisan como máximo 5.000 entradas ignorando temporales."
    }

    private func saveDraftAsProfile() {
        let name = saveProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let profile = FocusProfile(
            id: model.workspace.profiles.first(where: { $0.name.lowercased() == name.lowercased() })?.id ?? UUID(),
            name: name,
            category: draft.category,
            minutes: draft.minutes,
            leadMinutes: draft.leadMinutes,
            strict: draft.strict,
            apps: draft.apps,
            domains: draft.domains,
            folder: draft.folder,
            checklist: draft.checklist,
            autoStart: draft.autoStart
        )
        model.saveProfile(profile)
        draft.profileID = profile.id
        showSaveProfile = false
        focusedField = .title
    }

    private var webHint: String {
        switch draft.webBlockAction {
        case .warn:
            return "Solo se anota y se avisa; la página sigue abierta. Activa la lectura del navegador en Ajustes."
        case .redirect:
            return "Esa pestaña irá a una página de FocusDesk con el tiempo que queda. Las demás pestañas no se tocan."
        case .closeTab:
            return "Se cierra solo esa pestaña, como con ⌘W. El resto del navegador sigue igual."
        }
    }

    private var seriesHint: String {
        switch (seriesKind, editSingleOccurrenceOnly) {
        case (.detached, false):
            return "Los cambios de título, duración, apps y checklist pasan también a la serie. Su hora y su repetición no cambian."
        case (_, true):
            return "Solo cambia este día. El resto de la serie sigue igual."
        case (.projected, false):
            return "Cambia la serie entera. Si mueves la hora o el día, toda la serie se mueve igual; no empieza en este día."
        default:
            return "Cambia la serie entera a partir de su próxima ocurrencia."
        }
    }

    private func applyProfile(_ profile: FocusProfile) {
        draft.apply(profile)
        if draft.apps.isEmpty {
            let isVideo = profile.name.lowercased().contains("vídeo") || profile.name.lowercased().contains("video")
            let ids = isVideo ? ["com.lemon.lvoverseas", "com.brave.Browser", "com.anthropic.claudefordesktop", "com.openai.chat"] : ["com.brave.Browser"]
            draft.apps = ids.compactMap { id in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
                return AllowedApp(id: id, name: url.deletingPathExtension().lastPathComponent, path: url.path)
            }
        }
    }
}

struct CompletionView: View {
    @ObservedObject var model: AppModel
    @State private var note = ""
    @State private var transition: NextTransitionAction = .keepSchedule
    @State private var confirmCancel = false

    private var allEvidenceFiles: [String] {
        var combined = model.changedFiles
        for manual in model.manualAttachments where !combined.contains(manual) {
            combined.append(manual)
        }
        return combined
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.app(32, weight: .regular))
                    .foregroundStyle(Palette.mint)
                    .frame(width: 52, height: 52)
                    .background(Palette.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("¿Qué has conseguido?").font(.app(24, weight: .semibold, design: .rounded))
                    Text("La sesión ha terminado y las restricciones están desactivadas. Tú confirmas el resultado.")
                        .font(.app(12))
                        .foregroundStyle(Palette.muted)
                }
            }
            if let error = model.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).font(.app(10))
                    Spacer()
                    Button("Reintentar guardado") { _ = model.retrySave() }
                        .buttonStyle(.focus(.warning, compact: true))
                }.padding(10).foregroundStyle(Palette.danger).background(Palette.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if let s = model.session {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(s.task.title).font(.app(15, weight: .semibold))
                        HStack(spacing: 10) {
                            Chip("\(Int(s.accumulated / 60)) min de sesión", icon: "clock", color: Palette.mint)
                            Chip("\(s.interruptionCount) interrupciones", icon: "exclamationmark.bubble", color: s.interruptionCount == 0 ? Palette.mint : Palette.warning)
                            Chip("\(s.checked.count) \(s.checked.count == 1 ? "paso" : "pasos")", icon: "checklist")
                            Chip("\(model.selectedDeliverables.count)/\(allEvidenceFiles.count) entregables", icon: "doc.badge.checkmark", color: Palette.mint)
                        }
                    }
                }
            }
            // The steps can be ticked here too: work done in CapCut or Brave usually ends with "0 pasos" otherwise.
            if let s = model.session, !s.task.checklist.isEmpty {
                let steps = s.task.checklist.split(separator: "\n").map(String.init)
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Checklist · \(s.checked.count) de \(steps.count)", icon: "checklist")
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                        Toggle(text, isOn: Binding(
                            get: { model.session?.checked.contains(String(index)) == true },
                            set: { model.setCheck(String(index), value: $0) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            if let message = model.evidenceMessage {
                Text(message).font(.app(10)).foregroundStyle(Palette.warning)
            }

            // Evidence selection & manual attachment (Item 16)
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Evidencias y entregables", icon: "folder.badge.gearshape") {
                    Button { attachFileManually() } label: {
                        Label("Adjuntar archivo manualmente…", systemImage: "paperclip")
                    }
                    .buttonStyle(.focus(.secondary, compact: true))
                }
                if allEvidenceFiles.isEmpty {
                    Text("No se han detectado archivos nuevos en la carpeta. Puedes adjuntar el resultado manualmente o confirmar con una nota.")
                        .font(.app(10))
                        .foregroundStyle(Palette.muted)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(allEvidenceFiles.prefix(50), id: \.self) { path in
                                let isSelected = model.selectedDeliverables.contains(path)
                                let isManual = model.manualAttachments.contains(path)
                                let isWriting = model.writingFiles.contains(path)
                                HStack(spacing: 10) {
                                    // A real checkbox: VoiceOver says which file it is and whether it is ticked.
                                    Toggle(isOn: Binding(get: { isSelected }, set: { _ in model.toggleDeliverable(path) })) {
                                        Text("Entregable")
                                    }
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .accessibilityLabel("Entregable: \(URL(fileURLWithPath: path).lastPathComponent)")
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.app(10, weight: .medium)).lineLimit(1)
                                            Chip(isManual ? "Adjunto manual" : "Señal automática", color: isManual ? Palette.mint : Palette.muted)
                                            if isSelected {
                                                Chip("Resultado elegido", icon: "checkmark", color: Palette.mint)
                                            }
                                            if isWriting {
                                                Chip("Recién escrito (<2 s)", icon: "clock", color: Palette.warning)
                                            }
                                        }
                                        Text(path).font(.app(10)).foregroundStyle(Palette.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Mostrar") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                    }.buttonStyle(.focus(.ghost, compact: true))
                                    Button("Abrir") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                    }.buttonStyle(.focus(.secondary, compact: true))
                                }
                                .padding(8)
                                .background(Palette.surface.opacity(isSelected ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isSelected ? Palette.mint.opacity(0.35) : Palette.stroke, lineWidth: 1))
                            }
                        }
                    }.frame(maxHeight: 145)
                }
                Text("Señal automática ≠ trabajo demostrado: marca cuál corresponde al entregable real.").font(.app(10)).foregroundStyle(Palette.muted)
            }

            TextField("Resultado o próximo paso (opcional)", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            // Next Task Transition (Item 13). A task queued by an accepted hand-off is what the user asked for,
            // so it takes the slot and the picker already points at starting it.
            if let nextTask = model.queuedStartTask ?? model.next {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(
                            model.queuedStartTask != nil
                                ? "ESPERANDO PARA EMPEZAR: \(nextTask.title)"
                                : "SIGUIENTE TAREA SUGERIDA: \(nextTask.title)",
                            systemImage: "arrow.right.circle"
                        )
                            .font(.app(10, weight: .semibold))
                            .foregroundStyle(Palette.mint)
                        Spacer()
                        if nextTask.isScheduled {
                            Text(nextTask.scheduledAt.formatted(date: .omitted, time: .shortened) + (nextTask.isFixedAppointment ? " · Cita fija" : ""))
                                .font(.app(10))
                                .foregroundStyle(Palette.muted)
                        } else {
                            Text("Bandeja de pendientes").font(.app(10)).foregroundStyle(Palette.muted)
                        }
                    }
                    Picker("Al confirmar", selection: $transition) {
                        Text("Mantener su horario").tag(NextTransitionAction.keepSchedule)
                        Text("Empezar la siguiente").tag(NextTransitionAction.startNextNow)
                        Text("Descansar 10 min").tag(NextTransitionAction.rest10Min)
                    }.pickerStyle(.segmented)
                }
                .padding(12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onAppear { if model.queuedStartTask != nil { transition = .startNextNow } }
            }

            HStack(spacing: 10) {
                // Same question as the session controls: cancelling throws the session away.
                // Every label whole: buttons size to their text, the sheet is wide enough for all four.
                Button("Cancelar sesión") { confirmCancel = true }
                    .buttonStyle(.focusDestructive)
                    .fixedSize()
                Button("Volver a la sesión") { model.reopenSession() }
                    .buttonStyle(.focusGhost)
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)
                    .help("Deshace «He terminado» y sigue con el tiempo que te quedaba (Esc)")
                Spacer()
                Button("Sigue pendiente") {
                    model.confirm(completed: false, note: note, transition: transition)
                }
                .buttonStyle(.focusSecondary)
                .keyboardShortcut(.return, modifiers: .option)
                .help("Guardar la sesión sin dar la tarea por terminada (⌥↩)")
                .fixedSize()
                Button("Sí, he terminado") {
                    model.confirm(completed: true, note: note, transition: transition)
                }
                .buttonStyle(FocusPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .fixedSize()
            }
        }
        .padding(26)
        .frame(width: 720 + 160 * (TextScale.factor - 1))
        .background(Palette.background)
        .tint(Palette.mint)
        .interactiveDismissDisabled()
        .confirmationDialog(
            "¿Cancelar esta sesión? La tarea seguirá pendiente y la sesión quedará registrada como cancelada.",
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button("Cancelar sesión", role: .destructive) {
                model.cancelSession(note: note.isEmpty ? "Sesión cancelada al confirmar" : note)
            }
            Button("Volver", role: .cancel) {}
        }
    }

    private func attachFileManually() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.attachManualFile(url.path)
        }
    }
}

enum SettingsSectionTab: String, CaseIterable, Identifiable {
    /// The panes of the settings window, in toolbar order.
    static var panes: [SettingsSectionTab] { allCases.filter { $0 != .all } }

    case general = "General"
    case connections = "Conexiones y avisos"
    case schedule = "Agenda y perfiles"
    case privacy = "Privacidad"
    case data = "Datos y copias"
    case all = "Ver todo"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .connections: return "calendar.badge.clock"
        case .schedule: return "bookmark.square"
        case .privacy: return "hand.raised"
        case .data: return "internaldrive"
        case .all: return "rectangle.grid.1x2"
        }
    }
}

/// No molestar during the sessions that block apps, with the one-time setup of its two shortcuts.
private struct DoNotDisturbSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var focusMode: FocusModeController

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("No molestar al bloquear apps", icon: "moon.fill")
                Toggle("Poner No molestar en las tareas que bloquean apps", isOn: Binding(
                    get: { model.workspace.settings.focusDuringStrict },
                    set: { value in model.updateSettings { $0.focusDuringStrict = value } }
                ))
                .toggleStyle(.switch)
                Text("Se activa al empezar una tarea con «Bloquear las apps que distraen» y se quita al pausarla o terminarla. macOS no deja saber si ya lo tenías puesto: en ese caso también se quitará.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Chip(focusMode.ready == true ? "Atajos listos" : (focusMode.ready == false ? "Faltan los atajos" : "Comprobando…"),
                         icon: focusMode.ready == true ? "checkmark.circle.fill" : "exclamationmark.circle",
                         color: focusMode.ready == true ? Palette.mint : Palette.warning)
                    Spacer()
                    if focusMode.ready != true {
                        Button(focusMode.working ? "Preparando…" : "Crear los atajos…") { Task { await focusMode.prepareShortcuts() } }
                            .buttonStyle(FocusPrimaryButton(compact: true))
                            .disabled(focusMode.working || model.preview)
                    } else {
                        Button("Probar") { focusMode.test() }
                            .buttonStyle(.focus(.secondary, compact: true))
                            .disabled(model.session != nil || model.preview)
                            .help("Activa No molestar unos segundos y lo quita (sin una sesión en marcha)")
                    }
                    Button("Comprobar") { Task { await focusMode.refresh() } }
                        .buttonStyle(.focus(.ghost, compact: true))
                        .disabled(model.preview)
                }
                Text(focusMode.message)
                    .font(.app(10))
                    .foregroundStyle(focusMode.ready == true ? Palette.muted : Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Con No molestar, los avisos de FocusDesk (como «Tiempo previsto agotado») solo te llegan si la permites en No molestar.")
                        .font(.app(10))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Abrir Concentración") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.focus(.ghost, compact: true))
                }
            }
        }
    }
}

/// Full weekday names for VoiceOver ("Lun" is otherwise read letter by letter).
private func fullDayNameFor(_ weekday: Int) -> String {
    ["Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"][max(0, min(6, weekday - 1))]
}

/// One pane of the settings window.
struct SettingsPane: View {
    @ObservedObject var model: AppModel
    let section: SettingsSectionTab

    var body: some View {
        ScrollView {
            SettingsView(model: model, bridge: model.calendar, reminders: model.reminders, fixedSection: section)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
        .background(Palette.background)
        .tint(Palette.mint)
        .id(model.workspace.settings.textScale)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: CalendarBridge
    @ObservedObject var reminders: ReminderService
    /// The settings window shows one pane per toolbar item (`settings.md › Desktop`); nil keeps the in-page picker.
    var fixedSection: SettingsSectionTab? = nil
    @State private var selectedSection: SettingsSectionTab = .connections
    private var section: SettingsSectionTab { fixedSection ?? selectedSection }
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var eraseDetails = false
    @State private var newCategoryName = ""
    @State private var newCategoryColor = Color(red: 0.64, green: 0.89, blue: 0.73)
    @State private var newBreakTitle = "Descanso"
    @State private var newBreakHour = 14
    @State private var newBreakDuration = 30
    @State private var pendingImportURL: URL?
    @State private var pendingImportSummary = ""
    @State private var editingProfile: FocusProfile?
    @State private var profilePendingDeletion: FocusProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.preview {
                Text("Modo de prueba: las conexiones y permisos están desactivados.").foregroundStyle(Palette.warning)
            }

            // Quick section navigation bar so the user can move between settings without scrolling
            if fixedSection == nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SettingsSectionTab.allCases) { tab in
                        Button {
                            withAnimation(.easeOut(duration: 0.14)) { selectedSection = tab }
                        } label: {
                            Label(tab.rawValue, systemImage: tab.icon)
                        }
                        .buttonStyle(SelectableChipStyle(selected: selectedSection == tab))
                    }
                }
            }
            }

            if section == .general || section == .all {
                Card {
                    VStack(alignment: .leading, spacing: 15) {
                        SectionHeader("General", icon: "gearshape")
                        // macOS has no Dynamic Type, so the app offers its own text size (accessibility.md › Vision).
                        Picker("Tamaño del texto", selection: Binding(
                            get: { model.workspace.settings.textScale },
                            set: { value in model.updateSettings { $0.textScale = value } }
                        )) {
                            ForEach(TextScale.options, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        Text("Agranda todos los textos de FocusDesk, también el panel de la barra de menús.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                        Toggle("Mostrar el contador en la barra de menús", isOn: Binding(
                            get: { model.workspace.settings.showMenuBarItem },
                            set: { value in model.updateSettings { $0.showMenuBarItem = value } }
                        ))
                        .toggleStyle(.switch)
                        Text("Si lo ocultas, el tiempo sigue en el Dock y FocusDesk se abre con su atajo o desde el Dock.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                    }
                }
                DoNotDisturbSettings(model: model, focusMode: model.focusMode)
            }

            if section == .connections || section == .all {
                IntegrationView(model: model, bridge: bridge)

                // Notifications & Configurable Global Shortcut (Items 1 & 14)
                Card {
                    VStack(alignment: .leading, spacing: 15) {
                        SectionHeader("Recordatorios y acceso rápido", icon: "bell")
                        HStack {
                            Text(reminders.message).font(.app(12))
                            Spacer()
                            Button("Activar notificaciones") {
                                Task { await reminders.request(); model.schedule() }
                            }.buttonStyle(.focusSecondary)
                            if reminders.status == .denied {
                                Button("Abrir Ajustes de Notificaciones") {
                                    reminders.openSystemSettings()
                                }.buttonStyle(.focus(.warning))
                            }
                        }
                        Divider().overlay(Palette.stroke)
                        HStack {
                            Toggle("Atajo global para abrir FocusDesk", isOn: Binding(
                                get: { model.workspace.settings.hotKeyEnabled },
                                set: { v in model.updateSettings { $0.hotKeyEnabled = v } }
                            ))
                            Spacer()
                            Picker("Atajo", selection: Binding(
                                get: { model.workspace.settings.hotKeyLabel },
                                set: { label in
                                    if let preset = HotKeyPreset.presets.first(where: { $0.label == label }) {
                                        model.updateSettings {
                                            $0.hotKeyLabel = preset.label
                                            $0.hotKeyCode = preset.keyCode
                                            $0.hotKeyModifiers = preset.modifiers
                                        }
                                    }
                                }
                            )) {
                                ForEach(HotKeyPreset.presets) { preset in
                                    Text(preset.label).tag(preset.label)
                                }
                            }.frame(width: 200)
                        }
                        Picker("Al usar el atajo global", selection: Binding(
                            get: { model.workspace.settings.hotKeyTarget },
                            set: { target in model.updateSettings { $0.hotKeyTarget = target } }
                        )) {
                            ForEach(HotKeyTarget.allCases, id: \.self) { target in
                                Text(target.label).tag(target)
                            }
                        }.pickerStyle(.segmented)
                        Text("Atajos en la app: ⌘1–⌘3 Hoy, Semana, Historial · ⌘, Ajustes · ⌘[ / ⌘] Anterior y siguiente · ⌘T Hoy · ⌘N Nueva tarea · ⌘Z / ⇧⌘Z Deshacer y rehacer · ⌃⌥⌘P Pausar · ⌃⌥⌘T He terminado · ⌃⌥⌘A Ampliar 10 min")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                        Toggle("Abrir FocusDesk al iniciar sesión", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, value in
                            do {
                                if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                model.error = error.localizedDescription
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    }
                }
            }

            if section == .schedule || section == .all {
                // Reusable Profiles Management (Item 9)
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader("Perfiles de trabajo reutilizables", icon: "bookmark.square") {
                            Button {
                                editingProfile = FocusProfile(name: "Nuevo perfil")
                            } label: {
                                Label("Nuevo perfil", systemImage: "plus")
                            }
                            .buttonStyle(FocusPrimaryButton(compact: true))
                        }
                        Text("Guarda las apps permitidas, dominios, modo estricto, duración habitual, checklist y carpeta para aplicarlos en un clic.")
                            .font(.app(12))
                            .foregroundStyle(Palette.muted)
                        ForEach(model.workspace.profiles) { profile in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Palette.category(profile.category, in: model.workspace.settings.categories))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).fontWeight(.semibold)
                                    Text("\(profile.category) · \(profile.minutes) min · \(profile.strict ? "Bloquea apps" : "Solo avisa") · \(profile.apps.count) app(s)")
                                        .font(.app(10))
                                        .foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Button("Editar") { editingProfile = profile }
                                    .buttonStyle(.focus(.secondary, compact: true))
                                if model.workspace.profiles.count > 1 {
                                    // A profile carries apps, domains, folder and checklist: worth one question before it goes.
                                    Button {
                                        profilePendingDeletion = profile
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .accessibilityLabel("Borrar perfil \(profile.name)")
                                    .help("Borrar el perfil «\(profile.name)»")
                                    .buttonStyle(FocusIconButtonStyle(size: 26, tint: Palette.danger))
                                }
                            }
                            .padding(12)
                            .background(Palette.elevated.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }

                // Calendar Personalization: Categories, Workdays, Breaks (Item 10)
                Card {
                    VStack(alignment: .leading, spacing: 15) {
                        SectionHeader("Personalización de agenda y horario", icon: "calendar.day.timeline.left")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Días laborables").font(.app(12, weight: .medium))
                            HStack(spacing: 8) {
                                ForEach([(2, "Lun"), (3, "Mar"), (4, "Mié"), (5, "Jue"), (6, "Vie"), (7, "Sáb"), (1, "Dom")], id: \.0) { day, label in
                                    let active = model.workspace.settings.workdays.contains(day)
                                    Button(label) {
                                        model.updateSettings {
                                            if active { $0.workdays.remove(day) } else { $0.workdays.insert(day) }
                                        }
                                    }
                                    .buttonStyle(SelectableChipStyle(selected: active))
                                            .accessibilityLabel(fullDayNameFor(day))
                                }
                            }
                        }
                        HStack(spacing: 20) {
                            Stepper("Inicio jornada: \(model.workspace.settings.workStartHour):00", value: Binding(
                                get: { model.workspace.settings.workStartHour },
                                set: { v in model.updateSettings { $0.workStartHour = min(v, $0.workEndHour - 1) } }
                            ), in: 5...20)
                            Stepper("Fin jornada: \(model.workspace.settings.workEndHour):00", value: Binding(
                                get: { model.workspace.settings.workEndHour },
                                set: { v in model.updateSettings { $0.workEndHour = max(v, $0.workStartHour + 1) } }
                            ), in: 8...23)
                        }
                        Divider().overlay(Palette.stroke)
                        Text("Descansos habituales").font(.app(12, weight: .medium))
                        ForEach(model.workspace.settings.breaks) { brk in
                            HStack {
                                Chip("\(String(format: "%02d:%02d", brk.startHour, brk.startMinute)) · \(brk.durationMinutes) min", icon: "cup.and.saucer")
                                Text(brk.title).font(.app(12))
                                Spacer()
                                Button {
                                    model.updateSettings { $0.breaks.removeAll { b in b.id == brk.id } }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("Borrar descanso \(brk.title)")
                                .help("Borrar el descanso «\(brk.title)»")
                                .buttonStyle(FocusIconButtonStyle(size: 24, tint: Palette.danger))
                            }
                        }
                        HStack {
                            TextField("Descanso", text: $newBreakTitle).textFieldStyle(.roundedBorder).frame(width: 150)
                            Stepper("Hora: \(newBreakHour):00", value: $newBreakHour, in: 6...22)
                            Stepper("\(newBreakDuration) min", value: $newBreakDuration, in: 10...180, step: 10)
                            Button("Añadir descanso") {
                                let clean = newBreakTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !clean.isEmpty else { return }
                                model.updateSettings {
                                    $0.breaks.append(BreakPeriod(title: clean, startHour: newBreakHour, startMinute: 0, durationMinutes: newBreakDuration))
                                }
                            }.buttonStyle(.focus(.secondary, compact: true))
                        }
                        Divider().overlay(Palette.stroke)
                        Text("Categorías y colores").font(.app(12, weight: .medium))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                            ForEach(model.workspace.settings.categories) { cat in
                                HStack(spacing: 8) {
                                    Circle().fill(Color(red: cat.red, green: cat.green, blue: cat.blue)).frame(width: 12, height: 12)
                                    Text(cat.name).font(.app(10, weight: .medium))
                                    Spacer()
                                    if !["Personal", "Contenido", "Estudio", "Tienda"].contains(cat.name) {
                                        Button {
                                            model.updateSettings { $0.categories.removeAll { $0.name == cat.name } }
                                        } label: { Image(systemName: "xmark") }
                                        .buttonStyle(FocusIconButtonStyle(size: 22))
                                        .accessibilityLabel("Borrar categoría \(cat.name)")
                                        .help("Borrar la categoría «\(cat.name)»")
                                    }
                                }.padding(8).background(Palette.elevated.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        HStack {
                            TextField("Nueva categoría", text: $newCategoryName).textFieldStyle(.roundedBorder).frame(width: 180)
                            ColorPicker("Color de la categoría", selection: $newCategoryColor, supportsOpacity: false).labelsHidden()
                            Button("Añadir categoría") {
                                let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !name.isEmpty else { return }
                                let nsColor = NSColor(newCategoryColor).usingColorSpace(.sRGB) ?? NSColor.systemMint
                                let item = CategoryItem(
                                    name: name,
                                    red: Double(nsColor.redComponent),
                                    green: Double(nsColor.greenComponent),
                                    blue: Double(nsColor.blueComponent)
                                )
                                model.updateSettings {
                                    if let idx = $0.categories.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                                        $0.categories[idx] = item
                                    } else {
                                        $0.categories.append(item)
                                    }
                                }
                                newCategoryName = ""
                            }.buttonStyle(.focus(.secondary, compact: true))
                        }
                    }
                }
            }

            if section == .privacy || section == .all {
                // Privacy & Observation Controls (Items 15 & 17)
                Card {
                    VStack(alignment: .leading, spacing: 15) {
                        SectionHeader("Qué puede observar y controles de privacidad", icon: "hand.raised")
                        Text("Solo durante una sesión activa. No se registran teclas ni se capturan pantallas.").foregroundStyle(Palette.muted)
                        Toggle("Leer títulos de ventana", isOn: Binding(
                            get: { model.workspace.settings.observeTitles },
                            set: { value in model.updateSettings { $0.observeTitles = value } }
                        ))
                        HStack {
                            Chip(model.accessible ? "Accesibilidad concedida" : "Accesibilidad pendiente", icon: model.accessible ? "checkmark.circle.fill" : "circle", color: model.accessible ? Palette.mint : Palette.warning)
                            Spacer()
                            Button("Conceder Accesibilidad") { MacActivity.requestAccessibility() }
                                .buttonStyle(.focus(.secondary, compact: true))
                            Button("Ajustes de Accesibilidad") { MacActivity.openAccessibilitySettings() }
                                .buttonStyle(.focus(.ghost, compact: true))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Excluir aplicaciones de la lectura de títulos").font(.app(12, weight: .medium))
                                Spacer()
                                Button("Añadir app excluida…") { addExcludedTitleApp() }
                                    .buttonStyle(.focus(.secondary, compact: true))
                            }
                            if model.workspace.settings.excludedTitleApps.isEmpty {
                                Text("Ninguna app excluida. Añade gestores de contraseñas o mensajería si no quieres guardar sus títulos de ventana.")
                                    .font(.app(10))
                                    .foregroundStyle(Palette.muted)
                            } else {
                                ForEach(model.workspace.settings.excludedTitleApps) { app in
                                    HStack {
                                        Text(app.name).font(.app(10, weight: .medium))
                                        Spacer()
                                        Button {
                                            model.updateSettings { $0.excludedTitleApps.removeAll { a in a.id == app.id } }
                                        } label: { Image(systemName: "xmark") }
                                        .buttonStyle(FocusIconButtonStyle(size: 22))
                                        .accessibilityLabel("Quitar \(app.name) de las apps excluidas")
                                        .help("Volver a leer los títulos de \(app.name)")
                                    }
                                }
                            }
                        }
                        Divider().overlay(Palette.stroke)
                        Toggle("Observar el dominio de la pestaña activa del navegador", isOn: Binding(
                            get: { model.workspace.settings.observeBrave },
                            set: { value in model.updateSettings { $0.observeBrave = value } }
                        ))
                        HStack {
                            Text("Estado: \(model.braveStatus)").font(.app(10)).foregroundStyle(Palette.muted)
                            Spacer()
                            Button("Ajustes de Automatización") { MacActivity.openAutomationSettings() }
                                .buttonStyle(.focus(.ghost, compact: true))
                        }
                        Text("Safari, Brave, Chrome, Edge, Arc, Vivaldi y Chromium. Solo se guarda el dominio (sin rutas ni parámetros). Las tareas que bloquean webs lo leen aunque esto esté apagado.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                        Divider().overlay(Palette.stroke)
                        Toggle("Vigilar también las ventanas visibles sin foco", isOn: Binding(
                            get: { model.workspace.settings.watchBackgroundWindows },
                            set: { value in model.updateBlockingSetting(turningOn: value) { $0.watchBackgroundWindows = value } }
                        ))
                        Text("Un vídeo en una esquina o en el segundo monitor distrae igual aunque escribas en otra ventana. Se ocultan, nunca se cierran.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                        Toggle("Mirar dentro de apps con web incrustada", isOn: Binding(
                            get: { model.workspace.settings.inspectEmbeddedPages },
                            set: { value in model.updateBlockingSetting(turningOn: value) { $0.inspectEmbeddedPages = value } }
                        ))
                        Text("Páginas abiertas dentro de Discord, Slack o Notion: solo se avisa, esas ventanas llevan conversaciones y documentos. Las webs instaladas como app desde Chrome, Brave o Edge se bloquean como la web que abren.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                    }
                }

                // The login item that brings FocusDesk back if it is killed mid-session.
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Si cierras FocusDesk a la fuerza", icon: "arrow.clockwise.circle")
                        Toggle("Volver a abrirse si lo matan durante una sesión", isOn: Binding(
                            get: { model.relaunchGuard.installed },
                            set: { value in
                                // Switching it off is one more way out of a protected session, so it waits for the end.
                                if !value, model.refuseWhileProtected("apagar el vigilante") { return }
                                if value { model.relaunchGuard.install() } else { model.relaunchGuard.remove() }
                                model.updateSettings { $0.relaunchGuard = model.relaunchGuard.installed }
                            }
                        ))
                        .disabled(!model.relaunchGuard.available)
                        Text(model.relaunchGuard.message).font(.app(10)).foregroundStyle(Palette.muted)
                        Text("Es un elemento de inicio en tu propia cuenta: añade fricción, no es inviolable. Quien sepa usar launchctl puede apagarlo, y FocusDesk no pide contraseña de administrador para nada.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                        if !model.workspace.settings.emergencyUses.isEmpty {
                            Divider().overlay(Palette.stroke)
                            Text("Salidas de emergencia usadas: \(model.workspace.settings.emergencyUses.suffix(5).joined(separator: ", "))")
                                .font(.app(10))
                                .foregroundStyle(Palette.warning)
                        }
                    }
                }
            }

            if section == .data || section == .all {
                // Data Retention, Backups & Recovery (Items 6, 17, 18)
                Card {
                    VStack(alignment: .leading, spacing: 15) {
                        SectionHeader("Tus datos, copias y recuperación", icon: "internaldrive")
                        HStack {
                            Text("Conservar detalle de actividad durante:")
                            Picker("Días", selection: Binding(
                                get: { model.workspace.settings.detailDays },
                                set: { days in
                                    model.updateSettings { $0.detailDays = days }
                                    model.workspace.prune(at: Date())
                                    _ = model.persist()
                                }
                            )) {
                                ForEach([7, 14, 30, 60, 90], id: \.self) { d in
                                    Text("\(d) días").tag(d)
                                }
                            }.frame(width: 130)
                            Spacer()
                        }
                        Text("Pasado ese plazo se limpia el detalle de actividad puntual y se conservan los resúmenes, notas y archivos confirmados.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                        if model.hasUnsavedChanges {
                            HStack {
                                Label("Hay cambios pendientes de guardar en disco.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                                Spacer()
                                Button("Reintentar guardado ahora") { _ = model.retrySave() }.buttonStyle(FocusPrimaryButton(compact: true))
                            }
                        }
                        if model.corruptFileDetected {
                            HStack {
                                Label("El archivo principal está dañado y protegido contra escritura accidental.", systemImage: "shield.lefthalf.filled").foregroundStyle(Palette.warning)
                                Spacer()
                                Button("Recuperar última copia automática") { model.recoverFromAutoBackup() }.buttonStyle(FocusPrimaryButton(compact: true))
                                Button("Iniciar agenda limpia (conservando dañado)") { model.resetCorruptWorkspacePreservingFile() }
                                    .buttonStyle(.focusSecondary)
                            }
                        }
                        HStack(spacing: 10) {
                            Button("Exportar copia JSON") { model.export() }
                                .buttonStyle(.focusSecondary)
                            // A copy brings its session back paused: not while a protected session is running.
                            Button("Importar / Restaurar copia…") { chooseBackupToImport() }
                                .buttonStyle(.focusSecondary)
                                .disabled(model.protectedSessionRunning)
                                .help(model.protectedSessionRunning ? "No disponible con una sesión protegida en marcha" : "Restaurar una copia de seguridad")
                            Button("Recuperar copia automática") { model.recoverFromAutoBackup() }
                                .buttonStyle(.focusSecondary)
                                .disabled(model.protectedSessionRunning)
                                .help(model.protectedSessionRunning ? "No disponible con una sesión protegida en marcha" : "Volver a la última copia automática")
                            Button("Abrir carpeta de datos") { NSWorkspace.shared.open(model.store.url.deletingLastPathComponent()) }
                                .buttonStyle(.focusGhost)
                            Spacer()
                            Button("Borrar detalle de actividad") { eraseDetails = true }
                                .buttonStyle(.focusDestructive)
                        }
                    }
                }
            }
        }
        .disabled(model.preview)
        .confirmationDialog(
            "¿Borrar el perfil «\(profilePendingDeletion?.name ?? "")»?",
            isPresented: Binding(get: { profilePendingDeletion != nil }, set: { if !$0 { profilePendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Borrar perfil", role: .destructive) {
                if let profile = profilePendingDeletion { model.deleteProfile(profile.id) }
                profilePendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) { profilePendingDeletion = nil }
        } message: {
            Text("Las tareas que ya lo usan conservan su configuración.")
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorSheet(model: model, draft: profile)
        }
        .confirmationDialog(
            "¿Borrar el detalle de aplicaciones, títulos y dominios de las sesiones anteriores? Los resúmenes se conservan.",
            isPresented: $eraseDetails,
            titleVisibility: .visible
        ) {
            Button("Borrar detalle", role: .destructive) { model.removeDetailedHistory() }
        }
        .confirmationDialog(
            "¿Restaurar esta copia de seguridad? \(pendingImportSummary) Se guardará primero un respaldo automático de tus datos actuales en la carpeta backups.",
            isPresented: Binding(get: { pendingImportURL != nil }, set: { if !$0 { pendingImportURL = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restaurar copia y respaldar actual") {
                if let url = pendingImportURL {
                    do { try model.restoreBackup(from: url) }
                    catch { model.error = error.localizedDescription }
                }
                pendingImportURL = nil
            }
        }
    }

    private func addExcludedTitleApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        model.updateSettings { settings in
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !settings.excludedTitleApps.contains(where: { $0.id == id }) else { continue }
                settings.excludedTitleApps.append(AllowedApp(id: id, name: url.deletingPathExtension().lastPathComponent, path: url.path))
            }
        }
    }

    private func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let previewWorkspace = try model.store.validateBackup(at: url)
            let currentTasks = model.workspace.tasks.count
            let currentHistory = model.workspace.history.count
            pendingImportSummary = "La copia contiene \(previewWorkspace.tasks.count) tareas y \(previewWorkspace.history.count) sesiones (actualmente tienes \(currentTasks) tareas y \(currentHistory) sesiones)."
            pendingImportURL = url
        } catch {
            model.error = "Archivo de copia no válido: \(error.localizedDescription)"
        }
    }
}

struct ProfileEditorSheet: View {
    @ObservedObject var model: AppModel
    @State var draft: FocusProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Editar perfil reutilizable").font(.app(17, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(FocusIconButtonStyle(size: 28))
                    .help("Cerrar sin guardar (Esc)")
                    .accessibilityLabel("Cerrar")
            }
            TextField("Nombre del perfil", text: $draft.name).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Categoría", selection: $draft.category) {
                    ForEach(model.workspace.settings.categories.map(\.name), id: \.self) { Text($0) }
                }
                Stepper("Duración: \(draft.minutes) min", value: $draft.minutes, in: 5...720, step: 5)
            }
            Toggle("Bloquear las apps que distraen", isOn: $draft.strict)
            Toggle("Empezar sola a su hora", isOn: $draft.autoStart)
            HStack {
                Text("Aplicaciones (\(draft.apps.count))").font(.app(12, weight: .medium))
                Spacer()
                Button("Añadir apps…") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowedContentTypes = [.application]
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        for url in panel.urls {
                            if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !draft.apps.contains(where: { $0.id == id }) {
                                draft.apps.append(AllowedApp(id: id, name: url.deletingPathExtension().lastPathComponent, path: url.path))
                            }
                        }
                    }
                }.buttonStyle(.focus(.secondary, compact: true))
            }
            ForEach(draft.apps) { app in
                HStack {
                    Text(app.name).font(.app(10))
                    Spacer()
                    Button { draft.apps.removeAll { $0.id == app.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(FocusIconButtonStyle(size: 22))
                        .accessibilityLabel("Quitar \(app.name)")
                }
            }
            TextField("Dominios (ej. chatgpt.com, claude.ai)", text: $draft.domains).textFieldStyle(.roundedBorder)
            Text("Checklist (un paso por línea)").font(.app(10)).foregroundStyle(Palette.muted)
            TextEditor(text: $draft.checklist).frame(height: 70).overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.stroke))
            HStack {
                Text(draft.folder ?? "Sin carpeta predeterminada").font(.app(10)).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer()
                Button("Carpeta…") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { draft.folder = url.path }
                }.buttonStyle(.focus(.secondary, compact: true))
                if draft.folder != nil {
                    Button("Quitar") { draft.folder = nil }.buttonStyle(.focus(.ghost, compact: true))
                }
            }
            HStack {
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.focusSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Guardar perfil") {
                    model.saveProfile(draft)
                    dismiss()
                }
                .buttonStyle(FocusPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Palette.background)
    }
}
