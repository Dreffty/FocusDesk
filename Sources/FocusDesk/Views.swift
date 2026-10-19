import AppKit
import FocusCore
import ServiceManagement
import SwiftUI

enum Palette {
    static let background = Color(red: 0.055, green: 0.07, blue: 0.09)
    static let surface = Color(red: 0.09, green: 0.11, blue: 0.135)
    static let mint = Color(red: 0.64, green: 0.89, blue: 0.73)
    static let muted = Color(red: 0.56, green: 0.61, blue: 0.64)
    static let coral = Color(red: 1, green: 0.65, blue: 0.48)
    static func category(_ name: String) -> Color { switch name { case "Contenido": return coral; case "Estudio": return .init(red: 0.65, green: 0.69, blue: 0.98); case "Tienda": return mint; default: return .init(red: 0.7, green: 0.78, blue: 0.87) } }
}

struct FocusPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(Palette.background)
            .background(Palette.mint.opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.3), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.07), lineWidth: 1)) }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var deleteTask: FocusTask?
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(.white.opacity(0.05))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let error = model.error { banner(error, color: .red) }
                    if let notice = model.notice { banner(notice, color: Palette.mint) }
                    switch model.page {
                    case "Semana": week
                    case "Historial": history
                    case "Ajustes": SettingsView(model: model, bridge: model.calendar, reminders: model.reminders)
                    default: today
                    }
                }.padding(32).frame(maxWidth: 1150)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 680)
        .background(Palette.background).preferredColorScheme(.dark).tint(Palette.mint)
        .sheet(item: $model.editingTask) { task in TaskEditor(model: model, draft: task) }
        .sheet(isPresented: $model.showCompletion) { CompletionView(model: model) }
        .confirmationDialog("¿Eliminar esta tarea y su evento de calendario?", isPresented: Binding(get: { deleteTask != nil }, set: { if !$0 { deleteTask = nil } }), titleVisibility: .visible) {
            Button("Eliminar tarea", role: .destructive) { if let task = deleteTask { model.deleteTask(task) }; deleteTask = nil }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "scope").font(.system(size: 27, weight: .medium)).foregroundStyle(Palette.mint)
                Text("focusdesk").font(.system(size: 21, weight: .semibold, design: .rounded))
            }.padding(.top, 24)
            Text("MENOS RUIDO. MÁS FOCO.").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(Palette.muted)
            VStack(spacing: 7) {
                ForEach([("Hoy", "sun.max"), ("Semana", "calendar"), ("Historial", "chart.bar.xaxis"), ("Ajustes", "slider.horizontal.3")], id: \.0) { item in
                    Button { model.page = item.0 } label: {
                        HStack(spacing: 12) { Image(systemName: item.1).frame(width: 20); Text(item.0).fontWeight(.medium); Spacer(); if model.page == item.0 { Circle().fill(Palette.mint).frame(width: 5, height: 5) } }
                            .padding(13).foregroundStyle(model.page == item.0 ? Palette.mint : Palette.muted)
                            .background(model.page == item.0 ? Palette.mint.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "command").foregroundStyle(Palette.mint)
                Text("Tu siguiente paso,\nsiempre a mano.").font(.system(size: 14, weight: .medium)).lineSpacing(3)
                Text("⌃ ⌥ ⌘ F").font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            Label("En tu Mac", systemImage: "internaldrive").font(.caption).foregroundStyle(Palette.muted)
        }.padding(20).frame(width: 208).background(.black.opacity(0.13))
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased()).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Palette.muted)
                Text(model.page == "Hoy" ? "Haz espacio para lo importante." : model.page == "Semana" ? "Una semana con intención." : model.page == "Historial" ? "Lo que has hecho cuenta." : "A tu manera.").font(.system(size: 28, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 10)
            if model.page != "Ajustes" {
                Button { model.editingTask = FocusTask(scheduledAt: Calendar.current.isDateInToday(model.selectedDate) ? Date().addingTimeInterval(600) : Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: model.selectedDate)!) } label: { Label("Nueva tarea", systemImage: "plus").padding(.vertical, 5) }.buttonStyle(FocusPrimaryButton()).foregroundStyle(Palette.background).disabled(model.readOnly)
            }
        }
    }
    private var today: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let session = model.session { SessionHero(model: model, session: session) }
            else { emptyHero }
            HStack {
                Text("TU PLAN").font(.system(size: 11, weight: .semibold)).tracking(1.8).foregroundStyle(Palette.muted)
                Spacer()
                DatePicker("Fecha", selection: $model.selectedDate, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                Button("Hoy") { model.selectedDate = Date() }.buttonStyle(.borderless)
            }
            let dayTasks = model.workspace.tasks.filter { Calendar.current.isDate($0.scheduledAt, inSameDayAs: model.selectedDate) }.sorted { $0.scheduledAt < $1.scheduledAt }
            if dayTasks.isEmpty { emptyState("Un día por diseñar", detail: "Añade una tarea, elige cuánto tiempo darle y prepara tu espacio de trabajo.", icon: "calendar.badge.plus") }
            ForEach(dayTasks) { task in taskRow(task) }
            if !model.tasks.filter({ $0.scheduledAt < Calendar.current.startOfDay(for: Date()) }).isEmpty {
                DisclosureGroup("Pendientes de otros días") {
                    ForEach(model.tasks.filter { $0.scheduledAt < Calendar.current.startOfDay(for: Date()) }) { task in taskRow(task) }
                }.foregroundStyle(Palette.muted)
            }
            HStack(spacing: 14) {
                miniStat("POR HACER", value: "\(dayTasks.filter { !$0.completed }.count)", icon: "circle.dotted")
                miniStat("TIEMPO PREVISTO", value: "\(dayTasks.filter { !$0.completed }.reduce(0) { $0 + $1.minutes }) min", icon: "hourglass")
                miniStat("COMPLETADAS", value: "\(dayTasks.filter(\.completed).count)", icon: "checkmark.circle")
            }
        }
    }
    private var emptyHero: some View {
        Card {
            HStack(alignment: .center, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("TU SIGUIENTE PASO", systemImage: "sparkle").font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(Palette.mint)
                    Text(model.next?.title ?? "Una cosa cada vez.").font(.system(size: 29, weight: .medium, design: .rounded))
                    Text(model.next.map { "\($0.minutes) minutos para \($0.category.lowercased()). Todo empieza con un pequeño paso." } ?? "Prepara tu primera tarea. Nosotros te ayudamos a volver a ella.").foregroundStyle(Palette.muted).lineSpacing(4)
                    if let task = model.next {
                        Button { model.start(task) } label: { Label("Empezar ahora", systemImage: "play.fill").padding(.vertical, 6) }.buttonStyle(FocusPrimaryButton()).foregroundStyle(Palette.background).disabled(model.busy || model.readOnly)
                    } else {
                        Button("Crear mi primera tarea") { model.editingTask = FocusTask() }.buttonStyle(FocusPrimaryButton()).foregroundStyle(Palette.background).disabled(model.readOnly)
                    }
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(Palette.mint.opacity(0.10), lineWidth: 1).frame(width: 148, height: 148)
                    Circle().stroke(Palette.mint.opacity(0.16), lineWidth: 1).frame(width: 112, height: 112)
                    Circle().fill(Palette.mint.opacity(0.08)).frame(width: 76, height: 76)
                    if let next = model.next, next.scheduledAt > model.now, next.scheduledAt.timeIntervalSince(model.now) <= Double(next.leadMinutes) * 60 {
                        VStack(spacing: 6) { Text("EMPIEZA EN").font(.system(size: 8, weight: .bold)).tracking(1); Text(FocusRules.clock(next.scheduledAt.timeIntervalSince(model.now))).font(.system(size: 24, weight: .medium, design: .monospaced)) }.foregroundStyle(Palette.mint)
                    } else { Image(systemName: "scope").font(.system(size: 33, weight: .ultraLight)).foregroundStyle(Palette.mint) }
                }.accessibilityLabel("Próxima sesión")
            }.padding(.vertical, 12)
        }
    }
    private var week: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button { model.selectedDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: model.selectedDate)! } label: { Image(systemName: "chevron.left") }
                Text(model.selectedDate.formatted(.dateTime.month(.wide).year())).font(.title3)
                Button { model.selectedDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: model.selectedDate)! } label: { Image(systemName: "chevron.right") }
                Spacer(); Button("Esta semana") { model.selectedDate = Date() }
            }
            let start = Calendar.current.dateInterval(of: .weekOfYear, for: model.selectedDate)!.start
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(0..<7) { offset in
                        let date = Calendar.current.date(byAdding: .day, value: offset, to: start)!
                        let tasks = model.workspace.tasks.filter { Calendar.current.isDate($0.scheduledAt, inSameDayAs: date) }.sorted { $0.scheduledAt < $1.scheduledAt }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
                            Text(date.formatted(.dateTime.day())).font(.system(size: 28, weight: .medium)).foregroundStyle(Calendar.current.isDateInToday(date) ? Palette.mint : .white)
                            Divider()
                            ForEach(tasks) { task in
                                Button { if task.id != model.session?.task.id { model.editingTask = task } } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        Text(task.scheduledAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(Palette.muted)
                                        Text(task.title).font(.system(size: 13, weight: .semibold)).lineLimit(4).strikethrough(task.completed)
                                        Text("\(task.minutes) min").font(.caption2).foregroundStyle(Palette.category(task.category))
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.category(task.category).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain)
                            }
                            Button { model.editingTask = FocusTask(scheduledAt: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: date)!) } label: { Image(systemName: "plus").frame(maxWidth: .infinity).padding(10) }.buttonStyle(.borderless)
                            Spacer()
                        }.padding(14).frame(width: 144, alignment: .topLeading).frame(minHeight: 400).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            Text("Pulsa un bloque para cambiar su hora, duración o perfil. Los solapamientos se señalan al editar.").font(.caption).foregroundStyle(Palette.muted)
        }
    }
    private var history: some View {
        VStack(spacing: 14) {
            if model.workspace.history.isEmpty { emptyState("Aquí aparecerá tu progreso", detail: "Al terminar una sesión verás el tiempo real, las interrupciones y el resultado que confirmes.", icon: "checkmark.seal") }
            ForEach(model.workspace.history) { record in
                Card {
                    HStack(alignment: .top) {
                        Image(systemName: record.completed ? "checkmark.circle.fill" : "pause.circle").foregroundStyle(record.completed ? Palette.mint : Palette.coral).font(.title2)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(record.session.task.title).font(.title3.weight(.semibold))
                            Text(record.session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Palette.muted)
                            Text(record.note.isEmpty ? (record.completed ? "Completada · confirmada por ti" : "Sesión incompleta") : record.note).foregroundStyle(Palette.muted)
                            if !record.changedFiles.isEmpty { Text("\(record.changedFiles.count) archivos nuevos o modificados").font(.caption).foregroundStyle(Palette.mint) }
                            DisclosureGroup("Actividad registrada") {
                                ForEach(record.session.activities.suffix(80)) { activity in
                                    HStack { Text(activity.at.formatted(date: .omitted, time: .shortened)); Text(activity.name); Text(activity.domain ?? activity.title ?? "").lineLimit(1); Spacer(); if activity.interruption { Image(systemName: "arrow.uturn.backward").foregroundStyle(Palette.coral) } }.font(.caption).foregroundStyle(Palette.muted)
                                }
                            }.font(.caption)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) { Text("\(Int(record.session.accumulated / 60)) min").font(.title2.monospacedDigit()); Text("de \(record.session.task.minutes) previstos").font(.caption).foregroundStyle(Palette.muted); Text("\(record.session.interruptionCount) interrupciones").font(.caption).foregroundStyle(Palette.muted) }
                    }
                }
            }
        }
    }
    private func taskRow(_ task: FocusTask) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) { Text(task.scheduledAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 16, weight: .medium, design: .monospaced)); Text("\(task.minutes) min").font(.caption).foregroundStyle(Palette.muted) }.frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(Palette.category(task.category)).frame(width: 3, height: 36)
            VStack(alignment: .leading, spacing: 7) {
                Text(task.title).font(.system(size: 16, weight: .medium)).strikethrough(task.completed)
                HStack(spacing: 10) { Text(task.category); if task.strict { Label("Enfoque estricto", systemImage: "scope") }; if task.repeatRule != .never { Image(systemName: "repeat") } }.font(.caption).foregroundStyle(Palette.muted)
            }
            Spacer()
            if task.completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint).font(.title3) }
            else if model.session?.task.id == task.id { Text("EN SESIÓN").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(Palette.mint) }
            else {
                Button { model.start(task) } label: { Image(systemName: "play.fill").padding(5) }.disabled(model.session != nil || model.busy || model.readOnly).accessibilityLabel("Empezar \(task.title)")
                Menu { Button("Editar") { model.editingTask = task }; Button("Posponer 10 minutos") { model.shift(task, to: task.scheduledAt.addingTimeInterval(600)) }; Button("Eliminar", role: .destructive) { deleteTask = task } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
            }
        }.padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 15)).opacity(task.completed ? 0.6 : 1)
    }
    private func miniStat(_ label: String, value: String, icon: String) -> some View {
        Card { VStack(alignment: .leading, spacing: 12) { HStack { Text(label).font(.system(size: 9, weight: .semibold)).tracking(1); Spacer(); Image(systemName: icon) }.foregroundStyle(Palette.muted); Text(value).font(.system(size: 24, weight: .medium, design: .rounded)) } }
    }
    private func banner(_ text: String, color: Color) -> some View {
        HStack { Image(systemName: "info.circle"); Text(text).font(.callout); Spacer(); Button { if color == .red { model.error = nil } else { model.notice = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(14).foregroundStyle(color).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private func emptyState(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 14) { Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(Palette.mint); Text(title).font(.title3.weight(.medium)); Text(detail).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 400) }.padding(36).frame(maxWidth: .infinity).background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct SessionHero: View {
    @ObservedObject var model: AppModel
    var session: WorkSession
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(session.endedAt != nil ? "RESULTADO PENDIENTE" : session.paused ? "EN PAUSA" : "AHORA, SOLO ESTO", systemImage: session.paused ? "pause.circle" : "circle.fill").font(.system(size: 10, weight: .bold)).tracking(1.6).foregroundStyle(Palette.mint)
                    Spacer(); Text(session.task.category).font(.caption).foregroundStyle(Palette.muted)
                }
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 9) { Text(session.task.title).font(.system(size: 27, weight: .medium, design: .rounded)); Text(session.task.strict ? "Te devolvemos a tus apps de trabajo." : "Avisos suaves. Tú decides el ritmo.").foregroundStyle(Palette.muted) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(FocusRules.clock(session.remaining(at: model.now))).font(.system(size: 46, weight: .light, design: .monospaced)).foregroundStyle(session.remaining(at: model.now) < 0 ? Palette.coral : Palette.mint).contentTransition(.numericText())
                        Text(session.remaining(at: model.now) < 0 ? "TIEMPO EXTRA" : "TIEMPO RESTANTE").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted)
                    }
                }
                ProgressView(value: min(1, max(0, session.elapsed(at: model.now) / max(1, session.budget)))).tint(Palette.mint)
                SessionButtons(model: model)
                if !session.task.apps.isEmpty { Text("Tu espacio: " + session.task.apps.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(Palette.muted) }
                let checks = session.task.checklist.split(separator: "\n").map(String.init)
                ForEach(Array(checks.enumerated()), id: \.offset) { index, text in
                    Toggle(text, isOn: Binding(get: { model.session?.checked.contains(String(index)) == true }, set: { model.setCheck(String(index), value: $0) })).toggleStyle(.checkbox)
                }
            }
        }
    }
}

