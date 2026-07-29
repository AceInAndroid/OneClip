import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    static let historyRetentionDidChange = Notification.Name("HistoryRetentionDidChange")
    static let clipboardPresentationModeDidChange = Notification.Name("ClipboardPresentationModeDidChange")
}

enum ClipboardPresentationMode: String, CaseIterable, Codable, Identifiable {
    case bottomShelf
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomShelf: return "底部弹窗"
        case .window: return "窗口"
        }
    }

    var subtitle: String {
        switch self {
        case .bottomShelf: return "从屏幕底部弹出，横向浏览"
        case .window: return "使用经典纵向剪贴板窗口"
        }
    }

    var icon: String {
        switch self {
        case .bottomShelf: return "rectangle.bottomthird.inset.filled"
        case .window: return "macwindow"
        }
    }
}

struct GlobalShortcut: Equatable {
    static let defaultKeyCode: UInt16 = 9 // V
    static let defaultModifierFlags = NSEvent.ModifierFlags.command.union(.shift).rawValue

    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags

    init(
        keyCode: UInt16 = GlobalShortcut.defaultKeyCode,
        modifierFlags: UInt = GlobalShortcut.defaultModifierFlags
    ) {
        self.keyCode = keyCode
        self.modifierFlags = NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    var displayName: String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        return parts.joined() + Self.keyName(for: keyCode)
    }

    var menuKeyEquivalent: String {
        Self.keyEquivalent(for: keyCode)
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0...5: return ["A", "S", "D", "F", "H", "G"][Int(keyCode)]
        case 6...9: return ["Z", "X", "C", "V"][Int(keyCode - 6)]
        case 11: return "B"
        case 12...15: return ["Q", "W", "E", "R"][Int(keyCode - 12)]
        case 16...17: return ["Y", "T"][Int(keyCode - 16)]
        case 18...29: return ["1", "2", "3", "4", "6", "5", "=", "9", "7", "-", "8", "0"][Int(keyCode - 18)]
        case 31...35: return ["O", "U", "[", "I", "P"][Int(keyCode - 31)]
        case 37...40: return ["L", "J", "'", "K"][Int(keyCode - 37)]
        case 41: return ";"
        case 43...47: return ["\\", ",", "/", "N", "M"][Int(keyCode - 43)]
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        default: return "Key \(keyCode)"
        }
    }

    private static func keyEquivalent(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0...5: return ["a", "s", "d", "f", "h", "g"][Int(keyCode)]
        case 6...9: return ["z", "x", "c", "v"][Int(keyCode - 6)]
        case 11: return "b"
        case 12...15: return ["q", "w", "e", "r"][Int(keyCode - 12)]
        case 16...17: return ["y", "t"][Int(keyCode - 16)]
        case 18...29: return ["1", "2", "3", "4", "6", "5", "=", "9", "7", "-", "8", "0"][Int(keyCode - 18)]
        case 31...35: return ["o", "u", "[", "i", "p"][Int(keyCode - 31)]
        case 37...40: return ["l", "j", "'", "k"][Int(keyCode - 37)]
        case 41: return ";"
        case 43...47: return ["\\", ",", "/", "n", "m"][Int(keyCode - 43)]
        case 49: return " "
        case 36: return "\r"
        case 48: return "\t"
        case 51: return "\u{8}"
        case 53: return "\u{1B}"
        default: return ""
        }
    }
}

/// 应用设置数据结构
struct AppSettings: Codable {
    var showInDock: Bool
    var enableHistoryPersistence: Bool
    var autoStartOnLogin: Bool
    var isFirstLaunch: Bool
    var hasShownWelcome: Bool
    var hasShownPermissionPrompt: Bool
    
    var previewSize: String
    var showLineNumbers: Bool
    var enableAnimations: Bool

    var showInMenuBar: Bool
    var enableNotifications: Bool
    var maxImageSize: Double
    var compressionQuality: Double
    var monitoringInterval: Double
    var autoCleanupDays: Int
    var themeMode: String
    var keepWindowOnTop: Bool
    var globalShortcutKeyCode: UInt16?
    var globalShortcutModifierFlags: UInt?
    var clipboardPresentationMode: String?
    var webDAVConfiguration: WebDAVConfiguration?
    
