import Foundation

public struct PlaylistSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let persistentID: String
    public let specialKind: String
    public let isSmart: Bool
    public let trackPersistentIDs: [String]

    public init(
        name: String,
        persistentID: String,
        specialKind: String = "",
        isSmart: Bool = false,
        trackPersistentIDs: [String]
    ) {
        self.name = name
        self.persistentID = persistentID
        self.specialKind = specialKind
        self.isSmart = isSmart
        self.trackPersistentIDs = trackPersistentIDs
    }

    public var id: String { persistentID }

    public var isSystemSmartPlaylist: Bool {
        guard isSmart else { return false }
        let trimmed = specialKind.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("none") != .orderedSame
    }
}

public struct ManagedPlaylistPart: Codable, Equatable, Identifiable, Sendable {
    public let index: Int
    public var targetPersistentID: String
    public var targetName: String

    public init(index: Int, targetPersistentID: String, targetName: String) {
        self.index = index
        self.targetPersistentID = targetPersistentID
        self.targetName = targetName
    }

    public var id: String { "\(index)-\(targetPersistentID)" }
}

public struct ManagedPlaylistState: Codable, Equatable, Identifiable, Sendable {
    public var sourcePersistentID: String
    public var sourceName: String
    public var parts: [ManagedPlaylistPart]
    public var lastSyncedAt: Date?
    public var lastError: String?
    public var lastFailureCategory: FailureCategory?
    public var lastRunID: String?

    public init(
        sourcePersistentID: String,
        sourceName: String,
        parts: [ManagedPlaylistPart] = [],
        lastSyncedAt: Date? = nil,
        lastError: String? = nil,
        lastFailureCategory: FailureCategory? = nil,
        lastRunID: String? = nil
    ) {
        self.sourcePersistentID = sourcePersistentID
        self.sourceName = sourceName
        self.parts = parts
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
        self.lastFailureCategory = lastFailureCategory
        self.lastRunID = lastRunID
    }

    public var id: String { sourcePersistentID }
}

public struct SyncState: Codable, Equatable, Sendable {
    public var managedPlaylists: [String: ManagedPlaylistState]

    public init(managedPlaylists: [String: ManagedPlaylistState] = [:]) {
        self.managedPlaylists = managedPlaylists
    }
}

public enum SyncTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case startup
    case manual
    case scheduled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .startup:
            return "Startup"
        case .manual:
            return "Manual"
        case .scheduled:
            return "Scheduled"
        }
    }
}

public enum LogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case debug
    case info
    case warning
    case error

    public var id: String { rawValue }

    public var priority: Int {
        switch self {
        case .debug:
            return 0
        case .info:
            return 1
        case .warning:
            return 2
        case .error:
            return 3
        }
    }
}

public enum FailureCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case automationPermissionDenied
    case musicUnavailable
    case playlistLookupFailed
    case appleScriptExecutionFailed
    case stateStoreFailure
    case launchAtLoginFailure
    case unknown

    public var id: String { rawValue }

    public static func classify(message: String, operation: String? = nil) -> FailureCategory {
        let haystack = "\(operation ?? "") \(message)".lowercased()

        if haystack.contains("-1743")
            || haystack.contains("not authorized")
            || haystack.contains("not permitted")
            || haystack.contains("apple events")
            || haystack.contains("permission") {
            return .automationPermissionDenied
        }

        if haystack.contains("application isn’t running")
            || haystack.contains("application isn't running")
            || haystack.contains("music got an error")
            || haystack.contains("can’t communicate")
            || haystack.contains("can't communicate") {
            return .musicUnavailable
        }

        if haystack.contains("playlist not found")
            || haystack.contains("did not return playlist")
            || haystack.contains("can’t get")
            || haystack.contains("can't get") {
            return .playlistLookupFailed
        }

        if haystack.contains("state")
            || haystack.contains("config")
            || haystack.contains("decode")
            || haystack.contains("encode")
            || haystack.contains("json")
            || haystack.contains("write")
            || haystack.contains("read") {
            return .stateStoreFailure
        }

        if haystack.contains("launch at login")
            || haystack.contains("login item")
            || haystack.contains("smappservice") {
            return .launchAtLoginFailure
        }

        if haystack.contains("timed out")
            || haystack.contains("timeout") {
            return .appleScriptExecutionFailed
        }

        if haystack.contains("osascript") || haystack.contains("applescript") {
            return .appleScriptExecutionFailed
        }

        return .unknown
    }
}

