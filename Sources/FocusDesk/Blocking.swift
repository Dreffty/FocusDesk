import AppKit
import ApplicationServices
import FocusCore

// Seeing the distraction is most of the work. The app in front is only one of the places a blocked site can be:
// it can sit in a window on the other monitor, inside a "web app" with its own icon, or inside Discord or Notion.
// This file finds it; AppModel decides what to do about it.

// MARK: - Windows that are on screen without the keyboard focus

enum ScreenWindows {
    /// Process ids with a real window drawn on any monitor right now, focused or not. Needs no permission:
    /// window titles would, the owners do not.
    static func visibleOwnerPIDs() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var pids: Set<pid_t> = []
        for window in list {
            // Layer 0 is a normal document window: this skips menu bar extras, the Dock and overlays.
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = bounds?["Width"] as? Double ?? 0
            let height = bounds?["Height"] as? Double ?? 0
            // Tiny helper windows are not a distraction anyone can watch.
            guard width >= 120, height >= 90 else { continue }
            pids.insert(pid)
        }
        return pids
    }

    /// Running applications with a visible window that are not in `allowed` and may be acted on.
    static func visibleUnallowedApps(allowedBundleIDs: Set<String>, exempt: Set<String>) -> [NSRunningApplication] {
        let pids = visibleOwnerPIDs()
        guard !pids.isEmpty else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, app.processIdentifier != ownPID, pids.contains(app.processIdentifier),
                  let id = app.bundleIdentifier, !exempt.contains(id), !allowedBundleIDs.contains(id) else { return false }
            return app.activationPolicy == .regular
        }
    }
}

// MARK: - What a window is really showing

/// What FocusDesk managed to find out about the app in front (or a visible one behind it).
struct AppSurface {
    let app: NSRunningApplication
    let bundleID: String
    /// Host of the site this app is on, when it could be read: a browser tab, a Chromium web app, or a page
    /// embedded in an Electron app.
    var host: String?
    /// Where the host came from, for the history and for honest messages.
    var source: Source = .none

    enum Source: String {
        case none
        case browserTab
        case chromiumWebApp
        case embeddedPage
    }
}

enum AppInspector {
    /// A Chromium "web app" (YouTube installed from Chrome, say) is a real `.app` with its own bundle id, and its
    /// `Info.plist` keeps the site it wraps. Without this, installing a blocked site as an app walks past the rules.
    static func chromiumWebAppHost(for app: NSRunningApplication) -> String? {
        guard let bundleURL = app.bundleURL else { return nil }
        guard let info = Bundle(url: bundleURL)?.infoDictionary else { return nil }
        guard let raw = info["CrAppModeShortcutURL"] as? String ?? info["CrAppModeShortcutURLString"] as? String else { return nil }
        return URL(string: raw)?.host?.lowercased()
    }

    /// Hosts of the web pages open inside an Electron app (Discord, Slack, Notion, Obsidian…). Chromium keeps its
    /// accessibility tree switched off until something asks for it, so this asks, then reads the web areas.
    /// Called off the main thread's critical path: it walks a tree and can take a few milliseconds.
    static func embeddedHosts(for app: NSRunningApplication, limit: Int = 6) -> [String] {
        guard isElectron(app) else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var hosts: [String] = []
        collectWebAreaHosts(element, into: &hosts, depth: 0, maxDepth: 6, limit: limit)
        return hosts
    }

    static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        let framework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    private static func collectWebAreaHosts(_ element: AXUIElement, into hosts: inout [String], depth: Int, maxDepth: Int, limit: Int) {
        guard depth <= maxDepth, hosts.count < limit else { return }
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           (roleValue as? String) == "AXWebArea" {
            var urlValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlValue) == .success {
                let raw = (urlValue as? URL) ?? (urlValue as? String).flatMap(URL.init(string:))
                if let host = raw?.host?.lowercased(), !hosts.contains(host) {
                    hosts.append(host)
                }
            }
        }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children.prefix(40) {
            collectWebAreaHosts(child, into: &hosts, depth: depth + 1, maxDepth: maxDepth, limit: limit)
            if hosts.count >= limit { return }
        }
    }
}

