//
//  ContentView.swift
//  AudioReader
//
//

import SwiftUI
import AVFoundation
import MediaPlayer
import Observation
import Security
import UIKit

enum ThemePreference: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@Observable
final class AppStore {
    struct Session: Codable, Equatable {
        var baseURLString: String
        var userId: String
        var username: String
        var accessToken: String
        var refreshToken: String
        var userDefaultLibraryId: String?

        var baseURL: URL? { URL(string: baseURLString) }
    }

    var isBootstrapping = true

    var serverHostInput = ""
    var serverScheme: ServerScheme = .https
    var serverPortInput = "443"
    var serverPathPrefixInput = ""
    var selectedServerProfileId: String?
    var serverProfiles: [ServerProfile] = []

    var usernameInput = ""
    var passwordInput = ""
    var authError: String?
    var isAuthenticating = false

    var session: Session?
    var libraries: [Library] = []
    var selectedLibraryId: String?
    var libraryItems: [LibraryItemSummary] = []
    var isLoadingLibraryItems = false
    var libraryItemsError: String?

    var homeContinueListening: [ContinueListeningEntry] = []
    var homeRecentAdded: [LibraryItemSummary] = []
    var isLoadingHome = false
    var homeError: String?

    var selectedItemDetail: LibraryItemDetail?
    var itemDetailError: String?
    var isLoadingItemDetail = false
    var cachedPlaybackSessions: [String: PlaybackSessionResponse] = [:]
    var cachedChapters: [String: [Chapter]] = [:]

    var showingPlayer = false
    var themePreference: ThemePreference = .system

    private let keychain = KeychainStore(service: "com.rfrftt.AudioReader")
    private var apiClient: APIClient?
    let player = AudioPlayerManager.shared

    init() {
        themePreference = loadThemePreference()
        loadServerProfiles()
        if let selected = selectedServerProfileId, let profile = serverProfiles.first(where: { $0.id == selected }) {
            applyServerProfile(profile)
        }
        player.onProgressTick = { [weak self] payload in
            guard let self else { return }
            Task { await self.syncProgress(payload: payload) }
        }
        player.onPlaybackEnded = { [weak self] payload in
            guard let self else { return }
            Task { await self.syncProgress(payload: payload, force: true) }
        }
    }

    @MainActor
    func bootstrap() async {
        defer { isBootstrapping = false }

        guard let savedSession = loadSessionFromKeychain() else {
            return
        }
        session = savedSession
        configureClientIfPossible()

        do {
            try await refreshTokenIfNeeded()
        } catch {
            if let apiError = error as? APIError, case .unauthorized = apiError {
                await signOut()
                return
            }
            homeError = error.localizedDescription
        }

        do {
            try await loadLibraries()
        } catch {
            if let apiError = error as? APIError, case .unauthorized = apiError {
                await signOut()
                return
            }
            libraryItemsError = error.localizedDescription
        }

        await loadHome()
    }

    func buildBaseURL() -> URL? {
        let trimmedHost = sanitizeServerText(serverHostInput)
        guard !trimmedHost.isEmpty else { return nil }

        var hostPart = trimmedHost
        var pathFromHost = ""
        if hostPart.contains("/") {
            let parts = hostPart.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            hostPart = String(parts.first ?? "")
            if parts.count > 1 {
                pathFromHost = "/" + sanitizeServerText(String(parts[1]))
            }
        }

        var port: Int? = Int(serverPortInput.trimmingCharacters(in: .whitespacesAndNewlines))
        if port == 0 { port = nil }
        if port == nil {
            port = (serverScheme == .https) ? 443 : 80
        }

        var components = URLComponents()
        components.scheme = serverScheme.rawValue
        components.host = hostPart
        components.port = port

        let prefix = sanitizeServerText(serverPathPrefixInput)
        let resolvedPrefix = prefix.isEmpty ? pathFromHost : prefix
        if !resolvedPrefix.isEmpty {
            components.path = resolvedPrefix.hasPrefix("/") ? resolvedPrefix : "/" + resolvedPrefix
        }

        return components.url
    }

    @MainActor
    func selectServerProfile(id: String?) {
        selectedServerProfileId = id
        saveServerProfiles()
        if let id, let profile = serverProfiles.first(where: { $0.id == id }) {
            applyServerProfile(profile)
        }
    }

    @MainActor
    func upsertServerProfile(_ profile: ServerProfile) {
        if let index = serverProfiles.firstIndex(where: { $0.id == profile.id }) {
            serverProfiles[index] = profile
        } else {
            serverProfiles.insert(profile, at: 0)
        }
        selectedServerProfileId = profile.id
        saveServerProfiles()
        applyServerProfile(profile)
    }

    @MainActor
    func deleteServerProfile(id: String) {
        serverProfiles.removeAll(where: { $0.id == id })
        if selectedServerProfileId == id {
            selectedServerProfileId = serverProfiles.first?.id
            if let next = serverProfiles.first {
                applyServerProfile(next)
            }
        }
        saveServerProfiles()
    }

