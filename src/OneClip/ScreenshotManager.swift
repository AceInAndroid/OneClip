import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

/// Selection coordinates are AppKit points (bottom-left); CGImage crops use top-left pixels.
enum ScreenshotGeometry {
    static func selection(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(start.x - end.x), height: abs(start.y - end.y)).intersection(bounds)
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return nil }
        return rect
    }

    static func pixelRect(for selection: CGRect, in bounds: CGRect, imageSize: CGSize) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0, imageSize.width > 0, imageSize.height > 0,
              let clipped = self.selection(from: selection.origin,
                                           to: CGPoint(x: selection.maxX, y: selection.maxY), in: bounds) else { return nil }
        let scaleX = imageSize.width / bounds.width
        let scaleY = imageSize.height / bounds.height
        return CGRect(x: (clipped.minX - bounds.minX) * scaleX,
                      y: (bounds.maxY - clipped.maxY) * scaleY,
                      width: clipped.width * scaleX, height: clipped.height * scaleY)
            .integral.intersection(CGRect(origin: .zero, size: imageSize))
    }
}

enum ScreenshotImageEncoder {
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.encodingFailed }
        return data as Data
    }
}

private enum ScreenshotError: LocalizedError {
    case noDisplay, tooLarge, encodingFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "未找到可截图的屏幕，请检查显示器连接后重试。"
        case .tooLarge: return "当前显示器总分辨率过大，请暂时减少连接的屏幕后重试。"
        case .encodingFailed: return "截图编码失败，原剪贴板内容未更改，请重试。"
        }
    }
}

@MainActor
final class ScreenshotManager: NSObject, ObservableObject {
    static let shared = ScreenshotManager()

    @Published private(set) var hasPermission = false
    @Published private(set) var isCapturing = false
    @Published private(set) var statusMessage = "拖动框选区域，回车或双击选区复制，Esc 取消。"
    @Published private(set) var shortcutError: String?

    var onWillCapture: (() -> Void)?
    private var shortcut: Hotkey?
    private var isRecordingShortcut = false
    private var captureTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var panels: [ScreenshotSelectionPanel] = []
    private var previousApplication: NSRunningApplication?
    private var toastPanel: NSPanel?
    private var toastTask: Task<Void, Never>?

