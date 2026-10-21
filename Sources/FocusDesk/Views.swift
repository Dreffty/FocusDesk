import AppKit
import FocusCore
import SwiftUI

// MARK: - Shared helpers

extension AppModel {
    var currentPage: AppPage { AppPage(rawValue: page) ?? .today }

    func go(to target: AppPage) {
        withAnimation(.easeOut(duration: 0.15)) { page = target.rawValue }
    }

    func newTaskDraft(for date: Date? = nil) -> FocusTask {
        let day = date ?? selectedDate
        let start = FocusRules.firstFreeSlot(
            on: day,
            tasks: workspace.tasks,
            breaks: workspace.settings.breaks,
            workStartHour: workspace.settings.workStartHour,
            now: Date()
        )
        return FocusTask(scheduledAt: start)
    }

    func shiftSelectedDay(by days: Int) {
        if let moved = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) { selectedDate = moved }
    }

    /// Starts a task from the agenda. Projected occurrences are detached from their series first.
    func startFromAgenda(_ task: FocusTask, isProjected: Bool) {
        if isProjected, let seriesID = task.seriesID, let head = seriesHead(seriesID),
           let index = workspace.tasks.firstIndex(where: { $0.id == head.id }) {
            let (updatedSeries, single) = workspace.tasks[index].detachOccurrence(at: task.scheduledAt, workdays: workspace.settings.workdays)
            saveTask(updatedSeries)
            saveTask(single)
            start(single)
        } else {
            start(task)
        }
    }

    func color(for task: FocusTask) -> Color {
        Palette.category(task.category, in: workspace.settings.categories)
    }
}

private func dayTitle(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Hoy" }
    if calendar.isDateInTomorrow(date) { return "Mañana" }
    if calendar.isDateInYesterday(date) { return "Ayer" }
    return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
}

