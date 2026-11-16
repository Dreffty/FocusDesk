import AppKit
import FocusCore
import SwiftUI

/// Draws FocusDesk's own windows into PNG files with realistic demo data, so the interface can be checked without
/// screen-recording or accessibility permissions (it only renders its own views). `--preview --snapshots <folder>`.
@MainActor
enum SnapshotTool {
    static func run(_ model: AppModel, to folder: URL) async -> String {
        do {
            guard model.preview else { throw Failure("Snapshots require --preview") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await seed(model)

            var written: [String] = []
            guard let window = mainWindow() else { throw Failure("Main window not found") }
            window.setContentSize(NSSize(width: 1240, height: 860))
            // Every screen in both appearances (and optionally at the largest text size): the app follows the system.
            let appearances: [(String, NSAppearance.Name)] = [("oscuro", .darkAqua), ("claro", .aqua)]
            let scale = CommandLine.arguments.contains("--snapshot-large-text") ? 1.3 : 1.0
            model.updateSettings { $0.textScale = scale }
            for (suffix, appearanceName) in appearances {
                NSApp.appearance = NSAppearance(named: appearanceName)
                try await settle(0.6)
                for (name, show) in pagesToShow(model) {
                    show()
                    try await settle()
                    try capture(window.contentView, name: "\(name)-\(suffix)", in: folder)
                    written.append("\(name)-\(suffix)")
                    if let page = largestScrollContent(in: window.contentView) {
                        try capture(page, name: "\(name)-\(suffix)-completa", in: folder)
                    }
                }
                // ⌘K and Novedades, the two ways in to every feature.
                for (name, flag) in [("buscar", \AppModel.showFeatureFinder), ("novedades", \AppModel.showWhatsNew)] {
                    model.page = AppPage.today.rawValue
                    model[keyPath: flag] = true
                    try await settle(0.9)
                    try capture(window.attachedSheet?.contentView, name: "\(name)-\(suffix)", in: folder)
                    written.append("\(name)-\(suffix)")
                    model[keyPath: flag] = false
                    try await settle(0.7)
                }
            }
            // The settings window, pane by pane, in both appearances.
            model.showSettings?(nil)
            try await settle(0.6)
            if let settings = NSApp.windows.first(where: { $0.contentViewController is NSTabViewController }),
               let tabs = settings.contentViewController as? NSTabViewController {
                for (suffix, appearanceName) in appearances {
                    NSApp.appearance = NSAppearance(named: appearanceName)
                    for index in tabs.tabViewItems.indices {
                        tabs.selectedTabViewItemIndex = index
                        try await settle(0.5)
                        let name = "ajustes-\(index + 1)-\(suffix)"
                        try capture(settings.contentView?.superview ?? settings.contentView, name: name, in: folder)
                        written.append(name)
                    }
                }
                settings.orderOut(nil)
            }
            NSApp.appearance = NSAppearance(named: .darkAqua)
            if CommandLine.arguments.contains("--snapshot-pages-only") {
                return "SNAPSHOTS: " + written.joined(separator: ", ")
            }

            AppPreferences.current.set(true, forKey: "FocusDesk.dayLayoutHourly")
            model.page = AppPage.today.rawValue

            // The editor of a game rule, with the game picker and the timed-match settings.
            model.editingGeneralRule = GeneralBlockRule.gameTemplate(GameCatalog.game(id: "fortnite")!)
            try await settle(0.8)
            try capture(window.attachedSheet?.contentView, name: "editor-juego", in: folder)
            written.append("editor-juego")
            if let page = largestScrollContent(in: window.attachedSheet?.contentView) {
                try capture(page, name: "editor-juego-completa", in: folder)
                written.append("editor-juego-completa")
            }
            model.editingGeneralRule = nil
            try await settle()

            // Editor of a recurring occurrence (shows the series picker and its hint).
            if let series = model.workspace.tasks.first(where: { $0.repeatRule != .never }) {
                model.editingTask = series
                try await settle(0.8)
                try capture(window.attachedSheet?.contentView, name: "editor", in: folder)
                written.append("editor")
                model.editingTask = nil
                try await settle()
            }

            // The editor of a task that locks itself, so the protection section can be looked at.
            var guarded = FocusTask(
                title: "Montar el vídeo del lunes",
                category: "Contenido",
                scheduledAt: Date().addingTimeInterval(3600),
                minutes: 90,
                strict: true,
                apps: model.workspace.tasks.first(where: { !$0.apps.isEmpty })?.apps ?? [],
                domains: "claude.ai, chatgpt.com",
                protection: .challenge,
                unlockChars: 32,
                blockAction: .close,
                webBlockAction: .redirect,
                blockedFolders: [NSHomeDirectory() + "/Movies", NSHomeDirectory() + "/Downloads"]
            )
            if guarded.apps.isEmpty {
                guarded.apps = [AllowedApp(id: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")]
            }
            model.editingTask = guarded
            try await settle(0.8)
            try capture(window.attachedSheet?.contentView, name: "editor-plegado", in: folder)
            written.append("editor-plegado")
            model.editingTask = nil
            try await settle()
            model.unfoldEditorForSnapshot = true
            model.editingTask = guarded
            try await settle(0.8)
            model.unfoldEditorForSnapshot = false
            try capture(window.attachedSheet?.contentView, name: "editor-proteccion", in: folder)
            written.append("editor-proteccion")
            if let page = largestScrollContent(in: window.attachedSheet?.contentView) {
                try capture(page, name: "editor-proteccion-completa", in: folder)
                written.append("editor-proteccion-completa")
            }
            model.editingTask = nil
            try await settle()

            // The code you have to type to leave a protected session.
            model.pendingStop = PendingStopChallenge(
                reason: .pause,
                expected: UnlockChallenge.make(length: 32),
                typed: String(UnlockChallenge.make(length: 32).prefix(0))
            )
            if let expected = model.pendingStop?.expected {
                model.pendingStop?.typed = String(expected.prefix(11))
            }
            let unlock = NSHostingView(rootView: UnlockSheet(model: model).environment(\.locale, Locale(identifier: "es_ES")))
            unlock.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
            let unlockWindow = NSWindow(contentRect: unlock.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            unlockWindow.contentView = unlock
            try await settle(0.6)
            try capture(unlock, name: "codigo-desbloqueo", in: folder)
            written.append("codigo-desbloqueo")
            model.pendingStop = nil
            try await settle()

            // The same code, asked for deleting a protected task five minutes before it starts.
            if let soon = model.workspace.tasks.first(where: { model.protectedBeforeStart($0) }) {
                model.pendingStop = PendingStopChallenge(reason: .cancel, expected: UnlockChallenge.make(length: 24),
                                                         runUp: .delete(soon), runUpAction: "Borrarla")
                if let expected = model.pendingStop?.expected { model.pendingStop?.typed = String(expected.prefix(6)) }
                try await settle(0.6)
                try capture(unlock, name: "codigo-antes-de-empezar", in: folder)
                written.append("codigo-antes-de-empezar")
                model.pendingStop = nil
                try await settle()
            }

            // Menu-bar panel, during the session.
            let panel = NSHostingView(rootView: MenuPanel(model: model).environment(\.locale, Locale(identifier: "es_ES")))
            panel.frame = NSRect(x: 0, y: 0, width: 360, height: 520)
            let offscreen = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            offscreen.contentView = panel
            try await settle()
            try capture(panel, name: "panel", in: folder)
            written.append("panel")

            // Result confirmation after «He terminado».
            model.finish()
            for _ in 0..<200 where model.busy { try await Task.sleep(nanoseconds: 20_000_000) }
            try await settle(0.8)
            try capture(window.attachedSheet?.contentView, name: "confirmacion", in: folder)
            written.append("confirmacion")

            // Hoy with nothing running: the card of the next task instead of the session.
            model.confirm(completed: true, note: "")
            try await idle(model)
            model.page = AppPage.today.rawValue
            try await settle(0.8)
            try capture(window.contentView, name: "hoy-sin-sesion", in: folder)
            written.append("hoy-sin-sesion")

            // What counts as study, with one site added today (it shows «desde mañana»).
            model.addStudyWeb("apuntes.ejemplo.com")
            for (suffix, appearance) in appearances {
                let host = NSHostingView(rootView: StudySourcesSettings(model: model).padding(20).frame(width: 640).background(Palette.background))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                try await settle(0.3)
                try capture(host, name: "estudio-\(suffix)", in: folder)
                written.append("estudio-\(suffix)")
            }

            return "SNAPSHOTS: " + written.map { $0 + ".png" }.joined(separator: ", ") + " → " + folder.path
        } catch {
            return "SNAPSHOTS FAIL: \(error.localizedDescription)"
        }
    }

    /// A day with what usually goes wrong visually: overlapping tasks, one crossing midnight, a recurring series,
    /// something overdue, the inbox, a finished session in the history and one running now.
    private static func seed(_ model: AppModel) async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let currentHour = calendar.component(.hour, from: Date())
        let base = max(8, min(currentHour, 20))

        model.saveTask(FocusTask(title: "Grabar el vídeo del lunes", category: "Contenido", scheduledAt: at(base, 0), minutes: 60, checklist: "Preparar el guion\nGrabar las tomas\nGuardar el material"))
        model.saveTask(FocusTask(title: "Editar el vídeo", category: "Contenido", scheduledAt: at(base, 30), minutes: 45))
        model.saveTask(FocusTask(title: "Responder pedidos de la tienda", category: "Tienda", scheduledAt: at(base, 30), minutes: 20))
        model.saveTask(FocusTask(title: "Estudiar Álgebra", category: "Estudio", scheduledAt: at(min(base + 2, 22), 0), minutes: 45, repeatRule: .daily))
        model.saveTask(FocusTask(title: "Repasar apuntes de noche", category: "Estudio", scheduledAt: at(23, 30), minutes: 60))
        model.saveTask(FocusTask(title: "Preparar el guion de la semana", category: "Contenido", scheduledAt: at(9, 0, dayOffset: -2), minutes: 30))
        model.saveTask(FocusTask(title: "Llamar al proveedor", isScheduled: false, dueDate: at(18, 0, dayOffset: 1), minutes: 15))
        model.saveTask(FocusTask(title: "Grabar intro para el canal", category: "Contenido", scheduledAt: at(10, 0, dayOffset: 1), minutes: 30))
        model.saveTask(FocusTask(title: "Inventario de la tienda", category: "Tienda", scheduledAt: at(16, 0, dayOffset: 2), minutes: 60))
        // Five minutes away and protected: already defends itself, and closes a folder of films while it runs.
        model.saveTask(FocusTask(title: "Repasar redes para el examen", category: "Estudio", scheduledAt: Date().addingTimeInterval(300),
                                 minutes: 45, protection: .challenge, unlockChars: 24,
                                 blockedFolders: [NSHomeDirectory() + "/Movies"]))

        // A finished session in the history.
        let done = FocusTask(title: "Revisar correo", category: "Personal", scheduledAt: at(max(0, base - 1), 0), minutes: 20)
        model.saveTask(done)
        model.start(done)
        try await idle(model)
        try await Task.sleep(nanoseconds: 300_000_000)
        model.finish()
        try await idle(model)
        model.confirm(completed: true, note: "Bandeja a cero")

        // And one running now, so the live block, the session hero and the panel show a real session.
        let running = FocusTask(title: "Escribir el guion", category: "Contenido", scheduledAt: Date().addingTimeInterval(-600), minutes: 50, checklist: "Estructura\nGanchos\nCierre", pomodoroWorkMinutes: 25)
        model.saveTask(running)
        model.start(running)
        try await idle(model)
        model.setCheck("0", value: true)

        // Rules for the Antidistracción pages: one of each state. Fictitious .test domains only, so the demo run
        // never blocks anything real on this Mac.
        func rule(_ kind: GeneralRuleKind, _ name: String, _ domain: String, enabled: Bool = true) -> GeneralBlockRule {
            var rule = GeneralBlockRule.template(kind)
            rule.name = name
            rule.domains = domain
            rule.blockedTitleKeywords = ""
            rule.enabled = enabled
            return rule
        }
        let pomodoro = rule(.pomodoro, "Pomodoro de enfoque", "redes-sociales.test")
        model.saveGeneralRule(pomodoro)
        if let saved = model.workspace.generalRules.first(where: { $0.id == pomodoro.id }) { model.startPomodoroRule(saved) }
        model.saveGeneralRule(rule(.dailyLimit, "Shorts y redes", "videos-cortos.test"))
        model.saveGeneralRule(rule(.schedule, "Noche sin pantallas", "series.test"))
        model.saveGeneralRule(rule(.launchLimit, "Correo contado", "correo.test", enabled: false))
        var quick = rule(.countdown, "Bloqueo rápido · Redes y vídeos cortos", "redes-sociales.test")
        quick.protection = .none
        quick.startCountdown(minutes: 30)
        model.saveGeneralRule(quick)
        // A game rule in the middle of a timed match. «Otro juego» with a fictitious app, so it never closes a real game.
        var game = GeneralBlockRule.gameTemplate(GameCatalog.game(id: GameCatalog.customID)!)
        game.name = "1 h de estudio por partida · Juego de prueba"
        game.blockApps = true
        game.apps = [AllowedApp(id: "com.example.juego-de-prueba", name: "Juego de prueba", path: "/Applications/Juego de prueba.app")]
        game.protection = .none
        game.startTimedMatch()
        model.saveGeneralRule(game)
        model.updateSettings { $0.continuousBreakEnabled = true }

        model.selectedDate = Date()
        model.notice = nil
    }

    private static func pagesToShow(_ model: AppModel) -> [(String, () -> Void)] {
        [
            ("hoy-horas", { model.page = AppPage.today.rawValue; AppPreferences.current.set(true, forKey: "FocusDesk.dayLayoutHourly") }),
            ("hoy-lista", { model.page = AppPage.today.rawValue; AppPreferences.current.set(false, forKey: "FocusDesk.dayLayoutHourly") }),
            ("semana", { model.page = AppPage.week.rawValue }),
            ("historial", { model.historyShowsAudit = false; model.page = AppPage.history.rawValue }),
            ("historial-registro", { model.historyShowsAudit = true; model.page = AppPage.history.rawValue }),
            ("bloquear", { model.historyShowsAudit = false; model.page = AppPage.blocking.rawValue }),
            ("reglas", { model.page = AppPage.rules.rawValue }),
            ("descansos", { model.page = AppPage.breaks.rawValue }),
        ]
    }

    private static func largestScrollContent(in root: NSView?) -> NSView? {
        guard let root else { return nil }
        var best: NSView?
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.bounds.height > (best?.bounds.height ?? 0) {
                best = document
            }
            stack.append(contentsOf: view.subviews)
        }
        return best
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == AppDelegate.mainWindowID }
    }

    private static func settle(_ seconds: Double = 0.5) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func idle(_ model: AppModel) async throws {
        for _ in 0..<500 where model.busy { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    private static func capture(_ view: NSView?, name: String, in folder: URL) throws {
        guard let view else { throw Failure("Nothing to capture for \(name)") }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw Failure("Empty view for \(name)")
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure("PNG for \(name)") }
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