    override private init() {
        super.init()
        refreshPermission()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigurationChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func applicationActivated() { refreshPermission() }

    @objc private func screenConfigurationChanged() {
        if isCapturing {
            cancel()
            statusMessage = "显示器配置已变化，截图已取消，请重新开始。"
        }
    }

    @discardableResult
    func refreshPermission() -> Bool {
        hasPermission = CGPreflightScreenCaptureAccess()
        return hasPermission
    }

    func requestPermission() {
        // Only a user action reaches this path; startup and status checks never prompt.
        if !refreshPermission() { _ = CGRequestScreenCaptureAccess() }
        if refreshPermission() {
            statusMessage = "屏幕录制已授权，可以开始区域截图。"
        } else {
            statusMessage = "请在系统设置中打开 PasteLight 的屏幕录制权限，再返回重新检查。必要时退出并重新打开应用。"
            openPermissionSettings()
        }
    }

    func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func configureShortcut(_ value: GlobalShortcut) {
        shortcut?.unregister()
        shortcut = nil
        guard !isRecordingShortcut else { return }
        guard !value.conflicts(with: SettingsManager.shared.globalShortcut) else {
            shortcutError = "截图与剪贴板快捷键重复，请在设置中更换。"
            return
        }
        let hotkey = Hotkey(keyCode: value.keyCode, modifierFlags: value.modifierFlags, callback: { [weak self] in
            Task { @MainActor in self?.startCapture() }
        }, hotkeyID: 1002)
        guard hotkey.registerCarbonOnly() else {
            shortcutError = "截图快捷键注册失败，可能已被系统或其他应用占用。请更换快捷键，也可使用菜单截图。"
            return
        }
        shortcut = hotkey
        shortcutError = nil
    }

    func setShortcutRecording(_ recording: Bool) {
        isRecordingShortcut = recording
        configureShortcut(SettingsManager.shared.screenshotShortcut)
    }

    func startCapture() {
        if isCapturing {
            // An existing selection may have lost focus or been ordered out by macOS.
            // Restore that session instead of silently ignoring every subsequent action.
            if !panels.isEmpty {
                ScreenshotSelectionPanel.present(panels)
                Logger.shared.info("已恢复截图框选窗口")
            }
            return
        }
        guard refreshPermission() else {
            let alert = NSAlert()
            alert.messageText = "允许 PasteLight 截取屏幕"
            alert.informativeText = "区域截图需要“屏幕与系统音频录制”权限。仅在你发起截图时读取屏幕，不录制视频或音频。请在系统设置中开启 PasteLight；若授权后仍未生效，请退出并重新打开应用。"
            alert.addButton(withTitle: "申请权限并打开设置")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { requestPermission() }
            return
        }

        isCapturing = true
        Logger.shared.info("开始区域截图")
        statusMessage = "正在准备截图…"
        sessionID = UUID()
        let currentSession = sessionID
        previousApplication = NSWorkspace.shared.frontmostApplication
        toastPanel?.orderOut(nil)
        toastPanel = nil
        onWillCapture?()

        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.sessionID == currentSession else { return }
            self.fail("读取屏幕超时，请检查屏幕录制权限后重试。")
        }
        captureTask = Task { [weak self] in
            do {
                // Let the clipboard panel and menu disappear before taking the frozen desktop images.
                try await Task.sleep(for: .milliseconds(180))
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let self, self.sessionID == currentSession else { return }
                let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                var snapshots: [(NSScreen, CGImage)] = []
                var totalPixels: CGFloat = 0
                for screen in NSScreen.screens {
                    guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                          let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
                    let width = Int(ceil(screen.frame.width * screen.backingScaleFactor))
                    let height = Int(ceil(screen.frame.height * screen.backingScaleFactor))
                    // Bound full-resolution snapshots to 256 MiB of pixel data per capture session.
                    totalPixels += CGFloat(width) * CGFloat(height)
                    guard width > 0, height > 0, totalPixels <= 64 * 1024 * 1024 else { throw ScreenshotError.tooLarge }
                    let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
                    let configuration = SCStreamConfiguration()
                    configuration.width = width
                    configuration.height = height
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    configuration.queueDepth = 1
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    try Task.checkCancellation()
                    guard self.sessionID == currentSession else { return }
                    snapshots.append((screen, image))
                }
                guard !snapshots.isEmpty else { throw ScreenshotError.noDisplay }
                Logger.shared.info("截图静态图已就绪：\(snapshots.count) 个显示器")
                self.timeoutTask?.cancel()
                self.timeoutTask = nil
                self.presentSelection(snapshots)
            } catch is CancellationError {
                // Cancellation and timeout already clean up the session.
            } catch {
                guard let self, self.sessionID == currentSession else { return }
                self.fail("无法截图：\(error.localizedDescription) 请确认屏幕录制权限；授权后可能需要重新打开应用。")
            }
        }
    }

    private func presentSelection(_ snapshots: [(NSScreen, CGImage)]) {
        for (screen, image) in snapshots {
            let panel = ScreenshotSelectionPanel.make(frame: screen.frame)
            let view = ScreenshotSelectionView(image: image, size: screen.frame.size)
            view.onCancel = { [weak self] in self?.cancel() }
            view.onSelect = { [weak self, weak view] in
                guard let self, let view else { return }
                for panel in self.panels {
                    if let other = panel.contentView as? ScreenshotSelectionView, other !== view { other.clearSelection() }
                }
                view.window?.makeKey()
            }
            view.onConfirm = { [weak self] cropped in self?.complete(cropped) }
            panel.contentView = view
            panel.makeFirstResponder(view)
            panels.append(panel)
        }
        ScreenshotSelectionPanel.present(panels)
        Logger.shared.info("截图框选窗口已显示")
        statusMessage = "拖动框选后可添加标注，回车复制；Esc / 右键取消。"
    }

