import AppKit
import Combine
import FocusCore
import SwiftUI
import UserNotifications

@main
struct FocusDeskApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let isIsolatedCheck = CommandLine.arguments.contains("--preview")
        if !isIsolatedCheck,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: "local.focusdesk.app")
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.focusdesk.showWindow"), object: nil)
            other.activate(options: [])
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model: AppModel = {
        let preview = CommandLine.arguments.contains("--preview")
        let args = CommandLine.arguments
        let supplied = args.firstIndex(of: "--preview-directory").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let directory = preview ? supplied ?? FileManager.default.temporaryDirectory.appendingPathComponent("FocusDesk-preview-" + UUID().uuidString) : nil
        return AppModel(directory: directory, preview: preview)
    }()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let hotkey = GlobalHotKey()
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        UNUserNotificationCenter.current().delegate = self
        model.showWindow = { [weak self] in self?.show() }
        model.toggleCompactPanel = { [weak self] in self?.togglePanel() }
        model.onHotKeySettingsChanged = { [weak self] in self?.applyHotKeySettings() }
        hotkey.action = { [weak self] in self?.handleHotKeyTriggered() }
        applyHotKeySettings()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "FocusDesk")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(togglePanel)
            button.setAccessibilityLabel("FocusDesk · temporizador y tareas")
        }
        statusItem = item
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuPanel(model: model))
        model.$now.combineLatest(model.$workspace).sink { [weak self] _, _ in self?.updateStatus() }.store(in: &subscriptions)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(show), name: Notification.Name("local.focusdesk.showWindow"), object: nil)
        updateStatus()
        show()

        if CommandLine.arguments.contains("--smoke-test") && model.preview {
            Task {
                let report = await SmokeCheck.run(model, statusVisible: self.statusItem?.isVisible == true)
                print(report)
                fflush(stdout)
                try? report.write(to: model.store.url.deletingLastPathComponent().appendingPathComponent("smoke-report.txt"), atomically: true, encoding: .utf8)
                if !report.hasPrefix("PASS") {
                    exit(1)
                }
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--verify-calendar") && !model.preview {
            model.page = "Ajustes"
            Task {
                let report = await CalendarLiveCheck.run(model)
                print(report)
                fflush(stdout)
                try? report.write(to: model.store.url.deletingLastPathComponent().appendingPathComponent("calendar-check.txt"), atomically: true, encoding: .utf8)
                model.notice = report.hasPrefix("PASS") ? "Comprobación de Calendar superada. Los eventos temporales de prueba se han retirado." : report
                if !report.hasPrefix("PASS") {
                    exit(1)
                }
                if CommandLine.arguments.contains("--quit-after-verify") {
                    exit(0)
                }
            }
        }
        if CommandLine.arguments.contains("--connect-calendar") && !model.preview {
            model.page = "Ajustes"
            Task { await model.calendar.request() }
        }
    }

    private func applyHotKeySettings() {
        let s = model.workspace.settings
        let ok = hotkey.register(keyCode: s.hotKeyCode, modifiers: s.hotKeyModifiers, enabled: s.hotKeyEnabled)
        if s.hotKeyEnabled && !ok {
            model.notice = "El atajo \(s.hotKeyLabel) está ocupado por otra app. Puedes cambiarlo en Ajustes."
        }
    }

    private func handleHotKeyTriggered() {
        switch model.workspace.settings.hotKeyTarget {
        case .mainWindow:
            show()
        case .compactPanel:
            togglePanel()
        }
    }

    private func updateStatus() {
        let title = model.menuTitle
        NSApp.dockTile.badgeLabel = model.session == nil ? nil : title
        statusItem?.button?.title = title == "FocusDesk" ? "" : " " + title
        statusItem?.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem?.button?.toolTip = model.session.map { "FocusDesk · \($0.task.title) · \(title)" } ?? "FocusDesk · abrir tareas"
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc func show() {
        popover.performClose(nil)
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "FocusDesk"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 960, height: 680)
            window.contentView = NSHostingView(rootView: MainView(model: model).environment(\.locale, Locale(identifier: "es_ES")))
            window.setFrameAutosaveName("FocusDeskMainWindow")
            if !window.setFrameUsingName("FocusDeskMainWindow") { window.center() }
            self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    @objc private func settings() { model.page = "Ajustes"; show() }
    @objc private func goTodayPage() { model.page = "Hoy"; show() }
    @objc private func goWeekPage() { model.page = "Semana"; show() }
    @objc private func goHistoryPage() { model.page = "Historial"; show() }
    @objc private func prevDay() {
        model.shiftSelectedDay(by: -1)
    }
    @objc private func nextDay() {
        model.shiftSelectedDay(by: 1)
    }
    @objc private func jumpToCurrentDay() {
        model.selectedDate = Date()
        model.page = "Hoy"
        show()
    }
    // Same draft as the sidebar button: respects the day you are looking at and the start of your working day.
    @objc private func newTask() { model.editingTask = model.newTaskDraft(); show() }
    @objc private func menuStartNext() {
        // No silent no-op with a session running: `start` either resumes, asks for the hand-off, or explains.
        if let next = model.next {
            model.start(next)
        } else if let current = model.session {
            model.notice = "«\(current.task.title)» está en marcha y no hay otra tarea pendiente."
        } else {
            model.notice = "No hay ninguna tarea pendiente. Crea una con ⌘N."
            show()
        }
    }
    @objc private func menuPauseResume() {
        guard let s = model.session, s.endedAt == nil else { return }
        if s.paused { model.resume() } else { model.pause() }
    }
    @objc private func menuFinishSession() {
        if model.session != nil { model.finish() }
    }
    @objc private func menuAddTenMinutes() {
        if model.session?.endedAt == nil { model.addTime(minutes: 10) }
    }

    private func buildMainMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let appMenu = NSMenu(title: "FocusDesk"); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Acerca de FocusDesk", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settingsItem = appMenu.addItem(withTitle: "Ajustes…", action: #selector(settings), keyEquivalent: ","); settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar FocusDesk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Salir de FocusDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem(); bar.addItem(fileItem); fileItem.submenu = NSMenu(title: "Archivo")
        let new = fileItem.submenu!.addItem(withTitle: "Nueva tarea", action: #selector(newTask), keyEquivalent: "n"); new.target = self
        let reopen = fileItem.submenu!.addItem(withTitle: "Abrir planificador", action: #selector(show), keyEquivalent: "0"); reopen.target = self
        let compact = fileItem.submenu!.addItem(withTitle: "Panel compacto de barra", action: #selector(togglePanel), keyEquivalent: "m")
        compact.keyEquivalentModifierMask = [.command, .option, .control]; compact.target = self
        fileItem.submenu!.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let navItem = NSMenuItem(); bar.addItem(navItem); navItem.submenu = NSMenu(title: "Navegación")
        let navToday = navItem.submenu!.addItem(withTitle: "Hoy", action: #selector(goTodayPage), keyEquivalent: "1"); navToday.target = self
        let navWeek = navItem.submenu!.addItem(withTitle: "Semana", action: #selector(goWeekPage), keyEquivalent: "2"); navWeek.target = self
        let navHistory = navItem.submenu!.addItem(withTitle: "Historial", action: #selector(goHistoryPage), keyEquivalent: "3"); navHistory.target = self
        let navSettings = navItem.submenu!.addItem(withTitle: "Ajustes", action: #selector(settings), keyEquivalent: "4"); navSettings.target = self
        navItem.submenu!.addItem(.separator())
        let navPrevDay = navItem.submenu!.addItem(withTitle: "Día anterior", action: #selector(prevDay), keyEquivalent: "["); navPrevDay.target = self
        let navNextDay = navItem.submenu!.addItem(withTitle: "Día siguiente", action: #selector(nextDay), keyEquivalent: "]"); navNextDay.target = self
        let navNowDay = navItem.submenu!.addItem(withTitle: "Ir a hoy", action: #selector(jumpToCurrentDay), keyEquivalent: "t"); navNowDay.target = self

        let sessionItem = NSMenuItem(); bar.addItem(sessionItem); sessionItem.submenu = NSMenu(title: "Sesión")
        let startItem = sessionItem.submenu!.addItem(withTitle: "Empezar siguiente tarea", action: #selector(menuStartNext), keyEquivalent: "s")
        startItem.keyEquivalentModifierMask = [.command, .option, .control]; startItem.target = self
        let pauseItem = sessionItem.submenu!.addItem(withTitle: "Pausar o reanudar", action: #selector(menuPauseResume), keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = [.command, .option, .control]; pauseItem.target = self
        let finishItem = sessionItem.submenu!.addItem(withTitle: "He terminado", action: #selector(menuFinishSession), keyEquivalent: "t")
        finishItem.keyEquivalentModifierMask = [.command, .option, .control]; finishItem.target = self
        let extendItem = sessionItem.submenu!.addItem(withTitle: "Ampliar +10 minutos", action: #selector(menuAddTenMinutes), keyEquivalent: "+")
        extendItem.keyEquivalentModifierMask = [.command, .option, .control]; extendItem.target = self

        let editItem = NSMenuItem(); bar.addItem(editItem); editItem.submenu = NSMenu(title: "Edición")
        for (title, action, key) in [("Deshacer", "undo:", "z"), ("Cortar", "cut:", "x"), ("Copiar", "copy:", "c"), ("Pegar", "paste:", "v"), ("Seleccionar todo", "selectAll:", "a")] {
            editItem.submenu!.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = bar
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            self.model.handleNotificationAction(identifier: actionID, userInfo: userInfo)
            completionHandler()
        }
    }
}
