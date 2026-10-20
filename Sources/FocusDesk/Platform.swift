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
final class ReminderService: ObservableObject {
    @Published var message = "Comprobando notificaciones…"
    let center = UNUserNotificationCenter.current()
    private var pending: Task<Void, Never>?
    init() { Task { await refresh() } }
    func refresh() async {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional: message = "Notificaciones autorizadas"
        case .denied: message = "Notificaciones denegadas en Ajustes del Sistema"
        default: message = "Activa las notificaciones para recibir avisos"
        }
    }
    func request() async {
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]); await refresh() }
        catch { message = error.localizedDescription }
    }
    func schedule(_ tasks: [FocusTask], sessionTaskID: UUID?) {
        let previous = pending
        pending?.cancel()
        pending = Task {
            // Wait for a previous add to finish before removing its requests.
            await previous?.value
            guard !Task.isCancelled else { return }
            center.removeAllPendingNotificationRequests()
            let status = await center.notificationSettings().authorizationStatus
            guard !Task.isCancelled, [.authorized, .provisional].contains(status) else { return }
            for reminder in ReminderPlan.make(tasks: tasks, sessionTaskID: sessionTaskID, now: Date()) {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent(); content.title = reminder.title; content.body = reminder.body; content.sound = .default
                let delay = max(1, reminder.at.timeIntervalSinceNow)
                do { try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))) }
                catch { message = "No se pudo programar un aviso: \(error.localizedDescription)" }
            }
        }
    }
    func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        Task {
            do { try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
            catch { message = "No se pudo mostrar el aviso: \(error.localizedDescription)" }
        }
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