    private func complete(_ image: CGImage) {
        guard isCapturing else { return }
        let currentSession = sessionID
        closeSelectionPanels()
        statusMessage = "正在复制截图…"
        captureTask = Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotImageEncoder.png(image)
                }.value
                guard let self, self.sessionID == currentSession else { return }
                guard ClipboardManager.shared.importScreenshot(data) else {
                    self.fail("截图无法写入剪贴板，请重试。")
                    return
                }
                self.finishSession()
                self.statusMessage = "截图已复制，可直接 ⌘V 粘贴，也可从剪贴板历史中查看。"
                self.showToast()
            } catch {
                guard let self, self.sessionID == currentSession else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard isCapturing else { return }
        finishSession()
        statusMessage = "截图已取消，原剪贴板内容未更改。"
    }

    private func finishSession() {
        sessionID = UUID()
        captureTask?.cancel()
        captureTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        closeSelectionPanels()
        isCapturing = false
        if let application = previousApplication, application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            application.activate(options: [])
        }
        previousApplication = nil
    }

    private func closeSelectionPanels() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
    }

    private func fail(_ message: String) {
        Logger.shared.error("截图失败：\(message)")
        finishSession()
        refreshPermission()
        statusMessage = message
        let alert = NSAlert()
        alert.messageText = "截图未完成"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showToast() {
        toastTask?.cancel()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 58),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            Label("截图已复制，可直接 ⌘V 粘贴", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium)).padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 140, y: screen.visibleFrame.minY + 32))
        }
        toastPanel = panel
        panel.orderFrontRegardless()
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.toastPanel?.orderOut(nil)
            self?.toastPanel = nil
        }
    }
}

final class ScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func make(frame: CGRect) -> ScreenshotSelectionPanel {
        let panel = ScreenshotSelectionPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // NSPanel defaults to hiding on deactivation. A screenshot must remain usable
        // even if WeChat or any other application becomes active during selection.
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.sharingType = .none
        return panel
    }

    static func present(_ panels: [ScreenshotSelectionPanel]) {
        guard !panels.isEmpty else { return }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        for panel in panels { panel.orderFrontRegardless() }
        let pointer = NSEvent.mouseLocation
        (panels.first(where: { $0.frame.contains(pointer) }) ?? panels.first)?.makeKeyAndOrderFront(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        // Keep confirmation/cancellation available even when a toolbar button has focus.
        if event.type == .keyDown,
           ([UInt16(36), 76, 53].contains(event.keyCode) ||
            (event.modifierFlags.contains(.command) && event.keyCode == 6)),
           let selectionView = contentView as? ScreenshotSelectionView {
            selectionView.keyDown(with: event)
            return
        }
        super.sendEvent(event)
    }
}

enum ScreenshotTool: String, CaseIterable {
    case selection, rectangle, ellipse, arrow, pen, number

    var title: String {
        switch self {
        case .selection: return "选区"
        case .rectangle: return "矩形"
        case .ellipse: return "圆形"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .number: return "序号"
        }
    }

    var symbol: String {
        switch self {
        case .selection: return "viewfinder"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .number: return "1.circle"
        }
    }
}

enum ScreenshotInk: String, CaseIterable {
    case red, blue, yellow, white

    var title: String {
        switch self {
        case .red: return "珊瑚红"
        case .blue: return "蓝色"
        case .yellow: return "黄色"
        case .white: return "白色"
        }
    }

    var color: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 1, green: 0.25, blue: 0.31, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.12, green: 0.55, blue: 1, alpha: 1)
        case .yellow: return NSColor(srgbRed: 1, green: 0.8, blue: 0.12, alpha: 1)
        case .white: return .white
        }
    }
}

struct ScreenshotAnnotation {
    let tool: ScreenshotTool
    let ink: ScreenshotInk
    let lineWidth: CGFloat
    var points: [CGPoint]
    var number = 0

