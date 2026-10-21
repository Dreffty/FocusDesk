import AppKit
import ApplicationServices
import Carbon.HIToolbox
import EventKit
import FocusCore
import UserNotifications

struct FileSnapshot: Sendable {
    var files: [String: FileStamp]
    var writingFiles: [String]
    var valid: Bool
    var message: String?
}

actor EvidenceScanner {
    private static let ignoredExtensions: Set<String> = [
        "tmp", "temp", "part", "crdownload", "download", "partial", "lock"
    ]

    func scan(_ path: String?) -> FileSnapshot {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FileSnapshot(files: [:], writingFiles: [], valid: false, message: "Sin carpeta de resultados; puedes confirmar o adjuntar un archivo manualmente.")
        }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            return FileSnapshot(files: [:], writingFiles: [], valid: false, message: "No se puede leer la carpeta de resultados configurada.")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in failed = true; return true }
        ) else {
            return FileSnapshot(files: [:], writingFiles: [], valid: false, message: "No se pudo inspeccionar la carpeta.")
        }
        let scanInstant = Date()
        var files: [String: FileStamp] = [:]
        var writingFiles: [String] = []
        var visited = 0
        for case let item as URL in enumerator {
            visited += 1
            if visited > 5000 { failed = true; break }
            let name = item.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("~$") || name.hasPrefix(".sb-") { continue }
            guard !Self.ignoredExtensions.contains(item.pathExtension.lowercased()) else { continue }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { failed = true; continue }
            guard values.isSymbolicLink != true, values.isRegularFile == true, let date = values.contentModificationDate else { continue }
            let size = Int64(values.fileSize ?? 0)
            files[item.path] = FileStamp(modified: date, bytes: size)
            if abs(scanInstant.timeIntervalSince(date)) < 2.0 {
                writingFiles.append(item.path)
            }
        }
        var warnings: [String] = []
        if failed {
            warnings.append("Lectura parcial (límite de 5.000 entradas o archivos inaccesibles).")
        }
        if !writingFiles.isEmpty {
            warnings.append("Hay archivos modificados hace menos de 2 s que podrían seguir escribiéndose.")
        }
        return FileSnapshot(
            files: files,
            writingFiles: writingFiles,
            valid: !failed,
            message: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
    }
}

@MainActor
final class ReminderService: ObservableObject {
    static let taskCategory = "TASK_REMINDER"
    static let overtimeCategory = "SESSION_OVERTIME"
    static let pausedCategory = "SESSION_PAUSED"
    static let actionStart = "START_TASK"
    static let actionSnooze = "SNOOZE_TASK"
    static let actionFinish = "FINISH_SESSION"
    static let actionExtend = "EXTEND_SESSION"
    static let actionPause = "PAUSE_SESSION"
    static let actionResume = "RESUME_SESSION"

    @Published var message = "Comprobando notificaciones…"
    @Published var status: UNAuthorizationStatus = .notDetermined
    @Published private(set) var scheduledIDs: [String] = []
    let center = UNUserNotificationCenter.current()
    private var pending: Task<Void, Never>?

    init() {
        registerCategories()
        Task { await refresh() }
    }

    func registerCategories() {
        let startAction = UNNotificationAction(identifier: Self.actionStart, title: "Empezar ahora", options: [.foreground])
        let snoozeAction = UNNotificationAction(identifier: Self.actionSnooze, title: "Posponer 10 min", options: [])
        let taskCat = UNNotificationCategory(
            identifier: Self.taskCategory,
            actions: [startAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )

        let finishAction = UNNotificationAction(identifier: Self.actionFinish, title: "He terminado", options: [.foreground])
        let extendAction = UNNotificationAction(identifier: Self.actionExtend, title: "+10 min", options: [])
        let pauseAction = UNNotificationAction(identifier: Self.actionPause, title: "Pausar", options: [])
        let overtimeCat = UNNotificationCategory(
            identifier: Self.overtimeCategory,
            actions: [finishAction, extendAction, pauseAction],
            intentIdentifiers: [],
            options: []
        )

        // Offered when the Mac woke up or was unlocked with a session the system had paused.
        let resumeAction = UNNotificationAction(identifier: Self.actionResume, title: "Reanudar", options: [])
        let pausedCat = UNNotificationCategory(
            identifier: Self.pausedCategory,
            actions: [resumeAction, finishAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([taskCat, overtimeCat, pausedCat])
    }

    func refresh() async {
        let current = await center.notificationSettings().authorizationStatus
        status = current
        switch current {
        case .authorized, .provisional:
            message = "Notificaciones autorizadas (con acciones Empezar y Posponer)"
        case .denied:
            message = "Notificaciones denegadas en Ajustes del Sistema. Ábrelos para permitir avisos."
        default:
            message = "Activa las notificaciones para recibir avisos previos y de inicio"
        }
    }

    func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    func request() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refresh()
            if !granted && status == .denied {
                message = "Permiso denegado. Pulsa «Abrir Ajustes de Notificaciones» para activarlo en macOS."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func schedule(_ tasks: [FocusTask], sessionTaskID: UUID?) {
        let previous = pending
        pending?.cancel()
        pending = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            center.removeAllPendingNotificationRequests()
            let currentStatus = await center.notificationSettings().authorizationStatus
            status = currentStatus
            guard !Task.isCancelled, [.authorized, .provisional].contains(currentStatus) else {
                scheduledIDs = []
                return
            }
            let planned = ReminderPlan.make(tasks: tasks, sessionTaskID: sessionTaskID, now: Date())
            var addedIDs: [String] = []
            for reminder in planned {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.body = reminder.body
                content.sound = .default
                content.categoryIdentifier = Self.taskCategory
                content.userInfo = [
                    "taskID": reminder.taskID.uuidString,
                    "kind": reminder.kind.rawValue
                ]
                let delay = max(1, reminder.at.timeIntervalSinceNow)
                do {
                    try await center.add(
                        UNNotificationRequest(
                            identifier: reminder.id,
                            content: content,
                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
                        )
                    )
                    addedIDs.append(reminder.id)
                } catch {
                    message = "No se pudo programar un aviso: \(error.localizedDescription)"
                }
            }
            if !Task.isCancelled {
                scheduledIDs = addedIDs
            }
        }
    }

    /// Retires reminders already shown for a task that started, moved or was deleted, so a stale «Es el momento»
    /// does not sit in Notification Center offering to start it again.
    func removeDelivered(forTaskID id: UUID) {
        removeDelivered(identifiers: [id.uuidString + "before", id.uuidString + "start"])
    }

    func removeDelivered(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// `identifier` lets a notification replace the previous one with the same id instead of piling up.
    func notify(_ title: String, body: String, category: String? = nil, userInfo: [AnyHashable: Any] = [:], identifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        if !userInfo.isEmpty { content.userInfo = userInfo }
        Task {
            do {
                try await center.add(UNNotificationRequest(identifier: identifier ?? UUID().uuidString, content: content, trigger: nil))
            } catch {
                message = "No se pudo mostrar el aviso: \(error.localizedDescription)"
            }
        }
    }
}

struct Foreground {
    let app: NSRunningApplication
    let title: String?
    let titleStatus: String?
}

enum MacActivity {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
    static func foreground(readTitle: Bool, excludedAppIDs: Set<String> = []) -> Foreground? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var title: String?
        var titleStatus: String?
        if readTitle {
            if let id = app.bundleIdentifier, excludedAppIDs.contains(id) {
                titleStatus = "excluida por privacidad"
            } else if !accessibility {
                titleStatus = "sin permiso de Accesibilidad"
            } else {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.15)
                var window: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
                   let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                    var value: CFTypeRef?
                    AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value)
                    let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !trimmed.isEmpty {
                        title = String(trimmed.prefix(200))
                    } else {
                        titleStatus = "ventana sin título"
                    }
                } else {
                    titleStatus = "sin ventana activa"
                }
            }
        }
        return Foreground(app: app, title: title, titleStatus: titleStatus)
    }
}

