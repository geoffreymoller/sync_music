import Foundation

public enum SyncMusicPaths {
    public static func defaultRootDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SyncMusic", isDirectory: true)
    }

    public static func configFile(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("config.json")
    }

    public static func stateFile(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("state.json")
    }

    public static func logsDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public static func runsDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("runs", isDirectory: true)
    }

    public static func activeLogFile(rootDirectory: URL) -> URL {
        logsDirectory(rootDirectory: rootDirectory).appendingPathComponent("syncmusic.log.jsonl")
    }

    public static func rotatedLogFile(rootDirectory: URL, index: Int) -> URL {
        logsDirectory(rootDirectory: rootDirectory).appendingPathComponent("syncmusic.log.\(index).jsonl")
    }

    public static func lastRunSnapshotFile(rootDirectory: URL) -> URL {
        runsDirectory(rootDirectory: rootDirectory).appendingPathComponent("last-run.json")
    }

    public static func crashContextFile(rootDirectory: URL) -> URL {
        runsDirectory(rootDirectory: rootDirectory).appendingPathComponent("crash-context.json")
    }

    public static func ensureDirectories(rootDirectory: URL) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory(rootDirectory: rootDirectory), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runsDirectory(rootDirectory: rootDirectory), withIntermediateDirectories: true)
    }
}