    @MainActor
    func login() async {
        authError = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        guard let baseURL = buildBaseURL() else {
            authError = "请输入有效的服务器地址"
            return
        }
        let username = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordInput
        guard !username.isEmpty, !password.isEmpty else {
            authError = "请输入用户名和密码"
            return
        }

        do {
            _ = try await URLSession.shared.data(from: baseURL.appendingPathComponent("ping"))
            let response: LoginResponse = try await APIClient.login(baseURL: baseURL, username: username, password: password)
            guard let accessToken = response.user.accessToken, let refreshToken = response.user.refreshToken else {
                authError = "登录返回缺少 Token"
                return
            }
            let newSession = Session(
                baseURLString: normalizedBaseURLString(baseURL),
                userId: response.user.id,
                username: response.user.username,
                accessToken: accessToken,
                refreshToken: refreshToken,
                userDefaultLibraryId: response.userDefaultLibraryId
            )
            session = newSession
            saveSessionToKeychain(newSession)

            configureClientIfPossible()
            try await loadLibraries()
            await loadHome(fromLoginUser: response.user)
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                authError = "无法连接服务器，请检查地址/端口/网络"
            } else {
                authError = "登录失败：\(error.localizedDescription)"
            }
        }
    }

    @MainActor
    func signOut() async {
        player.stop()
        session = nil
        libraries = []
        selectedLibraryId = nil
        libraryItems = []
        homeContinueListening = []
        homeRecentAdded = []
        selectedItemDetail = nil
        apiClient = nil
        deleteSessionFromKeychain()
    }

    @MainActor
    func loadLibraries() async throws {
        guard let client = apiClient else { throw AppError.notAuthenticated }
        let response: LibrariesResponse = try await client.get(path: "/api/libraries", query: nil)
        libraries = response.libraries.sorted(by: { $0.displayOrder < $1.displayOrder })
        if selectedLibraryId == nil {
            selectedLibraryId = session?.userDefaultLibraryId ?? libraries.first?.id
        }
    }

    @MainActor
    func loadLibraryItems(libraryId: String) async {
        libraryItemsError = nil
        isLoadingLibraryItems = true
        defer { isLoadingLibraryItems = false }
        guard let client = apiClient else {
            libraryItemsError = "未登录"
            return
        }
        do {
            let response: LibraryItemsResponse = try await client.get(
                path: "/api/libraries/\(libraryId)/items",
                query: [
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "page", value: "0"),
                    URLQueryItem(name: "sort", value: "addedAt"),
                    URLQueryItem(name: "desc", value: "1")
                ]
            )
            libraryItems = response.results
        } catch {
            libraryItemsError = error.localizedDescription
        }
    }

    @MainActor
    func loadItemDetail(itemId: String) async {
        itemDetailError = nil
        isLoadingItemDetail = true
        defer { isLoadingItemDetail = false }
        guard let client = apiClient else {
            itemDetailError = "未登录"
            return
        }
        do {
            let detail: LibraryItemDetail = try await client.get(
                path: "/api/items/\(itemId)",
                query: [
                    URLQueryItem(name: "expanded", value: "1"),
                    URLQueryItem(name: "include", value: "progress")
                ]
            )
            selectedItemDetail = detail
        } catch {
            itemDetailError = error.localizedDescription
        }
    }

    @MainActor
    func startPlayback(itemId: String, episodeId: String? = nil, startAtOverride: Double? = nil) async {
        guard let client = apiClient, let baseURL = session?.baseURL else { return }
        do {
            let payload = PlaybackStartRequest(
                mediaPlayer: "ios",
                supportedMimeTypes: ["audio/mp4", "audio/mpeg", "audio/flac", "application/vnd.apple.mpegurl"],
                forceDirectPlay: false,
                forceTranscode: false,
                deviceInfo: DeviceInfoPayload(deviceId: UIDevice.current.identifierForVendor?.uuidString)
            )
            let sessionResponse: PlaybackSessionResponse
            if let episodeId {
                sessionResponse = try await client.post(path: "/api/items/\(itemId)/play/\(episodeId)", body: payload)
            } else {
                sessionResponse = try await client.post(path: "/api/items/\(itemId)/play", body: payload)
            }

            let localURL = try await resolveLocalFileURLIfAvailable(itemId: itemId)
            let token = await client.currentAccessToken
            cachedPlaybackSessions[itemId] = sessionResponse
            player.start(session: sessionResponse, baseURL: baseURL, accessToken: token, localOverrideURL: localURL, startAtOverride: startAtOverride)
            showingPlayer = true
        } catch {
            itemDetailError = "播放失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    func fetchPlaybackSessionForChapters(itemId: String) async throws -> PlaybackSessionResponse {
        if let cached = cachedPlaybackSessions[itemId], !(cached.chapters ?? []).isEmpty {
            return cached
        }
        guard let client = apiClient else { throw AppError.notAuthenticated }
        let payload = PlaybackStartRequest(
            mediaPlayer: "ios",
            supportedMimeTypes: ["audio/mp4", "audio/mpeg", "audio/flac", "application/vnd.apple.mpegurl"],
            forceDirectPlay: false,
            forceTranscode: false,
            deviceInfo: DeviceInfoPayload(deviceId: UIDevice.current.identifierForVendor?.uuidString)
        )
        let sessionResponse: PlaybackSessionResponse = try await client.post(path: "/api/items/\(itemId)/play", body: payload)
        cachedPlaybackSessions[itemId] = sessionResponse
        return sessionResponse
    }

    @MainActor
    func loadChaptersFromCache(itemId: String) -> [Chapter]? {
        cachedChapters[itemId]
    }

    func loadChaptersFromDisk(itemId: String) async -> [Chapter]? {
        let url = chapterCacheFileURL(itemId: itemId)
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([Chapter].self, from: data)
        }.value
    }

    func saveChaptersToDisk(itemId: String, chapters: [Chapter]) {
        let url = chapterCacheFileURL(itemId: itemId)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(chapters) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func chapterCacheFileURL(itemId: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("AudioReader", isDirectory: true)
            .appendingPathComponent("ChapterCache", isDirectory: true)
            .appendingPathComponent("\(itemId).json", isDirectory: false)
    }

    @MainActor
    func downloadIfPossible(item: LibraryItemDetail) async {
        guard item.isFile == true else {
            itemDetailError = "当前条目是多文件目录，暂仅支持单文件条目离线下载"
            return
        }
        guard let client = apiClient else {
            itemDetailError = "未登录"
            return
        }
        do {
            let url = try await client.makeURL(path: "/api/items/\(item.id)/download", query: nil)
            let destination = try DownloadStore.destinationURL(itemId: item.id, suggestedFilename: DownloadStore.sanitizedFilename("\(item.displayTitle).m4b"))
            let token = await client.currentAccessToken
            try await DownloadStore.download(from: url, bearerToken: token, to: destination)
        } catch {
            itemDetailError = "下载失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    func loadHome(fromLoginUser user: LoginUser? = nil) async {
        isLoadingHome = true
        homeError = nil
        defer { isLoadingHome = false }
        guard let client = apiClient else { return }

        let progresses = user?.mediaProgress ?? []
        let continueItems = progresses
            .filter { ($0.isFinished ?? false) == false }
            .sorted(by: { ($0.lastUpdate ?? 0) > ($1.lastUpdate ?? 0) })
            .prefix(10)
            .map { ContinueListeningEntry(progress: $0, item: nil) }
        homeContinueListening = Array(continueItems)

        await withTaskGroup(of: (Int, LibraryItemSummary?).self) { group in
            for (index, entry) in homeContinueListening.enumerated() {
                group.addTask {
                    do {
                        let item: LibraryItemSummary = try await client.get(path: "/api/items/\(entry.progress.libraryItemId)", query: nil)
                        return (index, item)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var updated = homeContinueListening
            for await (index, item) in group {
                if let item {
                    updated[index].item = item
                }
            }
            homeContinueListening = updated.filter { $0.item != nil }
        }

        if let libraryId = selectedLibraryId {
            do {
                let response: LibraryItemsResponse = try await client.get(
                    path: "/api/libraries/\(libraryId)/items",
                    query: [
                        URLQueryItem(name: "limit", value: "10"),
                        URLQueryItem(name: "page", value: "0"),
                        URLQueryItem(name: "sort", value: "addedAt"),
                        URLQueryItem(name: "desc", value: "1")
                    ]
                )
                homeRecentAdded = response.results
            } catch {
                homeRecentAdded = []
            }
        }
    }

    @MainActor
    private func configureClientIfPossible() {
        guard let session, let baseURL = session.baseURL else { return }
        let client = APIClient(baseURL: baseURL, accessToken: session.accessToken, refreshToken: session.refreshToken)
        apiClient = client
        let capturedSessionId = session.userId
        Task {
            await client.setTokensRefreshedHandler { [weak self] newAccess, newRefresh in
                guard let strongSelf = self else { return }
                Task { @MainActor in
                    guard var session = strongSelf.session, session.userId == capturedSessionId else { return }
                    if session.accessToken == newAccess, session.refreshToken == newRefresh { return }
                    session.accessToken = newAccess
                    session.refreshToken = newRefresh
                    strongSelf.session = session
                    strongSelf.saveSessionToKeychain(session)
                    strongSelf.player.updateAccessToken(newAccess)
                }
            }
        }
    }

    @MainActor
    private func refreshTokenIfNeeded() async throws {
        guard let client = apiClient else { return }
        let refreshed = try await client.refreshTokens()
        if refreshed, var session {
            session.accessToken = await client.currentAccessToken
            session.refreshToken = await client.currentRefreshToken
            self.session = session
            saveSessionToKeychain(session)
            player.updateAccessToken(session.accessToken)
        }
    }

    private func syncProgress(payload: PlaybackSyncPayload, force: Bool = false) async {
        guard let client = apiClient else { return }
        if !force, payload.isScrubbing { return }
        do {
            let body = SessionSyncRequest(
                currentTime: payload.currentTime,
                timeListened: payload.timeListened,
                duration: payload.duration
            )
            try await client.postVoid(path: "/api/session/\(payload.sessionId)/sync", body: body)
        } catch {
            return
        }
    }

    private func resolveLocalFileURLIfAvailable(itemId: String) async throws -> URL? {
        let folder = try DownloadStore.itemFolderURL(itemId: itemId)
        let candidates = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { !$0.hasDirectoryPath }
        return candidates.first
    }

    private func loadSessionFromKeychain() -> Session? {
        guard let json = keychain.getString(account: "session") else { return nil }
        return try? JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    private func saveSessionToKeychain(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session),
              let string = String(data: data, encoding: .utf8)
        else { return }
        keychain.setString(string, account: "session")
    }

    private func deleteSessionFromKeychain() {
        keychain.delete(account: "session")
    }

    private func normalizedBaseURLString(_ url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }

    private func sanitizeServerText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let junk = CharacterSet(charactersIn: ",，")
        return trimmed.trimmingCharacters(in: junk)
    }

    private func applyServerProfile(_ profile: ServerProfile) {
        serverScheme = profile.scheme
        serverHostInput = profile.host
        serverPortInput = profile.port
        serverPathPrefixInput = profile.pathPrefix
    }

    private func loadServerProfiles() {
        let defaults = UserDefaults.standard
        selectedServerProfileId = defaults.string(forKey: "server_profiles_selected_id")
        guard let data = defaults.data(forKey: "server_profiles_v1") else {
            let profile = defaultServerProfile(name: "默认服务器")
            serverProfiles = [profile]
            selectedServerProfileId = profile.id
            saveServerProfiles()
            return
        }
        do {
            serverProfiles = try JSONDecoder().decode([ServerProfile].self, from: data)
        } catch {
            let profile = defaultServerProfile(name: "默认服务器")
            serverProfiles = [profile]
            selectedServerProfileId = profile.id
            saveServerProfiles()
            return
        }

        if serverProfiles.isEmpty {
            let profile = defaultServerProfile(name: "默认服务器")
            serverProfiles = [profile]
            selectedServerProfileId = profile.id
            saveServerProfiles()
            return
        }

        if let selectedServerProfileId, serverProfiles.contains(where: { $0.id == selectedServerProfileId }) {
            return
        }
        selectedServerProfileId = serverProfiles.first?.id
        saveServerProfiles()
    }

    private func defaultServerProfile(name: String) -> ServerProfile {
        ServerProfile(
            id: UUID().uuidString,
            name: name,
            scheme: .https,
            host: "",
            port: "443",
            pathPrefix: ""
        )
    }

    private func saveServerProfiles() {
        let defaults = UserDefaults.standard
        defaults.setValue(selectedServerProfileId, forKey: "server_profiles_selected_id")
        if let data = try? JSONEncoder().encode(serverProfiles) {
            defaults.set(data, forKey: "server_profiles_v1")
        }
    }

    private func loadThemePreference() -> ThemePreference {
        let raw = UserDefaults.standard.string(forKey: "theme_preference") ?? ThemePreference.system.rawValue
        return ThemePreference(rawValue: raw) ?? .system
    }

    func setThemePreference(_ preference: ThemePreference) {
        themePreference = preference
        UserDefaults.standard.setValue(preference.rawValue, forKey: "theme_preference")
    }
}

enum ServerScheme: String, CaseIterable, Identifiable, Codable {
    case http
    case https
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

struct ServerProfile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var scheme: ServerScheme
    var host: String
    var port: String
    var pathPrefix: String
}

enum AppError: LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "未登录"
        }
    }
}

