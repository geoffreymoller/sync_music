import CryptoKit
import Foundation

public actor SyncEngine {
    private let store: StateStore
    private let musicClient: MusicLibraryClient
    private let diagnostics: DiagnosticsLogger

    public init(
        store: StateStore = StateStore(),
        diagnostics: DiagnosticsLogger = DiagnosticsLogger(),
        musicClient: MusicLibraryClient? = nil
    ) {
        self.store = store
        self.diagnostics = diagnostics
        self.musicClient = musicClient ?? MusicLibraryClient(diagnostics: diagnostics)
    }

    public func loadConfig() async -> AppConfig {
        do {
            let config = try store.loadConfig()
            await diagnostics.updateConfig(config)
            return config
        } catch {
            let fallback = AppConfig()
            await diagnostics.updateConfig(fallback)
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "state",
                    operation: "state.loadConfig",
                    message: "Failed loading config. Falling back to defaults.",
                    errorCategory: .stateStoreFailure,
                    errorMessage: error.localizedDescription
                )
            )
            return fallback
        }
    }

    public func saveConfig(_ config: AppConfig) async throws {
        do {
            try store.saveConfig(config)
            await diagnostics.updateConfig(config)
            await diagnostics.log(
                SyncEvent(
                    level: .info,
                    subsystem: "state",
                    operation: "state.saveConfig",
                    message: "Saved app configuration.",
                    metadata: [
                        "logLevel": config.logLevel.rawValue,
                        "debugLogging": "\(config.debugLogging)",
                    ]
                )
            )
        } catch {
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "state",
                    operation: "state.saveConfig",
                    message: "Failed saving app configuration.",
                    errorCategory: .stateStoreFailure,
                    errorMessage: error.localizedDescription
                )
            )
            throw error
        }
    }

    public func loadState() async -> SyncState {
        do {
            return try store.loadState()
        } catch {
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "state",
                    operation: "state.loadState",
                    message: "Failed loading sync state. Returning empty state.",
                    errorCategory: .stateStoreFailure,
                    errorMessage: error.localizedDescription
                )
            )
            return SyncState()
        }
    }

    public func saveState(_ state: SyncState) async throws {
        do {
            try store.saveState(state)
        } catch {
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "state",
                    operation: "state.saveState",
                    message: "Failed saving sync state.",
                    errorCategory: .stateStoreFailure,
                    errorMessage: error.localizedDescription
                )
            )
            throw error
        }
    }

    public func loadLastRunSnapshot() async -> LastRunSnapshot? {
        await diagnostics.loadLastRunSnapshot()
    }

    public func loadCrashContext() async -> RunContext? {
        await diagnostics.loadCrashContext()
    }

    public func latestLogFileURL() async -> URL? {
        await diagnostics.latestLogFileURL()
    }

    public func diagnosticsDirectoryURL() async -> URL {
        await diagnostics.diagnosticsDirectoryURL()
    }

    public func buildDiagnosticsSummary(currentStatus: String) async -> DiagnosticsSummary {
        let config = await loadConfig()
        let state = await loadState()
        return await diagnostics.buildDiagnosticsSummary(
            config: config,
            state: state,
            currentStatus: currentStatus,
            appVersion: RuntimeEnvironment.appVersion()
        )
    }

    public func logAppEvent(
        level: LogLevel,
        operation: String,
        message: String,
        category: FailureCategory? = nil,
        metadata: [String: String]? = nil
    ) async {
        await diagnostics.log(
            SyncEvent(
                level: level,
                subsystem: "app",
                operation: operation,
                message: message,
                errorCategory: category,
                errorMessage: category == nil ? nil : message,
                metadata: metadata
            )
        )
    }

    public func recentEvents(limit: Int) async -> [SyncEvent] {
        await diagnostics.loadRecentEvents(limit: limit)
    }

    public func runSync(
        config: AppConfig,
        trigger: SyncTrigger,
        progress: @Sendable (SyncProgressUpdate) async -> Void = { _ in }
    ) async -> SyncRunReport {
        await diagnostics.updateConfig(config)

        let startedAt = Date()
        let runContext = RunContext(
            runID: UUID().uuidString,
            trigger: trigger,
            startedAt: startedAt,
            appVersion: RuntimeEnvironment.appVersion(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )

        await diagnostics.setCrashContext(runContext)
        await diagnostics.log(
            SyncEvent(
                level: .info,
                subsystem: "sync",
                operation: "sync.run.start",
                runID: runContext.runID,
                trigger: runContext.trigger,
                message: "\(trigger.displayName) sync started.",
                metadata: [
                    "profile": config.providerProfile.rawValue,
                    "prefix": config.materializedPrefix,
                ]
            )
        )
        await progress(
            SyncProgressUpdate(
                runID: runContext.runID,
                stage: .starting,
                message: "\(trigger.displayName) sync starting…",
                processedPlaylistCount: 0
            )
        )

        var processedPlaylistCount = 0
        var writtenTrackCount = 0
        var rebuiltPlaylistPartCount = 0
        let addedTrackCount = 0
        let removedTrackCount = 0
        var createdPlaylistCount = 0
        var deletedPlaylistCount = 0
        var renamedPlaylistCount = 0
        var failures: [SyncFailure] = []
        var lastCompletedStep: String?
        var state = SyncState()

        do {
            state = try store.loadState()
        } catch {
            let failure = makeFailure(
                playlistName: "State",
                operation: "state.loadState",
                error: error
            )
            failures.append(failure)
            let report = SyncRunReport(
                runID: runContext.runID,
                trigger: trigger,
                startedAt: startedAt,
                finishedAt: Date(),
                processedPlaylistCount: 0,
                writtenTrackCount: 0,
                rebuiltPlaylistPartCount: 0,
                addedTrackCount: 0,
                removedTrackCount: 0,
                createdPlaylistCount: 0,
                deletedPlaylistCount: 0,
                renamedPlaylistCount: 0,
                failures: failures
            )
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "state",
                    operation: "state.loadState",
                    runID: runContext.runID,
                    trigger: trigger,
                    message: failure.message,
                    errorCategory: failure.category,
                    errorMessage: failure.underlyingMessage
                )
            )
            await finalizeRun(report: report, config: config, progress: progress, lastCompletedStep: lastCompletedStep)
            return report
        }

        await progress(
            SyncProgressUpdate(
                runID: runContext.runID,
                stage: .discoveringPlaylists,
                message: "Discovering smart playlists…",
                lastCompletedStep: lastCompletedStep,
                processedPlaylistCount: processedPlaylistCount
            )
        )

        let discoveredSmartPlaylists: [PlaylistSnapshot]
        do {
            discoveredSmartPlaylists = try await musicClient.listSmartPlaylistMetadata(runContext: runContext)
        } catch {
            let failure = makeFailure(
                playlistName: "Library",
                operation: "music.listSmartPlaylistMetadata",
                error: error
            )
            failures.append(failure)
            let report = SyncRunReport(
                runID: runContext.runID,
                trigger: trigger,
                startedAt: startedAt,
                finishedAt: Date(),
                processedPlaylistCount: 0,
                writtenTrackCount: 0,
                rebuiltPlaylistPartCount: 0,
                addedTrackCount: 0,
                removedTrackCount: 0,
                createdPlaylistCount: 0,
                deletedPlaylistCount: 0,
                renamedPlaylistCount: 0,
                failures: failures
            )
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "sync",
                    operation: "sync.discoverPlaylists",
                    runID: runContext.runID,
                    trigger: trigger,
                    message: failure.message,
                    errorCategory: failure.category,
                    errorMessage: failure.underlyingMessage
                )
            )
            await finalizeRun(report: report, config: config, progress: progress, lastCompletedStep: lastCompletedStep)
            return report
        }

        let playlistEvaluation = SyncPlanner.evaluateSmartPlaylists(
            from: discoveredSmartPlaylists,
            includeSystemPlaylists: config.includeSystemSmartPlaylists,
            exclusionRules: config.sourcePlaylistExclusions,
            allowedSourcePlaylistNames: config.allowedSourcePlaylistNames
        )

        let sourcePlaylistMetadata = playlistEvaluation.included.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if playlistEvaluation.excludedByRules.isEmpty == false {
            let excludedNames = playlistEvaluation.excludedByRules
                .prefix(10)
                .map(\.name)
                .joined(separator: ", ")
            await diagnostics.log(
                SyncEvent(
                    level: .info,
                    subsystem: "sync",
                    operation: "sync.excludePlaylists",
                    runID: runContext.runID,
                    trigger: trigger,
                    message: "Skipping \(playlistEvaluation.excludedByRules.count) smart playlist(s) due to exclusion rules.",
                    metadata: [
                        "playlistCount": "\(playlistEvaluation.excludedByRules.count)",
                        "playlistNames": excludedNames,
                    ]
                )
            )
        }

        if playlistEvaluation.excludedByAllowlist.isEmpty == false {
            let excludedNames = playlistEvaluation.excludedByAllowlist
                .prefix(10)
                .map(\.name)
                .joined(separator: ", ")
            await diagnostics.log(
                SyncEvent(
                    level: .info,
                    subsystem: "sync",
                    operation: "sync.allowlistPlaylists",
                    runID: runContext.runID,
                    trigger: trigger,
                    message: "Skipping \(playlistEvaluation.excludedByAllowlist.count) smart playlist(s) due to the source allowlist.",
                    metadata: [
                        "playlistCount": "\(playlistEvaluation.excludedByAllowlist.count)",
                        "playlistNames": excludedNames,
                    ]
                )
            )
        }

        await diagnostics.log(
            SyncEvent(
                level: .info,
                subsystem: "sync",
                operation: "sync.discoverPlaylists",
                runID: runContext.runID,
                trigger: trigger,
                message: "Ready to reconcile \(sourcePlaylistMetadata.count) smart playlists.",
                metadata: [
                    "playlistCount": "\(sourcePlaylistMetadata.count)",
                    "excludedByRuleCount": "\(playlistEvaluation.excludedByRules.count)",
                    "excludedByAllowlistCount": "\(playlistEvaluation.excludedByAllowlist.count)",
                    "excludedBySystemCount": "\(playlistEvaluation.excludedBySystemFilter.count)",
                ]
            )
        )

        for sourceMetadata in sourcePlaylistMetadata {
            await progress(
                SyncProgressUpdate(
                    runID: runContext.runID,
                    stage: .discoveringPlaylists,
                    message: "Loading \(sourceMetadata.name)…",
                    lastCompletedStep: lastCompletedStep,
                    currentPlaylistName: sourceMetadata.name,
                    processedPlaylistCount: processedPlaylistCount
                )
            )

            let source: PlaylistSnapshot
            do {
                source = try await musicClient.snapshotUserPlaylist(
                    persistentID: sourceMetadata.persistentID,
                    runContext: runContext,
                    sourcePlaylistName: sourceMetadata.name
                )
            } catch {
                let failure = makeFailure(
                    playlistName: sourceMetadata.name,
                    operation: "music.snapshotUserPlaylist",
                    error: error,
                    sourcePlaylistPersistentID: sourceMetadata.persistentID
                )
                failures.append(failure)
                await diagnostics.log(
                    SyncEvent(
                        level: .error,
                        subsystem: "sync",
                        operation: "sync.snapshotSourcePlaylist",
                        runID: runContext.runID,
                        trigger: trigger,
                        message: failure.message,
                        sourcePlaylistName: sourceMetadata.name,
                        sourcePlaylistPersistentID: sourceMetadata.persistentID,
                        errorCategory: failure.category,
                        errorMessage: failure.underlyingMessage
                    )
                )
                processedPlaylistCount += 1
                continue
            }

            var managed = state.managedPlaylists[source.persistentID] ?? ManagedPlaylistState(
                sourcePersistentID: source.persistentID,
                sourceName: source.name
            )
            managed.sourceName = source.name
            managed.lastRunID = runContext.runID

            await progress(
                SyncProgressUpdate(
                    runID: runContext.runID,
                    stage: .reconcilingPlaylist,
                    message: "Reconciling \(source.name)…",
                    lastCompletedStep: lastCompletedStep,
                    currentPlaylistName: source.name,
                    processedPlaylistCount: processedPlaylistCount
                )
            )

            await diagnostics.log(
                SyncEvent(
                    level: .info,
                    subsystem: "sync",
                    operation: "sync.reconcilePlaylist",
                    runID: runContext.runID,
                    trigger: trigger,
                    message: "Reconciling smart playlist.",
                    sourcePlaylistName: source.name,
                    sourcePlaylistPersistentID: source.persistentID,
                    trackCount: source.trackPersistentIDs.count
                )
            )

            do {
                let desiredChunks = SyncPlanner.chunkedTrackIDs(
                    source.trackPersistentIDs,
                    limit: config.providerProfile.trackLimit
                )
                let desiredNames = SyncPlanner.materializedPlaylistNames(
                    prefix: config.materializedPrefix,
                    sourceName: source.name,
                    partCount: desiredChunks.count
                )
                let sourceFingerprint = fingerprint(for: source, desiredNames: desiredNames)
                let sourceHasChanged = managed.lastSourceFingerprint != sourceFingerprint
                    || managed.parts.count != desiredNames.count

                var updatedParts: [ManagedPlaylistPart] = []
                var nextSourceTrackStartIndex = 1

                for (index, trackChunk) in desiredChunks.enumerated() {
                    let desiredName = desiredNames[index]
                    let sourceTrackStartIndex = nextSourceTrackStartIndex
                    let sourceTrackEndIndex = sourceTrackStartIndex + trackChunk.count - 1
                    let existingPart = managed.parts.first { $0.index == index }
                    var targetPersistentID: String
                    var shouldReplaceContents = sourceHasChanged
                    var rebuildMode: String? = sourceHasChanged ? "sourceChanged" : nil

                    if let existingPart {
                        do {
                            let currentTargetName = try await musicClient.playlistName(
                                persistentID: existingPart.targetPersistentID,
                                runContext: runContext,
                                sourcePlaylistName: source.name,
                                targetPlaylistName: existingPart.targetName
                            )
                            if currentTargetName != desiredName {
                                try await musicClient.renamePlaylist(
                                    persistentID: existingPart.targetPersistentID,
                                    newName: desiredName,
                                    runContext: runContext,
                                    sourcePlaylistName: source.name
                                )
                                renamedPlaylistCount += 1
                            }
                            targetPersistentID = existingPart.targetPersistentID
                        } catch {
                            let targetCreationCategory = recoveryCategory(for: error)
                            guard targetCreationCategory == .playlistLookupFailed else {
                                throw error
                            }

                            targetPersistentID = try await musicClient.createUserPlaylist(
                                named: desiredName,
                                runContext: runContext,
                                sourcePlaylistName: source.name
                            )
                            createdPlaylistCount += 1
                            shouldReplaceContents = true
                            rebuildMode = "recreatedMissingTarget"

                            await diagnostics.log(
                                SyncEvent(
                                    level: .warning,
                                    subsystem: "sync",
                                    operation: "sync.recreateMissingTarget",
                                    runID: runContext.runID,
                                    trigger: trigger,
                                    message: "Managed target lookup failed; creating a fresh materialized playlist.",
                                    sourcePlaylistName: source.name,
                                    sourcePlaylistPersistentID: source.persistentID,
                                    targetPlaylistName: desiredName,
                                    targetPlaylistPersistentID: targetPersistentID,
                                    partIndex: index,
                                    totalParts: desiredChunks.count,
                                    trackCount: trackChunk.count,
                                    errorCategory: targetCreationCategory,
                                    errorMessage: recoveryMessage(for: error),
                                    metadata: [
                                        "recovery": "createNewTarget",
                                    ]
                                )
                            )
                        }
                    } else {
                        targetPersistentID = try await musicClient.createUserPlaylist(
                            named: desiredName,
                            runContext: runContext,
                            sourcePlaylistName: source.name
                        )
                        createdPlaylistCount += 1
                        shouldReplaceContents = true
                        rebuildMode = "newPart"
                    }

                    if shouldReplaceContents {
                        try await musicClient.replacePlaylistContents(
                            sourcePlaylistPersistentID: source.persistentID,
                            targetPlaylistPersistentID: targetPersistentID,
                            sourceTrackStartIndex: sourceTrackStartIndex,
                            sourceTrackEndIndex: sourceTrackEndIndex,
                            desiredTrackIDs: trackChunk,
                            runContext: runContext,
                            sourcePlaylistName: source.name,
                            targetPlaylistName: desiredName,
                            partIndex: index,
                            totalParts: desiredChunks.count
                        )
                        writtenTrackCount += trackChunk.count
                        rebuiltPlaylistPartCount += 1
                    }

                    var reconcileMetadata: [String: String] = [:]
                    if let rebuildMode {
                        reconcileMetadata["rebuildMode"] = rebuildMode
                    }

                    await diagnostics.log(
                        SyncEvent(
                            level: .info,
                            subsystem: "sync",
                            operation: "sync.reconcilePart",
                            runID: runContext.runID,
                            trigger: trigger,
                            message: rebuildMode == nil
                                ? "Reconciled materialized playlist part."
                                : "Rebuilt materialized playlist part.",
                            sourcePlaylistName: source.name,
                            sourcePlaylistPersistentID: source.persistentID,
                            targetPlaylistName: desiredName,
                            targetPlaylistPersistentID: targetPersistentID,
                            partIndex: index,
                            totalParts: desiredChunks.count,
                            trackCount: trackChunk.count,
                            writtenTrackCount: shouldReplaceContents ? trackChunk.count : 0,
                            rebuiltPlaylistPartCount: shouldReplaceContents ? 1 : 0,
                            metadata: reconcileMetadata.isEmpty ? nil : reconcileMetadata
                        )
                    )

                    updatedParts.append(
                        ManagedPlaylistPart(
                            index: index,
                            targetPersistentID: targetPersistentID,
                            targetName: desiredName
                        )
                    )

                    nextSourceTrackStartIndex = sourceTrackEndIndex + 1
                }

                let staleParts = managed.parts.filter { oldPart in
                    updatedParts.contains(where: { $0.index == oldPart.index }) == false
                }

                if config.deleteStaleManagedPlaylists && !staleParts.isEmpty {
                    await progress(
                        SyncProgressUpdate(
                            runID: runContext.runID,
                            stage: .deletingStalePlaylists,
                            message: "Deleting stale materialized playlists for \(source.name)…",
                            lastCompletedStep: lastCompletedStep,
                            currentPlaylistName: source.name,
                            processedPlaylistCount: processedPlaylistCount
                        )
                    )
                }

                if config.deleteStaleManagedPlaylists {
                    for stalePart in staleParts {
                        do {
                            try await musicClient.deletePlaylist(
                                persistentID: stalePart.targetPersistentID,
                                runContext: runContext,
                                sourcePlaylistName: source.name,
                                targetPlaylistName: stalePart.targetName
                            )
                            deletedPlaylistCount += 1
                        } catch {
                            let failure = makeFailure(
                                playlistName: stalePart.targetName,
                                operation: "music.deletePlaylist",
                                error: error,
                                sourcePlaylistPersistentID: source.persistentID,
                                targetPlaylistPersistentID: stalePart.targetPersistentID,
                                targetPlaylistName: stalePart.targetName
                            )
                            failures.append(failure)
                            await diagnostics.log(
                                SyncEvent(
                                    level: .error,
                                    subsystem: "sync",
                                    operation: "sync.deleteStalePart",
                                    runID: runContext.runID,
                                    trigger: trigger,
                                    message: failure.message,
                                    sourcePlaylistName: source.name,
                                    sourcePlaylistPersistentID: source.persistentID,
                                    targetPlaylistName: stalePart.targetName,
                                    targetPlaylistPersistentID: stalePart.targetPersistentID,
                                    errorCategory: failure.category,
                                    errorMessage: failure.underlyingMessage
                                )
                            )
                        }
                    }
                }

                managed.parts = updatedParts.sorted { $0.index < $1.index }
                managed.lastSourceFingerprint = sourceFingerprint
                managed.lastSyncedAt = Date()
                managed.lastError = nil
                managed.lastFailureCategory = nil
                managed.lastRunID = runContext.runID
                state.managedPlaylists[source.persistentID] = managed

                lastCompletedStep = "Reconciled \(source.name)"
                await diagnostics.log(
                    SyncEvent(
                        level: .info,
                        subsystem: "sync",
                        operation: "sync.reconcilePlaylist",
                        runID: runContext.runID,
                        trigger: trigger,
                        message: "Finished reconciling smart playlist.",
                        sourcePlaylistName: source.name,
                        sourcePlaylistPersistentID: source.persistentID,
                        trackCount: source.trackPersistentIDs.count,
                        metadata: ["parts": "\(updatedParts.count)"]
                    )
                )
            } catch {
                let failure = makeFailure(
                    playlistName: source.name,
                    operation: "sync.reconcilePlaylist",
                    error: error,
                    sourcePlaylistPersistentID: source.persistentID
                )
                managed.lastError = failure.message
                managed.lastFailureCategory = failure.category
                managed.lastRunID = runContext.runID
                state.managedPlaylists[source.persistentID] = managed
                failures.append(failure)
                lastCompletedStep = "Failed \(source.name)"

                await diagnostics.log(
                    SyncEvent(
                        level: .error,
                        subsystem: "sync",
                        operation: "sync.reconcilePlaylist",
                        runID: runContext.runID,
                        trigger: trigger,
                        message: failure.message,
                        sourcePlaylistName: source.name,
                        sourcePlaylistPersistentID: source.persistentID,
                        errorCategory: failure.category,
                        errorMessage: failure.underlyingMessage
                    )
                )
            }

            do {
                try store.saveState(state)
            } catch {
                let checkpointFailure = makeFailure(
                    playlistName: source.name,
                    operation: "state.saveCheckpoint",
                    error: error
                )
                failures.append(checkpointFailure)
                await diagnostics.log(
                    SyncEvent(
                        level: .error,
                        subsystem: "state",
                        operation: "state.saveCheckpoint",
                        runID: runContext.runID,
                        trigger: trigger,
                        message: checkpointFailure.message,
                        sourcePlaylistName: source.name,
                        errorCategory: checkpointFailure.category,
                        errorMessage: checkpointFailure.underlyingMessage
                    )
                )
            }
            processedPlaylistCount += 1
        }

        let liveSourceIDs = playlistEvaluation.protectedSourceIDs
        let staleSourceIDs = state.managedPlaylists.keys.filter { !liveSourceIDs.contains($0) }
        if config.deleteStaleManagedPlaylists && !staleSourceIDs.isEmpty {
            await progress(
                SyncProgressUpdate(
                    runID: runContext.runID,
                    stage: .deletingStalePlaylists,
                    message: "Deleting orphaned materialized playlists…",
                    lastCompletedStep: lastCompletedStep,
                    processedPlaylistCount: processedPlaylistCount
                )
            )
        }

        for staleSourceID in staleSourceIDs {
            guard let staleManaged = state.managedPlaylists[staleSourceID] else {
                continue
            }

            var encounteredDeletionFailure = false
            if config.deleteStaleManagedPlaylists {
                for part in staleManaged.parts {
                    do {
                        try await musicClient.deletePlaylist(
                            persistentID: part.targetPersistentID,
                            runContext: runContext,
                            sourcePlaylistName: staleManaged.sourceName,
                            targetPlaylistName: part.targetName
                        )
                        deletedPlaylistCount += 1
                    } catch {
                        encounteredDeletionFailure = true
                        let failure = makeFailure(
                            playlistName: staleManaged.sourceName,
                            operation: "music.deletePlaylist",
                            error: error,
                            sourcePlaylistPersistentID: staleManaged.sourcePersistentID,
                            targetPlaylistPersistentID: part.targetPersistentID,
                            targetPlaylistName: part.targetName
                        )
                        failures.append(failure)
                        await diagnostics.log(
                            SyncEvent(
                                level: .error,
                                subsystem: "sync",
                                operation: "sync.deleteOrphanedPlaylist",
                                runID: runContext.runID,
                                trigger: trigger,
                                message: failure.message,
                                sourcePlaylistName: staleManaged.sourceName,
                                sourcePlaylistPersistentID: staleManaged.sourcePersistentID,
                                targetPlaylistName: part.targetName,
                                targetPlaylistPersistentID: part.targetPersistentID,
                                errorCategory: failure.category,
                                errorMessage: failure.underlyingMessage
                            )
                        )
                    }
                }
            }

            if config.deleteStaleManagedPlaylists {
                if encounteredDeletionFailure {
                    var updatedManaged = staleManaged
                    updatedManaged.lastError = "Failed deleting one or more orphaned materialized playlists."
                    updatedManaged.lastFailureCategory = .unknown
                    updatedManaged.lastRunID = runContext.runID
                    state.managedPlaylists[staleSourceID] = updatedManaged
                } else {
                    state.managedPlaylists.removeValue(forKey: staleSourceID)
                }
            } else {
                state.managedPlaylists.removeValue(forKey: staleSourceID)
            }
        }

        await progress(
            SyncProgressUpdate(
                runID: runContext.runID,
                stage: .savingState,
                message: "Saving sync state…",
                lastCompletedStep: lastCompletedStep,
                processedPlaylistCount: processedPlaylistCount
            )
        )

        do {
            try store.saveState(state)
        } catch {
            let failure = makeFailure(
                playlistName: "State",
                operation: "state.saveState",
                error: error
            )
            failures.append(failure)
            await diagnostics.log(
                SyncEvent(
                    level: .error,
                    subsystem: "state",
                    operation: "state.saveState",
                    runID: runContext.runID,
                    trigger: trigger,
                    message: failure.message,
                    errorCategory: failure.category,
                    errorMessage: failure.underlyingMessage
                )
            )
        }

        let report = SyncRunReport(
            runID: runContext.runID,
            trigger: trigger,
            startedAt: startedAt,
            finishedAt: Date(),
            processedPlaylistCount: processedPlaylistCount,
            writtenTrackCount: writtenTrackCount,
            rebuiltPlaylistPartCount: rebuiltPlaylistPartCount,
            addedTrackCount: addedTrackCount,
            removedTrackCount: removedTrackCount,
            createdPlaylistCount: createdPlaylistCount,
            deletedPlaylistCount: deletedPlaylistCount,
            renamedPlaylistCount: renamedPlaylistCount,
            failures: failures
        )

        await finalizeRun(report: report, config: config, progress: progress, lastCompletedStep: lastCompletedStep)
        return report
    }

    private func finalizeRun(
        report: SyncRunReport,
        config: AppConfig,
        progress: @Sendable (SyncProgressUpdate) async -> Void,
        lastCompletedStep: String?
    ) async {
        await diagnostics.saveLastRunSnapshot(LastRunSnapshot(report: report, config: config))
        await diagnostics.clearCrashContext()
        await diagnostics.log(
            SyncEvent(
                level: report.failures.isEmpty ? .info : .warning,
                subsystem: "sync",
                operation: "sync.run.finish",
                runID: report.runID,
                trigger: report.trigger,
                message: report.failures.isEmpty ? "Sync run completed successfully." : "Sync run completed with \(report.failures.count) issue(s).",
                writtenTrackCount: report.writtenTrackCount,
                rebuiltPlaylistPartCount: report.rebuiltPlaylistPartCount,
                addedTrackCount: report.addedTrackCount,
                removedTrackCount: report.removedTrackCount,
                durationMilliseconds: report.durationMilliseconds,
                metadata: [
                    "processedPlaylistCount": "\(report.processedPlaylistCount)",
                    "failureCount": "\(report.failures.count)",
                    "writtenTrackCount": "\(report.writtenTrackCount)",
                    "rebuiltPlaylistPartCount": "\(report.rebuiltPlaylistPartCount)",
                ]
            )
        )
        await progress(
            SyncProgressUpdate(
                runID: report.runID,
                stage: report.failures.isEmpty ? .completed : .failed,
                message: report.failures.isEmpty ? "Sync completed." : "Sync completed with \(report.failures.count) issue(s).",
                lastCompletedStep: lastCompletedStep,
                processedPlaylistCount: report.processedPlaylistCount
            )
        )
    }

    private func makeFailure(
        playlistName: String,
        operation: String,
        error: Error,
        sourcePlaylistPersistentID: String? = nil,
        targetPlaylistPersistentID: String? = nil,
        targetPlaylistName: String? = nil
    ) -> SyncFailure {
        if let osaScriptError = error as? OsaScriptError {
            return SyncFailure(
                playlistName: playlistName,
                message: osaScriptError.message,
                category: osaScriptError.category,
                operation: operation,
                sourcePlaylistPersistentID: sourcePlaylistPersistentID,
                targetPlaylistPersistentID: targetPlaylistPersistentID,
                targetPlaylistName: targetPlaylistName,
                underlyingMessage: osaScriptError.message
            )
        }

        return SyncFailure(
            playlistName: playlistName,
            message: error.localizedDescription,
            category: FailureCategory.classify(message: error.localizedDescription, operation: operation),
            operation: operation,
            sourcePlaylistPersistentID: sourcePlaylistPersistentID,
            targetPlaylistPersistentID: targetPlaylistPersistentID,
            targetPlaylistName: targetPlaylistName,
            underlyingMessage: error.localizedDescription
        )
    }

    private func recoveryCategory(for error: Error) -> FailureCategory {
        switch error {
        case let error as OsaScriptError:
            return error.category
        case _ as OsaScriptTimeoutError:
            return .appleScriptExecutionFailed
        default:
            return FailureCategory.classify(message: error.localizedDescription)
        }
    }

    private func recoveryMessage(for error: Error) -> String {
        switch error {
        case let error as OsaScriptError:
            return error.message
        case let error as OsaScriptTimeoutError:
            return error.message
        default:
            return error.localizedDescription
        }
    }

    private func fingerprint(for source: PlaylistSnapshot, desiredNames: [String]) -> String {
        let payload = ([source.name, source.persistentID] + desiredNames + source.trackPersistentIDs)
            .joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
