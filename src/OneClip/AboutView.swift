import SwiftUI
import AppKit

enum PasteLightAboutInfo {
    static let author = "Ace"
    static let email = "2577113@qq.com"
    static let repository = "AceInAndroid/OneClip"
    static let repositoryURL = URL(string: "https://github.com/AceInAndroid/OneClip")!
    static let emailURL = URL(string: "mailto:2577113@qq.com")!

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"
    }
}

struct PasteLightAboutView: View {
    let isStandalone: Bool
    var onClose: (() -> Void)?

    init(isStandalone: Bool = false, onClose: (() -> Void)? = nil) {
        self.isStandalone = isStandalone
        self.onClose = onClose
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 20) {
                hero

                HStack(spacing: 12) {
                    AboutMetricCard(
                        icon: "person.fill",
                        label: "作者",
                        value: PasteLightAboutInfo.author,
                        tint: .indigo
                    )
                    AboutMetricCard(
                        icon: "shippingbox.fill",
                        label: "当前版本",
                        value: "\(PasteLightAboutInfo.version) · \(PasteLightAboutInfo.build)",
                        tint: .blue
                    )
                }

                AboutGlassCard {
                    VStack(spacing: 0) {
                        AboutLinkRow(
                            icon: "envelope.fill",
                            title: "联系邮箱",
                            value: PasteLightAboutInfo.email,
                            tint: .blue,
                            destination: PasteLightAboutInfo.emailURL
                        )
                        Divider()
                            .opacity(0.45)
                            .padding(.leading, 42)
                        AboutLinkRow(
                            icon: "chevron.left.forwardslash.chevron.right",
                            title: "开源仓库",
                            value: PasteLightAboutInfo.repository,
                            tint: .indigo,
                            destination: PasteLightAboutInfo.repositoryURL
                        )
                    }
                }

                HStack(spacing: 8) {
                    AboutTraitBadge(icon: "lock.shield.fill", title: "数据仅存本机")
                    AboutTraitBadge(icon: "swift", title: "原生 SwiftUI")
                    AboutTraitBadge(icon: "leaf.fill", title: "轻量常驻")
                }

                Text("© 2026 Ace · PasteLight")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(isStandalone ? 30 : 4)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(.thinMaterial)
                                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.8))
                        )
                }
                .buttonStyle(.plain)
                .help("关闭")
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            if isStandalone {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.09),
                                Color.clear,
                                Color.indigo.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            if isStandalone {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.34), .blue.opacity(0.12), .white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        }
        .shadow(color: isStandalone ? .black.opacity(0.2) : .clear, radius: 28, y: 12)
    }

    private var hero: some View {
        HStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 92, height: 92)
                .shadow(color: .blue.opacity(0.2), radius: 15, y: 7)
                .accessibilityLabel("PasteLight 应用图标")

            VStack(alignment: .leading, spacing: 7) {
                Text("PasteLight")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("轻一点，快一点，粘贴一步到位。")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Label("macOS 轻量剪贴板", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.blue.opacity(0.1)))
            }

            Spacer(minLength: isStandalone ? 36 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, isStandalone ? 28 : 0)
    }
}

private struct AboutMetricCard: View {
    let icon: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        AboutGlassCard {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }
}

private struct AboutLinkRow: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.11)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .help(value)
    }
}

private struct AboutTraitBadge: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.thinMaterial)
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.7))
            )
    }
}

private struct AboutGlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.24), .white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    )
            )
    }
}