// MARK: - Reading and steering browser tabs

enum WebReadResult: Sendable, Equatable {
    case page(host: String, path: String = "")
    case noWindowOrTab
    case notRunning
    case permissionDenied
    case timeout
    /// An internal page (`chrome://`, a new tab) or one whose address could not be parsed.
    case unknown
}

/// Runs AppleScript against the browsers FocusDesk knows, one call at a time per browser. Every script is fixed
/// text; nothing read from a page is ever put back into something that runs.
final class WebInspector {
    private var busy: Set<String> = []

    func read(bundleID: String, completion: @escaping (WebReadResult) -> Void) {
        guard let kind = WebRules.browserKind(for: bundleID) else { completion(.unknown); return }
        guard isRunning(bundleID) else { completion(.notRunning); return }
        guard !busy.contains(bundleID) else { return }
        if kind == .accessibility {
            completion(Self.readAccessibilityBrowser(bundleID: bundleID))
            return
        }
        busy.insert(bundleID)
        let script: String
        switch kind {
        case .safari:
            script = """
            with timeout of 2 seconds
             tell application id "\(bundleID)"
              if (count of windows) is 0 then return "__NO_WINDOW__"
              return URL of front document
             end tell
            end timeout
            """
        case .chromium:
            script = """
            with timeout of 2 seconds
             tell application id "\(bundleID)"
              if (count of windows) is 0 then return "__NO_WINDOW__"
              return URL of active tab of front window
             end tell
            end timeout
            """
        case .accessibility:
            busy.remove(bundleID)
            completion(.unknown)
            return
        }
        run(script, timeout: 3) { [weak self] output, errorText, status, timedOut in
            self?.busy.remove(bundleID)
            completion(Self.interpret(output: output, errorText: errorText, status: status, timedOut: timedOut))
        }
    }