// MARK: - Main window

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var deleteRecordID: UUID?

    var body: some View {
        content
            // A new text size has to reach every view, including leaf views whose inputs did not change and that
            // SwiftUI would otherwise not redraw: rebuild the tree when the size changes.
            .id(model.workspace.settings.textScale)
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
            Rectangle().fill(Palette.stroke).frame(width: 1)
            VStack(spacing: 0) {
                TopBar(model: model)
                Rectangle().fill(Palette.stroke).frame(height: 1)
                if model.error != nil || model.notice != nil || model.resumePrompt != nil {
                    BannerStack(model: model)
                        .padding(.horizontal, 28)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch model.currentPage {
                        case .today: TodayPage(model: model, onDelete: { model.taskPendingDeletion = $0 })
                        case .week: WeekPage(model: model, onDelete: { model.taskPendingDeletion = $0 })
                        case .history: HistoryPage(model: model, onDeleteRecord: { deleteRecordID = $0 })
                        case .settings: SettingsView(model: model, bridge: model.calendar, reminders: model.reminders)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 1180, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                // A fresh scroll position for each section makes navigation predictable.
                .id(model.currentPage)
            }
            .animation(.easeOut(duration: 0.2), value: model.notice)
            .animation(.easeOut(duration: 0.2), value: model.error)
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Palette.background)
        .tint(Palette.mint)
        .sheet(item: $model.editingTask) { task in TaskEditor(model: model, draft: task) }
        .sheet(isPresented: $model.showCompletion) { CompletionView(model: model) }
        .confirmationDialog("¿Eliminar esta tarea y su evento de calendario?", isPresented: Binding(get: { model.taskPendingDeletion != nil }, set: { if !$0 { model.taskPendingDeletion = nil } }), titleVisibility: .visible) {
            Button("Eliminar tarea", role: .destructive) { if let task = model.taskPendingDeletion { model.deleteTask(task) }; model.taskPendingDeletion = nil }
        }
        .confirmationDialog("¿Borrar esta sesión del historial?", isPresented: Binding(get: { deleteRecordID != nil }, set: { if !$0 { deleteRecordID = nil } }), titleVisibility: .visible) {
            Button("Borrar sesión", role: .destructive) { if let id = deleteRecordID { model.deleteHistoryRecord(id) }; deleteRecordID = nil }
        }
        // One timer at a time: starting another task asks first, so a mistaken tap never discards a live session.
        .confirmationDialog(
            handoffTitle,
            isPresented: Binding(get: { model.handoffRequest != nil }, set: { if !$0 { model.cancelHandoff() } }),
            titleVisibility: .visible
        ) {
            if let requested = model.handoffRequest {
                Button("Terminar y empezar «\(requested.title)»") { model.acceptHandoff() }
                Button("Seguir con la de ahora", role: .cancel) { model.cancelHandoff() }
            }
        } message: {
            Text("Solo puede haber un temporizador en marcha. Terminarás la de ahora y confirmarás su resultado antes de empezar la nueva, así no se pierde el tiempo ya trabajado.")
        }
        // Notices leave by an explicit action — their ✕, the next notice, or moving to another page — never on a timer:
        // "Prefer dismissing views with an explicit action" (`accessibility.md › Cognitive`).
        .onChange(of: model.page) { _, _ in model.notice = nil }
    }

    private var handoffTitle: String {
        guard let requested = model.handoffRequest else { return "" }
        guard let current = model.session else { return "¿Empezar «\(requested.title)»?" }
        return "Tienes «\(current.task.title)» en marcha. ¿La terminas y empiezas «\(requested.title)»?"
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .font(.app(16, weight: .semibold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 30, height: 30)
                    .background(Palette.mint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("focusdesk").font(.app(17, weight: .semibold, design: .rounded))
                    Text("Menos ruido. Más foco.").font(.app(10)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.top, 44)
            .padding(.bottom, 22)
            .padding(.horizontal, 6)

            VStack(spacing: 3) {
                ForEach(AppPage.allCases.filter { $0 != .settings }) { item in
                    SidebarItem(page: item, selected: model.currentPage == item, badge: badge(for: item)) { model.go(to: item) }
                }
            }

            // What the Ajustes badge used to signal, now that Ajustes opens in its own window with ⌘,.
            let calendarAttention = model.calendar.pendingCount + model.calendar.issues.count
            if calendarAttention > 0 {
                Button { model.showSettings?(.connections) } label: {
                    Label(
                        model.calendar.issues.isEmpty ? "Calendar: \(calendarAttention) cambios en cola" : "Calendar: \(calendarAttention) por revisar",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .font(.app(12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.focus(.warning, compact: true))
                .padding(.top, 10)
                .help("Abrir Ajustes › Conexiones y avisos")
            }

            Button { model.editingTask = model.newTaskDraft() } label: {
                Label("Nueva tarea", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.focusSecondary)
            .disabled(model.readOnly)
            .help("Nueva tarea (⌘N)")
            .padding(.top, 16)

            // The running session and its «Terminar» sit up here: the bottom edge of a sidebar is often hidden when
            // the window is moved (`sidebars.md › Desktop`).
            Group {
                if let session = model.session {
                    SidebarSessionCard(model: model, session: session)
                } else if let next = model.next {
                    SidebarNextCard(model: model, task: next)
                }
            }
            .padding(.top, 14)

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(Palette.muted)
                Text(model.workspace.settings.hotKeyEnabled ? "Abrir desde cualquier app" : "Atajo global desactivado")
                    .font(.app(11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if model.workspace.settings.hotKeyEnabled { KeyHint(model.workspace.settings.hotKeyLabel) }
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        // Wider with larger text, so «Terminar» and the countdown never get clipped.
        .frame(width: 228 + 140 * (TextScale.factor - 1))
        .background(Palette.sidebar)
    }

    private func badge(for item: AppPage) -> Int {
        switch item {
        case .settings:
            return model.calendar.pendingCount + model.calendar.issues.count + (model.hasUnsavedChanges || model.corruptFileDetected ? 1 : 0)
        case .today:
            let startOfToday = Calendar.current.startOfDay(for: model.now)
            let overdue = model.scheduledTasks.filter { $0.scheduledAt < startOfToday }.count
            return overdue + model.unscheduledTasks.filter { ($0.dueDate ?? .distantFuture) < model.now }.count
        default: return 0
        }
    }
}

private struct SidebarItem: View {
    let page: AppPage
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: page.icon).font(.app(14, weight: .medium)).frame(width: 20)
                Text(page.rawValue).font(.app(13, weight: selected ? .semibold : .medium))
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.app(10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Palette.warning)
                        .background(Palette.warning.opacity(0.18), in: Capsule())
                } else if hovering && !selected {
                    KeyHint(page.shortcut)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? Palette.mint : (hovering ? Palette.text : Palette.muted))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Palette.mint.opacity(0.11) : (hovering ? Palette.fill : .clear))
            )
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Palette.mint).frame(width: 3, height: 16).offset(x: -7) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("\(page.rawValue) (\(page.shortcut))")
        .accessibilityLabel(page.rawValue)
        .accessibilityValue(badge > 0 ? "\(badge) pendientes" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarSessionCard: View {
    @ObservedObject var model: AppModel
    let session: WorkSession

    var body: some View {
        let remaining = model.currentRemaining(for: session)
        let ended = session.endedAt != nil
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(ended ? Palette.mint : (session.paused ? Palette.warning : Palette.mint)).frame(width: 6, height: 6)
                Text(ended ? "POR CONFIRMAR" : (session.paused ? "EN PAUSA" : "EN SESIÓN"))
                    .font(.app(9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button { model.go(to: .today) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(FocusIconButtonStyle(size: 22))
                    .help("Ver la sesión en Hoy")
                    .accessibilityLabel("Ver la sesión en Hoy")
            }
            Text(session.task.title).font(.app(13, weight: .semibold)).lineLimit(2)
            if !ended {
                Text(FocusRules.clock(remaining))
                    .font(.app(26, weight: .regular, design: .monospaced))
                    .foregroundStyle(remaining < 0 ? Palette.warning : Palette.mint)
                    .modifier(CountdownTransition())
                    .accessibilityLabel(remaining < 0 ? "Tiempo extra" : "Tiempo restante")
                    .accessibilityValue(spokenDuration(remaining))
            }
            HStack(spacing: 6) {
                if !ended {
                    Button { session.paused ? model.resume() : model.pause() } label: {
                        Image(systemName: session.paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.focusIcon)
                    .accessibilityLabel(session.paused ? "Reanudar" : "Pausar")
                    .help(session.paused ? "Reanudar (⌃⌥⌘P)" : "Pausar (⌃⌥⌘P)")
                    Button { model.addTime() } label: { Image(systemName: "plus") }
                        .buttonStyle(.focusIcon)
                        .help("Ampliar 10 minutos")
                        .accessibilityLabel("Ampliar 10 minutos")
                }
                Spacer(minLength: 0)
                Button { model.finish() } label: { Label(ended ? "Confirmar" : "Terminar", systemImage: "checkmark") }
                    .buttonStyle(FocusPrimaryButton(compact: true))
                    .disabled(model.busy)
                    .help("He terminado (⌃⌥⌘T)")
            }
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.mint.opacity(0.18), lineWidth: 1))
    }
}

private struct SidebarNextCard: View {
    @ObservedObject var model: AppModel
    let task: FocusTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SIGUIENTE").font(.app(9, weight: .bold)).tracking(1.2).foregroundStyle(Palette.muted)
            Text(task.title).font(.app(13, weight: .semibold)).lineLimit(2)
            Text(task.isScheduled ? "\(dayTitle(for: task.scheduledAt)) · \(task.scheduledAt.formatted(date: .omitted, time: .shortened)) · \(task.minutes) min" : "Sin hora · \(task.minutes) min")
                .font(.app(11))
                .foregroundStyle(Palette.muted)
            HStack(spacing: 6) {
                Button { model.start(task) } label: { Label("Empezar", systemImage: "play.fill") }
                    .buttonStyle(FocusPrimaryButton(compact: true))
                    .disabled(model.busy || model.readOnly)
                    .help("Empezar siguiente (⌃⌥⌘S)")
                Button { model.snoozeTask(task, minutes: 10) } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.focusIcon)
                    .disabled(model.busy || model.readOnly)
                    .help("Posponer 10 minutos")
                    .accessibilityLabel("Posponer 10 minutos")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

// MARK: - Top bar and banners

private struct TopBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.app(10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(Palette.muted)
                Text(model.currentPage.headline).font(.app(22, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 12)
            if model.calendar.pendingCount > 0 {
                Button { model.syncCalendar(resetRetries: true) } label: {
                    Label("Calendar: \(model.calendar.pendingCount) pendiente(s)", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.focus(.warning, compact: true))
                .help("Reintentar ahora la sincronización con Calendar")
            }
            if model.currentPage != .settings {
                Button { model.editingTask = model.newTaskDraft() } label: { Label("Nueva tarea", systemImage: "plus") }
                    .buttonStyle(FocusPrimaryButton())
                    .disabled(model.readOnly)
                    .help("Nueva tarea (⌘N)")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background(Palette.background)
    }
}

private struct BannerStack: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            // Waits for an answer instead of fading away: the Mac paused this session while nobody was watching.
            if let prompt = model.resumePrompt {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill")
                    Text(prompt).font(.app(12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    // Strict pause with no allowed app open: open one and the session resumes by itself.
                    ForEach(model.promptApps.prefix(3)) { app in
                        Button("Abrir \(app.name)") { model.openAllowedAppAndResume(app) }
                            .buttonStyle(FocusPrimaryButton(compact: true))
                    }
                    Button("Reanudar") { model.resume() }
                        .buttonStyle(model.promptApps.isEmpty ? FocusButtonStyle(kind: .primary, compact: true) : FocusButtonStyle(kind: .secondary, compact: true))
                    Button("Terminar") { model.dismissResumePrompt(); model.finish() }
                        .buttonStyle(.focus(.secondary, compact: true))
                    Button { model.dismissResumePrompt() } label: { Image(systemName: "xmark") }
                        .buttonStyle(FocusIconButtonStyle(size: 22, tint: Palette.warning))
                        .help("Dejarla en pausa")
                        .accessibilityLabel("Dejarla en pausa")
                }
                .padding(12)
                .foregroundStyle(Palette.warning)
                .background(Palette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.warning.opacity(0.28), lineWidth: 1))
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").padding(.top, 1)
                    Text(error).font(.app(12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if model.hasUnsavedChanges {
                        Button("Reintentar guardado") { _ = model.retrySave() }.buttonStyle(.focus(.secondary, compact: true))
                        Button("Exportar copia") { model.export() }.buttonStyle(.focus(.ghost, compact: true))
                    }
                    if model.corruptFileDetected {
                        Button("Recuperar copia automática") { model.recoverFromAutoBackup() }.buttonStyle(.focus(.secondary, compact: true))
                        Button("Agenda limpia") { model.resetCorruptWorkspacePreservingFile() }
                            .buttonStyle(.focus(.ghost, compact: true))
                            .help("Empieza con datos vacíos conservando el archivo dañado en backups")
                    }
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(FocusIconButtonStyle(size: 22, tint: Palette.danger))
                        .help("Ocultar")
                        .accessibilityLabel("Ocultar")
                }
                .padding(12)
                .foregroundStyle(Palette.danger)
                .background(Palette.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.danger.opacity(0.22), lineWidth: 1))
            }
            if let notice = model.notice {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                    Text(notice).font(.app(12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if model.canUndoAgenda {
                        Button("Deshacer") { model.undoAgendaChange() }
                            .buttonStyle(.focus(.secondary, compact: true))
                            .help("Deshacer el último cambio en la agenda (⌘Z)")
                    }
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(FocusIconButtonStyle(size: 22, tint: Palette.mint))
                        .help("Ocultar")
                        .accessibilityLabel("Ocultar")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundStyle(Palette.mint)
                .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.mint.opacity(0.18), lineWidth: 1))
            }
        }
    }
}

// MARK: - Today

private struct TodayPage: View {
    @ObservedObject var model: AppModel
    var onDelete: (FocusTask) -> Void
    @AppStorage("FocusDesk.dayLayoutHourly") private var hourly = true
    @State private var overdueExpanded = true
    @FocusState private var agendaFocused: Bool

    var body: some View {
        let bundle = model.tasksForDay(model.selectedDate)
        let real = bundle.real
        let projected = bundle.projected
        let pending = real.filter { !$0.completed }
        let plannedMinutes = pending.reduce(0) { $0 + $1.minutes } + projected.reduce(0) { $0 + $1.minutes }
        let overdue = model.scheduledTasks.filter {
            $0.scheduledAt < Calendar.current.startOfDay(for: Date()) && !Calendar.current.isDate($0.scheduledAt, inSameDayAs: model.selectedDate)
        }

        VStack(alignment: .leading, spacing: 22) {
            NotificationPermissionBanner(model: model, reminders: model.reminders)

            if let session = model.session {
                SessionHero(model: model, session: session)
            } else {
                NextUpHero(model: model)
            }

            HStack(spacing: 12) {
                StatPill(label: "Por hacer", value: "\(pending.count + projected.count)", icon: "circle.dotted")
                StatPill(label: "Tiempo previsto", value: "\(plannedMinutes) min", icon: "hourglass", tint: Palette.muted)
                StatPill(label: "Sin horario", value: "\(model.unscheduledTasks.count)", icon: "tray", tint: Palette.warning)
                StatPill(label: "Completadas", value: "\(real.filter(\.completed).count)", icon: "checkmark.circle")
                StatPill(label: "Trabajado", value: Self.workedText(model.workedSeconds(on: model.selectedDate)), icon: "timer", tint: Palette.mint)
            }

            // What slipped from earlier days goes first and open: at the bottom and folded it was easy to miss.
            if !overdue.isEmpty {
                Card(padding: 16) {
                    DisclosureGroup(isExpanded: $overdueExpanded) {
                        VStack(spacing: 8) {
                            ForEach(overdue) { task in TaskRowView(model: model, task: task, onDelete: onDelete) }
                        }
                        .padding(.top, 10)
                    } label: {
                        SectionHeader("Atrasadas de otros días · \(overdue.count)", icon: "exclamationmark.circle", tint: Palette.warning)
                    }
                }
            }

            dayToolbar

            if hourly {
                HourlyDayTimelineView(model: model, date: model.selectedDate, realTasks: real, projectedTasks: projected)
            } else if real.isEmpty && projected.isEmpty {
                EmptyStateView(title: "Un día por diseñar", detail: "Añade una tarea, aplica un perfil o arrastra algo desde la bandeja de pendientes.", icon: "calendar.badge.plus")
            } else {
                VStack(spacing: 8) {
                    ForEach(real) { task in TaskRowView(model: model, task: task, onDelete: onDelete) }
                    if !projected.isEmpty {
                        SectionHeader("Próximas ocurrencias de la serie", icon: "repeat").padding(.top, 8)
                        ForEach(projected) { task in TaskRowView(model: model, task: task, isProjected: true, onDelete: onDelete) }
                    }
                }
            }

            UnscheduledInbox(model: model, onDelete: onDelete)
        }
        // The agenda takes the keyboard: ↑↓ choose a task, ↩ edit, space start, ⌫ delete, ⌥↑↓ move 5 min,
        // ⌥⇧↑↓ change its length, Esc clear. Without this a specific task could only be reached with the mouse.
        .focusable()
        .focusEffectDisabled()
        .focused($agendaFocused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear { agendaFocused = true }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let option = press.modifiers.contains(.option)
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .downArrow, .upArrow:
            let step = press.key == .downArrow ? 1 : -1
            if option && shift { model.resizeSelected(by: 5 * step) }
            else if option { model.nudgeSelected(minutes: 5 * step) }
            else { model.moveSelection(by: step) }
            return .handled
        case .return:
            guard let task = model.selectedTask, task.id != model.session?.task.id else { return .ignored }
            model.editingTask = task
            return .handled
        case .space:
            guard model.selectedTaskIsActionable, let task = model.selectedTask else { return .ignored }
            model.start(task)
            return .handled
        case .delete, .deleteForward:
            guard model.selectedTaskIsActionable || model.selectedTask?.completed == true, let task = model.selectedTask else { return .ignored }
            onDelete(task)
            return .handled
        case .escape:
            guard model.selectedTaskID != nil else { return .ignored }
            model.selectedTaskID = nil
            return .handled
        default:
            return .ignored
        }
    }

    static func workedText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private var dayToolbar: some View {
        let isWorkday = model.workspace.settings.workdays.contains(Calendar.current.component(.weekday, from: model.selectedDate))
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button { model.shiftSelectedDay(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.focusIcon)
                    .help("Día anterior (⌘[)")
                    .accessibilityLabel("Día anterior")
                Button { model.selectedDate = Date() } label: {
                    Text(dayTitle(for: model.selectedDate)).frame(minWidth: 70)
                }
                .buttonStyle(.focus(.ghost, compact: true))
                .help("Volver a hoy (⌘T)")
                Button { model.shiftSelectedDay(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.focusIcon)
                    .help("Día siguiente (⌘])")
                    .accessibilityLabel("Día siguiente")
            }
            DatePicker("Fecha", selection: $model.selectedDate, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 112)
            if !isWorkday { Chip("Día libre", icon: "leaf", color: Palette.mint) }
            Spacer()
            Picker("Vista", selection: $hourly) {
                Label("Horas", systemImage: "calendar.day.timeline.left").tag(true)
                Label("Lista", systemImage: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .help("Vista por horas (arrastrar y redimensionar) o lista")
        }
    }
}

/// Says so when reminders cannot reach the user, instead of failing silently. Observes the reminder service itself so
/// it disappears the moment permission is granted.
private struct NotificationPermissionBanner: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reminders: ReminderService

    var body: some View {
        if !model.preview, model.notificationsNeedAttention {
            let denied = reminders.status == .denied
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.slash.fill").padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Los avisos están desactivados").font(.app(12, weight: .semibold))
                    Text(denied
                         ? "macOS no deja a FocusDesk avisarte: no sabrás que una tarea empieza ni tendrás «Empezar ahora» en el aviso. Actívalos en Ajustes del Sistema → Notificaciones → FocusDesk."
                         : "Sin permiso no te avisaré antes de tus tareas ni cuando llegue su hora.")
                        .font(.app(12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if denied {
                    Button("Abrir Ajustes") { reminders.openSystemSettings() }
                        .buttonStyle(FocusPrimaryButton(compact: true))
                } else {
                    Button("Activar avisos") {
                        Task { await reminders.request(); model.schedule() }
                    }
                    .buttonStyle(FocusPrimaryButton(compact: true))
                }
                Button { model.notificationBannerDismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(FocusIconButtonStyle(size: 22, tint: Palette.warning))
                    .help("Ocultar hasta la próxima vez que abras FocusDesk")
                    .accessibilityLabel("Ocultar aviso de notificaciones")
            }
            .padding(12)
            .foregroundStyle(Palette.warning)
            .background(Palette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.warning.opacity(0.28), lineWidth: 1))
            .task { await reminders.refresh() }
        }
    }
}

private struct NextUpHero: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card(padding: 26) {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("TU SIGUIENTE PASO", systemImage: "sparkle")
                        .font(.app(10, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Palette.mint)
                    if let next = model.next {
                        Text(next.title).font(.app(26, weight: .semibold, design: .rounded)).lineLimit(2)
                        HStack(spacing: 6) {
                            Chip(next.category, color: model.color(for: next))
                            Chip("\(next.minutes) min", icon: "hourglass")
                            if next.isScheduled {
                                Chip("\(dayTitle(for: next.scheduledAt)) · \(next.scheduledAt.formatted(date: .omitted, time: .shortened))", icon: "clock")
                            } else {
                                Chip("Sin hora", icon: "tray")
                            }
                            if let due = next.dueDate {
                                DueChip(due: due, now: model.now)
                            }
                        }
                        HStack(spacing: 10) {
                            Button { model.start(next) } label: { Label("Empezar ahora", systemImage: "play.fill") }
                                .buttonStyle(FocusPrimaryButton())
                                .disabled(model.busy || model.readOnly)
                                .help("Empezar (⌃⌥⌘S)")
                            Button { model.snoozeTask(next, minutes: 10) } label: { Label("Posponer 10 min", systemImage: "clock.arrow.circlepath") }
                                .buttonStyle(.focusSecondary)
                                .disabled(model.busy || model.readOnly)
                            Button { model.editingTask = next } label: { Label("Editar", systemImage: "pencil") }
                                .buttonStyle(.focusGhost)
                        }
                        .padding(.top, 4)
                    } else {
                        Text("Una cosa cada vez.").font(.app(26, weight: .semibold, design: .rounded))
                        Text("Prepara tu primera tarea o aplica un perfil reutilizable. Te ayudamos a volver a ella.")
                            .foregroundStyle(Palette.muted)
                        Button { model.editingTask = model.newTaskDraft() } label: { Label("Crear una tarea", systemImage: "plus") }
                            .buttonStyle(FocusPrimaryButton())
                            .disabled(model.readOnly)
                    }
                }
                Spacer(minLength: 0)
                countdown
            }
        }
    }

    @ViewBuilder private var countdown: some View {
        ZStack {
            Circle().stroke(Palette.mint.opacity(0.08), lineWidth: 1).frame(width: 140, height: 140)
            Circle().stroke(Palette.mint.opacity(0.14), lineWidth: 1).frame(width: 104, height: 104)
            Circle().fill(Palette.mint.opacity(0.07)).frame(width: 70, height: 70)
            if let next = model.next, next.isScheduled, next.scheduledAt > model.now,
               next.scheduledAt.timeIntervalSince(model.now) <= Double(max(10, next.leadMinutes)) * 60 {
                VStack(spacing: 4) {
                    Text("EMPIEZA EN").font(.app(8, weight: .bold)).tracking(1)
                    Text(FocusRules.clock(next.scheduledAt.timeIntervalSince(model.now)))
                        .font(.app(22, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(Palette.mint)
            } else {
                Image(systemName: "scope").font(.app(30, weight: .ultraLight)).foregroundStyle(Palette.mint)
            }
        }
        .accessibilityLabel("Próxima sesión")
    }
}

// MARK: - Task row

struct TaskRowView: View {
    @ObservedObject var model: AppModel
    let task: FocusTask
    var isProjected = false
    var onDelete: (FocusTask) -> Void
    @State private var hovering = false

    private var isActive: Bool { model.session?.task.id == task.id }

    var body: some View {
        let color = model.color(for: task)
        let overlaps = !isProjected && model.workspace.tasks.contains { FocusRules.overlaps(task, $0) }

        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.isScheduled ? task.scheduledAt.formatted(date: .omitted, time: .shortened) : "—")
                    .font(.app(15, weight: .medium, design: .monospaced))
                Text("\(task.minutes) min").font(.app(10)).foregroundStyle(Palette.muted)
            }
            .frame(width: 62, alignment: .leading)

            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.app(15, weight: .medium))
                    .strikethrough(task.completed)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Chip(task.category, color: color)
                    if isProjected { Chip("Próxima", icon: "repeat", color: Palette.mint) }
                    else if task.repeatRule != .never { Chip(task.repeatRule.label, icon: "repeat") }
                    if task.strict { Chip("Estricto", icon: "scope") }
                    if task.isFixedAppointment { Chip("Cita fija", icon: "lock.fill") }
                    if overlaps { Chip("Solapada", icon: "exclamationmark.triangle.fill", color: Palette.warning) }
                    if let issue = model.calendar.issues[task.id] {
                        Chip("Calendar: revisar", icon: "exclamationmark.arrow.triangle.2.circlepath", color: Palette.warning)
                            .help("Vorssaint no mostrará esta cuenta atrás: \(issue) Resuélvelo en Ajustes.")
                    }
                    if let due = task.dueDate {
                        DueChip(due: due, now: model.now)
                    }
                }
            }

            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.opacity(isProjected ? 0.6 : 1)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Palette.mint.opacity(0.5) : (hovering ? Palette.fieldStroke : Palette.stroke),
                              style: StrokeStyle(lineWidth: 1, dash: isProjected ? [5, 3] : []))
        )
        .saturation(task.completed ? 0 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.mint, lineWidth: model.selectedTaskID == task.id ? 2 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2) { if !isActive { model.editingTask = task } }
        .simultaneousGesture(TapGesture().onEnded { if !isProjected { model.selectedTaskID = task.id } })
        .accessibilityAddTraits(model.selectedTaskID == task.id ? .isSelected : [])
        .contextMenu { menuItems }
        .draggable(task.id.uuidString)
        .help(isActive ? "Tarea en sesión" : "Doble clic para editar · arrastra para mover · clic derecho para más acciones")
    }

    @ViewBuilder private var trailing: some View {
        if task.completed {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint).font(.app(15))
        } else if isActive {
            Chip("En sesión", icon: "circle.fill", color: Palette.mint)
        } else {
            HStack(spacing: 6) {
                Button { model.startFromAgenda(task, isProjected: isProjected) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(FocusIconButtonStyle(tint: Palette.mint))
                    .disabled(model.busy || model.readOnly)
                    .help("Empezar ahora")
                    .accessibilityLabel("Empezar \(task.title)")
                if !isProjected {
                    Button { model.snoozeTask(task, minutes: 10) } label: { Image(systemName: "clock.arrow.circlepath") }
                        .buttonStyle(.focusIcon)
                        .disabled(model.busy || model.readOnly)
                        .help("Posponer 10 minutos")
                        .accessibilityLabel("Posponer 10 minutos")
                }
                Menu { menuItems } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28, height: 28)
                    .help("Más acciones")
                    .accessibilityLabel("Más acciones")
            }
        }
    }

    @ViewBuilder private var menuItems: some View {
        if !isActive {
            if !task.completed {
                Button { model.startFromAgenda(task, isProjected: isProjected) } label: { Label("Empezar ahora", systemImage: "play.fill") }
                    .disabled(model.busy || model.readOnly)
            }
            Button { model.editingTask = task } label: { Label(isProjected ? "Editar ocurrencia o serie…" : "Editar…", systemImage: "pencil") }
            if !isProjected && !task.completed {
                Button { model.snoozeTask(task, minutes: 10) } label: { Label("Posponer 10 minutos", systemImage: "clock.arrow.circlepath") }
                Button { model.shift(task, to: task.scheduledAt, durationMinutes: task.minutes + 15) } label: { Label("Alargar 15 minutos", systemImage: "plus.circle") }
                Button { model.moveToInbox(task) } label: { Label("Mover a la bandeja sin hora", systemImage: "tray.and.arrow.down") }
                Divider()
                Button { model.moveToFirstFreeSlotToday(task) } label: { Label("Hoy en el primer hueco", systemImage: "calendar.badge.clock") }
                Button { model.moveToTomorrowSameTime(task) } label: { Label("Mañana a la misma hora", systemImage: "sunrise") }
            }
            if !isProjected {
                Divider()
                Button(role: .destructive) { onDelete(task) } label: { Label("Eliminar…", systemImage: "trash") }
            }
        }
    }
}