public enum ProviderProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case generic
    case qobuzViaSoundiiz

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .generic:
            return "Generic"
        case .qobuzViaSoundiiz:
            return "Qobuz via Soundiiz"
        }
    }

    public var trackLimit: Int? {
        switch self {
        case .generic:
            return nil
        case .qobuzViaSoundiiz:
            return 1_900
        }
    }
}

public enum PlaylistExclusionMatchType: String, Codable, CaseIterable, Identifiable, Sendable {
    case exactName
    case specialKind

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .exactName:
            return "Name"
        case .specialKind:
            return "Special Kind"
        }
    }
}

public struct PlaylistExclusionRule: Codable, Equatable, Identifiable, Sendable {
    public var matchType: PlaylistExclusionMatchType
    public var value: String

    public init(
        matchType: PlaylistExclusionMatchType = .exactName,
        value: String
    ) {
        self.matchType = matchType
        self.value = value
    }

    public var id: String {
        "\(matchType.rawValue):\(normalizedValue.lowercased())"
    }

    public var normalizedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEnabled: Bool {
        !normalizedValue.isEmpty
    }

    public var displayDescription: String {
        "\(matchType.displayName): \(normalizedValue)"
    }

    public func matches(snapshot: PlaylistSnapshot) -> Bool {
        guard isEnabled else {
            return false
        }

        switch matchType {
        case .exactName:
            return snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedValue) == .orderedSame
        case .specialKind:
            return snapshot.specialKind.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedValue) == .orderedSame
        }
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var syncIntervalMinutes: Int
    public var materializedPrefix: String
    public var includeSystemSmartPlaylists: Bool
    public var sourcePlaylistExclusions: [PlaylistExclusionRule]
    public var providerProfile: ProviderProfile
    public var deleteStaleManagedPlaylists: Bool
    public var logLevel: LogLevel
    public var debugLogging: Bool
    public var maxLogFileSizeBytes: Int
    public var maxRotatedLogFiles: Int

    public static var defaultSourcePlaylistExclusions: [PlaylistExclusionRule] {
        [
            PlaylistExclusionRule(matchType: .specialKind, value: "Music"),
            PlaylistExclusionRule(matchType: .exactName, value: "Favorite Songs"),
        ]
    }

    public init(
        syncIntervalMinutes: Int = 30,
        materializedPrefix: String = "Sync Mirror",
        includeSystemSmartPlaylists: Bool = false,
        sourcePlaylistExclusions: [PlaylistExclusionRule] = AppConfig.defaultSourcePlaylistExclusions,
        providerProfile: ProviderProfile = .qobuzViaSoundiiz,
        deleteStaleManagedPlaylists: Bool = false,
        logLevel: LogLevel = .info,
        debugLogging: Bool = false,
        maxLogFileSizeBytes: Int = 2_000_000,
        maxRotatedLogFiles: Int = 5
    ) {
        self.syncIntervalMinutes = syncIntervalMinutes
        self.materializedPrefix = materializedPrefix
        self.includeSystemSmartPlaylists = includeSystemSmartPlaylists
        self.sourcePlaylistExclusions = sourcePlaylistExclusions
        self.providerProfile = providerProfile
        self.deleteStaleManagedPlaylists = deleteStaleManagedPlaylists
        self.logLevel = logLevel
        self.debugLogging = debugLogging
        self.maxLogFileSizeBytes = maxLogFileSizeBytes
        self.maxRotatedLogFiles = maxRotatedLogFiles
    }

    private enum CodingKeys: String, CodingKey {
        case syncIntervalMinutes
        case materializedPrefix
        case includeSystemSmartPlaylists
        case sourcePlaylistExclusions
        case providerProfile
        case deleteStaleManagedPlaylists
        case logLevel
        case debugLogging
        case maxLogFileSizeBytes
        case maxRotatedLogFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        syncIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes) ?? 30
        materializedPrefix = try container.decodeIfPresent(String.self, forKey: .materializedPrefix) ?? "Sync Mirror"
        includeSystemSmartPlaylists = try container.decodeIfPresent(Bool.self, forKey: .includeSystemSmartPlaylists) ?? false
        sourcePlaylistExclusions = try container.decodeIfPresent([PlaylistExclusionRule].self, forKey: .sourcePlaylistExclusions)
            ?? AppConfig.defaultSourcePlaylistExclusions
        providerProfile = try container.decodeIfPresent(ProviderProfile.self, forKey: .providerProfile) ?? .qobuzViaSoundiiz
        deleteStaleManagedPlaylists = try container.decodeIfPresent(Bool.self, forKey: .deleteStaleManagedPlaylists) ?? false
        logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        debugLogging = try container.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? false
        maxLogFileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .maxLogFileSizeBytes) ?? 2_000_000
        maxRotatedLogFiles = try container.decodeIfPresent(Int.self, forKey: .maxRotatedLogFiles) ?? 5
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(syncIntervalMinutes, forKey: .syncIntervalMinutes)
        try container.encode(materializedPrefix, forKey: .materializedPrefix)
        try container.encode(includeSystemSmartPlaylists, forKey: .includeSystemSmartPlaylists)
        try container.encode(sourcePlaylistExclusions, forKey: .sourcePlaylistExclusions)
        try container.encode(providerProfile, forKey: .providerProfile)
        try container.encode(deleteStaleManagedPlaylists, forKey: .deleteStaleManagedPlaylists)
        try container.encode(logLevel, forKey: .logLevel)
        try container.encode(debugLogging, forKey: .debugLogging)
        try container.encode(maxLogFileSizeBytes, forKey: .maxLogFileSizeBytes)
        try container.encode(maxRotatedLogFiles, forKey: .maxRotatedLogFiles)
    }
}

