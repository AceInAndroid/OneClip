import Foundation
import AppKit
import Combine
import CoreGraphics
import ImageIO
import UserNotifications

// 确保能访问 ClipboardItemType 和 ClipboardItem

enum ClipboardPayloadLimits {
    static let maxFormattedTextBytes = 8 * 1024 * 1024
    static let maxStoredFormattedTextBytes = maxFormattedTextBytes + 64 * 1024
    static let maxImageBytes: Int64 = 50 * 1024 * 1024
    static let maxImagePixels: Int64 = 40_000_000

    static func acceptsFormattedText(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maxFormattedTextBytes
    }

    static func acceptsStoredFormattedText(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maxStoredFormattedTextBytes
    }

    static func acceptsImage(byteCount: Int, pixelWidth: Int64, pixelHeight: Int64) -> Bool {
        guard byteCount > 0,
              Int64(byteCount) <= maxImageBytes,
              pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= Int64.max / pixelHeight else {
            return false
        }
        return pixelWidth * pixelHeight <= maxImagePixels
    }
}

protocol ClipboardImageDataProviding: AnyObject {
    var types: [NSPasteboard.PasteboardType]? { get }
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: ClipboardImageDataProviding {}

struct ClipboardImagePayload {
    let data: Data
    let type: NSPasteboard.PasteboardType
    let formatName: String
}

enum ClipboardImagePayloadReader {
    private static let preferredFormats: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "PNG"),
        (.tiff, "TIFF"),
        (NSPasteboard.PasteboardType("public.png"), "PNG"),
        (NSPasteboard.PasteboardType("public.jpeg"), "JPEG"),
        (NSPasteboard.PasteboardType("image/png"), "PNG"),
        (NSPasteboard.PasteboardType("image/jpeg"), "JPEG"),
        (NSPasteboard.PasteboardType("public.heic"), "HEIC"),
        (NSPasteboard.PasteboardType("public.heif"), "HEIF"),
        (NSPasteboard.PasteboardType("public.webp"), "WebP"),
        (NSPasteboard.PasteboardType("public.gif"), "GIF"),
        (NSPasteboard.PasteboardType("image/gif"), "GIF"),
        (NSPasteboard.PasteboardType("public.svg-image"), "SVG"),
        (.pdf, "PDF"),
        (NSPasteboard.PasteboardType("public.image"), "通用图片")
    ]

    static func read(from provider: ClipboardImageDataProviding) -> ClipboardImagePayload? {
        let declaredTypes = provider.types ?? []
        let declaredTypeSet = Set(declaredTypes)

        if let preferred = preferredFormats.first(where: { declaredTypeSet.contains($0.0) }) {
            guard let data = provider.data(forType: preferred.0), data.count > 20 else {
                return nil
            }
            return ClipboardImagePayload(data: data, type: preferred.0, formatName: preferred.1)
        }

        guard let customType = declaredTypes.first(where: { type in
            let value = type.rawValue.lowercased()
            return (value.contains("image") || value.contains("photo"))
                && !value.contains("url")
                && !value.contains("path")
        }),
        let data = provider.data(forType: customType),
        data.count > 20 else {
            return nil
        }

        return ClipboardImagePayload(
            data: data,
            type: customType,
            formatName: "自定义(\(customType.rawValue))"
        )
    }
}

enum ClipboardWriteValue {
    case string(String, NSPasteboard.PasteboardType)
    case data(Data, NSPasteboard.PasteboardType)
}

struct ClipboardWritePlan {
    private let values: [ClipboardWriteValue]
    private let fileURLs: [URL]

    init(values: [ClipboardWriteValue]) {
        self.values = values
        self.fileURLs = []
    }

    init(fileURLs: [URL]) {
        self.values = []
        self.fileURLs = fileURLs
    }

    var isValid: Bool {
        !values.isEmpty || !fileURLs.isEmpty
    }