struct KeychainStore {
    let service: String

    func setString(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let attributes: [String: Any] = query.merging([kSecValueData as String: data]) { $1 }
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func getString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Unified Button Styles

struct PrimaryCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 44, height: 44)
            .foregroundStyle(.white)
            .background(Color.accentColor)
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct SecondaryIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 44, height: 44)
            .foregroundStyle(.accent)
            .background(Color(uiColor: .tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

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

@Observable
final class AudioPlayerManager {
    static let shared = AudioPlayerManager()

    private enum DefaultsKeys {
        static let rate = "player_rate_v1"
        static let skipEnabled = "player_skip_enabled_v1"
        static let skipIntroSeconds = "player_skip_intro_seconds_v1"
        static let skipOutroSeconds = "player_skip_outro_seconds_v1"
    }

    var isPlaying = false
    var isBuffering = false
    var isPlayRequested = false
    var title = ""
    var author = ""
    var coverURL: URL?
    var currentTime: Double = 0
    var duration: Double = 0
    var rate: Float = 1.0
    var skipEnabled = false
    var skipIntroSeconds: Double = 0
    var skipOutroSeconds: Double = 0
    var chapters: [Chapter] = []
    var currentChapterId: Int?
    var currentChapterIndex: Int?
    var currentChapterTitle: String?
    var currentChapterStart: Double = 0
    var currentChapterDuration: Double = 0
    var currentChapterElapsed: Double = 0
    var chapterProgress = ChapterProgress(chapterId: nil, elapsed: 0, duration: 1)
    var libraryItemId: String?
    var episodeId: String?
    var sessionId: String?
    var isScrubbing = false

    var onProgressTick: (@Sendable (PlaybackSyncPayload) -> Void)?
    var onPlaybackEnded: (@Sendable (PlaybackSyncPayload) -> Void)?

    private struct TrackInfo: Hashable {
        var contentPath: String
        var localURL: URL?
        var startOffset: Double
        var duration: Double
    }

    private var player: AVPlayer?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var progressTimer: Timer?
    private var sleepTimer: Timer?
    private var remoteCommandsConfigured = false
    private var tracks: [TrackInfo] = []
    private var playerItems: [AVPlayerItem] = []
    private var playlistStartIndex: Int = 0
    private var lastSyncWallTime: CFTimeInterval?
    private var activeCommandToken = UUID()
    private var audioSessionConfigured = false
    private var lifecycleObserversInstalled = false
    private var wasPlayingBeforeInterruption = false
    private var lastAutoIntroChapterId: Int?
    private var lastAutoOutroChapterId: Int?
    private var isSeeking = false
    private var playbackBaseURL: URL?
    private var accessToken: String?
    private var isRebuildingForToken = false

    private init() {
        loadPreferences()
    }

    @MainActor
    func start(session: PlaybackSessionResponse, baseURL: URL, accessToken: String, localOverrideURL: URL?, startAtOverride: Double?) {
        stop()

        playbackBaseURL = baseURL
        self.accessToken = accessToken
        let newTracks = makeTrackList(session: session, localOverrideURL: localOverrideURL)
        guard !newTracks.isEmpty else { return }

        sessionId = session.id
        libraryItemId = session.libraryItemId
        episodeId = session.episodeId
        title = session.displayTitle ?? title
        author = session.displayAuthor ?? author
        duration = session.duration ?? duration
        chapters = session.chapters ?? []
        tracks = newTracks

        let rawStartAt = max(0, startAtOverride ?? session.currentTime ?? session.startTime ?? 0)
        let startAt = adjustedStartTimeForIntroIfNeeded(rawStartAt)
        currentTime = startAt
        updateCurrentChapterContext()

        configureAudioSession(force: false, allowDeactivate: true)
        installAppLifecycleObserversIfNeeded()
        setupRemoteCommandsIfNeeded()
        buildPlayer(startAtGlobalTime: startAt)
        updateNowPlaying()
        let token = beginCommand()
        jumpToGlobalTime(startAt, autoplay: true, commandToken: token, completion: nil)
    }

    @MainActor
    func updateAccessToken(_ newToken: String) {
        guard !newToken.isEmpty else { return }
        if accessToken == newToken { return }
        accessToken = newToken
        guard sessionId != nil else { return }
        guard !isScrubbing, !isSeeking else { return }
        guard !isRebuildingForToken else { return }
        isRebuildingForToken = true
        let preservedTime = currentTime
        let shouldAutoplay = isPlayRequested
        buildPlayer(startAtGlobalTime: preservedTime)
        updateNowPlaying()
        let token = beginCommand()
        jumpToGlobalTime(preservedTime, autoplay: shouldAutoplay, commandToken: token) { [weak self] in
            guard let self else { return }
            isRebuildingForToken = false
        }
    }

    private func adjustedStartTimeForIntroIfNeeded(_ time: Double) -> Double {
        guard skipEnabled, skipIntroSeconds > 0 else { return time }
        guard !chapters.isEmpty else { return time }
        let t = max(0, time)
        let intro = skipIntroSeconds
        guard intro > 0 else { return t }
        let index = chapterIndex(forGlobalTime: t)
        guard index >= 0, index < chapters.count else { return t }
        let start = max(0, chapters[index].start)
        let end: Double
        if index + 1 < chapters.count {
            end = max(start, chapters[index + 1].start)
        } else if duration > 0 {
            end = max(start, duration)
        } else {
            end = start
        }
        let chapterDuration = max(0, end - start)
        let maxIntro = max(0, chapterDuration - 1)
        let resolved = min(intro, maxIntro)
        guard resolved > 0 else { return t }
        let target = start + resolved
        if t <= target - 0.25 { return target }
        return t
    }

    private func chapterIndex(forGlobalTime time: Double) -> Int {
        guard !chapters.isEmpty else { return 0 }
        let t = max(0, time.isFinite ? time : 0)
        let target = t + 0.001
        var low = 0
        var high = chapters.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if chapters[mid].start <= target {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    func togglePlayPause() {
        isPlayRequested ? pause() : play()
    }

    func play() {
        isPlayRequested = true
        if !audioSessionConfigured {
            Task { @MainActor in
                configureAudioSession(force: true, allowDeactivate: false)
            }
        }
        if lastSyncWallTime == nil {
            lastSyncWallTime = CACurrentMediaTime()
        }
        if let player {
            player.playImmediately(atRate: rate)
            if player.timeControlStatus != .playing {
                isBuffering = true
            }
        }
        updateNowPlaying()
    }

    func pause() {
        isPlayRequested = false
        player?.pause()
        isPlaying = false
        isBuffering = false
        progressTimer?.invalidate()
        progressTimer = nil
        updateNowPlaying()
        tickProgress(force: true)
    }

    func stop() {
        isPlayRequested = false
        sleepTimer?.invalidate()
        sleepTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        NotificationCenter.default.removeObserver(self)
        lifecycleObserversInstalled = false

        timeControlStatusObservation = nil
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player?.pause()
        player = nil
        playerItems = []
        tracks = []
        playlistStartIndex = 0
        lastSyncWallTime = nil
        isPlaying = false
        isBuffering = false
        isScrubbing = false
        currentTime = 0
        duration = 0
        chapters = []
        currentChapterId = nil
        currentChapterIndex = nil
        currentChapterTitle = nil
        currentChapterStart = 0
        currentChapterDuration = 0
        currentChapterElapsed = 0
        chapterProgress = ChapterProgress(chapterId: nil, elapsed: 0, duration: 1)
        libraryItemId = nil
        episodeId = nil
        sessionId = nil
        playbackBaseURL = nil
        accessToken = nil
        isRebuildingForToken = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func pauseForSystem() {
        player?.pause()
        isPlaying = false
        isBuffering = false
        progressTimer?.invalidate()
        progressTimer = nil
        updateNowPlaying()
    }

    func seek(to time: Double, autoplay: Bool = false) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        currentTime = clamped
        updateCurrentChapterContext()
        updateNowPlaying()
        isSeeking = true
        let token = beginCommand()
        jumpToGlobalTime(clamped, autoplay: autoplay, commandToken: token) { [weak self] in
            guard let self else { return }
            guard self.activeCommandToken == token else { return }
            isSeeking = false
            tickProgress(force: true)
        }
    }

    func skip(seconds: Double) {
        seek(to: currentTime + seconds, autoplay: isPlayRequested)
    }

    func jumpToChapter(_ chapter: Chapter) {
        let target = adjustedStartTimeForIntroIfNeeded(chapter.start)
        seek(to: target, autoplay: true)
    }

    func nextChapter() {
        guard !chapters.isEmpty else { return }
        let idx = currentChapterIndex ?? chapterIndex(forGlobalTime: currentTime)
        let nextIndex = idx + 1
        guard nextIndex >= 0, nextIndex < chapters.count else { return }
        jumpToChapter(chapters[nextIndex])
    }

    func previousChapter() {
        guard !chapters.isEmpty else { return }
        let idx = currentChapterIndex ?? chapterIndex(forGlobalTime: currentTime)
        let prevIndex = idx - 1
        guard prevIndex >= 0 else {
            seek(to: 0, autoplay: true)
            return
        }
        guard prevIndex < chapters.count else { return }
        jumpToChapter(chapters[prevIndex])
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if let player {
            if isPlayRequested {
                player.playImmediately(atRate: newRate)
            } else {
                player.pause()
            }
        }
        savePreferences()
        updateNowPlaying()
    }

    func setSkipEnabled(_ enabled: Bool) {
        skipEnabled = enabled
        lastAutoIntroChapterId = nil
        lastAutoOutroChapterId = nil
        savePreferences()
    }

    func setSkipIntroSeconds(_ seconds: Double) {
        skipIntroSeconds = max(0, seconds)
        lastAutoIntroChapterId = nil
        savePreferences()
    }

    func setSkipOutroSeconds(_ seconds: Double) {
        skipOutroSeconds = max(0, seconds)
        lastAutoOutroChapterId = nil
        savePreferences()
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let minutes, minutes > 0 else { return }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.pause()
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.tickProgress(force: false)
        }
    }

    private func tickProgress(force: Bool) {
        guard let sessionId, let libraryItemId else { return }
        let now = CACurrentMediaTime()
        let timeListened: Double
        if isPlaying, !isScrubbing, !isSeeking {
            if let lastSyncWallTime {
                let delta = max(0, now - lastSyncWallTime)
                timeListened = min(delta * Double(rate), 30)
            } else {
                timeListened = 0
            }
        } else {
            timeListened = 0
        }
        lastSyncWallTime = now
        let payload = PlaybackSyncPayload(
            sessionId: sessionId,
            libraryItemId: libraryItemId,
            episodeId: episodeId,
            currentTime: currentTime,
            timeListened: timeListened,
            duration: max(duration, 0),
            isScrubbing: isScrubbing
        )
        if force {
            onPlaybackEnded?(payload)
        } else {
            onProgressTick?(payload)
        }
    }

    @objc private func itemDidFinish(_ notification: Notification) {
        if tracks.count > 1 {
            guard let finishedItem = notification.object as? AVPlayerItem else { return }
            if finishedItem !== playerItems.last { return }
        }
        pause()
    }

    @MainActor
    private func configureAudioSession(force: Bool, allowDeactivate: Bool) {
        if audioSessionConfigured, !force { return }
        let session = AVAudioSession.sharedInstance()
        if allowDeactivate {
            try? session.setActive(false)
        }

        let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.playback, .default, []),
            (.playback, .spokenAudio, []),
            (.playback, .moviePlayback, []),
            (.playback, .default, [.allowAirPlay]),
            (.playback, .spokenAudio, [.allowAirPlay])
        ]

        for (category, mode, options) in attempts {
            do {
                try session.setCategory(category, mode: mode, options: options)
                try session.setActive(true)
                audioSessionConfigured = true
                return
            } catch {
                continue
            }
        }

        do {
            try session.setCategory(.playback)
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            audioSessionConfigured = false
        }
    }

    private func installAppLifecycleObserversIfNeeded() {
        guard !lifecycleObserversInstalled else { return }
        lifecycleObserversInstalled = true
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleMediaServicesReset(_:)), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        guard sessionId != nil else { return }
        Task { @MainActor in
            configureAudioSession(force: true, allowDeactivate: false)
            ensurePlaybackContinuesIfNeeded()
        }
    }

    @objc private func appWillEnterForeground() {
        guard sessionId != nil else { return }
        Task { @MainActor in
            configureAudioSession(force: true, allowDeactivate: false)
            ensurePlaybackContinuesIfNeeded()
        }
    }

    @objc private func appDidBecomeActive() {
        guard sessionId != nil else { return }
        Task { @MainActor in
            configureAudioSession(force: true, allowDeactivate: false)
            ensurePlaybackContinuesIfNeeded()
        }
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt
        let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlayRequested
            pauseForSystem()
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = optionsValue.flatMap(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Task { @MainActor in
                configureAudioSession(force: true, allowDeactivate: true)
                if (options.contains(.shouldResume) || wasPlayingBeforeInterruption), sessionId != nil {
                    play()
                }
            }
        default:
            return
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        Task { @MainActor in
            configureAudioSession(force: true, allowDeactivate: true)
            if sessionId != nil, isPlaying {
                play()
            }
        }
    }

    @MainActor
    private func ensurePlaybackContinuesIfNeeded() {
        guard isPlayRequested else { return }
        guard let player else { return }
        if player.timeControlStatus != .playing {
            player.playImmediately(atRate: rate)
        }
    }

    private func setupRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextChapter()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousChapter()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime, autoplay: true)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard !title.isEmpty else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func makeTrackList(session: PlaybackSessionResponse, localOverrideURL: URL?) -> [TrackInfo] {
        if let localOverrideURL {
            return [TrackInfo(contentPath: "", localURL: localOverrideURL, startOffset: 0, duration: max(session.duration ?? 0, 0))]
        }
        let audioTracks = session.audioTracks ?? []
        let mapped = audioTracks.map { track in
            TrackInfo(
                contentPath: track.contentUrl,
                localURL: nil,
                startOffset: max(track.startOffset ?? 0, 0),
                duration: max(track.duration ?? 0, 0)
            )
        }
        return mapped.sorted(by: { $0.startOffset < $1.startOffset })
    }

    private func resolvedURL(for track: TrackInfo) -> URL? {
        if let localURL = track.localURL {
            return localURL
        }
        guard let baseURL = playbackBaseURL else { return nil }
        let token = accessToken ?? ""
        if track.contentPath.hasPrefix("/api/"), token.isEmpty {
            return nil
        }
        return AudioPlayerManager.buildPlayableURL(baseURL: baseURL, path: track.contentPath, accessToken: token)
    }

    private func buildPlayer(startAtGlobalTime: Double) {
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        timeControlStatusObservation = nil
        player?.pause()
        player = nil

        if tracks.count <= 1 {
            playlistStartIndex = 0
            guard let url = resolvedURL(for: tracks[0]) else { return }
            let item = AVPlayerItem(url: url)
            playerItems = [item]
            player = AVPlayer(playerItem: item)
            player?.pause()
            NotificationCenter.default.addObserver(self, selector: #selector(itemDidFinish(_:)), name: .AVPlayerItemDidPlayToEndTime, object: item)
            installPlaybackStateObserver()
            installTimeObserver()
            return
        }

        let startIndex = trackIndex(forGlobalTime: startAtGlobalTime)
        playlistStartIndex = startIndex
        let urls = tracks[startIndex...].compactMap { resolvedURL(for: $0) }
        guard urls.count == tracks[startIndex...].count else { return }
        let items = urls.map { AVPlayerItem(url: $0) }
        playerItems = Array(items)
        let queue = AVQueuePlayer(items: playerItems)
        queue.actionAtItemEnd = .advance
        player = queue
        player?.pause()
        for item in playerItems {
            NotificationCenter.default.addObserver(self, selector: #selector(itemDidFinish(_:)), name: .AVPlayerItemDidPlayToEndTime, object: item)
        }
        installPlaybackStateObserver()
        installTimeObserver()
    }

    private func installPlaybackStateObserver() {
        guard let player else { return }
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard let self else { return }
            switch player.timeControlStatus {
            case .playing:
                if !isPlaying { isPlaying = true }
                if isBuffering { isBuffering = false }
                if isPlayRequested {
                    if lastSyncWallTime == nil {
                        lastSyncWallTime = CACurrentMediaTime()
                    }
                    startProgressTimer()
                }
            case .waitingToPlayAtSpecifiedRate:
                if isPlaying { isPlaying = false }
                if !isBuffering { isBuffering = true }
                progressTimer?.invalidate()
                progressTimer = nil
            case .paused:
                if isPlaying { isPlaying = false }
                if isBuffering { isBuffering = false }
                progressTimer?.invalidate()
                progressTimer = nil
            @unknown default:
                if isBuffering { isBuffering = false }
            }
            updateNowPlaying()
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if isScrubbing || isSeeking { return }
            if let item = player?.currentItem, let localIndex = playerItems.firstIndex(where: { $0 === item }) {
                let globalIndex = playlistStartIndex + localIndex
                if globalIndex < tracks.count {
                    let base = tracks[globalIndex].startOffset
                    let t = time.seconds.isFinite ? time.seconds : 0
                    currentTime = max(0, base + t)
                }
            } else {
                let t = time.seconds.isFinite ? time.seconds : 0
                currentTime = max(0, t)
            }
            if duration == 0, let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 {
                duration = d
            }
            updateNowPlaying()
            updateCurrentChapterContext()
            applyAutoSkipIfNeeded()
        }
    }

    private func applyAutoSkipIfNeeded() {
        guard skipEnabled else { return }
        guard !isScrubbing, !isSeeking else { return }
        guard isPlayRequested else { return }
        guard let chapterId = currentChapterId else { return }
        guard currentChapterDuration > 0 else { return }

        if skipIntroSeconds > 0 {
            if lastAutoIntroChapterId != chapterId {
                lastAutoIntroChapterId = chapterId
                let maxIntro = max(0, currentChapterDuration - 1)
                let intro = min(skipIntroSeconds, maxIntro)
                if intro > 0 {
                    let target = currentChapterStart + intro
                    if currentTime < target - 0.25 {
                        seek(to: target, autoplay: true)
                        return
                    }
                }
            }
        }

        if skipOutroSeconds > 0 {
            if lastAutoOutroChapterId != chapterId {
                let outro = min(skipOutroSeconds, max(0, currentChapterDuration - 1))
                guard outro > 0 else { return }
                guard currentChapterDuration > outro + 1 else { return }
                let chapterEnd = currentChapterStart + currentChapterDuration
                let remaining = max(0, chapterEnd - currentTime)
                if remaining <= outro + 0.25, remaining > 0.15 {
                    lastAutoOutroChapterId = chapterId
                    if let idx = currentChapterIndex, idx + 1 < chapters.count {
                        nextChapter()
                    } else {
                        pause()
                    }
                }
            }
        }
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKeys.rate) != nil {
            rate = defaults.float(forKey: DefaultsKeys.rate)
        } else {
            rate = 1.0
        }
        skipEnabled = defaults.bool(forKey: DefaultsKeys.skipEnabled)
        let intro = defaults.double(forKey: DefaultsKeys.skipIntroSeconds)
        let outro = defaults.double(forKey: DefaultsKeys.skipOutroSeconds)
        skipIntroSeconds = max(0, intro)
        skipOutroSeconds = max(0, outro)
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(rate, forKey: DefaultsKeys.rate)
        defaults.set(skipEnabled, forKey: DefaultsKeys.skipEnabled)
        defaults.set(skipIntroSeconds, forKey: DefaultsKeys.skipIntroSeconds)
        defaults.set(skipOutroSeconds, forKey: DefaultsKeys.skipOutroSeconds)
    }

    private func updateCurrentChapterContext() {
        guard !chapters.isEmpty else {
            if currentChapterId != nil { currentChapterId = nil }
            if currentChapterIndex != nil { currentChapterIndex = nil }
            if currentChapterTitle != nil { currentChapterTitle = nil }
            if currentChapterStart != 0 { currentChapterStart = 0 }
            let d = max(1, max(0, duration))
            if currentChapterDuration != d { currentChapterDuration = d }
            let elapsed = max(0, min(currentTime, d))
            if currentChapterElapsed != elapsed { currentChapterElapsed = elapsed }
            let p = ChapterProgress(chapterId: nil, elapsed: elapsed, duration: d)
            if chapterProgress != p { chapterProgress = p }
            return
        }

        let t = max(0, currentTime.isFinite ? currentTime : 0)
        let count = chapters.count
        var low = 0
        var high = count - 1
        var best = 0
        let target = t + 0.001
        while low <= high {
            let mid = (low + high) / 2
            if chapters[mid].start <= target {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let start = max(0, chapters[best].start)
        let end: Double
        if best + 1 < count {
            end = max(start, chapters[best + 1].start)
        } else if duration > 0 {
            end = max(start, duration)
        } else {
            end = start + 1
        }
        let newId = chapters[best].id
        let newIndex = best
        let newTitle = chapters[best].title
        let newStart = start
        let newDuration = max(1, end - start)
        let newElapsed = max(0, min(t - newStart, newDuration))

        if currentChapterId != newId { currentChapterId = newId }
        if currentChapterIndex != newIndex { currentChapterIndex = newIndex }
        if currentChapterTitle != newTitle { currentChapterTitle = newTitle }
        if currentChapterStart != newStart { currentChapterStart = newStart }
        if currentChapterDuration != newDuration { currentChapterDuration = newDuration }
        if currentChapterElapsed != newElapsed { currentChapterElapsed = newElapsed }
        let p = ChapterProgress(chapterId: newId, elapsed: newElapsed, duration: newDuration)
        if chapterProgress != p { chapterProgress = p }
    }

    private func trackIndex(forGlobalTime time: Double) -> Int {
        if tracks.count <= 1 { return 0 }
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        for i in 0..<tracks.count {
            let start = tracks[i].startOffset
            let end = start + tracks[i].duration
            if clamped >= start && (tracks[i].duration <= 0 || clamped < end) {
                return i
            }
        }
        return max(0, tracks.count - 1)
    }

    private func jumpToGlobalTime(_ time: Double, autoplay: Bool, commandToken: UUID, completion: (() -> Void)?) {
        if tracks.count <= 1 {
            guard let player else {
                completion?()
                return
            }
            let cm = CMTime(seconds: time, preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { return }
                guard self.activeCommandToken == commandToken else { return }
                if autoplay { self.play() }
                completion?()
            }
            return
        }

        let targetIndex = trackIndex(forGlobalTime: time)
        if targetIndex != playlistStartIndex {
            buildPlayer(startAtGlobalTime: time)
        }
        guard let player else {
            completion?()
            return
        }

        let seekInItem = max(0, time - tracks[targetIndex].startOffset)
        let cm = CMTime(seconds: seekInItem, preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            guard self.activeCommandToken == commandToken else { return }
            if autoplay { self.play() }
            completion?()
        }
    }

    private func beginCommand() -> UUID {
        let token = UUID()
        activeCommandToken = token
        return token
    }

    private static func buildPlayableURL(baseURL: URL, path: String, accessToken: String) -> URL? {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appendingPathComponent(normalized)
        if path.hasPrefix("/api/") {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "token", value: accessToken))
            components.queryItems = items
            return components.url
        }
        return url
    }
}