    /// Sends only the offending tab to `url`, leaving every other tab and window where they were.
    func redirectActiveTab(bundleID: String, to url: URL, completion: @escaping (Bool) -> Void) {
        guard let kind = WebRules.browserKind(for: bundleID), isRunning(bundleID) else { completion(false); return }
        if kind == .accessibility {
            // Firefox, Zen, Waterfox and DuckDuckGo do not expose active-tab URL mutation via AppleScript:
            // close the offending tab immediately, and if a custom web redirect URL was configured, open it.
            let closed = Self.closeAccessibilityTab(bundleID: bundleID)
            if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            }
            completion(closed)
            return
        }
        let target = url.absoluteString
        // The address is one FocusDesk built (its own blocked page); nothing from the web reaches this text.
        let script: String
        switch kind {
        case .safari:
            script = """
            with timeout of 3 seconds
             tell application id "\(bundleID)"
              if (count of windows) is 0 then return "__NO_WINDOW__"
              set URL of front document to "\(target)"
             end tell
            end timeout
            """
        case .chromium:
            script = """
            with timeout of 3 seconds
             tell application id "\(bundleID)"
              if (count of windows) is 0 then return "__NO_WINDOW__"
              set URL of active tab of front window to "\(target)"
             end tell
            end timeout
            """
        case .accessibility:
            completion(false)
            return
        }
        run(script, timeout: 4) { _, _, status, timedOut in
            completion(status == 0 && !timedOut)
        }
    }

    /// Closes only the active tab. With a single tab open the browser closes its window, which is the same thing
    /// the user would get pressing ⌘W.
    func closeActiveTab(bundleID: String, completion: @escaping (Bool) -> Void) {
        guard let kind = WebRules.browserKind(for: bundleID), isRunning(bundleID) else { completion(false); return }
        if kind == .accessibility {
            completion(Self.closeAccessibilityTab(bundleID: bundleID))
            return
        }
        let script: String
        switch kind {
        case .safari:
            script = """
            with timeout of 3 seconds
             tell application id "\(bundleID)"
              if (count of windows) is 0 then return "__NO_WINDOW__"
              close current tab of front window
             end tell
            end timeout
            """
        case .chromium:
            script = """
            with timeout of 3 seconds
             tell application id "\(bundleID)"
              if (count of windows) is 0 then return "__NO_WINDOW__"
              close active tab of front window
             end tell
            end timeout
            """
        case .accessibility:
            completion(false)
            return
        }
        run(script, timeout: 4) { _, _, status, timedOut in
            completion(status == 0 && !timedOut)
        }
    }

    /// Reads the active page URL from browsers that do not expose an AppleScript dictionary for tabs
    /// (Firefox, Zen Browser, Waterfox, DuckDuckGo Browser) using the macOS Accessibility tree (`AXUIElement`).
    private static func readAccessibilityBrowser(bundleID: String) -> WebReadResult {
        guard AXIsProcessTrusted() else { return .permissionDenied }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID && !$0.isTerminated }) else {
            return .notRunning
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) != .success || windowRef == nil {
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement], let first = windows.first {
                windowRef = first
            }
        }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return .noWindowOrTab
        }
        let window = windowRef as! AXUIElement
        var webAreaURL: String?
        var addressBarCandidate: String?
        findAccessibilityURL(in: window, depth: 0, maxDepth: 9, webAreaURL: &webAreaURL, addressBarCandidate: &addressBarCandidate)

        if let raw = webAreaURL ?? addressBarCandidate, let parsed = parseBrowserAddress(raw) {
            return .page(host: parsed.host, path: parsed.path)
        }
        return .unknown
    }

    private static func findAccessibilityURL(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        webAreaURL: inout String?,
        addressBarCandidate: inout String?
    ) {
        guard depth <= maxDepth, webAreaURL == nil else { return }
        var roleValue: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success)
            ? (roleValue as? String ?? "")
            : ""

        if role == "AXWebArea" {
            var urlValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlValue) == .success {
                if let url = urlValue as? URL {
                    webAreaURL = url.absoluteString
                    return
                } else if let str = urlValue as? String, !str.isEmpty {
                    webAreaURL = str
                    return
                }
            }
        } else if role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String) {
            // Skip address bars while the user is actively typing in them.
            var focusedValue: CFTypeRef?
            let isFocused = (AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedValue) == .success)
                && ((focusedValue as? Bool) == true)
            if !isFocused {
                var idValue: CFTypeRef?
                let identifier = (AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &idValue) == .success)
                    ? (idValue as? String ?? "")
                    : ""
                var valRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef) == .success,
                   let value = valRef as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if identifier.contains("addressBar") || identifier.contains("urlbar") || looksLikeAddressBarValue(trimmed) {
                        if addressBarCandidate == nil {
                            addressBarCandidate = trimmed
                        }
                    }
                }
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children.prefix(35) {
            findAccessibilityURL(in: child, depth: depth + 1, maxDepth: maxDepth, webAreaURL: &webAreaURL, addressBarCandidate: &addressBarCandidate)
            if webAreaURL != nil { return }
        }
    }

    private static func looksLikeAddressBarValue(_ raw: String) -> Bool {
        guard !raw.isEmpty, !raw.contains(" ") else { return false }
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return true }
        guard let slash = raw.firstIndex(of: "/") ?? Optional(raw.endIndex) else { return false }
        let hostPart = String(raw[..<slash])
        let parts = hostPart.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        return true
    }

    private static func parseBrowserAddress(_ raw: String) -> (host: String, path: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else {
            withScheme = "https://" + trimmed
        }
        guard let url = URL(string: withScheme),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              host.contains(".") else { return nil }
        return (host, url.path)
    }

    private static func closeAccessibilityTab(bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID && !$0.isTerminated }) else {
            return false
        }
        // Send ⌘W (virtual key 13) directly to the browser process so only the active tab closes.
        if let src = CGEventSource(stateID: .hidSystemState),
           let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: false) {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.postToPid(app.processIdentifier)
            keyUp.postToPid(app.processIdentifier)
            return true
        }
        return WindowCloser.closeFrontWindow(pid: app.processIdentifier)
    }

    private func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID && !$0.isTerminated }
    }

    static func interpret(output: String, errorText: String, status: Int32, timedOut: Bool) -> WebReadResult {
        let lowered = errorText.lowercased()
        if timedOut || lowered.contains("timed out") || lowered.contains("-1712") { return .timeout }
        if lowered.contains("-1743") || lowered.contains("not authorized") || lowered.contains("no está autorizado") {
            return .permissionDenied
        }
        if output == "__NO_WINDOW__" || output.isEmpty { return .noWindowOrTab }
        guard status == 0, let url = URL(string: output),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return .unknown }
        return .page(host: host, path: url.path)
    }

    private func run(_ source: String, timeout: TimeInterval, completion: @escaping (String, String, Int32, Bool) -> Void) {
        OsaScript.run(source, timeout: timeout, completion: completion)
    }
}