public struct PlaylistDiff: Equatable, Sendable {
    public let toAdd: [String]
    public let toRemove: [String]

    public init(toAdd: [String], toRemove: [String]) {
        self.toAdd = toAdd
        self.toRemove = toRemove
    }

    public var isEmpty: Bool {
        toAdd.isEmpty && toRemove.isEmpty
    }
}

public struct SyncFailure: Codable, Equatable, Identifiable, Sendable {
    public let playlistName: String
    public let message: String
    public let category: FailureCategory
    public let operation: String
    public let sourcePlaylistPersistentID: String?
    public let targetPlaylistPersistentID: String?
    public let targetPlaylistName: String?
    public let underlyingMessage: String?

    public init(
        playlistName: String,
        message: String,
        category: FailureCategory,
        operation: String,
        sourcePlaylistPersistentID: String? = nil,
        targetPlaylistPersistentID: String? = nil,
        targetPlaylistName: String? = nil,
        underlyingMessage: String? = nil
    ) {
        self.playlistName = playlistName
        self.message = message
        self.category = category
        self.operation = operation
        self.sourcePlaylistPersistentID = sourcePlaylistPersistentID
        self.targetPlaylistPersistentID = targetPlaylistPersistentID
        self.targetPlaylistName = targetPlaylistName
        self.underlyingMessage = underlyingMessage
    }

    public var id: String { "\(playlistName):\(operation):\(message)" }
}

public struct SyncRunReport: Codable, Equatable, Sendable {
    public let runID: String
    public let trigger: SyncTrigger
    public let startedAt: Date
    public let finishedAt: Date
    public let processedPlaylistCount: Int
    public let addedTrackCount: Int
    public let removedTrackCount: Int
    public let createdPlaylistCount: Int
    public let deletedPlaylistCount: Int
    public let renamedPlaylistCount: Int
    public let failures: [SyncFailure]

    public init(
        runID: String,
        trigger: SyncTrigger,
        startedAt: Date,
        finishedAt: Date,
        processedPlaylistCount: Int,
        addedTrackCount: Int,
        removedTrackCount: Int,
        createdPlaylistCount: Int,
        deletedPlaylistCount: Int,
        renamedPlaylistCount: Int,
        failures: [SyncFailure]
    ) {
        self.runID = runID
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.processedPlaylistCount = processedPlaylistCount
        self.addedTrackCount = addedTrackCount
        self.removedTrackCount = removedTrackCount
        self.createdPlaylistCount = createdPlaylistCount
        self.deletedPlaylistCount = deletedPlaylistCount
        self.renamedPlaylistCount = renamedPlaylistCount
        self.failures = failures
    }

    public var isSuccess: Bool {
        failures.isEmpty
    }

    public var durationMilliseconds: Int {
        Int(finishedAt.timeIntervalSince(startedAt) * 1_000)
    }
}

public struct RunContext: Codable, Equatable, Sendable {
    public let runID: String
    public let trigger: SyncTrigger
    public let startedAt: Date
    public let appVersion: String
    public let osVersion: String

