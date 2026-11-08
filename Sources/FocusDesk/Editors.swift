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
    // Writing down something simple takes a title, a time and a length. The rest stays folded, saying what is inside.
    @State private var optionsExpanded = false
    @State private var blockingExpanded = false
    @State private var resultExpanded = false
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
                VStack(alignment: .leading, spacing: 12) {
                    profilesRow

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

                    essentialsCard

                    FoldedCard(title: "Más opciones", icon: "slider.horizontal.3", summary: draft.optionsSummary,
                               attention: draft.repeatRule == .customDays && draft.repeatDays.isEmpty, isExpanded: $optionsExpanded) {
                        optionsContent
                    }

                    FoldedCard(title: "Bloqueo", icon: "lock.shield", summary: draft.blockingSummary,
                               attention: draft.blockingIsIncomplete, isExpanded: $blockingExpanded) {
                        VStack(alignment: .leading, spacing: 14) {
                            workspaceCard
                            Divider().overlay(Palette.stroke)
                            protectionCard
                        }
                    }

                    FoldedCard(title: "Resultado", icon: "checkmark.circle", summary: draft.resultSummary, isExpanded: $resultExpanded) {
                        resultContent
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
        .frame(width: 700, height: min(optionsExpanded || blockingExpanded || resultExpanded ? 780 : 610, (NSScreen.main?.visibleFrame.height ?? 820) - 70))
        // Something that stops the task from being saved never stays folded away.
        .onChange(of: draft.blockingIsIncomplete) { _, incomplete in if incomplete { blockingExpanded = true } }
        .onChange(of: draft.repeatDays.isEmpty) { _, empty in if empty && draft.repeatRule == .customDays { optionsExpanded = true } }
        .onAppear {
            focusedField = .title
            if draft.blockingIsIncomplete || model.unfoldEditorForSnapshot { blockingExpanded = true }
            if draft.repeatRule == .customDays && draft.repeatDays.isEmpty { optionsExpanded = true }
            if model.unfoldEditorForSnapshot {
                optionsExpanded = true
                resultExpanded = true
            }
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

    /// Reusable profiles, one line: a click fills the whole task in.
    @ViewBuilder private var profilesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("PERFILES").fieldLabelStyle()
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
                                    Text(FocusRules.durationText(minutes: profile.minutes)).opacity(0.75)
                                }
                            }
                            .buttonStyle(SelectableChipStyle(selected: draft.profileID == profile.id))
                        }
                    }
                }
                Button {
                    saveProfileName = draft.title.isEmpty ? "Nuevo perfil" : draft.title
                    showSaveProfile.toggle()
                } label: {
                    Label(showSaveProfile ? "Ocultar" : "Guardar como perfil", systemImage: "bookmark.badge.plus")
                }
                .buttonStyle(.focus(.ghost, compact: true))
                .fixedSize()
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

    /// What every task needs: what, when and for how long.
    @ViewBuilder private var essentialsCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("¿QUÉ VAS A HACER?").fieldLabelStyle()
                    TextField("Ej. Grabar el vídeo de mañana", text: $draft.title)
                        .font(.app(15))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .title)
                }

                Toggle("Reservar horario en la agenda", isOn: $draft.isScheduled).toggleStyle(.trailingSwitch)

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
                                if model.workspace.tasks.contains(where: { FocusRules.overlaps(draft, $0) }) {
                                    Chip("Coincide con otra tarea", icon: "exclamationmark.triangle", color: Palette.warning)
                                }
                            }
                        }
                    } else {
                        Chip("Bandeja de pendientes sin hora", icon: "tray", color: Palette.mint)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DURACIÓN").fieldLabelStyle()
                        // Same range and steps as every other duration control (it went 5 → 1 → 6 → 11 before).
                        Stepper(FocusRules.durationText(minutes: draft.minutes), value: $draft.minutes, in: FocusRules.minutesRange, step: 5)
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
            }
        }
    }

    /// Area, repetition, deadline and how it starts.
    @ViewBuilder private var optionsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            VStack(alignment: .leading, spacing: 8) {
                Text("FECHA LÍMITE · OPCIONAL").fieldLabelStyle()
                HStack {
                    Toggle("Antes de", isOn: Binding(
                        get: { draft.dueDate != nil },
                        set: { enabled in
                            draft.dueDate = enabled ? (Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date().addingTimeInterval(86400 * 2)) : nil
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

            Divider().overlay(Palette.stroke)

            if draft.isScheduled {
                Toggle("Empezar sola a su hora", isOn: $draft.autoStart)
                    .toggleStyle(.trailingSwitch)
                    .help("Si el Mac está desbloqueado y no hay otra sesión en marcha, la sesión empieza sola a la hora prevista.")
            }

            pomodoroSection

            if draft.isScheduled {
                Stepper("Avisar \(draft.leadMinutes) minutos antes", value: $draft.leadMinutes, in: 0...60, step: 5)
                Toggle("Cita fija (no desplazar)", isOn: $draft.isFixedAppointment)
                    .toggleStyle(.checkbox)
                    .font(.app(11))
                    .foregroundStyle(Palette.muted)
            }

            if draft.minutes > 60 {
                Text("Vorssaint mostrará el final solo durante los últimos 60 minutos. El contador de FocusDesk seguirá visible.").font(.app(10)).foregroundStyle(Palette.muted)
            }
        }
    }

    /// How you will know it is done.
    @ViewBuilder private var resultContent: some View {
        VStack(alignment: .leading, spacing: 10) {
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

    /// Focus and breaks inside the task itself, so a long block does not have to be one sitting.
    @ViewBuilder private var pomodoroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Trabajar en Pomodoro: foco y descansos dentro de la tarea", isOn: Binding(
                get: { draft.pomodoroWorkMinutes > 0 },
                set: { draft.pomodoroWorkMinutes = $0 ? 25 : 0 }
            ))
            .toggleStyle(.trailingSwitch)
            if draft.usesPomodoro {
                HStack(spacing: 18) {
                    Stepper("Foco \(draft.pomodoroWorkMinutes) min", value: $draft.pomodoroWorkMinutes, in: 10...90, step: 5)
                    Stepper("Descanso \(draft.pomodoroBreakMinutes) min", value: $draft.pomodoroBreakMinutes, in: 1...30)
                    Stepper("Largo \(draft.pomodoroLongBreakMinutes) min", value: $draft.pomodoroLongBreakMinutes, in: 5...45, step: 5)
                }
                .font(.app(12))
                Text(pomodoroPlanSummary)
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// «En 120 min: 4 bloques de foco de 25 min con descansos de 5 (largo de 15 tras el 4.º).»
    private var pomodoroPlanSummary: String {
        let total = Double(draft.minutes) * 60
        var blocks = 0
        var t: TimeInterval = 0
        while t < total, blocks < 200, let phase = draft.pomodoroPhase(elapsed: t) {
            if !phase.isBreak { blocks += 1 }
            t += max(1, phase.remainingInPhase)
        }
        let long = blocks >= draft.pomodoroLongBreakEvery
            ? ", y uno largo de \(draft.pomodoroLongBreakMinutes) tras cada \(draft.pomodoroLongBreakEvery) bloques"
            : ""
        return "En \(draft.minutes) min: \(blocks) bloque(s) de foco de \(draft.pomodoroWorkMinutes) min con descansos de \(draft.pomodoroBreakMinutes)\(long). En los descansos se suelta el bloqueo y te aviso al volver al foco."
    }

    @ViewBuilder private var workspaceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Tu espacio de trabajo", icon: "macwindow")
                // First the switch, then what depends on it: the list used to sit above the switch that turns it on.
                Toggle("Bloquear las apps que distraen", isOn: $draft.strict).toggleStyle(.trailingSwitch)
                Toggle("Bloquear bibliotecas de juegos (Steam, Epic, Battle.net, Riot, juegos de Mac…)", isOn: $draft.blockGameLibraries)
                    .toggleStyle(.trailingSwitch)
                    .font(.app(12))
                HStack(spacing: 10) {
                    Text("Puedes usar").font(.app(12))
                    Picker("Puedes usar", selection: $draft.appListMode) {
                        ForEach(AppListMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button { chooseApps() } label: { Label("Elegir apps", systemImage: "plus") }
                        .buttonStyle(.focus(.secondary, compact: true))
                }
                Text(draft.appListMode.explanation).font(.app(10)).foregroundStyle(Palette.muted)
                if draft.apps.isEmpty {
                    Text(draft.appListMode == .allowListed
                         ? "Sin selección: se admiten todas las apps. Añade las necesarias para distinguir distracciones."
                         : "Elige las apps concretas que quieras bloquear durante esta tarea.").font(.app(12)).foregroundStyle(Palette.muted)
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
                Text("Si abres una app bloqueada, FocusDesk la oculta o cierra\(model.workspace.settings.focusDuringStrict ? " y activa No molestar mientras dura la sesión" : ""). \(draft.protection == .none ? "Puedes pausar en cualquier momento." : "Para parar antes de tiempo, lo que elijas abajo en «Si quieres dejarlo a medias».") Finder, Ajustes, FocusDesk, diálogos del sistema y Vorssaint siguen accesibles.").font(.app(10)).foregroundStyle(Palette.muted)
                if draft.strict && draft.apps.isEmpty && !draft.blockGameLibraries {
                    Text(draft.appListMode == .allowListed
                         ? "Elige al menos una app permitida para poder bloquear las demás."
                         : "Elige al menos una app para bloquearla.").font(.app(10)).foregroundStyle(Palette.warning)
                }

                Divider().overlay(Palette.stroke)
                domainsAndWebSection

                Divider().overlay(Palette.stroke)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("PALABRAS BLOQUEADAS EN EL TÍTULO DE VENTANA · OPCIONAL").fieldLabelStyle()
                        Spacer()
                        if !model.recentObservedTitles.isEmpty {
                            Menu("Vistos recientemente…") {
                                ForEach(model.recentObservedTitles, id: \.self) { recentTitle in
                                    Button(recentTitle) {
                                        let existing = FocusRules.parseTitleKeywords(draft.blockedTitleKeywords)
                                        if !existing.contains(where: { $0.lowercased() == recentTitle.lowercased() }) {
                                            draft.blockedTitleKeywords = (existing + [recentTitle]).joined(separator: ", ")
                                        }
                                    }
                                }
                            }
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                    TextField("Shorts, Reels, Netflix, *gameplay*, /partid[ao]/ (separadas por comas)", text: $draft.blockedTitleKeywords)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Exigir palabra completa (evita que «art» bloquee «article»; admite comodines * y ? o /regex/)", isOn: $draft.wholeWordKeywords)
                        .toggleStyle(.checkbox)
                        .font(.app(11))
                    Text("Si el título de la ventana activa coincide con alguna de estas entradas, FocusDesk oculta esa app al instante.")
                        .font(.app(10))
                        .foregroundStyle(Palette.muted)
                }

                Divider().overlay(Palette.stroke)
                BlockedFoldersField(folders: $draft.blockedFolders)
        }
    }

    @ViewBuilder private var domainsAndWebSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WEBS Y SUBRUTAS PARA ESTA TAREA · OPCIONAL").fieldLabelStyle()
                Spacer()
                if !model.recentObservedDomains.isEmpty && draft.webListMode != .blockAll {
                    Menu("Vistos recientemente…") {
                        ForEach(model.recentObservedDomains, id: \.self) { dom in
                            Button(dom) {
                                let existing = FocusRules.parseDomains(draft.domains).valid
                                if !existing.contains(dom) {
                                    draft.domains = (existing + [dom]).joined(separator: ", ")
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                if !draft.domains.isEmpty && FocusRules.normalizeDomains(draft.domains) != draft.domains {
                    Button("Normalizar URLs") {
                        draft.domains = FocusRules.normalizeDomains(draft.domains)
                    }.buttonStyle(.focus(.ghost, compact: true))
                }
            }
            HStack(spacing: 10) {
                Text("Puedes abrir").font(.app(12))
                Picker("Puedes abrir", selection: $draft.webListMode) {
                    ForEach(WebListMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if draft.webListMode != .blockAll {
                TextField(
                    draft.webListMode == .allowListed
                        ? "chatgpt.com, claude.ai, github.com/apple/swift, *.edu"
                        : "youtube.com/shorts, instagram.com/reels, *casino*, /reddit\\.com\\/r\\/all/",
                    text: $draft.domains
                )
                .textFieldStyle(.roundedBorder)
                if draft.webListMode == .blockListed {
                    DistractionPresetChipsView(domains: $draft.domains, keywords: $draft.blockedTitleKeywords)
                }
                if !domainParse.invalid.isEmpty {
                    Text("Entradas no reconocidas como dominio, comodín o /regex/ (se ignorarán): \(domainParse.invalid.joined(separator: ", "))")
                        .font(.app(10))
                        .foregroundStyle(Palette.warning)
                } else if !domainParse.valid.isEmpty {
                    Text("\(draft.webListMode == .allowListed ? "Webs permitidas" : "Webs/rutas bloqueadas"): \(domainParse.valid.joined(separator: ", "))")
                        .font(.app(10))
                        .foregroundStyle(Palette.mint)
                }
            } else {
                Text("Se bloquearán todas las páginas web abiertas en Safari, Chrome, Brave, Edge, Arc y Vivaldi.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
            }
            Toggle("Bloquear pestañas de Vídeos e Imágenes en buscadores (Google, Bing, DuckDuckGo, Brave, Yahoo…)", isOn: $draft.blockSearchMedia)
                .toggleStyle(.checkbox)
                .font(.app(11))
            if draft.webListMode == .blockListed {
                HStack(spacing: 8) {
                    Text("Protección contra excepciones similares:").font(.app(11)).foregroundStyle(Palette.muted)
                    Picker("Similitud", selection: $draft.similarityProtection) {
                        ForEach(SimilarityProtectionLevel.allCases, id: \.self) { lvl in
                            Text(lvl.label).tag(lvl)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            Picker("Si abres una web no permitida", selection: $draft.webBlockAction) {
                ForEach(WebBlockAction.allCases, id: \.self) { action in
                    Text(action.label).tag(action)
                }
            }
            .pickerStyle(.radioGroup)
            if draft.webBlockAction != .warn && draft.webListMode != .blockAll && domainParse.valid.isEmpty && !draft.blockSearchMedia {
                Text(draft.webListMode == .allowListed
                     ? "Para bloquear webs hace falta decir cuáles sí. Sin lista, se bloquearía todo."
                     : "Indica al menos una web o ruta (ej. youtube.com/shorts) para bloquearla.")
                    .font(.app(10))
                    .foregroundStyle(Palette.warning)
            } else {
                Text(webHint).font(.app(10)).foregroundStyle(Palette.muted)
            }
            if draft.webBlockAction == .redirect {
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Frase de recordatorio en la página de bloqueo (opcional)", text: $draft.motivationalMessage)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(11))
                    TextField("URL de redirección personalizada https://… (opcional; vacío = página de bloqueo de FocusDesk)", text: $draft.customRedirectURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(11))
                    if FocusRules.isRedirectDestinationBlocked(
                        redirectURL: draft.customRedirectURL,
                        list: draft.domains,
                        mode: draft.webListMode,
                        blockSearchMedia: draft.blockSearchMedia
                    ) != nil {
                        Label("Atención: la URL de redirección coincide con tus propias reglas de bloqueo y causaría un bucle infinito.", systemImage: "exclamationmark.triangle.fill")
                            .font(.app(10))
                            .foregroundStyle(Palette.warning)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var protectionCard: some View {
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
                if let saved = model.workspace.tasks.first(where: { $0.id == draft.id }),
                   model.protectedBeforeStart(saved) {
                    Label("Ya está protegida: empieza a las \(saved.scheduledAt.formatted(date: .omitted, time: .shortened)). Retrasarla, moverla al pasado o ablandarla costará lo mismo que pararla; adelantarla a una hora por venir, alargarla o endurecerla, no.",
                          systemImage: "lock.fill")
                        .font(.app(10, weight: .medium))
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if draft.protection != .none, model.workspace.settings.runUpMinutes > 0, draft.isScheduled {
                    Text("Protege la tarea desde \(model.workspace.settings.runUpMinutes) min antes de empezar: a esa hora, borrarla o retrasarla ya cuesta lo mismo que pararla. El margen se cambia en Ajustes.")
                        .font(.app(10))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                Toggle("Endurecer si insistes", isOn: $draft.punisherEnabled).toggleStyle(.trailingSwitch)
                Text("Tras cuatro intentos seguidos en pocos minutos, durante un rato FocusDesk cierra esas apps en vez de ocultarlas.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
                Toggle("Proteger los ajustes que desarman el bloqueo", isOn: $draft.guardSystemPanes).toggleStyle(.trailingSwitch)
                Text("Cierra «Privacidad y seguridad», «Fecha y hora» y «Usuarios y grupos» mientras dura la sesión. El resto de Ajustes del Sistema sigue a mano.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
            }
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
            autoStart: draft.autoStart,
            protection: draft.protection,
            unlockChars: draft.unlockChars,
            stopDelayMinutes: draft.stopDelayMinutes,
            blockAction: draft.blockAction,
            webBlockAction: draft.webBlockAction,
            guardSystemPanes: draft.guardSystemPanes,
            punisherEnabled: draft.punisherEnabled,
            blockedFolders: draft.blockedFolders,
            appListMode: draft.appListMode,
            webListMode: draft.webListMode,
            blockedTitleKeywords: draft.blockedTitleKeywords,
            wholeWordKeywords: draft.wholeWordKeywords,
            customRedirectURL: draft.customRedirectURL,
            motivationalMessage: draft.motivationalMessage,
            blockSearchMedia: draft.blockSearchMedia,
            blockGameLibraries: draft.blockGameLibraries,
            similarityProtection: draft.similarityProtection
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

/// How long before its start a protected task already defends itself (`RunUp`).
private struct RunUpSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Antes de que empiece una tarea o una regla protegida", icon: "lock.shield")
                Picker("Protegerla desde", selection: Binding(
                    get: { model.workspace.settings.runUpMinutes },
                    set: { model.setRunUpMinutes($0) }
                )) {
                    ForEach(RunUp.choices, id: \.self) { minutes in
                        Text(minutes == 0 ? "No protegerla antes" : "\(minutes) min antes").tag(minutes)
                    }
                }
                .frame(maxWidth: 360)
                Text("A las 8:55, una tarea de las 9:00 aún no ha empezado y borrarla sería gratis: justo cuando gana el impulso. Desde este margen, retrasar, borrar, mover al pasado o ablandar una tarea protegida cuesta lo mismo que pararla —su código, su espera o la salida de emergencia—. Adelantarla a una hora por venir, alargarla o endurecerla sigue libre, y las tareas que «Se pueden parar» no cambian. Las reglas con protección también: un horario queda protegido desde este margen antes de empezar, y un presupuesto o una recompensa cuando le quedan esos minutos.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// No molestar during the sessions that block apps, with the one-time setup of its two shortcuts.
/// FD-09: what counts as verified study for the rules that ask for it (the LoL one among them). Only what is here.
struct StudySourcesSettings: View {
    @ObservedObject var model: AppModel
    @State private var newWeb = ""
    @State private var showMissingApps = false

    private var sources: [StudySource] { model.workspace.settings.studySources }
    private var installedApps: [StudySource] { sources.filter { $0.kind == .app && Self.appURL($0) != nil } }
    private var missingApps: [StudySource] { sources.filter { $0.kind == .app && Self.appURL($0) == nil } }
    private var webs: [StudySource] { sources.filter { $0.kind == .web } }

    static func appURL(_ source: StudySource) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.value)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Qué cuenta como estudio", icon: "book")
                Text("Las reglas que piden estudio verificado, como la de LoL, solo cuentan el tiempo en estas apps y webs, y en cualquier PDF. Lo demás no cuenta, y los juegos nunca.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Apps").font(.app(11, weight: .semibold))
                FlowLayout(spacing: 6) {
                    ForEach(installedApps) { chip($0) }
                }
                if !missingApps.isEmpty {
                    DisclosureGroup(isExpanded: $showMissingApps) {
                        FlowLayout(spacing: 6) {
                            ForEach(missingApps) { chip($0) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("\(missingApps.count) más que no tienes instaladas")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                    }
                }
                Button("Añadir app…") { chooseApps() }
                    .buttonStyle(.focus(.secondary, compact: true))
                    .disabled(model.readOnly)

                Divider().overlay(Palette.stroke)
                Text("Webs").font(.app(11, weight: .semibold))
                FlowLayout(spacing: 6) {
                    ForEach(webs) { chip($0) }
                }
                HStack(spacing: 8) {
                    TextField("apuntes.ejemplo.com", text: $newWeb)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(addWeb)
                        .accessibilityLabel("Web que cuenta como estudio")
                    Button("Añadir web", action: addWeb)
                        .buttonStyle(.focus(.secondary, compact: true))
                        .disabled(model.readOnly || newWeb.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Una web incluye sus subdominios: usal.es cuenta también para Studium. Lo que añades cuenta desde mañana, para que no sirva para cumplir la meta de hoy. Quitar algo es inmediato.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func chip(_ source: StudySource) -> some View {
        let pending = !source.counts(today: model.studyToday)
        HStack(spacing: 5) {
            if source.kind == .app, let url = Self.appURL(source) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            Text(source.name).font(.app(10, weight: .medium))
            if pending {
                Text("desde mañana").font(.app(9)).foregroundStyle(Palette.muted)
            }
            Button {
                model.removeStudySource(source)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .disabled(model.readOnly)
            .accessibilityLabel("Quitar \(source.name) de lo que cuenta como estudio")
            .help("Dejar de contar \(source.name) como estudio")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Palette.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pending ? "\(source.name), cuenta desde mañana" : source.name)
    }

    private func addWeb() {
        let text = newWeb.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.addStudyWeb(text)
        newWeb = ""
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            model.addStudySource(StudySource(kind: .app, value: id, name: url.deletingPathExtension().lastPathComponent))
        }
    }
}

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
                .toggleStyle(.trailingSwitch)
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
                        .toggleStyle(.trailingSwitch)
                        Text("Si lo ocultas, el tiempo sigue en el Dock y FocusDesk se abre con su atajo o desde el Dock.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                        Toggle("Mostrar píldora flotante de cuenta atrás al usar un presupuesto diario o visita", isOn: Binding(
                            get: { model.workspace.settings.showFloatingTimerPill },
                            set: { value in
                                model.updateSettings { $0.showFloatingTimerPill = value }
                                model.updateFloatingPill(at: Date())
                            }
                        ))
                        .toggleStyle(.trailingSwitch)
                        Toggle("Avisarme cuando queden 5 min y 1 min de un presupuesto diario o visita", isOn: Binding(
                            get: { model.workspace.settings.preBlockRemindersEnabled },
                            set: { value in model.updateSettings { $0.preBlockRemindersEnabled = value } }
                        ))
                        .toggleStyle(.trailingSwitch)
                    }
                }
                DoNotDisturbSettings(model: model, focusMode: model.focusMode)
                RunUpSettings(model: model)
                StudySourcesSettings(model: model)
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
                        Text("Atajos en la app: ⌘K Buscar función · ⌘1–⌘3 Hoy, Semana, Historial · ⌘4–⌘6 Bloquear ahora, Reglas y límites, Descansos · ⌃⌥⌘B Bloquear 30 min · ⌘, Ajustes · ⌘[ / ⌘] Anterior y siguiente · ⌘T Hoy · ⌘N Nueva tarea · ⌘Z / ⇧⌘Z Deshacer y rehacer · ⌃⌥⌘P Pausar · ⌃⌥⌘T He terminado · ⌃⌥⌘A Ampliar 10 min")
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
                            Stepper("Corte de día: \(String(format: "%02d:00", model.workspace.settings.dayRolloverHour))", value: Binding(
                                get: { model.workspace.settings.dayRolloverHour },
                                set: { v in model.updateSettings { $0.dayRolloverHour = max(0, min(8, v)) } }
                            ), in: 0...8)
                            .help("Hora en la que se reinician los presupuestos diarios, aperturas y micro-pausas (útil si trabajas pasadas las 00:00).")
                        }
                        Divider().overlay(Palette.stroke)
                        Text("Descansos habituales").font(.app(12, weight: .medium))
                        Toggle("Mostrar aviso y cuenta atrás cuando empiece un descanso", isOn: Binding(
                            get: { model.workspace.settings.enforceBreaks },
                            set: { value in model.updateSettings { $0.enforceBreaks = value } }
                        ))
                        Text("Durante el descanso aparece un temporizador en vivo en Hoy y en el panel de la barra de menús para recordar que apartes la vista de la pantalla.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
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
                        Text("Descansos por tiempo de uso continuo").font(.app(12, weight: .medium))
                        Toggle("Sugerir un descanso breve tras usar el Mac de forma continua", isOn: Binding(
                            get: { model.workspace.settings.continuousBreakEnabled },
                            set: { value in model.updateSettings { $0.continuousBreakEnabled = value } }
                        ))
                        .toggleStyle(.trailingSwitch)
                        if model.workspace.settings.continuousBreakEnabled {
                            HStack(spacing: 16) {
                                Stepper("Cada \(model.workspace.settings.continuousWorkMinutes) min de trabajo continuo", value: Binding(
                                    get: { model.workspace.settings.continuousWorkMinutes },
                                    set: { val in model.updateSettings { $0.continuousWorkMinutes = val } }
                                ), in: 15...180, step: 5)
                                Stepper("Descansar \(model.workspace.settings.continuousBreakDurationMinutes) min", value: Binding(
                                    get: { model.workspace.settings.continuousBreakDurationMinutes },
                                    set: { val in model.updateSettings { $0.continuousBreakDurationMinutes = val } }
                                ), in: 1...30)
                                Stepper("Máx. \(model.workspace.settings.continuousBreakMaxSkipsPerDay) saltos/día", value: Binding(
                                    get: { model.workspace.settings.continuousBreakMaxSkipsPerDay },
                                    set: { val in model.updateSettings { $0.continuousBreakMaxSkipsPerDay = val } }
                                ), in: 0...10)
                            }
                            .font(.app(11))
                        }
                        Text("Si te levantas o dejas el teclado unos minutos, el contador continuo se reinicia solo.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
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
                        Divider().overlay(Palette.stroke)
                        Toggle("Vigilar y limpiar el portapapeles durante bloqueos activos", isOn: Binding(
                            get: { model.workspace.settings.protectClipboard },
                            set: { value in model.updateBlockingSetting(turningOn: value) { $0.protectClipboard = value } }
                        ))
                        Text("Si copias una dirección o texto que coincida con un dominio o palabra bloqueada mientras dura la sesión o regla, FocusDesk vacía el portapapeles.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                        Toggle("Proteger el historial y registro de actividad con bloqueos activos", isOn: Binding(
                            get: { model.workspace.settings.protectActivityHistory },
                            set: { value in model.updateBlockingSetting(turningOn: value) { $0.protectActivityHistory = value } }
                        ))
                        Text("Impide borrar sesiones del historial o vaciar el registro de auditoría mientras haya una sesión o regla protegida en marcha.")
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
            Toggle("Bloquear las apps que distraen", isOn: $draft.strict).toggleStyle(.trailingSwitch)
            Picker("Puedes usar", selection: $draft.appListMode) {
                ForEach(AppListMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Empezar sola a su hora", isOn: $draft.autoStart).toggleStyle(.trailingSwitch)
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
            Picker("Puedes abrir", selection: $draft.webListMode) {
                ForEach(WebListMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if draft.webListMode != .blockAll {
                TextField("Dominios o rutas (ej. youtube.com/shorts, claude.ai)", text: $draft.domains).textFieldStyle(.roundedBorder)
            }
            TextField("Palabras bloqueadas en título (ej. Shorts, Reels, Netflix)", text: $draft.blockedTitleKeywords).textFieldStyle(.roundedBorder)
            BlockedFoldersField(folders: $draft.blockedFolders)
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

/// The folders a task (or profile) closes while it runs — FocusMe's «Finder locations». Added through the open
/// panel, so the path is always one that exists; the folders the Mac needs are refused with the reason.
struct BlockedFoldersField: View {
    @Binding var folders: [String]
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CARPETAS QUE DISTRAEN · OPCIONAL").fieldLabelStyle()
                Spacer()
                Button("Añadir carpeta…") { choose() }
                    .buttonStyle(.focus(.secondary, compact: true))
                    .help("Elegir carpetas que se cierran mientras dura la tarea")
            }
            if folders.isEmpty {
                Text("Una carpeta de series, juegos o descargas. Mientras dura la tarea, abrirla en el Finder —o abrir un archivo de dentro, como un vídeo en QuickTime— cierra esa ventana.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(folders, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(FolderRules.name(of: path)).font(.app(11, weight: .medium)).lineLimit(1)
                            Text(Self.abbreviated(path)).font(.app(9)).foregroundStyle(Palette.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Button { folders.removeAll { $0 == path } } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Desbloquear \(FolderRules.name(of: path))")
                            .help("Desbloquear \(FolderRules.name(of: path))")
                            .buttonStyle(FocusIconButtonStyle(size: 20))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
                Text("La primera vez, macOS te pedirá que FocusDesk pueda controlar el Finder: es lo que le deja ver qué carpeta tienes abierta.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.app(10)).foregroundStyle(Palette.warning)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Bloquear"
        panel.message = "Elige las carpetas que se cerrarán mientras dure la tarea."
        guard panel.runModal() == .OK else { return }
        problem = nil
        for url in panel.urls {
            if let why = FolderRules.problem(with: url.path) {
                problem = why
                continue
            }
            let clean = FolderRules.normalize(url.path)
            if !folders.contains(where: { $0.lowercased() == clean.lowercased() }) { folders.append(clean) }
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// One-click preset chips that append common distracting domains/subpaths and window title keywords.
struct DistractionPresetChipsView: View {
    @Binding var domains: String
    @Binding var keywords: String
    var webListMode: Binding<WebListMode>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Añadir lote rápido en 1 clic:").font(.app(10)).foregroundStyle(Palette.muted)
            HStack(spacing: 6) {
                ForEach(DistractionPreset.allCases) { preset in
                    Button {
                        apply(preset)
                    } label: {
                        Label(preset.label, systemImage: preset.icon)
                    }
                    .buttonStyle(SelectableChipStyle(selected: isApplied(preset)))
                    .help("Añadir \(preset.domains.joined(separator: ", "))")
                }
            }
        }
    }

    private func isApplied(_ preset: DistractionPreset) -> Bool {
        let current = Set(FocusRules.parseDomains(domains).valid)
        return !preset.domains.isEmpty && preset.domains.allSatisfy { current.contains($0) }
    }

    private func apply(_ preset: DistractionPreset) {
        if webListMode?.wrappedValue == .allowListed {
            webListMode?.wrappedValue = .blockListed
        }
        let existingDomains = FocusRules.parseDomains(domains).valid
        let mergedDomains = existingDomains + preset.domains.filter { !existingDomains.contains($0) }
        domains = mergedDomains.joined(separator: ", ")

        let existingKeywords = FocusRules.parseTitleKeywords(keywords)
        let mergedKeywords = existingKeywords + preset.titleKeywords.filter { kw in
            !existingKeywords.contains(where: { $0.lowercased() == kw.lowercased() })
        }
        keywords = mergedKeywords.joined(separator: ", ")
    }
}

/// Sheet to create or edit a standalone `GeneralBlockRule` (daily usage timer, countdown lock, schedule, or 24/7).
struct GeneralRuleEditor: View {
    @ObservedObject var model: AppModel
    @State var draft: GeneralBlockRule
    @State private var startCountdownOnSave = true
    @Environment(\.dismiss) private var dismiss

    private var lockedOriginal: GeneralBlockRule? {
        guard let current = model.workspace.generalRules.first(where: { $0.id == draft.id }),
              current.protection != .none,
              model.isRuleProtected(current, at: model.now) else { return nil }
        return current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.workspace.generalRules.contains(where: { $0.id == draft.id }) ? "Editar regla de bloqueo" : "Nueva regla o temporizador de bloqueo")
                        .font(.app(20, weight: .semibold, design: .rounded))
                    Text("Funciona en segundo plano aunque no tengas ninguna tarea de la agenda en marcha.")
                        .font(.app(11))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(FocusIconButtonStyle(size: 26))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cerrar")
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Rectangle().fill(Palette.stroke).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let locked = lockedOriginal {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                            Text("Esta regla está activa y protegida («\(locked.protection.label)»). Puedes endurecerla libremente; para ablandarla te pedirá su desbloqueo al guardar.")
                        }
                        .font(.app(11))
                        .foregroundStyle(Palette.mint)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    // Name & Kind
                    VStack(alignment: .leading, spacing: 10) {
                        Text("NOMBRE Y TIPO DE TEMPORIZADOR").fieldLabelStyle()
                        TextField("Ej. Límite diario de Shorts y redes, Cuenta atrás de estudio…", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.app(15, weight: .medium))

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 8)], spacing: 8) {
                            ForEach(GeneralRuleKind.allCases, id: \.self) { kind in
                                Button {
                                    draft.kind = kind
                                } label: {
                                    Label(kind.label, systemImage: kind.icon)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(SelectableChipStyle(selected: draft.kind == kind))
                            }
                        }

                        kindConfigurationBox
                    }

                    Divider().overlay(Palette.stroke)

                    // Selectors: Webs, URL subpaths, Presets, Title keywords, Apps, Folders
                    VStack(alignment: .leading, spacing: 12) {
                        Text("QUÉ BLOQUEA O CONTROLA ESTA REGLA").fieldLabelStyle()

                        DistractionPresetChipsView(
                            domains: $draft.domains,
                            keywords: $draft.blockedTitleKeywords,
                            webListMode: $draft.webListMode
                        )

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("WEBS Y SUBRUTAS URL").fieldLabelStyle()
                                Spacer()
                                if !model.recentObservedDomains.isEmpty && draft.webListMode != .blockAll {
                                    Menu("Vistos recientemente…") {
                                        ForEach(model.recentObservedDomains, id: \.self) { dom in
                                            Button(dom) {
                                                let existing = FocusRules.parseDomains(draft.domains).valid
                                                if !existing.contains(dom) {
                                                    draft.domains = (existing + [dom]).joined(separator: ", ")
                                                }
                                            }
                                        }
                                    }
                                    .controlSize(.small)
                                    .fixedSize()
                                }
                                Picker("Puedes abrir", selection: $draft.webListMode) {
                                    ForEach(WebListMode.allCases, id: \.self) { mode in
                                        Text(mode.label).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(maxWidth: 320)
                            }
                            if draft.webListMode == .blockAll {
                                Text("Se bloqueará cualquier página abierta en Safari, Brave, Chrome, Arc, Edge o Vivaldi.")
                                    .font(.app(10))
                                    .foregroundStyle(Palette.warning)
                            } else {
                                TextField(
                                    draft.webListMode == .allowListed
                                        ? "Solo permitir estos dominios o rutas: docs.swift.org, github.com, *.edu"
                                        : "Dominios, rutas, comodines (*) o /regex/: youtube.com/shorts, *casino*, /reddit\\.com\\/r\\/all/",
                                    text: $draft.domains
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.app(13))
                                .onChange(of: draft.domains) { _, val in
                                    if val.contains("://") { draft.domains = FocusRules.normalizeDomains(val) }
                                }
                                Text("Admite dominios (x.com), subrutas (youtube.com/shorts), comodines (* y ?) o expresiones regulares entre barras (/regex/).")
                                    .font(.app(10))
                                    .foregroundStyle(Palette.muted)
                            }
                            Toggle("Bloquear pestañas de Vídeos e Imágenes en buscadores (Google, Bing, DuckDuckGo, Brave, Yahoo…)", isOn: $draft.blockSearchMedia)
                                .toggleStyle(.checkbox)
                                .font(.app(11))
                            if draft.webListMode == .blockListed {
                                HStack(spacing: 8) {
                                    Text("Protección contra excepciones similares:").font(.app(11)).foregroundStyle(Palette.muted)
                                    Picker("Similitud", selection: $draft.similarityProtection) {
                                        ForEach(SimilarityProtectionLevel.allCases, id: \.self) { lvl in
                                            Text(lvl.label).tag(lvl)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 220)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("PALABRAS EN EL TÍTULO DE VENTANA · OPCIONAL").fieldLabelStyle()
                                Spacer()
                                if !model.recentObservedTitles.isEmpty {
                                    Menu("Vistos recientemente…") {
                                        ForEach(model.recentObservedTitles, id: \.self) { recentTitle in
                                            Button(recentTitle) {
                                                let existing = FocusRules.parseTitleKeywords(draft.blockedTitleKeywords)
                                                if !existing.contains(where: { $0.lowercased() == recentTitle.lowercased() }) {
                                                    draft.blockedTitleKeywords = (existing + [recentTitle]).joined(separator: ", ")
                                                }
                                            }
                                        }
                                    }
                                    .controlSize(.small)
                                    .fixedSize()
                                }
                            }
                            TextField("Shorts, Reels, Netflix, *gameplay*, /partid[ao]/…", text: $draft.blockedTitleKeywords)
                                .textFieldStyle(.roundedBorder)
                                .font(.app(13))
                            Toggle("Exigir palabra completa (evita que «art» bloquee «article»; admite comodines * y ? o /regex/)", isOn: $draft.wholeWordKeywords)
                                .toggleStyle(.checkbox)
                                .font(.app(11))
                            Text("Detecta distracciones por el título de cualquier ventana o pestaña aunque cambie el dominio.")
                                .font(.app(10))
                                .foregroundStyle(Palette.muted)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("APLICACIONES · PUEDES USAR").fieldLabelStyle()
                                Spacer()
                                Picker("Puedes usar", selection: $draft.appListMode) {
                                    ForEach(AppListMode.allCases, id: \.self) { mode in
                                        Text(mode.label).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(maxWidth: 340)
                                Button("Elegir de /Applications…") { pickRuleApplications() }
                                    .buttonStyle(.focus(.secondary, compact: true))
                            }
                            Toggle("Bloquear bibliotecas de juegos automáticamente (Steam, Epic, Battle.net, Riot, juegos de Mac…)", isOn: $draft.blockGameLibraries)
                                .toggleStyle(.checkbox)
                                .font(.app(11))
                            if draft.apps.isEmpty {
                                Text(draft.appListMode == .blockListed
                                     ? "Ninguna app bloqueada. Si solo quieres limitar webs, juegos o palabras del título, déjalo vacío."
                                     : "Ninguna app restringida. Si añades apps aquí, solo esas podrán estar al frente.")
                                    .font(.app(10))
                                    .foregroundStyle(Palette.muted)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(draft.apps) { app in
                                            HStack(spacing: 6) {
                                                Text(app.name).font(.app(11, weight: .medium))
                                                Button { draft.apps.removeAll { $0.id == app.id } } label: { Image(systemName: "xmark") }
                                                    .buttonStyle(FocusIconButtonStyle(size: 18))
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Palette.mint.opacity(0.14), in: Capsule())
                                        }
                                    }
                                }
                            }
                        }

                        BlockedFoldersField(folders: $draft.blockedFolders)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("PÁGINA DE BLOQUEO Y REDIRECCIÓN · OPCIONAL").fieldLabelStyle()
                            TextField("Frase motivadora para mostrar al bloquear (ej. Primero el código, luego YouTube)", text: $draft.motivationalMessage)
                                .textFieldStyle(.roundedBorder)
                                .font(.app(12))
                            TextField("URL de redirección personalizada https://… (vacío = página de bloqueo de FocusDesk)", text: $draft.customRedirectURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.app(12))
                            if FocusRules.isRedirectDestinationBlocked(
                                redirectURL: draft.customRedirectURL,
                                list: draft.domains,
                                mode: draft.webListMode,
                                blockSearchMedia: draft.blockSearchMedia
                            ) != nil {
                                Label("Atención: la URL de redirección coincide con tus propias reglas de bloqueo y causaría un bucle infinito.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.app(10))
                                    .foregroundStyle(Palette.warning)
                            }
                        }
                    }

                    Divider().overlay(Palette.stroke)

                    // Micro-pauses
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MICRO-PAUSAS CONTADAS AL DÍA · OPCIONAL").fieldLabelStyle()
                        HStack(spacing: 16) {
                            Stepper("Pausas permitidas hoy: \(draft.dailyMicroPausesAllowed)", value: $draft.dailyMicroPausesAllowed, in: 0...10)
                                .font(.app(12))
                            if draft.dailyMicroPausesAllowed > 0 {
                                Stepper("Duración de cada pausa: \(draft.microPauseMinutes) min", value: $draft.microPauseMinutes, in: 1...30)
                                    .font(.app(12))
                            }
                        }
                        Text(draft.dailyMicroPausesAllowed == 0
                             ? "Sin micro-pausas: no podrás pausar brevemente esta regla cuando esté bloqueando."
                             : "Permite hasta \(draft.dailyMicroPausesAllowed) micro-pausa(s) de \(draft.microPauseMinutes) min al día con re-bloqueo automático al terminar.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                    }

                    Divider().overlay(Palette.stroke)

                    // Protection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PROTECCIÓN Y OBLIGATORIEDAD").fieldLabelStyle()
                        Picker("Protección", selection: $draft.protection) {
                            ForEach(SessionProtection.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(draft.protection.explanation)
                            .font(.app(10))
                            .foregroundStyle(draft.protection == .forced ? Palette.warning : Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        if draft.protection == .challenge {
                            HStack(spacing: 12) {
                                Stepper("Longitud de la contraseña/código: \(draft.unlockChars) caracteres", value: $draft.unlockChars, in: UnlockChallenge.lengthRange, step: 4)
                                    .font(.app(12))
                                Button("64 dígitos (máx.)") {
                                    draft.unlockChars = 64
                                }
                                .buttonStyle(SelectableChipStyle(selected: draft.unlockChars == 64))
                            }
                        } else if draft.protection == .delay {
                            Stepper("Esperar \(draft.stopDelayMinutes) minutos antes de permitir cambios", value: $draft.stopDelayMinutes, in: 1...60)
                                .font(.app(12))
                        }

                        if draft.protection != .none {
                            Toggle("Regla pasiva obligatoria 24/7 (exigir el código siempre para apagarla, editarla, reiniciarla o cerrar FocusDesk)", isOn: $draft.alwaysProtected)
                                .toggleStyle(.checkbox)
                                .font(.app(11))
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 20)
            }

            Rectangle().fill(Palette.stroke).frame(height: 1)

            HStack {
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.focusSecondary)
                Spacer()
                Button("Guardar regla") {
                    commitSave()
                }
                .buttonStyle(FocusPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
        }
        .frame(width: 680, height: 720)
        .background(Palette.background)
        .tint(Palette.mint)
    }

    @ViewBuilder private var kindConfigurationBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch draft.kind {
            case .dailyLimit:
                HStack(spacing: 12) {
                    Image(systemName: "hourglass.bottomhalf.filled")
                        .font(.app(18))
                        .foregroundStyle(Palette.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Temporizador de presupuesto: \(draft.dailyLimitMinutes) min \(draft.limitPeriodUnit.label.lowercased())")
                            .font(.app(13, weight: .semibold))
                        Text("El reloj solo descuenta segundos cuando tienes una de estas webs, rutas, títulos o apps abierta en primer plano. Al llegar a 00:00 se bloquean hasta el próximo corte.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("Unidad de periodo", selection: $draft.limitPeriodUnit) {
                        ForEach(LimitPeriodUnit.allCases, id: \.self) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
                HStack(spacing: 6) {
                    ForEach([10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { mins in
                        Button("\(mins) min") { draft.dailyLimitMinutes = mins }
                            .buttonStyle(SelectableChipStyle(selected: draft.dailyLimitMinutes == mins))
                    }
                    Spacer()
                    Stepper("", value: $draft.dailyLimitMinutes, in: 5...600, step: 5)
                        .labelsHidden()
                }

            case .pomodoro:
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.app(18))
                        .foregroundStyle(Palette.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ciclo Pomodoro (\(draft.pomodoroWorkMinutes)m trabajo / \(draft.pomodoroShortBreakMinutes)m descanso · \(draft.pomodoroTotalCycles) ciclos)")
                            .font(.app(13, weight: .semibold))
                        Text("Bloquea las distracciones durante los tramos de trabajo y las libera durante los descansos.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 16) {
                    Stepper("Trabajo: \(draft.pomodoroWorkMinutes) min", value: $draft.pomodoroWorkMinutes, in: 5...180, step: 5)
                        .font(.app(12))
                    Stepper("Descanso corto: \(draft.pomodoroShortBreakMinutes) min", value: $draft.pomodoroShortBreakMinutes, in: 1...60)
                        .font(.app(12))
                    Stepper("Descanso largo: \(draft.pomodoroLongBreakMinutes) min", value: $draft.pomodoroLongBreakMinutes, in: 5...90, step: 5)
                        .font(.app(12))
                    Stepper("Ciclos: \(draft.pomodoroTotalCycles)", value: $draft.pomodoroTotalCycles, in: 1...12)
                        .font(.app(12))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Penalización Pomodoro: reiniciar el ciclo desde cero si intentas abrir una distracción", isOn: $draft.pomodoroPenaltyReset)
                        .font(.app(11))
                    Toggle("Proteger también los descansos (impedir editar o apagar la regla durante el descanso)", isOn: $draft.protectPomodoroBreaks)
                        .font(.app(11))
                    Toggle("Esperar mi confirmación manual antes de pasar a la siguiente fase", isOn: $draft.pomodoroWaitForUser)
                        .font(.app(11))
                    Toggle("Iniciar el primer ciclo Pomodoro al guardar", isOn: $startCountdownOnSave)
                        .font(.app(11))
                }

            case .workGoal:
                HStack(spacing: 12) {
                    Image(systemName: "flag.checkered")
                        .font(.app(18))
                        .foregroundStyle(Palette.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Primero el estudio/trabajo, luego el juego: \(draft.goalMinutesRequired) min requeridos hoy")
                            .font(.app(13, weight: .semibold))
                        Text(draft.verifyActiveStudy
                             ? "Modo pasivo + activo: suma minutos tanto si pulsas «Empezar» como si estudias directamente con una ventana o pestaña abierta (ej. Claude, apuntes, PDF, código) y actividad real."
                             : "Mantiene bloqueadas estas apps y webs hasta que acumules los minutos exigidos en sesiones de tareas de FocusDesk hoy.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    ForEach([25, 45, 60, 90, 120, 180], id: \.self) { mins in
                        Button("\(mins) min estudio") { draft.goalMinutesRequired = mins }
                            .buttonStyle(SelectableChipStyle(selected: draft.goalMinutesRequired == mins))
                    }
                    Spacer()
                    Stepper("", value: $draft.goalMinutesRequired, in: 10...600, step: 15)
                        .labelsHidden()
                }
                Toggle("Detección pasiva de estudio activo (cuenta sin darle a «Empezar» siempre que tengas abierta una pestaña/ventana productiva y actividad real)", isOn: $draft.verifyActiveStudy)
                    .toggleStyle(.checkbox)
                    .font(.app(11))
                HStack(spacing: 12) {
                    Toggle("Limitar tiempo de juego/recompensa por bloque", isOn: Binding(
                        get: { draft.goalRewardMinutes > 0 },
                        set: { enabled in draft.goalRewardMinutes = enabled ? max(15, draft.goalRewardMinutes) : 0 }
                    ))
                    .font(.app(12))
                    if draft.goalRewardMinutes > 0 {
                        Stepper("Tiempo máx.: \(draft.goalRewardMinutes) min por cada \(draft.goalMinutesRequired) min de estudio", value: $draft.goalRewardMinutes, in: 5...240, step: 5)
                            .font(.app(12))
                    } else {
                        Text("Sin tope de minutos tras cumplir la meta")
                            .font(.app(11))
                            .foregroundStyle(Palette.mint)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Toggle("Limitar partidas de League of Legends al día", isOn: Binding(
                            get: { draft.maxDailyMatches > 0 },
                            set: { enabled in
                                draft.maxDailyMatches = enabled ? max(2, draft.maxDailyMatches) : 0
                                if enabled { draft.deferBlockUntilMatchEnds = true }
                            }
                        ))
                        .font(.app(12))
                        if draft.maxDailyMatches > 0 {
                            Stepper("Máximo: \(draft.maxDailyMatches) partida(s) al día", value: $draft.maxDailyMatches, in: 1...10)
                                .font(.app(12))
                        }
                    }
                    if draft.maxDailyMatches > 0 || LeagueMatchRules.ruleTargetsLeague(draft) {
                        HStack(spacing: 12) {
                            Toggle("No sacar nunca a mitad de partida (esperar a que termine la partida en curso)", isOn: $draft.deferBlockUntilMatchEnds)
                                .toggleStyle(.checkbox)
                                .font(.app(11))
                            if draft.deferBlockUntilMatchEnds {
                                Stepper("Margen al acabar la partida: \(draft.postMatchGraceSeconds) s", value: $draft.postMatchGraceSeconds, in: 15...300, step: 15)
                                    .font(.app(11))
                            }
                        }
                    }
                }

            case .launchLimit:
                HStack(spacing: 12) {
                    Image(systemName: "door.left.hand.open")
                        .font(.app(18))
                        .foregroundStyle(Palette.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Límite de \(draft.maxDailyLaunches) aperturas al día · máx. \(draft.maxLaunchDurationMinutes) min por visita")
                            .font(.app(13, weight: .semibold))
                        Text("Ideal para correo, mensajería o redes: permite entrar contadas veces al día durante unos minutos y aplica un enfriamiento obligatorio entre visitas.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 18) {
                    Stepper("Aperturas/día: \(draft.maxDailyLaunches)", value: $draft.maxDailyLaunches, in: 1...50)
                        .font(.app(12))
                    Stepper("Duración visita: \(draft.maxLaunchDurationMinutes) min", value: $draft.maxLaunchDurationMinutes, in: 1...120)
                        .font(.app(12))
                    Stepper("Enfriamiento: \(draft.launchCooldownMinutes) min", value: $draft.launchCooldownMinutes, in: 0...240, step: 5)
                        .font(.app(12))
                }

            case .countdown:
                HStack(spacing: 12) {
                    Image(systemName: "timer")
                        .font(.app(18))
                        .foregroundStyle(Palette.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Temporizador de bloqueo directo: \(draft.countdownMinutes) min")
                            .font(.app(13, weight: .semibold))
                        Text("Bloquea de inmediato durante el tiempo elegido con reloj monotónico (resistente a cambios de hora del sistema).")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    ForEach([15, 30, 45, 60, 90, 120, 180, 240], id: \.self) { mins in
                        Button(mins >= 60 && mins % 60 == 0 ? "\(mins / 60) h" : "\(mins) min") {
                            draft.countdownMinutes = mins
                        }
                        .buttonStyle(SelectableChipStyle(selected: draft.countdownMinutes == mins))
                    }
                    Spacer()
                    Stepper("", value: $draft.countdownMinutes, in: 5...720, step: 15)
                        .labelsHidden()
                }
                Toggle("Iniciar la cuenta atrás nada más guardar", isOn: $startCountdownOnSave)
                    .font(.app(12))

            case .schedule:
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.app(18))
                        .foregroundStyle(Palette.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Horario automático (\(draft.scheduleLabel))")
                            .font(.app(13, weight: .semibold))
                        Text("Se activa sola los días elegidos entre las dos horas (admite tramos nocturnos como 22:30–07:30).")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                    }
                }
                HStack(spacing: 6) {
                    ForEach([(2, "Lun"), (3, "Mar"), (4, "Mié"), (5, "Jue"), (6, "Vie"), (7, "Sáb"), (1, "Dom")], id: \.0) { day, label in
                        let selected = draft.scheduleDays.contains(day)
                        Button(label) {
                            if selected && draft.scheduleDays.count > 1 {
                                draft.scheduleDays.remove(day)
                            } else {
                                draft.scheduleDays.insert(day)
                            }
                        }
                        .buttonStyle(SelectableChipStyle(selected: selected))
                    }
                }
                HStack(spacing: 18) {
                    HStack(spacing: 6) {
                        Text("Desde:").font(.app(12))
                        Picker("Hora inicio", selection: Binding(
                            get: { draft.startMinutes / 60 },
                            set: { draft.startMinutes = $0 * 60 + (draft.startMinutes % 60) }
                        )) {
                            ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d h", h)).tag(h) }
                        }
                        .labelsHidden()
                        .frame(width: 76)
                        Picker("Minuto inicio", selection: Binding(
                            get: { (draft.startMinutes % 60 / 15) * 15 },
                            set: { draft.startMinutes = (draft.startMinutes / 60) * 60 + $0 }
                        )) {
                            ForEach([0, 15, 30, 45], id: \.self) { m in Text(String(format: ":%02d", m)).tag(m) }
                        }
                        .labelsHidden()
                        .frame(width: 64)
                    }
                    HStack(spacing: 6) {
                        Text("Hasta:").font(.app(12))
                        Picker("Hora fin", selection: Binding(
                            get: { draft.endMinutes / 60 },
                            set: { draft.endMinutes = $0 * 60 + (draft.endMinutes % 60) }
                        )) {
                            ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d h", h)).tag(h) }
                        }
                        .labelsHidden()
                        .frame(width: 76)
                        Picker("Minuto fin", selection: Binding(
                            get: { (draft.endMinutes % 60 / 15) * 15 },
                            set: { draft.endMinutes = (draft.endMinutes / 60) * 60 + $0 }
                        )) {
                            ForEach([0, 15, 30, 45], id: \.self) { m in Text(String(format: ":%02d", m)).tag(m) }
                        }
                        .labelsHidden()
                        .frame(width: 64)
                    }
                    Spacer()
                    Button {
                        draft.extraScheduleIntervals.append(ScheduleInterval(startMinutes: 14 * 60, endMinutes: 18 * 60))
                    } label: {
                        Label("Añadir tramo", systemImage: "plus")
                    }
                    .buttonStyle(.focus(.secondary, compact: true))
                }
                ForEach(Array(draft.extraScheduleIntervals.enumerated()), id: \.element.id) { index, interval in
                    HStack(spacing: 14) {
                        Text("Tramo \(index + 2):").font(.app(11, weight: .medium)).foregroundStyle(Palette.muted)
                        HStack(spacing: 6) {
                            Text("Desde:").font(.app(11))
                            Picker("Hora inicio extra", selection: Binding(
                                get: { interval.startMinutes / 60 },
                                set: { draft.extraScheduleIntervals[index].startMinutes = $0 * 60 + (interval.startMinutes % 60) }
                            )) {
                                ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d h", h)).tag(h) }
                            }
                            .labelsHidden()
                            .frame(width: 72)
                            Picker("Minuto inicio extra", selection: Binding(
                                get: { (interval.startMinutes % 60 / 15) * 15 },
                                set: { draft.extraScheduleIntervals[index].startMinutes = (interval.startMinutes / 60) * 60 + $0 }
                            )) {
                                ForEach([0, 15, 30, 45], id: \.self) { m in Text(String(format: ":%02d", m)).tag(m) }
                            }
                            .labelsHidden()
                            .frame(width: 60)
                        }
                        HStack(spacing: 6) {
                            Text("Hasta:").font(.app(11))
                            Picker("Hora fin extra", selection: Binding(
                                get: { interval.endMinutes / 60 },
                                set: { draft.extraScheduleIntervals[index].endMinutes = $0 * 60 + (interval.endMinutes % 60) }
                            )) {
                                ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d h", h)).tag(h) }
                            }
                            .labelsHidden()
                            .frame(width: 72)
                            Picker("Minuto fin extra", selection: Binding(
                                get: { (interval.endMinutes % 60 / 15) * 15 },
                                set: { draft.extraScheduleIntervals[index].endMinutes = (interval.endMinutes / 60) * 60 + $0 }
                            )) {
                                ForEach([0, 15, 30, 45], id: \.self) { m in Text(String(format: ":%02d", m)).tag(m) }
                            }
                            .labelsHidden()
                            .frame(width: 60)
                        }
                        Spacer()
                        Button {
                            draft.extraScheduleIntervals.removeAll { $0.id == interval.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(FocusIconButtonStyle(size: 22, tint: Palette.danger))
                    }
                }

            case .alwaysOn:
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.app(18))
                        .foregroundStyle(Palette.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bloqueo permanente 24/7")
                            .font(.app(13, weight: .semibold))
                        Text("Permanece activo todo el día mientras el interruptor de la regla esté encendido.")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pickRuleApplications() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !draft.apps.contains(where: { $0.id == id }) else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            draft.apps.append(AllowedApp(id: id, name: name, path: url.path))
        }
    }

    private func commitSave() {
        var rule = draft
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.domains = FocusRules.normalizeDomains(rule.domains)
        rule.blockedTitleKeywords = FocusRules.normalizeTitleKeywords(rule.blockedTitleKeywords)
        if !rule.apps.isEmpty || rule.blockGameLibraries {
            rule.blockApps = true
        }
        if rule.kind == .countdown && startCountdownOnSave {
            rule.startCountdown(minutes: rule.countdownMinutes)
        } else if rule.kind == .pomodoro && startCountdownOnSave && rule.activePomodoroDeadline == nil {
            rule.startPomodoro()
        }
        model.saveGeneralRule(rule)
        dismiss()
    }
}
