import Foundation
import SyncMusicCore

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws -> Bool {
    guard condition() else {
        throw CheckFailure(message: message)
    }
    return true
}

private let unitSeparator = "\u{001F}"
private let recordSeparator = "\u{001E}"

private enum TrackIDProbeStrategy: String, CaseIterable {
    case currentLoop = "current"
    case bulkProperty = "bulk"

    var label: String {
        switch self {
        case .currentLoop:
            return "current-loop"
        case .bulkProperty:
            return "bulk-property"
        }
    }
}

private enum TrackIDStrategySelection: String {
    case current
    case bulk
    case both

    var strategies: [TrackIDProbeStrategy] {
        switch self {
        case .current:
            return [.currentLoop]
        case .bulk:
            return [.bulkProperty]
        case .both:
            return TrackIDProbeStrategy.allCases
        }
    }
}

private struct DiscoveryDebugOptions {
    var topPlaylistCount = 5
    var playlistTimeoutSeconds: TimeInterval = 60
    var fullProbeTimeoutSeconds: TimeInterval = 300
    var skipFullProbe = false
    var strategySelection: TrackIDStrategySelection = .both
    var includedOnly = false
    var playlistPersistentID: String?
    var playlistName: String?
}

private enum SyncMusicChecksCommand {
    case checks
    case debugDiscovery(DiscoveryDebugOptions)
    case runSyncOnce(SyncTrigger)
    case help
}

private struct DiscoveryPlaylistMetadata {
    let persistentID: String
    let name: String
    let specialKind: String
    let isSmart: Bool

    var isSystemSmartPlaylist: Bool {
        PlaylistSnapshot(
            name: name,
            persistentID: persistentID,
            specialKind: specialKind,
            isSmart: isSmart,
            trackPersistentIDs: []
        ).isSystemSmartPlaylist
    }

    var specialKindLabel: String {
        let trimmed = specialKind.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "none" : trimmed
    }
}

private struct DiscoveryPlaylistTrackProfile {
    let metadata: DiscoveryPlaylistMetadata
    let trackCount: Int
    let includedByConfig: Bool
}

private enum TrackIDProbeStatus {
    case success(trackIDCount: Int, stdoutBytes: Int, durationMilliseconds: Int)
    case timeout(message: String, durationMilliseconds: Int)
    case failure(message: String, durationMilliseconds: Int)
}

private struct TrackIDProbeOutcome {
    let strategy: TrackIDProbeStrategy
    let profile: DiscoveryPlaylistTrackProfile
    let status: TrackIDProbeStatus
}

private struct PlaylistStrategyComparison {
    let profile: DiscoveryPlaylistTrackProfile
    let outcomes: [TrackIDProbeStrategy: TrackIDProbeOutcome]
}

private struct TrackIDProbeSummary {
    let strategy: TrackIDProbeStrategy
    let successCount: Int
    let timeoutCount: Int
    let failureCount: Int
    let stdoutBytes: Int
}

private enum FullDiscoveryStatus {
    case success
    case timeout
    case failure
}

private struct FullDiscoveryOutcome {
    let label: String
    let durationMilliseconds: Int
    let playlistCount: Int?
    let trackCount: Int?
    let stdoutBytes: Int?
    let message: String
    let status: FullDiscoveryStatus
}

private func parseCommand() throws -> SyncMusicChecksCommand {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let first = arguments.first else {
        return .checks
    }

    switch first {
    case "--help", "help":
        return .help
    case "run-sync-once":
        var trigger: SyncTrigger = .manual
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--trigger":
                index += 1
                guard index < arguments.count, let value = SyncTrigger(rawValue: arguments[index]) else {
                    throw CheckFailure(message: "Expected one of: startup, manual, scheduled after --trigger.")
                }
                trigger = value
            case "--help":
                return .help
            default:
                throw CheckFailure(message: "Unknown argument for run-sync-once: \(argument)")
            }
            index += 1
        }
        return .runSyncOnce(trigger)
    case "debug-discovery":
        var options = DiscoveryDebugOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--top":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw CheckFailure(message: "Expected a positive integer after --top.")
                }
                options.topPlaylistCount = value
            case "--timeout":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value > 0 else {
                    throw CheckFailure(message: "Expected a positive number of seconds after --timeout.")
                }
                options.playlistTimeoutSeconds = value
            case "--full-timeout":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value > 0 else {
                    throw CheckFailure(message: "Expected a positive number of seconds after --full-timeout.")
                }
                options.fullProbeTimeoutSeconds = value
            case "--strategy":
                index += 1
                guard index < arguments.count, let value = TrackIDStrategySelection(rawValue: arguments[index]) else {
                    throw CheckFailure(message: "Expected one of: current, bulk, both after --strategy.")
                }
                options.strategySelection = value
            case "--included-only":
                options.includedOnly = true
            case "--playlist-id":
                index += 1
                guard index < arguments.count, arguments[index].isEmpty == false else {
                    throw CheckFailure(message: "Expected a playlist persistent ID after --playlist-id.")
                }
                options.playlistPersistentID = arguments[index]
            case "--playlist-name":
                index += 1
                guard index < arguments.count, arguments[index].isEmpty == false else {
                    throw CheckFailure(message: "Expected a playlist name after --playlist-name.")
                }
                options.playlistName = arguments[index]
            case "--skip-full-probe":
                options.skipFullProbe = true
            case "--help":
                return .help
            default:
                throw CheckFailure(message: "Unknown argument for debug-discovery: \(argument)")
            }
            index += 1
        }
        if options.playlistPersistentID != nil, options.playlistName != nil {
            throw CheckFailure(message: "Use only one of --playlist-id or --playlist-name.")
        }
        return .debugDiscovery(options)
    default:
        throw CheckFailure(message: "Unknown command: \(first)")
    }
}

