import AppKit
import SwiftUI
import UserNotifications

@main
struct FocusDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        MenuBarExtra { MenuPanel(model: delegate.model) } label: {
            MenuLabel(model: delegate.model)
        }.menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    @ObservedObject var model: AppModel
    var body: some View { Label(model.menuTitle, systemImage: "scope").monospacedDigit() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model: AppModel = {
        let preview = CommandLine.arguments.contains("--preview")
        let directory = preview ? FileManager.default.temporaryDirectory.appendingPathComponent("FocusDesk-preview-" + UUID().uuidString) : nil
        return AppModel(directory: directory, preview: preview)
    }()
    private var window: NSWindow?
    private let hotkey = GlobalHotKey()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        model.showWindow = { [weak self] in self?.show() }
        hotkey.action = { [weak self] in self?.show() }
        if !hotkey.register() { model.notice = "El atajo ⌃⌥⌘F está ocupado. Abre FocusDesk desde la barra." }
        show()
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "FocusDesk"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 960, height: 680)
            window.contentView = NSHostingView(rootView: MainView(model: model).environment(\.locale, Locale(identifier: "es_ES")))
            window.center(); self.window = window
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.show(); completionHandler() }
    }
}