enum DownloadStore {
    static func sanitizedFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = filename
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }

    static func itemFolderURL(itemId: String) throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = docs.appendingPathComponent("Downloads").appendingPathComponent(itemId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func destinationURL(itemId: String, suggestedFilename: String) throws -> URL {
        let folder = try itemFolderURL(itemId: itemId)
        return folder.appendingPathComponent(suggestedFilename)
    }

    static func download(from url: URL, bearerToken: String, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.httpStatus(http.statusCode, "下载失败")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}

struct RootView: View {
    @State private var store = AppStore()

    var body: some View {
        @Bindable var store = store
        Group {
            if store.isBootstrapping {
                ProgressView("加载中…")
            } else if store.session == nil {
                AuthView()
            } else {
                MainTabView()
            }
        }
        .environment(store)
        .preferredColorScheme(store.themePreference.colorScheme)
        .fullScreenCover(isPresented: $store.showingPlayer) {
            PlayerView()
                .environment(store)
        }
        .task {
            await store.bootstrap()
        }
    }
}

struct AuthView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .shadow(radius: 12)
                        Text("AudioReader")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    .padding(.top, 24)

                    AuthCard(title: "服务器配置") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Picker("配置", selection: $store.selectedServerProfileId) {
                                    ForEach(store.serverProfiles) { profile in
                                        Text(profile.displayName).tag(Optional(profile.id))
                                    }
                                }
                                .pickerStyle(.menu)

                                Spacer()

                                NavigationLink {
                                    ServerManagerView()
                                } label: {
                                    Label("管理", systemImage: "server.rack")
                                }
                                .buttonStyle(.bordered)
                            }

                            if let url = store.buildBaseURL() {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("地址预览")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(url.absoluteString)
                                        .font(.footnote)
                                        .monospaced()
                                        .textSelection(.enabled)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            } else {
                                Text("请先填写服务器地址")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    AuthCard(title: "服务器") {
                        Picker("", selection: $store.serverScheme) {
                            Text("HTTPS").tag(ServerScheme.https)
                            Text("HTTP").tag(ServerScheme.http)
                        }
                        .pickerStyle(.segmented)
                        AuthField(title: "域名或 IP（可含路径）", text: $store.serverHostInput, isSecure: false, keyboard: .default)
                        Text("示例：demo.com 或 192.168.1.2 或 demo.com/abs")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        AuthField(title: "端口", text: $store.serverPortInput, isSecure: false, keyboard: .numberPad)
                        AuthField(title: "路径前缀（可选，如 /abs）", text: $store.serverPathPrefixInput, isSecure: false, keyboard: .default)
                    }

                    AuthCard(title: "账号") {
                        AuthField(title: "用户名", text: $store.usernameInput, isSecure: false, keyboard: .default)
                        AuthField(title: "密码", text: $store.passwordInput, isSecure: true, keyboard: .default)

                        Button(store.isAuthenticating ? "登录中…" : "登录") {
                            Task { await store.login() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isAuthenticating)
                        Text("点击登录将自动验证服务器联通性并完成登录").foregroundStyle(.secondary).font(.footnote)
                        if let error = store.authError {
                            Text(error).foregroundStyle(.red).font(.footnote)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: store.serverScheme) {
                if store.serverPortInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.serverPortInput = (store.serverScheme == .https) ? "443" : "80"
                } else if store.serverPortInput == "80", store.serverScheme == .https {
                    store.serverPortInput = "443"
                } else if store.serverPortInput == "443", store.serverScheme == .http {
                    store.serverPortInput = "80"
                }
            }
            .onChange(of: store.selectedServerProfileId) { _, newValue in
                store.selectServerProfile(id: newValue)
            }
        }
    }
}