// MARK: - Inbox

private struct UnscheduledInbox: View {
    @ObservedObject var model: AppModel
    var onDelete: (FocusTask) -> Void

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Bandeja sin hora · \(model.unscheduledTasks.count)", icon: "tray.full") {
                    Button {
                        model.editingTask = FocusTask(isScheduled: false, dueDate: Calendar.current.date(byAdding: .day, value: 3, to: Date()))
                    } label: { Label("Añadir sin hora", systemImage: "plus") }
                        .buttonStyle(.focus(.secondary, compact: true))
                        .disabled(model.readOnly)
                }
                if model.unscheduledTasks.isEmpty {
                    Text("Guarda aquí tareas como «Preparar guion, antes del viernes» sin reservar todavía una hora. Arrástralas a la agenda cuando decidas cuándo hacerlas.")
                        .font(.app(12))
                        .foregroundStyle(Palette.muted)
                } else {
                    ForEach(model.unscheduledTasks) { task in
                        InboxRow(model: model, task: task, onDelete: onDelete)
                    }
                }
            }
        }
    }
}

private struct InboxRow: View {
    @ObservedObject var model: AppModel
    let task: FocusTask
    var onDelete: (FocusTask) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").font(.app(10)).foregroundStyle(Palette.muted.opacity(0.6)).help("Arrastra a la agenda")
            RoundedRectangle(cornerRadius: 2).fill(model.color(for: task)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.app(14, weight: .medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Chip("\(task.minutes) min", icon: "hourglass")
                    Chip(task.category, color: model.color(for: task))
                    if let due = task.dueDate {
                        DueChip(due: due, now: model.now, prefix: "Antes de")
                    }
                }
            }
            Spacer(minLength: 8)
            Button { model.snoozeTask(task, minutes: 10) } label: { Label("En 10 min", systemImage: "calendar.badge.plus") }
                .buttonStyle(.focus(.secondary, compact: true))
                .disabled(model.busy || model.readOnly)
                .help("Programar para dentro de 10 minutos")
            Button { model.start(task) } label: { Image(systemName: "play.fill") }
                .buttonStyle(FocusIconButtonStyle(tint: Palette.mint))
                .disabled(model.busy || model.readOnly)
                .help("Empezar ahora")
                .accessibilityLabel("Empezar ahora")
            Menu {
                Button { model.editingTask = task } label: { Label("Editar…", systemImage: "pencil") }
                Button {
                    model.scheduleInFirstFreeSlot(task, on: model.selectedDate)
                } label: { Label("Programar en el día seleccionado", systemImage: "calendar") }
                Divider()
                Button(role: .destructive) { onDelete(task) } label: { Label("Eliminar…", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
        }
        .padding(10)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverHighlight()
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.mint, lineWidth: model.selectedTaskID == task.id ? 2 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.editingTask = task }
        .simultaneousGesture(TapGesture().onEnded { model.selectedTaskID = task.id })
        .accessibilityAddTraits(model.selectedTaskID == task.id ? .isSelected : [])
        .draggable(task.id.uuidString)
    }
}

