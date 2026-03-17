import Foundation

public final class MusicLibraryClient: @unchecked Sendable {
    private let runner: OsaScriptRunner
    private let diagnostics: DiagnosticsLogger
    private let unitSeparator = "\u{001F}"
    private let recordSeparator = "\u{001E}"
    private let slowSnapshotThresholdMilliseconds = 10_000

    public init(
        runner: OsaScriptRunner = OsaScriptRunner(),
        diagnostics: DiagnosticsLogger = DiagnosticsLogger()
    ) {
        self.runner = runner
        self.diagnostics = diagnostics
    }

    public func listSmartPlaylists(runContext: RunContext?) async throws -> [PlaylistSnapshot] {
        let result = try await runMusicScript(
            operation: "music.listSmartPlaylists",
            script: smartPlaylistsScript,
            arguments: [],
            runContext: runContext,
            messageOnSuccess: "Enumerated smart playlists."
        )
        let playlists = parsePlaylistRows(result.stdoutText, isSmart: true)
        await diagnostics.log(
            SyncEvent(
                level: .info,
                subsystem: "music",
                operation: "music.listSmartPlaylists",
                runID: runContext?.runID,
                trigger: runContext?.trigger,
                message: "Discovered \(playlists.count) smart playlists.",
                trackCount: playlists.reduce(0) { $0 + $1.trackPersistentIDs.count },
                durationMilliseconds: result.durationMilliseconds,
                metadata: ["playlistCount": "\(playlists.count)"]
            )
        )
        return playlists
    }

    public func listSmartPlaylistMetadata(runContext: RunContext?) async throws -> [PlaylistSnapshot] {
        let result = try await runMusicScript(
            operation: "music.listSmartPlaylistMetadata",
            script: smartPlaylistMetadataScript,
            arguments: [],
            runContext: runContext,
            messageOnSuccess: "Enumerated smart playlist metadata."
        )
        let playlists = parsePlaylistRows(result.stdoutText, isSmart: true)
        await diagnostics.log(
            SyncEvent(
                level: .info,
                subsystem: "music",
                operation: "music.listSmartPlaylistMetadata",
                runID: runContext?.runID,
                trigger: runContext?.trigger,
                message: "Discovered metadata for \(playlists.count) smart playlists.",
                durationMilliseconds: result.durationMilliseconds,
                metadata: ["playlistCount": "\(playlists.count)"]
            )
        )
        return playlists
    }

