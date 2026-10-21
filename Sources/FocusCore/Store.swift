import Foundation

public struct WorkspaceStore {
    public let url: URL
    public var backupURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("workspace.backup.json")
    }
    public var backupsDirectoryURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("backups")
    }

    public init(url: URL) { self.url = url }

    public func load() throws -> Workspace {
        guard FileManager.default.fileExists(atPath: url.path) else { return Workspace() }
        return try validateBackup(at: url)
    }

    public func validateBackup(at fileURL: URL) throws -> Workspace {
        let data = try Data(contentsOf: fileURL)
        let value = try JSONDecoder().decode(Workspace.self, from: data)
        guard (1...Workspace.currentSchema).contains(value.schema) else { throw StoreError.unsupported }
        return value
    }

    public func save(_ workspace: Workspace) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Keep an automatic rolling backup so corrupt primary files can be recovered without data loss.
        try? data.write(to: backupURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }

    @discardableResult
    public func createTimestampedBackup(prefix: String = "workspace", at now: Date = Date()) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try FileManager.default.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let destination = backupsDirectoryURL.appendingPathComponent("\(prefix)-\(stamp)-\(UUID().uuidString.prefix(6)).json")
        try FileManager.default.copyItem(at: url, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    /// `workspace.backup.json` mirrors what is being written, so it recovers a damaged file but not a bad save.
    /// A dated snapshot per day is the copy you can actually go back to. Returns the snapshot when one was taken.
    @discardableResult
    public func createDailySnapshotIfNeeded(at now: Date = Date(), calendar: Calendar = .current, keeping limit: Int = 14) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        let stamp = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        let destination = backupsDirectoryURL.appendingPathComponent("daily-\(stamp).json")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        try FileManager.default.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        pruneDailySnapshots(keeping: limit)
        return destination
    }

    /// Keeps the newest `limit` dated snapshots. Only touches the files this store creates daily.
    public func pruneDailySnapshots(keeping limit: Int) {
        guard limit > 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: backupsDirectoryURL.path) else { return }
        let daily = names.filter { $0.hasPrefix("daily-") && $0.hasSuffix(".json") }.sorted()
        guard daily.count > limit else { return }
        for name in daily.prefix(daily.count - limit) {
            try? FileManager.default.removeItem(at: backupsDirectoryURL.appendingPathComponent(name))
        }
    }

    public func recoverFromRollingBackup(at now: Date = Date()) throws -> Workspace {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { throw StoreError.noBackupAvailable }
        let recovered = try validateBackup(at: backupURL)
        _ = try? createTimestampedBackup(prefix: "corrupt-preserved", at: now)
        var sanitized = recovered
        sanitized.session?.runningSince = nil
        sanitized.session?.runningUptime = nil
        try save(sanitized)
        return sanitized
    }

    @discardableResult
    public func restore(_ backupWorkspace: Workspace, at now: Date = Date()) throws -> (workspace: Workspace, previousBackupURL: URL?) {
        guard (1...Workspace.currentSchema).contains(backupWorkspace.schema) else { throw StoreError.unsupported }
        let previousURL = try createTimestampedBackup(prefix: "before-restore", at: now)
        var sanitized = backupWorkspace
        sanitized.session?.runningSince = nil
        sanitized.session?.runningUptime = nil
        try save(sanitized)
        return (sanitized, previousURL)
    }

    public enum StoreError: LocalizedError, Equatable {
        case unsupported
        case noBackupAvailable

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                return "Versión de archivo no compatible con esta versión de FocusDesk."
            case .noBackupAvailable:
                return "No hay una copia automática previa disponible."
            }
        }
    }
}