    @MainActor
    func draw() {
        guard let start = points.first, let end = points.last else { return }
        ink.color.setStroke()
        ink.color.setFill()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch tool {
        case .selection: return
        case .rectangle: path.appendRoundedRect(rect, xRadius: 2, yRadius: 2)
        case .ellipse: path.appendOval(in: rect)
        case .arrow:
            path.move(to: start)
            path.line(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = min(max(12, lineWidth * 4), hypot(end.x - start.x, end.y - start.y) * 0.45)
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: end)
                path.line(to: CGPoint(x: end.x - cos(angle + offset) * length,
                                     y: end.y - sin(angle + offset) * length))
            }
        case .pen:
            path.move(to: start)
            if points.count == 1 {
                NSBezierPath(ovalIn: CGRect(x: start.x - lineWidth / 2, y: start.y - lineWidth / 2,
                                            width: lineWidth, height: lineWidth)).fill()
            }
            for point in points.dropFirst() { path.line(to: point) }
        case .number:
            let text = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold),
                .foregroundColor: ink == .white || ink == .yellow ? NSColor.black : NSColor.white
            ]
            let size = text.size(withAttributes: attributes)
            let diameter = max(28, size.width + 12)
            NSBezierPath(ovalIn: CGRect(x: start.x - diameter / 2, y: start.y - diameter / 2,
                                        width: diameter, height: diameter)).fill()
            text.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2), withAttributes: attributes)
            return
        }
        path.stroke()
    }
}

/// Vector commands only: undo does not retain full-resolution bitmap snapshots.
@MainActor
final class ScreenshotMarkupState: ObservableObject {
    @Published var tool: ScreenshotTool = .selection
    @Published var ink: ScreenshotInk = .red
    @Published var lineWidth: CGFloat = 3
    @Published private(set) var annotations: [ScreenshotAnnotation] = []
    @Published private(set) var undone: [ScreenshotAnnotation] = []

    var nextNumber: Int { (annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1 }

    func append(_ annotation: ScreenshotAnnotation) {
        guard annotations.count < 500 else { return }
        annotations.append(annotation)
        undone.removeAll()
    }

    func undo() { if let last = annotations.popLast() { undone.append(last) } }
    func redo() { if let last = undone.popLast() { annotations.append(last) } }
    func clear() { annotations.removeAll(); undone.removeAll(); tool = .selection }
}

private struct ScreenshotMarkupToolbar: View {
    @ObservedObject var state: ScreenshotMarkupState
    var changed: () -> Void
    var cancel: () -> Void
    var confirm: () -> Void

    var body: some View {
        surface
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
    }

    @ViewBuilder private var surface: some View {
        if #available(macOS 26.0, *) {
            controls.glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            controls.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ScreenshotTool.allCases, id: \.self) { tool in
                    Button {
                        state.tool = tool
                        changed()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tool.symbol).font(.system(size: 17, weight: .medium))
                            Text(tool.title).font(.system(size: 10, weight: .medium))
                        }
                        .frame(width: 48, height: 48)
                        .foregroundStyle(state.tool == tool ? Color.white : Color.white.opacity(0.8))
                        .background(state.tool == tool ? Color.blue.opacity(0.65) : .clear,
                                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 15))
                    }
                    .help(tool == .selection ? "重新框选（会清除标注）" : tool.title)
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(state.tool == tool ? .isSelected : [])
                }
            }
            Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5)
            HStack(spacing: 9) {
                ForEach(ScreenshotInk.allCases, id: \.self) { ink in
                    Button { state.ink = ink; changed() } label: {
                        Circle().fill(Color(nsColor: ink.color)).frame(width: 16, height: 16)
                            .padding(3)
                            .overlay(Circle().strokeBorder(state.ink == ink ? .white : .clear, lineWidth: 1.5))
                    }
                    .help(ink.title).accessibilityLabel(ink.title)
                    .accessibilityAddTraits(state.ink == ink ? .isSelected : [])
                }
                Button {
                    state.lineWidth = state.lineWidth == 3 ? 5 : state.lineWidth == 5 ? 8 : 3
                    changed()
                } label: {
                    Image(systemName: "lineweight").frame(width: 22, height: 26)
                }
                .help("线条粗细：\(Int(state.lineWidth))，点击切换")
                .accessibilityLabel("线条粗细 \(Int(state.lineWidth))")
                Button { state.undo(); changed() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(state.annotations.isEmpty).help("撤销 ⌘Z").accessibilityLabel("撤销")
                Button { state.redo(); changed() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(state.undone.isEmpty).help("重做 ⇧⌘Z").accessibilityLabel("重做")
                Spacer(minLength: 0)
                Button(action: cancel) { Image(systemName: "xmark").frame(width: 22, height: 28) }
                    .help("取消 Esc").accessibilityLabel("取消截图")
                Button(action: confirm) {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 28).background(Color.blue, in: Capsule())
                }
                .help("复制 ↵").accessibilityLabel("复制截图")
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(width: 336)
    }
}