    public init(
        runID: String,
        trigger: SyncTrigger,
        startedAt: Date,
        appVersion: String,
        osVersion: String
    ) {
        self.runID = runID
        self.trigger = trigger
        self.startedAt = startedAt
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}

public enum SyncProgressStage: String, Codable, Sendable {
    case starting
    case discoveringPlaylists
    case reconcilingPlaylist
    case deletingStalePlaylists
    case savingState
    case completed
    case failed
}

public struct SyncProgressUpdate: Sendable {
    public let runID: String
    public let stage: SyncProgressStage
    public let message: String
    public let lastCompletedStep: String?
    public let currentPlaylistName: String?
    public let processedPlaylistCount: Int?
    public let updatedAt: Date

    public var sourcePlaylistName: String? { currentPlaylistName }

    public init(
        runID: String,
        stage: SyncProgressStage,
        message: String,
        lastCompletedStep: String? = nil,
        currentPlaylistName: String? = nil,
        processedPlaylistCount: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.runID = runID
        self.stage = stage
        self.message = message
        self.lastCompletedStep = lastCompletedStep
        self.currentPlaylistName = currentPlaylistName
        self.processedPlaylistCount = processedPlaylistCount
        self.updatedAt = updatedAt
    }
}

public struct SyncEvent: Codable, Identifiable, Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let subsystem: String
    public let operation: String
    public let runID: String?
    public let trigger: SyncTrigger?
    public let message: String
    public let sourcePlaylistName: String?
    public let sourcePlaylistPersistentID: String?
    public let targetPlaylistName: String?
    public let targetPlaylistPersistentID: String?
    public let partIndex: Int?
    public let totalParts: Int?
    public let trackCount: Int?
    public let addedTrackCount: Int?
    public let removedTrackCount: Int?
    public let durationMilliseconds: Int?
    public let errorCategory: FailureCategory?
    public let errorMessage: String?
    public let stdoutPreview: String?
    public let stderrPreview: String?
    public let metadata: [String: String]?

    public init(
        timestamp: Date = Date(),
        level: LogLevel,
        subsystem: String,
        operation: String,
        runID: String? = nil,
        trigger: SyncTrigger? = nil,
        message: String,
        sourcePlaylistName: String? = nil,
        sourcePlaylistPersistentID: String? = nil,
        targetPlaylistName: String? = nil,
        targetPlaylistPersistentID: String? = nil,
        partIndex: Int? = nil,
        totalParts: Int? = nil,
        trackCount: Int? = nil,
        addedTrackCount: Int? = nil,
        removedTrackCount: Int? = nil,
        durationMilliseconds: Int? = nil,
        errorCategory: FailureCategory? = nil,
        errorMessage: String? = nil,
        stdoutPreview: String? = nil,
        stderrPreview: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.operation = operation
        self.runID = runID
        self.trigger = trigger
        self.message = message
        self.sourcePlaylistName = sourcePlaylistName
        self.sourcePlaylistPersistentID = sourcePlaylistPersistentID
        self.targetPlaylistName = targetPlaylistName
        self.targetPlaylistPersistentID = targetPlaylistPersistentID
        self.partIndex = partIndex
        self.totalParts = totalParts
        self.trackCount = trackCount
        self.addedTrackCount = addedTrackCount
        self.removedTrackCount = removedTrackCount
        self.durationMilliseconds = durationMilliseconds
        self.errorCategory = errorCategory
        self.errorMessage = errorMessage
        self.stdoutPreview = stdoutPreview
        self.stderrPreview = stderrPreview
        self.metadata = metadata
    }

    public var id: String {
        let runComponent = runID ?? "no-run"
        return "\(timestamp.timeIntervalSince1970)-\(operation)-\(runComponent)"
    }
}

public struct LastRunSnapshot: Codable, Equatable, Sendable {
    public let report: SyncRunReport
    public let config: AppConfig
    public let generatedAt: Date

    public init(report: SyncRunReport, config: AppConfig, generatedAt: Date = Date()) {
        self.report = report
        self.config = config
        self.generatedAt = generatedAt
    }
}

public struct DiagnosticsSummary: Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum RuntimeEnvironment {
    public static func appVersion() -> String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildVersion) {
        case let (short?, build?) where short != build:
            return "\(short) (\(build))"
        case let (short?, _):
            return short
        case let (_, build?):
            return build
        default:
            return "development"
        }
    }
}
