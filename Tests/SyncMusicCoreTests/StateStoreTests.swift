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
            syncIntervalMinutes: 45,
            materializedPrefix: "Managed",
            includeSystemSmartPlaylists: true,
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
        ])

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
}
