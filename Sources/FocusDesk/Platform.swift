import AppKit
import ApplicationServices
import Carbon.HIToolbox
import EventKit
import FocusCore
import UserNotifications

struct FileSnapshot: Sendable {
    var files: [String: FileStamp]
    var valid: Bool
    var message: String?
}

actor EvidenceScanner {
    func scan(_ path: String?) -> FileSnapshot {
        guard let path else { return FileSnapshot(files: [:], valid: false, message: "Sin carpeta de resultados; puedes confirmar manualmente.") }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else { return FileSnapshot(files: [:], valid: false, message: "No se puede leer la carpeta de resultados.") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in failed = true; return true }) else {
            return FileSnapshot(files: [:], valid: false, message: "No se pudo inspeccionar la carpeta.")
        }
        var files: [String: FileStamp] = [:]
        var visited = 0
        for case let item as URL in enumerator {
            visited += 1
            if visited > 5000 { failed = true; break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { failed = true; continue }
            guard values.isSymbolicLink != true, values.isRegularFile == true, let date = values.contentModificationDate else { continue }
            guard !["tmp", "temp", "part", "crdownload"].contains(item.pathExtension.lowercased()) else { continue }
            files[item.path] = FileStamp(modified: date, bytes: Int64(values.fileSize ?? 0))
        }
        return FileSnapshot(files: files, valid: !failed, message: failed ? "Lectura parcial (límite de 5.000 entradas o archivos inaccesibles). Confirma el resultado manualmente." : nil)
    }
}

@MainActor
final class CalendarBridge: ObservableObject {
    let store = EKEventStore()
    @Published var sources: [EKSource] = []
    @Published var message = "Sin conectar"
    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    func request() async {
        do {
            guard try await store.requestFullAccessToEvents() else { message = "Permiso de calendario denegado"; return }
            sources = store.sources.filter { $0.sourceType == .local || $0.sourceType == .calDAV || $0.sourceType == .exchange }
            message = "Elige dónde crear el calendario FocusDesk"
        } catch { message = error.localizedDescription }
    }
    func create(in source: EKSource) throws -> String {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "FocusDesk"; calendar.cgColor = NSColor.systemMint.cgColor; calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        message = "Calendario conectado"
        return calendar.calendarIdentifier
    }
    func project(_ task: FocusTask, calendarID: String, start: Date, end: Date) throws -> String {
        guard authorized, let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else { throw BridgeError.calendarUnavailable }
        let marker = "focusdesk://task/" + task.id.uuidString
        let event: EKEvent
        if let id = task.calendarEventID, let old = store.event(withIdentifier: id) {
            guard old.calendar.calendarIdentifier == calendarID, old.url?.absoluteString == marker else { throw BridgeError.ownership }
            event = old
        } else { event = EKEvent(eventStore: store); event.calendar = calendar }
        event.title = task.title; event.startDate = start; event.endDate = max(end, start.addingTimeInterval(1))
        event.url = URL(string: marker); event.notes = "Bloque gestionado por FocusDesk. Edita sus horarios desde FocusDesk."
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }
    func remove(_ task: FocusTask, calendarID: String) throws {
        guard authorized else { throw BridgeError.calendarUnavailable }
        guard let id = task.calendarEventID, let event = store.event(withIdentifier: id) else { return }
        guard event.calendar.calendarIdentifier == calendarID, event.url?.absoluteString == "focusdesk://task/" + task.id.uuidString else { throw BridgeError.ownership }
        try store.remove(event, span: .thisEvent, commit: true)
    }
    enum BridgeError: LocalizedError {
        case calendarUnavailable, ownership
        var errorDescription: String? { self == .calendarUnavailable ? "Calendario no disponible o sin permiso de escritura." : "El evento no pertenece a FocusDesk. No se ha modificado." }
    }
}

@MainActor
final class ReminderService: ObservableObject {
    @Published var message = "Activar avisos"
    let center = UNUserNotificationCenter.current()
    func request() async {
        do { message = try await center.requestAuthorization(options: [.alert, .sound]) ? "Avisos activados" : "Avisos desactivados en macOS" }
        catch { message = error.localizedDescription }
    }
    func schedule(_ tasks: [FocusTask], sessionTaskID: UUID?) {
        center.removeAllPendingNotificationRequests()
        for task in tasks.filter({ !$0.completed && $0.id != sessionTaskID }).sorted(by: { $0.scheduledAt < $1.scheduledAt }).prefix(30) {
            for (suffix, date, title, body) in [
                ("before", task.scheduledAt.addingTimeInterval(-Double(task.leadMinutes) * 60), "En \(task.leadMinutes) min · \(task.title)", "Prepara tu espacio. Tendrás \(task.minutes) minutos."),
                ("start", task.scheduledAt, "Es el momento · \(task.title)", "Abre FocusDesk desde la barra para empezar.")
            ] {
                let delay = date.timeIntervalSinceNow
                guard delay > 1 else { continue }
                let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
                let request = UNNotificationRequest(identifier: task.id.uuidString + suffix, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
                center.add(request) { _ in }
            }
        }
    }
    func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }
}

struct Foreground {
    let app: NSRunningApplication
    let title: String?
}

enum MacActivity {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func foreground(readTitle: Bool) -> Foreground? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var title: String?
        if readTitle && accessibility {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value)
                title = (value as? String).map { String($0.prefix(200)) }
            }
        }
        return Foreground(app: app, title: title)
    }
}

// Runs only when the user enables domain observation, during an active session.
// Fixed script: no page data is interpolated into executable text.
final class BraveReader {
    private var busy = false
    func read(completion: @escaping (String?) -> Void) {
        guard !busy else { return }; busy = true
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "with timeout of 2 seconds\n tell application id \"com.brave.Browser\"\n if (count of windows) is 0 then return \"\"\n return URL of active tab of front window\n end tell\nend timeout"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = URL(string: raw)
            let host = p.terminationStatus == 0 && ["http", "https"].contains(url?.scheme ?? "") ? url?.host?.lowercased() : nil
            DispatchQueue.main.async { self?.busy = false; completion(host) }
        }
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if process.isRunning { process.terminate() } }
        } catch { busy = false; completion(nil) }
    }
}

final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    func register() -> Bool {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().action?(); return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return false }
        return RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(cmdKey | optionKey | controlKey), EventHotKeyID(signature: 0x464F4353, id: 1), GetApplicationEventTarget(), 0, &reference) == noErr
    }
    deinit { if let reference { UnregisterEventHotKey(reference) }; if let handler { RemoveEventHandler(handler) } }
}
