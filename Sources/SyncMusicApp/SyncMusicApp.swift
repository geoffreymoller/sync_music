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
                    Text("Tracks +\(lastReport.addedTrackCount) / -\(lastReport.removedTrackCount) • Playlists +\(lastReport.createdPlaylistCount) / -\(lastReport.deletedPlaylistCount) / rename \(lastReport.renamedPlaylistCount)")
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
                Stepper(
                    value: Binding(
                        get: { model.config.syncIntervalMinutes },
                        set: { newValue in
                            model.updateConfig { $0.syncIntervalMinutes = max(1, newValue) }
                        }
                    ),
                    in: 1...1_440
                ) {
                    Text("Interval: \(model.config.syncIntervalMinutes) min")
                }

                TextField(
                    "Materialized Prefix",
                    text: Binding(
                        get: { model.config.materializedPrefix },
                        set: { newValue in
                            model.updateConfig { $0.materializedPrefix = newValue.isEmpty ? "Sync Mirror" : newValue }
                        }
                    )
                )

                Picker(
                    "Destination Profile",
                    selection: Binding(
                        get: { model.config.providerProfile },
                        set: { newValue in
                            model.updateConfig { $0.providerProfile = newValue }
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
                        get: { model.config.includeSystemSmartPlaylists },
                        set: { newValue in
                            model.updateConfig { $0.includeSystemSmartPlaylists = newValue }
                        }
                    )
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Excluded source playlists")
                        .font(.caption.weight(.semibold))

                    Text("Rules are applied before track retrieval. Matches are exact, case-insensitive, and trim surrounding spaces.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(Array(model.config.sourcePlaylistExclusions.indices), id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Picker(
                                "Match Type",
                                selection: Binding(
                                    get: { model.config.sourcePlaylistExclusions[index].matchType },
                                    set: { newValue in
                                        model.updateConfig { config in
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
                                    get: { model.config.sourcePlaylistExclusions[index].value },
                                    set: { newValue in
                                        model.updateConfig { config in
                                            guard config.sourcePlaylistExclusions.indices.contains(index) else {
                                                return
                                            }
                                            config.sourcePlaylistExclusions[index].value = newValue
                                        }
                                    }
                                )
                            )

                            Button {
                                model.updateConfig { config in
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
                        model.updateConfig {
                            $0.sourcePlaylistExclusions.append(PlaylistExclusionRule(value: ""))
                        }
                    }
                }

                Toggle(
                    "Delete stale managed playlists",
                    isOn: Binding(
                        get: { model.config.deleteStaleManagedPlaylists },
                        set: { newValue in
                            model.updateConfig { $0.deleteStaleManagedPlaylists = newValue }
                        }
                    )
                )
            }

            Section("Diagnostics") {
                Picker(
                    "Log Level",
                    selection: Binding(
                        get: { model.config.logLevel },
                        set: { newValue in
                            model.updateConfig { $0.logLevel = newValue }
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
                        get: { model.config.debugLogging },
                        set: { newValue in
                            model.updateConfig { $0.debugLogging = newValue }
                        }
                    )
                )

                Stepper(
                    value: Binding(
                        get: { model.config.maxRotatedLogFiles },
                        set: { newValue in
                            model.updateConfig { $0.maxRotatedLogFiles = max(1, newValue) }
                        }
                    ),
                    in: 1...20
                ) {
                    Text("Rotated log files: \(model.config.maxRotatedLogFiles)")
                }

                Stepper(
                    value: Binding(
                        get: { model.config.maxLogFileSizeBytes / 1_000_000 },
                        set: { newValue in
                            model.updateConfig { $0.maxLogFileSizeBytes = max(1, newValue) * 1_000_000 }
                        }
                    ),
                    in: 1...20
                ) {
                    Text("Per-log size: \(model.config.maxLogFileSizeBytes / 1_000_000) MB")
                }
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
}

@main
struct SyncMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
                .task {
                    model.start()
                }
        } label: {
            Label(model.menuBarTitle, systemImage: model.menuBarSymbolName)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