private func printUsage() {
    print(
        """
        Usage:
          SyncMusicChecks
          SyncMusicChecks run-sync-once [--trigger startup|manual|scheduled]
          SyncMusicChecks debug-discovery [--top N] [--timeout seconds] [--full-timeout seconds] [--strategy current|bulk|both] [--included-only] [--playlist-id ID | --playlist-name NAME] [--skip-full-probe]

        Commands:
          (no command)        Run the fast verification checks.
          run-sync-once       Run one full sync against the current local state store.
          debug-discovery     Profile listSmartPlaylists discovery phases against the local Music library.

        Options:
          --top N             Probe the top N smart playlists by track count. Default: 5
          --timeout seconds   Per-playlist track-ID probe timeout. Default: 60
          --full-timeout sec  Timeout for the full current listSmartPlaylists call. Default: 300
          --trigger kind      Trigger label for run-sync-once. Default: manual
          --strategy mode     Compare track-ID extraction with current, bulk, or both. Default: both
          --included-only     Only probe playlists that are included by the current config.
          --playlist-id ID    Probe a specific smart playlist by persistent ID.
          --playlist-name NM  Probe a specific smart playlist by exact name.
          --skip-full-probe   Skip all full-discovery probes and only run phase/playlist probes.
        """
    )
}

private func loadCurrentConfig() -> AppConfig {
    let store = StateStore()
    return (try? store.loadConfig()) ?? AppConfig()
}

private func indent(_ text: String, spaces: Int) -> String {
    let prefix = String(repeating: " ", count: spaces)
    return text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { prefix + $0 }
        .joined(separator: "\n")
}

private func metadataProbeScript() -> String {
    """
    use AppleScript version "2.4"
    use scripting additions

    on joinList(inputList, delimiter)
        set oldDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to delimiter
        set joinedText to inputList as text
        set AppleScript's text item delimiters to oldDelimiters
        return joinedText
    end joinList

    on run argv
        set unitSep to character id 31
        set recordSep to character id 30
        set rows to {}

        tell application "Music"
            repeat with candidatePlaylist in every user playlist
                try
                    set playlistID to persistent ID of candidatePlaylist as text
                    set playlistName to name of candidatePlaylist as text
                    set specialKind to ""
                    try
                        set specialKind to special kind of candidatePlaylist as text
                    end try
                    set isSmartValue to "false"
                    try
                        if smart of candidatePlaylist is true then
                            set isSmartValue to "true"
                        end if
                    end try
                    set end of rows to playlistID & unitSep & playlistName & unitSep & specialKind & unitSep & isSmartValue
                end try
            end repeat
        end tell

        return my joinList(rows, recordSep)
    end run
    """
}

private func smartTrackCountProbeScript() -> String {
    """
    use AppleScript version "2.4"
    use scripting additions

    on joinList(inputList, delimiter)
        set oldDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to delimiter
        set joinedText to inputList as text
        set AppleScript's text item delimiters to oldDelimiters
        return joinedText
    end joinList

    on run argv
        set unitSep to character id 31
        set recordSep to character id 30
        set rows to {}

        tell application "Music"
            repeat with candidatePlaylist in every user playlist
                try
                    if smart of candidatePlaylist is true then
                        set playlistID to persistent ID of candidatePlaylist as text
                        set trackCountValue to count of every track of candidatePlaylist
                        set end of rows to playlistID & unitSep & (trackCountValue as text)
                    end if
                end try
            end repeat
        end tell

        return my joinList(rows, recordSep)
    end run
    """
}

private func trackIDCollectionScript(for strategy: TrackIDProbeStrategy, playlistReference: String) -> String {
    switch strategy {
    case .currentLoop:
        return """
        set trackIDs to {}
        tell application "Music"
            repeat with targetTrack in every track of \(playlistReference)
                try
                    set end of trackIDs to (persistent ID of targetTrack as text)
                end try
            end repeat
        end tell
        """
    case .bulkProperty:
        return """
        tell application "Music"
            set trackIDs to persistent ID of every track of \(playlistReference)
        end tell
        """
    }
}

private func playlistTrackIDsProbeScript(strategy: TrackIDProbeStrategy) -> String {
    let trackIDCollection = indent(
        trackIDCollectionScript(for: strategy, playlistReference: "targetPlaylist"),
        spaces: 8
    )
    return """
    use AppleScript version "2.4"
    use scripting additions

    on joinList(inputList, delimiter)
        set oldDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to delimiter
        set joinedText to inputList as text
        set AppleScript's text item delimiters to oldDelimiters
        return joinedText
    end joinList

    on playlistByPersistentID(targetID)
        tell application "Music"
            repeat with candidatePlaylist in every user playlist
                try
                    if (persistent ID of candidatePlaylist as text) is targetID then
                        return candidatePlaylist
                    end if
                end try
            end repeat
        end tell
        error "Playlist not found: " & targetID
    end playlistByPersistentID

    on run argv
        set targetID to item 1 of argv
        set targetPlaylist to my playlistByPersistentID(targetID)
""" + "\n" + trackIDCollection + "\n" + """
        return my joinList(trackIDs, ",")
    end run
    """
}

