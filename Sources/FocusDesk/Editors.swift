import AppKit
import FocusCore
import ServiceManagement
import SwiftUI

struct TaskEditor: View {
    @ObservedObject var model: AppModel
    @State var draft: FocusTask
    @Environment(\.dismiss) private var dismiss
    @State private var folderWarning: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Dale un espacio.").font(.system(size: 28, weight: .semibold, design: .rounded)); Text("Un objetivo claro. Un tiempo concreto.").foregroundStyle(Palette.muted) }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { ForEach(["Vídeo", "Estudiar", "Tienda"], id: \.self) { template in Button(template) { applyTemplate(template) }.buttonStyle(.bordered) }; Spacer(); Text("PLANTILLAS").font(.caption2).foregroundStyle(Palette.muted) }
                    VStack(alignment: .leading, spacing: 8) { fieldLabel("¿QUÉ VAS A HACER?"); TextField("Ej. Grabar el vídeo de mañana", text: $draft.title).font(.title3).textFieldStyle(.roundedBorder) }
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 9) { fieldLabel("CUÁNDO"); DatePicker("Inicio", selection: $draft.scheduledAt).labelsHidden(); Button("En diez minutos") { draft.scheduledAt = Date().addingTimeInterval(600) }.buttonStyle(.borderless).font(.caption) }
                        Spacer()
                        VStack(alignment: .leading, spacing: 9) { fieldLabel("DURACIÓN OBLIGATORIA"); Stepper("\(draft.minutes) min", value: $draft.minutes, in: 1...720, step: 5); HStack { ForEach([15, 30, 60, 90], id: \.self) { minutes in Button("\(minutes)") { draft.minutes = minutes }.buttonStyle(.bordered).tint(draft.minutes == minutes ? Palette.mint : .gray) } } }
                    }
                    HStack(spacing: 20) {
                        Picker("Área", selection: $draft.category) { ForEach(["Personal", "Contenido", "Estudio", "Tienda"], id: \.self) { Text($0) } }
                        Picker("Repetición", selection: $draft.repeatRule) { ForEach(RepeatRule.allCases, id: \.self) { Text($0.label).tag($0) } }
                    }
                    Stepper("Avisar \(draft.leadMinutes) minutos antes", value: $draft.leadMinutes, in: 0...60, step: 5)
                    if model.workspace.tasks.contains(where: { FocusRules.overlaps(draft, $0) }) { Label("Este bloque coincide con otra tarea. Solo puede haber una sesión activa.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.coral) }
                    if draft.minutes > 60 { Text("Vorssaint mostrará el final solo durante los últimos 60 minutos. El contador de FocusDesk seguirá visible.").font(.caption).foregroundStyle(Palette.muted) }
                    Divider()
                    HStack { fieldLabel("TU ESPACIO DE TRABAJO"); Spacer(); Button { chooseApps() } label: { Label("Elegir apps", systemImage: "plus") } }
                    if draft.apps.isEmpty { Text("Sin selección: se admiten todas las apps. Añade las necesarias para distinguir distracciones.").font(.callout).foregroundStyle(Palette.muted) }
                    ForEach(draft.apps) { app in
                        HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 25, height: 25); Text(app.name); Spacer(); Button { draft.apps.removeAll { $0.id == app.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                    }
                    Toggle("Volver a una app permitida cuando me distraiga", isOn: $draft.strict).toggleStyle(.switch)
                    Text("Puedes pausar en cualquier momento. Finder, Ajustes, FocusDesk y Vorssaint siguen accesibles. No se cierran aplicaciones.").font(.caption).foregroundStyle(Palette.muted)
                    if draft.strict && draft.apps.isEmpty { Text("Selecciona al menos una aplicación para usar el modo estricto.").font(.caption).foregroundStyle(Palette.coral) }
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("DOMINIOS PARA ESTA TAREA · OPCIONAL")
                        TextField("chatgpt.com, claude.ai", text: $draft.domains).textFieldStyle(.roundedBorder)
                        Text("Sirven para avisar y registrar en Brave. No bloquean páginas. Activa su lectura en Ajustes.").font(.caption).foregroundStyle(Palette.muted)
                    }
                    Divider()
                    fieldLabel("CÓMO SABRÁS QUE HAS TERMINADO")
                    Text("Checklist: un paso por línea").font(.caption).foregroundStyle(Palette.muted)
                    TextEditor(text: $draft.checklist).font(.body).frame(height: 80).padding(6).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12)))
                    HStack { VStack(alignment: .leading, spacing: 4) { Text("Carpeta de resultados"); Text(draft.folder ?? "Opcional. Solo se comparan metadatos.").font(.caption).foregroundStyle(Palette.muted).lineLimit(2) }; Spacer(); Button("Elegir") { chooseFolder() }; if draft.folder != nil { Button("Quitar") { draft.folder = nil }.buttonStyle(.borderless) } }
                    if let folderWarning { Text(folderWarning).font(.caption).foregroundStyle(Palette.coral) }
                }.padding(.trailing, 8)
            }
            HStack { Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Guardar tarea") { model.saveTask(draft); dismiss() }.buttonStyle(FocusPrimaryButton()).foregroundStyle(Palette.background).keyboardShortcut(.defaultAction).disabled(!draft.valid || model.readOnly) }
        }.padding(28).frame(width: 650, height: 780).background(Palette.background).preferredColorScheme(.dark).tint(Palette.mint)
    }
    private func fieldLabel(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Palette.muted) }
    private func chooseApps() {
        let panel = NSOpenPanel(); panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !draft.apps.contains(where: { $0.id == id }) else { continue }
            draft.apps.append(AllowedApp(id: id, name: url.deletingPathExtension().lastPathComponent, path: url.path))
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.folder = url.path; folderWarning = "Elige una carpeta concreta del proyecto; se revisan como máximo 5.000 entradas."
    }
    private func applyTemplate(_ name: String) {
        switch name {
        case "Vídeo": draft.title = "Grabar un vídeo"; draft.category = "Contenido"; draft.minutes = 60; draft.checklist = "Preparar el guion\nGrabar las tomas\nGuardar el material"; draft.domains = "chatgpt.com, claude.ai"
        case "Estudiar": draft.title = "Estudiar un tema"; draft.category = "Estudio"; draft.minutes = 45; draft.checklist = "Repasar el tema\nResolver ejercicios\nAnotar las dudas"; draft.domains = ""
        default: draft.title = "Gestionar la tienda"; draft.category = "Tienda"; draft.minutes = 30; draft.checklist = "Revisar pedidos\nResponder mensajes\nActualizar stock"; draft.domains = ""
        }
        if draft.apps.isEmpty {
            let ids = name == "Vídeo" ? ["com.lemon.lvoverseas", "com.brave.Browser", "com.anthropic.claudefordesktop", "com.openai.chat"] : ["com.brave.Browser"]
            draft.apps = ids.compactMap { id in guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }; return AllowedApp(id: id, name: url.deletingPathExtension().lastPathComponent, path: url.path) }
        }
    }
}

