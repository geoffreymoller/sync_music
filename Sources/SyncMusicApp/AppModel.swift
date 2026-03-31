import AppKit
import Foundation
import ServiceManagement
import SyncMusicCore

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig
    @Published var draftConfig: AppConfig
    @Published var hasPendingConfigChanges = false
    @Published var managedPlaylists: [ManagedPlaylistState] = []
    @Published var statusText = "Idle"
    @Published var currentStepText = "No sync running."
    @Published var lastCompletedStepText = "No completed steps yet."
    @Published var lastReport: SyncRunReport?
    @Published var recentFailures: [SyncFailure] = []
    @Published var isSyncing = false
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginError: String?
    @Published var activeRunID: String?
    @Published var activeRunTrigger: SyncTrigger?
    @Published var activeRunStartedAt: Date?
    @Published var activeProgressStage: SyncProgressStage?
    @Published var activeProcessedPlaylistCount = 0
    @Published var activeCurrentPlaylistName: String?

    private let engine: SyncEngine
    private var currentState = SyncState()
    private var schedulerTask: Task<Void, Never>?
    private var hasStarted = false
    private var wakeObserver: NSObjectProtocol?
    private var clockChangeObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?

    init() {
        let diagnostics = DiagnosticsLogger()
        self.engine = SyncEngine(diagnostics: diagnostics)
        let initialConfig = AppConfig()
        self.config = initialConfig
        self.draftConfig = initialConfig
    }

    func startIfNeeded() {
        guard hasStarted == false else {
            return
        }
        hasStarted = true
        Task {
            let loadedConfig = await engine.loadConfig()
            let loadedState = await engine.loadState()
            let lastSnapshot = await engine.loadLastRunSnapshot()
            let crashContext = await engine.loadCrashContext()

            config = loadedConfig
            draftConfig = loadedConfig
            hasPendingConfigChanges = false
            applyState(loadedState)
            lastReport = lastSnapshot?.report
            recentFailures = Array(lastSnapshot?.report.failures.prefix(5) ?? [])

            if let lastSnapshot {
                statusText = lastSnapshot.report.failures.isEmpty
                    ? "Last sync completed successfully."
                    : "Last sync completed with \(lastSnapshot.report.failures.count) issue(s)."
                lastCompletedStepText = "Last run finished at \(lastSnapshot.report.finishedAt.formatted(date: .abbreviated, time: .shortened))."
            }

            if let crashContext {
                currentStepText = "Recovered unfinished \(crashContext.trigger.displayName.lowercased()) sync \(crashContext.runID.suffix(8))."
            }

            refreshLaunchAtLoginState()
            installSchedulerObserversIfNeeded()
            restartScheduler(runStartupSync: true)
        }
    }

    func syncNow() {
        Task {
            await runSync(trigger: .manual, reason: "Manual sync")
        }
    }

    func updateDraftConfig(_ mutate: (inout AppConfig) -> Void) {
        mutate(&draftConfig)
        hasPendingConfigChanges = draftConfig != config
    }

    func addDraftExclusionRule() {
        updateDraftConfig {
            $0.sourcePlaylistExclusions.append(PlaylistExclusionRule(value: ""))
        }
    }

    func applyConfigChanges() {
        let normalized = normalizedConfig(from: draftConfig)
        let previousConfig = config
        draftConfig = normalized

        guard normalized != previousConfig else {
            hasPendingConfigChanges = false
            statusText = "No settings changes to apply."
            return
        }

        Task {
            do {
                try await engine.saveConfig(normalized)
                config = normalized
                hasPendingConfigChanges = false

                if normalized.autoSyncSchedule != previousConfig.autoSyncSchedule {
                    restartScheduler(runStartupSync: false)
                }

                statusText = "Saved settings."
            } catch {
                hasPendingConfigChanges = true
                statusText = "Failed saving config: \(error.localizedDescription)"
            }
        }
    }

    func revertConfigChanges() {
        draftConfig = config
        hasPendingConfigChanges = false
        statusText = "Reverted pending settings."
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            launchAtLoginError = "Launch at Login requires macOS 13 or later."
            Task {
                await engine.logAppEvent(
                    level: .error,
                    operation: "app.launchAtLogin",
                    message: launchAtLoginError ?? "Launch at login is unavailable.",
                    category: .launchAtLoginFailure
                )
            }
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = enabled
            launchAtLoginError = nil

            Task {
                await engine.logAppEvent(
                    level: .info,
                    operation: "app.launchAtLogin",
                    message: enabled ? "Enabled launch at login." : "Disabled launch at login."
                )
            }
        } catch {
            launchAtLoginError = error.localizedDescription
            refreshLaunchAtLoginState()

            Task {
                await engine.logAppEvent(
                    level: .error,
                    operation: "app.launchAtLogin",
                    message: error.localizedDescription,
                    category: .launchAtLoginFailure
                )
            }
        }
    }

    func openDiagnosticsFolder() {
        Task {
            let url = await engine.diagnosticsDirectoryURL()
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func viewLogs() {
        Task {
            let logURL = await engine.latestLogFileURL()
            let diagnosticsURL = await engine.diagnosticsDirectoryURL()
            let url = logURL ?? diagnosticsURL
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func copyDiagnosticsSummary() {
        Task {
            let summary = await engine.buildDiagnosticsSummary(currentStatus: statusText)
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(summary.text, forType: .string)
                statusText = "Diagnostics summary copied."
            }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    var menuBarTitle: String {
        if isSyncing {
            return "SyncMusic…"
        }
        return "SyncMusic"
    }

    var menuBarSymbolName: String {
        if isSyncing {
            return "arrow.trianglehead.2.clockwise"
        }
        if !recentFailures.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        return "music.note.list"
    }

    var activeRunSummaryTitle: String {
        let runLabel = activeRunID.map { "Run \($0.suffix(8))" } ?? "Run Starting"
        let triggerLabel = activeRunTrigger?.displayName ?? "Sync"
        return "\(runLabel) • \(triggerLabel)"
    }

    var menuStatusHeadline: String {
        if isSyncing {
            let triggerLabel = activeRunTrigger?.displayName ?? "Sync"
            return "\(triggerLabel) sync in progress"
        }

        if let lastReport {
            return lastReport.failures.isEmpty ? "Last sync succeeded" : "Last sync had issues"
        }

        return "Ready to sync"
    }

    var menuStatusSubtitle: String {
        if isSyncing {
            return activeRunStartedAt.map { "Started \($0.formatted(date: .omitted, time: .shortened))" }
                ?? "Preparing sync"
        }

        if let lastReport {
            return "Updated \(lastReport.finishedAt.formatted(date: .abbreviated, time: .shortened))"
        }

        return "No sync completed yet"
    }

    var menuActiveRunTitle: String {
        let triggerLabel = activeRunTrigger?.displayName ?? "Sync"
        return "\(triggerLabel) Sync"
    }

    var menuActiveRunSubtitle: String {
        activeRunStartedAt.map { "Started \($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "Starting now"
    }

    var menuActiveRunMetrics: String {
        let playlistLabel = activeProcessedPlaylistCount == 1 ? "playlist" : "playlists"
        return "\(activeProcessedPlaylistCount) \(playlistLabel) processed"
    }

    var menuLastRunTitle: String {
        guard let lastReport else {
            return "No completed sync yet"
        }

        return "Last \(lastReport.trigger.displayName) Sync"
    }

    var menuLastRunSubtitle: String {
        guard let lastReport else {
            return "Run Sync Now to create your first mirror."
        }

        return lastReport.finishedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var menuLastRunMetrics: String {
        guard let lastReport else {
            return "No playlists processed"
        }

        let playlistLabel = lastReport.processedPlaylistCount == 1 ? "playlist" : "playlists"
        return "\(lastReport.processedPlaylistCount) \(playlistLabel) in \(formattedDuration(milliseconds: lastReport.durationMilliseconds))"
    }

    var menuLastRunDetail: String? {
        guard let lastReport else {
            return nil
        }

        if lastReport.failures.isEmpty {
            return "Healthy"
        }

        let issueLabel = lastReport.failures.count == 1 ? "issue" : "issues"
        return "\(lastReport.failures.count) \(issueLabel)"
    }

    var menuHealthSummary: String? {
        guard recentFailures.isEmpty == false else {
            return nil
        }

        if recentFailures.count == 1, let failure = recentFailures.first {
            return "1 recent failure in \(failure.playlistName)"
        }

        return "\(recentFailures.count) recent failures. Open logs for details."
    }

    var activeRunStartedText: String? {
        activeRunStartedAt.map {
            "Started \($0.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    var activeRunProgressText: String {
        "Processed \(activeProcessedPlaylistCount) playlists so far"
    }

    var activeRunPlaylistText: String? {
        guard let activeCurrentPlaylistName else {
            return nil
        }

        switch activeProgressStage {
        case .discoveringPlaylists:
            return "Loading \(activeCurrentPlaylistName)"
        case .reconcilingPlaylist:
            return "Current: \(activeCurrentPlaylistName)"
        case .deletingStalePlaylists:
            return "Cleaning \(activeCurrentPlaylistName)"
        default:
            return nil
        }
    }

    private func restartScheduler(runStartupSync: Bool) {
        schedulerTask?.cancel()
        schedulerTask = Task {
            if runStartupSync {
                await runSync(trigger: .startup, reason: "Startup sync")
            }

            while !Task.isCancelled {
                switch config.autoSyncSchedule.normalized {
                case .interval(let minutes):
                    try? await Task.sleep(for: .seconds(TimeInterval(minutes * 60)))
                    guard !Task.isCancelled else {
                        break
                    }
                    await runSync(trigger: .scheduled, reason: "Scheduled sync")
                case .daily:
                    let evaluation = config.autoSyncSchedule.evaluate(
                        now: Date(),
                        lastScheduledAttemptAt: currentState.lastScheduledAttemptAt
                    )

                    if evaluation.shouldRunNow {
                        let started = await runSync(
                            trigger: .scheduled,
                            reason: "Daily scheduled sync",
                            scheduledAttemptAt: Date()
                        )

                        if started == false, !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(60))
                        }
                        continue
                    }

                    let secondsUntilCheck = max(1, evaluation.nextCheckAt.timeIntervalSinceNow)
                    try? await Task.sleep(for: .seconds(secondsUntilCheck))
                }
            }
        }
    }

    @discardableResult
    private func runSync(
        trigger: SyncTrigger,
        reason: String,
        scheduledAttemptAt: Date? = nil
    ) async -> Bool {
        guard !isSyncing else { return false }

        if let scheduledAttemptAt {
            let previousAttemptAt = currentState.lastScheduledAttemptAt
            currentState.lastScheduledAttemptAt = scheduledAttemptAt

            do {
                try await engine.saveState(currentState)
            } catch {
                currentState.lastScheduledAttemptAt = previousAttemptAt
                statusText = "Failed scheduling daily sync: \(error.localizedDescription)"
                await engine.logAppEvent(
                    level: .error,
                    operation: "scheduler.recordScheduledAttempt",
                    message: error.localizedDescription,
                    category: .stateStoreFailure
                )
                return false
            }
        }

        beginActiveRun(trigger: trigger)
        isSyncing = true
        statusText = "\(reason) in progress…"
        currentStepText = statusText
        defer {
            clearActiveRun()
            currentStepText = "Idle"
            isSyncing = false
        }

        let report = await engine.runSync(config: config, trigger: trigger) { [weak self] update in
            await MainActor.run {
                self?.activeRunID = update.runID
                self?.activeProgressStage = update.stage
                if let processedPlaylistCount = update.processedPlaylistCount {
                    self?.activeProcessedPlaylistCount = processedPlaylistCount
                }
                self?.activeCurrentPlaylistName = update.currentPlaylistName
                self?.currentStepText = update.message
                if let completedStep = update.lastCompletedStep {
                    self?.lastCompletedStepText = completedStep
                }
            }
        }

        lastReport = report
        recentFailures = Array(report.failures.prefix(5))
        applyState(await engine.loadState())

        if report.failures.isEmpty {
            statusText = "Last sync processed \(report.processedPlaylistCount) smart playlists."
            lastCompletedStepText = "Completed \(trigger.displayName.lowercased()) sync in \(report.durationMilliseconds) ms."
        } else {
            statusText = "Last sync finished with \(report.failures.count) issue(s)."
            lastCompletedStepText = "Completed \(trigger.displayName.lowercased()) sync with issues in \(report.durationMilliseconds) ms."
        }

        return true
    }

    private func refreshLaunchAtLoginState() {
        guard #available(macOS 13.0, *) else {
            launchAtLoginEnabled = false
            return
        }

        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func applyState(_ state: SyncState) {
        currentState = state
        managedPlaylists = state.managedPlaylists.values.sorted {
            $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending
        }
    }

    private func beginActiveRun(trigger: SyncTrigger) {
        activeRunID = nil
        activeRunTrigger = trigger
        activeRunStartedAt = Date()
        activeProgressStage = .starting
        activeProcessedPlaylistCount = 0
        activeCurrentPlaylistName = nil
    }

    private func clearActiveRun() {
        activeRunID = nil
        activeRunTrigger = nil
        activeRunStartedAt = nil
        activeProgressStage = nil
        activeProcessedPlaylistCount = 0
        activeCurrentPlaylistName = nil
    }

    private func normalizedConfig(from candidate: AppConfig) -> AppConfig {
        var normalized = candidate
        normalized.autoSyncSchedule = normalized.autoSyncSchedule.normalized
        if normalized.materializedPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.materializedPrefix = "Sync Mirror"
        }
        return normalized
    }

    private func installSchedulerObserversIfNeeded() {
        guard wakeObserver == nil, clockChangeObserver == nil, dayChangeObserver == nil else {
            return
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSchedulerEnvironmentChange(reason: "Wake")
            }
        }

        clockChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSchedulerEnvironmentChange(reason: "Clock change")
            }
        }

        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSchedulerEnvironmentChange(reason: "Calendar day changed")
            }
        }
    }

    private func handleSchedulerEnvironmentChange(reason: String) {
        guard hasStarted else {
            return
        }

        Task {
            await engine.logAppEvent(
                level: .debug,
                operation: "scheduler.environmentChange",
                message: "\(reason) detected. Re-evaluating auto-sync schedule."
            )
        }
        restartScheduler(runStartupSync: false)
    }

    private func formattedDuration(milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1_000
        if seconds < 1 {
            return "\(milliseconds) ms"
        }

        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }

        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return "\(minutes)m \(remainingSeconds)s"
    }
}