private func smartPlaylistsFullProbeScript(
    strategy: TrackIDProbeStrategy,
    includeSystemPlaylists: Bool
) -> String {
    let trackIDCollection = indent(
        trackIDCollectionScript(for: strategy, playlistReference: "targetPlaylist"),
        spaces: 8
    )
    let inclusionCheck = includeSystemPlaylists
        ? "true"
        : "my shouldIncludePlaylist(specialKind)"

    return """
    use AppleScript version "2.4"
    use scripting additions

    on joinList(inputList, delimiter)
        set oldDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to delimiter
        set joinedText to inputList as text
        set AppleScript's text item delimiters to oldDelimiters
        return joinedText
    end joinList

    on specialKindText(targetPlaylist)
        set specialKind to ""
        tell application "Music"
            try
                set specialKind to special kind of targetPlaylist as text
            end try
        end tell
        return specialKind
    end specialKindText

    on shouldIncludePlaylist(specialKind)
        if specialKind is "" then
            return true
        end if
        if specialKind is "none" then
            return true
        end if
        return false
    end shouldIncludePlaylist

    on playlistSnapshotText(targetPlaylist, specialKind, unitSep)
""" + "\n" + trackIDCollection + "\n" + """
        tell application "Music"
            return (persistent ID of targetPlaylist as text) & unitSep & (name of targetPlaylist as text) & unitSep & specialKind & unitSep & my joinList(trackIDs, ",")
        end tell
    end playlistSnapshotText

    on run argv
        set unitSep to character id 31
        set recordSep to character id 30
        set playlistRows to {}

        tell application "Music"
            repeat with candidatePlaylist in every user playlist
                try
                    if smart of candidatePlaylist is true then
                        set specialKind to my specialKindText(candidatePlaylist)
                        if \(inclusionCheck) then
                            set end of playlistRows to my playlistSnapshotText(candidatePlaylist, specialKind, unitSep)
                        end if
                    end if
                end try
            end repeat
        end tell

        return my joinList(playlistRows, recordSep)
    end run
    """
}

private func parseMetadataRows(_ output: String) -> [DiscoveryPlaylistMetadata] {
    guard output.isEmpty == false else {
        return []
    }

    return output
        .split(separator: Character(recordSeparator), omittingEmptySubsequences: true)
        .compactMap { row in
            let fields = row.split(separator: Character(unitSeparator), omittingEmptySubsequences: false)
            guard fields.count >= 4 else {
                return nil
            }
            return DiscoveryPlaylistMetadata(
                persistentID: String(fields[0]),
                name: String(fields[1]),
                specialKind: String(fields[2]),
                isSmart: String(fields[3]).lowercased() == "true"
            )
        }
}

private func parseTrackCounts(_ output: String) -> [String: Int] {
    guard output.isEmpty == false else {
        return [:]
    }

    var counts: [String: Int] = [:]
    for row in output.split(separator: Character(recordSeparator), omittingEmptySubsequences: true) {
        let fields = row.split(separator: Character(unitSeparator), omittingEmptySubsequences: false)
        guard fields.count >= 2, let count = Int(fields[1]) else {
            continue
        }
        counts[String(fields[0])] = count
    }
    return counts
}

private func parsePlaylistSnapshotRows(_ output: String) -> [PlaylistSnapshot] {
    guard output.isEmpty == false else {
        return []
    }

    return output
        .split(separator: Character(recordSeparator), omittingEmptySubsequences: true)
        .compactMap { row in
            let fields = row.split(separator: Character(unitSeparator), omittingEmptySubsequences: false)
            guard fields.count >= 4 else {
                return nil
            }

            let trackIDs = String(fields[3])
                .split(separator: ",", omittingEmptySubsequences: true)
                .map(String.init)

            return PlaylistSnapshot(
                name: String(fields[1]),
                persistentID: String(fields[0]),
                specialKind: String(fields[2]),
                isSmart: true,
                trackPersistentIDs: trackIDs
            )
        }
}

private func formatDuration(milliseconds: Int) -> String {
    String(format: "%.2fs", Double(milliseconds) / 1_000)
}

private func formatByteCount(_ byteCount: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
}

private extension TrackIDProbeStatus {
    var durationMilliseconds: Int {
        switch self {
        case let .success(_, _, durationMilliseconds),
            let .timeout(_, durationMilliseconds),
            let .failure(_, durationMilliseconds):
            return durationMilliseconds
        }
    }
}

private extension FullDiscoveryStatus {
    var label: String {
        switch self {
        case .success:
            return "success"
        case .timeout:
            return "timeout"
        case .failure:
            return "failure"
        }
    }
}

private func printPlaylistTable(title: String, profiles: [DiscoveryPlaylistTrackProfile]) {
    print("\n\(title)")
    if profiles.isEmpty {
        print("  (none)")
        return
    }

    for (index, profile) in profiles.enumerated() {
        print(
            """
              \(index + 1). \(profile.metadata.name)
                 id=\(profile.metadata.persistentID.suffix(8)) kind=\(profile.metadata.specialKindLabel) tracks=\(profile.trackCount) included=\(profile.includedByConfig)
            """
        )
    }
}

private func describeTrackIDStatus(_ status: TrackIDProbeStatus) -> String {
    switch status {
    case let .success(trackIDCount, stdoutBytes, durationMilliseconds):
        return "success in \(formatDuration(milliseconds: durationMilliseconds)), ids=\(trackIDCount), output=\(formatByteCount(stdoutBytes))"
    case let .timeout(message, durationMilliseconds):
        return "timeout after \(formatDuration(milliseconds: durationMilliseconds)): \(message)"
    case let .failure(message, durationMilliseconds):
        return "failure after \(formatDuration(milliseconds: durationMilliseconds)): \(message)"
    }
}