// MARK: - Week

private struct WeekPage: View {
    @ObservedObject var model: AppModel
    var onDelete: (FocusTask) -> Void

    var body: some View {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: model.selectedDate)?.start ?? model.selectedDate
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.focusIcon)
                    .help("Semana anterior")
                    .accessibilityLabel("Semana anterior")
                Text("\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))")
                    .font(.app(15, weight: .semibold))
                    .frame(minWidth: 170)
                Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.focusIcon)
                    .help("Semana siguiente")
                    .accessibilityLabel("Semana siguiente")
                Button("Esta semana") { model.selectedDate = Date() }
                    .buttonStyle(.focus(.ghost, compact: true))
                Spacer()
                Text("Arrastra bloques entre días o a una franja horaria").font(.app(10)).foregroundStyle(Palette.muted)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 92), spacing: 10, alignment: .top), count: 7), alignment: .leading, spacing: 10) {
                ForEach(0..<7, id: \.self) { offset in
                    if let date = Calendar.current.date(byAdding: .day, value: offset, to: start) {
                        WeekDayColumn(model: model, date: date)
                    }
                }
            }

            UnscheduledInbox(model: model, onDelete: onDelete)
        }
    }

    private func shiftWeek(_ value: Int) {
        if let moved = Calendar.current.date(byAdding: .weekOfYear, value: value, to: model.selectedDate) { model.selectedDate = moved }
    }
}

private struct WeekDayColumn: View {
    @ObservedObject var model: AppModel
    let date: Date
    @State private var targeted = false

    var body: some View {
        let weekday = Calendar.current.component(.weekday, from: date)
        let isWorkday = model.workspace.settings.workdays.contains(weekday)
        let isToday = Calendar.current.isDateInToday(date)
        let bundle = model.tasksForDay(date)
        let all = bundle.real + bundle.projected

        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.selectedDate = date
                model.go(to: .today)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.app(10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(isWorkday ? Palette.muted : Palette.warning.opacity(0.8))
                    Spacer(minLength: 0)
                    Text(date.formatted(.dateTime.day()))
                        .font(.app(20, weight: isToday ? .bold : .medium, design: .rounded))
                        .foregroundStyle(isToday ? Palette.background : Palette.text)
                        .frame(minWidth: 30, minHeight: 30)
                        .background(isToday ? Palette.mint : .clear, in: Circle())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Abrir este día por horas")

            Rectangle().fill(Palette.stroke).frame(height: 1)

            ForEach(bundle.real) { task in
                WeekTaskCard(model: model, task: task, isProjected: false, hasOverlap: all.contains { FocusRules.overlaps(task, $0) })
            }
            ForEach(bundle.projected) { task in
                WeekTaskCard(model: model, task: task, isProjected: true, hasOverlap: all.contains { FocusRules.overlaps(task, $0) })
            }

            HStack(spacing: 4) {
                ForEach([("9h", 9), ("12h", 12), ("16h", 16)], id: \.1) { label, hour in
                    SlotDropTarget(label: label) { values in dropTask(values: values, fixedHour: hour) }
                }
            }
            .padding(.top, 2)

            Button { model.editingTask = model.newTaskDraft(for: date) } label: {
                Image(systemName: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.focus(.ghost, compact: true))
            .help("Nueva tarea este día")
            .accessibilityLabel("Nueva tarea este día")

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
        .background(Palette.surface.opacity(isWorkday ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Palette.mint.opacity(0.6) : (isToday ? Palette.mint.opacity(0.25) : Palette.stroke), lineWidth: targeted ? 2 : 1)
        )
        .dropDestination(for: String.self) { values, _ in
            dropTask(values: values, fixedHour: nil)
        } isTargeted: { targeted = $0 }
    }

    private func dropTask(values: [String], fixedHour: Int?) -> Bool {
        guard !model.readOnly, !model.busy, let raw = values.first, let id = UUID(uuidString: raw),
              let task = model.workspace.tasks.first(where: { $0.id == id && !$0.completed }),
              task.id != model.session?.task.id else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: task.scheduledAt)
        let hour = fixedHour ?? (task.isScheduled ? (parts.hour ?? 10) : model.workspace.settings.workStartHour)
        let minute = fixedHour != nil ? 0 : (task.isScheduled ? (parts.minute ?? 0) : 0)
        guard let moved = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date) else { return false }
        model.shift(task, to: moved)
        return true
    }
}

private struct SlotDropTarget: View {
    let label: String
    let onDrop: ([String]) -> Bool
    @State private var targeted = false

