import SwiftUI

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

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 14)]

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
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.libraryItems) { item in
                                NavigationLink {
                                    ItemDetailView(itemId: item.id)
                                } label: {
                                    LibraryGridCard(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 120)
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
                    VStack(spacing: 14) {
                        CoverImageView(itemId: detail.id, size: 188, height: 256)
                            .shadow(radius: 18)
                            .padding(.top, 8)

                        VStack(spacing: 8) {
                            Text(detail.displayTitle)
                                .font(.title3)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                            if !detail.displayAuthor.isEmpty {
                                Text(detail.displayAuthor)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .padding(.horizontal, 10)
                            }
                        }

                        HStack(spacing: 10) {
                            if let duration = detail.media.duration, duration > 0 {
                                DetailMetaChip(title: TimeFormatter.durationString(duration), icon: "clock")
                            }
                            if let chapterCount = detail.media.numChapters, chapterCount > 0 {
                                DetailMetaChip(title: "\(chapterCount) 章", icon: "list.bullet")
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
                            .buttonStyle(.borderedProminent)
                            .frame(height: 44)
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    if let text = (detail.media.metadata.descriptionPlain ?? detail.media.metadata.description), !text.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("简介").font(.headline)
                            Text(text)
                                .font(.body)
                                .lineSpacing(4)
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

private struct DetailMetaChip: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemBackground))
            .clipShape(Capsule())
    }
}
