import AppKit
import Carbon.HIToolbox
import Combine
import FocusCore
import SwiftUI
import UserNotifications

@main
struct FocusDeskApplication {
    @MainActor static func main() {
        // The login item's watcher: no window, no Dock icon, and never a second planner (`RelaunchWatcher`).
        if CommandLine.arguments.contains(RelaunchGuard.watcherArgument) {
            RelaunchWatcher.run(arguments: CommandLine.arguments)
        }
        let app = NSApplication.shared
        let isIsolatedCheck = CommandLine.arguments.contains("--preview")
        // Only another planner counts: the watcher has no Dock icon and must not make FocusDesk refuse to open.
        if !isIsolatedCheck,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: "local.focusdesk.app")
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular }) {
            // The checks read and write the real data: with FocusDesk open they used to just bring it forward and
            // exit 0, as if they had passed.
            if CommandLine.arguments.contains("--verify-guard") || CommandLine.arguments.contains("--verify-calendar") {
                print("FAIL: FocusDesk ya está abierta (pid \(other.processIdentifier)). Ciérrala antes de comprobar: dos copias escribirían el mismo archivo de datos.")
                exit(2)
            }
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
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate, NSMenuItemValidation {
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
    private var lastPauseToggle = Date.distantPast
    private var warnedSessionHotKeys = false
    private var settingsWindow: NSWindow?
    /// Typing in the main window keeps its own undo history, separate from agenda changes.
    private let textUndoManager = UndoManager()
    private var settingsPaneObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        UNUserNotificationCenter.current().delegate = self
        model.showWindow = { [weak self] in self?.show() }
        model.toggleCompactPanel = { [weak self] in self?.togglePanel() }
        model.onHotKeySettingsChanged = { [weak self] in self?.applyHotKeySettings() }
        model.showSettings = { [weak self] section in self?.showSettings(section) }
        model.isInterfaceVisible = { [weak self] in
            guard let self else { return true }
            let windowOnScreen = [self.window, self.settingsWindow].contains { window in
                guard let window else { return false }
                return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            }
            return windowOnScreen || self.popover.isShown
        }
        hotkey.action = { [weak self] id in self?.handleHotKeyTriggered(id) }
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
        // Session shortcuts exist only while there is a session, so ⌃⌥⌘P and ⌃⌥⌘T stay free for other apps otherwise.
        model.$workspace
            .map { $0.session != nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hasSession in self?.applySessionHotKeys(active: hasSession) }
            .store(in: &subscriptions)
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
        if model.preview, let index = CommandLine.arguments.firstIndex(of: "--snapshots"), index + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                let report = await SnapshotTool.run(model, to: folder)
                print(report)
                fflush(stdout)
                exit(report.hasPrefix("SNAPSHOTS:") ? 0 : 1)
            }
        }
        if CommandLine.arguments.contains("--verify-calendar") && !model.preview {
            showSettings(.connections)
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
        // Proves, in the signed app, that the pieces that defend a session actually work on this Mac.
        if CommandLine.arguments.contains("--verify-guard") && !model.preview {
            let keychain = KeychainWitness.selfCheck()
            let probe = AccessibilityProbe.actuallyGranted()
            let switchSays = MacActivity.accessibility
            let axLine: String
            if !switchSays {
                axLine = "PENDIENTE: Accesibilidad sin conceder; el bloqueo de apps no puede actuar todavía."
            } else if probe {
                axLine = "OK: Accesibilidad concedida y funcionando (sonda contra el Dock)."
            } else {
                axLine = "FAIL: macOS dice que hay permiso pero la sonda falla. " + AccessibilityProbe.brokenPermissionAdvice
            }
            let guardLine = model.relaunchGuard.available
                ? "OK: el vigilante de relanzado se puede instalar (\(model.relaunchGuard.installed ? "ya activo" : "apagado"))."
                : "PENDIENTE: ejecuta la app instalada, no el binario suelto, para poder activar el vigilante."
            let visible = ScreenWindows.visibleOwnerPIDs().count
            let windowsLine = visible > 0
                ? "OK: se ven \(visible) apps con ventana en pantalla (vigilancia de segundo plano)."
                : "FAIL: no se pudo listar ninguna ventana en pantalla."
            // A sample of the page a blocked tab lands on, so it can be looked at without blocking anything.
            let sample = BlockPage.write(
                taskTitle: "Montar el vídeo del lunes",
                host: "youtube.com",
                remaining: 2_715,
                endsAt: Date().addingTimeInterval(2_715),
                allowedDomains: ["claude.ai", "chatgpt.com"],
                in: FileManager.default.temporaryDirectory.appendingPathComponent("FocusDesk-muestra")
            )
            let pageLine = sample.map { "OK: página de bloqueo de muestra en \($0.path)" }
                ?? "FAIL: no se pudo escribir la página de bloqueo."
            // The data file itself: proof that the app can still read what it saved.
            let dataLine: String
            if let failure = model.error {
                dataLine = "FAIL: no se pudieron leer los datos — \(failure)"
            } else {
                dataLine = "OK: datos legibles (\(model.workspace.tasks.count) tareas, \(model.workspace.history.count) sesiones en el historial)."
            }
            let report = [keychain, axLine, guardLine, windowsLine, pageLine, dataLine].joined(separator: "\n")
            print(report)
            fflush(stdout)
            if CommandLine.arguments.contains("--quit-after-verify") {
                exit(report.contains("FAIL") ? 1 : 0)
            }
        }
        if CommandLine.arguments.contains("--connect-calendar") && !model.preview {
            showSettings(.connections)
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

    private func handleHotKeyTriggered(_ id: UInt32) {
        switch id {
        case GlobalHotKey.pauseResumeID:
            menuPauseResume()
        case GlobalHotKey.finishID:
            menuFinishSession()
        default:
            switch model.workspace.settings.hotKeyTarget {
            case .mainWindow:
                show()
            case .compactPanel:
                togglePanel()
            }
        }
    }

    /// ⌃⌥⌘P and ⌃⌥⌘T, system-wide while a session exists: the menu equivalents only work with FocusDesk in front.
    private func applySessionHotKeys(active: Bool) {
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        guard active else {
            hotkey.unregister(id: GlobalHotKey.pauseResumeID)
            hotkey.unregister(id: GlobalHotKey.finishID)
            model.sessionHotKeysActive = false
            return
        }
        let pause = hotkey.register(id: GlobalHotKey.pauseResumeID, keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers)
        let finish = hotkey.register(id: GlobalHotKey.finishID, keyCode: UInt32(kVK_ANSI_T), modifiers: modifiers)
        model.sessionHotKeysActive = pause && finish
        if !(pause && finish), !warnedSessionHotKeys {
            warnedSessionHotKeys = true
            model.notice = "Otra app ya usa ⌃⌥⌘P o ⌃⌥⌘T, así que solo funcionan con FocusDesk delante. Pausa o termina desde la barra de menús."
        }
    }

    private func updateStatus() {
        let title = model.menuTitle
        NSApp.dockTile.badgeLabel = model.session == nil ? nil : title
        statusItem?.button?.title = title == "FocusDesk" ? "" : " " + title
        statusItem?.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem?.button?.toolTip = model.session.map { "FocusDesk · \($0.task.title) · \(title)" } ?? "FocusDesk · abrir tareas"
        // VoiceOver read a fixed name; now the whole state in words, rounded to the minute so it does not churn.
        statusItem?.button?.setAccessibilityLabel(statusAccessibilityText())
        // People decide whether the countdown lives in the menu bar (`the-menu-bar.md › Menu bar extras`).
        statusItem?.isVisible = model.workspace.settings.showMenuBarItem
    }

    private func statusAccessibilityText() -> String {
        guard let s = model.session else {
            if let upcoming = model.scheduledTasks.first(where: { $0.scheduledAt > model.now }),
               upcoming.scheduledAt.timeIntervalSince(model.now) <= Double(upcoming.leadMinutes) * 60 {
                return "FocusDesk, «\(upcoming.title)» empieza en \(spokenDuration(upcoming.scheduledAt.timeIntervalSince(model.now)))"
            }
            return "FocusDesk, sin sesión"
        }
        if s.endedAt != nil { return "FocusDesk, «\(s.task.title)» terminada, confirma el resultado" }
        if s.paused { return "FocusDesk, «\(s.task.title)» en pausa" }
        let remaining = model.currentRemaining(for: s)
        return remaining < 0
            ? "FocusDesk, «\(s.task.title)», tiempo extra \(spokenDuration(remaining))"
            : "FocusDesk, «\(s.task.title)», quedan \(spokenDuration(remaining))"
    }

    @objc private func togglePanel() {
        // With the menu-bar item hidden there is nothing to anchor the panel to: open the planner instead.
        guard let button = statusItem?.button, statusItem?.isVisible == true else { show(); return }
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
            window.delegate = self
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

    /// Quitting is the shortest way out of a block, so a protected session asks for the same thing pausing does.
    /// A restart, a shutdown or a log-out is never stopped; everything else quits as usual.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.canQuitNow(systemQuit: Self.isSystemQuit()) ? .terminateNow : .terminateCancel
    }

    private static func isSystemQuit() -> Bool {
        QuitEvent.isSystemQuit(NSAppleEventManager.shared().currentAppleEvent)
    }

    @objc private func settings() { showSettings(nil) }

    /// Ajustes in its own window, opened with ⌘, from the app menu: a non-customizable toolbar with one pane per
    /// group, the title follows the pane, minimize and zoom dimmed, and the last pane comes back (`settings.md`).
    func showSettings(_ section: SettingsSectionTab?) {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for pane in SettingsSectionTab.panes {
                let root = SettingsPane(model: model, section: pane).environment(\.locale, Locale(identifier: "es_ES"))
                let host = NSHostingController(rootView: root)
                host.title = pane.rawValue
                let item = NSTabViewItem(viewController: host)
                item.label = pane.rawValue
                item.image = NSImage(systemSymbolName: pane.icon, accessibilityDescription: pane.rawValue)
                tabs.addTabViewItem(item)
            }
            let saved = UserDefaults.standard.integer(forKey: "FocusDesk.settingsPane")
            tabs.selectedTabViewItemIndex = min(max(0, saved), SettingsSectionTab.panes.count - 1)
            settingsPaneObservation = tabs.observe(\.selectedTabViewItemIndex, options: [.new]) { _, change in
                if let index = change.newValue { UserDefaults.standard.set(index, forKey: "FocusDesk.settingsPane") }
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 820, height: 640))
            window.backgroundColor = NSColor(Palette.background)
            window.center()
            window.setFrameAutosaveName("FocusDeskSettingsWindow")
            settingsWindow = window
        }
        if let section, let index = SettingsSectionTab.panes.firstIndex(of: section),
           let tabs = settingsWindow?.contentViewController as? NSTabViewController {
            tabs.selectedTabViewItemIndex = index
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The main window gives AppKit the model's undo manager, so Edición › Deshacer and ⌘Z reach agenda changes.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard window === self.window else { return nil }
        // While a text field is being edited, ⌘Z undoes the typing; otherwise it undoes the last agenda change.
        return window.firstResponder is NSTextView ? textUndoManager : model.undoManager
    }

    /// Session commands from the Dock icon too: the menu-bar item can be hidden (`the-menu-bar.md`).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if let s = model.session {
            menu.addItem(NSMenuItem(title: "«\(s.task.title)»", action: nil, keyEquivalent: ""))
            if s.endedAt == nil {
                let pause = menu.addItem(withTitle: s.paused ? "Reanudar" : "Pausar", action: #selector(menuPauseResume), keyEquivalent: "")
                pause.target = self
                let finish = menu.addItem(withTitle: "He terminado", action: #selector(menuFinishSession), keyEquivalent: "")
                finish.target = self
                let extend = menu.addItem(withTitle: "Ampliar 10 minutos", action: #selector(menuAddTenMinutes), keyEquivalent: "")
                extend.target = self
            } else {
                let confirm = menu.addItem(withTitle: "Confirmar el resultado…", action: #selector(menuFinishSession), keyEquivalent: "")
                confirm.target = self
            }
            menu.addItem(.separator())
        } else if model.next != nil {
            let start = menu.addItem(withTitle: "Empezar siguiente tarea", action: #selector(menuStartNext), keyEquivalent: "")
            start.target = self
        }
        let new = menu.addItem(withTitle: "Nueva tarea…", action: #selector(newTask), keyEquivalent: "")
        new.target = self
        return menu
    }

    /// Commands stay visible and are disabled when they cannot run, instead of doing nothing (`the-menu-bar.md`).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let s = model.session
        switch menuItem.action {
        case #selector(menuPauseResume):
            menuItem.title = s?.paused == true ? "Reanudar" : "Pausar"
            return s != nil && s?.endedAt == nil && !model.readOnly
        case #selector(menuFinishSession):
            menuItem.title = s?.endedAt != nil ? "Confirmar el resultado…" : "He terminado"
            return s != nil
        case #selector(menuAddTenMinutes):
            return s != nil && s?.endedAt == nil && !model.readOnly
        case #selector(menuStartNext):
            return model.next != nil && !model.busy && !model.readOnly
        case #selector(newTask):
            return !model.readOnly
        case #selector(prevDay), #selector(nextDay):
            return model.currentPage == .today || model.currentPage == .week
        case #selector(menuEditSelected):
            return model.selectedTask != nil && model.selectedTask?.id != model.session?.task.id && !model.readOnly
        case #selector(menuStartSelected), #selector(menuSnoozeSelected), #selector(menuTodaySelected),
             #selector(menuTomorrowSelected), #selector(menuInboxSelected):
            return model.selectedTaskIsActionable
        case #selector(menuDeleteSelected):
            return model.selectedTask != nil && model.selectedTask?.id != model.session?.task.id && !model.readOnly
        default:
            return true
        }
    }

    @objc private func showShortcutsHelp() {
        let alert = NSAlert()
        alert.messageText = "Atajos de FocusDesk"
        alert.informativeText = """
        Desde cualquier app
        \(model.workspace.settings.hotKeyLabel)  Abrir FocusDesk
        ⌃⌥⌘P  Pausar o reanudar la sesión
        ⌃⌥⌘T  He terminado

        Con FocusDesk delante
        ⌘N  Nueva tarea · ⌘,  Ajustes
        ⌘1 ⌘2 ⌘3  Hoy, Semana, Historial
        ⌘[ ⌘]  Día o semana anterior y siguiente · ⌘T  Hoy
        ⌃⌥⌘S  Empezar la siguiente tarea · ⌃⌥⌘A  Ampliar 10 minutos
        ⌘Z ⇧⌘Z  Deshacer y rehacer cambios en la agenda

        En Hoy, con una tarea elegida
        ↑ ↓  Elegir tarea · ↩  Editar · Espacio  Empezar · ⌫  Borrar
        ⌥↑ ⌥↓  Mover 5 minutos · ⌥⇧↑ ⌥⇧↓  Más corta o más larga
        ⌘E  Editar · menú Tarea para el resto
        """
        alert.addButton(withTitle: "Cerrar")
        alert.runModal()
    }
    @objc private func goTodayPage() { model.page = "Hoy"; show() }
    @objc private func goWeekPage() { model.page = "Semana"; show() }
    @objc private func goHistoryPage() { model.page = "Historial"; show() }
    @objc private func prevDay() {
        model.shiftSelectedDay(by: model.currentPage == .week ? -7 : -1)
    }
    @objc private func nextDay() {
        model.shiftSelectedDay(by: model.currentPage == .week ? 7 : 1)
    }
    @objc private func jumpToCurrentDay() {
        model.selectedDate = Date()
        // On Semana, ⌘T goes to this week without leaving the page.
        if model.currentPage != .week { model.page = "Hoy" }
        show()
    }
    // Same draft as the sidebar button: respects the day you are looking at and the start of your working day.
    @objc private func newTask() {
        // Replacing the open sheet would throw away what was being typed, without asking.
        guard model.editingTask == nil, !model.showCompletion else {
            NSSound.beep()
            model.notice = model.showCompletion
                ? "Confirma primero el resultado de la sesión."
                : "Guarda o cancela la tarea que estás editando antes de crear otra."
            show()
            return
        }
        model.editingTask = model.newTaskDraft()
        show()
    }
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
        // The same keystroke can reach both the system-wide shortcut and the menu: never toggle twice for one press.
        guard Date().timeIntervalSince(lastPauseToggle) > 0.35 else { return }
        lastPauseToggle = Date()
        if s.paused { model.resume() } else { model.pause() }
    }
    @objc private func menuFinishSession() {
        if model.session != nil { model.finish() }
    }
    @objc private func menuEditSelected() { if let task = model.selectedTask { model.editingTask = task; show() } }
    @objc private func menuStartSelected() { if let task = model.selectedTask { model.start(task) } }
    @objc private func menuSnoozeSelected() { if let task = model.selectedTask { model.snoozeTask(task, minutes: 10) } }
    @objc private func menuTodaySelected() { if let task = model.selectedTask { model.moveToFirstFreeSlotToday(task) } }
    @objc private func menuTomorrowSelected() { if let task = model.selectedTask { model.moveToTomorrowSameTime(task) } }
    @objc private func menuInboxSelected() { if let task = model.selectedTask { model.moveToInbox(task) } }
    @objc private func menuDeleteSelected() { if let task = model.selectedTask { model.taskPendingDeletion = task; show() } }
    @objc private func menuAddTenMinutes() {
        if let s = model.session, s.endedAt == nil { model.addTime(minutes: 10) }
    }

    /// Standard order: app, Archivo, Edición, app-specific menus, Ventana, Ayuda (`the-menu-bar.md › Anatomy`).
    private func buildMainMenu() {
        let bar = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            bar.addItem(item)
            let menu = NSMenu(title: title)
            item.submenu = menu
            return menu
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }

        let app = submenu("FocusDesk")
        add(app, "Acerca de FocusDesk", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Ajustes…", #selector(settings), ",", target: self)
        app.addItem(.separator())
        let servicesItem = app.addItem(withTitle: "Servicios", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Servicios")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        add(app, "Ocultar FocusDesk", #selector(NSApplication.hide(_:)), "h")
        add(app, "Ocultar otros", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Mostrar todo", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Salir de FocusDesk", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("Archivo")
        add(file, "Nueva tarea…", #selector(newTask), "n", target: self)
        add(file, "Abrir planificador", #selector(show), "0", target: self)
        add(file, "Panel compacto de la barra", #selector(togglePanel), "m", [.control, .option, .command], target: self)
        file.addItem(.separator())
        add(file, "Cerrar ventana", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edición")
        // Undo and redo reach agenda changes through the main window's undo manager (and text fields as usual).
        add(edit, "Deshacer", Selector(("undo:")), "z")
        add(edit, "Rehacer", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cortar", #selector(NSText.cut(_:)), "x")
        add(edit, "Copiar", #selector(NSText.copy(_:)), "c")
        add(edit, "Pegar", #selector(NSText.paste(_:)), "v")
        add(edit, "Seleccionar todo", #selector(NSText.selectAll(_:)), "a")

        let nav = submenu("Navegación")
        add(nav, "Hoy", #selector(goTodayPage), "1", target: self)
        add(nav, "Semana", #selector(goWeekPage), "2", target: self)
        add(nav, "Historial", #selector(goHistoryPage), "3", target: self)
        nav.addItem(.separator())
        add(nav, "Anterior", #selector(prevDay), "[", target: self)
        add(nav, "Siguiente", #selector(nextDay), "]", target: self)
        add(nav, "Ir a hoy", #selector(jumpToCurrentDay), "t", target: self)

        // Every command on the selected task also lives in the menu bar (`designing-for-macos.md`).
        let taskMenu = submenu("Tarea")
        add(taskMenu, "Editar tarea…", #selector(menuEditSelected), "e", target: self)
        add(taskMenu, "Empezar tarea", #selector(menuStartSelected), target: self)
        add(taskMenu, "Posponer 10 minutos", #selector(menuSnoozeSelected), target: self)
        taskMenu.addItem(.separator())
        add(taskMenu, "Hoy en el primer hueco", #selector(menuTodaySelected), target: self)
        add(taskMenu, "Mañana a la misma hora", #selector(menuTomorrowSelected), target: self)
        add(taskMenu, "Pasar a la bandeja sin hora", #selector(menuInboxSelected), target: self)
        taskMenu.addItem(.separator())
        add(taskMenu, "Borrar tarea…", #selector(menuDeleteSelected), target: self)

        let session = submenu("Sesión")
        add(session, "Empezar siguiente tarea", #selector(menuStartNext), "s", [.control, .option, .command], target: self)
        add(session, "Pausar", #selector(menuPauseResume), "p", [.control, .option, .command], target: self)
        add(session, "He terminado", #selector(menuFinishSession), "t", [.control, .option, .command], target: self)
        // A letter: "+" needs Shift on many keyboards and sits elsewhere on others (`keyboards.md`).
        add(session, "Ampliar 10 minutos", #selector(menuAddTenMinutes), "a", [.control, .option, .command], target: self)

        let windowMenu = submenu("Ventana")
        add(windowMenu, "Minimizar", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        add(windowMenu, "Traer todo al frente", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windowMenu

        let help = submenu("Ayuda")
        add(help, "Atajos de FocusDesk", #selector(showShortcutsHelp), target: self)
        NSApp.helpMenu = help

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

/// Whether a quit comes from macOS restarting, shutting down or logging out: the reason travels in the quit Apple
/// event. ⌘Q, the Dock and `quit app` scripts carry none and still go through the session's gate.
enum QuitEvent {
    static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        let keyword = AEKeyword(kAEQuitReason)
        guard let reason = event.attributeDescriptor(forKeyword: keyword) ?? event.paramDescriptor(forKeyword: keyword) else {
            return false
        }
        let code = reason.enumCodeValue != 0 ? reason.enumCodeValue : reason.typeCodeValue
        return SystemQuit.isSystemQuit(reasonCode: code)
    }

    /// A quit event like the one macOS sends, for the smoke check; `reason` nil is a plain ⌘Q.
    static func make(reason: OSType?, asAttribute: Bool = true) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let reason {
            let value = NSAppleEventDescriptor(enumCode: reason)
            if asAttribute {
                event.setAttribute(value, forKeyword: AEKeyword(kAEQuitReason))
            } else {
                event.setParam(value, forKeyword: AEKeyword(kAEQuitReason))
            }
        }
        return event
    }
}
