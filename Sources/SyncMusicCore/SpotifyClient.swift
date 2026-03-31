import CryptoKit
import Foundation
import Network
import Security

public struct SpotifyConnectionStatus: Equatable, Sendable {
    public let isConnected: Bool
    public let accountID: String?
    public let accountDisplayName: String?

    public init(
        isConnected: Bool,
        accountID: String? = nil,
        accountDisplayName: String? = nil
    ) {
        self.isConnected = isConnected
        self.accountID = accountID
        self.accountDisplayName = accountDisplayName
    }
}

public struct SpotifyUserProfile: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

public struct SpotifyPlaylistSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isPublic: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isPublic = "public"
    }
}

public enum SpotifyClientError: LocalizedError, Sendable {
    case authNotConfigured
    case invalidRedirectURI
    case authorizationCancelled
    case authorizationFailed(String)
    case notConnected
    case invalidHTTPResponse
    case apiError(statusCode: Int, message: String)
    case playlistNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .authNotConfigured:
            return "Spotify auth is not configured."
        case .invalidRedirectURI:
            return "Spotify redirect URI must be a loopback HTTP URI with an explicit port."
        case .authorizationCancelled:
            return "Spotify authorization was cancelled or timed out."
        case .authorizationFailed(let message):
            return "Spotify authorization failed: \(message)"
        case .notConnected:
            return "Spotify is not connected."
        case .invalidHTTPResponse:
            return "Spotify returned an invalid HTTP response."
        case .apiError(_, let message):
            return message
        case .playlistNotFound(let reference):
            return "Spotify playlist not found: \(reference)"
        }
    }
}

struct SpotifyTokenBundle: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isExpired: Bool {
        expiresAt.timeIntervalSinceNow <= 60
    }
}

private struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private struct SpotifyPlaylistTracksResponse: Decodable {
    struct Item: Decodable {
        struct Track: Decodable {
            let uri: String?
        }

        let track: Track?
    }

    let items: [Item]
    let next: String?
}

private struct SpotifySearchResponse: Decodable {
    struct Tracks: Decodable {
        let items: [SpotifyTrackCandidate]
    }

    let tracks: Tracks
}

private struct SpotifyTrackCandidate: Decodable, Sendable {
    struct Artist: Decodable, Sendable {
        let name: String
    }

    struct Album: Decodable, Sendable {
        let name: String
    }

    let id: String
    let uri: String
    let name: String
    let artists: [Artist]
    let album: Album
}