struct AuthCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct AuthField: View {
    let title: String
    @Binding var text: String
    let isSecure: Bool
    let keyboard: UIKeyboardType

    var body: some View {
        Group {
            if isSecure {
                SecureField(title, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField(title, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(keyboard)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ServerManagerView: View {
    @Environment(AppStore.self) private var store
    @State private var editingProfile: ServerProfile?

    var body: some View {
        @Bindable var store = store
        Group {
            if store.serverProfiles.isEmpty {
                ContentUnavailableView("暂无服务器", systemImage: "server.rack", description: Text("点击右上角“新增”添加服务器配置"))
            } else {
                List {
                    ForEach(store.serverProfiles) { profile in
                        Button {
                            store.selectServerProfile(id: profile.id)
                            Task { await store.signOut() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.displayName)
                                    Text(profile.displayAddress)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if store.selectedServerProfileId == profile.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("编辑") {
                                editingProfile = profile
                            }
                            Button("删除", role: .destructive) {
                                store.deleteServerProfile(id: profile.id)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("服务器管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("新增") {
                    editingProfile = ServerProfile(
                        id: UUID().uuidString,
                        name: "新服务器",
                        scheme: .https,
                        host: "",
                        port: "443",
                        pathPrefix: ""
                    )
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            ServerProfileEditorView(
                profile: profile,
                title: (store.serverProfiles.contains(where: { $0.id == profile.id }) ? "编辑服务器" : "新增服务器")
            ) { updated in
                store.upsertServerProfile(updated)
                editingProfile = nil
            } onCancel: {
                editingProfile = nil
            }
        }
    }
}

struct ServerProfileEditorView: View {
    @State var profile: ServerProfile
    let title: String
    var onSave: (ServerProfile) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("名称", text: $profile.name)
                }
                Section("地址") {
                    Picker("协议", selection: $profile.scheme) {
                        ForEach(ServerScheme.allCases) { scheme in
                            Text(scheme.title).tag(scheme)
                        }
                    }
                    TextField("域名或IP", text: $profile.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $profile.port)
                        .keyboardType(.numberPad)
                    TextField("路径前缀（可选）", text: $profile.pathPrefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { onSave(profile) }
                        .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

extension ServerProfile {
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名服务器" : trimmed
    }

    var displayAddress: String {
        let hostPart = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portPart = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = prefix.isEmpty ? "" : (prefix.hasPrefix("/") ? prefix : "/" + prefix)
        return "\(scheme.title) \(hostPart):\(portPart)\(path)"
    }
}

struct MainTabView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "house") }
            LibraryView()
                .tabItem { Label("媒体库", systemImage: "books.vertical") }
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person") }
        }
        .overlay(alignment: .bottom) {
            MiniPlayerBar()
                .padding(.bottom, 60)
        }
        .task(id: store.selectedLibraryId) {
            if let id = store.selectedLibraryId {
                await store.loadLibraryItems(libraryId: id)
            }
        }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.isLoadingHome {
                        ProgressView().frame(maxWidth: .infinity)
                    }

                    if let error = store.homeError {
                        Text(error).foregroundStyle(.red)
                    }

                    if !store.homeContinueListening.isEmpty {
                        SectionHeader(title: "继续收听")
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(store.homeContinueListening) { entry in
                                    if let item = entry.item {
                                        NavigationLink {
                                            ItemDetailView(itemId: item.id)
                                        } label: {
                                            ContinueListeningCard(item: item, progress: entry.progress)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .scrollIndicators(.hidden)
                    }

                    if !store.homeRecentAdded.isEmpty {
                        SectionHeader(title: "最近添加")
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(store.homeRecentAdded) { item in
                                    NavigationLink {
                                        ItemDetailView(itemId: item.id)
                                    } label: {
                                        RecentAddedCard(item: item)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .padding(.top, 12)
            }
            .navigationTitle("首页")
            .refreshable {
                await store.loadHome()
            }
        }
    }
}

struct LibraryView: View {
    @Environment(AppStore.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            VStack(spacing: 0) {
                if !store.libraries.isEmpty {
                    Picker("库", selection: $store.selectedLibraryId) {
                        ForEach(store.libraries) { lib in
                            Text(lib.name).tag(Optional(lib.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 12)
                }

                if store.isLoadingLibraryItems {
                    ProgressView().padding()
                } else if let error = store.libraryItemsError {
                    Text(error).foregroundStyle(.red).padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(store.libraryItems) { item in
                                NavigationLink {
                                    ItemDetailView(itemId: item.id)
                                } label: {
                                    LibraryGridCard(item: item)
                                }
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        if let id = store.selectedLibraryId {
                            await store.loadLibraryItems(libraryId: id)
                        }
                    }
                }
            }
            .navigationTitle("媒体库")
        }
    }
}

struct SearchView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var searchTask: Task<Void, Never>?

    var filtered: [LibraryItemSummary] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.libraryItems }
        return store.libraryItems.filter { item in
            item.displayTitle.localizedCaseInsensitiveContains(q) || item.displayAuthor.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { item in
                    HStack(spacing: 12) {
                        NavigationLink {
                            ItemDetailView(itemId: item.id)
                        } label: {
                            HStack(spacing: 12) {
                                CoverImageView(itemId: item.id, size: 54)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayTitle).lineLimit(2)
                                    if !item.displayAuthor.isEmpty {
                                        Text(item.displayAuthor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        Spacer()
                        Button {
                            Task { await store.startPlayback(itemId: item.id) }
                        } label: {
                            Image(systemName: "play.fill").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                        }
                        .buttonStyle(SecondaryIconButtonStyle())
                    }
                }
            }
            .searchable(text: $query, prompt: "在当前库内搜索")
            .listStyle(.insetGrouped)
            .navigationTitle("搜索")
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await MainActor.run { debouncedQuery = newValue }
                }
            }
        }
    }
}

struct ProfileView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section("当前账号") {
                    Text(store.session?.username ?? "-")
                }
                Section("服务器") {
                    Text(store.session?.baseURLString ?? "-")
                }
                Section("播放") {
                    Picker("默认倍速", selection: Binding(
                        get: { store.player.rate },
                        set: { store.player.setRate($0) }
                    )) {
                        Text("0.75x").tag(Float(0.75))
                        Text("1.0x").tag(Float(1.0))
                        Text("1.25x").tag(Float(1.25))
                        Text("1.5x").tag(Float(1.5))
                        Text("2.0x").tag(Float(2.0))
                    }

                    Toggle("跳过片头片尾", isOn: Binding(
                        get: { store.player.skipEnabled },
                        set: { store.player.setSkipEnabled($0) }
                    ))

                    Stepper(value: Binding(
                        get: { Int(store.player.skipIntroSeconds) },
                        set: { store.player.setSkipIntroSeconds(Double($0)) }
                    ), in: 0...180, step: 1) {
                        HStack {
                            Text("片头")
                            Spacer()
                            Text("\(Int(store.player.skipIntroSeconds))s")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!store.player.skipEnabled)

                    Stepper(value: Binding(
                        get: { Int(store.player.skipOutroSeconds) },
                        set: { store.player.setSkipOutroSeconds(Double($0)) }
                    ), in: 0...180, step: 1) {
                        HStack {
                            Text("片尾")
                            Spacer()
                            Text("\(Int(store.player.skipOutroSeconds))s")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!store.player.skipEnabled)
                }
                Section("外观") {
                    Picker("主题", selection: $store.themePreference) {
                        ForEach(ThemePreference.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .onChange(of: store.themePreference) { _, newValue in
                        store.setThemePreference(newValue)
                    }
                }
                Section {
                    Button("退出登录", role: .destructive) {
                        Task { await store.signOut() }
                    }
                }
            }
            .navigationTitle("我的")
        }
    }
}

struct ItemDetailView: View {
    @Environment(AppStore.self) private var store
    let itemId: String

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if store.isLoadingItemDetail {
                    ProgressView().frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }

                if let detail = store.selectedItemDetail, detail.id == itemId {
                    VStack(spacing: 12) {
                        CoverImageView(itemId: detail.id, size: 180)
                            .shadow(radius: 18)
                            .padding(.top, 24)

                        VStack(spacing: 6) {
                            Text(detail.displayTitle)
                                .font(.title2)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                            if !detail.displayAuthor.isEmpty {
                                Text(detail.displayAuthor)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 16)
                            }
                        }

                        HStack(spacing: 14) {
                            Button {
                                Task { await store.startPlayback(itemId: itemId) }
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(PrimaryCircleButtonStyle())

                            NavigationLink {
                                ItemChapterListView(itemId: itemId)
                            } label: {
                                Label("章节", systemImage: "list.bullet")
                            }
                            .buttonStyle(.bordered)
                            .frame(height: 44)
                        }
                        .padding(.top, 4)

                        if let duration = detail.media.duration, duration > 0 {
                            Text(TimeFormatter.durationString(duration))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    if let text = (detail.media.metadata.descriptionPlain ?? detail.media.metadata.description), !text.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("简介").font(.headline)
                            Text(text).font(.body)
                        }
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                } else if let error = store.itemDetailError {
                    Text(error).foregroundStyle(.red).padding(.horizontal)
                        .padding(.top, 24)
                }

                Spacer(minLength: 24)
            }
            .padding(.top, 12)
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: itemId) {
            await store.loadItemDetail(itemId: itemId)
        }
    }
}

struct ItemChapterListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let itemId: String
    @State private var isLoading = true
    @State private var isUpdating = false
    @State private var errorText: String?
    @State private var chapters: [Chapter] = []
    @State private var startTimeHint: Double = 0
    @State private var isHandlingTap = false

    var body: some View {
        ScrollViewReader { proxy in
            let currentId = (store.player.libraryItemId == itemId) ? store.player.currentChapterId : nil
            List {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorText {
                    Text(errorText).foregroundStyle(.red)
                } else {
                    ForEach(chapters) { chapter in
                        Button {
                            handleTap(chapter: chapter)
                        } label: {
                            HStack {
                                if currentId == chapter.id, store.player.isPlaying {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.tint)
                                }
                                Text(chapter.title).lineLimit(1)
                                    .fontWeight(currentId == chapter.id ? .semibold : .regular)
                                Spacer()
                                Text(TimeFormatter.timeString(chapter.start)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isHandlingTap)
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .id(chapter.id)
                    }
                }
            }
            .navigationTitle("章节")
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .task(id: itemId) {
                await load(proxy: proxy)
            }
        }
    }

    @MainActor
    private func load(proxy: ScrollViewProxy) async {
        errorText = nil
        startTimeHint = store.player.libraryItemId == itemId ? store.player.currentTime : 0

        if let cached = store.loadChaptersFromCache(itemId: itemId) {
            chapters = cached
            isLoading = false
        } else if let disk = await store.loadChaptersFromDisk(itemId: itemId) {
            store.cachedChapters[itemId] = disk
            chapters = disk
            isLoading = false
        } else {
            isLoading = true
        }

        if isLoading == false, let targetId = nearestChapterId(currentTime: startTimeHint, chapters: chapters) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                proxy.scrollTo(targetId, anchor: .center)
            }
        }

        guard !isUpdating else { return }
        isUpdating = true
        Task {
            defer { isUpdating = false }
            do {
                let session = try await store.fetchPlaybackSessionForChapters(itemId: itemId)
                let list = session.chapters ?? []
                await MainActor.run {
                    store.cachedChapters[itemId] = list
                    store.saveChaptersToDisk(itemId: itemId, chapters: list)
                    if chapters.isEmpty || chaptersDiffer(chapters, list) {
                        chapters = list
                        isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    if chapters.isEmpty {
                        errorText = error.localizedDescription
                        isLoading = false
                    }
                }
            }
        }
    }

    private func handleTap(chapter: Chapter) {
        guard !isHandlingTap else { return }
        isHandlingTap = true
        if store.player.libraryItemId == itemId, store.player.sessionId != nil {
            store.player.jumpToChapter(chapter)
            store.showingPlayer = true
            dismiss()
            isHandlingTap = false
            return
        }
        Task {
            await store.startPlayback(itemId: itemId, startAtOverride: chapter.start)
            await MainActor.run {
                dismiss()
                isHandlingTap = false
            }
        }
    }

    private func nearestChapterId(currentTime: Double, chapters: [Chapter]) -> Int? {
        guard !chapters.isEmpty else { return nil }
        let t = max(0, currentTime.isFinite ? currentTime : 0)
        let target = t + 0.001
        var low = 0
        var high = chapters.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if chapters[mid].start <= target {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return chapters[best].id
    }

    private func chaptersDiffer(_ a: [Chapter], _ b: [Chapter]) -> Bool {
        if a.count != b.count { return true }
        if a.isEmpty { return false }
        guard let a0 = a.first, let b0 = b.first else { return true }
        guard let aN = a.last, let bN = b.last else { return true }
        if a0.id != b0.id || a0.start != b0.start || a0.title != b0.title { return true }
        if aN.id != bN.id || aN.start != bN.start || aN.title != bN.title { return true }

        let mid = a.count / 2
        let am = a[mid]
        let bm = b[mid]
        if am.id != bm.id || am.start != bm.start || am.title != bm.title { return true }
        return false
    }
}

struct MiniPlayerBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.player.sessionId != nil {
            let duration = max(store.player.currentChapterDuration, 1)
            let elapsed = max(0, min(store.player.currentTime - store.player.currentChapterStart, duration))
            let fraction = max(0, min(elapsed / duration, 1))
            let chapterTitle = store.player.currentChapterTitle ?? ""
            VStack(spacing: 0) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 44, height: 44)
                        .overlay(Text("♪").foregroundStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.player.title.isEmpty ? "播放中" : store.player.title).lineLimit(1)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                Text(chapterTitle.isEmpty ? store.player.author : chapterTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    Text("\(TimeFormatter.timeString(elapsed)) / \(TimeFormatter.timeString(duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button {
                        store.player.togglePlayPause()
                    } label: {
                        ZStack {
                            Image(systemName: store.player.isPlayRequested ? "pause.fill" : "play.fill")
                            if store.player.isBuffering {
                                ProgressView()
                            }
                        }
                    }
                    .buttonStyle(SecondaryIconButtonStyle())
                }
                .padding(.horizontal, 12)
                .frame(height: 60)
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                store.showingPlayer = true
            }
        }
    }
}

struct ContinueListeningCard: View {
    let item: LibraryItemSummary
    let progress: MediaProgress

    var body: some View {
        let fraction = min(max(progress.progress, 0), 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CoverImageView(itemId: item.id, size: 80)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.displayTitle).font(.headline).lineLimit(2)
                    if !item.displayAuthor.isEmpty {
                        Text(item.displayAuthor).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("\(TimeFormatter.timeString(progress.currentTime)) / \(TimeFormatter.timeString(progress.duration ?? 0))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(height: 4)
        }
        .padding(16)
        .frame(width: 280, height: 120, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)
    }
}

struct ScrubberBar: View {
    var duration: Double
    var elapsed: Double
    var onCommit: (Double) -> Void

    @GestureState private var dragFraction: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let safeDuration = (duration.isFinite && duration > 0) ? duration : 1
            let safeElapsed = elapsed.isFinite ? elapsed : 0
            let baseFraction = max(0, min(safeElapsed / safeDuration, 1))
            let fraction = dragFraction ?? baseFraction
            let rawFillWidth = width * fraction
            let fillWidth = (fraction > 0 && rawFillWidth < 1) ? 1 : max(0, min(rawFillWidth, width))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: fillWidth, height: 6)
                Circle()
                    .fill(Color(uiColor: .systemBackground))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .offset(x: max(0, min(fillWidth - 7, width - 14)))
            }
            .frame(height: 22)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragFraction) { value, state, _ in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) >= abs(dy) else {
                            state = nil
                            return
                        }
                        let x = max(0, min(value.location.x, width))
                        state = Double(x / width)
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) >= abs(dy) else { return }
                        let x = max(0, min(value.location.x, width))
                        let newPosition = (x / width) * safeDuration
                        onCommit(newPosition)
                    }
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
    }
}

