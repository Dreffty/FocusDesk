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
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Vorssaint · tu tiempo a la vista", systemImage: "calendar.badge.clock").font(.title3.weight(.semibold))
                    Spacer()
                    if vorssaintURL != nil { Label("Instalado", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Palette.mint) }
                }
                Text("FocusDesk envía el horario de tu tarea a un calendario propio. Vorssaint usa ese evento para mostrar la cuenta atrás y el tiempo restante en su isla.").foregroundStyle(Palette.muted)
                HStack {
                    Label(bridge.authorized ? "1. Permiso concedido" : "1. Permitir Calendario", systemImage: bridge.authorized ? "checkmark.circle.fill" : "circle").fontWeight(.medium)
                    Spacer()
                    if !bridge.authorized {
                        Button(bridge.requesting ? "Esperando permiso…" : "Conectar Calendario") { Task { await bridge.request() } }.buttonStyle(FocusPrimaryButton()).disabled(bridge.requesting)
                    }
                }
                if !bridge.authorized {
                    Text("macOS pide acceso completo; FocusDesk modifica solo eventos con su propia marca en el calendario que elijas.").font(.caption).foregroundStyle(Palette.muted)
                    Button("Abrir permisos de Calendario") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }.buttonStyle(.borderless)
                }
                Divider()
                Label("2. Calendario FocusDesk", systemImage: model.workspace.settings.calendarID == nil ? "circle" : "checkmark.circle.fill").fontWeight(.medium)
                if let id = model.workspace.settings.calendarID {
                    if let connected = bridge.connected(id) { Text("\(connected.title) · \(connected.source.title)").foregroundStyle(Palette.muted) }
                    HStack {
                        Button("Sincronizar ahora") { model.syncCalendar() }
                        Button("Desconectar…") { disconnect = true }.buttonStyle(.borderless)
                    }
                } else if bridge.authorized {
                    ForEach(bridge.existing, id: \.calendarIdentifier) { calendar in
                        Button("Usar FocusDesk · \(calendar.source.title)") { model.connectCalendar(calendar.calendarIdentifier) }
                    }
                    ForEach(bridge.sources, id: \.sourceIdentifier) { source in
                        Button("Crear en \(source.title)\(source.sourceType == .local ? " · solo este Mac" : " · cuenta sincronizada")") { model.chooseCalendarSource(source) }
                    }
                    if bridge.sources.isEmpty { Text("No hay cuentas disponibles. Abre Calendar y configura una cuenta; después pulsa Actualizar estado.").font(.caption).foregroundStyle(Palette.coral) }
                }
                Text(bridge.message).font(.caption).foregroundStyle(bridge.issues.isEmpty ? Palette.mint : Palette.coral)
                if let last = bridge.lastSync { Text("Último envío: \(last.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(Palette.muted) }
                ForEach(model.workspace.tasks.filter { bridge.issues[$0.id] != nil }) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.title).fontWeight(.medium)
                        Text(bridge.issues[task.id] ?? "").font(.caption).foregroundStyle(Palette.coral)
                        HStack {
                            Button("Ver en Calendar") { bridge.openEvent(task) }
                            Button("Aplicar horario de FocusDesk…") { resolving = task }
                        }.font(.caption)
                    }.padding(12).background(Palette.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }
                Divider()
                Label("3. Activar la isla en Vorssaint", systemImage: "circle").fontWeight(.medium)
                Text("En Vorssaint: Dynamic Island → Calendar. Activa Calendar, cuenta atrás y tiempo restante, y deja seleccionado el calendario FocusDesk. Vorssaint también necesita su permiso de Calendario.").font(.callout).foregroundStyle(Palette.muted)
                HStack {
                    Button("Abrir Vorssaint") {
                        if let url = vorssaintURL { NSWorkspace.shared.open(url) }
                    }.disabled(vorssaintURL == nil)
                    Button("Actualizar estado") { model.checkCalendar() }
                    if model.workspace.settings.calendarID != nil && bridge.authorized {
                        Button("Crear tarea de prueba · 2 min") { model.createIntegrationTest() }.disabled(model.busy)
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
