import Foundation
import SyncMusicCore
import Testing

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
            lastSyncedAt: Date(timeIntervalSince1970: 1_234),
            lastError: nil
        ),
    ])

    try store.saveConfig(config)
    try store.saveState(state)

    #expect(store.loadConfig() == config)
    #expect(store.loadState() == state)
}
