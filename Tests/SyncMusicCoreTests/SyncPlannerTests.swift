import Foundation
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

    @Test
    func allowlistMatchesExactNamesCaseInsensitively() {
        let recent = PlaylistSnapshot(
            name: "Recently Added",
            persistentID: "RECENT",
            specialKind: "none",
            isSmart: true,
            trackPersistentIDs: []
        )
        let roadTrip = PlaylistSnapshot(
            name: "Road Trip Mix",
            persistentID: "ROAD",
            specialKind: "none",
            isSmart: true,
            trackPersistentIDs: []
        )

        let evaluation = SyncPlanner.evaluateSmartPlaylists(
            from: [recent, roadTrip],
            includeSystemPlaylists: false,
            exclusionRules: [],
            allowedSourcePlaylistNames: ["recently added"]
        )

        #expect(evaluation.included == [recent])
        #expect(evaluation.excludedByAllowlist == [roadTrip])
    }

    @Test
    func emptyAllowlistExcludesAllEligiblePlaylists() {
        let recent = PlaylistSnapshot(
            name: "Recently Added",
            persistentID: "RECENT",
            specialKind: "none",
            isSmart: true,
            trackPersistentIDs: []
        )

        let evaluation = SyncPlanner.evaluateSmartPlaylists(
            from: [recent],
            includeSystemPlaylists: false,
            exclusionRules: [],
            allowedSourcePlaylistNames: []
        )

        #expect(evaluation.included.isEmpty)
        #expect(evaluation.excludedByAllowlist == [recent])
        #expect(evaluation.protectedSourceIDs == Set(["RECENT"]))
    }

    @Test
    func exclusionRulesTakePrecedenceOverAllowlist() {
        let favoriteSongs = PlaylistSnapshot(
            name: "Favorite Songs",
            persistentID: "FAVORITE",
            specialKind: "none",
            isSmart: true,
            trackPersistentIDs: []
        )

        let evaluation = SyncPlanner.evaluateSmartPlaylists(
            from: [favoriteSongs],
            includeSystemPlaylists: false,
            exclusionRules: [PlaylistExclusionRule(matchType: .exactName, value: "Favorite Songs")],
            allowedSourcePlaylistNames: ["Favorite Songs"]
        )

        #expect(evaluation.included.isEmpty)
        #expect(evaluation.excludedByRules == [favoriteSongs])
        #expect(evaluation.excludedByAllowlist.isEmpty)
        #expect(evaluation.protectedSourceIDs == Set(["FAVORITE"]))
    }

    @Test
    func dailyScheduleRunsAfterDueTimeWhenNoAttemptWasRecorded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let schedule = AutoSyncSchedule.daily(time: DailySyncTime(hour: 2, minute: 0))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 17,
            hour: 3,
            minute: 30
        )))

        let evaluation = schedule.evaluate(
            now: now,
            lastScheduledAttemptAt: nil,
            calendar: calendar
        )

        #expect(evaluation.shouldRunNow)
    }

    @Test
    func dailyScheduleSkipsSecondAttemptOnSameDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let schedule = AutoSyncSchedule.daily(time: DailySyncTime(hour: 2, minute: 0))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 17,
            hour: 8,
            minute: 0
        )))
        let attemptedAt = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 17,
            hour: 2,
            minute: 5
        )))
        let expectedNextCheck = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 18,
            hour: 2,
            minute: 0
        )))

        let evaluation = schedule.evaluate(
            now: now,
            lastScheduledAttemptAt: attemptedAt,
            calendar: calendar
        )

        #expect(evaluation.shouldRunNow == false)
        #expect(evaluation.nextCheckAt == expectedNextCheck)
    }
}
