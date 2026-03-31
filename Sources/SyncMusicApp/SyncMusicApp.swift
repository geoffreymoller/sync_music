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
        VStack(alignment: .leading, spacing: 10) {
            MenuHeaderSection(model: model)
            RunSummaryCard(model: model)

            if let healthSummary = model.menuHealthSummary {
                HealthBanner(summary: healthSummary)
            }

            MenuActionSection(model: model)
        }
        .padding(12)
        .frame(width: 320)
    }
}

private enum MenuStatusTone {
    case syncing
    case warning
    case healthy
    case idle

    @MainActor
    init(model: AppModel) {
        if model.isSyncing {
            self = .syncing
        } else if model.menuHealthSummary != nil {
            self = .warning
        } else if model.lastReport != nil {
            self = .healthy
        } else {
            self = .idle
        }
    }

    var symbolName: String {
        switch self {
        case .syncing:
            return "arrow.trianglehead.2.clockwise"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .healthy:
            return "checkmark.circle.fill"
        case .idle:
            return "music.note.list"
        }
    }

    var tint: Color {
        switch self {
        case .syncing:
            return .accentColor
        case .warning:
            return .orange
        case .healthy:
            return .green
        case .idle:
            return .secondary
        }
    }
}

private struct MenuHeaderSection: View {
    @ObservedObject var model: AppModel

    private var tone: MenuStatusTone {
        MenuStatusTone(model: model)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("SyncMusic")
                    .font(.system(size: 13, weight: .semibold))

                Text(model.menuStatusHeadline)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(model.menuStatusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if model.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }
}

private struct RunSummaryCard: View {
    @ObservedObject var model: AppModel

    private var backgroundTint: Color {
        model.isSyncing ? .accentColor.opacity(0.12) : .primary.opacity(0.05)
    }

    private var borderTint: Color {
        model.isSyncing ? .accentColor.opacity(0.2) : .primary.opacity(0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: model.isSyncing ? "dot.radiowaves.left.and.right" : "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let detail = trailingDetail {
                    Text(detail)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(metrics)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let playlistLine {
                Label {
                    Text(playlistLine)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "music.note.list")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(backgroundTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderTint, lineWidth: 1)
        )
    }

    private var title: String {
        model.isSyncing ? model.menuActiveRunTitle : model.menuLastRunTitle
    }

    private var subtitle: String {
        model.isSyncing ? model.menuActiveRunSubtitle : model.menuLastRunSubtitle
    }

    private var metrics: String {
        model.isSyncing ? model.menuActiveRunMetrics : model.menuLastRunMetrics
    }

    private var trailingDetail: String? {
        model.isSyncing ? nil : model.menuLastRunDetail
    }

    private var playlistLine: String? {
        guard model.isSyncing else {
            return nil
        }

        return model.activeCurrentPlaylistName.map { "Current: \($0)" }
    }
}

private struct HealthBanner: View {
    let summary: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(summary)
                .font(.caption)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

private struct MenuActionSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.syncNow()
                } label: {
                    Label(model.isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSyncing)

                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }

            Menu {
                Button("View Logs") {
                    model.viewLogs()
                }

                Button("Open Diagnostics Folder") {
                    model.openDiagnosticsFolder()
                }

                Button("Copy Diagnostics Summary") {
                    model.copyDiagnosticsSummary()
                }

                Divider()

                Button("Quit") {
                    model.quit()
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .controlSize(.small)
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

            Section("Spotify") {
                TextField("Client ID", text: spotifyClientIDBinding)
                TextField("Redirect URI", text: spotifyRedirectURIBinding)

                HStack {
                    Button("Connect Spotify") {
                        model.connectSpotify()
                    }
                    .disabled(model.hasPendingConfigChanges || !(model.config.spotifyAuth?.isConfigured ?? false))

                    Button("Disconnect") {
                        model.disconnectSpotify()
                    }
                    .disabled(model.spotifyConnectionStatus.isConnected == false)
                }

                if model.hasPendingConfigChanges {
                    Text("Apply pending Spotify settings before connecting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.spotifyConnectionStatus.isConnected {
                    Text(
                        model.spotifyConnectionStatus.accountDisplayName.map { "Connected as \($0)" }
                            ?? model.spotifyConnectionStatus.accountID.map { "Connected as \($0)" }
                            ?? "Connected to Spotify"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Spotify is not connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Spotify mappings")
                        .font(.caption.weight(.semibold))

                    if model.draftConfig.spotifyPlaylistMappings.isEmpty {
                        Text("No Spotify playlist mappings are configured. Add them in config.json.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.draftConfig.spotifyPlaylistMappings) { mapping in
                            let targetReference = mapping.spotifyPlaylistReference.isEmpty
                                ? (mapping.targetPlaylistName?.isEmpty == false ? "Create private mirror: \(mapping.targetPlaylistName!)" : "Create private mirror")
                                : mapping.spotifyPlaylistReference
                            Text("\(mapping.appleSourceName) (\(mapping.appleSourceKind.displayName)) → \(targetReference)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                Text("Spotify mappings are configured in config.json. Use an Apple playlist name plus a Spotify playlist URL/ID to adopt an existing target.")
                Text("Direct Spotify sync runs on the same schedule as the app sync. Use an interval schedule for sub-daily updates.")
                Text("Soundiiz can only see regular playlists. SyncMusic still keeps Apple mirror playlists up to date for that workflow.")
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

    private var spotifyClientIDBinding: Binding<String> {
        Binding(
            get: { model.draftConfig.spotifyAuth?.clientID ?? "" },
            set: { newValue in
                model.updateDraftConfig { config in
                    var spotifyAuth = config.spotifyAuth ?? SpotifyAuthConfig()
                    spotifyAuth.clientID = newValue
                    config.spotifyAuth = spotifyAuth
                }
            }
        )
    }

    private var spotifyRedirectURIBinding: Binding<String> {
        Binding(
            get: { model.draftConfig.spotifyAuth?.redirectURI ?? "http://127.0.0.1:43821/callback" },
            set: { newValue in
                model.updateDraftConfig { config in
                    var spotifyAuth = config.spotifyAuth ?? SpotifyAuthConfig()
                    spotifyAuth.redirectURI = newValue
                    config.spotifyAuth = spotifyAuth
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