    init() {
        showInDock = false
        enableHistoryPersistence = true
        autoStartOnLogin = false
        isFirstLaunch = true
        hasShownWelcome = false
        hasShownPermissionPrompt = false
        
        previewSize = "medium"
        showLineNumbers = false
        enableAnimations = true

        showInMenuBar = true
        enableNotifications = false
        maxImageSize = 1024.0
        compressionQuality = 0.8
        monitoringInterval = 0.6 // Default to 0.6 seconds
        autoCleanupDays = HistoryRetentionPolicy.defaultDays
        themeMode = "system"
        keepWindowOnTop = false
        globalShortcutKeyCode = GlobalShortcut.defaultKeyCode
        globalShortcutModifierFlags = GlobalShortcut.defaultModifierFlags
        clipboardPresentationMode = ClipboardPresentationMode.bottomShelf.rawValue
        webDAVConfiguration = WebDAVConfiguration()
    }
}

final class DebouncedActionScheduler: @unchecked Sendable {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pendingAction: (() -> Void)?
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval, queue: DispatchQueue) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(_ action: @escaping () -> Void) {
        lock.lock()
        generation &+= 1
        let scheduledGeneration = generation
        pendingAction = action
        workItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.execute(generation: scheduledGeneration)
        }
        workItem = item
        lock.unlock()

        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func flush() {
        lock.lock()
        generation &+= 1
        workItem?.cancel()
        workItem = nil
        let action = pendingAction
        pendingAction = nil
        lock.unlock()

        action?()
    }

    private func execute(generation scheduledGeneration: UInt64) {
        lock.lock()
        guard generation == scheduledGeneration else {
            lock.unlock()
            return
        }
        let action = pendingAction
        pendingAction = nil
        workItem = nil
        lock.unlock()

        action?()
    }
}