private func printStrategyComparisons(
    title: String,
    comparisons: [PlaylistStrategyComparison],
    strategies: [TrackIDProbeStrategy]
) {
    print("\n\(title)")
    if comparisons.isEmpty {
        print("  (none)")
        return
    }

    for comparison in comparisons {
        let prefix = "  - \(comparison.profile.metadata.name) [\(comparison.profile.metadata.persistentID.suffix(8))] kind=\(comparison.profile.metadata.specialKindLabel) tracks=\(comparison.profile.trackCount) included=\(comparison.profile.includedByConfig)"
        print(prefix)
        for strategy in strategies {
            guard let outcome = comparison.outcomes[strategy] else {
                continue
            }
            print("    \(strategy.label)=\(describeTrackIDStatus(outcome.status))")
        }
    }
}

private func printTrackIDProbeSummaries(
    metadataDurationMilliseconds: Int,
    trackCountDurationMilliseconds: Int,
    summaries: [TrackIDProbeSummary]
) {
    print("\nProbe strategy summary")
    print("  metadata=\(formatDuration(milliseconds: metadataDurationMilliseconds)) trackCounts=\(formatDuration(milliseconds: trackCountDurationMilliseconds))")
    for summary in summaries {
        print(
            "  \(summary.strategy.label): success=\(summary.successCount) timeout=\(summary.timeoutCount) failure=\(summary.failureCount) stdout=\(formatByteCount(summary.stdoutBytes))"
        )
    }
}

private func printFullDiscoveryOutcomes(_ outcomes: [FullDiscoveryOutcome]) {
    print("\nFull discovery probes")
    if outcomes.isEmpty {
        print("  (none)")
        return
    }

    for outcome in outcomes {
        let playlistCount = outcome.playlistCount.map(String.init) ?? "n/a"
        let trackCount = outcome.trackCount.map(String.init) ?? "n/a"
        let stdoutBytes = outcome.stdoutBytes.map(formatByteCount) ?? "n/a"
        print("  \(outcome.label): \(outcome.status.label) in \(formatDuration(milliseconds: outcome.durationMilliseconds))")
        print("    playlists=\(playlistCount) tracks=\(trackCount) output=\(stdoutBytes)")
        print("    \(outcome.message)")
    }
}

private func runMetadataProbe(timeout: TimeInterval) throws -> (playlists: [DiscoveryPlaylistMetadata], durationMilliseconds: Int) {
    let runner = OsaScriptRunner(timeoutInterval: timeout)
    let result = try runner.run(
        scriptName: "checks.discovery.metadata",
        script: metadataProbeScript()
    )
    return (parseMetadataRows(result.stdoutText), result.durationMilliseconds)
}

private func runTrackCountProbe(timeout: TimeInterval) throws -> (counts: [String: Int], durationMilliseconds: Int) {
    let runner = OsaScriptRunner(timeoutInterval: timeout)
    let result = try runner.run(
        scriptName: "checks.discovery.trackCounts",
        script: smartTrackCountProbeScript()
    )
    return (parseTrackCounts(result.stdoutText), result.durationMilliseconds)
}

private func runTrackIDProbe(
    profile: DiscoveryPlaylistTrackProfile,
    strategy: TrackIDProbeStrategy,
    timeout: TimeInterval
) -> TrackIDProbeOutcome {
    let runner = OsaScriptRunner(timeoutInterval: timeout)

    do {
        let result = try runner.run(
            scriptName: "checks.discovery.trackIDs.\(strategy.rawValue)",
            script: playlistTrackIDsProbeScript(strategy: strategy),
            arguments: [profile.metadata.persistentID]
        )
        let trackIDCount: Int
        if result.stdoutText.isEmpty {
            trackIDCount = 0
        } else {
            trackIDCount = result.stdoutText.split(separator: ",", omittingEmptySubsequences: true).count
        }
        return TrackIDProbeOutcome(
            strategy: strategy,
            profile: profile,
            status: .success(
                trackIDCount: trackIDCount,
                stdoutBytes: result.stdoutText.lengthOfBytes(using: .utf8),
                durationMilliseconds: result.durationMilliseconds
            )
        )
    } catch let error as OsaScriptTimeoutError {
        return TrackIDProbeOutcome(
            strategy: strategy,
            profile: profile,
            status: .timeout(
                message: error.message,
                durationMilliseconds: error.durationMilliseconds
            )
        )
    } catch let error as OsaScriptError {
        return TrackIDProbeOutcome(
            strategy: strategy,
            profile: profile,
            status: .failure(
                message: error.message,
                durationMilliseconds: error.durationMilliseconds
            )
        )
    } catch {
        return TrackIDProbeOutcome(
            strategy: strategy,
            profile: profile,
            status: .failure(
                message: error.localizedDescription,
                durationMilliseconds: 0
            )
        )
    }
}

private func runCurrentFullDiscoveryProbe(timeout: TimeInterval) async -> FullDiscoveryOutcome {
    let diagnosticsRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let diagnostics = DiagnosticsLogger(rootDirectory: diagnosticsRoot)
    let client = MusicLibraryClient(
        runner: OsaScriptRunner(timeoutInterval: timeout),
        diagnostics: diagnostics
    )

    let startedAt = Date()
    do {
        let playlists = try await client.listSmartPlaylists(runContext: nil)
        let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        return FullDiscoveryOutcome(
            label: "client-current",
            durationMilliseconds: durationMilliseconds,
            playlistCount: playlists.count,
            trackCount: playlists.reduce(0) { $0 + $1.trackPersistentIDs.count },
            stdoutBytes: nil,
            message: "Completed current listSmartPlaylists path.",
            status: .success
        )
    } catch let error as OsaScriptTimeoutError {
        return FullDiscoveryOutcome(
            label: "client-current",
            durationMilliseconds: error.durationMilliseconds,
            playlistCount: nil,
            trackCount: nil,
            stdoutBytes: nil,
            message: error.message,
            status: .timeout
        )
    } catch let error as OsaScriptError {
        return FullDiscoveryOutcome(
            label: "client-current",
            durationMilliseconds: error.durationMilliseconds,
            playlistCount: nil,
            trackCount: nil,
            stdoutBytes: nil,
            message: error.message,
            status: .failure
        )
    } catch {
        let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        return FullDiscoveryOutcome(
            label: "client-current",
            durationMilliseconds: durationMilliseconds,
            playlistCount: nil,
            trackCount: nil,
            stdoutBytes: nil,
            message: error.localizedDescription,
            status: .failure
        )
    }
}