    var body: some View {
        Text(label)
            .font(.app(9, weight: .medium, design: .monospaced))
            .foregroundStyle(targeted ? Palette.background : Palette.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(targeted ? Palette.mint : Palette.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .dropDestination(for: String.self) { values, _ in onDrop(values) } isTargeted: { targeted = $0 }
            .help("Suelta aquí para programar a las \(label)")
    }
}

private struct WeekTaskCard: View {
    @ObservedObject var model: AppModel
    let task: FocusTask
    let isProjected: Bool
    let hasOverlap: Bool
    @State private var hovering = false

    var body: some View {
        let color = model.color(for: task)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(task.scheduledAt.formatted(date: .omitted, time: .shortened)).font(.app(10, design: .monospaced)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                if isProjected { Image(systemName: "repeat").font(.app(9)).foregroundStyle(Palette.mint) }
                if hasOverlap { Image(systemName: "exclamationmark.triangle.fill").font(.app(9)).foregroundStyle(Palette.warning) }
            }
            Text(task.title).font(.app(12, weight: .semibold)).lineLimit(3).strikethrough(task.completed)
            Text("\(task.minutes) min").font(.app(10, weight: .medium)).foregroundStyle(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(isProjected ? 0.05 : (hovering ? 0.17 : 0.11)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(hasOverlap ? Palette.warning.opacity(0.7) : (isProjected ? color.opacity(0.35) : .clear),
                              style: StrokeStyle(lineWidth: 1, dash: isProjected ? [4, 3] : []))
        )
        .saturation(task.completed ? 0 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if task.id != model.session?.task.id { model.editingTask = task } }
        .contextMenu {
            if !task.completed && !isProjected && task.id != model.session?.task.id {
                Button { model.start(task) } label: { Label("Empezar ahora", systemImage: "play.fill") }
                    .disabled(model.busy)
                Button { model.shift(task, to: task.scheduledAt, durationMinutes: task.minutes + 15) } label: { Label("Alargar 15 min", systemImage: "plus.circle") }
                if task.minutes > 15 {
                    Button { model.shift(task, to: task.scheduledAt, durationMinutes: task.minutes - 15) } label: { Label("Acortar 15 min", systemImage: "minus.circle") }
                }
                Button { model.snoozeTask(task, minutes: 10) } label: { Label("Posponer 10 min", systemImage: "clock.arrow.circlepath") }
            }
            Button { model.editingTask = task } label: { Label("Editar…", systemImage: "pencil") }
        }
        .draggable(task.id.uuidString)
        .help("\(task.title) · clic para editar, clic derecho para más acciones")
        // Only a tap gesture before: not reachable by keyboard or VoiceOver. Now a button with its state in words.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(weekCardDescription)
        .accessibilityAction { if task.id != model.session?.task.id { model.editingTask = task } }
    }

    private var weekCardDescription: String {
        var parts = ["\(task.scheduledAt.formatted(date: .omitted, time: .shortened)), \(task.title), \(task.minutes) minutos, \(task.category)"]
        if task.completed { parts.append("completada") }
        if hasOverlap { parts.append("solapada con otra tarea") }
        if isProjected { parts.append("ocurrencia futura de una serie") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - History

private struct HistoryPage: View {
    @ObservedObject var model: AppModel
    var onDeleteRecord: (UUID) -> Void
    @State private var search = ""
    @State private var category = "Todas"
    @State private var status = "Todas"
    @State private var range = "Todo"
    @State private var visibleLimit = 50

    private var records: [SessionRecord] {
        let now = Date()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.workspace.history.filter { record in
            if category != "Todas" && record.session.task.category != category { return false }
            if status == "Completadas" && !record.completed { return false }
            if status == "Incompletas" && (record.completed || record.cancelled) { return false }
            if status == "Canceladas" && !record.cancelled { return false }
            if range == "Hoy" && !Calendar.current.isDateInToday(record.session.startedAt) { return false }
            if range == "Ayer" && !Calendar.current.isDateInYesterday(record.session.startedAt) { return false }
            if range == "7 días" && record.session.startedAt < now.addingTimeInterval(-7 * 86400) { return false }
            if range == "30 días" && record.session.startedAt < now.addingTimeInterval(-30 * 86400) { return false }
            if !query.isEmpty {
                let haystack = ([record.session.task.title, record.note, record.session.task.category] + record.confirmedFiles + record.changedFiles)
                    .joined(separator: " ").lowercased()
                if !haystack.contains(query) { return false }
            }
            return true
        }
    }

    var body: some View {
        let list = records
        let sessionMinutes = Int(list.reduce(0) { $0 + $1.session.accumulated } / 60)
        let observedMinutes = Int(list.reduce(0) { $0 + $1.observedSeconds } / 60)
        let completed = list.filter(\.completed).count

        VStack(alignment: .leading, spacing: 18) {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                        TextField("Buscar por tarea, nota, área o archivo…", text: $search).textFieldStyle(.plain).font(.app(14))
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(Palette.muted)
                                .help("Limpiar búsqueda")
                                .accessibilityLabel("Limpiar búsqueda")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.fieldStroke, lineWidth: 1))
                    HStack(spacing: 14) {
                        Picker("Área", selection: $category) {
                            Text("Todas").tag("Todas")
                            ForEach(model.workspace.settings.categories.map(\.name), id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 180)
                        Picker("Estado", selection: $status) {
                            ForEach(["Todas", "Completadas", "Incompletas", "Canceladas"], id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 190)
                        // Natural width: squeezed, the "Periodo" label broke into three lines.
                        Picker("Periodo", selection: $range) {
                            ForEach(["Todo", "Hoy", "Ayer", "7 días", "30 días"], id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Spacer(minLength: 0)
                        if search != "" || category != "Todas" || status != "Todas" || range != "Todo" {
                            Button("Quitar filtros") { search = ""; category = "Todas"; status = "Todas"; range = "Todo" }
                                .buttonStyle(.focus(.ghost, compact: true))
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                StatPill(label: "Sesiones", value: "\(list.count)", icon: "list.bullet.rectangle")
                StatPill(label: "Completadas", value: "\(completed)", icon: "checkmark.circle")
                StatPill(label: "Tiempo de sesión (reloj)", value: "\(sessionMinutes) min", icon: "clock.fill", tint: Palette.muted)
                StatPill(label: "Actividad observada", value: "\(observedMinutes) min", icon: "eye", tint: Palette.muted)
            }

            if list.isEmpty {
                EmptyStateView(
                    title: model.workspace.history.isEmpty ? "Aquí aparecerá tu progreso" : "Nada coincide con los filtros",
                    detail: "Cada registro distingue el tiempo de sesión medido, la actividad observada en apps y los archivos que confirmes como resultado.",
                    icon: "checkmark.seal"
                )
            }

            // Grouped by day with that day's totals: "what did I do yesterday" is one glance, not a hunt through dates.
            let shown = Array(list.prefix(visibleLimit))
            let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.session.startedAt) }
                .sorted { $0.key > $1.key }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(days, id: \.key) { day, dayRecords in
                    let minutes = Int(dayRecords.reduce(0) { $0 + $1.session.accumulated } / 60)
                    let done = dayRecords.filter(\.completed).count
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.dayHeader(day)).font(.app(15, weight: .semibold))
                        Text("\(dayRecords.count) \(dayRecords.count == 1 ? "sesión" : "sesiones") · \(done) \(done == 1 ? "completada" : "completadas") · \(TodayPage.workedText(Double(minutes) * 60))")
                            .font(.app(12))
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.top, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(dayRecords) { record in
                        HistoryRecordCard(record: record) { onDeleteRecord(record.id) }
                    }
                }
            }
            if list.count > visibleLimit {
                Button("Mostrar \(min(50, list.count - visibleLimit)) sesiones más") { visibleLimit += 50 }
                    .buttonStyle(.focusSecondary)
            }
        }
        .onChange(of: search) { _, _ in visibleLimit = 50 }
        .onChange(of: range) { _, _ in visibleLimit = 50 }
    }

    static func dayHeader(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoy" }
        if calendar.isDateInYesterday(day) { return "Ayer" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).capitalized(with: Locale(identifier: "es_ES"))
    }
}

private struct HistoryRecordCard: View {
    let record: SessionRecord
    let onDelete: () -> Void

    private var statusText: String { record.cancelled ? "Cancelada" : (record.completed ? "Completada" : "Sigue pendiente") }
    private var statusColor: Color { record.cancelled ? Palette.muted : (record.completed ? Palette.mint : Palette.warning) }

    var body: some View {
        Card(padding: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: record.cancelled ? "xmark.circle" : (record.completed ? "checkmark.circle.fill" : "pause.circle"))
                    .foregroundStyle(statusColor)
                    .font(.app(17))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(record.session.task.title).font(.app(16, weight: .semibold))
                        Chip(statusText, color: statusColor)
                    }
                    let end = record.session.endedAt ?? record.session.startedAt.addingTimeInterval(record.session.accumulated)
                    Text("\(record.session.startedAt.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened)) · \(Int(record.session.accumulated / 60)) min · \(record.session.task.category)")
                        .font(.app(10))
                        .foregroundStyle(Palette.muted)
                    let steps = record.checklistSteps
                    if !steps.isEmpty {
                        let ticked = steps.filter(\.done)
                        HStack(spacing: 6) {
                            Chip("Checklist \(ticked.count) de \(steps.count)", icon: "checklist", color: ticked.count == steps.count ? Palette.mint : Palette.muted)
                            if !ticked.isEmpty {
                                Text(ticked.map(\.text).joined(separator: " · ")).font(.app(10)).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                        }
                    }
                    if !record.note.isEmpty {
                        Text(record.note).font(.app(12)).foregroundStyle(Palette.text.opacity(0.85))
                    }
                    if !record.confirmedFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Resultado confirmado por ti").font(.app(10, weight: .semibold)).foregroundStyle(Palette.mint)
                            ForEach(record.confirmedFiles, id: \.self) { path in
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.mint)
                                    Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                                    Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                        .buttonStyle(.focus(.ghost, compact: true))
                                }
                                .font(.app(10))
                            }
                        }
                    }
                    if !record.changedFiles.isEmpty {
                        Text("Señal automática: \(record.changedFiles.count) archivo(s) nuevos o modificados en la carpeta")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                    }
                    let summaries = record.appSummaries
                    if !summaries.isEmpty {
                        HStack(spacing: 6) {
                            Text("Observado:").font(.app(10)).foregroundStyle(Palette.muted)
                            ForEach(summaries.prefix(4)) { item in
                                Chip("\(item.name) · \(max(1, Int((item.seconds / 60).rounded()))) min")
                            }
                        }
                    }
                    if !record.session.activities.isEmpty {
                        DisclosureGroup("Actividad observada (\(record.session.activities.count) eventos)") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(record.session.activities.suffix(80)) { activity in
                                    HStack(spacing: 8) {
                                        Text(activity.at.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                                        Text(activity.name).fontWeight(.medium)
                                        if let detail = activity.domain ?? activity.title {
                                            Text(detail).lineLimit(1)
                                        } else if let status = activity.domainStatus ?? activity.titleStatus {
                                            Text("(\(status))").italic()
                                        }
                                        Spacer()
                                        if activity.duration > 0 { Text("\(Int(activity.duration)) s").monospacedDigit() }
                                        if activity.interruption { Image(systemName: "arrow.uturn.backward").foregroundStyle(Palette.warning) }
                                    }
                                    .font(.app(10))
                                    .foregroundStyle(Palette.muted)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.app(10))
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("\(Int(record.session.accumulated / 60)) min").font(.app(20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("de \(record.session.task.minutes) previstos").font(.app(10)).foregroundStyle(Palette.muted)
                    Text("\(record.session.interruptionCount) interrupciones").font(.app(10)).foregroundStyle(Palette.muted)
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(FocusIconButtonStyle(size: 26, tint: Palette.danger))
                        .help("Borrar esta sesión del historial")
                        .padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - Hourly timeline

/// Interactive hourly day timeline: drag a block to change its hour, drag its bottom edge to change duration.
struct HourlyDayTimelineView: View {
    @ObservedObject var model: AppModel
    let date: Date
    let realTasks: [FocusTask]
    let projectedTasks: [FocusTask]

    @State private var moveOffsets: [UUID: CGFloat] = [:]
    @State private var resizeDeltas: [UUID: CGFloat] = [:]

    private let pixelsPerMinute: CGFloat = 1.0
    private let gutter: CGFloat = 58
    private static let dragThreshold: CGFloat = 12

    private var startHour: Int {
        // The live session counts too: one started at 6:00 for a task planned later was drawn at the 7:00 row.
        let starts = (realTasks + projectedTasks).map(\.scheduledAt) + [liveInterval?.start].compactMap { $0 }
        let earliest = starts.map { Calendar.current.component(.hour, from: $0) }.min() ?? model.workspace.settings.workStartHour
        return max(0, min(earliest, model.workspace.settings.workStartHour - 1, 7))
    }

    private var endHour: Int {
        // In minutes from the start of the day: a task from 23:00 to 00:30 used to read "ends at hour 0", cut the
        // grid at 21:00 and vanish from this view.
        let ends = (realTasks + projectedTasks).map(\.end) + [liveInterval?.end].compactMap { $0 }
        let latest = ends.map { end -> Int in
            let minutes = min(24 * 60, wallMinutes(of: end, onDayOf: date))
            return Int((Double(minutes) / 60).rounded(.up))
        }.max() ?? model.workspace.settings.workEndHour
        return min(24, max(latest, model.workspace.settings.workEndHour + 1, 21))
    }

    /// Wall-clock minutes since midnight of `day`, or past 24 h when `moment` falls on a later day.
    private func wallMinutes(of moment: Date, onDayOf day: Date) -> Int {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: moment)
        let sameDay = calendar.isDate(moment, inSameDayAs: day)
        let laterDay = moment > day && !sameDay
        return (laterDay ? 24 * 60 : 0) + (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private static let liveBlockID = UUID(uuidString: "00000000-0000-0000-0000-00000000F0CD")!

    /// The running session, drawn where it really is (started late, extended…) rather than in its planned slot.
    private var liveInterval: (start: Date, end: Date)? {
        guard let s = model.session, Calendar.current.isDate(s.startedAt, inSameDayAs: date) else { return nil }
        let end = s.endedAt ?? CalendarProjection.deadline(for: s, now: model.now, uptime: model.uptime)
        return (s.startedAt, max(end, s.startedAt.addingTimeInterval(60)))
    }

    private var visibleTasks: [FocusTask] {
        let all = realTasks + projectedTasks
        guard liveInterval != nil, let sessionTaskID = model.session?.task.id else { return all }
        return all.filter { $0.id != sessionTaskID }
    }

    private var blockLayout: [UUID: TimelineLayout.Slot] {
        var intervals = visibleTasks.map { TimelineLayout.Interval(id: $0.id, start: $0.scheduledAt, end: $0.end) }
        if let live = liveInterval { intervals.append(.init(id: Self.liveBlockID, start: live.start, end: live.end)) }
        return TimelineLayout.columns(for: intervals)
    }

    private struct BlockFrame {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var continuesTomorrow: Bool
    }

    /// Where a block goes: its column inside its cluster of overlapping blocks, clipped at midnight.
    private func blockFrame(start: Date, minutes: Double, width: CGFloat, slot: TimelineLayout.Slot?) -> BlockFrame {
        let startMinutes = Double(wallMinutes(of: start, onDayOf: date))
        let fromTop = max(0, startMinutes - Double(startHour * 60))
        let untilMidnight = max(0, 24 * 60 - startMinutes)
        let shown = min(minutes, untilMidnight)
        let lane = max(120, width - gutter - 10)
        let slot = slot ?? TimelineLayout.Slot(column: 0, columns: 1)
        let columnWidth = lane / CGFloat(max(1, slot.columns))
        let gap: CGFloat = slot.columns > 1 ? 3 : 0
        return BlockFrame(
            x: gutter + 4 + columnWidth * CGFloat(slot.column),
            y: CGFloat(fromTop) * pixelsPerMinute,
            width: columnWidth - gap,
            height: max(30, CGFloat(shown) * pixelsPerMinute),
            continuesTomorrow: minutes > untilMidnight + 0.5
        )
    }

    private var initialHour: Int {
        if Calendar.current.isDateInToday(date) {
            return max(startHour, Calendar.current.component(.hour, from: Date()) - 1)
        }
        if let first = realTasks.first(where: { !$0.completed }) ?? realTasks.first {
            return max(startHour, Calendar.current.component(.hour, from: first.scheduledAt) - 1)
        }
        return max(startHour, model.workspace.settings.workStartHour)
    }

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Por horas", icon: "calendar.day.timeline.left") {
                    Text("Arrastra un bloque para moverlo · su borde inferior para cambiar la duración · los de borde discontinuo son una vista previa de la serie")
                        .font(.app(10))
                        .foregroundStyle(Palette.muted)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        GeometryReader { geometry in
                            let layout = blockLayout
                            ZStack(alignment: .topLeading) {
                                hourGrid
                                breaks
                                ForEach(visibleTasks) { task in
                                    timelineBlock(
                                        for: task,
                                        isProjected: projectedTasks.contains(where: { $0.id == task.id }),
                                        width: geometry.size.width,
                                        slot: layout[task.id]
                                    )
                                }
                                liveSessionBlock(width: geometry.size.width, slot: layout[Self.liveBlockID])
                                nowLine
                            }
                        }
                        .frame(height: CGFloat(endHour - startHour) * 60 * pixelsPerMinute)
                    }
                    .frame(height: 460)
                    .onAppear { proxy.scrollTo(initialHour, anchor: .top) }
                    .onChange(of: Calendar.current.startOfDay(for: date)) { _, _ in proxy.scrollTo(initialHour, anchor: .top) }
                }
            }
        }
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { hour in
                HourRow(model: model, hour: hour, date: date, gutter: gutter, height: 60 * pixelsPerMinute)
                    .id(hour)
            }
        }
    }

    @ViewBuilder private var breaks: some View {
        ForEach(model.workspace.settings.breaks) { brk in
            if brk.startHour >= startHour && brk.startHour < endHour {
                let y = CGFloat((brk.startHour - startHour) * 60 + brk.startMinute) * pixelsPerMinute
                HStack(spacing: 6) {
                    Image(systemName: "cup.and.saucer.fill")
                    Text("\(brk.title) · \(String(format: "%02d:%02d", brk.startHour, brk.startMinute)) · \(brk.durationMinutes) min")
                    Spacer()
                }
                .font(.app(10))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 10)
                .frame(height: max(20, CGFloat(brk.durationMinutes) * pixelsPerMinute))
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.fill)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Palette.stroke))
                )
                .padding(.leading, gutter + 4)
                .padding(.trailing, 6)
                .offset(y: y)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var nowLine: some View {
        if Calendar.current.isDateInToday(date) {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: model.now)
            let minutes = ((parts.hour ?? 0) - startHour) * 60 + (parts.minute ?? 0)
            if minutes >= 0 && minutes <= (endHour - startHour) * 60 {
                HStack(spacing: 0) {
                    Text(model.now.formatted(date: .omitted, time: .shortened))
                        .font(.app(9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Palette.danger, in: Capsule())
                        .frame(width: gutter, alignment: .trailing)
                    Rectangle().fill(Palette.danger).frame(height: 1.5)
                }
                .offset(y: CGFloat(minutes) * pixelsPerMinute - 7)
                .allowsHitTesting(false)
                .accessibilityLabel("Hora actual")
            }
        }
    }

