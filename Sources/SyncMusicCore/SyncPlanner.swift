import Foundation

public struct PlaylistFilterEvaluation: Equatable, Sendable {
    public let included: [PlaylistSnapshot]
    public let excludedByRules: [PlaylistSnapshot]
    public let excludedBySystemFilter: [PlaylistSnapshot]

    public init(
        included: [PlaylistSnapshot],
        excludedByRules: [PlaylistSnapshot],
        excludedBySystemFilter: [PlaylistSnapshot]
    ) {
        self.included = included
        self.excludedByRules = excludedByRules
        self.excludedBySystemFilter = excludedBySystemFilter
    }

    public var protectedSourceIDs: Set<String> {
        Set(included.map(\.persistentID) + excludedByRules.map(\.persistentID))
    }
}

public enum SyncPlanner {
    public static func evaluateSmartPlaylists(
        from playlists: [PlaylistSnapshot],
        includeSystemPlaylists: Bool,
        exclusionRules: [PlaylistExclusionRule]
    ) -> PlaylistFilterEvaluation {
        var included: [PlaylistSnapshot] = []
        var excludedByRules: [PlaylistSnapshot] = []
        var excludedBySystemFilter: [PlaylistSnapshot] = []

        for snapshot in playlists {
            if includeSystemPlaylists == false && snapshot.isSystemSmartPlaylist {
                excludedBySystemFilter.append(snapshot)
                continue
            }

            if exclusionRules.contains(where: { $0.matches(snapshot: snapshot) }) {
                excludedByRules.append(snapshot)
                continue
            }

            included.append(snapshot)
        }

        return PlaylistFilterEvaluation(
            included: included,
            excludedByRules: excludedByRules,
            excludedBySystemFilter: excludedBySystemFilter
        )
    }

    public static func filteredSmartPlaylists(
        from playlists: [PlaylistSnapshot],
        includeSystemPlaylists: Bool,
        exclusionRules: [PlaylistExclusionRule] = []
    ) -> [PlaylistSnapshot] {
        evaluateSmartPlaylists(
            from: playlists,
            includeSystemPlaylists: includeSystemPlaylists,
            exclusionRules: exclusionRules
        ).included
    }

    public static func chunkedTrackIDs(_ trackIDs: [String], limit: Int?) -> [[String]] {
        guard let limit, limit > 0 else {
            return [trackIDs]
        }

        if trackIDs.isEmpty {
            return [[]]
        }

        var chunks: [[String]] = []
        var currentIndex = 0

        while currentIndex < trackIDs.count {
            let nextIndex = min(currentIndex + limit, trackIDs.count)
            chunks.append(Array(trackIDs[currentIndex..<nextIndex]))
            currentIndex = nextIndex
        }

        return chunks
    }

    public static func materializedPlaylistNames(
        prefix: String,
        sourceName: String,
        partCount: Int
    ) -> [String] {
        let baseName = "\(prefix) / \(sourceName)"
        guard partCount > 1 else {
            return [baseName]
        }

        return (1...partCount).map { "\(baseName) (Part \($0))" }
    }

    public static func diff(source: [String], target: [String]) -> PlaylistDiff {
        let sourceSet = Set(source)
        let targetSet = Set(target)

        let toAdd = source.filter { !targetSet.contains($0) }
        let toRemove = target.filter { !sourceSet.contains($0) }
        return PlaylistDiff(toAdd: toAdd, toRemove: toRemove)
    }
}