private func runScriptedFullDiscoveryProbe(
    strategy: TrackIDProbeStrategy,
    timeout: TimeInterval,
    includeSystemPlaylists: Bool
) -> FullDiscoveryOutcome {
    let runner = OsaScriptRunner(timeoutInterval: timeout)
    let labelSuffix = includeSystemPlaylists ? "all-smart" : "included-only"

    do {
        let result = try runner.run(
            scriptName: "checks.discovery.full.\(strategy.rawValue).\(labelSuffix)",
            script: smartPlaylistsFullProbeScript(
                strategy: strategy,
                includeSystemPlaylists: includeSystemPlaylists
            )
        )
        let playlists = parsePlaylistSnapshotRows(result.stdoutText)
        return FullDiscoveryOutcome(
            label: "scripted-\(strategy.label)-\(labelSuffix)",
            durationMilliseconds: result.durationMilliseconds,
            playlistCount: playlists.count,
            trackCount: playlists.reduce(0) { $0 + $1.trackPersistentIDs.count },
            stdoutBytes: result.stdoutText.lengthOfBytes(using: .utf8),
            message: "Completed scripted discovery probe.",
            status: .success
        )
    } catch let error as OsaScriptTimeoutError {
        return FullDiscoveryOutcome(
            label: "scripted-\(strategy.label)-\(labelSuffix)",
            durationMilliseconds: error.durationMilliseconds,
            playlistCount: nil,
            trackCount: nil,
            stdoutBytes: error.stdoutText.lengthOfBytes(using: .utf8),
            message: error.message,
            status: .timeout
        )
    } catch let error as OsaScriptError {
        return FullDiscoveryOutcome(
            label: "scripted-\(strategy.label)-\(labelSuffix)",
            durationMilliseconds: error.durationMilliseconds,
            playlistCount: nil,
            trackCount: nil,
            stdoutBytes: error.stdoutText.lengthOfBytes(using: .utf8),
            message: error.message,
            status: .failure
        )
    } catch {
        return FullDiscoveryOutcome(
            label: "scripted-\(strategy.label)-\(labelSuffix)",
            durationMilliseconds: 0,
            playlistCount: nil,
            trackCount: nil,
            stdoutBytes: nil,
            message: error.localizedDescription,
            status: .failure
        )
    }
}

private func deduplicatedProfiles(_ profiles: [DiscoveryPlaylistTrackProfile]) -> [DiscoveryPlaylistTrackProfile] {
    var seenIDs: Set<String> = []
    var output: [DiscoveryPlaylistTrackProfile] = []

    for profile in profiles where seenIDs.insert(profile.metadata.persistentID).inserted {
        output.append(profile)
    }

    return output
}

private func resolveSelectedProfiles(
    options: DiscoveryDebugOptions,
    allProfiles: [DiscoveryPlaylistTrackProfile],
    topOverall: [DiscoveryPlaylistTrackProfile],
    topIncluded: [DiscoveryPlaylistTrackProfile]
) throws -> [DiscoveryPlaylistTrackProfile] {
    if let persistentID = options.playlistPersistentID {
        guard let profile = allProfiles.first(where: { $0.metadata.persistentID.caseInsensitiveCompare(persistentID) == .orderedSame }) else {
            throw CheckFailure(message: "No smart playlist matched persistent ID \(persistentID).")
        }
        return [profile]
    }

    if let playlistName = options.playlistName {
        let matches = allProfiles.filter { $0.metadata.name.caseInsensitiveCompare(playlistName) == .orderedSame }
        guard matches.isEmpty == false else {
            throw CheckFailure(message: "No smart playlist matched name \(playlistName).")
        }
        guard matches.count == 1 else {
            let ids = matches.map(\.metadata.persistentID).joined(separator: ", ")
            throw CheckFailure(message: "Multiple smart playlists matched name \(playlistName). Use --playlist-id instead. Matches: \(ids)")
        }
        return matches
    }

    if options.includedOnly {
        return topIncluded
    }

    return deduplicatedProfiles(topOverall + topIncluded)
}

private func summarizeOutcomes(
    comparisons: [PlaylistStrategyComparison],
    strategies: [TrackIDProbeStrategy]
) -> [TrackIDProbeSummary] {
    strategies.map { strategy in
        var successCount = 0
        var timeoutCount = 0
        var failureCount = 0
        var stdoutBytes = 0

        for comparison in comparisons {
            guard let outcome = comparison.outcomes[strategy] else {
                continue
            }
            switch outcome.status {
            case let .success(_, outcomeBytes, _):
                successCount += 1
                stdoutBytes += outcomeBytes
            case .timeout:
                timeoutCount += 1
            case .failure:
                failureCount += 1
            }
        }

        return TrackIDProbeSummary(
            strategy: strategy,
            successCount: successCount,
            timeoutCount: timeoutCount,
            failureCount: failureCount,
            stdoutBytes: stdoutBytes
        )
    }
}

private func timedOutPlaylistNames(
    comparisons: [PlaylistStrategyComparison],
    strategy: TrackIDProbeStrategy
) -> [String] {
    comparisons.compactMap { comparison in
        guard let outcome = comparison.outcomes[strategy] else {
            return nil
        }
        if case .timeout = outcome.status {
            return comparison.profile.metadata.name
        }
        return nil
    }
}

