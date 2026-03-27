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
    public var lastSourceFingerprint: String?
    public var lastSyncedAt: Date?
    public var lastError: String?
    public var lastFailureCategory: FailureCategory?
    public var lastRunID: String?

    public init(
        sourcePersistentID: String,
        sourceName: String,
        parts: [ManagedPlaylistPart] = [],
        lastSourceFingerprint: String? = nil,
        lastSyncedAt: Date? = nil,
        lastError: String? = nil,
        lastFailureCategory: FailureCategory? = nil,
        lastRunID: String? = nil
    ) {
        self.sourcePersistentID = sourcePersistentID
        self.sourceName = sourceName
        self.parts = parts
        self.lastSourceFingerprint = lastSourceFingerprint
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
        self.lastFailureCategory = lastFailureCategory
        self.lastRunID = lastRunID
    }

    public var id: String { sourcePersistentID }
}

public struct SyncState: Codable, Equatable, Sendable {
    public var managedPlaylists: [String: ManagedPlaylistState]
    public var lastScheduledAttemptAt: Date?

    public init(
        managedPlaylists: [String: ManagedPlaylistState] = [:],
        lastScheduledAttemptAt: Date? = nil
    ) {
        self.managedPlaylists = managedPlaylists
        self.lastScheduledAttemptAt = lastScheduledAttemptAt
    }
}

public enum AutoSyncScheduleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case interval
    case daily

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .interval:
            return "Interval"
        case .daily:
            return "Daily"
        }
    }
}

public struct DailySyncTime: Codable, Equatable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int = 2, minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    public var normalized: DailySyncTime {
        DailySyncTime(
            hour: min(max(hour, 0), 23),
            minute: min(max(minute, 0), 59)
        )
    }

    public var displayDescription: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date(on: Date(), calendar: .current))
    }

    public func date(on referenceDate: Date, calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: referenceDate)
        let components = DateComponents(
            hour: normalized.hour,
            minute: normalized.minute,
            second: 0
        )

        return calendar.nextDate(
            after: dayStart.addingTimeInterval(-1),
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? dayStart
    }
}

public struct AutoSyncScheduleEvaluation: Equatable, Sendable {
    public let shouldRunNow: Bool
    public let nextCheckAt: Date

    public init(shouldRunNow: Bool, nextCheckAt: Date) {
        self.shouldRunNow = shouldRunNow
        self.nextCheckAt = nextCheckAt
    }
}

public enum AutoSyncSchedule: Equatable, Sendable {
    case interval(minutes: Int)
    case daily(time: DailySyncTime)

    public var kind: AutoSyncScheduleKind {
        switch self {
        case .interval:
            return .interval
        case .daily:
            return .daily
        }
    }

    public var normalized: AutoSyncSchedule {
        switch self {
        case .interval(let minutes):
            return .interval(minutes: max(1, minutes))
        case .daily(let time):
            return .daily(time: time.normalized)
        }
    }

    public var intervalMinutes: Int? {
        switch self {
        case .interval(let minutes):
            return minutes
        case .daily:
            return nil
        }
    }

    public var dailyTime: DailySyncTime? {
        switch self {
        case .interval:
            return nil
        case .daily(let time):
            return time
        }
    }

    public var displayDescription: String {
        switch normalized {
        case .interval(let minutes):
            return "Every \(minutes) min"
        case .daily(let time):
            return "Daily at \(time.displayDescription)"
        }
    }

    public func evaluate(
        now: Date,
        lastScheduledAttemptAt: Date?,
        calendar: Calendar = .current
    ) -> AutoSyncScheduleEvaluation {
        switch normalized {
        case .interval(let minutes):
            return AutoSyncScheduleEvaluation(
                shouldRunNow: false,
                nextCheckAt: now.addingTimeInterval(TimeInterval(minutes * 60))
            )
        case .daily(let time):
            let scheduledToday = time.date(on: now, calendar: calendar)
            let attemptedToday = lastScheduledAttemptAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false

            if attemptedToday == false, now >= scheduledToday {
                return AutoSyncScheduleEvaluation(
                    shouldRunNow: true,
                    nextCheckAt: scheduledToday
                )
            }

            if now < scheduledToday {
                return AutoSyncScheduleEvaluation(
                    shouldRunNow: false,
                    nextCheckAt: scheduledToday
                )
            }

            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
            return AutoSyncScheduleEvaluation(
                shouldRunNow: false,
                nextCheckAt: time.date(on: tomorrow, calendar: calendar)
            )
        }
    }
}