    func commit(to pasteboard: NSPasteboard) -> Bool {
        guard isValid else { return false }

        pasteboard.clearContents()

        if !fileURLs.isEmpty {
            let objects = fileURLs.map { $0 as NSURL }
            if pasteboard.writeObjects(objects) {
                return true
            }

            pasteboard.clearContents()
            return pasteboard.setPropertyList(
                fileURLs.map(\.path),
                forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
            )
        }

        for value in values {
            let succeeded: Bool
            switch value {
            case let .string(string, type):
                succeeded = pasteboard.setString(string, forType: type)
            case let .data(data, type):
                succeeded = pasteboard.setData(data, forType: type)
            }

            guard succeeded else { return false }
        }

        return true
    }
}

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()
    
    @Published var clipboardItems: [ClipboardItem] = []
    @Published var unreadCount: Int = 0
    private var lastChangeCount: Int = 0
    private var clipboardObserver: NSObjectProtocol?
    private var monitoringTimer: Timer?
    private let settingsManager = SettingsManager.shared
    private let logger = Logger.shared
    
    // 🔧 修复：保存所有 NotificationCenter 观察者，用于后续清理
    private var notificationObservers: [NSObjectProtocol] = []
    private var historyRetentionObserver: NSObjectProtocol?
    
    // 延迟初始化 store，以便传入 settingsManager
    internal lazy var store = ClipboardStore(getCleanupDays: { [weak self] in
        return self?.settingsManager.autoCleanupDays ?? HistoryRetentionPolicy.defaultDays
    })
    private let maxClipboardImageBytes = ClipboardPayloadLimits.maxImageBytes
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    
    // 防止重复监控的机制
    private var isPerformingCopyOperation = false
    private var copyOperationTimestamp: TimeInterval = 0
    private var lastChangeTimestamp: TimeInterval = 0
    
    // 应用状态和监控管理
    private var isAppActive: Bool = true
    private var lastActiveTime: Date = Date()
    
    // 智能休眠相关属性
    private var currentMonitoringInterval: TimeInterval = 0.6
    private let activeMonitoringInterval: TimeInterval = 0.6  // 活跃时的监控间隔
    private let inactiveMonitoringInterval: TimeInterval = 2.0  // 不活跃时的监控间隔
    private let sleepMonitoringInterval: TimeInterval = 5.0   // 深度休眠时的监控间隔
    private var activityMonitor: UserActivityMonitor = UserActivityMonitor.shared
    private var currentActivityState: UserActivityState = .active
    
    // 去重机制优化
    private var itemFingerprints: [UUID: String] = [:]
    private var knownFingerprints: Set<String> = []
    private let backgroundFingerprintThreshold = 1024 * 1024
    private var isFingerprintMigrationRunning = false
    private var lastMemoryRetentionCleanup = Date.distantPast
    private let memoryRetentionCleanupInterval: TimeInterval = 60 * 60
    
    // 针对浏览器复制优化的去重机制
    private var lastContentHash: String = ""
    private var lastContentTime: Date = Date.distantPast
    private let duplicateTimeWindow: TimeInterval = 0.5 // 减少到0.5秒，允许快速复制不同内容
    private var copyOperationGeneration: UInt64 = 0

    private struct FormattedTextPayload: Codable {
        let version: Int
        let rtf: Data?
        let html: Data?

        var hasContent: Bool {
            rtf?.isEmpty == false || html?.isEmpty == false
        }
    }
    
    // 搜索优化
    @Published var searchText: String = "" {
        didSet {
            updateFilteredItems()
        }
    }
    @Published var filteredItems: [ClipboardItem] = []
    
    private init() {
        // 设置内存压力监听
        setupMemoryPressureMonitoring()
        
        // 设置用户活动监控
        setupUserActivityMonitoring()

        historyRetentionObserver = NotificationCenter.default.addObserver(
            forName: .historyRetentionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyHistoryRetention()
        }
        
        loadClipboardItems()
        updateFilteredItems()
    }
    
    func startMonitoring() {
        checkPermissions()
        setupClipboardObserver()

        // 启动用户活动监控
        activityMonitor.startMonitoring()

        logger.info("剪贴板监控已启动")
    }
    
    private func setupClipboardObserver() {
        // 移除现有观察者
        if let observer = clipboardObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // 使用 DistributedNotificationCenter 监听剪贴板变化（主要监控机制）
        clipboardObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.pasteboard.changed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkClipboardChange()
            }
        }
        
        // 使用动态监控间隔，根据用户活动状态调整
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: currentMonitoringInterval, repeats: true) { [weak self] _ in
            self?.checkClipboardChange()
        }
        
        // 立即执行一次检查
        checkClipboardChange()
        
        // 添加应用状态监听器
        setupApplicationStateObservers()
        
        logger.info("剪贴板监控已设置，初始检查频率: \(currentMonitoringInterval * 1000)ms (智能调节模式)")
    }
    
    // 设置应用状态监听器
    private func setupApplicationStateObservers() {
        // 清理旧的观察者
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()

        // 监听应用激活事件
        let appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleApplicationDidBecomeActive()
        }
        notificationObservers.append(appActiveObserver)
        
        // 监听应用进入后台事件
        let appInactiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleApplicationWillResignActive()
        }
        notificationObservers.append(appInactiveObserver)
        
        // 监听系统休眠/唤醒事件
        let willSleepObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("系统即将休眠")
        }
        notificationObservers.append(willSleepObserver)
        
        let didWakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("系统从休眠中唤醒")
            // 强制检查剪贴板状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.checkClipboardChange()
            }
        }
        notificationObservers.append(didWakeObserver)
        
        logger.debug("应用状态监听器已设置，共 \(notificationObservers.count) 个观察者")
    }
    
    // 应用状态处理方法
    private func handleApplicationDidBecomeActive() {
        logger.info("应用重新获得焦点（从后台返回或重新激活）")
        isAppActive = true
        lastActiveTime = Date()
        
        // 清除未读计数
        clearUnreadCount()
        
        // 强制检查剪贴板变化
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.checkClipboardChange()
        }
    }
    
    // MARK: - 未读计数管理
    func clearUnreadCount() {
        logger.info("清除未读计数: \(unreadCount) -> 0")
        unreadCount = 0
        // 只有在启用通知时才清除dock栏角标
        if SettingsManager.shared.enableNotifications {
            let app = NSApplication.shared.dockTile
            app.badgeLabel = nil
        }
    }
    
    func markAsRead() {
        clearUnreadCount()
    }
    
    // MARK: - 用户活动管理
    /// 更新用户活动状态，用于智能休眠功能
    public func updateUserActivity() {
        activityMonitor.updateActivity()
    }
    
    private func handleApplicationWillResignActive() {
        logger.info("应用失去焦点（进入后台或失去活跃状态）")
        isAppActive = false
    }
    
    private func checkPermissions() {
        // macOS 读取通用剪贴板不需要辅助功能权限；该权限仅用于模拟 Cmd+V。
        let accessibilityEnabled = AccessibilityPermissionManager.shared.checkPermissionSync()

        if !accessibilityEnabled {
            logger.info("辅助功能权限未授予；剪贴板历史正常工作，直接粘贴将回退为复制")
        }

        logger.info("权限检查完成")
    }
    
    // 🔧 修复：添加 deinit 清理所有资源
    deinit {
        logger.info("ClipboardManager 正在释放...")
        
        // 清理所有 NotificationCenter 观察者
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()

        if let historyRetentionObserver {
            NotificationCenter.default.removeObserver(historyRetentionObserver)
        }
        
        // 清理主剪贴板观察者
        if let observer = clipboardObserver {
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        
        // 停止所有定时器
        monitoringTimer?.invalidate()
        monitoringTimer = nil

        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        
        // 停止用户活动监控
        activityMonitor.stopMonitoring()
        
        logger.info("ClipboardManager 已完全释放")
    }
    
    func stopMonitoring() {
        if let observer = clipboardObserver {
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            clipboardObserver = nil
        }
        
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        
        // 停止用户活动监控
        activityMonitor.stopMonitoring()
        
        // 清理应用状态观察者
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        
        logger.info("剪贴板监控已停止")
    }
    
    // MARK: - 用户活动监控和智能休眠
    
    private func setupUserActivityMonitoring() {
        // 监听用户活动状态变化
        let activeObserver = NotificationCenter.default.addObserver(
            forName: .userBecameActive,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleUserBecameActive()
        }
        notificationObservers.append(activeObserver)
        
        let inactiveObserver = NotificationCenter.default.addObserver(
            forName: .userBecameInactive,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleUserBecameInactive()
        }
        notificationObservers.append(inactiveObserver)
        
        // 初始化当前监控间隔
        currentMonitoringInterval = activeMonitoringInterval
        
        logger.info("用户活动监控已设置")
    }
    
    private func handleUserBecameActive() {
        logger.info("用户重新活跃，切换到活跃监控模式")
        currentActivityState = .active
        updateMonitoringInterval(to: activeMonitoringInterval)
    }
    
    private func handleUserBecameInactive() {
        logger.info("用户进入不活跃状态，切换到节能监控模式")
        currentActivityState = .inactive
        
        // 根据不活跃时间决定监控间隔
        let inactivityDuration = activityMonitor.getInactivityDuration()
        if inactivityDuration > 300 { // 5分钟以上进入深度休眠
            currentActivityState = .sleeping
            updateMonitoringInterval(to: sleepMonitoringInterval)
            logger.info("进入深度休眠模式")
        } else {
            updateMonitoringInterval(to: inactiveMonitoringInterval)
        }
    }
    
    private func updateMonitoringInterval(to newInterval: TimeInterval) {
        guard newInterval != currentMonitoringInterval else { return }
        
        currentMonitoringInterval = newInterval
        
        // 重新设置定时器
        monitoringTimer?.invalidate()
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: newInterval, repeats: true) { [weak self] _ in
            self?.checkClipboardChange()
        }
        
        logger.info("监控间隔已调整为: \(newInterval)秒 (状态: \(currentActivityState.description))")
    }
    
    private func checkClipboardChange() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        
        if currentChangeCount != lastChangeCount {
            logger.debug("检测到剪贴板变化: \(lastChangeCount) -> \(currentChangeCount)")
            
            // 检查是否是我们自己的复制操作触发的
            let now = Date().timeIntervalSince1970
            if isPerformingCopyOperation && (now - copyOperationTimestamp) < 2.0 {
                logger.debug("跳过自己的复制操作触发的剪贴板变化")
                lastChangeCount = currentChangeCount
                return
            }
            
            // 防抖处理，减少频繁检查
            let timeSinceLastChange = now - lastChangeTimestamp
            if timeSinceLastChange < 0.2 { // 提高到200ms防抖
                logger.debug("跳过过于频繁的剪贴板变化 (间隔: \(timeSinceLastChange * 1000)ms)")
                lastChangeCount = currentChangeCount
                return
            }
            
            lastChangeCount = currentChangeCount
            lastChangeTimestamp = now
            
            // 处理剪贴板变化
            logger.info("处理剪贴板变化")
            handleClipboardChange()
        }
    }
    
    private func handleClipboardChange() {
        // 立即激活用户活动状态，确保响应及时
        activityMonitor.updateActivity()
        
        let pasteboard = NSPasteboard.general
        
        // 详细的剪贴板状态检查
        logger.debug("剪贴板变化检测开始")
        logger.debug("剪贴板变化计数: \(pasteboard.changeCount)")
        
        let types = pasteboard.types
        logger.debug("剪贴板可用类型: \(types?.map { $0.rawValue } ?? ["nil"])")
        
        // 空剪贴板是正常状态，不代表访问被拒绝；等待下一次 changeCount 变化即可。
        if types == nil || types?.isEmpty == true {
            logger.debug("剪贴板为空，等待下一次变化")
            return
        }
        
        // 重新设计的检测逻辑：智能区分访达文件复制和直接图片复制
        
        // 1. 首先检查是否有本地文件URL（访达复制文件的情况）
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !fileURLs.isEmpty {
            logger.info("发现URL: \(fileURLs.map { $0.absoluteString })")
            
            // 过滤出真正的本地文件URL（file:// 协议且文件存在）
            let localFileURLs = fileURLs.filter { url in
                return url.isFileURL && FileManager.default.fileExists(atPath: url.path)
            }
            
            if !localFileURLs.isEmpty {
                logger.info("确认本地文件URL: \(localFileURLs.map { $0.path })")
                
                // 检查是否为图片文件
                let imageFileURLs = localFileURLs.filter { url in
                    let pathExtension = url.pathExtension.lowercased()
                    let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "svg", "ico", "icns"]
                    return imageExtensions.contains(pathExtension)
                }
                
                if !imageFileURLs.isEmpty {
                    logger.info("检测到本地图片文件，加载原始图片: \(imageFileURLs.map { $0.path })")
                    handleImageFileContent(imageFileURLs)
                    return
                } else {
                    logger.info("处理非图片本地文件")
                    handleFileContent(localFileURLs)
                    return
                }
            } else {
                logger.debug("发现网络URL或不存在的文件路径，继续检查图片内容")
                // 继续下面的图片内容检查逻辑
            }
        }
        
        // 2. 检查直接的图片内容（浏览器复制图片等）
        let hasImage = hasImageContent(pasteboard)
        logger.debug("图片内容检测结果: \(hasImage)")
        
        if hasImage {
            logger.info("检测到直接图片内容（非文件复制）")
            handleImageContentSync(pasteboard)
            return
        }

        // 快速去重仅用于文本。图片和文件由完整内容指纹去重，
        // 避免为快速哈希额外读取一次大块二进制。
        let currentHash = calculateQuickContentHash(pasteboard)
        let currentTime = Date()
        if currentHash == lastContentHash,
           currentTime.timeIntervalSince(lastContentTime) < duplicateTimeWindow {
            logger.debug("检测到重复文本，跳过处理（哈希: \(String(currentHash.prefix(8)))）")
            return
        }
        lastContentHash = currentHash
        lastContentTime = currentTime
        
        // 3. 列表使用系统提供的纯文本。Excel 表格的制表符和换行会保留，
        // RTF/HTML 作为默认粘贴时恢复格式的隐藏数据保存，不参与列表展示。
        if let rawPlainText = pasteboard.string(forType: .string) {
            let plainText = ClipboardTextSanitizer.cleanForHistory(rawPlainText)
            if !plainText.isEmpty {
                addTextClipboardItem(
                    content: plainText,
                    formattedData: captureFormattedText(from: pasteboard)
                )
                return
            }
        }

        // 4. 少数应用只提供 RTF，使用其可见字符串作为纯文本回退。
        if let rtfData = pasteboard.data(forType: .rtf),
           ClipboardPayloadLimits.acceptsFormattedText(byteCount: rtfData.count),
           let attributedString = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            let plainText = ClipboardTextSanitizer.cleanForHistory(attributedString.string)
            if !plainText.isEmpty {
                addTextClipboardItem(
                    content: plainText,
                    formattedData: captureFormattedText(from: pasteboard)
                )
                return
            }
        }

        // 5. 最后处理仅提供 HTML 的文本来源。
        if let htmlData = pasteboard.data(forType: .html),
           ClipboardPayloadLimits.acceptsFormattedText(byteCount: htmlData.count) {
            let plainText = extractPlainTextFromHTML(htmlData)
            if !plainText.isEmpty {
                addTextClipboardItem(
                    content: plainText,
                    formattedData: captureFormattedText(from: pasteboard)
                )
                return
            }
        }
        
        // 6. 特殊检查：可能存在的其他数据类型
        if let types = pasteboard.types {
            for type in types {
                let typeString = type.rawValue.lowercased()
                // 检查是否有我们可能错过的图片类型
                if typeString.contains("image") && !typeString.contains("url") && !typeString.contains("path") {
                    logger.debug("发现可能的图片类型: \(type.rawValue)")
                    handleImageContentSync(pasteboard)
                    return
                }
            }
        }
        
        logger.warning("未识别的剪贴板内容类型，可用类型: \(pasteboard.types?.map { $0.rawValue } ?? [])")
    }
    
    private func addTextClipboardItem(content: String, formattedData: Data?) {
        if isDuplicateContent(content, type: .text) {
            logger.debug("跳过重复文本内容")
            return
        }

        addClipboardItem(content: content, type: .text, data: formattedData)
        logger.info("文本内容已添加: \(content.prefix(30))")
    }

    private func captureFormattedText(from pasteboard: NSPasteboard) -> Data? {
        let availableTypes = Set(pasteboard.types ?? [])

        // 只保存一种原始格式，避免 Excel 同时提供 RTF/HTML 时产生双倍内存峰值。
        // RTF 对表格与常见富文本的兼容性更稳定，缺失时再使用 HTML。
        for type in [NSPasteboard.PasteboardType.rtf, .html] where availableTypes.contains(type) {
            guard let data = autoreleasepool(invoking: { pasteboard.data(forType: type) }) else {
                continue
            }
            guard ClipboardPayloadLimits.acceptsFormattedText(byteCount: data.count) else {
                logger.warning("富文本格式数据超过 8MB，已降级为纯文本历史记录")
                return nil
            }

            let payload = FormattedTextPayload(
                version: 1,
                rtf: type == .rtf ? data : nil,
                html: type == .html ? data : nil
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary

            guard let encoded = try? encoder.encode(payload),
                  ClipboardPayloadLimits.acceptsStoredFormattedText(byteCount: encoded.count) else {
                logger.warning("富文本格式数据编码失败或超过存储上限，已降级为纯文本历史记录")
                return nil
            }
            return encoded
        }

        return nil
    }

    private func formattedTextPayload(for item: ClipboardItem) -> FormattedTextPayload? {
        guard item.type == .text else { return nil }

        let data: Data?
        if let inMemoryData = item.data,
           ClipboardPayloadLimits.acceptsStoredFormattedText(byteCount: inMemoryData.count) {
            data = inMemoryData
        } else if let filePath = item.filePath,
                  URL(fileURLWithPath: filePath).pathExtension == "richtext" {
            let url = URL(fileURLWithPath: filePath)
            let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let fileSize,
                  ClipboardPayloadLimits.acceptsStoredFormattedText(byteCount: fileSize) else {
                logger.warning("富文本历史载荷不存在或超过安全上限，已降级为纯文本")
                return nil
            }
            data = try? Data(contentsOf: url, options: .mappedIfSafe)
        } else {
            data = nil
        }

        guard let data, !data.isEmpty else { return nil }

        if let payload = try? PropertyListDecoder().decode(FormattedTextPayload.self, from: data),
           payload.version == 1,
           payload.hasContent,
           formattedPayloadIsWithinLimits(payload) {
            return payload
        }

        // Backward compatibility for history created before the structured payload format.
        guard ClipboardPayloadLimits.acceptsFormattedText(byteCount: data.count) else {
            logger.warning("旧版富文本历史载荷超过 8MB，已降级为纯文本")
            return nil
        }
        if NSAttributedString(rtf: data, documentAttributes: nil) != nil {
            return FormattedTextPayload(version: 0, rtf: data, html: nil)
        }
        if let html = String(data: data, encoding: .utf8), html.range(of: "<html", options: .caseInsensitive) != nil {
            return FormattedTextPayload(version: 0, rtf: nil, html: data)
        }
        return nil
    }

    private func formattedPayloadIsWithinLimits(_ payload: FormattedTextPayload) -> Bool {
        let rtfBytes = payload.rtf?.count ?? 0
        let htmlBytes = payload.html?.count ?? 0
        guard rtfBytes <= Int.max - htmlBytes else { return false }
        return ClipboardPayloadLimits.acceptsFormattedText(byteCount: rtfBytes + htmlBytes)
    }

    // 从 HTML 中提取纯文本；系统解析器能正确处理实体、表格换行和 Office HTML。
    private func extractPlainTextFromHTML(_ htmlData: Data) -> String {
        guard ClipboardPayloadLimits.acceptsFormattedText(byteCount: htmlData.count) else {
            return ""
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        if let attributedString = try? NSAttributedString(
            data: htmlData,
            options: options,
            documentAttributes: nil
        ) {
            return ClipboardTextSanitizer.cleanForHistory(attributedString.string)
        }

        guard let html = String(data: htmlData, encoding: .utf8) else { return "" }
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return ClipboardTextSanitizer.cleanForHistory(withoutTags)
    }
    
    // MARK: - Enhanced File Type Support
    
    private struct FileTypeClassifier {
        static let imageExtensions = [
            // Common formats
            "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "svg",
            // Apple formats
            "heic", "heif",
            // Adobe formats  
            "psd", "ai", "eps",
            // Raw formats
            "raw", "cr2", "nef", "arw", "dng",
            // Other formats
            "ico", "icns", "jp2", "j2k"
        ]
        
        static let videoExtensions = [
            // Common video formats
            "mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "m4v", "3gp",
            // Apple formats
            "m4v", "mov",
            // Professional formats
            "prores", "dnxhd", "avchd"
        ]
        
        static let audioExtensions = [
            // Common audio formats
            "mp3", "wav", "flac", "aac", "ogg", "wma", "m4a", "opus",
            // Apple formats
            "aiff", "caf",
            // Professional formats
            "alac", "dsd"
        ]
        
        static let documentExtensions = [
            // Microsoft Office
            "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            // Adobe
            "pdf",
            // Apple
            "pages", "numbers", "keynote",
            // Text formats
            "txt", "rtf", "md", "tex",
            // Other office formats
            "odt", "ods", "odp"
        ]
        
        static let codeExtensions = [
            // Programming languages
            "swift", "py", "js", "ts", "html", "css", "java", "cpp", "c", "h",
            "go", "rs", "php", "rb", "kt", "scala", "cs", "vb",
            // Config and data
            "json", "xml", "yaml", "yml", "toml", "ini", "cfg",
            // Scripts
            "sh", "bat", "ps1", "zsh", "fish",
            // Web
            "vue", "jsx", "tsx", "scss", "less", "sass"
        ]
        
        static let archiveExtensions = [
            // Common archives
            "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
            // Apple formats
            "dmg", "pkg", "app",
            // Disk images
            "iso", "img"
        ]
        
        static let executableExtensions = [
            // macOS
            "app", "pkg", "dmg",
            // Cross-platform
            "exe", "msi", "deb", "rpm", "appimage"
        ]
        
        static func classifyFileType(fileExtension: String) -> (category: String, icon: String, description: String, itemType: ClipboardItemType) {
            let ext = fileExtension.lowercased()
            
            if imageExtensions.contains(ext) {
                return ("图片", "photo", getImageTypeDescription(ext), .image)
            } else if videoExtensions.contains(ext) {
                return ("视频", "video", getVideoTypeDescription(ext), .video)
            } else if audioExtensions.contains(ext) {
                return ("音频", "music.note", getAudioTypeDescription(ext), .audio)
            } else if documentExtensions.contains(ext) {
                return ("文档", "doc.text", getDocumentTypeDescription(ext), .document)
            } else if codeExtensions.contains(ext) {
                return ("代码", "chevron.left.forwardslash.chevron.right", getCodeTypeDescription(ext), .code)
            } else if archiveExtensions.contains(ext) {
                return ("压缩包", "archivebox", getArchiveTypeDescription(ext), .archive)
            } else if executableExtensions.contains(ext) {
                return ("应用程序", "app", getExecutableTypeDescription(ext), .executable)
            } else {
                return ("文件", "doc", "未知类型文件", .file)
            }
        }
        
        private static func getImageTypeDescription(_ ext: String) -> String {
            switch ext {
            case "jpg", "jpeg": return "JPEG 图片"
            case "png": return "PNG 图片"
            case "gif": return "GIF 动画"
            case "svg": return "SVG 矢量图"
            case "heic", "heif": return "HEIF 图片"
            case "psd": return "Photoshop 文档"
            case "ai": return "Illustrator 文件"
            case "raw", "cr2", "nef", "arw", "dng": return "RAW 原片"
            default: return "图片文件"
            }
        }
        
        private static func getVideoTypeDescription(_ ext: String) -> String {
            switch ext {
            case "mp4": return "MP4 视频"
            case "mov": return "QuickTime 视频"
            case "avi": return "AVI 视频"
            case "mkv": return "MKV 视频"
            default: return "视频文件"
            }
        }
        
        private static func getAudioTypeDescription(_ ext: String) -> String {
            switch ext {
            case "mp3": return "MP3 音频"
            case "wav": return "WAV 音频"
            case "flac": return "FLAC 无损音频"
            case "m4a": return "AAC 音频"
            default: return "音频文件"
            }
        }
        
        private static func getDocumentTypeDescription(_ ext: String) -> String {
            switch ext {
            case "pdf": return "PDF 文档"
            case "doc", "docx": return "Word 文档"
            case "xls", "xlsx": return "Excel 表格"
            case "ppt", "pptx": return "PowerPoint 演示"
            case "pages": return "Pages 文档"
            case "numbers": return "Numbers 表格"
            case "keynote": return "Keynote 演示"
            case "txt": return "文本文件"
            case "md": return "Markdown 文档"
            default: return "文档文件"
            }
        }
        
        private static func getCodeTypeDescription(_ ext: String) -> String {
            switch ext {
            case "swift": return "Swift 代码"
            case "py": return "Python 代码"
            case "js": return "JavaScript 代码"
            case "ts": return "TypeScript 代码"
            case "html": return "HTML 文件"
            case "css": return "CSS 样式"
            case "json": return "JSON 数据"
            case "xml": return "XML 文件"
            default: return "代码文件"
            }
        }
        
        private static func getArchiveTypeDescription(_ ext: String) -> String {
            switch ext {
            case "zip": return "ZIP 压缩包"
            case "rar": return "RAR 压缩包"
            case "7z": return "7-Zip 压缩包"
            case "dmg": return "磁盘映像"
            case "pkg": return "macOS 安装包"
            default: return "压缩文件"
            }
        }
        
        private static func getExecutableTypeDescription(_ ext: String) -> String {
            switch ext {
            case "app": return "macOS 应用"
            case "pkg": return "macOS 安装包"
            case "dmg": return "磁盘映像"
            case "exe": return "Windows 程序"
            default: return "可执行文件"
            }
        }
    }
    
    private func hasImageContent(_ pasteboard: NSPasteboard) -> Bool {
        let availableTypes = Set(pasteboard.types ?? [])

        // 先检查是否有真实的图片格式（非图标）
        let realImageTypes: [NSPasteboard.PasteboardType] = [
            .tiff, .png,
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.bmp"),
            NSPasteboard.PasteboardType("public.gif"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
            NSPasteboard.PasteboardType("public.webp"),
            NSPasteboard.PasteboardType("public.avif")
        ]
        
        // 只检查类型声明，不为检测而提前加载一遍大图片数据。
        let hasRealImageData = realImageTypes.contains { type in
            availableTypes.contains(type)
        }
        
        if hasRealImageData {
            logger.debug("检测到真实图片数据")
            return true
        }
        
        // 如果同时存在文件URL和ICNS但没有真实图片数据，可能只是文件图标
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !fileURLs.isEmpty,
           availableTypes.contains(NSPasteboard.PasteboardType("com.apple.icns")) {
            logger.debug("只有文件URL和ICNS图标，无真实图片数据，不认为是图片内容")
            return false
        }
        
        // 扩展的图片格式检测 - 支持更多常见和特殊格式
        let imageTypes: [NSPasteboard.PasteboardType] = [
            // 系统标准格式（排除可能的文件图标格式）
            .tiff, .png,
            
            // 通用图片格式
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.bmp"),
            NSPasteboard.PasteboardType("public.gif"),
            
            // 现代格式
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
            NSPasteboard.PasteboardType("public.webp"),
            NSPasteboard.PasteboardType("public.avif"),
            
            // 矢量和特殊格式
            NSPasteboard.PasteboardType("public.svg-image"),
            NSPasteboard.PasteboardType("com.adobe.photoshop-image"),
            
            // 浏览器特殊格式
            NSPasteboard.PasteboardType("image/png"),
            NSPasteboard.PasteboardType("image/jpeg"),
            NSPasteboard.PasteboardType("image/gif"),
            NSPasteboard.PasteboardType("image/webp"),
            NSPasteboard.PasteboardType("image/svg+xml"),
            
            // 其他可能的图片格式
            NSPasteboard.PasteboardType("public.jpeg-2000"),
            NSPasteboard.PasteboardType("public.camera-raw-image"),
            NSPasteboard.PasteboardType("org.webmproject.webp")
        ]
        
        logger.debug("检查剪贴板中的图片内容，可用类型: \(pasteboard.types ?? [])")
        
        // 检查是否声明了图片类型；真正的数据只在处理阶段读取一次。
        for type in imageTypes {
            if availableTypes.contains(type) {
                logger.debug("检测到图片类型: \(type.rawValue)")
                return true
            }
        }
        
        logger.debug("未检测到图片内容")
        return false
    }
    
    private func handleImageContentSync(_ pasteboard: NSPasteboard) {
        logger.info("开始处理图片内容")

        guard let payload = ClipboardImagePayloadReader.read(from: pasteboard) else {
            logger.warning("无法获取任何格式的图片数据")
            return
        }

        let data = payload.data
        logger.info("成功获取 \(payload.formatName) 格式图片: \(data.count) 字节")

        guard Int64(data.count) <= maxClipboardImageBytes else {
            logger.warning("图片超过 50MB，已跳过预览存储以保护内存")
            return
        }
        
        // 图片内容指纹在 addClipboardItem 中按大小选择后台计算，避免在主线程
        // 对大数据重复执行 Data.hashValue 和 SHA-256。
        let fileSize = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let imageInfo = "图片 (\(payload.formatName), \(fileSize))"

        // 直接保存原始数据，让 ImagePreviewView 处理解码
        addClipboardItemWithData(content: imageInfo, type: ClipboardItemType.image, data: data)
        logger.info("图片数据已添加: \(imageInfo)")
    }
    
    private func handleImageFileContent(_ fileURLs: [URL]) {
        logger.info("处理图片文件内容: \(fileURLs.count) 个图片文件")
        
        // 验证图片文件是否存在
        let validImageFiles = fileURLs.filter { url in
            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists {
                logger.warning("图片文件不存在: \(url.path)")
            }
            return exists
        }
        
        guard !validImageFiles.isEmpty else {
            logger.error("没有有效的图片文件")
            return
        }
        
        // 处理第一个图片文件（通常只有一个）
        let imageFile = validImageFiles.first!
        logger.info("加载图片文件: \(imageFile.path)")

        if let fileSize = try? imageFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(fileSize) >= maxClipboardImageBytes {
            logger.info("图片文件超过 50MB，按普通文件记录，避免整文件载入内存")
            handleFileContent(validImageFiles)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // 文件读取、图片验证和完整指纹计算都在后台执行。
                let imageData = try Data(contentsOf: imageFile, options: .mappedIfSafe)
                guard NSImage(data: imageData) != nil else {
                    DispatchQueue.main.async {
                        self?.logger.error("图片文件格式无效或损坏: \(imageFile.path)")
                        self?.handleFileContent(validImageFiles)
                    }
                    return
                }

                let fileSize = ByteCountFormatter.string(fromByteCount: Int64(imageData.count), countStyle: .file)
                let previewText = "图片文件: \(imageFile.lastPathComponent) (\(fileSize))"
                let fingerprint = ClipboardItemFingerprint.make(
                    content: previewText,
                    type: .image,
                    data: imageData
                )

                DispatchQueue.main.async {
                    self?.addClipboardItem(
                        content: previewText,
                        type: .image,
                        data: imageData,
                        precomputedFingerprint: fingerprint
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self?.logger.error("读取图片文件失败: \(error.localizedDescription)")
                    self?.handleFileContent(validImageFiles)
                }
            }
        }
    }
    
    private func handleFileContent(_ fileURLs: [URL]) {
        logger.info("处理文件内容: \(fileURLs.count) 个文件")
        
        // 验证所有文件是否存在
        let validFiles = fileURLs.filter { url in
            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists {
                #if DEBUG
                logger.warning("文件不存在: \(url.path)")
                #endif
            }
            return exists
        }
        
        guard !validFiles.isEmpty else {
            logger.warning("没有有效的文件")
            return
        }
        
        // 使用新的文件类型分类器对文件进行分类
        var categorizedFiles: [String: [URL]] = [:]
        var fileInfos: [[String: Any]] = []
        
        for url in validFiles {
            let pathExtension = url.pathExtension.lowercased()
            let fileClassification = FileTypeClassifier.classifyFileType(fileExtension: pathExtension)
            let category = fileClassification.category
            
            // 按类别分组
            if categorizedFiles[category] == nil {
                categorizedFiles[category] = []
            }
            categorizedFiles[category]?.append(url)
            
            // 创建详细的文件信息
            var fileInfo: [String: Any] = [
                "name": url.lastPathComponent,
                "path": url.path,
                "type": url.pathExtension,
                "url": url.absoluteString,
                "category": category,
                "icon": fileClassification.icon,
                "description": fileClassification.description,
                "itemType": fileClassification.itemType.rawValue
            ]
            
            // 获取文件大小
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attributes[.size] as? Int64 {
                fileInfo["size"] = fileSize
                fileInfo["sizeFormatted"] = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            }
            
            // 获取文件创建和修改时间
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if let creationDate = attributes[.creationDate] as? Date {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    fileInfo["creationDate"] = formatter.string(from: creationDate)
                }
                if let modificationDate = attributes[.modificationDate] as? Date {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    fileInfo["modificationDate"] = formatter.string(from: modificationDate)
                }
            }
            
            fileInfos.append(fileInfo)
        }
        
        // 生成描述性内容
        let totalFiles = validFiles.count
        
        if totalFiles == 1 {
            // 单个文件，使用该文件的具体类型
            let singleFile = validFiles.first!
            let classification = FileTypeClassifier.classifyFileType(fileExtension: singleFile.pathExtension.lowercased())
            let contentTitle = "\(classification.category): \(singleFile.lastPathComponent)"
            
            if !isDuplicateContent(contentTitle, type: classification.itemType) {
                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: fileInfos, options: .prettyPrinted)
                    addClipboardItem(content: contentTitle, type: classification.itemType, data: jsonData)
                    logger.info("文件内容已添加: \(contentTitle)")
                } catch {
                    let pathsText = validFiles.map { $0.path }.joined(separator: "\n")
                    addClipboardItem(content: contentTitle, type: classification.itemType, data: pathsText.data(using: .utf8))
                    logger.info("文件内容已添加（简化版）: \(contentTitle)")
                }
            } else {
                logger.debug("跳过重复文件内容")
            }
        } else {
            // 多个文件，检查是否为同一类型
            let fileTypes = Set(validFiles.map { url in
                FileTypeClassifier.classifyFileType(fileExtension: url.pathExtension.lowercased()).itemType
            })
            
            var contentComponents: [String] = []
            
            // 按类别统计并添加到描述中
            let sortedCategories = categorizedFiles.keys.sorted()
            for category in sortedCategories {
                guard let filesInCategory = categorizedFiles[category] else { continue }
                let count = filesInCategory.count
                let fileNames = filesInCategory.prefix(3).map { $0.lastPathComponent }.joined(separator: ", ")
                
                if count <= 3 {
                    contentComponents.append("\(category): \(fileNames)")
                } else {
                    contentComponents.append("\(category): \(fileNames) 等\(count)个")
                }
            }
            
            let fileDescription = contentComponents.joined(separator: "; ")
            let contentTitle = "文件 (\(totalFiles)个): \(fileDescription)"
            
            // 如果所有文件都是同一类型，使用该类型；否则使用通用的 .file 类型
            let itemType: ClipboardItemType = fileTypes.count == 1 ? fileTypes.first! : .file
            
            if !isDuplicateContent(contentTitle, type: itemType) {
                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: fileInfos, options: .prettyPrinted)
                    addClipboardItem(content: contentTitle, type: itemType, data: jsonData)
                    logger.info("文件内容已添加: \(contentTitle)")
                } catch {
                    logger.warning("JSON序列化失败，使用简化版本: \(error.localizedDescription)")
                    let simplifiedFileInfos = fileInfos.map { info -> [String: String] in
                        return [
                            "name": info["name"] as? String ?? "",
                            "path": info["path"] as? String ?? "",
                            "category": info["category"] as? String ?? "文件"
                        ]
                    }
                    
                    if let simpleJsonData = try? JSONSerialization.data(withJSONObject: simplifiedFileInfos, options: []) {
                        addClipboardItem(content: contentTitle, type: itemType, data: simpleJsonData)
                    } else {
                        // 最后的备用方案
                        let pathsText = validFiles.map { $0.path }.joined(separator: "\n")
                        addClipboardItem(content: contentTitle, type: itemType, data: pathsText.data(using: .utf8))
                    }
                    logger.info("文件内容已添加（简化版）: \(contentTitle)")
                }
            } else {
                logger.debug("跳过重复文件内容")
            }
        }
    }
    
    // MARK: - 智能去重和内容过滤
    
    private func isDuplicateContent(_ content: String, type: ClipboardItemType) -> Bool {
        // 检查内容是否过短或无效
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.count < 1 {
            return true
        }
        
        // 文本可以直接按可见内容判断；图片和文件必须留给二进制指纹判断，
        // 避免两张同尺寸图片或两个同名文件被描述文本误判为重复。
        if type == .text || type == .code {
            let fingerprint = ClipboardItemFingerprint.make(content: content, type: type, data: nil)
            if knownFingerprints.contains(fingerprint) {
                logger.debug("跳过重复内容（历史项匹配）")
                return true
            }
        }
        
        // 检查是否为系统内容
        let systemPrefixes = ["com.apple.", "system:", "internal:"]
        if systemPrefixes.contains(where: content.lowercased().hasPrefix) {
            logger.debug("跳过系统内容")
            return true
        }
        
        return false
    }
    
    // MARK: - 添加剪贴板项目的方法
    
    private func addClipboardItemWithData(content: String, type: ClipboardItemType, data: Data) {
        addClipboardItem(content: content, type: type, data: data)
    }
    
    private func addClipboardItem(
        content: String,
        type: ClipboardItemType,
        data: Data? = nil,
        precomputedFingerprint: String? = nil
    ) {
        // 验证输入数据
        guard !content.isEmpty else {
            logger.debug("尝试添加空内容，已忽略")
            return
        }
        
        // 限制内容长度以防止内存问题
        let maxContentLength = ClipboardTextSanitizer.maxStoredCharacters
        let truncatedContent = content.count > maxContentLength ? String(content.prefix(maxContentLength)) + "..." : content

        let fingerprintContent = (type == .text || type == .code) ? content : truncatedContent
        if precomputedFingerprint == nil,
           type != .text,
           type != .code,
           let data,
           data.count >= backgroundFingerprintThreshold {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let fingerprint = ClipboardItemFingerprint.make(
                    content: fingerprintContent,
                    type: type,
                    data: data
                )
                DispatchQueue.main.async {
                    self?.addClipboardItem(
                        content: content,
                        type: type,
                        data: data,
                        precomputedFingerprint: fingerprint
                    )
                }
            }
            return
        }

        let newFingerprint = precomputedFingerprint ?? ClipboardItemFingerprint.make(
            content: fingerprintContent,
            type: type,
            data: data
        )
        if knownFingerprints.contains(newFingerprint) {
            logger.debug("跳过重复项目（类型: \(type.displayName)，指纹: \(newFingerprint.prefix(16))）")
            return
        }
        
        // 创建新项目
        let newItem = ClipboardItem(
            id: UUID(),
            content: truncatedContent,
            type: type,
            timestamp: Date(),
            data: data,
            fingerprint: newFingerprint
        )
        
        // 检查该项目是否已经在收藏列表中，并设置正确的收藏状态
        let isFavorite = FavoriteManager.shared.isFavorite(newItem)
        let item = ClipboardItem(
            id: newItem.id,
            content: newItem.content,
            type: newItem.type,
            timestamp: newItem.timestamp,
            data: newItem.data,
            filePath: newItem.filePath,
            isFavorite: isFavorite,
            fingerprint: newFingerprint
        )
        
        // 添加到顶部
        clipboardItems.insert(item, at: 0)
        itemFingerprints[item.id] = newFingerprint
        knownFingerprints.insert(newFingerprint)
        
        // 生成日志信息
        if type == .image, let imageData = data {
            print("添加新图片项目: \(type.displayName), 数据大小: \(imageData.count) 字节, 指纹: \(newFingerprint.prefix(12))")
        } else {
            print("添加新项目: \(type.displayName)")
        }
        
        removeExpiredItemsFromMemory()
        
        // 异步保存到持久化存储，避免阻塞UI
        Task.detached(priority: .background) { [weak self, item] in
            guard let self else { return }
            let storedItem = self.store.saveItem(item)

            // 图片成功落盘后释放列表中的大块 Data；预览和粘贴按 filePath 按需加载。
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let index = self.clipboardItems.firstIndex(where: { $0.id == storedItem.id }) else {
                    return
                }
                self.clipboardItems[index].data = storedItem.data
                self.clipboardItems[index].filePath = storedItem.filePath
                self.clipboardItems[index].fingerprint = storedItem.fingerprint
                self.updateFilteredItems()
            }
        }
        
        // 立即发送剪贴板变化通知，确保UI即时更新
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("ClipboardItemsChanged"), object: nil)
        }
        
        // 发送用户通知
        if let firstItem = clipboardItems.first {
            logger.info("准备发送通知，内容: \(String(firstItem.content.prefix(20)))...")
            
            // 检查通知设置
            if SettingsManager.shared.enableNotifications {
                logger.info("通知已启用，发送通知")
                
                // 增加未读计数
                unreadCount += 1
                
                // 更新 badge 数量
                NotificationManager.shared.setBadgeCount(unreadCount)
                
                // 直接调用 NotificationManager 发送通知
                NotificationManager.shared.showClipboardNotification(content: firstItem.content)
            } else {
                logger.info("通知已禁用，跳过发送和计数")
                // 通知禁用时不增加未读计数，也不显示badge
            }
        }
    }
    
    @discardableResult
    func copyToClipboard(
        item: ClipboardItem,
        preservingFormatting: Bool = true,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        logger.info("准备复制项目到剪贴板: \(item.type.displayName)")
        
        // 设置标志位防止重复监控
        isPerformingCopyOperation = true
        copyOperationTimestamp = Date().timeIntervalSince1970
        copyOperationGeneration &+= 1
        let operationGeneration = copyOperationGeneration

        // 延迟重置标志位
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.copyOperationGeneration == operationGeneration else { return }
            self.isPerformingCopyOperation = false
        }
        
        do {
            let writePlan: ClipboardWritePlan
            switch item.type {
            case .text:
                writePlan = try prepareTextClipboardWrite(
                    item,
                    preservingFormatting: preservingFormatting
                )
                
            case .image:
                writePlan = try prepareImageClipboardWrite(item)
                
            case .file, .video, .audio, .document, .code, .archive, .executable:
                writePlan = try prepareFileClipboardWrite(item)
            }

            guard writePlan.commit(to: pasteboard) else {
                throw ClipboardError.fileOperationFailed
            }

            if pasteboard.name == NSPasteboard.Name.general {
                lastChangeCount = pasteboard.changeCount
            }
            logger.info("剪贴板写入成功: \(item.type.displayName)")
            return true
        } catch {
            logger.error("复制失败: \(error.localizedDescription)")
            FeedbackManager.shared.showError("复制失败: \(error.localizedDescription)")
            if copyOperationGeneration == operationGeneration {
                isPerformingCopyOperation = false
            }
            if pasteboard.name == NSPasteboard.Name.general {
                lastChangeCount = pasteboard.changeCount
            }
            return false
        }
    }

    /// 将成功使用的记录提升到首位，并异步持久化排序信息。
    func markItemAsUsed(_ item: ClipboardItem, at usedAt: Date = Date()) {
        guard let index = clipboardItems.firstIndex(where: { $0.id == item.id }) else { return }

        var updatedItem = clipboardItems.remove(at: index)
        updatedItem.lastUsedAt = max(updatedItem.lastUsedAt ?? .distantPast, usedAt)
        clipboardItems.insert(updatedItem, at: 0)

        if updatedItem.isFavorite || FavoriteManager.shared.isFavorite(updatedItem) {
            FavoriteManager.shared.updateUsage(for: updatedItem)
        }

        updateFilteredItems()
        NotificationCenter.default.post(
            name: NSNotification.Name("ClipboardItemsChanged"),
            object: nil
        )

        Task.detached(priority: .utility) { [weak self, updatedItem, usedAt] in
            self?.store.markItemUsed(updatedItem, at: usedAt)
        }
    }
    
    private func prepareTextClipboardWrite(
        _ item: ClipboardItem,
        preservingFormatting: Bool
    ) throws -> ClipboardWritePlan {
        // 验证文本内容
        guard !item.content.isEmpty else {
            throw ClipboardError.dataCorrupted
        }

        var values: [ClipboardWriteValue] = [
            .string(item.content, .string)
        ]

        if preservingFormatting, let payload = formattedTextPayload(for: item) {
            if let rtfData = payload.rtf {
                values.append(.data(rtfData, .rtf))
            }
            if let htmlData = payload.html {
                values.append(.data(htmlData, .html))
            }
            logger.info("文本已按原格式复制到剪贴板")
        } else {
            logger.info("文本已按纯文本复制到剪贴板")
        }

        return ClipboardWritePlan(values: values)
    }
    
    private func prepareImageClipboardWrite(_ item: ClipboardItem) throws -> ClipboardWritePlan {
        // 优先使用内存中的数据，如果没有则从磁盘加载
        var imageData = item.data
        
        // 如果内存中没有数据，尝试从磁盘加载
        if imageData == nil || (imageData?.isEmpty == true) {
            logger.info("图片数据为空，尝试从磁盘加载: \(item.filePath ?? "无路径")")
            
            if let filePath = item.filePath {
                let url = URL(fileURLWithPath: filePath)
                let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let fileSize,
                      fileSize > 0,
                      Int64(fileSize) <= maxClipboardImageBytes else {
                    logger.error("图片文件不存在或超过 50MB 安全上限")
                    throw ClipboardError.imageProcessingFailed
                }
                do {
                    imageData = try Data(contentsOf: url, options: .mappedIfSafe)
                    logger.info("成功从磁盘加载图片数据，大小: \(imageData?.count ?? 0) 字节")
                } catch {
                    logger.error("从磁盘加载图片失败: \(error.localizedDescription)")
                    throw ClipboardError.dataCorrupted
                }
            } else {
                logger.error("图片文件路径为空")
                throw ClipboardError.dataCorrupted
            }
        }
        
        guard let data = imageData, !data.isEmpty else {
            logger.error("图片数据无效或为空")
            throw ClipboardError.dataCorrupted
        }

        guard Int64(data.count) <= maxClipboardImageBytes else {
            logger.error("图片超过 50MB 安全上限")
            throw ClipboardError.imageProcessingFailed
        }

        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let sourceType = CGImageSourceGetType(source),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value {
            guard ClipboardPayloadLimits.acceptsImage(
                byteCount: data.count,
                pixelWidth: width,
                pixelHeight: height
            ) else {
                logger.error("图片像素或文件大小超过安全上限: \(width)×\(height), \(data.count) 字节")
                throw ClipboardError.imageProcessingFailed
            }

            let pasteboardType = NSPasteboard.PasteboardType(sourceType as String)
            logger.info("图片将以原始格式写入剪贴板: \(pasteboardType.rawValue)")
            return ClipboardWritePlan(values: [.data(data, pasteboardType)])
        }

        let header = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        if header.contains("<svg") {
            return ClipboardWritePlan(values: [
                .data(data, NSPasteboard.PasteboardType("public.svg-image"))
            ])
        }
        if data.starts(with: Data("%PDF".utf8)) {
            return ClipboardWritePlan(values: [.data(data, .pdf)])
        }

        logger.error("无法安全识别图片格式，拒绝执行解码转换")
        throw ClipboardError.imageProcessingFailed
    }
    
    private func prepareFileClipboardWrite(_ item: ClipboardItem) throws -> ClipboardWritePlan {
        logger.info("开始复制文件类型内容: \(item.content)")
        logger.debug("项目类型: \(item.type)")
        logger.debug("数据大小: \(item.data?.count ?? 0) 字节")
        
        var fileURLs: [URL] = []
        
        // 方案1: 从JSON数据中解析文件URL
        if let jsonData = item.data {
            logger.debug("尝试解析JSON数据...")
            
            do {
                if let fileInfos = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                    logger.debug("成功解析JSON，包含 \(fileInfos.count) 个文件信息")
                    
                    fileURLs = fileInfos.compactMap { info -> URL? in
                        guard let path = info["path"] as? String else { 
                            logger.warning("无效的文件路径: \(info)")
                            return nil 
                        }
                        
                        logger.debug("处理文件路径: \(path)")
                        
                        let url = URL(fileURLWithPath: path)
                        let exists = FileManager.default.fileExists(atPath: url.path)
                        
                        if !exists {
                            logger.warning("文件不存在: \(path)")
                            return nil
                        }
                        
                        logger.debug("文件存在: \(url.lastPathComponent)")
                        return url
                    }
                    
                    logger.info("从JSON解析到 \(fileURLs.count) 个有效文件")
                } else {
                    logger.warning("JSON数据格式不正确")
                }
            } catch {
                logger.error("JSON解析失败: \(error)")
            }
        }
        
        // 方案2: 如果JSON解析失败，尝试从content中提取文件名并搜索
        if fileURLs.isEmpty {
            logger.debug("尝试从content中提取文件名: \(item.content)")
            
            // 从类似 "文档: 高等学校毕业生档案转递单 - (附件3) .docx" 中提取文件名
            var fileName: String?
            
            // 查找冒号后的内容
            if let colonIndex = item.content.firstIndex(of: ":") {
                let afterColon = String(item.content[item.content.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                fileName = afterColon
            } else {
                fileName = item.content
            }
            
            if let searchFileName = fileName, !searchFileName.isEmpty {
                logger.debug("搜索文件名: \(searchFileName)")
                
                // 在常用位置搜索文件
                let searchPaths = [
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
                ]
                
                for searchPath in searchPaths {
                    let potentialFile = searchPath.appendingPathComponent(searchFileName)
                    if FileManager.default.fileExists(atPath: potentialFile.path) {
                        fileURLs.append(potentialFile)
                        logger.info("找到文件: \(potentialFile.path)")
                        break
                    }
                }
                
                // 如果还没找到，进行递归搜索
                if fileURLs.isEmpty {
                    logger.debug("进行递归搜索...")
                    if let foundURL = searchFileRecursively(fileName: searchFileName) {
                        fileURLs.append(foundURL)
                        logger.info("递归搜索找到文件: \(foundURL.path)")
                    }
                }
            }
        }
        
        // 方案3: 生成文件剪贴板写入计划
        if !fileURLs.isEmpty {
            logger.info("准备复制 \(fileURLs.count) 个文件到剪贴板")
            return ClipboardWritePlan(fileURLs: fileURLs)
        } else {
            logger.error("没有找到有效的文件路径")
            guard !item.content.isEmpty else {
                throw ClipboardError.fileOperationFailed
            }
            logger.warning("将无法定位的文件记录降级为文本复制")
            return ClipboardWritePlan(values: [.string(item.content, .string)])
        }
    }
    
    // MARK: - 异步文件搜索优化
    
    private func searchFileRecursively(fileName: String) -> URL? {
        // 对于主线程调用，使用快速搜索
        return searchFileQuickly(fileName: fileName)
    }
    
    private func searchFileQuickly(fileName: String) -> URL? {
        // 只搜索最常用的目录，避免深度递归
        let commonPaths = getCommonSearchPaths()
        
        for basePath in commonPaths {
            let fileURL = basePath.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                logger.info("快速搜索找到文件: \(fileURL.path)")
                return fileURL
            }
        }
        
        // 如果快速搜索失败，启动异步深度搜索
        searchFileAsynchronously(fileName: fileName) { [weak self] foundURL in
            guard let self = self, let url = foundURL else { return }
            
            DispatchQueue.main.async {
                // 如果找到文件，可以选择性地通知UI或缓存结果
                self.logger.info("异步搜索找到文件: \(url.path)")
            }
        }
        
        return nil
    }
    
    private func searchFileAsynchronously(fileName: String, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            
            guard let enumerator = FileManager.default.enumerator(
                at: homeDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                completion(nil)
                return
            }
            
            // 限制搜索时间，避免长时间阻塞
            let startTime = Date()
            let maxSearchTime: TimeInterval = 5.0 // 最多搜索5秒
            
            for case let fileURL as URL in enumerator {
                // 检查是否超时
                if Date().timeIntervalSince(startTime) > maxSearchTime {
                    self.logger.warning("文件搜索超时，停止搜索: \(fileName)")
                    break
                }
                
                if fileURL.lastPathComponent == fileName {
                    do {
                        let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                        if resourceValues.isRegularFile == true {
                            completion(fileURL)
                            return
                        }
                    } catch {
                        continue
                    }
                }
            }
            
            completion(nil)
        }
    }
    
    private func getFileSize(url: URL) -> String {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int64 {
                return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            }
        } catch {
            logger.warning("无法获取文件大小: \(url.path)")
        }
        return "未知大小"
    }
    
    func deleteItem(_ item: ClipboardItem) {
        // 检查是否为收藏项目，如果是则不允许删除
        if FavoriteManager.shared.isFavorite(item) {
            logger.info("收藏项目不能删除: \(item.content.prefix(30))")
            return
        }
        
        if let index = clipboardItems.firstIndex(where: { $0.id == item.id }) {
            let itemToDelete = clipboardItems[index]
            
            // 如果是图片类型，从缓存中移除
            if itemToDelete.type == .image {
                ImageCacheManager.shared.removeImage(forKey: itemToDelete.id.uuidString)
            }
            
            clipboardItems.remove(at: index)
            rebuildFingerprintIndex()
            store.deleteItem(itemToDelete)
            logger.info("项目已删除: \(itemToDelete.content.prefix(30))")
            updateFilteredItems()
            
            // 发送剪贴板变化通知，确保菜单栏立即更新
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("ClipboardItemsChanged"), object: nil)
            }
        }
    }
    
    func clearAllItems() {
        // 1. 获取所有收藏项目（从FavoriteManager获取，确保数据一致性）
        let favoriteItems = ClipboardHistoryDeduplicator.deduplicate(
            FavoriteManager.shared.getAllFavorites()
        )
        
        // 2. 清理非收藏项目的图片缓存
        for item in clipboardItems {
            if !FavoriteManager.shared.isFavorite(item) && item.type == .image {
                ImageCacheManager.shared.removeImage(forKey: item.id.uuidString)
            }
        }
        
        // 3. 清空存储
        let storedFavoriteItems = store.clearAllItems(preserving: favoriteItems)
        
        // 4. 更新ClipboardManager的内存列表，包含所有收藏项目
        clipboardItems = storedFavoriteItems
        rebuildFingerprintIndex()
        
        // 5. 确保收藏项目在ClipboardManager中的状态正确
        for i in 0..<clipboardItems.count {
            clipboardItems[i].isFavorite = true
        }

        if clipboardItems.contains(where: { $0.fingerprint == nil }) {
            scheduleFingerprintMigration()
        }
        
        logger.info("非收藏项目已清空，收藏项目已保留(\(favoriteItems.count)个)")
        updateFilteredItems()
        
        // 6. 通知界面更新
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("ClipboardItemsChanged"), object: nil)
        }
    }

    func applyHistoryRetention() {
        let removedCount = removeExpiredItemsFromMemory(force: true)
        let retentionDays = settingsManager.autoCleanupDays

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.store.cleanupExpiredItems()
        }

        updateFilteredItems()
        if removedCount > 0 {
            logger.info("已按保留期限清理 \(removedCount) 条非收藏历史")
            NotificationCenter.default.post(name: NSNotification.Name("ClipboardItemsChanged"), object: nil)
        } else if retentionDays == 0 {
            logger.info("历史记录保留期限已设为永久")
        }
    }

    @discardableResult
    private func removeExpiredItemsFromMemory(now: Date = Date(), force: Bool = false) -> Int {
        let retentionDays = settingsManager.autoCleanupDays
        guard retentionDays > 0 else { return 0 }
        guard force || now.timeIntervalSince(lastMemoryRetentionCleanup) >= memoryRetentionCleanupInterval else {
            return 0
        }
        lastMemoryRetentionCleanup = now

        let originalCount = clipboardItems.count
        clipboardItems.removeAll { item in
            if FavoriteManager.shared.isFavorite(item) { return false }
            return !HistoryRetentionPolicy.shouldRetain(item, retentionDays: retentionDays, now: now)
        }
        let removedCount = originalCount - clipboardItems.count
        if removedCount > 0 {
            rebuildFingerprintIndex()
        }
        return removedCount
    }
    
    private func loadClipboardItems() {
        var loadedItems = store.loadItems()
        var requiresFingerprintPersistence = loadedItems.contains { $0.fingerprint == nil }
        var didSanitizeHistory = false

        loadedItems = loadedItems.compactMap { item in
            guard item.type == .text || item.type == .code else { return item }

            let cleanedContent = ClipboardTextSanitizer.clean(item.content)
            guard !cleanedContent.isEmpty else {
                didSanitizeHistory = true
                return nil
            }
            guard cleanedContent != item.content else { return item }

            didSanitizeHistory = true
            requiresFingerprintPersistence = true
            return ClipboardItem(
                id: item.id,
                content: cleanedContent,
                type: item.type,
                timestamp: item.timestamp,
                data: item.data,
                filePath: item.filePath,
                isFavorite: item.isFavorite,
                fingerprint: ClipboardItemFingerprint.make(
                    content: cleanedContent,
                    type: item.type,
                    data: nil
                ),
                lastUsedAt: item.lastUsedAt
            )
        }

        if didSanitizeHistory {
            store.persistSanitizedHistory(loadedItems)
            logger.info("已清理历史文本中的 Office VML/CSS 噪声")
        }

        // 文本指纹不需要磁盘 I/O，可以立即补齐；图片等旧记录交给后台流式迁移。
        for index in loadedItems.indices where loadedItems[index].fingerprint == nil {
            if loadedItems[index].type == .text || loadedItems[index].type == .code {
                loadedItems[index].fingerprint = ClipboardItemFingerprint.make(
                    content: loadedItems[index].content,
                    type: loadedItems[index].type,
                    data: nil
                )
            }
        }

        let loadedCount = loadedItems.count
        clipboardItems = ClipboardHistoryDeduplicator.deduplicate(loadedItems)
        rebuildFingerprintIndex()

        if requiresFingerprintPersistence || clipboardItems.count != loadedCount {
            scheduleFingerprintMigration(persistKnownFingerprints: true)
        }
        
        logger.info("重启后加载了\(clipboardItems.count)个剪贴板项目")
        
        // 同步收藏状态，确保数据一致性
        // 延迟执行以确保FavoriteManager已完全初始化
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            FavoriteManager.shared.syncWithClipboardStore()
            
            // 确保收藏项目在重启后能正确显示
            let favoriteItems = FavoriteManager.shared.getAllFavorites()
            if !favoriteItems.isEmpty {
                // 将收藏项目合并到ClipboardManager中（如果不存在的话）
                var updatedItems = self.clipboardItems
                var updatedIDs = Set(updatedItems.map(\.id))
                var updatedFingerprints = Set(updatedItems.compactMap(\.fingerprint))
                for var favoriteItem in favoriteItems {
                    if favoriteItem.fingerprint == nil,
                       let existingFingerprint = self.itemFingerprints[favoriteItem.id] {
                        favoriteItem.fingerprint = existingFingerprint
                    }

                    let isKnownContent = favoriteItem.fingerprint.map(updatedFingerprints.contains) ?? false
                    if !updatedIDs.contains(favoriteItem.id) && !isKnownContent {
                        updatedItems.append(favoriteItem)
                        updatedIDs.insert(favoriteItem.id)
                        if let fingerprint = favoriteItem.fingerprint {
                            updatedFingerprints.insert(fingerprint)
                        }
                    }
                }
                
                if updatedItems.count != self.clipboardItems.count {
                    self.clipboardItems = updatedItems.sorted { $0.sortTimestamp > $1.sortTimestamp }
                    self.rebuildFingerprintIndex()
                    self.logger.info("重启后恢复了\(favoriteItems.count)个收藏项目")
                }

                if self.clipboardItems.contains(where: { $0.fingerprint == nil }) {
                    self.scheduleFingerprintMigration()
                }
            }
        }
        
        // 启动预加载缓存机制
        preloadRecentImages()
    }

    private func scheduleFingerprintMigration(persistKnownFingerprints: Bool = false) {
        guard !isFingerprintMigrationRunning else { return }

        let itemsNeedingMigration = persistKnownFingerprints
            ? clipboardItems
            : clipboardItems.filter { $0.fingerprint == nil }
        guard !itemsNeedingMigration.isEmpty else { return }

        isFingerprintMigrationRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var fingerprints: [UUID: String] = [:]
            fingerprints.reserveCapacity(itemsNeedingMigration.count)

            for item in itemsNeedingMigration {
                autoreleasepool {
                    fingerprints[item.id] = ClipboardItemFingerprint.make(for: item)
                }
            }

            self?.store.applyFingerprintMigration(fingerprints)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let previousCount = self.clipboardItems.count

                for index in self.clipboardItems.indices {
                    if let fingerprint = fingerprints[self.clipboardItems[index].id] {
                        self.clipboardItems[index].fingerprint = fingerprint
                    }
                }

                self.clipboardItems = ClipboardHistoryDeduplicator.deduplicate(self.clipboardItems)
                self.rebuildFingerprintIndex()
                self.isFingerprintMigrationRunning = false
                self.updateFilteredItems()

                if self.clipboardItems.count != previousCount {
                    self.logger.info("后台历史去重：原\(previousCount)项，去重后\(self.clipboardItems.count)项")
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ClipboardItemsChanged"),
                        object: nil
                    )
                }

                // 迁移期间可能恢复了旧收藏，继续处理新增的无指纹记录。
                if self.clipboardItems.contains(where: { $0.fingerprint == nil }) {
                    self.scheduleFingerprintMigration()
                }
            }
        }
    }

    private func rebuildFingerprintIndex() {
        itemFingerprints = Dictionary(
            uniqueKeysWithValues: clipboardItems.compactMap { item in
                guard let fingerprint = item.fingerprint, !fingerprint.isEmpty else { return nil }
                return (item.id, fingerprint)
            }
        )
        knownFingerprints = Set(itemFingerprints.values)
    }
    
    // MARK: - 文件处理辅助方法
    
    private func extractFileURLsFromContent(_ content: String) -> [URL]? {
        print("从内容中提取文件URL: \(content.prefix(50))")
        
        // 方法1：从文件内容格式中提取
        if content.hasPrefix("Files: ") {
            let filesPart = String(content.dropFirst(7))
            return extractURLsFromFilesString(filesPart)
        }
        
        // 方法2：从分类格式中提取
        if content.contains("文件 (") && content.contains("个): ") {
            let components = content.components(separatedBy: ": ")
            if components.count > 1 {
                let filesPart = components[1]
                return extractURLsFromFilesString(filesPart)
            }
        }
        
        // 方法3：从单个文件格式中提取
        let patterns = [
            #"(图片|视频|音频|文档|代码|压缩包|应用程序|文件): (.+)"#,
            #"[^/\\]+\.(\w+)"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
                for match in matches {
                    if let range = Range(match.range(at: 2), in: content) {
                        let fileName = String(content[range])
                        if let urls = findFileByName(fileName) {
                            return urls
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    private func extractURLsFromFilesString(_ filesString: String) -> [URL]? {
        print("解析文件字符串: \(filesString)")
        
        var fileNames: [String] = []
        
        // 处理多个文件的情况，如 "file1.txt, file2.pdf 等3个"
        if filesString.contains(" 等") && filesString.contains("个") {
            let mainPart = filesString.components(separatedBy: " 等").first ?? filesString
            fileNames = mainPart.components(separatedBy: ", ").map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
        } else {
            // 处理简单逗号分隔的文件列表
            fileNames = filesString.components(separatedBy: ", ").map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
        }
        
        // 清理文件名（移除编号前缀等）
        fileNames = fileNames.compactMap { fileName in
            // 移除可能的编号前缀，如 "1. filename.txt"
            let cleaned = fileName.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
            return cleaned.isEmpty ? fileName : cleaned
        }
        
        print("提取的文件名: \(fileNames)")
        
        var validURLs: [URL] = []
        
        for fileName in fileNames {
            if let urls = findFileByName(fileName) {
                validURLs.append(contentsOf: urls)
            }
        }
        
        return validURLs.isEmpty ? nil : validURLs
    }
    
    private func findFileByName(_ fileName: String) -> [URL]? {
        guard !fileName.isEmpty else { return nil }
        
        print("查找文件: \(fileName)")
        
        // 验证文件名安全性
        guard isValidFileName(fileName) else {
            print("文件名包含非法字符: \(fileName)")
            return nil
        }
        
        var foundURLs: [URL] = []
        
        // 优先搜索路径
        let searchPaths = getCommonSearchPaths()
        
        for basePath in searchPaths {
            let fullPath = basePath.appendingPathComponent(fileName).path
            let url = URL(fileURLWithPath: fullPath)
            
            if FileManager.default.fileExists(atPath: url.path) {
                foundURLs.append(url)
                print("找到文件: \(fullPath)")
            }
        }
        
        // 如果在常见路径找不到，尝试用户主目录搜索
        if foundURLs.isEmpty {
            let homeURL = URL(fileURLWithPath: NSHomeDirectory())
            
            if let enumerator = FileManager.default.enumerator(at: homeURL, includingPropertiesForKeys: [.nameKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
                
                while let fileURL = enumerator.nextObject() as? URL {
                    if fileURL.lastPathComponent == fileName {
                        foundURLs.append(fileURL)
                        logger.info("在主目录找到文件: \(fileURL.path)")
                        
                        // 限制搜索结果数量
                        if foundURLs.count >= 3 {
                            break
                        }
                    }
                }
            } else {
                logger.warning("无法创建主目录枚举器")
            }
        }
        
        return foundURLs.isEmpty ? nil : foundURLs
    }
    
    private func parseFileURLsFromContent(_ content: String) -> [URL]? {
        // 使用新的提取方法
        return extractFileURLsFromContent(content)
    }
    
    // MARK: - 文件路径验证和安全检查
    
    private func isValidFilePath(_ path: String) -> Bool {
        // 基本路径验证
        guard !path.isEmpty && !path.contains("..") else {
            return false
        }
        
        // 检查路径是否以 /Users/ 开头（用户目录）或是绝对路径
        let isUserPath = path.hasPrefix("/Users/")
        let isValidAbsolutePath = path.hasPrefix("/") && FileManager.default.fileExists(atPath: path)
        
        return isUserPath || isValidAbsolutePath
    }
    
    private func isValidFileName(_ fileName: String) -> Bool {
        // 检查文件名是否包含危险字符
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return fileName.rangeOfCharacter(from: invalidCharacters) == nil
    }
    
    private func getCommonSearchPaths() -> [URL] {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        return [
            homeURL.appendingPathComponent("Downloads"),
            homeURL.appendingPathComponent("Desktop"),
            homeURL.appendingPathComponent("Documents"),
            URL(fileURLWithPath: "/tmp")
        ]
    }
    
    // MARK: - 内存压力管理

    private func setupMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.memoryPressureSource else { return }
            self.handleMemoryPressure(source.data)
        }
        memoryPressureSource = source
        source.resume()
    }

    private func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        ImageCacheManager.shared.clearCache()
        NotificationCenter.default.post(
            name: NSNotification.Name("ClearImagePreviewCache"),
            object: nil
        )

        if event.contains(.critical) {
            logger.warning("收到严重内存压力，已释放全部图片预览缓存")
        } else {
            logger.info("收到内存压力警告，已释放图片预览缓存")
        }
    }
    
    // 快速计算内容哈希用于去重
    private func calculateQuickContentHash(_ pasteboard: NSPasteboard) -> String {
        var components: [String] = []
        
        // 添加类型信息
        if let types = pasteboard.types {
            components.append(types.map { $0.rawValue }.sorted().joined(separator: ","))
        }
        
        // 添加文本内容的前200个字符
        if let text = pasteboard.string(forType: .string) {
            components.append(String(text.prefix(200)))
        }
        
        // 不在快速去重阶段读取图片二进制。图片数据在正式处理时只获取一次，
        // 历史去重继续使用完整 SHA-256 指纹。
        
        // 为文件URL添加路径信息
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty {
            let paths = fileURLs.map { $0.path }.sorted().joined(separator: ",")
            components.append("files:\(paths)")
        }
        
        return components.joined(separator: "|").hash.description
    }
    
    // 为已存储的ClipboardItem创建哈希用于去重
    func createItemHash(_ item: ClipboardItem) -> String {
        if let cachedFingerprint = itemFingerprints[item.id] {
            return cachedFingerprint
        }

        if let fingerprint = item.fingerprint, !fingerprint.isEmpty {
            itemFingerprints[item.id] = fingerprint
            knownFingerprints.insert(fingerprint)
            return fingerprint
        }

        // 菜单渲染等主线程调用不得为旧图片同步读取整个文件。后台迁移完成后
        // 会用真实内容指纹替换这个仅按 ID 区分的临时值。
        return "pending:\(item.id.uuidString)"
    }
    
    private func updateFilteredItems() {
        if searchText.isEmpty {
            filteredItems = clipboardItems
        } else {
            filteredItems = clipboardItems.filter { item in
                // 支持模糊搜索
                let searchComponents = searchText.lowercased().components(separatedBy: " ")
                let itemContent = item.content.lowercased()
                
                return searchComponents.allSatisfy { component in
                    itemContent.contains(component)
                }
            }
        }
    }
    
    // 新增：将项目恢复到系统剪贴板
    func restoreToClipboard(_ item: ClipboardItem) {
        // 设置标志避免自己触发的变化被重复检测
        isPerformingCopyOperation = true
        copyOperationTimestamp = Date().timeIntervalSince1970
        
        // 直接将项目内容恢复到系统剪贴板
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        var success = false
        switch item.type {
        case .text:
            success = pasteboard.setString(item.content, forType: .string)
        case .image:
            if let imageData = item.data {
                success = pasteboard.setData(imageData, forType: .png)
            } else if let filePath = item.filePath, !filePath.isEmpty,
                      let imageData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                success = pasteboard.setData(imageData, forType: .png)
            }
        case .file:
            if let fileData = item.data {
                success = pasteboard.setData(fileData, forType: .fileContents)
            } else if let filePath = item.filePath, !filePath.isEmpty,
                      let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                success = pasteboard.setData(fileData, forType: .fileContents)
            }
        case .video:
            if let videoData = item.data {
                success = pasteboard.setData(videoData, forType: .fileContents)
            } else if let filePath = item.filePath, !filePath.isEmpty,
                      let videoData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                success = pasteboard.setData(videoData, forType: .fileContents)
            }
        case .audio:
            if let audioData = item.data {
                success = pasteboard.setData(audioData, forType: .fileContents)
            } else if let filePath = item.filePath, !filePath.isEmpty,
                      let audioData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                success = pasteboard.setData(audioData, forType: .fileContents)
            }
        case .document:
            if let documentData = item.data {
                success = pasteboard.setData(documentData, forType: .fileContents)
            } else if let filePath = item.filePath, !filePath.isEmpty,
                      let documentData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                success = pasteboard.setData(documentData, forType: .fileContents)
            }
        case .code:
            // 代码类型作为文本处理
            success = pasteboard.setString(item.content, forType: .string)
        case .archive:
            if let archiveData = item.data {
                success = pasteboard.setData(archiveData, forType: .fileContents)
            } else if let filePath = item.filePath, !filePath.isEmpty,
                      let archiveData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                success = pasteboard.setData(archiveData, forType: .fileContents)
            }
        case .executable:
            if let executableData = item.data {
                success = pasteboard.setData(executableData, forType: .fileContents)
            } else if let filePath = item.filePath, !filePath.isEmpty,
                      let executableData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                success = pasteboard.setData(executableData, forType: .fileContents)
            }
        }
        
        if success {
            logger.info("已恢复到系统剪贴板: \(item.content.prefix(30))")
            
            // 更新剪贴板计数以同步状态
            lastChangeCount = NSPasteboard.general.changeCount
        } else {
            logger.error("恢复到剪贴板失败: \(item.content.prefix(30))")
        }
        
        // 延迟恢复监控状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isPerformingCopyOperation = false
        }
    }
    
    // 新增：获取存储信息
    func getStorageInfo() -> ClipboardStore.StorageInfo {
        return store.getStorageInfo()
    }
    
    // 新增：手动清理存储
    func performManualCleanup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.logger.info("开始手动清理存储...")
            self?.store.performManualCleanup()
            
            // 重新加载剪贴板项目
            DispatchQueue.main.async {
                self?.clipboardItems = []
                self?.loadClipboardItems()
            }
            
            self?.logger.info("手动清理完成")
        }
    }
    
    // MARK: - 增强的搜索功能
    
    func searchItems(with query: String) -> [ClipboardItem] {
        guard !query.isEmpty else { return clipboardItems }
        
        let lowercaseQuery = query.lowercased()
        
        return clipboardItems.filter { item in
            // 1. 精确匹配
            if item.content.lowercased().contains(lowercaseQuery) {
                return true
            }
            
            // 2. 模糊匹配（支持拼音首字母等）
            let words = item.content.components(separatedBy: CharacterSet.whitespacesAndNewlines)
            return words.contains { word in
                word.lowercased().hasPrefix(lowercaseQuery)
            }
        }.sorted { item1, item2 in
            // 按相关性排序
            let score1 = calculateRelevanceScore(item: item1, query: lowercaseQuery)
            let score2 = calculateRelevanceScore(item: item2, query: lowercaseQuery)
            return score1 > score2
        }
    }
    
    private func calculateRelevanceScore(item: ClipboardItem, query: String) -> Int {
        let content = item.content.lowercased()
        var score = 0
        
        // 开头匹配得分更高
        if content.hasPrefix(query) {
            score += 100
        }
        
        // 包含完整查询的得分
        if content.contains(query) {
            score += 50
        }
        
        // 时间越新得分越高
        let timeScore = max(0, 10 - Int(Date().timeIntervalSince(item.timestamp) / 3600))
        score += timeScore
        
        return score
    }
    
    // MARK: - 智能内容分类
    
    private func categorizeContent(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // URL检测
        if let url = URL(string: trimmed), url.scheme != nil {
            return "链接"
        }
        
        // 邮箱检测
        if trimmed.contains("@") && trimmed.contains(".") {
            let emailRegex = try? NSRegularExpression(pattern: #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#)
            if emailRegex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.count)) != nil {
                return "邮箱"
            }
        }
        
        // 电话号码检测
        let phoneRegex = try? NSRegularExpression(pattern: #"^[+]?[\d\s\-\(\)]{8,}$"#)
        if phoneRegex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.count)) != nil {
            return "电话"
        }
        
        // 代码检测
        if trimmed.contains("{") && trimmed.contains("}") ||
           trimmed.contains("function") || trimmed.contains("class") ||
           trimmed.contains("import") || trimmed.contains("from") {
            return "代码"
        }
        
        return "文本"
    }
    
    // MARK: - 预加载缓存机制
    
    /// 预加载最近的图片到缓存中，提升启动体验
    private func preloadRecentImages() {
        let maxPreloadCount = 5 // 预加载最近5张图片
        
        // 在后台线程执行预加载，避免阻塞主线程
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            
            let recentImageItems = self.clipboardItems
                .filter { $0.type == ClipboardItemType.image }
                .prefix(maxPreloadCount)
            
            self.logger.info("🚀 开始预加载 \(recentImageItems.count) 张最近的图片")
            
            for item in recentImageItems {
                // 检查是否已在缓存中
                let cacheKey = ImageThumbnailDecoder.cacheKey(itemID: item.id)
                if ImageCacheManager.shared.getImage(forKey: cacheKey) != nil {
                    continue // 已缓存，跳过
                }
                
                // 使用队列管理器进行预加载
                ImageLoadingQueueManager.shared.enqueueImageLoad(
                    itemId: item.id.uuidString,
                    priority: .background
                ) {
                    await self.performPreloadImage(item: item)
                }
            }
        }
    }
    
    /// 执行单个图片的预加载
    @MainActor
    private func performPreloadImage(item: ClipboardItem) async {
        let thumbnail = await Task.detached(priority: .background) {
            autoreleasepool {
                guard let imageData = ImageThumbnailDecoder.imageData(for: item) else {
                    return nil as NSImage?
                }
                return ImageThumbnailDecoder.makeThumbnail(from: imageData)
            }
        }.value
        
        if let thumbnail {
            ImageCacheManager.shared.setImage(
                thumbnail,
                forKey: ImageThumbnailDecoder.cacheKey(itemID: item.id)
            )
            logger.debug("缩略图预加载完成：\(item.id)")
        } else {
            logger.debug("缩略图预加载失败：\(item.id)")
        }
    }
    
}