final class ScreenshotSelectionView: NSView {
    var onCancel: (() -> Void)?
    var onSelect: (() -> Void)?
    var onConfirm: ((CGImage) -> Void)?
    private let image: CGImage
    private let backdrop: NSImage
    private var dragStart: CGPoint?
    private var selection: CGRect?
    let markup = ScreenshotMarkupState()
    private var draft: ScreenshotAnnotation?
    private var annotationStart: CGPoint?
    private var toolbar: NSHostingView<ScreenshotMarkupToolbar>!
    private let hint = NSTextField(labelWithString: "拖动框选区域 · 回车或双击选区复制 · Esc / 右键取消")

    init(image: CGImage, size: CGSize) {
        self.image = image
        backdrop = NSImage(cgImage: image, size: size)
        super.init(frame: CGRect(origin: .zero, size: size))
        setAccessibilityLabel("区域截图，拖动选择区域，回车确认，Escape 取消")
        toolbar = NSHostingView(rootView: ScreenshotMarkupToolbar(state: markup, changed: { [weak self] in
            guard let self else { return }
            self.draft = nil
            self.annotationStart = nil
            self.needsDisplay = true
            self.hint.stringValue = self.markup.tool == .selection
                ? "拖动重新框选 · 双击 / 回车复制 · Esc 取消"
                : "\(self.markup.tool.title) · \(self.markup.tool == .number ? "点击添加连续序号" : "在选区内拖动绘制") · ⌘Z 撤销 · 回车复制"
            self.window?.makeFirstResponder(self)
        }, cancel: { [weak self] in self?.cancelSelection() }, confirm: { [weak self] in self?.confirmSelection() }))
        toolbar.isHidden = true
        addSubview(toolbar)
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.alignment = .center
        hint.frame = NSRect(x: 20, y: size.height - 58, width: max(0, size.width - 40), height: 28)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if !toolbar.isHidden { addCursorRect(toolbar.frame, cursor: .arrow) }
    }

