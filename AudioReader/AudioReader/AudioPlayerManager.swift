import AVFoundation
import MediaPlayer
import Observation
import UIKit

@Observable
final class AudioPlayerManager {
    static let shared = AudioPlayerManager()

    private enum DefaultsKeys {
        static let rate = "player_rate_v1"
        static let skipEnabled = "player_skip_enabled_v1"
        static let skipIntroSeconds = "player_skip_intro_seconds_v1"
        static let skipOutroSeconds = "player_skip_outro_seconds_v1"
        static let customSleepMinutes = "player_custom_sleep_minutes_v1"
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
    var customSleepMinutes = 20
    var sleepTimerTargetDate: Date?
    var sleepTimerDurationMinutes: Int?

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
        sleepTimerTargetDate = nil
        sleepTimerDurationMinutes = nil
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
        sleepTimerTargetDate = nil
        sleepTimerDurationMinutes = nil
        guard let minutes, minutes > 0 else { return }
        sleepTimerDurationMinutes = minutes
        sleepTimerTargetDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            guard let self else { return }
            pause()
            sleepTimerTargetDate = nil
            sleepTimerDurationMinutes = nil
            sleepTimer = nil
        }
    }

    func setCustomSleepMinutes(_ minutes: Int) {
        customSleepMinutes = max(1, min(minutes, 720))
        savePreferences()
    }

    func sleepRemainingSeconds(at now: Date = Date()) -> Int? {
        guard let target = sleepTimerTargetDate else { return nil }
        let remaining = Int(target.timeIntervalSince(now))
        if remaining <= 0 { return nil }
        return remaining
    }

    func sleepMenuLabel(at now: Date = Date()) -> String {
        guard let remaining = sleepRemainingSeconds(at: now) else { return "睡眠" }
        if remaining >= 3600 {
            let h = remaining / 3600
            let m = (remaining % 3600) / 60
            return String(format: "睡眠 %d:%02d", h, m)
        }
        let m = remaining / 60
        let s = remaining % 60
        return String(format: "睡眠 %d:%02d", m, s)
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
        if defaults.object(forKey: DefaultsKeys.customSleepMinutes) != nil {
            customSleepMinutes = max(1, min(defaults.integer(forKey: DefaultsKeys.customSleepMinutes), 720))
        } else {
            customSleepMinutes = 20
        }
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(rate, forKey: DefaultsKeys.rate)
        defaults.set(skipEnabled, forKey: DefaultsKeys.skipEnabled)
        defaults.set(skipIntroSeconds, forKey: DefaultsKeys.skipIntroSeconds)
        defaults.set(skipOutroSeconds, forKey: DefaultsKeys.skipOutroSeconds)
        defaults.set(customSleepMinutes, forKey: DefaultsKeys.customSleepMinutes)
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