enum ImageThumbnailDecoder {
    static let defaultMaxPixelSize = 320

    struct Metadata {
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func cacheKey(itemID: UUID, maxPixelSize: Int = defaultMaxPixelSize) -> String {
        "\(itemID.uuidString)-thumbnail-\(maxPixelSize)"
    }

    static func imageData(for item: ClipboardItem) -> Data? {
        if let data = item.data, !data.isEmpty {
            guard Int64(data.count) <= ClipboardPayloadLimits.maxImageBytes else { return nil }
            return data
        }

        guard let filePath = item.filePath, !filePath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: filePath)
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize > 0,
              Int64(fileSize) <= ClipboardPayloadLimits.maxImageBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func metadata(from data: Data) -> Metadata? {
        guard !data.isEmpty,
              Int64(data.count) <= ClipboardPayloadLimits.maxImageBytes,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              ClipboardPayloadLimits.acceptsImage(
                byteCount: data.count,
                pixelWidth: width,
                pixelHeight: height
              ),
              width <= Int64(Int.max),
              height <= Int64(Int.max) else {
            return nil
        }

        return Metadata(pixelWidth: Int(width), pixelHeight: Int(height))
    }

    static func makeThumbnail(
        from data: Data,
        maxPixelSize: Int = defaultMaxPixelSize
    ) -> NSImage? {
        guard maxPixelSize > 0,
              !data.isEmpty,
              Int64(data.count) <= ClipboardPayloadLimits.maxImageBytes,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return nil
        }

        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
           !ClipboardPayloadLimits.acceptsImage(
                byteCount: data.count,
                pixelWidth: width,
                pixelHeight: height
           ) {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        let representation = NSBitmapImageRep(cgImage: cgImage)
        let image = NSImage(
            size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
        image.addRepresentation(representation)
        return image
    }

    static func estimatedMemoryCost(of image: NSImage) -> Int {
        let pixelWidth = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
        let pixelHeight = image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height)
        guard pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= Int.max / pixelHeight,
              pixelWidth * pixelHeight <= Int.max / 4 else {
            return 0
        }
        return pixelWidth * pixelHeight * 4
    }
}

class ImageCacheManager {
    static let shared = ImageCacheManager()

