//
//  ContentView.swift
//  AudioReader
//
//  Created by zwq on 2026/1/19.
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
        if shouldInvalidateSessionForSelectedServer(savedSession) {
            deleteSessionFromKeychain()
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
    func switchServerProfileAndSignOutIfNeeded(id: String) async {
        guard let profile = serverProfiles.first(where: { $0.id == id }) else { return }
        let previousBaseURL = session?.baseURLString
        selectedServerProfileId = id
        saveServerProfiles()
        applyServerProfile(profile)

        guard let currentSessionBaseURL = previousBaseURL else { return }
        let nextBaseURL = buildBaseURL().map(normalizedBaseURLString)
        if nextBaseURL != currentSessionBaseURL {
            await signOut()
        }
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

    private func shouldInvalidateSessionForSelectedServer(_ session: Session) -> Bool {
        guard let configured = buildBaseURL().map(normalizedBaseURLString) else { return false }
        return configured != session.baseURLString
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
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        let attributes: [String: Any] = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { $1 }
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            _ = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
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

