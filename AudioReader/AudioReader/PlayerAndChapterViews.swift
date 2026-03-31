import SwiftUI
import UIKit

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
    @State private var didInitialScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            let currentId = (store.player.libraryItemId == itemId) ? store.player.currentChapterId : nil
            Group {
                if isLoading {
                    VStack {
                        Spacer(minLength: 24)
                        ProgressView()
                        Spacer()
                    }
                } else if let errorText {
                    VStack {
                        Spacer(minLength: 24)
                        Text(errorText).foregroundStyle(.red)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(chapters) { chapter in
                                let isCurrent = currentId == chapter.id
                                Button {
                                    handleTap(chapter: chapter)
                                } label: {
                                    ChapterListRowView(
                                        chapter: chapter,
                                        isCurrent: isCurrent,
                                        showPlayingIndicator: isCurrent && store.player.isPlaying,
                                        style: .grouped
                                    )
                                }
                                .disabled(isHandlingTap)
                                .buttonStyle(.plain)
                                .id(chapter.id)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("章节")
            .background(Color(uiColor: .systemGroupedBackground))
            .task(id: itemId) {
                await load(proxy: proxy)
            }
            .onChange(of: chapters.count) { _, _ in
                scrollToInitialChapterIfNeeded(proxy: proxy)
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

        scrollToInitialChapterIfNeeded(proxy: proxy)

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

    private func scrollToInitialChapterIfNeeded(proxy: ScrollViewProxy) {
        guard !didInitialScroll else { return }
        guard !isLoading else { return }
        guard let targetId = nearestChapterId(currentTime: startTimeHint, chapters: chapters) else { return }
        didInitialScroll = true
        scrollTo(proxy: proxy, id: targetId)
    }

    private func scrollTo(proxy: ScrollViewProxy, id: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
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

private enum ChapterListRowStyle: Equatable {
    case grouped
    case plain
    case card
}

private struct ChapterListRowView: View, Equatable {
    let chapter: Chapter
    let isCurrent: Bool
    let showPlayingIndicator: Bool
    let style: ChapterListRowStyle

    static func == (lhs: ChapterListRowView, rhs: ChapterListRowView) -> Bool {
        lhs.chapter == rhs.chapter &&
            lhs.isCurrent == rhs.isCurrent &&
            lhs.showPlayingIndicator == rhs.showPlayingIndicator &&
            lhs.style == rhs.style
    }

    var body: some View {
        HStack(spacing: 10) {
            if showPlayingIndicator {
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
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(alignment: .bottom) {
            if style == .plain {
                Divider()
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, outerVerticalPadding)
        .padding(.horizontal, outerHorizontalPadding)
    }

    private var backgroundColor: Color {
        switch style {
        case .grouped:
            return isCurrent ? Color.secondary.opacity(0.12) : Color(uiColor: .secondarySystemBackground)
        case .plain:
            return isCurrent ? Color.secondary.opacity(0.12) : Color.clear
        case .card:
            return isCurrent ? Color.secondary.opacity(0.12) : Color(uiColor: .secondarySystemBackground)
        }
    }

    private var cornerRadius: CGFloat {
        switch style {
        case .grouped, .card:
            return 12
        case .plain:
            return 0
        }
    }

    private var verticalPadding: CGFloat {
        style == .plain ? 12 : 10
    }

    private var outerVerticalPadding: CGFloat {
        style == .card ? 4 : 0
    }

    private var outerHorizontalPadding: CGFloat {
        style == .grouped ? 12 : 0
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
    @State private var showingCustomSleepSheet = false
    @State private var dragOffsetY: CGFloat = 0
    @State private var sleepTick = Date()
    private let sleepTickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                            Button("上次 \(store.player.customSleepMinutes) 分钟") {
                                store.player.setSleepTimer(minutes: store.player.customSleepMinutes)
                            }
                            Divider()
                            Button("自定义…") { showingCustomSleepSheet = true }
                        } label: {
                            Label(store.player.sleepMenuLabel(at: sleepTick), systemImage: "moon")
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
        .sheet(isPresented: $showingCustomSleepSheet) {
            SleepTimerCustomSheetView()
                .environment(store)
        }
        .onReceive(sleepTickTimer) { value in
            if store.player.sleepTimerTargetDate != nil {
                sleepTick = value
            }
        }
    }
}

struct SleepTimerCustomSheetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var minuteInput = ""
    @State private var inputError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("快速选择") {
                    HStack(spacing: 8) {
                        quickButton(10)
                        quickButton(20)
                        quickButton(45)
                        quickButton(90)
                    }
                }

                Section("自定义分钟数") {
                    TextField("输入分钟（1-720）", text: $minuteInput)
                        .keyboardType(.numberPad)
                    if let inputError {
                        Text(inputError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Text("建议：入睡常用 20-45 分钟")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let remaining = store.player.sleepRemainingSeconds() {
                    Section("当前睡眠定时") {
                        Text("剩余 \(formatRemaining(seconds: remaining))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("睡眠定时")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置") { applyCustomSleepTimer() }
                }
            }
            .onAppear {
                minuteInput = "\(store.player.customSleepMinutes)"
                inputError = nil
            }
        }
    }

    @ViewBuilder
    private func quickButton(_ minutes: Int) -> some View {
        Button("\(minutes)m") {
            store.player.setSleepTimer(minutes: minutes)
            store.player.setCustomSleepMinutes(minutes)
            dismiss()
        }
        .buttonStyle(.bordered)
    }

    private func applyCustomSleepTimer() {
        let raw = minuteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(raw), (1...720).contains(minutes) else {
            inputError = "请输入 1 到 720 之间的整数分钟"
            return
        }
        store.player.setCustomSleepMinutes(minutes)
        store.player.setSleepTimer(minutes: minutes)
        dismiss()
    }

    private func formatRemaining(seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "\(h)小时\(m)分钟"
        }
        return "\(seconds / 60)分\(seconds % 60)秒"
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
                                ChapterListRowView(
                                    chapter: chapter,
                                    isCurrent: isCurrent,
                                    showPlayingIndicator: isCurrent && store.player.isPlaying,
                                    style: .plain
                                )
                            }
                            .buttonStyle(.plain)
                            .id(chapter.id)
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
                        let isCurrent = currentId == chapter.id
                        Button {
                            store.player.jumpToChapter(chapter)
                            dismiss()
                        } label: {
                            ChapterListRowView(
                                chapter: chapter,
                                isCurrent: isCurrent,
                                showPlayingIndicator: isCurrent && store.player.isPlaying,
                                style: .card
                            )
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
        VStack(alignment: .leading, spacing: 10) {
            CoverImageView(itemId: item.id, size: 140, height: 200)
            Text(item.displayTitle)
                .font(.callout)
                .fontWeight(.semibold)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 38, alignment: .topLeading)
            if !item.displayAuthor.isEmpty {
                Text(item.displayAuthor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 168, height: 292, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)
    }
}

struct LibraryGridCard: View {
    let item: LibraryItemSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverImageView(itemId: item.id, size: 140, height: 188)
            Text(item.displayTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 38, alignment: .topLeading)
            if !item.displayAuthor.isEmpty {
                Text(item.displayAuthor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 274, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
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