    // NSCache 是线程安全的，并且会在系统内存不足时自动释放对象
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        // 缓存中只保存缩略图，控制在低配置机器也可接受的范围内。
        cache.totalCostLimit = 12 * 1024 * 1024
        cache.countLimit = 48
    }

    /// 将图片存入缓存
    /// - Parameters:
    ///   - image: 要缓存的 NSImage 对象
    ///   - key: 唯一的缓存键 (通常是 item.id.uuidString)
    func setImage(_ image: NSImage, forKey key: String) {
        let cost = ImageThumbnailDecoder.estimatedMemoryCost(of: image)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// 从缓存中获取图片
    /// - Parameter key: 唯一的缓存键
    /// - Returns: 缓存的 NSImage 对象，如果不存在则返回 nil
    func getImage(forKey key: String) -> NSImage? {
        if let image = cache.object(forKey: key as NSString) {
            return image
        } else {
            return nil
        }
    }

    func thumbnail(itemID: UUID, data: Data, maxPixelSize: Int) -> NSImage? {
        let key = ImageThumbnailDecoder.cacheKey(
            itemID: itemID,
            maxPixelSize: maxPixelSize
        )
        if let cached = getImage(forKey: key) {
            return cached
        }

        guard let thumbnail = ImageThumbnailDecoder.makeThumbnail(
            from: data,
            maxPixelSize: maxPixelSize
        ) else {
            return nil
        }
        setImage(thumbnail, forKey: key)
        return thumbnail
    }

    /// 从缓存中移除指定的图片
    /// - Parameter key: 唯一的缓存键
    func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    /// 清空整个缓存
    func clearCache() {
        cache.removeAllObjects()
    }
}

// MARK: - 图片加载队列管理器
class ImageLoadingQueueManager: @unchecked Sendable {
    static let shared = ImageLoadingQueueManager()
    
