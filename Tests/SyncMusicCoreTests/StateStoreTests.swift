import Foundation
import SyncMusicCore
import Testing

struct StateStoreTests {
    @Test
    func stateStoreRoundTripsConfigAndState() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = StateStore(rootDirectory: tempDirectory)

        let config = AppConfig(
            autoSyncSchedule: .daily(time: DailySyncTime(hour: 2, minute: 15)),
            materializedPrefix: "Managed",
            includeSystemSmartPlaylists: true,
            allowedSourcePlaylistNames: ["Recently Added", "Road Trip"],
            providerProfile: .generic,
            deleteStaleManagedPlaylists: false
        )

        let state = SyncState(managedPlaylists: [
            "SOURCE": ManagedPlaylistState(
                sourcePersistentID: "SOURCE",
                sourceName: "Recently Added",
                parts: [ManagedPlaylistPart(index: 0, targetPersistentID: "TARGET", targetName: "Managed / Recently Added")],
                lastSourceFingerprint: "fingerprint-1",
                lastSyncedAt: Date(timeIntervalSince1970: 1_234),
                lastError: nil
            ),
        ], lastScheduledAttemptAt: Date(timeIntervalSince1970: 4_321))

        try store.saveConfig(config)
        try store.saveState(state)

        #expect(try store.loadConfig() == config)
        #expect(try store.loadState() == state)
    }

    @Test
    func syncRunReportDecodesOlderSnapshotsWithoutRebuildMetrics() throws {
        let json = """
        {
          "runID": "RUN-1",
          "trigger": "manual",
          "startedAt": "2026-03-17T20:00:00Z",
          "finishedAt": "2026-03-17T20:01:00Z",
          "processedPlaylistCount": 4,
          "addedTrackCount": 12,
          "removedTrackCount": 3,
          "createdPlaylistCount": 1,
          "deletedPlaylistCount": 0,
          "renamedPlaylistCount": 0,
          "failures": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(SyncRunReport.self, from: Data(json.utf8))

        #expect(report.writtenTrackCount == 0)
        #expect(report.rebuiltPlaylistPartCount == 0)
        #expect(report.addedTrackCount == 12)
        #expect(report.removedTrackCount == 3)
    }

    @Test
    func appConfigDecodesLegacyIntervalSchedule() throws {
        let json = """
        {
          "syncIntervalMinutes": 45,
          "materializedPrefix": "Managed",
          "includeSystemSmartPlaylists": false,
          "sourcePlaylistExclusions": [],
          "providerProfile": "generic",
          "deleteStaleManagedPlaylists": false,
          "logLevel": "info",
          "debugLogging": false,
          "maxLogFileSizeBytes": 2000000,
          "maxRotatedLogFiles": 5
        }
        """

        let decoder = JSONDecoder()
        let config = try decoder.decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.autoSyncSchedule == .interval(minutes: 45))
        #expect(config.allowedSourcePlaylistNames == ["Recently Added"])
    }

    @Test
    func appConfigNormalizesAllowedSourcePlaylistNames() {
        let config = AppConfig(
            allowedSourcePlaylistNames: [" Recently Added ", "", "recently added", "Road Trip", "ROAD TRIP"]
        )

        #expect(config.allowedSourcePlaylistNames == ["Recently Added", "Road Trip"])
    }
}