struct ChapterProgressBar: View {
    var duration: Double
    var elapsed: Double
    var onSeek: (Double) -> Void

    @GestureState private var dragFraction: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let safeDuration = (duration.isFinite && duration > 0) ? duration : 1
            let safeElapsed = elapsed.isFinite ? elapsed : 0
            let baseFraction = max(0, min(safeElapsed / safeDuration, 1))
            let fraction = dragFraction ?? baseFraction
            let fillWidth = max(0, min(width, width * CGFloat(fraction)))
            let thumbRadius: CGFloat = 7
            let thumbCenterX = max(thumbRadius, min(width - thumbRadius, fillWidth))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: fillWidth, height: 6)
                Circle()
                    .fill(Color(uiColor: .systemBackground))
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.22), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.14), radius: 2, x: 0, y: 1)
                    .offset(x: thumbCenterX - thumbRadius)
            }
            .frame(height: 22)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragFraction) { value, state, _ in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) >= abs(dy) else {
                            state = nil
                            return
                        }
                        let x = max(0, min(value.location.x, width))
                        state = Double(x / width)
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) >= abs(dy) else { return }
                        let x = max(0, min(value.location.x, width))
                        onSeek((x / width) * safeDuration)
                    }
            )
        }
        .frame(height: 22)
    }
}

