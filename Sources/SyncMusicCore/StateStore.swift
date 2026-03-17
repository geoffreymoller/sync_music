import Foundation

public final class StateStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public var rootDirectoryURL: URL { rootDirectory }

    public init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            self.rootDirectory = SyncMusicPaths.defaultRootDirectory()
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func loadConfig() throws -> AppConfig {
        let url = SyncMusicPaths.configFile(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfig()
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(AppConfig.self, from: data)
    }

    public func saveConfig(_ config: AppConfig) throws {
        try createRootDirectoryIfNeeded()
        let url = SyncMusicPaths.configFile(rootDirectory: rootDirectory)
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    public func loadState() throws -> SyncState {
        let url = SyncMusicPaths.stateFile(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SyncState()
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(SyncState.self, from: data)
    }

    public func saveState(_ state: SyncState) throws {
        try createRootDirectoryIfNeeded()
        let url = SyncMusicPaths.stateFile(rootDirectory: rootDirectory)
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    private func createRootDirectoryIfNeeded() throws {
        try SyncMusicPaths.ensureDirectories(rootDirectory: rootDirectory)
    }
}
