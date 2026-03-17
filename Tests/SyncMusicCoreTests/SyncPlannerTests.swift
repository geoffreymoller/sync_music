import SyncMusicCore
import Testing

struct SyncPlannerTests {
    @Test
    func chunkingKeepsEmptyPlaylistsRepresented() {
        #expect(SyncPlanner.chunkedTrackIDs([], limit: nil) == [[]])
        #expect(SyncPlanner.chunkedTrackIDs([], limit: 1_900) == [[]])
    }

    @Test
    func qobuzChunkingSplitsLargeTrackListsDeterministically() {
        let trackIDs = (1...3_805).map { "TRACK-\($0)" }
        let chunks = SyncPlanner.chunkedTrackIDs(trackIDs, limit: 1_900)

        #expect(chunks.count == 3)
        #expect(chunks[0].count == 1_900)
        #expect(chunks[1].count == 1_900)
        #expect(chunks[2].count == 5)
        #expect(chunks[0].first == "TRACK-1")
        #expect(chunks[2].last == "TRACK-3805")
    }

    @Test
    func materializedPlaylistNamesUsePartSuffixOnlyWhenNeeded() {
        #expect(
            SyncPlanner.materializedPlaylistNames(prefix: "Sync Mirror", sourceName: "Recently Added", partCount: 1)
                == ["Sync Mirror / Recently Added"]
        )
        #expect(
            SyncPlanner.materializedPlaylistNames(prefix: "Sync Mirror", sourceName: "Recently Added", partCount: 3)
                == [
                    "Sync Mirror / Recently Added (Part 1)",
                    "Sync Mirror / Recently Added (Part 2)",
                    "Sync Mirror / Recently Added (Part 3)",
                ]
        )
    }

    @Test
    func systemSmartPlaylistsAreFilteredByDefault() {
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

        let filtered = SyncPlanner.filteredSmartPlaylists(
            from: [userPlaylist, systemPlaylist],
            includeSystemPlaylists: false
        )

        #expect(filtered == [userPlaylist])
    }
}