private func runDiscoveryDebug(options: DiscoveryDebugOptions) async throws {
    let config = loadCurrentConfig()
    let strategies = options.strategySelection.strategies
    let focusedSelection = options.playlistPersistentID != nil || options.playlistName != nil

    print("SyncMusicChecks discovery debug")
    print(
        "Config: includeSystemSmartPlaylists=\(config.includeSystemSmartPlaylists), providerProfile=\(config.providerProfile.rawValue), top=\(options.topPlaylistCount), probeTimeout=\(Int(options.playlistTimeoutSeconds))s, fullProbeTimeout=\(Int(options.fullProbeTimeoutSeconds))s, strategy=\(options.strategySelection.rawValue), includedOnly=\(options.includedOnly)"
    )

    let shouldRunFullProbes = options.skipFullProbe == false && focusedSelection == false
    if shouldRunFullProbes {
        var fullOutcomes = [await runCurrentFullDiscoveryProbe(timeout: options.fullProbeTimeoutSeconds)]
        let includeSystemVariants: [Bool] = options.includedOnly && config.includeSystemSmartPlaylists == false
            ? [true, false]
            : [true]

        for strategy in strategies {
            for includeSystemPlaylists in includeSystemVariants {
                fullOutcomes.append(
                    runScriptedFullDiscoveryProbe(
                        strategy: strategy,
                        timeout: options.fullProbeTimeoutSeconds,
                        includeSystemPlaylists: includeSystemPlaylists
                    )
                )
            }
        }

        printFullDiscoveryOutcomes(fullOutcomes)
    } else if focusedSelection, options.skipFullProbe == false {
        print("\nFull discovery probes")
        print("  skipped for focused playlist selection")
    }

    let metadataProbe = try runMetadataProbe(timeout: options.playlistTimeoutSeconds)
    print("\nMetadata probe")
    print("  duration=\(formatDuration(milliseconds: metadataProbe.durationMilliseconds)) playlists=\(metadataProbe.playlists.count)")

    let smartPlaylists = metadataProbe.playlists.filter(\.isSmart)
    let smartPlaylistSnapshots = smartPlaylists.map { metadata in
        PlaylistSnapshot(
            name: metadata.name,
            persistentID: metadata.persistentID,
            specialKind: metadata.specialKind,
            isSmart: metadata.isSmart,
            trackPersistentIDs: []
        )
    }
    let systemSmartCount = smartPlaylists.filter(\.isSystemSmartPlaylist).count
    let playlistEvaluation = SyncPlanner.evaluateSmartPlaylists(
        from: smartPlaylistSnapshots,
        includeSystemPlaylists: config.includeSystemSmartPlaylists,
        exclusionRules: config.sourcePlaylistExclusions
    )
    let includedIDs = Set(playlistEvaluation.included.map { $0.persistentID })
    let ruleExcludedIDs = Set(playlistEvaluation.excludedByRules.map { $0.persistentID })
    let systemExcludedIDs = Set(playlistEvaluation.excludedBySystemFilter.map { $0.persistentID })

    print("  smart=\(smartPlaylists.count) systemSmart=\(systemSmartCount) nonSystemSmart=\(smartPlaylists.count - systemSmartCount)")
    print("  excludedByRules=\(playlistEvaluation.excludedByRules.count) excludedBySystem=\(playlistEvaluation.excludedBySystemFilter.count)")

    let trackCountProbe = try runTrackCountProbe(timeout: options.playlistTimeoutSeconds)
    print("\nSmart track-count probe")
    print("  duration=\(formatDuration(milliseconds: trackCountProbe.durationMilliseconds)) playlists=\(trackCountProbe.counts.count)")

    let profiles = smartPlaylists.map { metadata in
        DiscoveryPlaylistTrackProfile(
            metadata: metadata,
            trackCount: trackCountProbe.counts[metadata.persistentID] ?? 0,
            includedByConfig: includedIDs.contains(metadata.persistentID)
        )
    }.sorted { lhs, rhs in
        if lhs.trackCount == rhs.trackCount {
            return lhs.metadata.name.localizedCaseInsensitiveCompare(rhs.metadata.name) == .orderedAscending
        }
        return lhs.trackCount > rhs.trackCount
    }

    let totalTrackCount = profiles.reduce(0) { $0 + $1.trackCount }
    let excludedByRuleTrackCount = profiles.filter { ruleExcludedIDs.contains($0.metadata.persistentID) }.reduce(0) { $0 + $1.trackCount }
    let excludedBySystemTrackCount = profiles.filter { systemExcludedIDs.contains($0.metadata.persistentID) }.reduce(0) { $0 + $1.trackCount }
    let excludedTrackCount = excludedByRuleTrackCount + excludedBySystemTrackCount
    let includedTrackCount = profiles.filter { $0.includedByConfig }.reduce(0) { $0 + $1.trackCount }

    print("\nTrack volume summary")
    print("  totalSmartTracks=\(totalTrackCount)")
    print("  includedByConfigTracks=\(includedTrackCount)")
    print("  excludedByRuleTracks=\(excludedByRuleTrackCount)")
    print("  excludedBySystemTracks=\(excludedBySystemTrackCount)")
    print("  excludedByConfigTracks=\(excludedTrackCount)")

    let topOverall = Array(profiles.prefix(options.topPlaylistCount))
    let topIncluded = Array(profiles.filter { $0.includedByConfig }.prefix(options.topPlaylistCount))

    if focusedSelection {
        let selectedProfiles = try resolveSelectedProfiles(
            options: options,
            allProfiles: profiles,
            topOverall: topOverall,
            topIncluded: topIncluded
        )
        printPlaylistTable(title: "Selected smart playlists", profiles: selectedProfiles)
    } else {
        printPlaylistTable(title: "Top smart playlists by track count", profiles: topOverall)
        printPlaylistTable(title: "Top included-by-config smart playlists by track count", profiles: topIncluded)
    }

    let selectedProfiles = try resolveSelectedProfiles(
        options: options,
        allProfiles: profiles,
        topOverall: topOverall,
        topIncluded: topIncluded
    )

    var cachedOutcomes: [String: [TrackIDProbeStrategy: TrackIDProbeOutcome]] = [:]
    func cachedProbe(for profile: DiscoveryPlaylistTrackProfile, strategy: TrackIDProbeStrategy) -> TrackIDProbeOutcome {
        if let existing = cachedOutcomes[profile.metadata.persistentID]?[strategy] {
            return existing
        }

        let outcome = runTrackIDProbe(
            profile: profile,
            strategy: strategy,
            timeout: options.playlistTimeoutSeconds
        )
        var strategyOutcomes = cachedOutcomes[profile.metadata.persistentID] ?? [:]
        strategyOutcomes[strategy] = outcome
        cachedOutcomes[profile.metadata.persistentID] = strategyOutcomes
        return outcome
    }

    let comparisons = selectedProfiles.map { profile in
        let outcomes = Dictionary(uniqueKeysWithValues: strategies.map { strategy in
            (strategy, cachedProbe(for: profile, strategy: strategy))
        })
        return PlaylistStrategyComparison(profile: profile, outcomes: outcomes)
    }

    let comparisonTitle = focusedSelection
        ? "Track-ID extraction comparisons for selected smart playlists"
        : "Track-ID extraction comparisons for probed smart playlists"
    printStrategyComparisons(
        title: comparisonTitle,
        comparisons: comparisons,
        strategies: strategies
    )

    let summaries = summarizeOutcomes(comparisons: comparisons, strategies: strategies)
    printTrackIDProbeSummaries(
        metadataDurationMilliseconds: metadataProbe.durationMilliseconds,
        trackCountDurationMilliseconds: trackCountProbe.durationMilliseconds,
        summaries: summaries
    )

    for strategy in strategies {
        let timedOutPlaylists = timedOutPlaylistNames(comparisons: comparisons, strategy: strategy)
        if timedOutPlaylists.isEmpty == false {
            print("\nTimed out playlists for \(strategy.label): \(timedOutPlaylists.joined(separator: ", "))")
        }
    }
}

