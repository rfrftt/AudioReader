import Foundation

actor APIClient {
    let baseURL: URL
    private var accessToken: String
    private var refreshToken: String
    private var tokensRefreshedHandler: (@Sendable (String, String) -> Void)?

    init(baseURL: URL, accessToken: String, refreshToken: String) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    var currentAccessToken: String { accessToken }
    var currentRefreshToken: String { refreshToken }

    func setTokensRefreshedHandler(_ handler: (@Sendable (String, String) -> Void)?) {
        tokensRefreshedHandler = handler
    }

    static func login(baseURL: URL, username: String, password: String) async throws -> LoginResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.httpBody = try JSONEncoder().encode(LoginRequest(username: username, password: password))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    func refreshTokens() async throws -> Bool {
        let oldAccess = accessToken
        let oldRefresh = refreshToken
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
        let payload = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard let newAccessToken = payload.user.accessToken else { return false }
        accessToken = newAccessToken
        if let newRefreshToken = payload.user.refreshToken {
            refreshToken = newRefreshToken
        }
        if accessToken != oldAccess || refreshToken != oldRefresh {
            tokensRefreshedHandler?(accessToken, refreshToken)
        }
        return true
    }

    func get<T: Decodable>(path: String, query: [URLQueryItem]?) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path, query: query))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    func post<T: Decodable, Body: Encodable>(path: String, body: Body) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path, query: nil))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    func postVoid<Body: Encodable>(path: String, body: Body) async throws {
        var request = URLRequest(url: try makeURL(path: path, query: nil))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            _ = try await sendRaw(request)
        } catch APIError.unauthorized {
            _ = try await refreshTokens()
            var retry = request
            retry.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            _ = try await sendRaw(retry)
        }
    }

    func patchVoid<Body: Encodable>(path: String, body: Body) async throws -> Bool {
        var request = URLRequest(url: try makeURL(path: path, query: nil))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await sendRaw(request)
        return true
    }

    func makeURL(path: String, query: [URLQueryItem]?) throws -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if let query, !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let data = try await sendRaw(request)
            return try JSONDecoder().decode(T.self, from: data)
        } catch APIError.unauthorized {
            _ = try await refreshTokens()
            var retry = request
            retry.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let data = try await sendRaw(retry)
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
        return data
    }
}

enum APIError: LocalizedError {
    case unauthorized
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "未授权（Token 失效）"
        case let .httpStatus(code, message): "HTTP \(code)：\(message)"
        }
    }
}

private func validateHTTP(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
        if http.statusCode == 401 { throw APIError.unauthorized }
        let message = String(data: data, encoding: .utf8) ?? ""
        throw APIError.httpStatus(http.statusCode, message)
    }
}

struct LoginRequest: Codable {
    var username: String
    var password: String
}

struct LoginResponse: Decodable {
    var user: LoginUser
    var userDefaultLibraryId: String?
}

struct LoginUser: Decodable {
    var id: String
    var username: String
    var accessToken: String?
    var refreshToken: String?
    var mediaProgress: [MediaProgress]?
}

struct MediaProgress: Decodable, Identifiable, Hashable {
    var id: String
    var libraryItemId: String
    var episodeId: String?
    var duration: Double?
    var progress: Double
    var currentTime: Double
    var isFinished: Bool?
    var lastUpdate: Double?
}

struct LibrariesResponse: Decodable {
    var libraries: [Library]
}

struct Library: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var displayOrder: Int
    var icon: String?
    var mediaType: String?
}

struct LibraryItemsResponse: Decodable {
    var results: [LibraryItemSummary]
    var total: Int?
}

struct LibraryItemSummary: Decodable, Identifiable, Hashable {
    var id: String
    var libraryId: String?
    var isFile: Bool?
    var mediaType: String?
    var media: LibraryItemMedia

    var displayTitle: String { media.metadata.title ?? "未命名" }
    var displayAuthor: String { media.metadata.authorName ?? "" }
}

struct LibraryItemDetail: Decodable, Identifiable, Hashable {
    var id: String
    var libraryId: String?
    var isFile: Bool?
    var mediaType: String?
    var media: LibraryItemMediaDetail

    var displayTitle: String { media.metadata.title ?? "未命名" }
    var displayAuthor: String { media.metadata.authorName ?? "" }
}

struct LibraryItemMedia: Decodable, Hashable {
    var id: String
    var metadata: MediaMetadata
    var coverPath: String?
    var duration: Double?
    var numTracks: Int?
    var numChapters: Int?
}

struct LibraryItemMediaDetail: Decodable, Hashable {
    var id: String
    var metadata: MediaMetadata
    var coverPath: String?
    var duration: Double?
    var numTracks: Int?
    var numChapters: Int?
}

struct MediaMetadata: Decodable, Hashable {
    var title: String?
    var subtitle: String?
    var authorName: String?
    var narratorName: String?
    var seriesName: String?
    var description: String?
    var descriptionPlain: String?
}

struct PlaybackStartRequest: Codable {
    var mediaPlayer: String
    var supportedMimeTypes: [String]
    var forceDirectPlay: Bool
    var forceTranscode: Bool
    var deviceInfo: DeviceInfoPayload?
}

struct DeviceInfoPayload: Codable {
    var deviceId: String?
}

struct PlaybackSessionResponse: Decodable, Hashable {
    var id: String
    var libraryItemId: String
    var episodeId: String?
    var displayTitle: String?
    var displayAuthor: String?
    var duration: Double?
    var startTime: Double?
    var currentTime: Double?
    var chapters: [Chapter]?
    var audioTracks: [AudioTrack]?
}

struct Chapter: Codable, Hashable, Identifiable {
    var id: Int
    var start: Double
    var end: Double
    var title: String
}

struct ChapterProgress: Hashable, Sendable {
    var chapterId: Int?
    var elapsed: Double
    var duration: Double
}

struct AudioTrack: Decodable, Hashable {
    var index: Int?
    var startOffset: Double?
    var duration: Double?
    var title: String?
    var contentUrl: String
    var mimeType: String?
}

struct SessionSyncRequest: Codable {
    var currentTime: Double
    var timeListened: Double
    var duration: Double
}

struct ContinueListeningEntry: Identifiable, Hashable {
    var id: String { progress.id }
    var progress: MediaProgress
    var item: LibraryItemSummary?
}

struct PlaybackSyncPayload: Sendable, Hashable {
    var sessionId: String
    var libraryItemId: String
    var episodeId: String?
    var currentTime: Double
    var timeListened: Double
    var duration: Double
    var isScrubbing: Bool
}
