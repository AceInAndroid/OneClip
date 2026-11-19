import SwiftUI

struct ScreenshotShortcutSettingsCard: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var screenshot = ScreenshotManager.shared

    var body: some View {
        ModernSettingsCard(title: "截图快捷键", icon: "viewfinder", color: .cyan) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("区域截图").font(.system(.body, weight: .medium))
                        Text("点击快捷键框，按下新的组合键，即时生效。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(shortcut: settings.screenshotShortcut) { settings.updateScreenshotShortcut($0) }
                        .frame(width: 160, height: 36)
                        .accessibilityLabel("区域截图快捷键")
                }
                HStack {
                    Text("默认 ⌘⇧X，可在其他应用中使用。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { settings.updateScreenshotShortcut(.screenshotDefault) }
                        .buttonStyle(.bordered)
                }
                if let error = settings.shortcutConflictMessage ?? screenshot.shortcutError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct ScreenshotSettingsView: View {
    @ObservedObject private var screenshot = ScreenshotManager.shared
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animateSelection = false

    var body: some View {
        VStack(spacing: 24) {
            ModernSettingsCard(title: "轻量截图", icon: "crop", color: .blue) {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(colors: [.blue.opacity(0.15), .cyan.opacity(0.06)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.thinMaterial)
                            .frame(width: 210, height: 82)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.blue.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .frame(width: animateSelection ? 164 : 120, height: animateSelection ? 56 : 38)
                        Image(systemName: "plus.viewfinder")
                            .foregroundStyle(.blue).offset(x: 82, y: -28)
                    }
                    .frame(height: 116)
                    .accessibilityHidden(true)
                    .onAppear {
                        guard !reduceMotion else { animateSelection = true; return }
                        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                            animateSelection = true
                        }
                    }
                    Text("截取一小块，直接粘贴。")
                        .font(.system(.title3, weight: .semibold))
                    Text("完成后复制为 PNG 图片，并自动加入剪贴板历史。截图期间暂时隐藏剪贴板窗口。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            screenshot.startCapture()
                        } label: {
                            Label(screenshot.isCapturing ? "正在截图…" : "开始区域截图", systemImage: "viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(screenshot.isCapturing)
                        Spacer()
                        Text(settings.screenshotShortcut.displayName)
                            .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text(screenshot.statusMessage)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            ScreenshotShortcutSettingsCard()

            ModernSettingsCard(title: "屏幕录制权限", icon: "lock.shield", color: .green) {
                VStack(alignment: .leading, spacing: 14) {
                    Label(screenshot.hasPermission ? "已授权" : "需要授权", systemImage:
                            screenshot.hasPermission ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundStyle(screenshot.hasPermission ? .green : .orange)
                    Text("在系统设置 → 隐私与安全性 → 屏幕与系统音频录制（部分系统显示为“屏幕录制”）中开启 PasteLight。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(screenshot.hasPermission ? "打开系统设置" : "申请权限") {
                            if screenshot.hasPermission { screenshot.openPermissionSettings() }
                            else { screenshot.requestPermission() }
                        }
                        Button("重新检查") { screenshot.refreshPermission() }
                        Spacer()
                    }
                    .buttonStyle(.bordered)
                    Text("只在你发起截图时读取屏幕，不录制视频或音频。截图权限独立于辅助功能权限；授权后若仍不可用，请完全退出并重新打开 PasteLight。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            ModernInfoCard(title: "如何截图", icon: "cursorarrow.motionlines", color: .cyan, items: [
                ("1 · 发起截图", "按截图快捷键，或在菜单栏选择“区域截图”。"),
                ("2 · 框选与确认", "拖动选择区域，松手后可重新框选。回车、双击选区或点击“复制”完成。"),
                ("3 · 粘贴图片", "回到目标应用按 ⌘V。按 Esc、右键或“取消”退出，原剪贴板不变。"),
                ("多显示器", "可以在任一屏幕上框选；一次截图的选区限于单个屏幕。"),
                ("历史与同步", "截图按现有历史保留和去重规则保存；启用 WebDAV 图片同步时，也遵循原有同步设置。")
            ])
        }
        .onAppear { screenshot.refreshPermission() }
    }
}
