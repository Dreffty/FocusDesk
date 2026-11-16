import Foundation

/// Where FocusDesk keeps its small preferences (the layout of Hoy, a remembered choice). The demo mode (`--preview`)
/// separates its data folder and must separate these too: taking screenshots must not change the real app.
public enum AppPreferences {
    static let demoSuiteName = "com.articdia.focusdesk.preview"

    public static func store(demo: Bool) -> UserDefaults {
        guard demo, let defaults = UserDefaults(suiteName: demoSuiteName) else { return .standard }
        defaults.removePersistentDomain(forName: demoSuiteName)
        return defaults
    }

    public static let current = store(demo: CommandLine.arguments.contains("--preview"))
}