struct CompletionView: View {
    @ObservedObject var model: AppModel
    @State private var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "checkmark.seal").font(.system(size: 38, weight: .light)).foregroundStyle(Palette.mint)
            Text("¿Qué has conseguido?").font(.system(size: 29, weight: .semibold, design: .rounded))
            Text("La sesión ha terminado y las restricciones están desactivadas. Tú confirmas el resultado.").foregroundStyle(Palette.muted)
            if let s = model.session {
                Text(s.task.title).font(.title3.weight(.medium))
                HStack { Label("\(Int(s.accumulated / 60)) min de sesión", systemImage: "clock"); Spacer(); Text("\(s.interruptionCount) interrupciones") }.foregroundStyle(Palette.muted)
                Text("\(s.checked.count) pasos marcados · \(model.changedFiles.count) archivos cambiados").font(.callout).foregroundStyle(Palette.mint)
            }
            if let message = model.evidenceMessage { Text(message).font(.caption).foregroundStyle(Palette.coral) }
            if !model.changedFiles.isEmpty {
                ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(model.changedFiles.prefix(50), id: \.self) { path in Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc").font(.caption).lineLimit(1) } } }.frame(maxHeight: 100)
            }
            Text("Estos datos son señales de actividad, no una prueba de calidad o autoría.").font(.caption).foregroundStyle(Palette.muted)
            TextField("Resultado o próximo paso (opcional)", text: $note, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
            HStack { Button("Sigue pendiente") { model.confirm(completed: false, note: note) }; Spacer(); Button("Sí, he terminado") { model.confirm(completed: true, note: note) }.buttonStyle(FocusPrimaryButton()).foregroundStyle(Palette.background).keyboardShortcut(.defaultAction) }
        }.padding(30).frame(width: 540).background(Palette.background).preferredColorScheme(.dark).tint(Palette.mint).interactiveDismissDisabled()
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: CalendarBridge
    @ObservedObject var reminders: ReminderService
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var eraseDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Vorssaint · tu tiempo a la vista", systemImage: "calendar.badge.clock").font(.title3.weight(.semibold))
                    Text("Conecta un calendario dedicado. En Vorssaint activa Dynamic Island → Calendar, las cuentas atrás y el tiempo restante; selecciona el calendario FocusDesk.").foregroundStyle(Palette.muted)
                    Text(bridge.message).font(.caption).foregroundStyle(Palette.mint)
                    if model.workspace.settings.calendarID == nil {
                        Button("Dar acceso a Calendar") { Task { await bridge.request() } }
                        ForEach(bridge.sources, id: \.sourceIdentifier) { source in
                            Button("Crear FocusDesk en \(source.title)\(source.sourceType == .local ? " · solo este Mac" : " · puede sincronizar")") { model.chooseCalendarSource(source) }
                        }
                        if bridge.authorized && bridge.sources.isEmpty { Text("No hay fuentes de calendario disponibles. Añade una en Calendar; FocusDesk seguirá funcionando sin el puente.").font(.caption).foregroundStyle(Palette.coral) }
                    } else {
                        Button("Actualizar eventos en Calendar") { model.syncCalendar() }
                    }
                    Text("Límite de Vorssaint: solo la última hora; no muestra tiempo extra. Este puente no controla su Pomodoro. Mantén el contador de FocusDesk como respaldo.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 15) {
                    Label("Recordatorios y acceso rápido", systemImage: "bell").font(.title3.weight(.semibold))
                    HStack { Text(reminders.message); Spacer(); Button("Activar notificaciones") { Task { await reminders.request(); model.schedule() } } }
                    Toggle("Abrir FocusDesk al iniciar sesión", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, value in
                        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { model.error = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                    Text("Atajo global: Control + Opción + Comando + F. Cerrar la ventana mantiene la app en la barra. Salir pausa la sesión.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Qué puede observar", systemImage: "hand.raised").font(.title3.weight(.semibold))
                    Text("Solo durante una sesión activa. No se registran teclas ni se capturan pantallas.").foregroundStyle(Palette.muted)
                    Toggle("Leer títulos de ventana", isOn: Binding(get: { model.workspace.settings.observeTitles }, set: { value in model.updateSettings { $0.observeTitles = value } }))
                    HStack { Label(model.accessible ? "Accesibilidad concedida" : "Accesibilidad pendiente para los títulos", systemImage: model.accessible ? "checkmark.circle" : "circle").font(.caption).foregroundStyle(Palette.muted); Spacer(); Button("Conceder Accesibilidad") { MacActivity.requestAccessibility() } }
                    Toggle("Observar el dominio de la pestaña activa en Brave", isOn: Binding(get: { model.workspace.settings.observeBrave }, set: { value in model.updateSettings { $0.observeBrave = value } }))
                    Text("macOS puede pedir permiso de Automatización al usar Brave en una sesión. Solo se guarda el dominio, sin rutas ni parámetros. Si no se obtiene, queda desconocido. Las webs se señalan; no se bloquean.").font(.caption).foregroundStyle(Palette.muted)
                    Text("Los títulos pueden incluir nombres de documentos o datos personales. Puedes desactivar su lectura cuando quieras.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Tus datos, en tu Mac", systemImage: "internaldrive").font(.title3.weight(.semibold))
                    Text("El detalle de actividad se conserva 30 días. Después queda el resumen. Las evidencias de archivos y las notas permanecen en tu historial.").foregroundStyle(Palette.muted)
                    HStack { Button("Exportar copia") { model.export() }; Button("Abrir carpeta de datos") { NSWorkspace.shared.open(model.store.url.deletingLastPathComponent()) }; Button("Borrar detalle de actividad", role: .destructive) { eraseDetails = true } }
                    Text("Versión 0.1 · calendario editable por formulario · las repeticiones generan el siguiente bloque al completar la tarea.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }.confirmationDialog("¿Borrar el detalle de aplicaciones, títulos y dominios de las sesiones anteriores? Los resúmenes se conservan.", isPresented: $eraseDetails, titleVisibility: .visible) { Button("Borrar detalle", role: .destructive) { model.removeDetailedHistory() } }
    }
}