struct PlayerView: View {
    @Environment(AppStore.self) private var store
    @State private var showingChapterSheet = false
    @State private var dragOffsetY: CGFloat = 0

    var body: some View {
        @Bindable var store = store
        @Bindable var player = store.player
        let chapterCount = player.chapters.count
        let chapterIndex = player.currentChapterIndex
        let chapterTitle = player.currentChapterTitle
        let chapterStart = player.currentChapterStart
        let chapterDuration = max(player.currentChapterDuration, 1)
        let elapsedInChapter = max(0, min(player.currentTime - chapterStart, chapterDuration))
        let effectiveSliderValue = elapsedInChapter
        let chapterLabel: String? = {
            guard let chapterIndex, let chapterTitle, chapterCount > 0 else { return nil }
            return "章节 \(chapterIndex + 1)/\(chapterCount)：\(chapterTitle)"
        }()
        let screenWidth = UIScreen.main.bounds.width
        let scrubberWidth = max(120, screenWidth - 32)

        ZStack {
            if let itemId = player.libraryItemId {
                CoverBackdropView(itemId: itemId)
                    .ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.35), Color(uiColor: .systemBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            NavigationStack {
                VStack(spacing: 16) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 44, height: 5)
                        .padding(.top, 8)

                    if let itemId = player.libraryItemId {
                        CoverImageView(itemId: itemId, size: 240)
                            .shadow(radius: 20)
                            .padding(.top, 4)
                    }

                    VStack(spacing: 6) {
                        Text(player.title.isEmpty ? "播放" : player.title)
                            .font(.title3)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        if !player.author.isEmpty {
                            Text(player.author)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        if let chapterLabel {
                            Text(chapterLabel)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if player.isBuffering {
                            Text("正在加载媒体资源…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(player.isPlaying ? "播放中" : "已暂停")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(TimeFormatter.timeString(elapsedInChapter)) / \(TimeFormatter.timeString(chapterDuration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) {
                        ChapterProgressBar(duration: chapterDuration, elapsed: elapsedInChapter) { newValue in
                            player.seek(to: chapterStart + max(0, min(newValue, chapterDuration)), autoplay: true)
                        }
                        .frame(width: scrubberWidth)
                        HStack {
                            Text(TimeFormatter.timeString(effectiveSliderValue)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(TimeFormatter.timeString(chapterDuration)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                    .transaction { $0.animation = nil }

                    HStack(spacing: 26) {
                        Button { store.player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                            .buttonStyle(SecondaryIconButtonStyle())
                        Button { store.player.skip(seconds: -15) } label: { Image(systemName: "gobackward.15") }
                            .buttonStyle(SecondaryIconButtonStyle())
                        Button { store.player.togglePlayPause() } label: {
                            ZStack {
                                Image(systemName: store.player.isPlayRequested ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 56))
                                if store.player.isBuffering {
                                    ProgressView()
                                        .tint(.white)
                                }
                            }
                        }
                        Button { store.player.skip(seconds: 30) } label: { Image(systemName: "goforward.30") }
                            .buttonStyle(SecondaryIconButtonStyle())
                        Button { store.player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                            .buttonStyle(SecondaryIconButtonStyle())
                    }
                    .font(.title2)

                    HStack(spacing: 12) {
                        Menu {
                            Button("0.75x") { store.player.setRate(0.75) }
                            Button("1.0x") { store.player.setRate(1.0) }
                            Button("1.25x") { store.player.setRate(1.25) }
                            Button("1.5x") { store.player.setRate(1.5) }
                            Button("2.0x") { store.player.setRate(2.0) }
                        } label: {
                            Label(String(format: "%.2gx", store.player.rate), systemImage: "speedometer")
                        }
                        .buttonStyle(.bordered)

                        Menu {
                            Button("关闭") { store.player.setSleepTimer(minutes: nil) }
                            Button("15 分钟") { store.player.setSleepTimer(minutes: 15) }
                            Button("30 分钟") { store.player.setSleepTimer(minutes: 30) }
                            Button("60 分钟") { store.player.setSleepTimer(minutes: 60) }
                        } label: {
                            Label("睡眠", systemImage: "moon")
                        }
                        .buttonStyle(.bordered)

                        if !store.player.chapters.isEmpty {
                            Button("章节") { showingChapterSheet = true }
                                .buttonStyle(.bordered)
                        }
                    }

                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
                .offset(y: max(0, dragOffsetY))
                .navigationTitle("播放器")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") {
                            store.showingPlayer = false
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    if store.player.isScrubbing { return }
                    if value.startLocation.x < 24, value.translation.width > 0, abs(value.translation.height) < 60 {
                        return
                    }
                    if value.translation.height > 0, abs(value.translation.width) < 80 {
                        dragOffsetY = value.translation.height
                    }
                }
                .onEnded { value in
                    if store.player.isScrubbing { return }
                    let isEdgeBack = value.startLocation.x < 24 && value.translation.width > 120 && abs(value.translation.height) < 60
                    let isPullDown = value.translation.height > 140 && abs(value.translation.width) < 100
                    if isEdgeBack || isPullDown {
                        store.showingPlayer = false
                        dragOffsetY = 0
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            dragOffsetY = 0
                        }
                    }
                }
        )
        .sheet(isPresented: $showingChapterSheet) {
            PlayerChapterSheetView()
                .environment(store)
        }
    }
}

struct PlayerChapterSheetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var didInitialScroll = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                let currentId = store.player.currentChapterId
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.player.chapters) { chapter in
                            let isCurrent = (currentId == chapter.id)
                            Button {
                                store.player.jumpToChapter(chapter)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    if isCurrent, store.player.isPlaying {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundStyle(.tint)
                                    } else {
                                        Image(systemName: "circle.fill")
                                            .foregroundStyle(.clear)
                                    }
                                    Text(chapter.title)
                                        .lineLimit(1)
                                        .fontWeight(isCurrent ? .semibold : .regular)
                                    Spacer()
                                    Text(TimeFormatter.timeString(chapter.start))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(isCurrent ? Color.secondary.opacity(0.12) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            .id(chapter.id)
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .background(Color(uiColor: .systemBackground))
                .navigationTitle("章节")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
                .onAppear {
                    guard !didInitialScroll else { return }
                    didInitialScroll = true
                    guard let id = store.player.currentChapterId ?? store.player.chapters.first?.id else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ChapterListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var didInitialScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            let currentId = store.player.currentChapterId
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.player.chapters) { chapter in
                        Button {
                            store.player.jumpToChapter(chapter)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                if currentId == chapter.id, store.player.isPlaying {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.tint)
                                } else {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(.clear)
                                }
                                Text(chapter.title)
                                    .lineLimit(1)
                                    .fontWeight(currentId == chapter.id ? .semibold : .regular)
                                Spacer()
                                Text(TimeFormatter.timeString(chapter.start))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(currentId == chapter.id ? Color.secondary.opacity(0.12) : Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .id(chapter.id)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("章节")
            .onAppear {
                guard !didInitialScroll else { return }
                didInitialScroll = true
                guard let id = store.player.currentChapterId ?? store.player.chapters.first?.id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

struct ItemCard: View {
    let item: LibraryItemSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImageView(itemId: item.id, size: 120)
            Text(item.displayTitle).font(.callout).lineLimit(2)
            if !item.displayAuthor.isEmpty {
                Text(item.displayAuthor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 140, alignment: .leading)
    }
}

struct CoverImageView: View {
    @Environment(AppStore.self) private var store
    let itemId: String
    let size: CGFloat
    var height: CGFloat? = nil

    var url: URL? {
        guard let baseURL = store.session?.baseURL else { return nil }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api/items/\(itemId)/cover"), resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent("api/items/\(itemId)/cover")
        }
        components.queryItems = [
            URLQueryItem(name: "width", value: "\(Int(size * 2))"),
            URLQueryItem(name: "format", value: "jpeg")
        ]
        return components.url
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: size, height: height ?? size)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                        case let .success(image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "book.closed").foregroundStyle(.secondary)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                }
            }
    }
}

struct SectionHeader: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.title2)
            .fontWeight(.bold)
            .padding(.horizontal)
    }
}

struct RecentAddedCard: View {
    let item: LibraryItemSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImageView(itemId: item.id, size: 140, height: 200)
            Text(item.displayTitle)
                .font(.callout)
                .fontWeight(.semibold)
                .lineLimit(2)
            if !item.displayAuthor.isEmpty {
                Text(item.displayAuthor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: 164, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)
    }
}

struct LibraryGridCard: View {
    let item: LibraryItemSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImageView(itemId: item.id, size: 120)
            Text(item.displayTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(2)
            if !item.displayAuthor.isEmpty {
                Text(item.displayAuthor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct CoverBackdropView: View {
    @Environment(AppStore.self) private var store
    let itemId: String

    private var url: URL? {
        guard let baseURL = store.session?.baseURL else { return nil }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api/items/\(itemId)/cover"), resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent("api/items/\(itemId)/cover")
        }
        components.queryItems = [
            URLQueryItem(name: "width", value: "768"),
            URLQueryItem(name: "format", value: "jpeg")
        ]
        return components.url
    }

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Color.clear
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
                .blur(radius: 28)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.15),
                            Color(uiColor: .systemBackground).opacity(1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            } else {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.35),
                        Color(uiColor: .systemBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

enum TimeFormatter {
    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func durationString(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return "\(h)小时\(m)分钟"
        }
        return "\(m)分钟"
    }
}

struct ContentView: View {
    var body: some View {
        RootView()
    }
}

#Preview {
    ContentView()
}
