import Foundation
import Cocoa

/// 优化的辅助功能权限管理器
/// 统一管理权限检查，减少重复调用和延迟
class AccessibilityPermissionManager: ObservableObject {
    static let shared = AccessibilityPermissionManager()
    
    // MARK: - Properties
    @Published private(set) var hasPermission: Bool = false
    @Published private(set) var isChecking: Bool = false
    
    private var permissionCache: Bool?
    private var lastCheckTime: Date = Date(timeIntervalSince1970: 0)
    private var observers: [() -> Void] = []
    private var pendingCompletions: [(Bool) -> Void] = []
    private var permissionTimer: Timer?
    
    // 缓存有效期：1秒（减少频繁检查）
    private let cacheValidDuration: TimeInterval = 1.0
    // 引导显示期间的权限监控间隔
    private let monitoringInterval: TimeInterval = 2.0
    static let promptSuppressionDefaultsKey = "DisableAccessibilityPrompt"
    
    private init() {
        // 初始检查
        checkPermissionAsync()
    }
    
    // MARK: - Public Methods
    
    /// 异步检查权限状态（推荐使用）
    func checkPermissionAsync(completion: ((Bool) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.checkPermissionAsync(completion: completion)
            }
            return
        }

        // 如果缓存仍有效，直接返回缓存结果
        if let cached = permissionCache,
           Date().timeIntervalSince(lastCheckTime) < cacheValidDuration {
            completion?(cached)
            return
        }
        
        if let completion {
            pendingCompletions.append(completion)
        }

        // 已经在检查时合并回调，避免返回可能过期的状态。
        guard !isChecking else { return }
        
        isChecking = true
        
        // 在后台队列检查权限
        DispatchQueue.global(qos: .userInitiated).async {
            let permission = AXIsProcessTrusted()
            
            DispatchQueue.main.async {
                self.updatePermissionStatus(permission)
                self.isChecking = false
                let completions = self.pendingCompletions
                self.pendingCompletions.removeAll()
                completions.forEach { $0(permission) }
            }
        }
    }
    
    /// 同步检查权限状态（仅在必要时使用）
    func checkPermissionSync(forceRefresh: Bool = false) -> Bool {
        // 如果缓存仍有效，直接返回缓存结果
        if !forceRefresh,
           let cached = permissionCache,
           Date().timeIntervalSince(lastCheckTime) < cacheValidDuration {
            return cached
        }
        
        let permission = AXIsProcessTrusted()
        updatePermissionStatus(permission)
        return permission
    }
    
    /// 开始监控权限变化
    func startMonitoring() {
        guard permissionTimer == nil else { return }
        
        #if DEBUG
        print("开始监控辅助功能权限（间隔: \(monitoringInterval)秒）")
        #endif
        
        checkPermissionAsync()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            self?.checkPermissionAsync()
        }
    }
    
    /// 停止监控权限变化
    func stopMonitoring() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        
        #if DEBUG
        print("停止监控辅助功能权限")
        #endif
    }
    
    /// 添加权限变化观察者
    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }
    
    /// 清除所有观察者
    func clearObservers() {
        observers.removeAll()
    }

    var isPromptSuppressed: Bool {
        UserDefaults.standard.bool(forKey: Self.promptSuppressionDefaultsKey)
    }

    func setPromptSuppressed(_ suppressed: Bool) {
        if suppressed {
            UserDefaults.standard.set(true, forKey: Self.promptSuppressionDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.promptSuppressionDefaultsKey)
        }
    }
    
    /// 请求辅助功能权限（仅检查，不显示弹窗）
    /// - Parameter showPrompt: 已废弃，权限弹窗统一由OneClipApp管理
    /// - Returns: 当前权限状态
    @discardableResult
    func requestPermission(showPrompt: Bool = false) -> Bool {
        print("[AccessibilityPermissionManager] 检查权限状态（不弹窗）")
        
        // 只检查权限状态，不显示弹窗
        let hasPermission = AXIsProcessTrusted()
        updatePermissionStatus(hasPermission)
        
        print("[AccessibilityPermissionManager] 权限检查结果: \(hasPermission)")
        return hasPermission
    }
    
    /// 静默检查权限（不显示对话框）
    func checkPermissionSilent() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false]
        let permission = AXIsProcessTrustedWithOptions(options as CFDictionary)
        updatePermissionStatus(permission)
        return permission
    }
    
    /// 强制显示权限对话框（已废弃，权限弹窗统一由OneClipApp管理）
    func forceShowPermissionDialog() {
        print("[AccessibilityPermissionManager] 强制权限检查（不弹窗，统一由OneClipApp管理）")
        
        // 只检查权限状态，不显示弹窗
        let hasPermission = AXIsProcessTrusted()
        updatePermissionStatus(hasPermission)
        
        print("[AccessibilityPermissionManager] 权限检查结果: \(hasPermission)")
        
        // 如果需要弹窗，通知OneClipApp处理
        if !hasPermission {
            print("[AccessibilityPermissionManager] 缺少权限，建议通过OneClipApp统一处理弹窗")
        }
    }
    
    // MARK: - Private Methods
    
    private func updatePermissionStatus(_ newStatus: Bool) {
        let oldStatus = hasPermission
        hasPermission = newStatus
        permissionCache = newStatus
        lastCheckTime = Date()
        
        // 如果状态发生变化，通知观察者
        if oldStatus != newStatus {
            #if DEBUG
            print("辅助功能权限状态变化: \(oldStatus ? "已授权" : "未授权") → \(newStatus ? "已授权" : "未授权")")
            #endif
            
            notifyObservers()
        }
    }
    
    private func notifyObservers() {
        for observer in observers {
            observer()
        }
    }
    
    // MARK: - Deinit
    
    deinit {
        stopMonitoring()
        clearObservers()
    }
}

// MARK: - Convenience Extensions

extension AccessibilityPermissionManager {
    /// 便捷方法：检查权限并在变化时执行回调
    func checkAndNotify(onChange: @escaping (Bool) -> Void) {
        checkPermissionAsync { hasPermission in
            onChange(hasPermission)
        }
    }
    
    /// 便捷方法：等待权限授权
    func waitForPermission(timeout: TimeInterval = 30.0, completion: @escaping (Bool) -> Void) {
        let startTime = Date()
        
        func checkRecursively() {
            checkPermissionAsync { hasPermission in
                if hasPermission {
                    completion(true)
                } else if Date().timeIntervalSince(startTime) < timeout {
                    // 继续等待
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        checkRecursively()
                    }
                } else {
                    // 超时
                    completion(false)
                }
            }
        }
        
        checkRecursively()
    }
}