/// 设置管理器 - 处理所有应用设置的读取、保存和管理
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    // MARK: - 发布属性，用于 SwiftUI 绑定
    @Published var showInDock: Bool = false {
        didSet { saveSettings() }
    }
    
    @Published var enableHistoryPersistence: Bool = true {
        didSet { saveSettings() }
    }
    
    @Published var autoStartOnLogin: Bool = false {
        didSet { 
            saveSettings()
            // LaunchAtLoginManager将在OneClipApp中处理
        }
    }
    
    @Published var isFirstLaunch: Bool = true {
        didSet { saveSettings() }
    }
    
    @Published var hasShownWelcome: Bool = false {
        didSet { saveSettings() }
    }
    
    @Published var hasShownPermissionPrompt: Bool = false {
        didSet { saveSettings() }
    }
    
    // 新增缺失的发布属性
    @Published var previewSize: String = "medium" {
        didSet { saveSettings() }
    }
    
    @Published var showLineNumbers: Bool = false {
        didSet { saveSettings() }
    }
    
    @Published var enableAnimations: Bool = true {
        didSet { saveSettings() }
    }
    

    

    
    @Published var showInMenuBar: Bool = true {
        didSet { saveSettings() }
    }
    
    @Published var enableNotifications: Bool = false {
        didSet { 
            saveSettings()
            // 当关闭通知时，立即清除dock栏的红标
            if !enableNotifications {
                // NotificationManager.shared.clearBadge()
            }
        }
    }
    
    @Published var maxImageSize: Double = 1024.0 {
        didSet { saveSettings() }
    }
    
    @Published var compressionQuality: Double = 0.8 {
        didSet { saveSettings() }
    }
    
    @Published var monitoringInterval: Double = 0.6 {
        didSet { saveSettings() }
    }
    
    @Published var autoCleanupDays: Int = HistoryRetentionPolicy.defaultDays {
        didSet {
            let normalizedValue = HistoryRetentionPolicy.normalizedDays(autoCleanupDays)
            guard normalizedValue == autoCleanupDays else {
                autoCleanupDays = normalizedValue
                return
            }
            saveSettings()
            NotificationCenter.default.post(name: .historyRetentionDidChange, object: autoCleanupDays)
        }
    }
    
    @Published var themeMode: String = "system" {
        didSet { 
            saveSettings()
            applyTheme()
        }
    }
    
    @Published var keepWindowOnTop: Bool = false {
        didSet { 
            saveSettings()
            // 通知WindowManager更新窗口置顶状态
            NotificationCenter.default.post(name: NSNotification.Name("WindowOnTopChanged"), object: keepWindowOnTop)
        }
    }

    @Published var globalShortcutKeyCode: UInt16 = GlobalShortcut.defaultKeyCode {
        didSet { saveSettings() }
    }

    @Published var globalShortcutModifierFlags: UInt = GlobalShortcut.defaultModifierFlags {
        didSet { saveSettings() }
    }

    @Published var clipboardPresentationMode: ClipboardPresentationMode = .bottomShelf {
        didSet {
            saveSettings()
            NotificationCenter.default.post(
                name: .clipboardPresentationModeDidChange,
                object: clipboardPresentationMode
            )
        }
    }

    /// Only non-sensitive WebDAV settings are persisted. Login passwords and the
    /// derived encryption key are stored separately in the macOS Keychain.
    @Published var webDAVConfiguration: WebDAVConfiguration = WebDAVConfiguration() {
        didSet {
            saveSettings()
            NotificationCenter.default.post(
                name: .webDAVConfigurationDidChange,
                object: webDAVConfiguration
            )
        }
    }

    var globalShortcut: GlobalShortcut {
        GlobalShortcut(keyCode: globalShortcutKeyCode, modifierFlags: globalShortcutModifierFlags)
    }
    
    // MARK: - 私有属性
    private let logger = Logger.shared
    private let settingsURL: URL
    private let saveScheduler = DebouncedActionScheduler(delay: 0.2, queue: .main)
    
    // MARK: - 初始化
    private init() {
        // 使用 Application Support 目录
        let appSupportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oneClipDir = appSupportPath.appendingPathComponent("OneClip")
        
        // 确保目录存在
        try? FileManager.default.createDirectory(at: oneClipDir, withIntermediateDirectories: true, attributes: nil)
        
        settingsURL = oneClipDir.appendingPathComponent("settings.json")
        
        // 执行数据迁移
        migrateSettingsIfNeeded()
        
        loadSettings()
        
        logger.info("SettingsManager initialized")
    }
    
    // MARK: - 公共方法
    
    /// 标记首次启动已完成
    func markFirstLaunchCompleted() {
        logger.info("Marking first launch as completed")
        isFirstLaunch = false
    }
    
    /// 标记欢迎页面已显示
    func markWelcomeShown() {
        logger.info("Marking welcome as shown")
        hasShownWelcome = true
    }
    
    /// 标记权限提示已显示
    func markPermissionPromptShown() {
        logger.info("Marking permission prompt as shown")
        hasShownPermissionPrompt = true
    }

    func updateGlobalShortcut(_ shortcut: GlobalShortcut) {
        globalShortcutKeyCode = shortcut.keyCode
        globalShortcutModifierFlags = shortcut.modifierFlags.rawValue
    }
    
    /// 重置到默认设置
    @MainActor
    func resetToDefaults() {
        logger.info("Resetting settings to defaults")
        AccessibilityPermissionManager.shared.setPromptSuppressed(false)
        if webDAVConfiguration.mode != .disabled {
            WebDAVSyncManager.shared.disconnect()
        }
        let defaults = AppSettings()
        DispatchQueue.main.async {
            self.showInDock = defaults.showInDock
            self.enableHistoryPersistence = defaults.enableHistoryPersistence
            self.autoStartOnLogin = defaults.autoStartOnLogin
            self.isFirstLaunch = defaults.isFirstLaunch
            self.hasShownWelcome = defaults.hasShownWelcome
            self.hasShownPermissionPrompt = defaults.hasShownPermissionPrompt
            
            self.previewSize = defaults.previewSize
            self.showLineNumbers = defaults.showLineNumbers
            self.enableAnimations = defaults.enableAnimations

            self.showInMenuBar = defaults.showInMenuBar
            self.enableNotifications = defaults.enableNotifications
            self.maxImageSize = defaults.maxImageSize
            self.compressionQuality = defaults.compressionQuality
            self.monitoringInterval = defaults.monitoringInterval
            self.autoCleanupDays = defaults.autoCleanupDays
            self.themeMode = defaults.themeMode
            self.keepWindowOnTop = defaults.keepWindowOnTop
            self.globalShortcutKeyCode = defaults.globalShortcutKeyCode ?? GlobalShortcut.defaultKeyCode
            self.globalShortcutModifierFlags = defaults.globalShortcutModifierFlags ?? GlobalShortcut.defaultModifierFlags
            self.clipboardPresentationMode = ClipboardPresentationMode(
                rawValue: defaults.clipboardPresentationMode ?? ""
            ) ?? .bottomShelf
            self.webDAVConfiguration = defaults.webDAVConfiguration ?? WebDAVConfiguration()
            
            self.applyTheme()
        }
    }
    
    // 高级功能相关方法已暂时禁用
    /*
    /// 导出数据到文件
    func exportData() -> URL? {
        logger.info("Exporting settings data")
        var settings = AppSettings()
        settings.showInDock = showInDock
        settings.enableHistoryPersistence = enableHistoryPersistence
        settings.autoStartOnLogin = autoStartOnLogin
        settings.isFirstLaunch = isFirstLaunch
        settings.hasShownWelcome = hasShownWelcome
        settings.hasShownPermissionPrompt = hasShownPermissionPrompt
        settings.previewSize = previewSize
        settings.showLineNumbers = showLineNumbers
        settings.enableAnimations = enableAnimations
        settings.showInMenuBar = showInMenuBar
        settings.enableNotifications = enableNotifications
        settings.maxImageSize = maxImageSize
        settings.compressionQuality = compressionQuality
        settings.monitoringInterval = monitoringInterval
        settings.autoCleanupDays = autoCleanupDays
        settings.themeMode = themeMode
        settings.keepWindowOnTop = keepWindowOnTop
        
        do {
            let data = try JSONEncoder().encode(settings)
            let appSupportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let oneClipDir = appSupportPath.appendingPathComponent("OneClip")
            let exportURL = oneClipDir.appendingPathComponent("settings_export.json")
            try data.write(to: exportURL)
            return exportURL
        } catch {
            logger.error("Failed to export settings: \(error)")
            return nil
        }
    }
    
    /// 从文件导入数据
    func importData(from url: URL) -> Bool {
        logger.info("Importing settings data from: \(url)")
        do {
            let data = try Data(contentsOf: url)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            
            DispatchQueue.main.async {
                self.showInDock = settings.showInDock
                self.enableHistoryPersistence = settings.enableHistoryPersistence
                self.autoStartOnLogin = settings.autoStartOnLogin
                self.isFirstLaunch = settings.isFirstLaunch
                self.hasShownWelcome = settings.hasShownWelcome
                self.hasShownPermissionPrompt = settings.hasShownPermissionPrompt
                
                self.previewSize = settings.previewSize
                self.showLineNumbers = settings.showLineNumbers
                self.enableAnimations = settings.enableAnimations

                self.showInMenuBar = settings.showInMenuBar
                self.enableNotifications = settings.enableNotifications
                self.maxImageSize = settings.maxImageSize
                self.compressionQuality = settings.compressionQuality
                self.monitoringInterval = settings.monitoringInterval
                self.autoCleanupDays = HistoryRetentionPolicy.normalizedDays(settings.autoCleanupDays)
                self.themeMode = settings.themeMode
                self.keepWindowOnTop = settings.keepWindowOnTop
                self.globalShortcutKeyCode = settings.globalShortcutKeyCode ?? GlobalShortcut.defaultKeyCode
                self.globalShortcutModifierFlags = settings.globalShortcutModifierFlags ?? GlobalShortcut.defaultModifierFlags
                self.clipboardPresentationMode = ClipboardPresentationMode(
                    rawValue: settings.clipboardPresentationMode ?? ""
                ) ?? .bottomShelf
                self.webDAVConfiguration = settings.webDAVConfiguration ?? WebDAVConfiguration()
                
                self.applyTheme()
            }
            
            return true
        } catch {
            logger.error("Failed to import settings: \(error)")
            return false
        }
    }
    */
    
    // MARK: - 私有方法
    
    /// 迁移设置文件（如果需要）
    private func migrateSettingsIfNeeded() {
        // 检查旧位置是否存在设置文件
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let oldSettingsURL = documentsPath.appendingPathComponent("settings.json")
        
        // 如果新位置已经有文件，或者旧位置没有文件，则不需要迁移
        guard !FileManager.default.fileExists(atPath: settingsURL.path),
              FileManager.default.fileExists(atPath: oldSettingsURL.path) else {
            return
        }
        
        do {
            // 复制文件到新位置
            try FileManager.default.copyItem(at: oldSettingsURL, to: settingsURL)
            logger.info("Settings file migrated from Documents to Application Support")
            
            // 删除旧文件
            try FileManager.default.removeItem(at: oldSettingsURL)
            logger.info("Old settings file removed from Documents")
        } catch {
            logger.error("Failed to migrate settings file: \(error)")
        }
    }
    
    /// 加载设置
    private func loadSettings() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            logger.info("Settings file not found, using defaults")
            applyTheme()
            return
        }
        
        do {
            let data = try Data(contentsOf: settingsURL)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            
            DispatchQueue.main.async {
                self.showInDock = settings.showInDock
                self.enableHistoryPersistence = settings.enableHistoryPersistence
                self.autoStartOnLogin = settings.autoStartOnLogin
                self.isFirstLaunch = settings.isFirstLaunch
                self.hasShownWelcome = settings.hasShownWelcome
                self.hasShownPermissionPrompt = settings.hasShownPermissionPrompt
                
                self.previewSize = settings.previewSize
                self.showLineNumbers = settings.showLineNumbers
                self.enableAnimations = settings.enableAnimations

                self.showInMenuBar = settings.showInMenuBar
                self.enableNotifications = settings.enableNotifications
                self.maxImageSize = settings.maxImageSize
                self.compressionQuality = settings.compressionQuality
                self.monitoringInterval = settings.monitoringInterval
                self.autoCleanupDays = HistoryRetentionPolicy.normalizedDays(settings.autoCleanupDays)
                self.themeMode = settings.themeMode
                self.keepWindowOnTop = settings.keepWindowOnTop
                self.clipboardPresentationMode = ClipboardPresentationMode(
                    rawValue: settings.clipboardPresentationMode ?? ""
                ) ?? .bottomShelf
                self.webDAVConfiguration = settings.webDAVConfiguration ?? WebDAVConfiguration()
            }
            
            applyTheme()
            logger.info("Settings loaded successfully")
        } catch {
            logger.error("Failed to load settings: \(error)")
            applyTheme()
        }
    }
    
    /// 合并短时间内的连续修改，滑块拖动时只在停止后保存一次。
    private func saveSettings() {
        saveScheduler.schedule { [weak self] in
            self?.persistSettingsNow()
        }
    }

    func flushPendingSave() {
        saveScheduler.flush()
    }

    private func persistSettingsNow() {
        var settings = AppSettings()
        settings.showInDock = showInDock
        settings.enableHistoryPersistence = enableHistoryPersistence
        settings.autoStartOnLogin = autoStartOnLogin
        settings.isFirstLaunch = isFirstLaunch
        settings.hasShownWelcome = hasShownWelcome
        settings.hasShownPermissionPrompt = hasShownPermissionPrompt
        settings.previewSize = previewSize
        settings.showLineNumbers = showLineNumbers
        settings.enableAnimations = enableAnimations
        settings.showInMenuBar = showInMenuBar
        settings.enableNotifications = enableNotifications
        settings.maxImageSize = maxImageSize
        settings.compressionQuality = compressionQuality
        settings.monitoringInterval = monitoringInterval
        settings.autoCleanupDays = autoCleanupDays
        settings.themeMode = themeMode
        settings.keepWindowOnTop = keepWindowOnTop
        settings.globalShortcutKeyCode = globalShortcutKeyCode
        settings.globalShortcutModifierFlags = globalShortcutModifierFlags
        settings.clipboardPresentationMode = clipboardPresentationMode.rawValue
        settings.webDAVConfiguration = webDAVConfiguration
        
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
            logger.info("Settings saved successfully")
        } catch {
            logger.error("Failed to save settings: \(error)")
        }
    }
    
    /// 应用主题
    private func applyTheme() {
        DispatchQueue.main.async {
            switch self.themeMode {
            case "light":
                NSApp.appearance = NSAppearance(named: .aqua)
            case "dark":
                NSApp.appearance = NSAppearance(named: .darkAqua)
            case "system", "auto":
                NSApp.appearance = nil
            default:
                NSApp.appearance = nil
            }
            
            self.logger.info("主题已切换到: \(self.themeMode)")
        }
    }
}