func runChecks() async throws {
    try expect(SyncPlanner.chunkedTrackIDs([], limit: nil) == [[]], "Empty playlist should still create one empty materialized part.")
    try expect(SyncPlanner.chunkedTrackIDs([], limit: 1_900) == [[]], "Chunked empty playlist should still create one empty materialized part.")

    let trackIDs = (1...3_805).map { "TRACK-\($0)" }
    let chunks = SyncPlanner.chunkedTrackIDs(trackIDs, limit: 1_900)
    try expect(chunks.count == 3, "Expected 3 chunks for 3,805 tracks at 1,900/part.")
    try expect(chunks[0].count == 1_900, "First chunk should contain 1,900 tracks.")
    try expect(chunks[1].count == 1_900, "Second chunk should contain 1,900 tracks.")
    try expect(chunks[2].count == 5, "Final chunk should contain 5 tracks.")
    try expect(chunks[0].first == "TRACK-1", "First chunk should preserve source order.")
    try expect(chunks[2].last == "TRACK-3805", "Last chunk should preserve source order.")

    let names = SyncPlanner.materializedPlaylistNames(prefix: "Sync Mirror", sourceName: "Recently Added", partCount: 3)
    try expect(names == [
        "Sync Mirror / Recently Added (Part 1)",
        "Sync Mirror / Recently Added (Part 2)",
        "Sync Mirror / Recently Added (Part 3)",
    ], "Materialized playlist names should be stable and numbered.")

    let diff = SyncPlanner.diff(source: ["A", "C", "D"], target: ["A", "B", "E"])
    try expect(diff.toAdd == ["C", "D"], "Adds should preserve source ordering.")
    try expect(diff.toRemove == ["B", "E"], "Removes should preserve target ordering.")

    let userPlaylist = PlaylistSnapshot(
        name: "Recently Added",
        persistentID: "USER",
        specialKind: "none",
        isSmart: true,
        trackPersistentIDs: []
    )
    let systemPlaylist = PlaylistSnapshot(
        name: "Music",
        persistentID: "SYSTEM",
        specialKind: "Music",
        isSmart: true,
        trackPersistentIDs: []
    )
    let favoriteSongsPlaylist = PlaylistSnapshot(
        name: "Favorite Songs",
        persistentID: "FAVORITE",
        specialKind: "none",
        isSmart: true,
        trackPersistentIDs: []
    )
    let evaluation = SyncPlanner.evaluateSmartPlaylists(
        from: [userPlaylist, favoriteSongsPlaylist, systemPlaylist],
        includeSystemPlaylists: false,
        exclusionRules: [PlaylistExclusionRule(matchType: .exactName, value: "favorite songs")]
    )
    try expect(evaluation.included == [userPlaylist], "Only non-system, non-excluded smart playlists should remain included.")
    try expect(evaluation.excludedByRules == [favoriteSongsPlaylist], "Favorite Songs should be excluded by explicit rule.")
    try expect(evaluation.excludedBySystemFilter == [systemPlaylist], "System smart playlists should still be excluded by the system toggle.")
    try expect(evaluation.protectedSourceIDs == Set(["USER", "FAVORITE"]), "Explicit exclusions should remain protected from stale cleanup.")

    let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = StateStore(rootDirectory: tempDirectory)
    let config = AppConfig(
        autoSyncSchedule: .interval(minutes: 45),
        materializedPrefix: "Managed",
        includeSystemSmartPlaylists: true,
        sourcePlaylistExclusions: [
            PlaylistExclusionRule(matchType: .specialKind, value: "Music"),
            PlaylistExclusionRule(matchType: .exactName, value: "Favorite Songs"),
        ],
        providerProfile: .generic,
        deleteStaleManagedPlaylists: false,
        logLevel: .debug,
        debugLogging: true,
        maxLogFileSizeBytes: 1_000_000,
        maxRotatedLogFiles: 3
    )
    let state = SyncState(managedPlaylists: [
        "SOURCE": ManagedPlaylistState(
            sourcePersistentID: "SOURCE",
            sourceName: "Recently Added",
            parts: [ManagedPlaylistPart(index: 0, targetPersistentID: "TARGET", targetName: "Managed / Recently Added")],
            lastSyncedAt: Date(timeIntervalSince1970: 1_234),
            lastError: nil,
            lastFailureCategory: nil,
            lastRunID: "RUN-1"
        ),
    ])

    try store.saveConfig(config)
    try store.saveState(state)

    let loadedConfig = try store.loadConfig()
    let loadedState = try store.loadState()
    try expect(loadedConfig == config, "Config should round-trip through StateStore.")
    try expect(loadedState == state, "State should round-trip through StateStore.")

    let diagnostics = DiagnosticsLogger(rootDirectory: tempDirectory)
    await diagnostics.updateConfig(config)
    await diagnostics.log(
        SyncEvent(
            level: .info,
            subsystem: "checks",
            operation: "checks.writeEvent",
            runID: "RUN-CHECK",
            trigger: .manual,
            message: "Writing a sample diagnostics event."
        )
    )
    let events = await diagnostics.loadRecentEvents(limit: 1)
    try expect(events.count == 1, "Diagnostics logger should persist at least one event.")
    try expect(events[0].operation == "checks.writeEvent", "Diagnostics logger should return the expected event.")

    let runner = OsaScriptRunner(timeoutInterval: 2)
    let largeOutputScript = """
    use AppleScript version "2.4"
    use scripting additions

    on run argv
        set payload to ""
        repeat 7000 times
            set payload to payload & "0123456789"
        end repeat
        return payload
    end run
    """
    let largeOutputResult = try runner.run(
        scriptName: "checks.largeStdout",
        script: largeOutputScript
    )
    try expect(largeOutputResult.stdoutText.count == 70_000, "OsaScriptRunner should fully capture large stdout payloads.")

    let timeoutRunner = OsaScriptRunner(timeoutInterval: 0.2)
    let timeoutScript = """
    use AppleScript version "2.4"
    use scripting additions

    on run argv
        delay 5
        return "done"
    end run
    """

    do {
        _ = try timeoutRunner.run(
            scriptName: "checks.timeout",
            script: timeoutScript
        )
        throw CheckFailure(message: "Expected OsaScriptRunner to time out for a long-running AppleScript.")
    } catch let timeoutError as OsaScriptTimeoutError {
        try expect(timeoutError.operation == "checks.timeout", "Timeout should preserve the operation name.")
        try expect(timeoutError.durationMilliseconds < 2_000, "Timeout should fail promptly.")
    }
}

