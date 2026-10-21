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

            UserDefaults.standard.set(true, forKey: "FocusDesk.dayLayoutHourly")
            model.page = AppPage.today.rawValue

            // Editor of a recurring occurrence (shows the series picker and its hint).
            if let series = model.workspace.tasks.first(where: { $0.repeatRule != .never }) {
                model.editingTask = series
                try await settle(0.8)
                try capture(window.attachedSheet?.contentView, name: "editor", in: folder)
                written.append("editor")
                model.editingTask = nil
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
        let running = FocusTask(title: "Escribir el guion", category: "Contenido", scheduledAt: Date().addingTimeInterval(-600), minutes: 50, checklist: "Estructura\nGanchos\nCierre")
        model.saveTask(running)
        model.start(running)
        try await idle(model)
        model.setCheck("0", value: true)
        model.selectedDate = Date()
        model.notice = nil
    }

    private static func pagesToShow(_ model: AppModel) -> [(String, () -> Void)] {
        [
            ("hoy-horas", { model.page = AppPage.today.rawValue; UserDefaults.standard.set(true, forKey: "FocusDesk.dayLayoutHourly") }),
            ("hoy-lista", { model.page = AppPage.today.rawValue; UserDefaults.standard.set(false, forKey: "FocusDesk.dayLayoutHourly") }),
            ("semana", { model.page = AppPage.week.rawValue }),
            ("historial", { model.page = AppPage.history.rawValue }),
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
        NSApp.windows.first { $0.frameAutosaveName == "FocusDeskMainWindow" }
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