    public func snapshotUserPlaylist(
        persistentID: String,
        runContext: RunContext?,
        sourcePlaylistName: String? = nil,
        targetPlaylistName: String? = nil
    ) async throws -> PlaylistSnapshot {
        let result = try await runMusicScript(
            operation: "music.snapshotUserPlaylist",
            script: playlistSnapshotScript,
            arguments: [persistentID],
            runContext: runContext,
            sourcePlaylistName: sourcePlaylistName,
            targetPlaylistName: targetPlaylistName,
            targetPlaylistPersistentID: persistentID,
            messageOnSuccess: "Loaded playlist snapshot."
        )

        guard let snapshot = parsePlaylistRows(result.stdoutText, isSmart: false).first else {
            let message = "Music did not return playlist \(persistentID)."
            let category = FailureCategory.playlistLookupFailed
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "music",
                    operation: "music.snapshotUserPlaylist",
                    runID: runContext?.runID,
                    trigger: runContext?.trigger,
                    message: message,
                    sourcePlaylistName: sourcePlaylistName,
                    targetPlaylistName: targetPlaylistName,
                    targetPlaylistPersistentID: persistentID,
                    durationMilliseconds: result.durationMilliseconds,
                    errorCategory: category,
                    errorMessage: message
                )
            )
            throw OsaScriptError(
                operation: "music.snapshotUserPlaylist",
                terminationStatus: -1,
                stdoutText: result.stdoutText,
                stderrText: message,
                durationMilliseconds: result.durationMilliseconds
            )
        }

        if result.durationMilliseconds >= slowSnapshotThresholdMilliseconds {
            await diagnostics.log(
                SyncEvent(
                    level: .warning,
                    subsystem: "music",
                    operation: "music.snapshotUserPlaylist.slow",
                    runID: runContext?.runID,
                    trigger: runContext?.trigger,
                    message: "Playlist snapshot exceeded the slow-operation threshold.",
                    sourcePlaylistName: sourcePlaylistName ?? snapshot.name,
                    targetPlaylistName: targetPlaylistName,
                    targetPlaylistPersistentID: persistentID,
                    trackCount: snapshot.trackPersistentIDs.count,
                    durationMilliseconds: result.durationMilliseconds
                )
            )
        }

        return snapshot
    }

    public func playlistName(
        persistentID: String,
        runContext: RunContext?,
        sourcePlaylistName: String? = nil,
        targetPlaylistName: String? = nil
    ) async throws -> String {
        let result = try await runMusicScript(
            operation: "music.playlistName",
            script: playlistNameScript,
            arguments: [persistentID],
            runContext: runContext,
            sourcePlaylistName: sourcePlaylistName,
            targetPlaylistName: targetPlaylistName,
            targetPlaylistPersistentID: persistentID,
            messageOnSuccess: "Resolved materialized playlist name."
        )

        let resolvedName = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedName.isEmpty == false else {
            let message = "Music did not return playlist \(persistentID)."
            throw OsaScriptError(
                operation: "music.playlistName",
                terminationStatus: -1,
                stdoutText: result.stdoutText,
                stderrText: message,
                durationMilliseconds: result.durationMilliseconds
            )
        }
        return resolvedName
    }

    public func createUserPlaylist(
        named name: String,
        runContext: RunContext?,
        sourcePlaylistName: String? = nil
    ) async throws -> String {
        let result = try await runMusicScript(
            operation: "music.createUserPlaylist",
            script: createPlaylistScript,
            arguments: [name],
            runContext: runContext,
            sourcePlaylistName: sourcePlaylistName,
            targetPlaylistName: name,
            messageOnSuccess: "Created materialized playlist."
        )
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func renamePlaylist(
        persistentID: String,
        newName: String,
        runContext: RunContext?,
        sourcePlaylistName: String? = nil
    ) async throws {
        _ = try await runMusicScript(
            operation: "music.renamePlaylist",
            script: renamePlaylistScript,
            arguments: [persistentID, newName],
            runContext: runContext,
            sourcePlaylistName: sourcePlaylistName,
            targetPlaylistName: newName,
            targetPlaylistPersistentID: persistentID,
            messageOnSuccess: "Renamed materialized playlist."
        )
    }

    public func deletePlaylist(
        persistentID: String,
        runContext: RunContext?,
        sourcePlaylistName: String? = nil,
        targetPlaylistName: String? = nil
    ) async throws {
        _ = try await runMusicScript(
            operation: "music.deletePlaylist",
            script: deletePlaylistScript,
            arguments: [persistentID],
            runContext: runContext,
            sourcePlaylistName: sourcePlaylistName,
            targetPlaylistName: targetPlaylistName,
            targetPlaylistPersistentID: persistentID,
            messageOnSuccess: "Deleted materialized playlist."
        )
    }

    public func replacePlaylistContents(
        sourcePlaylistPersistentID: String,
        targetPlaylistPersistentID: String,
        sourceTrackStartIndex: Int,
        sourceTrackEndIndex: Int,
        desiredTrackIDs: [String],
        runContext: RunContext?,
        sourcePlaylistName: String,
        targetPlaylistName: String,
        partIndex: Int,
        totalParts: Int
    ) async throws {
        let sampleIDs = desiredTrackIDs.prefix(3).joined(separator: ",")
        _ = try await runMusicScript(
            operation: "music.replacePlaylistContents",
            script: replacePlaylistScript,
            arguments: [
                sourcePlaylistPersistentID,
                targetPlaylistPersistentID,
                String(sourceTrackStartIndex),
                String(sourceTrackEndIndex),
            ],
            runContext: runContext,
            sourcePlaylistName: sourcePlaylistName,
            sourcePlaylistPersistentID: sourcePlaylistPersistentID,
            targetPlaylistName: targetPlaylistName,
            targetPlaylistPersistentID: targetPlaylistPersistentID,
            partIndex: partIndex,
            totalParts: totalParts,
            trackCount: desiredTrackIDs.count,
            metadata: [
                "desiredTrackSample": sampleIDs,
                "sourceTrackRange": "\(sourceTrackStartIndex)-\(sourceTrackEndIndex)",
            ],
            messageOnSuccess: "Replaced playlist contents with the source track range."
        )
    }

    private func runMusicScript(
        operation: String,
        script: String,
        arguments: [String],
        runContext: RunContext?,
        sourcePlaylistName: String? = nil,
        sourcePlaylistPersistentID: String? = nil,
        targetPlaylistName: String? = nil,
        targetPlaylistPersistentID: String? = nil,
        partIndex: Int? = nil,
        totalParts: Int? = nil,
        trackCount: Int? = nil,
        metadata: [String: String]? = nil,
        messageOnSuccess: String
    ) async throws -> OsaScriptExecution {
        await diagnostics.log(
            SyncEvent(
                level: .info,
                subsystem: "music",
                operation: operation,
                runID: runContext?.runID,
                trigger: runContext?.trigger,
                message: "Starting Music automation operation.",
                sourcePlaylistName: sourcePlaylistName,
                sourcePlaylistPersistentID: sourcePlaylistPersistentID,
                targetPlaylistName: targetPlaylistName,
                targetPlaylistPersistentID: targetPlaylistPersistentID,
                partIndex: partIndex,
                totalParts: totalParts,
                trackCount: trackCount,
                metadata: metadata
            )
        )

        do {
            let result = try runner.run(scriptName: operation, script: script, arguments: arguments)
            await diagnostics.log(
                SyncEvent(
                    level: .info,
                    subsystem: "music",
                    operation: operation,
                    runID: runContext?.runID,
                    trigger: runContext?.trigger,
                    message: messageOnSuccess,
                    sourcePlaylistName: sourcePlaylistName,
                    sourcePlaylistPersistentID: sourcePlaylistPersistentID,
                    targetPlaylistName: targetPlaylistName,
                    targetPlaylistPersistentID: targetPlaylistPersistentID,
                    partIndex: partIndex,
                    totalParts: totalParts,
                    trackCount: trackCount,
                    durationMilliseconds: result.durationMilliseconds,
                    stdoutPreview: truncate(result.stdoutText),
                    stderrPreview: truncate(result.stderrText),
                    metadata: metadata
                )
            )
            return result
        } catch let error as OsaScriptError {
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "music",
                    operation: operation,
                    runID: runContext?.runID,
                    trigger: runContext?.trigger,
                    message: error.message,
                    sourcePlaylistName: sourcePlaylistName,
                    sourcePlaylistPersistentID: sourcePlaylistPersistentID,
                    targetPlaylistName: targetPlaylistName,
                    targetPlaylistPersistentID: targetPlaylistPersistentID,
                    partIndex: partIndex,
                    totalParts: totalParts,
                    trackCount: trackCount,
                    durationMilliseconds: error.durationMilliseconds,
                    errorCategory: error.category,
                    errorMessage: error.message,
                    stdoutPreview: truncate(error.stdoutText),
                    stderrPreview: truncate(error.stderrText),
                    metadata: metadata
                )
            )
            throw error
        } catch {
            let category = FailureCategory.classify(message: error.localizedDescription, operation: operation)
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "music",
                    operation: operation,
                    runID: runContext?.runID,
                    trigger: runContext?.trigger,
                    message: error.localizedDescription,
                    sourcePlaylistName: sourcePlaylistName,
                    sourcePlaylistPersistentID: sourcePlaylistPersistentID,
                    targetPlaylistName: targetPlaylistName,
                    targetPlaylistPersistentID: targetPlaylistPersistentID,
                    partIndex: partIndex,
                    totalParts: totalParts,
                    trackCount: trackCount,
                    errorCategory: category,
                    errorMessage: error.localizedDescription,
                    metadata: metadata
                )
            )
            throw error
        }
    }

    private func parsePlaylistRows(_ output: String, isSmart: Bool) -> [PlaylistSnapshot] {
        guard !output.isEmpty else {
            return []
        }

        return output
            .split(separator: Character(recordSeparator), omittingEmptySubsequences: true)
            .compactMap { row -> PlaylistSnapshot? in
                let fields = row.split(separator: Character(unitSeparator), omittingEmptySubsequences: false)
                guard fields.count >= 4 else {
                    return nil
                }

                let persistentID = String(fields[0])
                let name = String(fields[1])
                let specialKind = String(fields[2])
                let trackIDs = String(fields[3])
                    .split(separator: ",", omittingEmptySubsequences: true)
                    .map(String.init)

                return PlaylistSnapshot(
                    name: name,
                    persistentID: persistentID,
                    specialKind: specialKind,
                    isSmart: isSmart,
                    trackPersistentIDs: trackIDs
                )
            }
    }

    private func truncate(_ value: String, maximumLength: Int = 240) -> String? {
        guard !value.isEmpty else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.count <= maximumLength {
            return trimmed
        }

        return String(trimmed.prefix(maximumLength)) + "…"
    }

    private var sharedHelpers: String {
        """
        on joinList(inputList, delimiter)
            set oldDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to delimiter
            set joinedText to inputList as text
            set AppleScript's text item delimiters to oldDelimiters
            return joinedText
        end joinList

        on splitCSV(inputText)
            if inputText is "" then
                return {}
            end if
            set oldDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to ","
            set outputList to text items of inputText
            set AppleScript's text item delimiters to oldDelimiters
            return outputList
        end splitCSV
        """
    }

    private var smartPlaylistsScript: String {
        """
        use AppleScript version "2.4"
        use scripting additions
        \(sharedHelpers)

        on run argv
            set unitSep to character id 31
            set recordSep to character id 30
            set playlistRows to {}

            tell application "Music"
                repeat with candidatePlaylist in every user playlist
                    try
                        if smart of candidatePlaylist is true then
                            set specialKind to ""
                            try
                                set specialKind to (special kind of candidatePlaylist as text)
                            end try
                            set trackIDs to persistent ID of every track of candidatePlaylist
                            set end of playlistRows to (persistent ID of candidatePlaylist as text) & unitSep & (name of candidatePlaylist as text) & unitSep & specialKind & unitSep & my joinList(trackIDs, ",")
                        end if
                    end try
                end repeat
            end tell

            return my joinList(playlistRows, recordSep)
        end run
        """
    }

    private var smartPlaylistMetadataScript: String {
        """
        use AppleScript version "2.4"
        use scripting additions
        \(sharedHelpers)

        on run argv
            set unitSep to character id 31
            set recordSep to character id 30
            set playlistRows to {}

            tell application "Music"
                repeat with candidatePlaylist in every user playlist
                    try
                        if smart of candidatePlaylist is true then
                            set specialKind to ""
                            try
                                set specialKind to (special kind of candidatePlaylist as text)
                            end try
                            set end of playlistRows to (persistent ID of candidatePlaylist as text) & unitSep & (name of candidatePlaylist as text) & unitSep & specialKind & unitSep
                        end if
                    end try
                end repeat
            end tell

            return my joinList(playlistRows, recordSep)
        end run
        """
    }

    private var playlistSnapshotScript: String {
        """
        use AppleScript version "2.4"
        use scripting additions
        \(sharedHelpers)

        on run argv
            set targetID to item 1 of argv
            set unitSep to character id 31
            set recordText to ""
            tell application "Music"
                repeat with candidatePlaylist in every playlist
                    try
                        if (persistent ID of candidatePlaylist as text) is targetID then
                            set specialKind to ""
                            try
                                set specialKind to (special kind of candidatePlaylist as text)
                            end try
                            set trackIDs to persistent ID of every track of candidatePlaylist
                            set recordText to (persistent ID of candidatePlaylist as text) & unitSep & (name of candidatePlaylist as text) & unitSep & specialKind & unitSep & my joinList(trackIDs, ",")
                            exit repeat
                        end if
                    end try
                end repeat
            end tell
            if recordText is "" then
                error "Playlist not found: " & targetID
            end if
            return recordText
        end run
        """
    }

    private var createPlaylistScript: String {
        """
        use AppleScript version "2.4"
        use scripting additions
        \(sharedHelpers)

        on run argv
            set targetName to item 1 of argv
            tell application "Music"
                set createdPlaylist to make new user playlist with properties {name:targetName}
                return persistent ID of createdPlaylist as text
            end tell
        end run
        """
    }

    private var playlistNameScript: String {
        """
        use AppleScript version "2.4"
        use scripting additions
        \(sharedHelpers)

        on run argv
            set targetID to item 1 of argv
            tell application "Music"
                repeat with candidatePlaylist in every playlist
                    try
                        if (persistent ID of candidatePlaylist as text) is targetID then
                            return name of candidatePlaylist as text
                        end if
                    end try
                end repeat
            end tell
            error "Playlist not found: " & targetID
        end run
        """
    }

    private var renamePlaylistScript: String {
        """
        use AppleScript version "2.4"
        use scripting additions
        \(sharedHelpers)

        on run argv
            set targetID to item 1 of argv
            set newName to item 2 of argv
            tell application "Music"
                repeat with candidatePlaylist in every playlist
                    try
                        if (persistent ID of candidatePlaylist as text) is targetID then
                            set name of candidatePlaylist to newName
                            return persistent ID of candidatePlaylist as text
                        end if
                    end try
                end repeat
            end tell
            error "Playlist not found: " & targetID
        end run
        """
    }

    private var deletePlaylistScript: String {
        """
        use AppleScript version "2.4"
        use scripting additions
        \(sharedHelpers)

        on run argv
            set targetID to item 1 of argv
            tell application "Music"
                repeat with candidatePlaylist in every playlist
                    try
                        if (persistent ID of candidatePlaylist as text) is targetID then
                            delete candidatePlaylist
                            return targetID
                        end if
                    end try
                end repeat
            end tell
            error "Playlist not found: " & targetID
        end run
        """
    }

    private var replacePlaylistScript: String {
        """
        use AppleScript version "2.4"
        use scripting additions
        \(sharedHelpers)

        on run argv
            set sourceID to item 1 of argv
            set targetID to item 2 of argv
            set sourceTrackStartIndex to (item 3 of argv) as integer
            set sourceTrackEndIndex to (item 4 of argv) as integer
            set sourcePlaylist to missing value
            set targetPlaylist to missing value

            tell application "Music"
                repeat with candidatePlaylist in every playlist
                    try
                        set candidateID to persistent ID of candidatePlaylist as text
                        if candidateID is sourceID then
                            set sourcePlaylist to candidatePlaylist
                        else if candidateID is targetID then
                            set targetPlaylist to candidatePlaylist
                        end if

                        if sourcePlaylist is not missing value and targetPlaylist is not missing value then
                            exit repeat
                        end if
                    end try
                end repeat

                if sourcePlaylist is missing value then
                    error "Playlist not found: " & sourceID
                end if
                if targetPlaylist is missing value then
                    error "Playlist not found: " & targetID
                end if

                set currentTracks to every track of targetPlaylist
                repeat with existingTrack in currentTracks
                    delete existingTrack
                end repeat

                if sourceTrackEndIndex < sourceTrackStartIndex then
                    return "ok"
                end if

                set sourceTrackCount to count of every track of sourcePlaylist
                if sourceTrackStartIndex < 1 or sourceTrackEndIndex > sourceTrackCount then
                    error "Requested source track range " & sourceTrackStartIndex & "-" & sourceTrackEndIndex & " is invalid for " & sourceID
                end if

                duplicate (tracks sourceTrackStartIndex thru sourceTrackEndIndex of sourcePlaylist) to targetPlaylist
            end tell

            return "ok"
        end run
        """
    }
}