/// One `osascript` process, killed if it hangs: a frozen browser or Finder must never freeze FocusDesk.
/// `arguments` reach the script as `argv`, never as part of its text, so nothing read from the disk can run.
enum OsaScript {
    static func run(_ source: String, arguments: [String] = [], timeout: TimeInterval,
                    completion: @escaping (String, String, Int32, Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        var timedOut = false
        process.terminationHandler = { finished in
            let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                completion(out, err, finished.terminationStatus, timedOut)
            }
        }
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
        } catch {
            DispatchQueue.main.async { completion("", error.localizedDescription, -1, false) }
        }
    }
}

// MARK: - Folders the task closes

/// Closing a window the polite way: its close button, through Accessibility. Nothing is quit, nothing is lost that
/// the app would not have asked about.
enum WindowCloser {
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

/// What a window has open from the disk — FocusMe's `getFinderLocation`, plus the document of any other app.
enum FolderInspector {
    /// The file the front window of `pid` has open (`AXDocument`): QuickTime, Preview, VLC, IINA and most document
    /// apps set it. Nothing else of the window is read.
    static func frontDocumentPath(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        var documentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXDocumentAttribute as CFString, &documentValue) == .success,
              let raw = documentValue as? String, let url = URL(string: raw), url.isFileURL else { return nil }
        return url.path
    }

    enum FinderResult: Equatable {
        /// The blocked folders some Finder window was showing; those windows now show the folder above.
        case movedOut([String])
        case permissionDenied
        case failed
    }

    /// Sends every Finder window (each tab that is in front) showing a blocked folder to the folder above it, the
    /// way a blocked tab goes to FocusDesk's page instead of the whole browser closing. The Finder does not say
    /// which folder a window shows over Accessibility, so this is AppleScript, and macOS asks once for permission.
    static func moveFinderWindowsOut(of folders: [String], completion: @escaping (FinderResult) -> Void) {
        let pairs = folders.flatMap { [$0, ($0 as NSString).deletingLastPathComponent] }
        guard !pairs.isEmpty else { completion(.movedOut([])); return }
        let script = """
        on run argv
         set parents to {}
         repeat with i from 2 to (count of argv) by 2
          set end of parents to (POSIX file (item i of argv) as alias)
         end repeat
         with timeout of 3 seconds
          tell application id "com.apple.finder"
           set hits to ""
           repeat with w in (every Finder window)
            try
             set p to POSIX path of (target of w as alias)
             repeat with k from 1 to (count of parents)
              set b to item (k * 2 - 1) of argv
              if p is (b & "/") or p starts with (b & "/") then
               set target of w to (item k of parents)
               set hits to hits & b & linefeed
               exit repeat
              end if
             end repeat
            end try
           end repeat
           return hits
          end tell
         end timeout
        end run
        """
        OsaScript.run(script, arguments: pairs, timeout: 4) { output, errorText, status, timedOut in
            let lowered = errorText.lowercased()
            if lowered.contains("-1743") || lowered.contains("not authorized") || lowered.contains("no está autorizado") {
                completion(.permissionDenied)
            } else if timedOut || status != 0 {
                completion(.failed)
            } else {
                completion(.movedOut(output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }))
            }
        }
    }
}