struct SessionButtons: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Button { model.finish() } label: { Label(model.session?.endedAt == nil ? "He terminado" : "Confirmar resultado", systemImage: "checkmark").padding(.vertical, 4) }.buttonStyle(FocusPrimaryButton()).foregroundStyle(Palette.background).disabled(model.busy)
            if model.session?.endedAt == nil {
                Button(model.session?.paused == true ? "Reanudar" : "Pausar") { if model.session?.paused == true { model.resume() } else { model.pause() } }.buttonStyle(.bordered)
                Button("+10 min") { model.addTime() }.buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("FocusDesk", systemImage: "scope").foregroundStyle(Palette.mint); Spacer(); Button { model.showWindow?() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help("Abrir planificador") }
            if let s = model.session {
                Text(s.task.title).font(.title3.weight(.semibold))
                Text(FocusRules.clock(s.remaining(at: model.now))).font(.system(size: 40, weight: .light, design: .monospaced)).foregroundStyle(Palette.mint)
                if s.paused { Text("En pausa").foregroundStyle(Palette.muted) }
                SessionButtons(model: model)
            } else if let next = model.next {
                Text("SIGUIENTE TAREA").font(.caption).foregroundStyle(Palette.muted)
                Text(next.title).font(.title3.weight(.medium))
                Text("\(next.scheduledAt.formatted(date: .abbreviated, time: .shortened)) · \(next.minutes) min").font(.caption).foregroundStyle(Palette.muted)
                Button("Empezar") { model.start(next) }.buttonStyle(FocusPrimaryButton()).disabled(model.busy || model.readOnly)
            } else { Text("Tu agenda tiene espacio.").foregroundStyle(Palette.muted); Button("Planificar una tarea") { model.showWindow?(); model.editingTask = FocusTask() } }
            Divider()
            HStack { Button("Abrir planificador") { model.showWindow?() }.buttonStyle(.borderless); Spacer(); Button("Salir") { NSApp.terminate(nil) }.buttonStyle(.borderless) }.font(.caption)
        }.padding(22).frame(width: 350).background(Palette.background).preferredColorScheme(.dark).tint(Palette.mint)
    }
}