enum BraveReadResult: Sendable, Equatable {
    case host(String)
    case noWindowOrTab
    case notRunning
    case permissionDenied
    case timeout
    case unknown
}

// Runs only when the user enables domain observation, during an active session.
// Fixed script: no page data is interpolated into executable text.
final class BraveReader {
    private var busy = false
    func read(completion: @escaping (BraveReadResult) -> Void) {
        guard !busy else { return }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.brave.Browser" && !$0.isTerminated }) else {
            completion(.notRunning)
            return
        }
        busy = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "with timeout of 2 seconds\n tell application id \"com.brave.Browser\"\n if (count of windows) is 0 then return \"__NO_WINDOW__\"\n return URL of active tab of front window\n end tell\nend timeout"
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        var didTimeout = false
        process.terminationHandler = { [weak self] p in
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errText = String(data: errData, encoding: .utf8)?.lowercased() ?? ""
            let result: BraveReadResult
            if didTimeout || errText.contains("timed out") || errText.contains("-1712") {
                result = .timeout
            } else if errText.contains("-1743") || errText.contains("not authorized") || errText.contains("no está autorizado") {
                result = .permissionDenied
            } else if raw == "__NO_WINDOW__" || raw.isEmpty {
                result = .noWindowOrTab
            } else if p.terminationStatus == 0, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() {
                result = .host(host)
            } else {
                result = .unknown
            }
            DispatchQueue.main.async {
                self?.busy = false
                completion(result)
            }
        }
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if process.isRunning {
                    didTimeout = true
                    process.terminate()
                }
            }
        } catch {
            busy = false
            completion(.unknown)
        }
    }
}

final class GlobalHotKey {
    /// The configurable shortcut that opens the planner or the compact panel.
    static let openID: UInt32 = 1
    /// Session shortcuts. Menu key equivalents only reach FocusDesk while it is the frontmost app, and during a session
    /// you are in CapCut or Brave — so pause and finish are registered system-wide while a session exists.
    static let pauseResumeID: UInt32 = 2
    static let finishID: UInt32 = 3
    private static let signature: OSType = 0x464F4353 // "FOCS"

    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// Called on the main thread with the id of the shortcut that was pressed.
    var action: ((UInt32) -> Void)?

    /// Registers (or replaces) the open shortcut.
    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_F), modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey), enabled: Bool = true) -> Bool {
        register(id: Self.openID, keyCode: keyCode, modifiers: modifiers, enabled: enabled)
    }

    /// Registers (or replaces) the shortcut with `id`. Returns false if another app already owns the combination.
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, enabled: Bool = true) -> Bool {
        unregister(id: id)
        guard enabled else { return true }
        guard installHandlerIfNeeded() else { return false }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        references[id] = reference
        return true
    }

    func isRegistered(_ id: UInt32) -> Bool { references[id] != nil }

    func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) {
            UnregisterEventHotKey(reference)
        }
    }

    /// Removes the open shortcut (the session ones are managed separately).
    func unregister() { unregister(id: Self.openID) }

    private func installHandlerIfNeeded() -> Bool {
        guard handler == nil else { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            // Which shortcut fired: every registration shares this one handler.
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard read == noErr, hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            owner.action?(hotKeyID.id)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        return status == noErr
    }

    deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
