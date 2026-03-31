import Foundation
import OSLog

public actor DiagnosticsLogger {
    public nonisolated let rootDirectory: URL

    private let subsystem = "local.geoff.syncmusic"
    private let logger = Logger(subsystem: "local.geoff.syncmusic", category: "diagnostics")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var minimumLevel: LogLevel = .info
    private var debugLogging = false
    private var maxLogFileSizeBytes = 2_000_000
    private var maxRotatedLogFiles = 5

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? SyncMusicPaths.defaultRootDirectory()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func updateConfig(_ config: AppConfig) {
        minimumLevel = config.logLevel
        debugLogging = config.debugLogging
        maxLogFileSizeBytes = max(32_768, config.maxLogFileSizeBytes)
        maxRotatedLogFiles = max(1, config.maxRotatedLogFiles)
    }

    public func log(_ event: SyncEvent) {
        guard shouldLog(level: event.level) else {
            return
        }

        writeToUnifiedLog(event)

        do {
            try SyncMusicPaths.ensureDirectories(rootDirectory: rootDirectory)
            try append(event)
        } catch {
            logger.error("Failed to persist diagnostics event: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func saveLastRunSnapshot(_ snapshot: LastRunSnapshot) {
        do {
            try SyncMusicPaths.ensureDirectories(rootDirectory: rootDirectory)
            let data = try encoder.encode(snapshot)
            try data.write(to: SyncMusicPaths.lastRunSnapshotFile(rootDirectory: rootDirectory), options: .atomic)
        } catch {
            logger.error("Failed writing last run snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadLastRunSnapshot() -> LastRunSnapshot? {
        do {
            let url = SyncMusicPaths.lastRunSnapshotFile(rootDirectory: rootDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }

            let data = try Data(contentsOf: url)
            return try decoder.decode(LastRunSnapshot.self, from: data)
        } catch {
            logger.error("Failed loading last run snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func setCrashContext(_ context: RunContext) {
        do {
            try SyncMusicPaths.ensureDirectories(rootDirectory: rootDirectory)
            let data = try encoder.encode(context)
            try data.write(to: SyncMusicPaths.crashContextFile(rootDirectory: rootDirectory), options: .atomic)
        } catch {
            logger.error("Failed writing crash context: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadCrashContext() -> RunContext? {
        do {
            let url = SyncMusicPaths.crashContextFile(rootDirectory: rootDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }

            let data = try Data(contentsOf: url)
            return try decoder.decode(RunContext.self, from: data)
        } catch {
            logger.error("Failed loading crash context: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func clearCrashContext() {
        do {
            let url = SyncMusicPaths.crashContextFile(rootDirectory: rootDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }

            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("Failed clearing crash context: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadRecentEvents(limit: Int) -> [SyncEvent] {
        let requestedLimit = max(1, limit)
        var events: [SyncEvent] = []

        for url in logFilesNewestFirst() {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                continue
            }

            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline).reversed()
            for line in lines {
                guard let lineData = String(line).data(using: .utf8),
                      let event = try? decoder.decode(SyncEvent.self, from: lineData) else {
                    continue
                }

                events.append(event)
                if events.count == requestedLimit {
                    return events
                }
            }
        }

        return events
    }

    public func latestLogFileURL() -> URL? {
        let url = SyncMusicPaths.activeLogFile(rootDirectory: rootDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func diagnosticsDirectoryURL() -> URL {
        rootDirectory
    }

    public func buildDiagnosticsSummary(
        config: AppConfig,
        state: SyncState,
        currentStatus: String,
        appVersion: String
    ) -> DiagnosticsSummary {
        let lastRun = loadLastRunSnapshot()
        let crashContext = loadCrashContext()
        let recentEvents = loadRecentEvents(limit: 8)

        var lines: [String] = []
        lines.append("SyncMusic Diagnostics Summary")
        lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append("App version: \(appVersion)")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Current status: \(currentStatus)")
        lines.append("Diagnostics root: \(rootDirectory.path)")
        lines.append("Active log: \(SyncMusicPaths.activeLogFile(rootDirectory: rootDirectory).path)")
        lines.append("")
        lines.append("Config")
        lines.append("- Schedule: \(config.autoSyncSchedule.displayDescription)")
        lines.append("- Prefix: \(config.materializedPrefix)")
        lines.append("- Include system playlists: \(config.includeSystemSmartPlaylists)")
        lines.append("- Allowed source playlists: \(config.allowedSourcePlaylistNames.count)")
        for playlistName in config.allowedSourcePlaylistNames.prefix(8) {
            lines.append("  • \(playlistName)")
        }
        lines.append("- Source exclusions: \(config.sourcePlaylistExclusions.filter(\.isEnabled).count)")
        for rule in config.sourcePlaylistExclusions.filter(\.isEnabled).prefix(8) {
            lines.append("  • \(rule.displayDescription)")
        }
        lines.append("- Provider profile: \(config.providerProfile.displayName)")
        lines.append("- Spotify auth configured: \(config.spotifyAuth?.isConfigured == true)")
        lines.append("- Spotify mappings: \(config.spotifyPlaylistMappings.count)")
        lines.append("- Delete stale managed playlists: \(config.deleteStaleManagedPlaylists)")
        lines.append("- Log level: \(config.logLevel.rawValue)")
        lines.append("- Debug logging: \(config.debugLogging)")
        lines.append("")
        lines.append("State")
        lines.append("- Managed sources tracked: \(state.managedPlaylists.count)")
        lines.append("- Spotify targets tracked: \(state.spotifyPlaylists.count)")

        if let lastRun {
            lines.append("")
            lines.append("Last run")
            lines.append("- Run ID: \(lastRun.report.runID)")
            lines.append("- Trigger: \(lastRun.report.trigger.rawValue)")
            lines.append("- Started: \(lastRun.report.startedAt.formatted(date: .abbreviated, time: .standard))")
            lines.append("- Finished: \(lastRun.report.finishedAt.formatted(date: .abbreviated, time: .standard))")
            lines.append("- Duration: \(lastRun.report.durationMilliseconds) ms")
            lines.append("- Processed playlists: \(lastRun.report.processedPlaylistCount)")
            lines.append("- Rebuilt playlist parts: \(lastRun.report.rebuiltPlaylistPartCount)")
            lines.append("- Written tracks: \(lastRun.report.writtenTrackCount)")
            lines.append("- Playlist changes: +\(lastRun.report.createdPlaylistCount) / -\(lastRun.report.deletedPlaylistCount) / rename \(lastRun.report.renamedPlaylistCount)")
            lines.append("- Failures: \(lastRun.report.failures.count)")

            if !lastRun.report.failures.isEmpty {
                lines.append("- Recent failure details:")
                for failure in lastRun.report.failures.prefix(5) {
                    lines.append("  • [\(failure.category.rawValue)] \(failure.playlistName): \(failure.message)")
                }
            }
        }

        if let crashContext {
            lines.append("")
            lines.append("Unfinished run")
            lines.append("- Run ID: \(crashContext.runID)")
            lines.append("- Trigger: \(crashContext.trigger.rawValue)")
            lines.append("- Started: \(crashContext.startedAt.formatted(date: .abbreviated, time: .standard))")
        }

        if !recentEvents.isEmpty {
            lines.append("")
            lines.append("Recent events")
            for event in recentEvents {
                lines.append("- [\(event.level.rawValue)] \(event.operation): \(event.message)")
            }
        }

        return DiagnosticsSummary(text: lines.joined(separator: "\n"))
    }

    private func shouldLog(level: LogLevel) -> Bool {
        let effectiveLevel: LogLevel = debugLogging ? .debug : minimumLevel
        return level.priority >= effectiveLevel.priority
    }

    private func writeToUnifiedLog(_ event: SyncEvent) {
        let text = "[\(event.operation)] \(event.message)"

        switch event.level {
        case .debug:
            logger.debug("\(text, privacy: .public)")
        case .info:
            logger.info("\(text, privacy: .public)")
        case .warning:
            logger.warning("\(text, privacy: .public)")
        case .error:
            logger.error("\(text, privacy: .public)")
        }
    }

    private func append(_ event: SyncEvent) throws {
        let encoded = try encoder.encode(event)
        let line = encoded + Data([0x0A])
        let activeLog = SyncMusicPaths.activeLogFile(rootDirectory: rootDirectory)
        try rotateIfNeeded(activeLog: activeLog, incomingByteCount: line.count)

        if !FileManager.default.fileExists(atPath: activeLog.path) {
            FileManager.default.createFile(atPath: activeLog.path, contents: Data())
        }

        let fileHandle = try FileHandle(forWritingTo: activeLog)
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: line)
        try fileHandle.close()
    }

    private func rotateIfNeeded(activeLog: URL, incomingByteCount: Int) throws {
        let fileSize = try currentFileSize(for: activeLog)
        guard fileSize + incomingByteCount > maxLogFileSizeBytes else {
            return
        }

        let fileManager = FileManager.default
        let oldestLog = SyncMusicPaths.rotatedLogFile(rootDirectory: rootDirectory, index: maxRotatedLogFiles)
        if fileManager.fileExists(atPath: oldestLog.path) {
            try fileManager.removeItem(at: oldestLog)
        }

        guard maxRotatedLogFiles > 1 else {
            if fileManager.fileExists(atPath: activeLog.path) {
                try fileManager.removeItem(at: activeLog)
            }
            return
        }

        for index in stride(from: maxRotatedLogFiles - 1, through: 1, by: -1) {
            let source = SyncMusicPaths.rotatedLogFile(rootDirectory: rootDirectory, index: index)
            let destination = SyncMusicPaths.rotatedLogFile(rootDirectory: rootDirectory, index: index + 1)
            if fileManager.fileExists(atPath: source.path) {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: source, to: destination)
            }
        }

        if fileManager.fileExists(atPath: activeLog.path) {
            let destination = SyncMusicPaths.rotatedLogFile(rootDirectory: rootDirectory, index: 1)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: activeLog, to: destination)
        }
    }

    private func currentFileSize(for url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    private func logFilesNewestFirst() -> [URL] {
        var urls: [URL] = []
        let active = SyncMusicPaths.activeLogFile(rootDirectory: rootDirectory)
        if FileManager.default.fileExists(atPath: active.path) {
            urls.append(active)
        }

        if maxRotatedLogFiles > 1 {
            for index in 1...maxRotatedLogFiles {
                let rotated = SyncMusicPaths.rotatedLogFile(rootDirectory: rootDirectory, index: index)
                if FileManager.default.fileExists(atPath: rotated.path) {
                    urls.append(rotated)
                }
            }
        }

        return urls
    }
}
