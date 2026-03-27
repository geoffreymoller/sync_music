import AppKit
import SwiftUI
import SyncMusicCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SyncMusic")
                .font(.headline)

            Text(model.statusText)
                .font(.subheadline.weight(.semibold))

            Text(model.currentStepText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Last completed: \(model.lastCompletedStepText)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if model.isSyncing {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.activeRunSummaryTitle)
                        .font(.caption.weight(.semibold))
                    if let activeRunStartedText = model.activeRunStartedText {
                        Text(activeRunStartedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(model.activeRunProgressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let activeRunPlaylistText = model.activeRunPlaylistText {
                        Text(activeRunPlaylistText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else if let lastReport = model.lastReport {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run \(lastReport.runID.suffix(8)) • \(lastReport.trigger.displayName)")
                        .font(.caption.weight(.semibold))
                    Text(lastReport.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Processed \(lastReport.processedPlaylistCount) playlists in \(lastReport.durationMilliseconds) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Rebuilt \(lastReport.rebuiltPlaylistPartCount) parts • Wrote \(lastReport.writtenTrackCount) tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Playlists +\(lastReport.createdPlaylistCount) / -\(lastReport.deletedPlaylistCount) / rename \(lastReport.renamedPlaylistCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if model.managedPlaylists.isEmpty {
                Text("No managed playlists yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.managedPlaylists.prefix(6)) { playlist in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.sourceName)
                                    .lineLimit(1)
                                if let lastError = playlist.lastError {
                                    Text(lastError)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text("\(playlist.parts.count)")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .font(.caption)
                    }
                }
            }

            if !model.recentFailures.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent failures")
                        .font(.caption.weight(.semibold))
                    ForEach(model.recentFailures) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(failure.category.rawValue)] \(failure.playlistName)")
                                .font(.caption)
                                .bold()
                            Text(failure.message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(model.isSyncing ? "Syncing…" : "Sync Now") {
                        model.syncNow()
                    }
                    .disabled(model.isSyncing)

                    SettingsLink {
                        Text("Settings…")
                    }

                    Spacer()

                    Button("Quit") {
                        model.quit()
                    }
                }

                HStack {
                    Button("View Logs") {
                        model.viewLogs()
                    }

                    Button("Open Diagnostics Folder") {
                        model.openDiagnosticsFolder()
                    }
                }

                Button("Copy Diagnostics Summary") {
                    model.copyDiagnosticsSummary()
                }
            }
        }
        .padding(14)
        .frame(width: 440)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Sync") {
                Picker("Auto Sync", selection: scheduleKindBinding) {
                    ForEach(AutoSyncScheduleKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                switch model.draftConfig.autoSyncSchedule.normalized {
                case .interval:
                    Stepper(value: intervalMinutesBinding, in: 1...1_440) {
                        Text("Interval: \(model.draftConfig.syncIntervalMinutes) min")
                    }
                case .daily:
                    DatePicker(
                        "Daily Time",
                        selection: dailyTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                }

                Text("Schedule: \(model.draftConfig.autoSyncSchedule.displayDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(
                    "Materialized Prefix",
                    text: Binding(
                        get: { model.draftConfig.materializedPrefix },
                        set: { newValue in
                            model.updateDraftConfig { $0.materializedPrefix = newValue }
                        }
                    )
                )

                Picker(
                    "Destination Profile",
                    selection: Binding(
                        get: { model.draftConfig.providerProfile },
                        set: { newValue in
                            model.updateDraftConfig { $0.providerProfile = newValue }
                        }
                    )
                ) {
                    ForEach(ProviderProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }

                Toggle(
                    "Include Apple system smart playlists",
                    isOn: Binding(
                        get: { model.draftConfig.includeSystemSmartPlaylists },
                        set: { newValue in
                            model.updateDraftConfig { $0.includeSystemSmartPlaylists = newValue }
                        }
                    )
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Excluded source playlists")
                        .font(.caption.weight(.semibold))

                    Text("Rules are applied before track retrieval. Matches are exact, case-insensitive, and trim surrounding spaces.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(Array(model.draftConfig.sourcePlaylistExclusions.indices), id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Picker(
                                "Match Type",
                                selection: Binding(
                                    get: { model.draftConfig.sourcePlaylistExclusions[index].matchType },
                                    set: { newValue in
                                        model.updateDraftConfig { config in
                                            guard config.sourcePlaylistExclusions.indices.contains(index) else {
                                                return
                                            }
                                            config.sourcePlaylistExclusions[index].matchType = newValue
                                        }
                                    }
                                )
                            ) {
                                ForEach(PlaylistExclusionMatchType.allCases) { matchType in
                                    Text(matchType.displayName).tag(matchType)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)

                            TextField(
                                "Favorite Songs or Music",
                                text: Binding(
                                    get: { model.draftConfig.sourcePlaylistExclusions[index].value },
                                    set: { newValue in
                                        model.updateDraftConfig { config in
                                            guard config.sourcePlaylistExclusions.indices.contains(index) else {
                                                return
                                            }
                                            config.sourcePlaylistExclusions[index].value = newValue
                                        }
                                    }
                                )
                            )

                            Button {
                                model.updateDraftConfig { config in
                                    guard config.sourcePlaylistExclusions.indices.contains(index) else {
                                        return
                                    }
                                    config.sourcePlaylistExclusions.remove(at: index)
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Remove exclusion rule")
                        }
                    }

                    Button("Add Exclusion Rule") {
                        model.addDraftExclusionRule()
                    }
                }

                Toggle(
                    "Delete stale managed playlists",
                    isOn: Binding(
                        get: { model.draftConfig.deleteStaleManagedPlaylists },
                        set: { newValue in
                            model.updateDraftConfig { $0.deleteStaleManagedPlaylists = newValue }
                        }
                    )
                )
            }

            Section("Diagnostics") {
                Picker(
                    "Log Level",
                    selection: Binding(
                        get: { model.draftConfig.logLevel },
                        set: { newValue in
                            model.updateDraftConfig { $0.logLevel = newValue }
                        }
                    )
                ) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }

                Toggle(
                    "Enable debug logging",
                    isOn: Binding(
                        get: { model.draftConfig.debugLogging },
                        set: { newValue in
                            model.updateDraftConfig { $0.debugLogging = newValue }
                        }
                    )
                )

                Stepper(
                    value: Binding(
                        get: { model.draftConfig.maxRotatedLogFiles },
                        set: { newValue in
                            model.updateDraftConfig { $0.maxRotatedLogFiles = max(1, newValue) }
                        }
                    ),
                    in: 1...20
                ) {
                    Text("Rotated log files: \(model.draftConfig.maxRotatedLogFiles)")
                }

                Stepper(
                    value: Binding(
                        get: { model.draftConfig.maxLogFileSizeBytes / 1_000_000 },
                        set: { newValue in
                            model.updateDraftConfig { $0.maxLogFileSizeBytes = max(1, newValue) * 1_000_000 }
                        }
                    ),
                    in: 1...20
                ) {
                    Text("Per-log size: \(model.draftConfig.maxLogFileSizeBytes / 1_000_000) MB")
                }
            }

            Section("Pending Changes") {
                HStack {
                    Button("Apply") {
                        model.applyConfigChanges()
                    }
                    .disabled(model.hasPendingConfigChanges == false)

                    Button("Revert") {
                        model.revertConfigChanges()
                    }
                    .disabled(model.hasPendingConfigChanges == false)
                }

                Text(model.hasPendingConfigChanges ? "Settings changes are staged locally until you apply them." : "No pending settings changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { newValue in
                            model.setLaunchAtLogin(newValue)
                        }
                    )
                )

                if let launchAtLoginError = model.launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notes") {
                Text("Logs, last-run snapshots, and crash context are stored in ~/Library/Application Support/SyncMusic.")
                Text("Soundiiz can only see regular playlists. SyncMusic keeps those playlists up to date from your smart playlists.")
                Text("Qobuz via Soundiiz uses 1,900 tracks per materialized part to stay below Qobuz limits.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
    }

    private var scheduleKindBinding: Binding<AutoSyncScheduleKind> {
        Binding(
            get: { model.draftConfig.autoSyncSchedule.kind },
            set: { newValue in
                model.updateDraftConfig { config in
                    switch newValue {
                    case .interval:
                        let minutes = config.autoSyncSchedule.intervalMinutes ?? config.syncIntervalMinutes
                        config.autoSyncSchedule = .interval(minutes: max(1, minutes))
                    case .daily:
                        let time = config.autoSyncSchedule.dailyTime ?? config.dailySyncTime
                        config.autoSyncSchedule = .daily(time: time.normalized)
                    }
                }
            }
        )
    }

    private var intervalMinutesBinding: Binding<Int> {
        Binding(
            get: { model.draftConfig.syncIntervalMinutes },
            set: { newValue in
                model.updateDraftConfig {
                    $0.autoSyncSchedule = .interval(minutes: max(1, newValue))
                }
            }
        )
    }

    private var dailyTimeBinding: Binding<Date> {
        Binding(
            get: { model.draftConfig.dailySyncTime.date(on: Date()) },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                let hour = components.hour ?? 2
                let minute = components.minute ?? 0

                model.updateDraftConfig {
                    $0.autoSyncSchedule = .daily(time: DailySyncTime(hour: hour, minute: minute))
                }
            }
        )
    }
}

@main
struct SyncMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        model.startIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Label(model.menuBarTitle, systemImage: model.menuBarSymbolName)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
