import CryptoKit
import Foundation

/// Where the data lives. `workspace.json` holds everything that changes during the day; the history, which is most of
/// the bytes and changes only when a session ends, has its own file. Each has a rolling copy next to it. Files that
/// leave this folder (exports, dated copies) are a single self-contained file, like every copy made before the split.
public struct WorkspaceStore: @unchecked Sendable {
    public let url: URL
    private let memory = WriteMemory()

    public var backupURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("workspace.backup.json")
    }
    public var backupsDirectoryURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("backups")
    }
    public var historyURL: URL {
        url.deletingPathExtension().appendingPathExtension("history.json")
    }
    public var historyBackupURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".history.backup.json")
    }
    /// Added to the name of a kept copy for its history, when something was damaged and they could not be joined.
    public static let keptHistorySuffix = ".history"

    public init(url: URL) { self.url = url }

    public func load() throws -> Workspace {
        var value = FileManager.default.fileExists(atPath: url.path) ? try validateBackup(at: url) : Workspace()
        attachHistory(to: &value)
        return value
    }

    /// For the watcher, which looks at the data every few seconds and has no use for the history.
    public func loadWithoutHistory() throws -> Workspace {
        guard FileManager.default.fileExists(atPath: url.path) else { return Workspace() }
        return try validateBackup(at: url)
    }

    public func validateBackup(at fileURL: URL) throws -> Workspace {
        let data = try Data(contentsOf: fileURL)
        let value = try JSONDecoder().decode(Workspace.self, from: data)
        guard (1...Workspace.currentSchema).contains(value.schema) else { throw StoreError.unsupported }
        return value
    }

    /// The history file's shape. Its key is not `history` on purpose: read by mistake as a workspace it says nothing.
    struct HistoryFile: Codable {
        var version = 1
        var records: [SessionRecord]
    }

    private struct ReadableHistory: Decodable {
        var records: LossyArray<SessionRecord>
    }

    /// A history inside the main file wins: it is the old format, or a self-contained copy put in its place by hand.
    /// A history file that cannot be read does not lock the agenda: its rolling copy is tried, and if that fails too
    /// it counts as an element that could not be read, so the app keeps the original before writing anything.
    private func attachHistory(to value: inout Workspace) {
        guard value.history.isEmpty else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: historyURL.path) || manager.fileExists(atPath: historyBackupURL.path) else { return }
        let read = [historyURL, historyBackupURL].lazy.compactMap { source -> ReadableHistory? in
            guard let data = try? Data(contentsOf: source) else { return nil }
            return try? JSONDecoder().decode(ReadableHistory.self, from: data)
        }.first
        guard let read else {
            value.decodingSkipped += 1
            return
        }
        value.history = read.records.elements
        value.decodingSkipped += read.records.skipped
        // The history is written first. Cut off right there, a session already in it is also still in the main file.
        if let session = value.session, value.history.contains(where: { $0.id == session.id }) {
            value.session = nil
        }
    }

    /// `rollingBackup: false` for an export: one self-contained file where the user chose, with no history file and no
    /// rolling copy written (or overwritten) next to it.
    ///
    /// Otherwise nothing is written when nothing changed: with a rule on, this runs every minute of the day, and a
    /// file that did not change costs one comparison instead of two rewrites. The history goes first (see above).
    public func save(_ workspace: Workspace, rollingBackup: Bool = true) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard rollingBackup else {
            try writeProtected(try Self.encodeReadable(workspace), to: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeIfChanged(try encoder.encode(HistoryFile(records: workspace.history)), to: historyURL, mirror: historyBackupURL)
        var withoutHistory = workspace
        withoutHistory.history = []
        try writeIfChanged(try encoder.encode(withoutHistory), to: url, mirror: backupURL)
    }

    private static func encodeReadable(_ workspace: Workspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(workspace)
    }

    /// Plain atomic write plus 0600. `completeFileProtectionUnlessOpen` is an iOS data-protection class: on macOS 26 it
    /// leaves the file unreadable even to FocusDesk itself ("Operation not permitted"), which locked a real agenda out
    /// of its own data. On a Mac the encryption at rest is FileVault's job, and the owner-only permissions below are
    /// what keeps other accounts out.
    private func writeProtected(_ data: Data, to target: URL) throws {
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private func writeIfChanged(_ data: Data, to target: URL, mirror: URL) throws {
        let digest = SHA256.hash(data: data)
        // Remembering the content is not enough: the file may have been deleted or edited behind FocusDesk's back.
        if let last = memory.mark(for: target.path), last.digest == digest, last.stamp == WriteMemory.stamp(of: target) { return }
        try writeProtected(data, to: target)
        if let stamp = WriteMemory.stamp(of: target) {
            memory.remember(WriteMemory.Mark(digest: digest, stamp: stamp), for: target.path)
        }
        // An automatic rolling copy, so a damaged file can be recovered without data loss.
        try? writeProtected(data, to: mirror)
    }

    /// A copy to keep in `backups/`. One self-contained file when everything reads; if something is damaged, the bytes
    /// as they are, because that is the point of keeping them.
    @discardableResult
    public func createTimestampedBackup(prefix: String = "workspace", at now: Date = Date()) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try FileManager.default.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let destination = backupsDirectoryURL.appendingPathComponent("\(prefix)-\(stamp)-\(UUID().uuidString.prefix(6)).json")
        if let whole = try? load(), whole.decodingSkipped == 0 {
            try writeProtected(try Self.encodeReadable(whole), to: destination)
            return destination
        }
        try FileManager.default.copyItem(at: url, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        if FileManager.default.fileExists(atPath: historyURL.path) {
            let keptHistory = URL(fileURLWithPath: destination.path + Self.keptHistorySuffix)
            try? FileManager.default.copyItem(at: historyURL, to: keptHistory)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keptHistory.path)
        }
        return destination
    }

    /// The rolling copies mirror what is being written, so they recover a damaged file but not a bad save.
    /// A dated snapshot per day is the copy you can actually go back to. Returns the snapshot when one was taken.
    /// Nothing that does not read back whole becomes a snapshot, and when one fails the older ones stay where they are.
    @discardableResult
    public func createDailySnapshotIfNeeded(at now: Date = Date(), calendar: Calendar = .current, keeping limit: Int = 14) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        let stamp = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        let destination = backupsDirectoryURL.appendingPathComponent("daily-\(stamp).json")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        let whole = try load()
        guard whole.decodingSkipped == 0 else { throw StoreError.partlyReadable }
        try FileManager.default.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        try writeProtected(try Self.encodeReadable(whole), to: destination)
        do {
            _ = try validateBackup(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        pruneDailySnapshots(keeping: limit)
        return destination
    }

    /// Keeps the newest `limit` dated snapshots that can still be read. Only touches the files this store creates daily.
    /// Copies that stopped being readable do not count: two weeks of them must not push out the last good one, which
    /// is how a macOS change once left nothing to go back to.
    public func pruneDailySnapshots(keeping limit: Int) {
        guard limit > 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: backupsDirectoryURL.path) else { return }
        let daily = names.filter { $0.hasPrefix("daily-") && $0.hasSuffix(".json") }.sorted()
        guard daily.count > limit else { return }
        var readable = 0
        for name in daily.reversed() {
            let file = backupsDirectoryURL.appendingPathComponent(name)
            if readable >= limit {
                try? FileManager.default.removeItem(at: file)
            } else if (try? validateBackup(at: file)) != nil {
                readable += 1
            }
        }
    }

    public func recoverFromRollingBackup(at now: Date = Date()) throws -> Workspace {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { throw StoreError.noBackupAvailable }
        var recovered = try validateBackup(at: backupURL)
        attachHistory(to: &recovered)
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
        case partlyReadable

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                return "Versión de archivo no compatible con esta versión de FocusDesk."
            case .noBackupAvailable:
                return "No hay una copia automática previa disponible."
            case .partlyReadable:
                return "Parte de los datos no se puede leer: no se hace copia con fecha hasta resolverlo."
            }
        }
    }
}