extension AutoSyncSchedule: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case minutes
        case dailyTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(AutoSyncScheduleKind.self, forKey: .kind)

        switch kind {
        case .interval:
            let minutes = try container.decodeIfPresent(Int.self, forKey: .minutes) ?? 30
            self = .interval(minutes: minutes)
        case .daily:
            let time = try container.decodeIfPresent(DailySyncTime.self, forKey: .dailyTime) ?? DailySyncTime()
            self = .daily(time: time)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch normalized {
        case .interval(let minutes):
            try container.encode(minutes, forKey: .minutes)
        case .daily(let time):
            try container.encode(time, forKey: .dailyTime)
        }
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
    public var autoSyncSchedule: AutoSyncSchedule
    public var materializedPrefix: String
    public var includeSystemSmartPlaylists: Bool
    public var sourcePlaylistExclusions: [PlaylistExclusionRule]
    public var allowedSourcePlaylistNames: [String]
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

    public static var defaultAllowedSourcePlaylistNames: [String] {
        ["Recently Added"]
    }

    public init(
        autoSyncSchedule: AutoSyncSchedule = .interval(minutes: 30),
        materializedPrefix: String = "Sync Mirror",
        includeSystemSmartPlaylists: Bool = false,
        sourcePlaylistExclusions: [PlaylistExclusionRule] = AppConfig.defaultSourcePlaylistExclusions,
        allowedSourcePlaylistNames: [String] = AppConfig.defaultAllowedSourcePlaylistNames,
        providerProfile: ProviderProfile = .qobuzViaSoundiiz,
        deleteStaleManagedPlaylists: Bool = false,
        logLevel: LogLevel = .info,
        debugLogging: Bool = false,
        maxLogFileSizeBytes: Int = 2_000_000,
        maxRotatedLogFiles: Int = 5
    ) {
        self.autoSyncSchedule = autoSyncSchedule.normalized
        self.materializedPrefix = materializedPrefix
        self.includeSystemSmartPlaylists = includeSystemSmartPlaylists
        self.sourcePlaylistExclusions = sourcePlaylistExclusions
        self.allowedSourcePlaylistNames = AppConfig.normalizedAllowedSourcePlaylistNames(from: allowedSourcePlaylistNames)
        self.providerProfile = providerProfile
        self.deleteStaleManagedPlaylists = deleteStaleManagedPlaylists
        self.logLevel = logLevel
        self.debugLogging = debugLogging
        self.maxLogFileSizeBytes = maxLogFileSizeBytes
        self.maxRotatedLogFiles = maxRotatedLogFiles
    }

    public var syncIntervalMinutes: Int {
        get { autoSyncSchedule.intervalMinutes ?? 30 }
        set { autoSyncSchedule = .interval(minutes: newValue) }
    }

    public var dailySyncTime: DailySyncTime {
        get { autoSyncSchedule.dailyTime ?? DailySyncTime() }
        set { autoSyncSchedule = .daily(time: newValue) }
    }

    private enum CodingKeys: String, CodingKey {
        case autoSyncSchedule
        case syncIntervalMinutes
        case materializedPrefix
        case includeSystemSmartPlaylists
        case sourcePlaylistExclusions
        case allowedSourcePlaylistNames
        case providerProfile
        case deleteStaleManagedPlaylists
        case logLevel
        case debugLogging
        case maxLogFileSizeBytes
        case maxRotatedLogFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let autoSyncSchedule = try container.decodeIfPresent(AutoSyncSchedule.self, forKey: .autoSyncSchedule) {
            self.autoSyncSchedule = autoSyncSchedule.normalized
        } else {
            let legacyInterval = try container.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes) ?? 30
            self.autoSyncSchedule = .interval(minutes: max(1, legacyInterval))
        }
        materializedPrefix = try container.decodeIfPresent(String.self, forKey: .materializedPrefix) ?? "Sync Mirror"
        includeSystemSmartPlaylists = try container.decodeIfPresent(Bool.self, forKey: .includeSystemSmartPlaylists) ?? false
        sourcePlaylistExclusions = try container.decodeIfPresent([PlaylistExclusionRule].self, forKey: .sourcePlaylistExclusions)
            ?? AppConfig.defaultSourcePlaylistExclusions
        allowedSourcePlaylistNames = AppConfig.normalizedAllowedSourcePlaylistNames(
            from: try container.decodeIfPresent([String].self, forKey: .allowedSourcePlaylistNames)
                ?? AppConfig.defaultAllowedSourcePlaylistNames
        )
        providerProfile = try container.decodeIfPresent(ProviderProfile.self, forKey: .providerProfile) ?? .qobuzViaSoundiiz
        deleteStaleManagedPlaylists = try container.decodeIfPresent(Bool.self, forKey: .deleteStaleManagedPlaylists) ?? false
        logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        debugLogging = try container.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? false
        maxLogFileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .maxLogFileSizeBytes) ?? 2_000_000
        maxRotatedLogFiles = try container.decodeIfPresent(Int.self, forKey: .maxRotatedLogFiles) ?? 5
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autoSyncSchedule.normalized, forKey: .autoSyncSchedule)
        try container.encode(materializedPrefix, forKey: .materializedPrefix)
        try container.encode(includeSystemSmartPlaylists, forKey: .includeSystemSmartPlaylists)
        try container.encode(sourcePlaylistExclusions, forKey: .sourcePlaylistExclusions)
        try container.encode(allowedSourcePlaylistNames, forKey: .allowedSourcePlaylistNames)
        try container.encode(providerProfile, forKey: .providerProfile)
        try container.encode(deleteStaleManagedPlaylists, forKey: .deleteStaleManagedPlaylists)
        try container.encode(logLevel, forKey: .logLevel)
        try container.encode(debugLogging, forKey: .debugLogging)
        try container.encode(maxLogFileSizeBytes, forKey: .maxLogFileSizeBytes)
        try container.encode(maxRotatedLogFiles, forKey: .maxRotatedLogFiles)
    }

    private static func normalizedAllowedSourcePlaylistNames(from names: [String]) -> [String] {
        var normalizedNames: [String] = []
        var seenKeys: Set<String> = []

        for name in names {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedName.isEmpty == false else {
                continue
            }

            let foldedName = trimmedName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seenKeys.insert(foldedName).inserted else {
                continue
            }

            normalizedNames.append(trimmedName)
        }

        return normalizedNames
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
    public let writtenTrackCount: Int
    public let rebuiltPlaylistPartCount: Int
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
        writtenTrackCount: Int,
        rebuiltPlaylistPartCount: Int,
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
        self.writtenTrackCount = writtenTrackCount
        self.rebuiltPlaylistPartCount = rebuiltPlaylistPartCount
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

    private enum CodingKeys: String, CodingKey {
        case runID
        case trigger
        case startedAt
        case finishedAt
        case processedPlaylistCount
        case writtenTrackCount
        case rebuiltPlaylistPartCount
        case addedTrackCount
        case removedTrackCount
        case createdPlaylistCount
        case deletedPlaylistCount
        case renamedPlaylistCount
        case failures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        trigger = try container.decode(SyncTrigger.self, forKey: .trigger)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        processedPlaylistCount = try container.decode(Int.self, forKey: .processedPlaylistCount)
        writtenTrackCount = try container.decodeIfPresent(Int.self, forKey: .writtenTrackCount) ?? 0
        rebuiltPlaylistPartCount = try container.decodeIfPresent(Int.self, forKey: .rebuiltPlaylistPartCount) ?? 0
        addedTrackCount = try container.decodeIfPresent(Int.self, forKey: .addedTrackCount) ?? 0
        removedTrackCount = try container.decodeIfPresent(Int.self, forKey: .removedTrackCount) ?? 0
        createdPlaylistCount = try container.decode(Int.self, forKey: .createdPlaylistCount)
        deletedPlaylistCount = try container.decode(Int.self, forKey: .deletedPlaylistCount)
        renamedPlaylistCount = try container.decode(Int.self, forKey: .renamedPlaylistCount)
        failures = try container.decode([SyncFailure].self, forKey: .failures)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
        try container.encode(processedPlaylistCount, forKey: .processedPlaylistCount)
        try container.encode(writtenTrackCount, forKey: .writtenTrackCount)
        try container.encode(rebuiltPlaylistPartCount, forKey: .rebuiltPlaylistPartCount)
        try container.encode(addedTrackCount, forKey: .addedTrackCount)
        try container.encode(removedTrackCount, forKey: .removedTrackCount)
        try container.encode(createdPlaylistCount, forKey: .createdPlaylistCount)
        try container.encode(deletedPlaylistCount, forKey: .deletedPlaylistCount)
        try container.encode(renamedPlaylistCount, forKey: .renamedPlaylistCount)
        try container.encode(failures, forKey: .failures)
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
    public let writtenTrackCount: Int?
    public let rebuiltPlaylistPartCount: Int?
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
        writtenTrackCount: Int? = nil,
        rebuiltPlaylistPartCount: Int? = nil,
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
        self.writtenTrackCount = writtenTrackCount
        self.rebuiltPlaylistPartCount = rebuiltPlaylistPartCount
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
