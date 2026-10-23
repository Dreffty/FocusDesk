import AppKit
import ApplicationServices
import FocusCore
import Security

// The parts that keep a block standing when FocusDesk itself is attacked: a witness kept outside its data file,
// a real check that macOS is still letting it see other windows, a guard on the System Settings panes that would
// end the block, and a login item that brings the app back if it is killed.

// MARK: - The witness in the Keychain

/// `workspace.json` is a file in your home folder: closing FocusDesk and deleting it used to end any block.
/// The witness lives in the login Keychain instead, so the running session survives losing — or editing — that file.
enum KeychainWitness {
    private static let service = "local.focusdesk.app.witness"
    private static let account = "active-session"

    static func save(_ witness: SessionWitness) {
        guard let data = try? JSONEncoder().encode(witness) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func load() -> SessionWitness? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let witness = try? JSONDecoder().decode(SessionWitness.self, from: data) else { return nil }
        return witness
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Writes, reads back and removes a throwaway witness, so `--verify-guard` can prove the Keychain really
    /// works in the signed app — and, above all, that it never puts a password prompt in the way.
    static func selfCheck() -> String {
        let existing = load()
        defer {
            clear()
            if let existing { save(existing) }
        }
        let probe = SessionWitness(
            sessionID: UUID(),
            taskTitle: "Comprobación",
            protection: .challenge,
            deadline: TrustedDeadline(seconds: 120)
        )
        save(probe)
        guard let read = load() else { return "FAIL: el Llavero no devolvió el testigo recién guardado." }
        guard read == probe, read.intact else { return "FAIL: el testigo leído no coincide con el guardado." }
        clear()
        guard load() == nil else { return "FAIL: el testigo no se borró del Llavero." }
        return "OK: guardar, leer y borrar en el Llavero, sin pedir contraseña."
    }
}

// MARK: - Is Accessibility really granted?

enum AccessibilityProbe {
    /// macOS sometimes says the permission is on while every call fails — it happens after rebuilding an app,
    /// and it leaves a block silently doing nothing. So FocusDesk asks the Dock a real question instead of
    /// trusting the switch.
    static func actuallyGranted() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            // No Dock to ask: fall back to what the system claims.
            return true
        }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        switch result {
        case .success, .noValue, .attributeUnsupported:
            return true
        case .apiDisabled, .notImplemented, .cannotComplete, .invalidUIElement:
            return false
        default:
            return false
        }
    }

    /// What to tell the user when the switch says yes and the probe says no. This is the macOS bug, and removing
    /// the app from the list and adding it again is the only thing that fixes it.
    static let brokenPermissionAdvice = """
    macOS dice que FocusDesk tiene permiso de Accesibilidad, pero no se lo está dando de verdad (le pasa a \
    cualquier app recién compilada). Abre Ajustes del Sistema › Privacidad y seguridad › Accesibilidad, quita \
    FocusDesk de la lista con el botón «−» y vuelve a añadirla. Mientras tanto el bloqueo no puede actuar.
    """
}

// MARK: - The System Settings panes that would end a block

enum SystemSettingsGuard {
    static let bundleIDs: Set<String> = ["com.apple.systempreferences", "com.apple.Settings"]

    /// Which pane of System Settings is selected right now, read from the sidebar. Everything else in System
    /// Settings — Wi-Fi, sound, displays — has to keep working during a session, so only the selected row matters.
    static func selectedPane(pid: pid_t) -> GuardedSettingsPane? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = windowValue as! AXUIElement
        guard let outline = findOutline(window, depth: 0) else { return nil }
        var rowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(outline, kAXSelectedRowsAttribute as CFString, &rowsValue) == .success,
              let rows = rowsValue as? [AXUIElement], let row = rows.first else { return nil }
        var text: [String] = []
        collectStaticText(row, into: &text, depth: 0)
        for candidate in text {
            if let pane = GuardedSettingsPane.match(selectedRow: candidate) { return pane }
        }
        return nil
    }

    private static func findOutline(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 8 else { return nil }
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           (roleValue as? String) == (kAXOutlineRole as String) {
            return element
        }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children.prefix(30) {
            if let found = findOutline(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func collectStaticText(_ element: AXUIElement, into text: inout [String], depth: Int) {
        guard depth <= 5, text.count < 8 else { return }
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let string = value as? String, !string.trimmingCharacters(in: .whitespaces).isEmpty {
                text.append(string)
            }
        }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children.prefix(12) {
            collectStaticText(child, into: &text, depth: depth + 1)
        }
    }

    /// Closes the frontmost System Settings window without quitting the app, so the rest stays available.
    @discardableResult
    static func closeFrontWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return false }
        let window = windowValue as! AXUIElement
        var buttonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonValue) == .success,
              let buttonValue, CFGetTypeID(buttonValue) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(buttonValue as! AXUIElement, kAXPressAction as CFString) == .success
    }
}

// MARK: - Coming back after being killed

/// A login item that brings FocusDesk back when it exits badly — which is what happens when it is killed from
/// Activity Monitor or with `kill`. It is deliberately modest: everything lives in your own account, and anyone
/// who knows `launchctl` can switch it off. It buys the half minute in which the impulse usually passes, and it
/// is the most a plain app can do without asking for an administrator password.
@MainActor
final class RelaunchGuard: ObservableObject {
    static let label = "local.focusdesk.guard"

    @Published private(set) var installed = false
    @Published private(set) var message = ""

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    /// Only meaningful when FocusDesk runs from a real `.app`: from a build folder there is nothing stable to point at.
    var available: Bool { bundledExecutable != nil }

    private var bundledExecutable: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return executable.path.contains(".app/Contents/MacOS/") ? executable : nil
    }

    func refresh() {
        installed = FileManager.default.fileExists(atPath: plistURL.path)
        if !available {
            message = "Disponible cuando abres FocusDesk desde la app instalada, no desde la carpeta de compilación."
        } else if installed {
            message = "Activo: si matan FocusDesk durante una sesión protegida, macOS vuelve a abrirlo."
        } else {
            message = "Apagado. Con él, cerrar FocusDesk a la fuerza deja de ser una salida fácil."
        }
    }

    func install() {
        guard let executable = bundledExecutable else { refresh(); return }
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable.path],
            // Only after an unclean exit: quitting FocusDesk properly from its menu is still allowed.
            "KeepAlive": ["SuccessfulExit": false],
            "RunAtLoad": false,
            "ProcessType": "Interactive",
            // Enough to outlast a burst of kills without turning into a loop.
            "ThrottleInterval": 5
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            let result = Self.launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            // 37 is "already bootstrapped", which is the state we wanted anyway.
            if result.status != 0 && result.status != 37 {
                message = "No se pudo activar el vigilante: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                installed = FileManager.default.fileExists(atPath: plistURL.path)
                return
            }
            refresh()
        } catch {
            message = "No se pudo activar el vigilante: \(error.localizedDescription)"
        }
    }

    func remove() {
        _ = Self.launchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        try? FileManager.default.removeItem(at: plistURL)
        refresh()
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