private func formattedTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func runSyncOnce(trigger: SyncTrigger) async throws {
    let engine = SyncEngine()
    let config = await engine.loadConfig()

    print("Running \(trigger.displayName.lowercased()) sync with profile \(config.providerProfile.rawValue)...")
    let report = await engine.runSync(config: config, trigger: trigger) { update in
        var details: [String] = []
        details.append(update.stage.rawValue)
        if let currentPlaylistName = update.currentPlaylistName {
            details.append("playlist=\(currentPlaylistName)")
        }
        if let processedPlaylistCount = update.processedPlaylistCount {
            details.append("processed=\(processedPlaylistCount)")
        }
        print("[\(formattedTimestamp(update.updatedAt))] \(details.joined(separator: " ")) :: \(update.message)")
    }

    print("")
    print("Run summary")
    print("runID=\(report.runID)")
    print("trigger=\(report.trigger.rawValue)")
    print("processedPlaylistCount=\(report.processedPlaylistCount)")
    print("writtenTrackCount=\(report.writtenTrackCount)")
    print("rebuiltPlaylistPartCount=\(report.rebuiltPlaylistPartCount)")
    print("addedTrackCount=\(report.addedTrackCount)")
    print("removedTrackCount=\(report.removedTrackCount)")
    print("createdPlaylistCount=\(report.createdPlaylistCount)")
    print("deletedPlaylistCount=\(report.deletedPlaylistCount)")
    print("renamedPlaylistCount=\(report.renamedPlaylistCount)")
    print("failureCount=\(report.failures.count)")
    print("durationMilliseconds=\(report.durationMilliseconds)")

    if report.failures.isEmpty == false {
        print("")
        print("Failures")
        for failure in report.failures {
            print("- [\(failure.category.rawValue)] \(failure.playlistName) :: \(failure.message)")
        }
        throw CheckFailure(message: "Sync completed with \(report.failures.count) failure(s).")
    }
}

@main
struct SyncMusicChecks {
    static func main() async {
        do {
            switch try parseCommand() {
            case .checks:
                try await runChecks()
                print("SyncMusicChecks passed")
            case let .runSyncOnce(trigger):
                try await runSyncOnce(trigger: trigger)
            case let .debugDiscovery(options):
                try await runDiscoveryDebug(options: options)
            case .help:
                printUsage()
            }
        } catch {
            fputs("SyncMusicChecks failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
