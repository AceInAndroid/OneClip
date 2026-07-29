import SwiftUI

struct WebDAVSettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var syncManager = WebDAVSyncManager.shared

    @State private var serverURL = ""
    @State private var remotePath = WebDAVConfiguration.defaultRemotePath
    @State private var username = ""
    @State private var password = ""
    @State private var syncPassword = ""
    @State private var deviceName = Host.current().localizedName ?? "Mac"
    @State private var selectedMode: WebDAVMode = .disabled
    @State private var hasLoaded = false
    @State private var showEnableConfirmation = false
    @State private var showDisconnectConfirmation = false
    @State private var pendingRestore: RemoteBackupInfo?
    @State private var estimate = WebDAVInitialEstimate(
        eligibleItemCount: 0,
        estimatedUploadBytes: 0,
        skippedItemCount: 0
    )

    var body: some View {
        LazyVStack(spacing: 18) {
            modeCard

            if selectedMode != .disabled {
                connectionCard
                encryptionCard
                actionCard
            } else {
                disabledCard
            }

            statusCard

            if selectedMode == .backup && settings.webDAVConfiguration.mode == .backup {
                backupsCard
            }
        }
        .onAppear {
            loadConfigurationIfNeeded()
            if settings.webDAVConfiguration.mode == .backup {
                syncManager.refreshBackups()
            }
        }
        .onDisappear {
            password = ""
            syncPassword = ""
        }
        .onChange(of: settings.webDAVConfiguration) { _, configuration in
            guard configuration.mode != .disabled else { return }
            password = ""
            syncPassword = ""
            selectedMode = configuration.mode
        }
        .alert("启用加密\(selectedMode.title)", isPresented: $showEnableConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确认并启用") { enable() }
        } message: {
            Text(
                "将处理 \(estimate.eligibleItemCount) 条历史，预计上传 \(ByteCountFormatter.string(fromByteCount: estimate.estimatedUploadBytes, countStyle: .file))。"
                + (estimate.skippedItemCount > 0 ? "\n\(estimate.skippedItemCount) 条不支持或超限内容只保留在本机。" : "")
            )
        }
        .alert("关闭同步与备份", isPresented: $showDisconnectConfirmation) {
            Button("取消", role: .cancel) { }
            Button("仅从本机断开", role: .destructive) {
                syncManager.disconnect()
                selectedMode = .disabled
                password = ""
                syncPassword = ""
            }
        } message: {
            Text("只会删除本机配置和 Keychain 密钥，不会删除 WebDAV 上的加密数据。")
        }
        .alert(
            "恢复加密备份",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingRestore = nil }
            Button("安全合并") {
                if let pendingRestore { syncManager.restore(pendingRestore) }
                pendingRestore = nil
            }
        } message: {
            Text("备份会与本机历史按指纹安全合并，不会清空现有内容，也不会写入当前系统剪贴板。")
        }
    }

    private var modeCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("工作模式", systemImage: "arrow.triangle.2.circlepath.icloud.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)

                HStack(spacing: 10) {
                    ForEach(WebDAVMode.allCases) { mode in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { selectedMode = mode }
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                Text(mode.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(mode.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(selectedMode == mode ? .white.opacity(0.78) : .secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .foregroundStyle(selectedMode == mode ? .white : .primary)
                            .frame(maxWidth: .infinity, minHeight: 82)
                            .padding(.horizontal, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(selectedMode == mode ? Color.blue.gradient : Color.clear.gradient)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(
                                                selectedMode == mode ? .white.opacity(0.22) : .primary.opacity(0.08),
                                                lineWidth: 1
                                            )
                                    }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var connectionCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 13) {
                cardTitle("WebDAV 服务器", icon: "server.rack", color: .cyan)
                settingsField("HTTPS 地址", text: $serverURL, prompt: "https://dav.example.com/")
                settingsField("远端目录", text: $remotePath, prompt: WebDAVConfiguration.defaultRemotePath)
                settingsField("用户名", text: $username, prompt: "WebDAV 用户名")
                secureSettingsField("登录密码", text: $password, prompt: "保存在 macOS Keychain")
                settingsField("设备名称", text: $deviceName, prompt: "这台 Mac 的名称")

                Label("仅接受系统信任的 HTTPS 证书；NAS 自建 CA 请先加入 macOS 系统信任。", systemImage: "lock.shield")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var encryptionCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 13) {
                cardTitle("端到端加密", icon: "key.horizontal.fill", color: .purple)
                secureSettingsField("同步密码", text: $syncPassword, prompt: "至少 12 个字符")
                Text("所有 Mac 需输入相同同步密码。PasteLight 使用 PBKDF2-HMAC-SHA256（至少 600,000 次）派生密钥，并以 AES-GCM 加密清单与附件。同步密码不会上传。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionCard: some View {
        glassCard {
            HStack(spacing: 12) {
                Button {
                    syncManager.testConnection(
                        configuration: draftConfiguration,
                        password: password,
                        passphrase: syncPassword
                    )
                } label: {
                    Label("测试连接", systemImage: "checkmark.shield")
                }
                .buttonStyle(GlassActionButtonStyle(tint: .secondary))
                .disabled(syncManager.status.phase.isWorking)

                Button {
                    estimate = syncManager.estimate(for: draftConfiguration)
                    showEnableConfirmation = true
                } label: {
                    Label(
                        settings.webDAVConfiguration.mode == .disabled ? "保存并启用" : "更新配置",
                        systemImage: "lock.icloud.fill"
                    )
                }
                .buttonStyle(GlassActionButtonStyle(tint: .blue))
                .disabled(syncManager.status.phase.isWorking)

                if settings.webDAVConfiguration.mode != .disabled {
                    Button(role: .destructive) {
                        showDisconnectConfirmation = true
                    } label: {
                        Label("断开", systemImage: "xmark.icloud")
                    }
                    .buttonStyle(GlassActionButtonStyle(tint: .red))
                }
            }
        }
    }

    private var disabledCard: some View {
        glassCard {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(.thinMaterial))
                VStack(alignment: .leading, spacing: 4) {
                    Text("同步与备份已关闭")
                        .font(.system(size: 14, weight: .semibold))
                    Text("历史仅保存在这台 Mac。选择上方模式后可直接在本页完成配置。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if settings.webDAVConfiguration.mode != .disabled {
                    Button("应用关闭") { showDisconnectConfirmation = true }
                        .buttonStyle(GlassActionButtonStyle(tint: .red))
                }
            }
        }
    }

    private var statusCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.45), radius: 4)
                    Text(syncManager.status.phase.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if syncManager.status.skippedItemCount > 0 {
                        Text("跳过 \(syncManager.status.skippedItemCount) 条")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                Text(syncManager.status.message)
                    .font(.system(size: 11))
                    .foregroundStyle(syncManager.status.phase == .failed ? .red : .secondary)
                    .textSelection(.enabled)

                if syncManager.status.phase.isWorking {
                    ProgressView(value: syncManager.status.progress)
                        .tint(.blue)
                }

                HStack {
                    if let lastSuccess = syncManager.status.lastSuccessAt {
                        Text("最近成功：\(lastSuccess.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if settings.webDAVConfiguration.mode != .disabled {
                        Button(settings.webDAVConfiguration.mode == .backup ? "立即备份" : "立即同步") {
                            syncManager.performNow()
                        }
                        .buttonStyle(GlassActionButtonStyle(tint: .blue))
                        .disabled(syncManager.status.phase.isWorking)
                    }
                }
            }
        }
    }

    private var backupsCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    cardTitle("最近备份", icon: "clock.arrow.circlepath", color: .green)
                    Spacer()
                    Button {
                        syncManager.refreshBackups()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }

                if syncManager.backups.isEmpty {
                    Text("暂无成功备份。每台设备最多保留最近 7 份。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(syncManager.backups) { backup in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11.5, weight: .medium))
                                Text(ByteCountFormatter.string(fromByteCount: backup.byteCount, countStyle: .file))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                                Text(
                                    backup.deviceID == settings.webDAVConfiguration.deviceID
                                        ? "这台 Mac"
                                        : "其他 Mac · \(backup.deviceID.uuidString.prefix(8))"
                                )
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("安全合并") { pendingRestore = backup }
                                .buttonStyle(GlassActionButtonStyle(tint: .green))
                        }
                        if backup.id != syncManager.backups.last?.id {
                            Divider().opacity(0.25)
                        }
                    }
                }
            }
        }
    }

    private var draftConfiguration: WebDAVConfiguration {
        WebDAVConfiguration(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePath: remotePath.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: selectedMode,
            deviceID: settings.webDAVConfiguration.deviceID,
            deviceName: deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Mac" : deviceName,
            imageLimitBytes: WebDAVConfiguration.defaultImageLimitBytes,
            accountID: settings.webDAVConfiguration.accountID
        )
    }

    private var statusColor: Color {
        switch syncManager.status.phase {
        case .failed: return .red
        case .success: return .green
        case .testing, .preparing, .uploading, .downloading, .merging: return .blue
        case .disabled: return .secondary
        case .idle: return .mint
        }
    }

    private func loadConfigurationIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let configuration = settings.webDAVConfiguration
        serverURL = configuration.serverURL
        remotePath = configuration.remotePath
        username = configuration.username
        deviceName = configuration.deviceName
        selectedMode = configuration.mode
    }

    private func enable() {
        syncManager.enable(
            configuration: draftConfiguration,
            password: password,
            passphrase: syncPassword
        )
    }

    private func cardTitle(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
    }

    private func settingsField(
        _ label: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(fieldBackground)
        }
    }

    private func secureSettingsField(
        _ label: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            SecureField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(fieldBackground)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 0.8)
            }
    }

    private func glassCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.2), .primary.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    }
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            }
    }
}

private struct GlassActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(tint == .secondary ? Color.primary : Color.white)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint == .secondary ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(tint.gradient))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 0.8)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}
