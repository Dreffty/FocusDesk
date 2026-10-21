import AppKit
import EventKit
import SwiftUI
import FocusCore

struct IntegrationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: CalendarBridge
    @State private var resolving: FocusTask?
    @State private var disconnect = false
    private var vorssaintURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.vorssaint.utils") }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Vorssaint · tu tiempo a la vista", icon: "calendar.badge.clock") {
                    HStack(spacing: 6) {
                        if bridge.pendingCount > 0 {
                            Chip("\(bridge.pendingCount) pendiente(s)", icon: "arrow.triangle.2.circlepath", color: Palette.coral)
                        }
                        if vorssaintURL != nil {
                            Chip("Vorssaint instalado", icon: "checkmark.circle", color: Palette.mint)
                        }
                    }
                }
                Text("FocusDesk envía el horario de tu tarea a un calendario propio. Vorssaint usa ese evento para mostrar la cuenta atrás y el tiempo restante en su isla.")
                    .font(.callout)
                    .foregroundStyle(Palette.muted)
                HStack {
                    Label(bridge.authorized ? "1. Permiso de Calendario concedido" : "1. Permitir acceso a Calendario", systemImage: bridge.authorized ? "checkmark.circle.fill" : "circle")
                        .fontWeight(.medium)
                        .foregroundStyle(bridge.authorized ? Palette.mint : Palette.text)
                    Spacer()
                    if !bridge.authorized {
                        Button(bridge.requesting ? "Esperando permiso…" : "Conectar Calendario") {
                            Task {
                                await bridge.request()
                                model.syncCalendar(resetRetries: true)
                            }
                        }
                        .buttonStyle(FocusPrimaryButton(compact: true))
                        .disabled(bridge.requesting)
                    }
                }
                if !bridge.authorized {
                    HStack {
                        Text("macOS pide acceso completo; FocusDesk modifica solo eventos con su propia marca en el calendario que elijas.")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                        Spacer()
                        Button("Abrir permisos de Calendario") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }.buttonStyle(.focus(.ghost, compact: true))
                    }
                }
                Divider().overlay(Palette.stroke)
                Label("2. Calendario FocusDesk", systemImage: model.workspace.settings.calendarID == nil ? "circle" : "checkmark.circle.fill")
                    .fontWeight(.medium)
                    .foregroundStyle(model.workspace.settings.calendarID == nil ? Palette.text : Palette.mint)
                if let id = model.workspace.settings.calendarID {
                    if let connected = bridge.connected(id) {
                        Text("\(connected.title) · \(connected.source.title)").font(.callout).foregroundStyle(Palette.muted)
                    }
                    HStack(spacing: 8) {
                        Button("Sincronizar ahora") { model.syncCalendar(resetRetries: true) }
                            .buttonStyle(.focusSecondary)
                        if !model.workspace.pendingCalendarOps.isEmpty {
                            Button("Reintentar cola (\(model.workspace.pendingCalendarOps.count))") {
                                model.syncCalendar(resetRetries: true)
                            }.buttonStyle(.focus(.warning))
                        }
                        Spacer()
                        Button("Desconectar…") { disconnect = true }
                            .buttonStyle(.focusGhost)
                    }
                } else if bridge.authorized {
                    HStack(spacing: 8) {
                        ForEach(bridge.existing, id: \.calendarIdentifier) { calendar in
                            Button("Usar FocusDesk · \(calendar.source.title)") { model.connectCalendar(calendar.calendarIdentifier) }
                                .buttonStyle(FocusPrimaryButton(compact: true))
                        }
                        ForEach(bridge.sources, id: \.sourceIdentifier) { source in
                            Button("Crear en \(source.title)\(source.sourceType == .local ? " · solo este Mac" : " · cuenta sincronizada")") {
                                model.chooseCalendarSource(source)
                            }
                            .buttonStyle(.focusSecondary)
                        }
                    }
                    if bridge.sources.isEmpty {
                        Text("No hay cuentas disponibles. Abre Calendar y configura una cuenta; después pulsa Actualizar estado.").font(.caption).foregroundStyle(Palette.coral)
                    }
                }
                HStack {
                    Text(bridge.message).font(.caption).foregroundStyle((bridge.issues.isEmpty && bridge.pendingCount == 0) ? Palette.mint : Palette.coral)
                    Spacer()
                    if let last = bridge.lastSync {
                        Text("Verificado: \(last.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(Palette.muted)
                    }
                }
                if !model.workspace.pendingCalendarOps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cola persistente de sincronización (\(model.workspace.pendingCalendarOps.count)):").font(.caption.weight(.semibold)).foregroundStyle(Palette.coral)
                        ForEach(model.workspace.pendingCalendarOps) { op in
                            HStack {
                                Image(systemName: op.action == .remove ? "trash" : "calendar.badge.clock")
                                Text(op.snapshot?.title ?? "Retirar evento anterior")
                                Spacer()
                                Text("Intento \(op.attempts)/5").font(.caption2).foregroundStyle(Palette.muted)
                            }.font(.caption)
                        }
                    }.padding(10).background(Palette.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(model.workspace.tasks.filter { bridge.issues[$0.id] != nil }) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.title).fontWeight(.medium)
                        Text(bridge.issues[task.id] ?? "").font(.caption).foregroundStyle(Palette.coral)
                        HStack(spacing: 8) {
                            Button("Ver en Calendar") { bridge.openEvent(task) }
                                .buttonStyle(.focus(.secondary, compact: true))
                            Button("Aplicar horario de FocusDesk…") { resolving = task }
                                .buttonStyle(.focus(.warning, compact: true))
                        }
                    }.padding(12).background(Palette.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }
                Divider().overlay(Palette.stroke)
                Label("3. Activar la isla en Vorssaint", systemImage: "sparkles.rectangle.stack").fontWeight(.medium)
                Text("En Vorssaint: Dynamic Island → Calendar. Activa Calendar, cuenta atrás y tiempo restante, y deja seleccionado el calendario FocusDesk. Vorssaint también necesita su permiso de Calendario.").font(.callout).foregroundStyle(Palette.muted)
                HStack(spacing: 8) {
                    Button("Abrir Vorssaint") {
                        if let url = vorssaintURL { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.focusSecondary)
                    .disabled(vorssaintURL == nil)

                    Button("Actualizar estado") { model.checkCalendar() }
                        .buttonStyle(.focusSecondary)

                    if model.workspace.settings.calendarID != nil && bridge.authorized {
                        Button("Crear tarea de prueba · 2 min") { model.createIntegrationTest() }
                            .buttonStyle(.focusGhost)
                            .disabled(model.busy)
                    }
                }
                Text("Vorssaint muestra solo la última hora y no muestra tiempo extra. No controla su Pomodoro. El contador de FocusDesk continúa en el Dock y en la barra; no se da por terminada una tarea al agotarse el tiempo.").font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .confirmationDialog("Se actualizará este evento con el horario de FocusDesk. Si lo eliminaste, se creará de nuevo. Un evento trasladado a otro calendario no se tocará.", isPresented: Binding(get: { resolving != nil }, set: { if !$0 { resolving = nil } }), titleVisibility: .visible) {
            Button("Aplicar horario") { if let task = resolving { model.syncCalendar(forceTaskID: task.id) }; resolving = nil }
        }
        .confirmationDialog("Se desconectará el calendario. Sus eventos existentes se conservan.", isPresented: $disconnect, titleVisibility: .visible) {
            Button("Desconectar") { model.disconnectCalendar() }
        }
    }
}
