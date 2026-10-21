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
        let start = Calendar.current.isDateInToday(day)
            ? Date().addingTimeInterval(600)
            : (Calendar.current.date(bySettingHour: workspace.settings.workStartHour, minute: 0, second: 0, of: day) ?? day)
        return FocusTask(scheduledAt: start)
    }

    func shiftSelectedDay(by days: Int) {
        if let moved = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) { selectedDate = moved }
    }

    /// Starts a task from the agenda. Projected occurrences are detached from their series first.
    func startFromAgenda(_ task: FocusTask, isProjected: Bool) {
        if isProjected, let seriesID = task.seriesID, let index = workspace.tasks.firstIndex(where: { $0.id == seriesID }) {
            let (updatedSeries, single) = workspace.tasks[index].detachOccurrence(at: task.scheduledAt, workdays: workspace.settings.workdays)
            saveTask(updatedSeries)
            saveTask(single)
            start(single)
        } else {
            start(task)
        }
    }

    func moveToInbox(_ task: FocusTask) {
        var unscheduled = task
        unscheduled.isScheduled = false
        saveTask(unscheduled)
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
    @State private var deleteTask: FocusTask?
    @State private var deleteRecordID: UUID?

    var body: some View {
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
                        case .today: TodayPage(model: model, onDelete: { deleteTask = $0 })
                        case .week: WeekPage(model: model, onDelete: { deleteTask = $0 })
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
        .preferredColorScheme(.dark)
        .tint(Palette.mint)
        .sheet(item: $model.editingTask) { task in TaskEditor(model: model, draft: task) }
        .sheet(isPresented: $model.showCompletion) { CompletionView(model: model) }
        .confirmationDialog("¿Eliminar esta tarea y su evento de calendario?", isPresented: Binding(get: { deleteTask != nil }, set: { if !$0 { deleteTask = nil } }), titleVisibility: .visible) {
            Button("Eliminar tarea", role: .destructive) { if let task = deleteTask { model.deleteTask(task) }; deleteTask = nil }
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
        .task(id: model.notice) {
            // Informational notices disappear on their own; errors stay until resolved.
            guard let current = model.notice else { return }
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled, model.notice == current { model.notice = nil }
        }
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
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.background)
                    .frame(width: 30, height: 30)
                    .background(Palette.mint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("focusdesk").font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Menos ruido. Más foco.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.top, 44)
            .padding(.bottom, 22)
            .padding(.horizontal, 6)

            VStack(spacing: 3) {
                ForEach(AppPage.allCases) { item in
                    SidebarItem(page: item, selected: model.currentPage == item, badge: badge(for: item)) { model.go(to: item) }
                }
            }

            Button { model.editingTask = model.newTaskDraft() } label: {
                Label("Nueva tarea", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.focusSecondary)
            .disabled(model.readOnly)
            .help("Nueva tarea (⌘N)")
            .padding(.top, 16)

            Spacer(minLength: 16)

            if let session = model.session {
                SidebarSessionCard(model: model, session: session)
            } else if let next = model.next {
                SidebarNextCard(model: model, task: next)
            }

            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(Palette.muted)
                Text(model.workspace.settings.hotKeyEnabled ? "Abrir desde cualquier app" : "Atajo global desactivado")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.workspace.settings.hotKeyEnabled { KeyHint(model.workspace.settings.hotKeyLabel) }
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .frame(width: 228)
        .background(Palette.sidebar)
    }

    private func badge(for item: AppPage) -> Int {
        switch item {
        case .settings: return model.calendar.pendingCount + (model.hasUnsavedChanges || model.corruptFileDetected ? 1 : 0)
        case .today: return model.unscheduledTasks.filter { ($0.dueDate ?? .distantFuture) < model.now }.count
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
                Image(systemName: page.icon).font(.system(size: 14, weight: .medium)).frame(width: 20)
                Text(page.rawValue).font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Palette.coral)
                        .background(Palette.coral.opacity(0.18), in: Capsule())
                } else if hovering && !selected {
                    KeyHint(page.shortcut)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? Palette.mint : (hovering ? Palette.text : Palette.muted))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Palette.mint.opacity(0.11) : (hovering ? Color.white.opacity(0.045) : .clear))
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
                Circle().fill(ended ? Palette.mint : (session.paused ? Palette.coral : Palette.mint)).frame(width: 6, height: 6)
                Text(ended ? "POR CONFIRMAR" : (session.paused ? "EN PAUSA" : "EN SESIÓN"))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button { model.go(to: .today) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(FocusIconButtonStyle(size: 22))
                    .help("Ver la sesión en Hoy")
            }
            Text(session.task.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            if !ended {
                Text(FocusRules.clock(remaining))
                    .font(.system(size: 26, weight: .light, design: .monospaced))
                    .foregroundStyle(remaining < 0 ? Palette.coral : Palette.mint)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 6) {
                if !ended {
                    Button { session.paused ? model.resume() : model.pause() } label: {
                        Image(systemName: session.paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.focusIcon)
                    .help(session.paused ? "Reanudar (⌃⌥⌘P)" : "Pausar (⌃⌥⌘P)")
                    Button { model.addTime() } label: { Image(systemName: "plus") }
                        .buttonStyle(.focusIcon)
                        .help("Ampliar 10 minutos")
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
            Text("SIGUIENTE").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Palette.muted)
            Text(task.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Text(task.isScheduled ? "\(dayTitle(for: task.scheduledAt)) · \(task.scheduledAt.formatted(date: .omitted, time: .shortened)) · \(task.minutes) min" : "Sin hora · \(task.minutes) min")
                .font(.system(size: 11))
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
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(Palette.muted)
                Text(model.currentPage.headline).font(.system(size: 22, weight: .semibold, design: .rounded))
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
                    Text(prompt).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Reanudar") { model.resume() }
                        .buttonStyle(FocusPrimaryButton(compact: true))
                    Button("Terminar") { model.dismissResumePrompt(); model.finish() }
                        .buttonStyle(.focus(.secondary, compact: true))
                    Button { model.dismissResumePrompt() } label: { Image(systemName: "xmark") }
                        .buttonStyle(FocusIconButtonStyle(size: 22, tint: Palette.coral))
                        .help("Dejarla en pausa")
                }
                .padding(12)
                .foregroundStyle(Palette.coral)
                .background(Palette.coral.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.coral.opacity(0.28), lineWidth: 1))
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").padding(.top, 1)
                    Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
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
                }
                .padding(12)
                .foregroundStyle(Palette.danger)
                .background(Palette.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.danger.opacity(0.22), lineWidth: 1))
            }
            if let notice = model.notice {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                    Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(FocusIconButtonStyle(size: 22, tint: Palette.mint))
                        .help("Ocultar")
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
            if let session = model.session {
                SessionHero(model: model, session: session)
            } else {
                NextUpHero(model: model)
            }

            HStack(spacing: 12) {
                StatPill(label: "Por hacer", value: "\(pending.count + projected.count)", icon: "circle.dotted")
                StatPill(label: "Tiempo previsto", value: "\(plannedMinutes) min", icon: "hourglass", tint: Palette.category("Estudio"))
                StatPill(label: "Sin horario", value: "\(model.unscheduledTasks.count)", icon: "tray", tint: Palette.coral)
                StatPill(label: "Completadas", value: "\(real.filter(\.completed).count)", icon: "checkmark.circle")
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

            if !overdue.isEmpty {
                Card(padding: 16) {
                    DisclosureGroup {
                        VStack(spacing: 8) {
                            ForEach(overdue) { task in TaskRowView(model: model, task: task, onDelete: onDelete) }
                        }
                        .padding(.top, 10)
                    } label: {
                        SectionHeader("Atrasadas de otros días · \(overdue.count)", icon: "exclamationmark.circle")
                    }
                }
            }
        }
    }

    private var dayToolbar: some View {
        let isWorkday = model.workspace.settings.workdays.contains(Calendar.current.component(.weekday, from: model.selectedDate))
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button { model.shiftSelectedDay(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.focusIcon)
                    .help("Día anterior (⌘[)")
                Button { model.selectedDate = Date() } label: {
                    Text(dayTitle(for: model.selectedDate)).frame(minWidth: 70)
                }
                .buttonStyle(.focus(.ghost, compact: true))
                .help("Volver a hoy (⌘T)")
                Button { model.shiftSelectedDay(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.focusIcon)
                    .help("Día siguiente (⌘])")
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

private struct NextUpHero: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card(padding: 26) {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("TU SIGUIENTE PASO", systemImage: "sparkle")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Palette.mint)
                    if let next = model.next {
                        Text(next.title).font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(2)
                        HStack(spacing: 6) {
                            Chip(next.category, color: model.color(for: next))
                            Chip("\(next.minutes) min", icon: "hourglass")
                            if next.isScheduled {
                                Chip("\(dayTitle(for: next.scheduledAt)) · \(next.scheduledAt.formatted(date: .omitted, time: .shortened))", icon: "clock")
                            } else {
                                Chip("Sin hora", icon: "tray")
                            }
                            if let due = next.dueDate {
                                Chip("Límite \(due.formatted(date: .abbreviated, time: .shortened))", icon: "flag", color: due < model.now ? Palette.coral : Palette.muted)
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
                        Text("Una cosa cada vez.").font(.system(size: 26, weight: .semibold, design: .rounded))
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
                    Text("EMPIEZA EN").font(.system(size: 8, weight: .bold)).tracking(1)
                    Text(FocusRules.clock(next.scheduledAt.timeIntervalSince(model.now)))
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(Palette.mint)
            } else {
                Image(systemName: "scope").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Palette.mint)
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
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                Text("\(task.minutes) min").font(.caption).foregroundStyle(Palette.muted)
            }
            .frame(width: 62, alignment: .leading)

            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.system(size: 15, weight: .medium))
                    .strikethrough(task.completed)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Chip(task.category, color: color)
                    if isProjected { Chip("Próxima", icon: "repeat", color: Palette.mint) }
                    else if task.repeatRule != .never { Chip(task.repeatRule.label, icon: "repeat") }
                    if task.strict { Chip("Estricto", icon: "scope") }
                    if task.isFixedAppointment { Chip("Cita fija", icon: "lock.fill") }
                    if overlaps { Chip("Solapada", icon: "exclamationmark.triangle.fill", color: Palette.coral) }
                    if let due = task.dueDate {
                        Chip("Límite \(due.formatted(date: .abbreviated, time: .shortened))", icon: "flag", color: due < model.now ? Palette.coral : Palette.muted)
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
                .strokeBorder(isActive ? Palette.mint.opacity(0.5) : Color.white.opacity(hovering ? 0.12 : 0.05),
                              style: StrokeStyle(lineWidth: 1, dash: isProjected ? [5, 3] : []))
        )
        .opacity(task.completed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2) { if !isActive { model.editingTask = task } }
        .contextMenu { menuItems }
        .draggable(task.id.uuidString)
        .help(isActive ? "Tarea en sesión" : "Doble clic para editar · arrastra para mover · clic derecho para más acciones")
    }

    @ViewBuilder private var trailing: some View {
        if task.completed {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint).font(.title3)
        } else if isActive {
            Chip("EN SESIÓN", icon: "circle.fill", color: Palette.mint)
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
                }
                Menu { menuItems } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28, height: 28)
                    .help("Más acciones")
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
                        .font(.callout)
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
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(Palette.muted.opacity(0.6)).help("Arrastra a la agenda")
            RoundedRectangle(cornerRadius: 2).fill(model.color(for: task)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Chip("\(task.minutes) min", icon: "hourglass")
                    Chip(task.category, color: model.color(for: task))
                    if let due = task.dueDate {
                        Chip("Antes de \(due.formatted(date: .abbreviated, time: .shortened))", icon: "flag.fill", color: due < model.now ? Palette.coral : Palette.mint)
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
            Menu {
                Button { model.editingTask = task } label: { Label("Editar…", systemImage: "pencil") }
                Button {
                    model.shift(task, to: model.startOfWorkingDay(on: model.selectedDate))
                } label: { Label("Programar en el día seleccionado", systemImage: "calendar") }
                Divider()
                Button(role: .destructive) { onDelete(task) } label: { Label("Eliminar…", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
        }
        .padding(10)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverHighlight()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.editingTask = task }
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
                Text("\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 170)
                Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.focusIcon)
                    .help("Semana siguiente")
                Button("Esta semana") { model.selectedDate = Date() }
                    .buttonStyle(.focus(.ghost, compact: true))
                Spacer()
                Text("Arrastra bloques entre días o a una franja horaria").font(.caption).foregroundStyle(Palette.muted)
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
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(isWorkday ? Palette.muted : Palette.coral.opacity(0.8))
                    Spacer(minLength: 0)
                    Text(date.formatted(.dateTime.day()))
                        .font(.system(size: 20, weight: isToday ? .bold : .medium, design: .rounded))
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
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(targeted ? Palette.background : Palette.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(targeted ? Palette.mint : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
                Text(task.scheduledAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                if isProjected { Image(systemName: "repeat").font(.system(size: 9)).foregroundStyle(Palette.mint) }
                if hasOverlap { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Palette.coral) }
            }
            Text(task.title).font(.system(size: 12, weight: .semibold)).lineLimit(3).strikethrough(task.completed)
            Text("\(task.minutes) min").font(.system(size: 10, weight: .medium)).foregroundStyle(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(isProjected ? 0.05 : (hovering ? 0.17 : 0.11)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(hasOverlap ? Palette.coral.opacity(0.7) : (isProjected ? color.opacity(0.35) : .clear),
                              style: StrokeStyle(lineWidth: 1, dash: isProjected ? [4, 3] : []))
        )
        .opacity(task.completed ? 0.55 : 1)
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

    private var records: [SessionRecord] {
        let now = model.now
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.workspace.history.filter { record in
            if category != "Todas" && record.session.task.category != category { return false }
            if status == "Completadas" && !record.completed { return false }
            if status == "Incompletas" && (record.completed || record.cancelled) { return false }
            if status == "Canceladas" && !record.cancelled { return false }
            if range == "Hoy" && !Calendar.current.isDateInToday(record.session.startedAt) { return false }
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
                        TextField("Buscar por tarea, nota, área o archivo…", text: $search).textFieldStyle(.plain).font(.system(size: 14))
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(Palette.muted)
                                .help("Limpiar búsqueda")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack(spacing: 14) {
                        Picker("Área", selection: $category) {
                            Text("Todas").tag("Todas")
                            ForEach(model.workspace.settings.categories.map(\.name), id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 200)
                        Picker("Estado", selection: $status) {
                            ForEach(["Todas", "Completadas", "Incompletas", "Canceladas"], id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 200)
                        Picker("Periodo", selection: $range) {
                            ForEach(["Todo", "Hoy", "7 días", "30 días"], id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
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
                StatPill(label: "Tiempo de sesión (reloj)", value: "\(sessionMinutes) min", icon: "clock.fill", tint: Palette.category("Estudio"))
                StatPill(label: "Actividad observada", value: "\(observedMinutes) min", icon: "eye", tint: Palette.muted)
            }

            if list.isEmpty {
                EmptyStateView(
                    title: model.workspace.history.isEmpty ? "Aquí aparecerá tu progreso" : "Nada coincide con los filtros",
                    detail: "Cada registro distingue el tiempo de sesión medido, la actividad observada en apps y los archivos que confirmes como resultado.",
                    icon: "checkmark.seal"
                )
            }

            ForEach(list) { record in
                HistoryRecordCard(record: record) { onDeleteRecord(record.id) }
            }
        }
    }
}

private struct HistoryRecordCard: View {
    let record: SessionRecord
    let onDelete: () -> Void

    private var statusText: String { record.cancelled ? "Cancelada" : (record.completed ? "Completada" : "Sigue pendiente") }
    private var statusColor: Color { record.cancelled ? Palette.muted : (record.completed ? Palette.mint : Palette.coral) }

    var body: some View {
        Card(padding: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: record.cancelled ? "xmark.circle" : (record.completed ? "checkmark.circle.fill" : "pause.circle"))
                    .foregroundStyle(statusColor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(record.session.task.title).font(.system(size: 16, weight: .semibold))
                        Chip(statusText, color: statusColor)
                    }
                    Text("\(record.session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.session.task.category)")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                    if !record.note.isEmpty {
                        Text(record.note).font(.callout).foregroundStyle(Palette.text.opacity(0.85))
                    }
                    if !record.confirmedFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Resultado confirmado por ti").font(.caption.weight(.semibold)).foregroundStyle(Palette.mint)
                            ForEach(record.confirmedFiles, id: \.self) { path in
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.mint)
                                    Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                                    Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                        .buttonStyle(.focus(.ghost, compact: true))
                                }
                                .font(.caption)
                            }
                        }
                    }
                    if !record.changedFiles.isEmpty {
                        Text("Señal automática: \(record.changedFiles.count) archivo(s) nuevos o modificados en la carpeta")
                            .font(.caption2)
                            .foregroundStyle(Palette.muted)
                    }
                    let summaries = record.appSummaries
                    if !summaries.isEmpty {
                        HStack(spacing: 6) {
                            Text("Observado:").font(.caption2).foregroundStyle(Palette.muted)
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
                                        if activity.interruption { Image(systemName: "arrow.uturn.backward").foregroundStyle(Palette.coral) }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(Palette.muted)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("\(Int(record.session.accumulated / 60)) min").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("de \(record.session.task.minutes) previstos").font(.caption).foregroundStyle(Palette.muted)
                    Text("\(record.session.interruptionCount) interrupciones").font(.caption).foregroundStyle(Palette.muted)
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

    private var startHour: Int {
        let earliest = (realTasks + projectedTasks).map { Calendar.current.component(.hour, from: $0.scheduledAt) }.min() ?? model.workspace.settings.workStartHour
        return max(0, min(earliest, model.workspace.settings.workStartHour - 1, 7))
    }

    private var endHour: Int {
        let latest = (realTasks + projectedTasks).map { Calendar.current.component(.hour, from: $0.end) + 1 }.max() ?? model.workspace.settings.workEndHour
        return min(24, max(latest, model.workspace.settings.workEndHour + 1, 21))
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
                        .font(.caption2)
                        .foregroundStyle(Palette.muted)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            hourGrid
                            breaks
                            ForEach(realTasks + projectedTasks) { task in
                                timelineBlock(for: task, isProjected: projectedTasks.contains(where: { $0.id == task.id }))
                            }
                            nowLine
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
                .font(.caption2)
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 10)
                .frame(height: max(20, CGFloat(brk.durationMinutes) * pixelsPerMinute))
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.03))
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
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.background)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Palette.coral, in: Capsule())
                        .frame(width: gutter, alignment: .trailing)
                    Rectangle().fill(Palette.coral).frame(height: 1.5)
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
        if resizeMinutes != 0 { copy.minutes = max(10, min(720, task.minutes + resizeMinutes)) }
        return copy
    }

    private func timelineBlock(for task: FocusTask, isProjected: Bool) -> some View {
        let preview = previewTask(for: task)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: preview.scheduledAt)
        let minutesFromStart = max(0, ((parts.hour ?? startHour) - startHour) * 60 + (parts.minute ?? 0))
        let topY = CGFloat(minutesFromStart) * pixelsPerMinute
        let blockHeight = max(30, CGFloat(preview.minutes) * pixelsPerMinute)
        let color = model.color(for: task)
        let others = (realTasks + projectedTasks).map { $0.id == task.id ? preview : $0 }
        let overlaps = others.contains { FocusRules.overlaps(preview, $0) }
        let isActive = model.session?.task.id == task.id
        let isEditable = !isProjected && !task.completed && !isActive && !model.readOnly
        let dragging = moveOffsets[task.id] != nil || resizeDeltas[task.id] != nil

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("\(preview.scheduledAt.formatted(date: .omitted, time: .shortened))–\(preview.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(dragging ? Palette.text : Palette.muted)
                Text(task.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).strikethrough(task.completed)
                if isProjected { Image(systemName: "repeat").font(.system(size: 10)).foregroundStyle(Palette.mint) }
                if isActive { Chip("En sesión", color: Palette.mint) }
                if overlaps { Chip("Solapa", icon: "exclamationmark.triangle.fill", color: Palette.coral) }
                Spacer(minLength: 4)
                if !task.completed && !isActive {
                    Button { model.startFromAgenda(task, isProjected: isProjected) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(FocusIconButtonStyle(size: 22, tint: Palette.mint))
                        .disabled(model.busy || model.readOnly)
                        .help(model.session == nil ? "Empezar ahora" : "Empezar esta en lugar de la que está en marcha")
                }
                if !isActive {
                    Button { model.editingTask = task } label: { Image(systemName: "pencil") }
                        .buttonStyle(FocusIconButtonStyle(size: 22))
                        .help("Editar")
                }
            }
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
                                    let delta = Int((value.translation.height / pixelsPerMinute / 5.0).rounded()) * 5
                                    resizeDeltas[task.id] = nil
                                    if delta != 0 { model.shift(task, to: task.scheduledAt, durationMinutes: max(10, min(720, task.minutes + delta))) }
                                }
                        )
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: blockHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(color.opacity(isProjected ? 0.10 : (dragging ? 0.30 : 0.20)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 5)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(overlaps ? Palette.coral : (isActive ? Palette.mint : color.opacity(0.45)),
                              style: StrokeStyle(lineWidth: overlaps || isActive ? 1.5 : 1, dash: isProjected ? [5, 3] : []))
        )
        .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: 8, y: 3)
        .opacity(task.completed ? 0.5 : 1)
        .padding(.leading, gutter + 4)
        .padding(.trailing, 6)
        .offset(y: topY)
        .zIndex(dragging ? 1 : 0)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard isEditable else { return }
                    moveOffsets[task.id] = value.translation.height
                }
                .onEnded { value in
                    guard isEditable else { return }
                    let delta = Int((value.translation.height / pixelsPerMinute / 5.0).rounded()) * 5
                    moveOffsets[task.id] = nil
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
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isWorkHour ? Palette.muted : Palette.muted.opacity(0.4))
                .frame(width: gutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .offset(y: -6)
            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(isWorkHour ? 0.07 : 0.035)).frame(height: 1)
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(
            Rectangle()
                .fill(targeted ? Palette.mint.opacity(0.10) : (isWorkHour ? Color.white.opacity(0.012) : Color.black.opacity(0.16)))
                .padding(.leading, gutter)
        )
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
        let ringColor = remaining < 0 ? Palette.coral : Palette.mint
        let checks = session.task.checklist.split(separator: "\n").map(String.init)

        Card(padding: 26) {
            HStack(alignment: .center, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Chip(ended ? "RESULTADO PENDIENTE" : (session.paused ? "EN PAUSA" : "AHORA, SOLO ESTO"),
                             icon: ended ? "checkmark.seal" : (session.paused ? "pause.fill" : "circle.fill"),
                             color: session.paused && !ended ? Palette.coral : Palette.mint)
                        Chip(session.task.category, color: model.color(for: session.task))
                        if session.task.strict { Chip("Estricto", icon: "scope") }
                    }
                    Text(session.task.title).font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(2)
                    Text(session.task.strict ? "Te devolvemos a tus apps de trabajo si te distraes." : "Avisos suaves. Tú decides el ritmo.")
                        .foregroundStyle(Palette.muted)
                    SessionButtons(model: model)
                    if !session.task.apps.isEmpty {
                        Label(session.task.apps.map(\.name).joined(separator: " · "), systemImage: "square.grid.2x2")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                    if !checks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(checks.enumerated()), id: \.offset) { index, text in
                                Toggle(text, isOn: Binding(
                                    get: { model.session?.checked.contains(String(index)) == true },
                                    set: { model.setCheck(String(index), value: $0) }
                                ))
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
                            .font(.system(size: 30, weight: .light, design: .monospaced))
                            .foregroundStyle(ringColor)
                            .contentTransition(.numericText())
                        Text(remaining < 0 ? "TIEMPO EXTRA" : "RESTANTE")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: 168, height: 168)
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
            .help("He terminado (⌃⌥⌘T)")
            if model.session?.endedAt == nil {
                let paused = model.session?.paused == true
                Button { paused ? model.resume() : model.pause() } label: {
                    Label(paused ? "Reanudar" : "Pausar", systemImage: paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.focus(.secondary, compact: compact))
                .help(paused ? "Reanudar (⌃⌥⌘P)" : "Pausar (⌃⌥⌘P)")
                Button { model.addTime() } label: { Label("+10 min", systemImage: "plus") }
                    .buttonStyle(.focus(.ghost, compact: compact))
                    .help("Ampliar 10 minutos (⌃⌥⌘+)")
                Button { confirmCancel = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(FocusIconButtonStyle(size: compact ? 24 : 30, tint: Palette.danger.opacity(0.8)))
                    .help("Cancelar la sesión sin completar la tarea")
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog("¿Cancelar esta sesión? La tarea seguirá pendiente y la sesión quedará registrada como cancelada.", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancelar sesión", role: .destructive) { model.cancelSession(note: "Sesión cancelada desde los controles de sesión") }
            Button("Seguir trabajando", role: .cancel) {}
        }
    }
}

// MARK: - Menu bar panel

struct MenuPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.background)
                    .frame(width: 22, height: 22)
                    .background(Palette.mint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("FocusDesk").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.calendar.pendingCount > 0 {
                    Chip("\(model.calendar.pendingCount) en cola", icon: "arrow.triangle.2.circlepath", color: Palette.coral)
                        .help("Cambios pendientes de enviar a Calendar")
                }
                Button { model.showWindow?() } label: { Image(systemName: "macwindow") }
                    .buttonStyle(FocusIconButtonStyle(size: 24))
                    .help("Abrir planificador")
            }

            if let s = model.session {
                sessionSection(s)
            } else if let next = model.next {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SIGUIENTE TAREA").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Palette.muted)
                    Text(next.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    Text(next.isScheduled ? "\(dayTitle(for: next.scheduledAt)) · \(next.scheduledAt.formatted(date: .omitted, time: .shortened)) · \(next.minutes) min" : "Bandeja sin hora · \(next.minutes) min")
                        .font(.caption)
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
        .preferredColorScheme(.dark)
        .tint(Palette.mint)
    }

    @ViewBuilder private func sessionSection(_ s: WorkSession) -> some View {
        Text(s.task.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
        if s.endedAt != nil {
            Text("Sesión terminada · confirma el resultado").font(.caption).foregroundStyle(Palette.mint)
            if let nextTask = model.next {
                Text("Siguiente: \(nextTask.title) · \(nextTask.minutes) min").font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
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
                    .font(.system(size: 38, weight: .light, design: .monospaced))
                    .foregroundStyle(remaining < 0 ? Palette.coral : Palette.mint)
                    .contentTransition(.numericText())
                if s.paused { Chip("En pausa", icon: "pause.fill", color: Palette.coral) }
            }
            SessionButtons(model: model, compact: true)
        }
    }
}