    private func previewTask(for task: FocusTask) -> FocusTask {
        var copy = task
        let moveMinutes = Int(((moveOffsets[task.id] ?? 0) / pixelsPerMinute / 5.0).rounded()) * 5
        let resizeMinutes = Int(((resizeDeltas[task.id] ?? 0) / pixelsPerMinute / 5.0).rounded()) * 5
        if moveMinutes != 0 { copy.scheduledAt = task.scheduledAt.addingTimeInterval(Double(moveMinutes) * 60) }
        if resizeMinutes != 0 { copy.minutes = FocusRules.clampedMinutes(task.minutes + resizeMinutes) }
        return copy
    }

    /// The running session's block: started late or extended, it shows where the time really goes.
    @ViewBuilder private func liveSessionBlock(width: CGFloat, slot: TimelineLayout.Slot?) -> some View {
        if let live = liveInterval, let s = model.session {
            let frame = blockFrame(start: live.start, minutes: live.end.timeIntervalSince(live.start) / 60, width: width, slot: slot)
            let state = s.endedAt != nil ? "Por confirmar" : (s.paused ? "En pausa" : "En directo")
            let range = "\(live.start.formatted(date: .omitted, time: .shortened))–\(live.end.formatted(date: .omitted, time: .shortened))"
            VStack(alignment: .leading, spacing: 2) {
                if frame.width < 300 {
                    HStack(spacing: 4) {
                        Image(systemName: s.paused ? "pause.fill" : "dot.radiowaves.left.and.right").font(.app(10)).foregroundStyle(Palette.mint)
                        Text(live.start.formatted(date: .omitted, time: .shortened))
                            .font(.app(10, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.text).fixedSize()
                        Text(state).font(.app(10, weight: .semibold)).foregroundStyle(Palette.mint).lineLimit(1)
                    }
                    Text(s.task.title).font(.app(12, weight: .semibold)).lineLimit(frame.height >= 60 ? 2 : 1)
                } else {
                    HStack(spacing: 8) {
                        Text(range).font(.app(10, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.text).fixedSize()
                        Text(s.task.title).font(.app(12, weight: .semibold)).lineLimit(1)
                        Chip(state, icon: s.paused ? "pause.fill" : "dot.radiowaves.left.and.right", color: Palette.mint)
                        Spacer(minLength: 0)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .background(Palette.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.mint, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            )
            .offset(x: frame.x, y: frame.y)
            .zIndex(2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(state): \(s.task.title), de \(range)")
            .help("La sesión tal y como va: empezó a las \(live.start.formatted(date: .omitted, time: .shortened)) y, a este ritmo, acaba a las \(live.end.formatted(date: .omitted, time: .shortened)).")
        }
    }

    private func timelineBlock(for task: FocusTask, isProjected: Bool, width: CGFloat, slot: TimelineLayout.Slot?) -> some View {
        let preview = previewTask(for: task)
        let frame = blockFrame(start: preview.scheduledAt, minutes: Double(preview.minutes), width: width, slot: slot)
        let topY = frame.y
        let blockHeight = frame.height
        let color = model.color(for: task)
        let calendarIssue = model.calendar.issues[task.id]
        let others = (realTasks + projectedTasks).map { $0.id == task.id ? preview : $0 }
        let overlaps = others.contains { FocusRules.overlaps(preview, $0) }
        let isActive = model.session?.task.id == task.id
        let isEditable = !isProjected && !task.completed && !isActive && !model.readOnly
        let dragging = moveOffsets[task.id] != nil || resizeDeltas[task.id] != nil

        // Side by side, columns get narrow: then a compact layout keeps the start time and the title readable
        // instead of truncating everything to "Gra…" with a clipped chip. Overlap is already shown by the columns.
        let compact = frame.width < 300
        let range = "\(preview.scheduledAt.formatted(date: .omitted, time: .shortened))–\(preview.end.formatted(date: .omitted, time: .shortened))"
        var state: [String] = []
        if task.completed { state.append("completada") }
        if isActive { state.append("en sesión") }
        if overlaps { state.append("solapada con otra tarea") }
        if isProjected { state.append("ocurrencia futura de una serie") }
        if frame.continuesTomorrow { state.append("sigue mañana") }
        if calendarIssue != nil { state.append("Calendar necesita revisión") }
        let spoken: String = state.isEmpty ? "\(range), \(task.title)" : "\(range), \(task.title), " + state.joined(separator: ", ")

        return VStack(alignment: .leading, spacing: 2) {
            blockHeader(
                task: task, preview: preview, isProjected: isProjected, isActive: isActive, overlaps: overlaps,
                compact: compact, blockHeight: blockHeight, dragging: dragging, calendarIssue: calendarIssue,
                continuesTomorrow: frame.continuesTomorrow, range: range
            )
            Spacer(minLength: 0)
            if isEditable && blockHeight >= 38 {
                HStack {
                    Spacer()
                    Capsule()
                        .fill(color.opacity(0.7))
                        .frame(width: 40, height: 4)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle().inset(by: -6))
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        .help("Arrastra para cambiar la duración")
                        .gesture(
                            DragGesture()
                                .onChanged { value in resizeDeltas[task.id] = value.translation.height }
                                .onEnded { value in
                                    resizeDeltas[task.id] = nil
                                    guard abs(value.translation.height) >= Self.dragThreshold else { return }
                                    let delta = Int((value.translation.height / pixelsPerMinute / 5.0).rounded()) * 5
                                    if delta != 0 { model.shift(task, to: task.scheduledAt, durationMinutes: FocusRules.clampedMinutes(task.minutes + delta)) }
                                }
                        )
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: frame.width, height: blockHeight, alignment: .topLeading)
        .background(color.opacity(isProjected ? 0.10 : (dragging ? 0.30 : 0.20)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 5)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(model.selectedTaskID == task.id ? Palette.text : (overlaps ? Palette.warning : (isActive ? Palette.mint : color.opacity(0.45))),
                              style: StrokeStyle(lineWidth: model.selectedTaskID == task.id ? 2.5 : (overlaps || isActive ? 1.5 : 1), dash: isProjected ? [5, 3] : []))
        )
        .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: 8, y: 3)
        .saturation(task.completed ? 0 : 1)
        .offset(x: frame.x, y: topY)
        .zIndex(dragging ? 1 : 0)
        .onTapGesture(count: 2) { if !isActive { model.editingTask = task } }
        .simultaneousGesture(TapGesture().onEnded { if !isProjected { model.selectedTaskID = task.id } })
        .modifier(BlockAccessibility(model: model, task: task, spoken: spoken, isProjected: isProjected, isActive: isActive, isEditable: isEditable))
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard isEditable else { return }
                    moveOffsets[task.id] = value.translation.height
                }
                .onEnded { value in
                    guard isEditable else { return }
                    moveOffsets[task.id] = nil
                    // At least half a 5-minute step of real movement: a click with a little jitter must not
                    // silently move the task and rewrite its reminder and Calendar event.
                    guard abs(value.translation.height) >= Self.dragThreshold else { return }
                    let delta = Int((value.translation.height / pixelsPerMinute / 5.0).rounded()) * 5
                    if delta != 0 { model.shift(task, to: task.scheduledAt.addingTimeInterval(Double(delta) * 60)) }
                }
        )
        .contextMenu {
            if isEditable {
                Button { model.shift(task, to: task.scheduledAt, durationMinutes: task.minutes + 15) } label: { Label("Alargar 15 min", systemImage: "plus.circle") }
                if task.minutes > 15 {
                    Button { model.shift(task, to: task.scheduledAt, durationMinutes: task.minutes - 15) } label: { Label("Acortar 15 min", systemImage: "minus.circle") }
                }
                Button { model.snoozeTask(task, minutes: 10) } label: { Label("Posponer 10 min", systemImage: "clock.arrow.circlepath") }
                Button { model.moveToInbox(task) } label: { Label("Mover a la bandeja sin hora", systemImage: "tray.and.arrow.down") }
            }
            if !isActive { Button { model.editingTask = task } label: { Label("Editar…", systemImage: "pencil") } }
        }
        .help(helpText(isProjected: isProjected, isActive: isActive, task: task))
    }

    private func helpText(isProjected: Bool, isActive: Bool, task: FocusTask) -> String {
        if isProjected { return "\(task.title) · ocurrencia futura de la serie. Edita la serie o púlsala para separar esta ocurrencia." }
        if isActive { return "\(task.title) · en sesión. Usa los controles de la sesión para pausar o terminar." }
        if task.completed { return "\(task.title) · completada" }
        return "\(task.title) · arrastra para moverla, su borde inferior para la duración"
    }
    @ViewBuilder private func blockHeader(
        task: FocusTask, preview: FocusTask, isProjected: Bool, isActive: Bool, overlaps: Bool, compact: Bool,
        blockHeight: CGFloat, dragging: Bool, calendarIssue: String?, continuesTomorrow: Bool, range: String
    ) -> some View {
            if compact {
                HStack(spacing: 4) {
                    Text(preview.scheduledAt.formatted(date: .omitted, time: .shortened))
                        .font(.app(10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(dragging ? Palette.text : Palette.muted)
                        .fixedSize()
                    if blockHeight < 44 {
                        Text(task.title).font(.app(12, weight: .semibold)).lineLimit(1).strikethrough(task.completed)
                    }
                    if overlaps { Image(systemName: "exclamationmark.triangle.fill").font(.app(10)).foregroundStyle(Palette.warning) }
                    if isProjected { Image(systemName: "repeat").font(.app(10)).foregroundStyle(Palette.mint) }
                    if calendarIssue != nil { Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").font(.app(10)).foregroundStyle(Palette.warning) }
                    Spacer(minLength: 0)
                    if !task.completed && !isActive {
                        Button { model.startFromAgenda(task, isProjected: isProjected) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(FocusIconButtonStyle(size: 20, tint: Palette.mint))
                            .disabled(model.busy || model.readOnly)
                            .help(model.session == nil ? "Empezar ahora" : "Empezar esta en lugar de la que está en marcha")
                            .accessibilityLabel("Empezar \(task.title)")
                    }
                }
                if blockHeight >= 44 {
                    Text(task.title)
                        .font(.app(12, weight: .semibold))
                        .lineLimit(blockHeight >= 60 ? 2 : 1)
                        .strikethrough(task.completed)
                }
            } else {
                HStack(spacing: 8) {
                    Text(range)
                        .font(.app(10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(dragging ? Palette.text : Palette.muted)
                        .fixedSize()
                    Text(task.title).font(.app(12, weight: .semibold)).lineLimit(1).strikethrough(task.completed)
                    if isProjected { Image(systemName: "repeat").font(.app(10)).foregroundStyle(Palette.mint) }
                    if isActive { Chip("En sesión", color: Palette.mint) }
                    if overlaps { Chip("Solapa", icon: "exclamationmark.triangle.fill", color: Palette.warning) }
                    if continuesTomorrow { Chip("Sigue mañana", icon: "arrow.turn.down.right") }
                    if let calendarIssue {
                        Chip("Calendar", icon: "exclamationmark.arrow.triangle.2.circlepath", color: Palette.warning)
                            .help("Vorssaint no mostrará esta cuenta atrás: \(calendarIssue) Resuélvelo en Ajustes.")
                    }
                    Spacer(minLength: 4)
                    if !task.completed && !isActive {
                        Button { model.startFromAgenda(task, isProjected: isProjected) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(FocusIconButtonStyle(size: 22, tint: Palette.mint))
                            .disabled(model.busy || model.readOnly)
                            .help(model.session == nil ? "Empezar ahora" : "Empezar esta en lugar de la que está en marcha")
                            .accessibilityLabel("Empezar \(task.title)")
                    }
                    if !isActive {
                        Button { model.editingTask = task } label: { Image(systemName: "pencil") }
                            .buttonStyle(FocusIconButtonStyle(size: 22))
                            .help("Editar")
                            .accessibilityLabel("Editar \(task.title)")
                    }
                }
            }
    }
}

/// One element for VoiceOver with the whole story of a block, and the drag-only edits as named actions.
private struct BlockAccessibility: ViewModifier {
    @ObservedObject var model: AppModel
    let task: FocusTask
    let spoken: String
    let isProjected: Bool
    let isActive: Bool
    let isEditable: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spoken)
            .accessibilityAction(named: "Editar") { if !isActive { model.editingTask = task } }
            .accessibilityAction(named: "Empezar") { if !task.completed && !isActive { model.startFromAgenda(task, isProjected: isProjected) } }
            .accessibilityAction(named: "Adelantar 15 minutos") { if isEditable { model.shift(task, to: task.scheduledAt.addingTimeInterval(-900)) } }
            .accessibilityAction(named: "Retrasar 15 minutos") { if isEditable { model.shift(task, to: task.scheduledAt.addingTimeInterval(900)) } }
            .accessibilityAction(named: "Alargar 15 minutos") { if isEditable { model.shift(task, to: task.scheduledAt, durationMinutes: task.minutes + 15) } }
            .accessibilityAction(named: "Acortar 15 minutos") { if isEditable { model.shift(task, to: task.scheduledAt, durationMinutes: task.minutes - 15) } }
    }
}

private struct HourRow: View {
    @ObservedObject var model: AppModel
    let hour: Int
    let date: Date
    let gutter: CGFloat
    let height: CGFloat
    @State private var targeted = false

    var body: some View {
        let isWorkHour = hour >= model.workspace.settings.workStartHour && hour < model.workspace.settings.workEndHour
        HStack(alignment: .top, spacing: 0) {
            Text(String(format: "%02d:00", hour))
                .font(.app(10, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .frame(width: gutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .offset(y: -6)
            VStack(spacing: 0) {
                Rectangle().fill(Palette.stroke).frame(height: 1)
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(
            Rectangle()
                .fill(targeted ? Palette.mint.opacity(0.10) : (isWorkHour ? Color.clear : Palette.offHours))
                .padding(.leading, gutter)
        )
        .gesture(
            SpatialTapGesture(count: 2).onEnded { value in
                guard !model.readOnly, model.editingTask == nil, !model.showCompletion, value.location.x > gutter,
                      let target = Calendar.current.date(
                        bySettingHour: hour,
                        minute: FocusRules.dropMinute(offset: Double(value.location.y), rowHeight: Double(height)),
                        second: 0,
                        of: date
                      ) else { return }
                var draft = model.newTaskDraft(for: date)
                draft.scheduledAt = target
                model.editingTask = draft
            }
        )
        .help("Doble clic en un hueco para crear una tarea a esa hora")
        .accessibilityHidden(true)
        .dropDestination(for: String.self) { values, location in
            guard !model.readOnly, !model.busy, let raw = values.first, let id = UUID(uuidString: raw),
                  let task = model.workspace.tasks.first(where: { $0.id == id && !$0.completed }),
                  task.id != model.session?.task.id else { return false }
            // Drop where you aimed, in 5-minute steps, like the rest of the timeline — not always on the hour.
            let minute = FocusRules.dropMinute(offset: Double(location.y), rowHeight: Double(height))
            guard let target = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date) else { return false }
            model.shift(task, to: target)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - Session

struct SessionHero: View {
    @ObservedObject var model: AppModel
    var session: WorkSession

    var body: some View {
        let remaining = model.currentRemaining(for: session)
        let elapsed = model.currentElapsed(for: session)
        let progress = min(1, max(0, elapsed / max(1, session.budget)))
        let ended = session.endedAt != nil
        let ringColor = remaining < 0 ? Palette.warning : Palette.mint
        let checks = session.task.checklist.split(separator: "\n").map(String.init)

        Card(padding: 26) {
            HStack(alignment: .center, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Chip(ended ? "RESULTADO PENDIENTE" : (session.paused ? "EN PAUSA" : "AHORA, SOLO ESTO"),
                             icon: ended ? "checkmark.seal" : (session.paused ? "pause.fill" : "circle.fill"),
                             color: session.paused && !ended ? Palette.warning : Palette.mint)
                        Chip(session.task.category, color: model.color(for: session.task))
                        if session.task.strict { Chip("Estricto", icon: "scope") }
                        if let issue = model.calendar.issues[session.task.id] {
                            Chip("Vorssaint sin sincronizar", icon: "exclamationmark.arrow.triangle.2.circlepath", color: Palette.warning)
                                .help("\(issue) Resuélvelo en Ajustes.")
                        }
                    }
                    Text(session.task.title).font(.app(26, weight: .semibold, design: .rounded)).lineLimit(2)
                    Text(session.task.strict ? "Te devolvemos a tus apps de trabajo si te distraes." : "Avisos suaves. Tú decides el ritmo.")
                        .foregroundStyle(Palette.muted)
                    SessionButtons(model: model)
                    if !session.task.apps.isEmpty {
                        Label(session.task.apps.map(\.name).joined(separator: " · "), systemImage: "square.grid.2x2")
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                    }
                    if !checks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(checks.enumerated()), id: \.offset) { index, text in
                                Toggle(isOn: Binding(
                                    get: { model.session?.checked.contains(String(index)) == true },
                                    set: { model.setCheck(String(index), value: $0) }
                                )) { Text(text).font(.app(13)) }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                ZStack {
                    ProgressRing(progress: progress, color: ringColor, lineWidth: 9)
                    VStack(spacing: 4) {
                        Text(FocusRules.clock(remaining))
                            .font(.app(30, weight: .regular, design: .monospaced))
                            .foregroundStyle(ringColor)
                            .modifier(CountdownTransition())
                        Text(remaining < 0 ? "TIEMPO EXTRA" : "RESTANTE")
                            .font(.app(9, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: 168, height: 168)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(remaining < 0 ? "Tiempo extra" : (session.paused && !ended ? "En pausa, tiempo restante" : "Tiempo restante"))
                .accessibilityValue(spokenDuration(remaining))
                .opacity(session.paused && !ended ? 0.6 : 1)
            }
        }
    }
}

struct SessionButtons: View {
    @ObservedObject var model: AppModel
    var compact = false
    @State private var confirmCancel = false

    var body: some View {
        HStack(spacing: 8) {
            Button { model.finish() } label: {
                Label(model.session?.endedAt == nil ? "He terminado" : "Confirmar resultado", systemImage: "checkmark")
            }
            .buttonStyle(FocusPrimaryButton(compact: compact))
            .disabled(model.busy)
            .fixedSize()
            .layoutPriority(1)
            .help("He terminado (⌃⌥⌘T)")
            if model.session?.endedAt == nil {
                let paused = model.session?.paused == true
                Button { paused ? model.resume() : model.pause() } label: {
                    Label(paused ? "Reanudar" : "Pausar", systemImage: paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.focus(.secondary, compact: compact))
                .help(paused ? "Reanudar (⌃⌥⌘P)" : "Pausar (⌃⌥⌘P)")
                // In the 360-pt panel the full label pushed «He terminado» into "He term…".
                Button { model.addTime() } label: { Label(compact ? "10" : "+10 min", systemImage: "plus") }
                    .buttonStyle(.focus(.ghost, compact: compact))
                    .help("Ampliar 10 minutos (⌃⌥⌘A)")
                    .accessibilityLabel("Ampliar 10 minutos")
                Button { confirmCancel = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(FocusIconButtonStyle(size: compact ? 24 : 30, tint: Palette.danger.opacity(0.8)))
                    .help("Cancelar la sesión sin completar la tarea")
                    .accessibilityLabel("Cancelar la sesión sin completar la tarea")
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog("¿Cancelar esta sesión? La tarea seguirá pendiente y la sesión quedará registrada como cancelada.", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancelar sesión", role: .destructive) { model.cancelSession(note: "Sesión cancelada desde los controles de sesión") }
            Button("Seguir trabajando", role: .cancel) {}
        }
    }
}

/// Jot something down without opening the planner: Return files it in the inbox, without a time.
private struct QuickCaptureField: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").foregroundStyle(Palette.muted)
            TextField("Apuntar en la bandeja…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if model.quickCapture(text) { text = "" } }
                .accessibilityLabel("Apuntar una tarea en la bandeja sin hora")
                .help("Escribe y pulsa Intro: queda en la bandeja sin hora para planificarla luego")
        }
        .disabled(model.readOnly)
    }
}

// MARK: - Menu bar panel

struct MenuPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        panel.id(model.workspace.settings.textScale)
    }

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.app(11, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 22, height: 22)
                    .background(Palette.mint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("FocusDesk").font(.app(13, weight: .semibold))
                Spacer()
                if model.calendar.pendingCount > 0 {
                    Chip("\(model.calendar.pendingCount) en cola", icon: "arrow.triangle.2.circlepath", color: Palette.warning)
                        .help("Cambios pendientes de enviar a Calendar")
                }
                Button { model.showWindow?() } label: { Image(systemName: "macwindow") }
                    .buttonStyle(FocusIconButtonStyle(size: 24))
                    .help("Abrir planificador")
                    .accessibilityLabel("Abrir planificador")
            }

            if let s = model.session {
                sessionSection(s)
            } else if let next = model.next {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SIGUIENTE TAREA").font(.app(9, weight: .bold)).tracking(1.2).foregroundStyle(Palette.muted)
                    Text(next.title).font(.app(16, weight: .semibold)).lineLimit(2)
                    Text(next.isScheduled ? "\(dayTitle(for: next.scheduledAt)) · \(next.scheduledAt.formatted(date: .omitted, time: .shortened)) · \(next.minutes) min" : "Bandeja sin hora · \(next.minutes) min")
                        .font(.app(10))
                        .foregroundStyle(Palette.muted)
                }
                HStack(spacing: 8) {
                    Button { model.start(next) } label: { Label("Empezar", systemImage: "play.fill") }
                        .buttonStyle(FocusPrimaryButton())
                        .disabled(model.busy || model.readOnly)
                    Button { model.snoozeTask(next, minutes: 10) } label: { Label("Posponer 10 min", systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(.focusSecondary)
                        .disabled(model.busy || model.readOnly)
                }
            } else {
                Text("Tu agenda tiene espacio.").foregroundStyle(Palette.muted)
                Button { model.showWindow?(); model.editingTask = model.newTaskDraft() } label: { Label("Planificar una tarea", systemImage: "plus") }
                    .buttonStyle(FocusPrimaryButton())
            }

            QuickCaptureField(model: model)
            Rectangle().fill(Palette.stroke).frame(height: 1)
            HStack {
                Button { model.showWindow?() } label: { Label("Planificador", systemImage: "calendar") }
                    .buttonStyle(.focus(.ghost, compact: true))
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Salir", systemImage: "power") }
                    .buttonStyle(.focus(.ghost, compact: true))
                    .help("Salir de FocusDesk (pausa la sesión activa)")
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(Palette.background)
        .tint(Palette.mint)
    }

    @ViewBuilder private func sessionSection(_ s: WorkSession) -> some View {
        Text(s.task.title).font(.app(16, weight: .semibold)).lineLimit(2)
        if s.endedAt != nil {
            Text("Sesión terminada · confirma el resultado").font(.app(10)).foregroundStyle(Palette.mint)
            if let nextTask = model.upcomingAfterSession {
                Text("\(model.queuedStartTask != nil ? "Esperando para empezar" : "Siguiente"): \(nextTask.title) · \(nextTask.minutes) min")
                    .font(.app(10)).foregroundStyle(Palette.muted).lineLimit(1)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button { model.confirm(completed: true, note: "", transition: .startNextNow) } label: { Label("Terminada · empezar siguiente", systemImage: "forward.fill") }
                            .buttonStyle(FocusPrimaryButton(compact: true))
                        Button { model.confirm(completed: true, note: "", transition: .keepSchedule) } label: { Text("Mantener horario") }
                            .buttonStyle(.focus(.secondary, compact: true))
                    }
                    HStack(spacing: 8) {
                        Button { model.confirm(completed: true, note: "", transition: .rest10Min) } label: { Label("Descansar 10 min", systemImage: "cup.and.saucer") }
                            .buttonStyle(.focus(.ghost, compact: true))
                        Button { model.confirm(completed: false, note: "", transition: .keepSchedule) } label: { Text("Sigue pendiente") }
                            .buttonStyle(.focus(.ghost, compact: true))
                        Button { model.showCompletion = true; model.showWindow?() } label: { Text("Detalles…") }
                            .buttonStyle(.focus(.ghost, compact: true))
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button { model.confirm(completed: true, note: "") } label: { Label("Sí, he terminado", systemImage: "checkmark") }
                        .buttonStyle(FocusPrimaryButton(compact: true))
                    Button { model.confirm(completed: false, note: "") } label: { Text("Sigue pendiente") }
                        .buttonStyle(.focus(.secondary, compact: true))
                }
            }
        } else {
            let remaining = model.currentRemaining(for: s)
            HStack(alignment: .firstTextBaseline) {
                Text(FocusRules.clock(remaining))
                    .font(.app(38, weight: .regular, design: .monospaced))
                    .foregroundStyle(remaining < 0 ? Palette.warning : Palette.mint)
                    .modifier(CountdownTransition())
                    .accessibilityLabel(remaining < 0 ? "Tiempo extra" : "Tiempo restante")
                    .accessibilityValue(spokenDuration(remaining))
                if s.paused { Chip("En pausa", icon: "pause.fill", color: Palette.warning) }
            }
            SessionButtons(model: model, compact: true)
            if !s.paused {
                let ends = Date().addingTimeInterval(max(0, remaining))
                Text("Termina a las \(ends.formatted(date: .omitted, time: .shortened))").font(.app(10)).foregroundStyle(Palette.muted)
            }
            if let after = model.upcomingAfterSession {
                Text("Después: \(after.title)\(after.isScheduled ? " · " + after.scheduledAt.formatted(date: .omitted, time: .shortened) : "")")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
    }
}