final class SpotifyTokenStore: @unchecked Sendable {
    private let service: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(service: String = "local.geoff.syncmusic.spotify") {
        self.service = service
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load(clientID: String) throws -> SpotifyTokenBundle? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try decoder.decode(SpotifyTokenBundle.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func save(_ bundle: SpotifyTokenBundle, clientID: String) throws {
        let data = try encoder.encode(bundle)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientID,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
            return
        }

        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func clear(clientID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

private final class SpotifyContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard didResume == false else {
            return false
        }
        didResume = true
        return true
    }
}

actor SpotifyClient {
    public typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let tokenStore: SpotifyTokenStore
    private let requestExecutor: RequestExecutor
    private let sessionQueue = DispatchQueue(label: "local.geoff.syncmusic.spotify-auth")

    init(
        tokenStore: SpotifyTokenStore = SpotifyTokenStore(),
        requestExecutor: RequestExecutor? = nil
    ) {
        self.tokenStore = tokenStore
        if let requestExecutor {
            self.requestExecutor = requestExecutor
        } else {
            self.requestExecutor = { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SpotifyClientError.invalidHTTPResponse
                }
                return (data, http)
            }
        }
    }

    func connectionStatus(authConfig: SpotifyAuthConfig?) async -> SpotifyConnectionStatus {
        guard let authConfig, authConfig.isConfigured else {
            return SpotifyConnectionStatus(isConnected: false)
        }

        do {
            let profile = try await currentUserProfile(authConfig: authConfig)
            return SpotifyConnectionStatus(
                isConnected: true,
                accountID: profile.id,
                accountDisplayName: profile.displayName
            )
        } catch {
            return SpotifyConnectionStatus(isConnected: false)
        }
    }

    func connect(
        authConfig: SpotifyAuthConfig,
        openURL: @escaping @Sendable (URL) -> Void
    ) async throws -> SpotifyConnectionStatus {
        guard authConfig.isConfigured else {
            throw SpotifyClientError.authNotConfigured
        }

        let verifier = Self.randomToken(length: 96)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomToken(length: 32)
        let authorizationURL = try Self.authorizationURL(
            authConfig: authConfig,
            challenge: challenge,
            state: state
        )

        async let code = listenForAuthorizationCode(
            redirectURI: authConfig.redirectURI,
            expectedState: state
        )
        openURL(authorizationURL)

        let authorizationCode = try await code
        let bundle = try await exchangeAuthorizationCode(
            authorizationCode,
            verifier: verifier,
            authConfig: authConfig
        )
        try tokenStore.save(bundle, clientID: authConfig.clientID)

        let profile = try await currentUserProfile(authConfig: authConfig)
        return SpotifyConnectionStatus(
            isConnected: true,
            accountID: profile.id,
            accountDisplayName: profile.displayName
        )
    }

    func disconnect(authConfig: SpotifyAuthConfig?) throws {
        guard let authConfig, authConfig.isConfigured else {
            return
        }
        try tokenStore.clear(clientID: authConfig.clientID)
    }

    func currentUserProfile(authConfig: SpotifyAuthConfig) async throws -> SpotifyUserProfile {
        try await sendJSONRequest(
            path: "/v1/me",
            authConfig: authConfig
        )
    }

    func createPlaylist(
        name: String,
        isPublic: Bool,
        authConfig: SpotifyAuthConfig
    ) async throws -> SpotifyPlaylistSummary {
        let profile = try await currentUserProfile(authConfig: authConfig)
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "public": isPublic,
        ])
        return try await sendJSONRequest(
            path: "/v1/users/\(profile.id)/playlists",
            method: "POST",
            body: body,
            authConfig: authConfig
        )
    }

    func playlistSummary(
        reference: String,
        authConfig: SpotifyAuthConfig
    ) async throws -> SpotifyPlaylistSummary {
        let playlistID = try Self.extractPlaylistID(from: reference)
        return try await sendJSONRequest(
            path: "/v1/playlists/\(playlistID)",
            authConfig: authConfig
        )
    }

    func playlistTrackURIs(
        playlistID: String,
        authConfig: SpotifyAuthConfig
    ) async throws -> [String] {
        var uris: [String] = []
        var nextPath = "/v1/playlists/\(playlistID)/tracks?fields=items(track(uri)),next&limit=100"

        while true {
            let response: SpotifyPlaylistTracksResponse = try await sendJSONRequest(
                rawPath: nextPath,
                authConfig: authConfig
            )
            uris.append(contentsOf: response.items.compactMap { $0.track?.uri })

            guard let next = response.next,
                  let nextURL = URL(string: next),
                  var components = URLComponents(url: nextURL, resolvingAgainstBaseURL: false) else {
                break
            }

            components.scheme = nil
            components.host = nil
            nextPath = components.string ?? ""
        }

        return uris
    }

    func replacePlaylistContents(
        playlistID: String,
        uris: [String],
        authConfig: SpotifyAuthConfig
    ) async throws {
        let firstBatch = Array(uris.prefix(100))
        let initialBody = try JSONSerialization.data(withJSONObject: [
            "uris": firstBatch,
        ])
        _ = try await sendRequest(
            path: "/v1/playlists/\(playlistID)/tracks",
            method: "PUT",
            body: initialBody,
            authConfig: authConfig
        )

        if uris.count <= 100 {
            return
        }

        var index = 100
        while index < uris.count {
            let nextIndex = min(index + 100, uris.count)
            let batch = Array(uris[index..<nextIndex])
            let body = try JSONSerialization.data(withJSONObject: [
                "uris": batch,
            ])
            _ = try await sendRequest(
                path: "/v1/playlists/\(playlistID)/tracks",
                method: "POST",
                body: body,
                authConfig: authConfig
            )
            index = nextIndex
        }
    }

    func findBestTrackMatchURI(
        for track: TrackSnapshot,
        authConfig: SpotifyAuthConfig
    ) async throws -> String? {
        if let isrc = track.isrc?.trimmingCharacters(in: .whitespacesAndNewlines),
           isrc.isEmpty == false {
            let isrcResults = try await searchTracks(query: "isrc:\(isrc)", authConfig: authConfig)
            if let exact = isrcResults.first {
                return exact.uri
            }
        }

        var queryParts: [String] = []
        if !track.title.isEmpty {
            queryParts.append("track:\(track.title)")
        }
        if !track.artist.isEmpty {
            queryParts.append("artist:\(track.artist)")
        }
        if !track.album.isEmpty {
            queryParts.append("album:\(track.album)")
        }

        let results = try await searchTracks(query: queryParts.joined(separator: " "), authConfig: authConfig)
        return selectCandidate(from: results, for: track)?.uri
    }

    private func searchTracks(
        query: String,
        authConfig: SpotifyAuthConfig
    ) async throws -> [SpotifyTrackCandidate] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let response: SpotifySearchResponse = try await sendJSONRequest(
            rawPath: "/v1/search?q=\(encodedQuery)&type=track&limit=10",
            authConfig: authConfig
        )
        return response.tracks.items
    }

    private func sendJSONRequest<T: Decodable>(
        path: String? = nil,
        rawPath: String? = nil,
        method: String = "GET",
        body: Data? = nil,
        authConfig: SpotifyAuthConfig
    ) async throws -> T {
        let (data, _) = try await sendRequest(
            path: path,
            rawPath: rawPath,
            method: method,
            body: body,
            authConfig: authConfig
        )
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func sendRequest(
        path: String? = nil,
        rawPath: String? = nil,
        method: String = "GET",
        body: Data? = nil,
        authConfig: SpotifyAuthConfig
    ) async throws -> (Data, HTTPURLResponse) {
        var tokenBundle = try tokenStore.load(clientID: authConfig.clientID)
        guard let loadedBundle = tokenBundle else {
            throw SpotifyClientError.notConnected
        }
        tokenBundle = loadedBundle

        if loadedBundle.isExpired {
            let refreshedBundle = try await refreshToken(loadedBundle, authConfig: authConfig)
            try tokenStore.save(refreshedBundle, clientID: authConfig.clientID)
            tokenBundle = refreshedBundle
        }

        guard let tokenBundle else {
            throw SpotifyClientError.notConnected
        }

        let targetURL: URL
        if let rawPath {
            guard let rawURL = URL(string: rawPath, relativeTo: URL(string: "https://api.spotify.com")) else {
                throw SpotifyClientError.invalidHTTPResponse
            }
            targetURL = rawURL.absoluteURL
        } else if let path, let url = URL(string: "https://api.spotify.com\(path)") {
            targetURL = url
        } else {
            throw SpotifyClientError.invalidHTTPResponse
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = method
        request.setValue("Bearer \(tokenBundle.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await requestExecutor(request)
        if response.statusCode == 429,
           let retryAfterValue = response.value(forHTTPHeaderField: "Retry-After"),
           let retryAfter = Int(retryAfterValue) {
            try? await Task.sleep(for: .seconds(Double(retryAfter)))
            return try await sendRequest(
                path: path,
                rawPath: rawPath,
                method: method,
                body: body,
                authConfig: authConfig
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            let message = Self.apiErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            if response.statusCode == 404, let path {
                throw SpotifyClientError.playlistNotFound(path)
            }
            throw SpotifyClientError.apiError(statusCode: response.statusCode, message: message)
        }

        return (data, response)
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        authConfig: SpotifyAuthConfig
    ) async throws -> SpotifyTokenBundle {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": authConfig.redirectURI,
            "client_id": authConfig.clientID,
            "code_verifier": verifier,
        ])

        let (data, response) = try await requestExecutor(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = Self.apiErrorMessage(from: data) ?? "Token exchange failed."
            throw SpotifyClientError.authorizationFailed(message)
        }

        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        guard let refreshToken = tokenResponse.refreshToken else {
            throw SpotifyClientError.authorizationFailed("Spotify did not return a refresh token.")
        }

        return SpotifyTokenBundle(
            accessToken: tokenResponse.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
    }

    private func refreshToken(
        _ currentBundle: SpotifyTokenBundle,
        authConfig: SpotifyAuthConfig
    ) async throws -> SpotifyTokenBundle {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token",
            "refresh_token": currentBundle.refreshToken,
            "client_id": authConfig.clientID,
        ])

        let (data, response) = try await requestExecutor(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = Self.apiErrorMessage(from: data) ?? "Token refresh failed."
            throw SpotifyClientError.authorizationFailed(message)
        }

        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        return SpotifyTokenBundle(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? currentBundle.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
    }

    private func listenForAuthorizationCode(
        redirectURI: String,
        expectedState: String
    ) async throws -> String {
        guard let redirectURL = URL(string: redirectURI),
              redirectURL.scheme == "http",
              let host = redirectURL.host,
              let port = redirectURL.port else {
            throw SpotifyClientError.invalidRedirectURI
        }

        let endpointPort = NWEndpoint.Port(rawValue: UInt16(port))
        guard let endpointPort else {
            throw SpotifyClientError.invalidRedirectURI
        }

        return try await withCheckedThrowingContinuation { continuation in
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: endpointPort)
            } catch {
                continuation.resume(throwing: error)
                return
            }

            let gate = SpotifyContinuationGate()

            @Sendable func finish(_ result: Result<String, SpotifyClientError>) {
                guard gate.claim() else { return }
                listener.cancel()
                continuation.resume(with: result)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    finish(.failure(.authorizationFailed(error.localizedDescription)))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: self.sessionQueue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, error in
                    if let error {
                        finish(.failure(.authorizationFailed(error.localizedDescription)))
                        return
                    }

                    guard let data, let requestText = String(data: data, encoding: .utf8) else {
                        finish(.failure(SpotifyClientError.authorizationCancelled))
                        return
                    }

                    let requestLine = requestText.split(separator: "\r\n", omittingEmptySubsequences: true).first
                    guard let requestLine,
                          let pathComponent = requestLine.split(separator: " ").dropFirst().first,
                          let callbackURL = URL(string: "http://\(host):\(port)\(pathComponent)"),
                          let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                        finish(.failure(SpotifyClientError.authorizationFailed("Spotify callback could not be parsed.")))
                        return
                    }

                    let code = components.queryItems?.first(where: { $0.name == "code" })?.value
                    let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
                    let errorDescription = components.queryItems?.first(where: { $0.name == "error_description" })?.value
                    let errorCode = components.queryItems?.first(where: { $0.name == "error" })?.value

                    let html = """
                    HTTP/1.1 200 OK\r
                    Content-Type: text/html; charset=utf-8\r
                    Connection: close\r
                    \r
                    <html><body><h2>SyncMusic</h2><p>You can close this window and return to the app.</p></body></html>
                    """
                    connection.send(content: Data(html.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })

                    if let errorCode {
                        finish(.failure(SpotifyClientError.authorizationFailed(errorDescription ?? errorCode)))
                        return
                    }

                    guard returnedState == expectedState else {
                        finish(.failure(SpotifyClientError.authorizationFailed("Spotify returned an unexpected state token.")))
                        return
                    }

                    guard let code else {
                        finish(.failure(SpotifyClientError.authorizationCancelled))
                        return
                    }

                    finish(.success(code))
                }
            }

            listener.start(queue: sessionQueue)

            sessionQueue.asyncAfter(deadline: .now() + 180) {
                finish(.failure(SpotifyClientError.authorizationCancelled))
            }
        }
    }

    private func selectCandidate(
        from candidates: [SpotifyTrackCandidate],
        for track: TrackSnapshot
    ) -> SpotifyTrackCandidate? {
        let normalizedTitle = Self.normalized(track.title)
        let normalizedArtist = Self.normalized(track.artist)
        let normalizedAlbum = Self.normalized(track.album)

        func artistMatches(_ candidate: SpotifyTrackCandidate) -> Bool {
            if normalizedArtist.isEmpty {
                return true
            }

            return candidate.artists.contains {
                Self.normalized($0.name) == normalizedArtist
            }
        }

        func albumMatches(_ candidate: SpotifyTrackCandidate) -> Bool {
            if normalizedAlbum.isEmpty {
                return true
            }

            return Self.normalized(candidate.album.name) == normalizedAlbum
        }

        if let exact = candidates.first(where: {
            Self.normalized($0.name) == normalizedTitle
                && artistMatches($0)
                && albumMatches($0)
        }) {
            return exact
        }

        if let strong = candidates.first(where: {
            Self.normalized($0.name) == normalizedTitle
                && artistMatches($0)
        }) {
            return strong
        }

        return nil
    }

    private static func authorizationURL(
        authConfig: SpotifyAuthConfig,
        challenge: String,
        state: String
    ) throws -> URL {
        guard var components = URLComponents(string: "https://accounts.spotify.com/authorize") else {
            throw SpotifyClientError.invalidRedirectURI
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: authConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: authConfig.redirectURI),
            URLQueryItem(name: "scope", value: "playlist-modify-private playlist-modify-public playlist-read-private user-read-private"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        guard let url = components.url else {
            throw SpotifyClientError.invalidRedirectURI
        }
        return url
    }

    private static func extractPlaylistID(from reference: String) throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw SpotifyClientError.playlistNotFound(reference)
        }

        if let url = URL(string: trimmed),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           url.host?.contains("spotify.com") == true {
            let parts = components.path.split(separator: "/")
            if let playlistIndex = parts.firstIndex(of: "playlist"), parts.indices.contains(playlistIndex + 1) {
                return String(parts[playlistIndex + 1])
            }
        }

        if trimmed.hasPrefix("spotify:playlist:") {
            return String(trimmed.dropFirst("spotify:playlist:".count))
        }

        return trimmed
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorObject = object["error"] as? [String: Any]
        else {
            return nil
        }

        if let message = errorObject["message"] as? String {
            return message
        }

        return nil
    }

    private static func formBody(_ fields: [String: String]) -> Data? {
        let pairs = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return pairs.joined(separator: "&").data(using: .utf8)
    }

    private static func randomToken(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in characters.randomElement() })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
