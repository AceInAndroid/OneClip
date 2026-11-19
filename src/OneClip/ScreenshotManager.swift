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
        statusMessage = "拖动框选，回车或双击选区复制；Esc / 右键取消。"
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
        if event.type == .keyDown, [UInt16(36), 76, 53].contains(event.keyCode),
           let selectionView = contentView as? ScreenshotSelectionView {
            selectionView.keyDown(with: event)
            return
        }
        super.sendEvent(event)
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
    private let toolbar = NSVisualEffectView()
    private let hint = NSTextField(labelWithString: "拖动框选区域 · 回车或双击选区复制 · Esc / 右键取消")

    init(image: CGImage, size: CGSize) {
        self.image = image
        backdrop = NSImage(cgImage: image, size: size)
        super.init(frame: CGRect(origin: .zero, size: size))
        setAccessibilityLabel("区域截图，拖动选择区域，回车确认，Escape 取消")
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 14
        toolbar.layer?.masksToBounds = true
        toolbar.isHidden = true
        let cancel = NSButton(title: "取消 Esc", target: self, action: #selector(cancelSelection))
        let confirm = NSButton(title: "复制 ↵", target: self, action: #selector(confirmSelection))
        cancel.bezelStyle = .rounded
        confirm.bezelStyle = .rounded
        confirm.contentTintColor = .controlAccentColor
        cancel.frame = NSRect(x: 10, y: 8, width: 84, height: 28)
        confirm.frame = NSRect(x: 100, y: 8, width: 84, height: 28)
        toolbar.addSubview(cancel)
        toolbar.addSubview(confirm)
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
        if event.clickCount == 2, selection?.contains(point) == true {
            confirmSelection()
            return
        }
        onSelect?()
        window?.makeFirstResponder(self)
        dragStart = point
        // Preserve an existing selection through the first click of a double click.
        if selection?.contains(point) != true { clearSelection() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        selection = ScreenshotGeometry.selection(from: start, to: convert(event.locationInWindow, from: nil), in: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        if selection?.contains(end) == true, abs(end.x - start.x) < 2, abs(end.y - start.y) < 2 {
            dragStart = nil
            return
        }
        mouseDragged(with: event)
        dragStart = nil
        guard let selection else { return }
        let width: CGFloat = 194
        let height: CGFloat = 44
        let y = selection.minY >= height + 10 ? selection.minY - height - 10 : selection.maxY + 10
        toolbar.frame = NSRect(x: max(8, min(bounds.maxX - width - 8, selection.maxX - width)),
                               y: max(8, min(bounds.maxY - height - 8, y)), width: width, height: height)
        toolbar.isHidden = false
        window?.invalidateCursorRects(for: self)
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: confirmSelection()
        default: break
        }
    }

    func clearSelection() {
        selection = nil
        toolbar.isHidden = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    @objc private func cancelSelection() { onCancel?() }

    @objc private func confirmSelection() {
        guard let selection,
              let rect = ScreenshotGeometry.pixelRect(for: selection, in: bounds,
                                                       imageSize: CGSize(width: image.width, height: image.height)),
              let cropped = image.cropping(to: rect) else { return }
        onConfirm?(cropped)
    }
}
