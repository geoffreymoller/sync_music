import Foundation
@testable import SyncMusicCore
import Testing

private actor RequestRecorder {
    var requests: [(method: String, uris: [String])] = []

    func append(method: String, uris: [String]) {
        requests.append((method, uris))
    }
}

struct SpotifyClientTests {
    @Test
    func trackSearchPrefersExactTitleArtistAlbumMatch() async throws {
        let clientID = "spotify-test-client-\(UUID().uuidString)"
        let tokenStore = SpotifyTokenStore(service: "local.geoff.syncmusic.spotify.tests.\(UUID().uuidString)")
        try tokenStore.save(
            SpotifyTokenBundle(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                expiresAt: Date().addingTimeInterval(3_600)
            ),
            clientID: clientID
        )

        defer { try? tokenStore.clear(clientID: clientID) }

        let client = SpotifyClient(
            tokenStore: tokenStore,
            requestExecutor: { request in
                #expect(request.url?.absoluteString.contains("/v1/search") == true)
                let json = """
                {
                  "tracks": {
                    "items": [
                      {
                        "id": "wrong",
                        "uri": "spotify:track:wrong",
                        "name": "For Luke (Live)",
                        "artists": [{ "name": "Phoebe Bridgers" }],
                        "album": { "name": "Live" }
                      },
                      {
                        "id": "right",
                        "uri": "spotify:track:right",
                        "name": "For Luke",
                        "artists": [{ "name": "Phoebe Bridgers" }],
                        "album": { "name": "Punisher" }
                      }
                    ]
                  }
                }
                """
                return (
                    Data(json.utf8),
                    HTTPURLResponse(
                        url: try #require(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        let match = try await client.findBestTrackMatchURI(
            for: TrackSnapshot(
                persistentID: "APPLE-TRACK-1",
                title: "For Luke",
                artist: "Phoebe Bridgers",
                album: "Punisher"
            ),
            authConfig: SpotifyAuthConfig(
                clientID: clientID,
                redirectURI: "http://127.0.0.1:43821/callback"
            )
        )

        #expect(match == "spotify:track:right")
    }

    @Test
    func playlistReplacementBatchesRequestsInHundreds() async throws {
        let clientID = "spotify-test-client-\(UUID().uuidString)"
        let tokenStore = SpotifyTokenStore(service: "local.geoff.syncmusic.spotify.tests.\(UUID().uuidString)")
        try tokenStore.save(
            SpotifyTokenBundle(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                expiresAt: Date().addingTimeInterval(3_600)
            ),
            clientID: clientID
        )

        defer { try? tokenStore.clear(clientID: clientID) }

        let recorder = RequestRecorder()
        let client = SpotifyClient(
            tokenStore: tokenStore,
            requestExecutor: { request in
                let body = try #require(request.httpBody)
                let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String]])
                await recorder.append(method: request.httpMethod ?? "GET", uris: payload["uris"] ?? [])
                return (
                    Data("{}".utf8),
                    HTTPURLResponse(
                        url: try #require(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        let uris = (1...205).map { "spotify:track:\($0)" }
        try await client.replacePlaylistContents(
            playlistID: "spotify-playlist-1",
            uris: uris,
            authConfig: SpotifyAuthConfig(
                clientID: clientID,
                redirectURI: "http://127.0.0.1:43821/callback"
            )
        )

        let requests = await recorder.requests
        #expect(requests.count == 3)
        #expect(requests[0].method == "PUT")
        #expect(requests[0].uris.count == 100)
        #expect(requests[1].method == "POST")
        #expect(requests[1].uris.count == 100)
        #expect(requests[2].method == "POST")
        #expect(requests[2].uris.count == 5)
    }
}