/// For the watcher, which looks at the data every two seconds while FocusDesk is closed: the file is only read and
/// decoded again when it changed on disk.
public final class WorkspaceWatchReader {
    public let store: WorkspaceStore
    public private(set) var decodeCount = 0
    private var lastStamp: WriteMemory.Stamp?
    private var cached: Workspace?
    private var hasRead = false

    public init(store: WorkspaceStore) { self.store = store }

    public func read() -> Workspace? {
        // The date and size are taken first: a change made while reading is seen on the next look.
        let stamp = WriteMemory.stamp(of: store.url)
        if hasRead, stamp == lastStamp { return cached }
        hasRead = true
        lastStamp = stamp
        decodeCount += 1
        cached = try? store.loadWithoutHistory()
        return cached
    }
}

/// What was last written to each file, to know when writing again would change nothing.
final class WriteMemory: @unchecked Sendable {
    struct Stamp: Equatable {
        var size: Int
        var modified: Date
    }

    struct Mark {
        var digest: SHA256.Digest
        var stamp: Stamp
    }

    private let lock = NSLock()
    private var marks: [String: Mark] = [:]

    func mark(for path: String) -> Mark? {
        lock.lock(); defer { lock.unlock() }
        return marks[path]
    }

    func remember(_ mark: Mark, for path: String) {
        lock.lock(); defer { lock.unlock() }
        marks[path] = mark
    }

    static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Stamp(size: size, modified: modified)
    }
}

/// Writes on its own thread, one at a time and in the order asked. The minute's checkpoint goes in the background; a
/// save the app has to know the result of waits its turn, so it can never be overwritten by an older one in the queue.
public final class WorkspaceSaver: @unchecked Sendable {
    public let store: WorkspaceStore
    private let queue = DispatchQueue(label: "local.focusdesk.saver", qos: .utility)

    public init(store: WorkspaceStore) { self.store = store }

    public func saveNow(_ workspace: Workspace) throws {
        try queue.sync { try store.save(workspace) }
    }

    public func saveInBackground(_ workspace: Workspace, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [store] in
            do {
                try store.save(workspace)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// For anything that reads or replaces the files directly.
    public func waitForPendingWrites() {
        queue.sync {}
    }
}
