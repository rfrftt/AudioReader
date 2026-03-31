import SwiftUI
import UIKit

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
                            Task { await store.switchServerProfileAndSignOutIfNeeded(id: profile.id) }
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
