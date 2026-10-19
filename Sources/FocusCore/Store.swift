import Foundation

public struct WorkspaceStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Workspace {
        guard FileManager.default.fileExists(atPath: url.path) else { return Workspace() }
        let value = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
        guard value.schema == 1 else { throw StoreError.unsupported }
        return value
    }
    public func save(_ workspace: Workspace) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public enum StoreError: Error { case unsupported }
}