    override func draw(_ dirtyRect: NSRect) {
        backdrop.draw(in: bounds)
        if let selection {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            for annotation in markup.annotations { annotation.draw() }
            draft?.draw()
            NSGraphicsContext.restoreGraphicsState()
        }
        let shade = NSBezierPath(rect: bounds)
        if let selection { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.36).setFill()
        shade.fill()
        if let selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            let label = "\(Int(selection.width * CGFloat(image.width) / bounds.width)) × \(Int(selection.height * CGFloat(image.height) / bounds.height)) px"
            (label as NSString).draw(at: NSPoint(x: selection.minX + 6, y: min(bounds.maxY - 20, selection.maxY + 6)),
                                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                     .foregroundColor: NSColor.white,
                                                     .backgroundColor: NSColor.black.withAlphaComponent(0.5)])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if markup.tool != .selection, let selection {
            guard selection.contains(point), markup.annotations.count < 500 else { return }
            window?.makeFirstResponder(self)
            if markup.tool == .number {
                markup.append(ScreenshotAnnotation(tool: .number, ink: markup.ink, lineWidth: markup.lineWidth,
                                                   points: [point], number: markup.nextNumber))
            } else {
                annotationStart = point
                draft = ScreenshotAnnotation(tool: markup.tool, ink: markup.ink,
                                             lineWidth: markup.lineWidth, points: [point])
            }
            needsDisplay = true
            return
        }
        if event.clickCount == 2, selection?.contains(point) == true {
            confirmSelection()
            return
        }
        onSelect?()
        window?.makeFirstResponder(self)
        // Preserve an existing selection through the first click of a double click.
        if selection?.contains(point) != true { clearSelection() }
        dragStart = point
    }

    override func mouseDragged(with event: NSEvent) {
        if annotationStart != nil, draft != nil, let selection {
            let point = convert(event.locationInWindow, from: nil)
            let clipped = CGPoint(x: min(max(point.x, selection.minX), selection.maxX),
                                  y: min(max(point.y, selection.minY), selection.maxY))
            if draft?.tool == .pen {
                if let last = draft?.points.last, hypot(clipped.x - last.x, clipped.y - last.y) >= 0.8 {
                    // Bound memory even during unusually long pointer drags.
                    if let points = draft?.points, points.count >= 8192 {
                        draft?.points = points.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
                    }
                    draft?.points.append(clipped)
                }
            } else if let start = draft?.points.first {
                draft?.points = [start, clipped]
            }
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - start.x, point.y - start.y) >= 2 {
            markup.clear()
            toolbar.isHidden = true
        }
        selection = ScreenshotGeometry.selection(from: start, to: convert(event.locationInWindow, from: nil), in: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if annotationStart != nil {
            mouseDragged(with: event)
            if let draft, draft.tool == .pen || (draft.points.count > 1 &&
                hypot(draft.points.last!.x - draft.points[0].x, draft.points.last!.y - draft.points[0].y) >= 2) {
                markup.append(draft)
            }
            draft = nil
            annotationStart = nil
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        if selection?.contains(end) == true, abs(end.x - start.x) < 2, abs(end.y - start.y) < 2 {
            dragStart = nil
            return
        }
        mouseDragged(with: event)
        dragStart = nil
        guard let selection else { return }
        let width: CGFloat = 336
        let height: CGFloat = 120
        let y = selection.minY >= height + 10 ? selection.minY - height - 10 : selection.maxY + 10
        toolbar.frame = NSRect(x: max(8, min(bounds.maxX - width - 8, selection.maxX - width)),
                               y: max(8, min(bounds.maxY - height - 8, y)), width: width, height: height)
        toolbar.isHidden = false
        window?.invalidateCursorRects(for: self)
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 6 {
            draft = nil
            annotationStart = nil
            if event.modifierFlags.contains(.shift) { markup.redo() } else { markup.undo() }
            needsDisplay = true
            return
        }
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: confirmSelection()
        default: break
        }
    }

    func clearSelection() {
        selection = nil
        dragStart = nil
        draft = nil
        annotationStart = nil
        markup.clear()
        hint.stringValue = "拖动框选区域 · 回车或双击选区复制 · Esc / 右键取消"
        toolbar.isHidden = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    @objc private func cancelSelection() { onCancel?() }

    @objc private func confirmSelection() {
        guard draft == nil, let result = renderedSelection() else { return }
        onConfirm?(result)
    }

    /// Render annotations at native capture resolution, excluding all overlay UI.
    func renderedSelection() -> CGImage? {
        guard let selection,
              let rect = ScreenshotGeometry.pixelRect(for: selection, in: bounds,
                                                       imageSize: CGSize(width: image.width, height: image.height)),
              let cropped = image.cropping(to: rect) else { return nil }
        guard !markup.annotations.isEmpty else { return cropped }
        guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(x: -bounds.minX - rect.minX / scaleX,
                            y: -bounds.minY - (CGFloat(image.height) - rect.maxY) / scaleY)
        context.clip(to: selection)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for annotation in markup.annotations { annotation.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