// MARK: - The page a blocked tab lands on

/// FocusDesk writes its own page and sends the tab there. It says what blocked it, how long is left and what the
/// task was for — the thing the user wrote while they were calm, read back at the moment it is needed.
enum BlockPage {
    static func url(in directory: URL) -> URL { directory.appendingPathComponent("bloqueada.html") }

    /// Writes the page and returns its address. Rewritten on each block so the countdown is right.
    @discardableResult
    static func write(
        taskTitle: String,
        host: String,
        remaining: TimeInterval,
        endsAt: Date,
        allowedDomains: [String],
        motivationalMessage: String = "",
        checklistSteps: [String] = [],
        in directory: URL
    ) -> URL? {
        let target = url(in: directory)
        let safeTitle = escape(taskTitle)
        let safeHost = escape(host)
        let clock = FocusRules.clock(max(0, remaining))
        let ends = endsAt.formatted(date: .omitted, time: .shortened)
        let trimmedMotivation = motivationalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let motivationBlock = trimmedMotivation.isEmpty
            ? ""
            : "<blockquote class=\"motivation\">«\(escape(trimmedMotivation))»</blockquote>"
        let cleanSteps = checklistSteps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let stepsBlock: String
        if cleanSteps.isEmpty {
            stepsBlock = ""
        } else {
            let items = cleanSteps.prefix(5).map { "<li>\(escape($0))</li>" }.joined()
            stepsBlock = "<div class=\"steps\"><div class=\"steps-title\">Siguientes pasos pendientes</div><ul>\(items)</ul></div>"
        }
        let allowed = allowedDomains.isEmpty
            ? ""
            : "<p class=\"allowed\">Para esta tarea sí: \(escape(allowedDomains.joined(separator: " · ")))</p>"
        let html = """
        <!doctype html>
        <html lang="es">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Ahora no · FocusDesk</title>
        <style>
          :root { color-scheme: light dark; --bg:#f6f7f9; --card:#fff; --ink:#1c1d22; --muted:#6b6f7a; --mint:#1f9c72; --line:#e3e5ea; }
          @media (prefers-color-scheme: dark) {
            :root { --bg:#131417; --card:#1c1e22; --ink:#f2f3f5; --muted:#9aa0ab; --mint:#4fd0a0; --line:#2b2e34; }
          }
          * { box-sizing: border-box; }
          body { margin:0; min-height:100vh; display:grid; place-items:center; padding:24px;
                 background:var(--bg); color:var(--ink);
                 font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
          .card { width:min(560px,100%); background:var(--card); border:1px solid var(--line);
                  border-radius:18px; padding:40px 36px; text-align:center;
                  box-shadow:0 16px 48px rgba(0,0,0,.08); }
          .dot { width:44px; height:44px; margin:0 auto 20px; border-radius:50%;
                 background:color-mix(in srgb, var(--mint) 16%, transparent);
                 display:grid; place-items:center; font-size:21px; }
          h1 { font-size:25px; margin:0 0 10px; letter-spacing:-.02em; }
          p { margin:0 0 8px; color:var(--muted); font-size:14px; line-height:1.55; }
          .host { font-family: ui-monospace, SFMono-Regular, monospace; color:var(--ink); }
          .clock { font-family: ui-monospace, SFMono-Regular, monospace; font-size:42px;
                   color:var(--mint); margin:26px 0 4px; font-variant-numeric: tabular-nums; }
          .label { font-size:10px; letter-spacing:.14em; text-transform:uppercase; color:var(--muted); }
          .motivation { margin:18px 0 0; padding:12px 16px; border-radius:12px;
                        background:color-mix(in srgb, var(--mint) 10%, transparent);
                        color:var(--ink); font-style:italic; font-size:14px; line-height:1.5; }
          .steps { margin-top:20px; padding:14px 18px; border-radius:12px; border:1px solid var(--line);
                   text-align:left; font-size:13px; }
          .steps-title { font-size:10px; font-weight:700; letter-spacing:.12em; text-transform:uppercase;
                         color:var(--muted); margin-bottom:8px; }
          .steps ul { margin:0; padding-left:18px; color:var(--ink); }
          .steps li { margin:4px 0; line-height:1.45; }
          .allowed { margin-top:22px; padding-top:18px; border-top:1px solid var(--line); font-size:12px; }
        </style>
        </head>
        <body>
          <main class="card">
            <div class="dot">◎</div>
            <h1>Ahora no.</h1>
            <p>Estás con <strong>\(safeTitle)</strong>, y <span class="host">\(safeHost)</span> no entra en esa tarea.</p>
            \(motivationBlock)
            <div class="clock" id="clock">\(clock)</div>
            <div class="label">para terminar · \(ends)</div>
            \(stepsBlock)
            \(allowed)
          </main>
          <script>
            let left = \(Int(max(0, remaining)));
            const node = document.getElementById("clock");
            setInterval(() => {
              if (left <= 0) { node.textContent = "00:00"; return; }
              left -= 1;
              const h = Math.floor(left / 3600), m = Math.floor(left / 60) % 60, s = left % 60;
              const pad = (n) => String(n).padStart(2, "0");
              node.textContent = h > 0 ? h + ":" + pad(m) + ":" + pad(s) : pad(m) + ":" + pad(s);
            }, 1000);
          </script>
        </body>
        </html>
        """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try html.write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }

    /// The page shows a task title and a host the user typed or visited: escaped, never injected as markup.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// MARK: - Discreet floating countdown pill (FocusMe's showTimer HUD)

/// A tiny non-activating floating pill in the top-right corner of the screen that shows the live countdown
/// when a user is consuming a daily budget, a timed launch visit, a work-goal reward, a micro-pause, or a break.
/// It ignores mouse events (`ignoresMouseEvents = true`) so it never steals focus or blocks clicks.
@MainActor
final class FloatingTimerPillController {
    private var panel: NSPanel?
    private var dotView: NSView?
    private var labelField: NSTextField?

    enum Urgency {
        case normal
        case warning
        case critical
        case pauseOrBreak
    }

    func update(title: String, remaining: TimeInterval, urgency: Urgency) {
        let panel = ensurePanel()
        let clock = FocusRules.clock(max(0, remaining))
        let cleanTitle = title.count > 26 ? String(title.prefix(25)) + "…" : title
        labelField?.stringValue = "\(clock)  ·  \(cleanTitle)"
        let dotColor: NSColor
        switch urgency {
        case .normal:
            dotColor = NSColor(calibratedRed: 0.14, green: 0.56, blue: 0.42, alpha: 1.0)
        case .warning:
            dotColor = NSColor(calibratedRed: 0.88, green: 0.54, blue: 0.14, alpha: 1.0)
        case .critical:
            dotColor = NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.22, alpha: 1.0)
        case .pauseOrBreak:
            dotColor = NSColor(calibratedRed: 0.28, green: 0.52, blue: 0.86, alpha: 1.0)
        }
        dotView?.layer?.backgroundColor = dotColor.cgColor

        labelField?.sizeToFit()
        let textSize = labelField?.frame.size ?? NSSize(width: 150, height: 18)
        let width = max(148, min(320, ceil(textSize.width) + 42))
        let height: CGFloat = 30
        labelField?.frame = NSRect(x: 28, y: (height - textSize.height) / 2, width: width - 38, height: textSize.height)
        dotView?.frame = NSRect(x: 12, y: (height - 8) / 2, width: 8, height: 8)

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let frame = NSRect(
                x: visible.maxX - width - 16,
                y: visible.maxY - height - 12,
                width: width,
                height: height
            )
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        container.autoresizingMask = [.width, .height]
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 15
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        let dot = NSView(frame: NSRect(x: 12, y: 11, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        container.addSubview(dot)

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)

        p.contentView = container
        self.panel = p
        self.dotView = dot
        self.labelField = label
        return p
    }
}