    private let maxConcurrentLoads = 3 // 最大同时加载数量
    private let loadingQueue = DispatchQueue(label: "image.loading.queue", qos: .userInitiated, attributes: .concurrent)
    private let semaphore: DispatchSemaphore
    private var activeLoads = Set<String>()
    private let activeLoadsLock = DispatchQueue(label: "activeLoads.lock", qos: .userInitiated, attributes: .concurrent)
    
    private init() {
        self.semaphore = DispatchSemaphore(value: maxConcurrentLoads)
    }
    
    /// 添加图片加载任务到队列
    /// - Parameters:
    ///   - itemId: 图片项目ID
    ///   - priority: 加载优先级
    ///   - loadTask: 加载任务闭包
    func enqueueImageLoad(itemId: String, priority: TaskPriority = .userInitiated, loadTask: @escaping () async -> Void) {
        // 检查是否已经在加载中
        let isAlreadyLoading = activeLoadsLock.sync {
            let isLoading = activeLoads.contains(itemId)
            if !isLoading {
                activeLoads.insert(itemId)
            }
            return isLoading
        }
        
        guard !isAlreadyLoading else {
            return
        }
        
        Task(priority: priority) {
            // 使用合适的QoS等待信号量，避免优先级倒置
            let qosClass: DispatchQoS.QoSClass = {
                switch priority {
                case .userInteractive:
                    return .userInteractive
                case .userInitiated:
                    return .userInitiated
                default:
                    return .utility
                }
            }()
            
            // 等待信号量，使用匹配的QoS避免优先级倒置
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: qosClass).async {
                    self.semaphore.wait()
                    continuation.resume()
                }
            }
            
            // 执行实际的加载任务
            await loadTask()
            
            // 完成后释放资源，使用匹配的QoS
            activeLoadsLock.async(qos: DispatchQoS(qosClass: qosClass, relativePriority: 0), flags: .barrier) { [self] in
                activeLoads.remove(itemId)
            }
            
            semaphore.signal()
        }
    }
    
    /// 取消指定图片的加载
    /// - Parameter itemId: 图片项目ID
    func cancelImageLoad(itemId: String) {
        activeLoadsLock.async(qos: .userInitiated, flags: .barrier) { [self] in
            activeLoads.remove(itemId)
        }
    }
    
    /// 获取当前活跃的加载数量
    var activeLoadCount: Int {
        return activeLoadsLock.sync {
            return activeLoads.count
        }
    }
}
