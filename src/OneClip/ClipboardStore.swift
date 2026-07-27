import Foundation
import AppKit
import Combine

class ClipboardStore: ObservableObject {
    struct StorageInfo {
        let itemCount: Int
        let totalSize: Int64
        let cachePath: String
    }
    
    private let fileManager = FileManager.default
    // 文件存储配置
    private let storageDirectory: URL
    
    // 线程安全：添加递归锁保护并发操作
    private let storeLock = NSRecursiveLock()
    
    // 获取清理天数的闭包
    private var getCleanupDays: () -> Int
    
    // 日期格式化器
    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    init(getCleanupDays: @escaping () -> Int = { HistoryRetentionPolicy.defaultDays }) {
        self.getCleanupDays = getCleanupDays
        
        // 创建专用的存储目录
        let documentsURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDirectory = documentsURL.appendingPathComponent("OneClip", isDirectory: true)
        
        // 创建存储目录
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true, attributes: nil)
        
        schedulePeriodicCleanup()
    }
    
    // MARK: - 日期分类存储方法
    
    /// 获取今天的存储文件夹
    private func getTodayStorageDirectory() -> URL {
        let today = dateFormatter.string(from: Date())
        return storageDirectory.appendingPathComponent(today, isDirectory: true)
    }
    
    /// 获取指定日期的存储文件夹
    private func getStorageDirectory(for date: Date) -> URL {
        let dateString = dateFormatter.string(from: date)
        return storageDirectory.appendingPathComponent(dateString, isDirectory: true)
    }
    
    /// 确保日期文件夹存在
    private func ensureDateDirectoryExists(for date: Date) -> URL {
        let dateDirectory = getStorageDirectory(for: date)
        try? fileManager.createDirectory(at: dateDirectory, withIntermediateDirectories: true, attributes: nil)
        return dateDirectory
    }
    
    // MARK: - 核心存储方法
    
    func saveItem(_ item: ClipboardItem) {
        storeLock.lock()
        defer { storeLock.unlock() }

        cleanupOldFilesUnsafe()
        
        var items = loadItemsUnsafe()
        
        // 移除重复项
        items.removeAll { $0.id == item.id }
        
        // 处理所有数据的持久化存储（统一存储到日期文件夹）
        let processedItem = processPersistentStorage(for: item)
        
        // 添加到列表开头
        items.insert(processedItem, at: 0)
        
        // 保存到存储
        saveItemsUnsafe(items)
    }
    
    func loadItems() -> [ClipboardItem] {
        storeLock.lock()
        defer { storeLock.unlock() }
        return loadItemsUnsafe()
    }
    
    private func loadItemsUnsafe() -> [ClipboardItem] {
        var allItems: [ClipboardItem] = []
        
        do {
            // 获取所有日期文件夹
            let dateDirectories = try fileManager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            
            // 按日期排序（最新的在前）
            let sortedDirectories = dateDirectories.sorted { dir1, dir2 in
                guard let date1 = try? dir1.resourceValues(forKeys: [.creationDateKey]).creationDate,
                      let date2 = try? dir2.resourceValues(forKeys: [.creationDateKey]).creationDate else {
                    return false
                }
                return date1 > date2
            }
            
            // 从每个日期文件夹加载项目
            for dateDirectory in sortedDirectories {
                let itemsFile = dateDirectory.appendingPathComponent("items.json")
                if fileManager.fileExists(atPath: itemsFile.path) {
                    let data = try Data(contentsOf: itemsFile)
                    let items = try JSONDecoder().decode([ClipboardItem].self, from: data)
                    allItems.append(contentsOf: items)
                }
            }
            
            // 按时间戳排序（最新的在前）
            allItems.sort { $0.timestamp > $1.timestamp }
            
            let retentionDays = getCleanupDays()
            allItems.removeAll {
                !HistoryRetentionPolicy.shouldRetain($0, retentionDays: retentionDays)
            }
            
        } catch {
            Logger.shared.error("加载剪贴板项目失败: \(error.localizedDescription)")
        }
        
        return allItems
    }
    
    func clearAllItems() {
        storeLock.lock()
        defer { storeLock.unlock() }
        
        do {
            // 1. 先获取所有收藏项目
            let allItems = loadItemsUnsafe()
            let favoriteItems = allItems.filter { $0.isFavorite }
            
            // 2. 删除所有日期文件夹
            let dateDirectories = try fileManager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            
            for dateDirectory in dateDirectories {
                try fileManager.removeItem(at: dateDirectory)
            }
            
            // 3. 重新保存收藏项目
            for favoriteItem in favoriteItems {
                let processedItem = processPersistentStorage(for: favoriteItem)
                let items = [processedItem]
                saveItemsUnsafe(items)
            }
            
            Logger.shared.info("所有剪贴板项目已清空，保留了 \(favoriteItems.count) 个收藏项目")
        } catch {
            Logger.shared.error("清空剪贴板项目失败: \(error.localizedDescription)")
        }
    }
    
    func deleteItem(_ item: ClipboardItem) {
        storeLock.lock()
        defer { storeLock.unlock() }
        
        var allItems = loadItemsUnsafe()
        allItems.removeAll { $0.id == item.id }
        
        // 直接保存更新后的项目列表，不调用 clearAllItems()
        saveItemsUnsafe(allItems)
        Logger.shared.info("项目已删除: \(item.id)")
    }
    
    // MARK: - 私有辅助方法
    
    private func saveItems(_ items: [ClipboardItem]) {
        storeLock.lock()
        defer { storeLock.unlock() }
        saveItemsUnsafe(items)
    }
    
    private func saveItemsUnsafe(_ items: [ClipboardItem]) {
        // 按日期分组保存项目
        let groupedItems = Dictionary(grouping: items) { item in
            dateFormatter.string(from: item.timestamp)
        }
        
        for (dateString, dateItems) in groupedItems {
            let dateDirectory = storageDirectory.appendingPathComponent(dateString, isDirectory: true)
            
            do {
                // 确保日期目录存在
                try fileManager.createDirectory(at: dateDirectory, withIntermediateDirectories: true, attributes: nil)
                
                // 保存项目到JSON文件
                let itemsFile = dateDirectory.appendingPathComponent("items.json")
                let data = try JSONEncoder().encode(dateItems)
                try data.write(to: itemsFile)
                
            } catch {
                Logger.shared.error("保存日期项目失败 \(dateString): \(error.localizedDescription)")
            }
        }
    }
    
    private func processPersistentStorage(for item: ClipboardItem) -> ClipboardItem {
        var processedItem = item
        
        // 为图片和文件类型处理持久化存储
        switch item.type {
        case .image:
            if let imageData = item.data {
                let dateDirectory = ensureDateDirectoryExists(for: item.timestamp)
                let imageFileName = "\(item.id.uuidString).png"
                let imageURL = dateDirectory.appendingPathComponent(imageFileName)
                
                do {
                    try imageData.write(to: imageURL)
                    processedItem.filePath = imageURL.path
                    // 清除内存中的数据，使用文件路径
                    processedItem.data = nil
                } catch {
                    print("保存图片文件失败: \(error)")
                }
            }
            
        case .file:
            if let fileData = item.data {
                let dateDirectory = ensureDateDirectoryExists(for: item.timestamp)
                let fileName = item.content.components(separatedBy: "/").last ?? "unknown_file"
                let fileURL = dateDirectory.appendingPathComponent(fileName)
                
                do {
                    try fileData.write(to: fileURL)
                    processedItem.filePath = fileURL.path
                    // 清除内存中的数据，使用文件路径
                    processedItem.data = nil
                } catch {
                    print("保存文件失败: \(error)")
                }
            }
            
        default:
            // 文本类型不需要额外处理
            break
        }
        
        return processedItem
    }
    
    // MARK: - 存储信息和清理方法
    
    func getStorageInfo() -> StorageInfo {
        var totalSize: Int64 = 0
        var itemCount = 0
        
        // 确保存储目录存在
        if !fileManager.fileExists(atPath: storageDirectory.path) {
            try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true, attributes: nil)
        }
        
        do {
            let dateDirectories = try fileManager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: .skipsHiddenFiles)
            
            for dateDirectory in dateDirectories {
                // 检查是否是目录
                let resourceValues = try? dateDirectory.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues?.isDirectory == true {
                    let files = try fileManager.contentsOfDirectory(at: dateDirectory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
                    
                    for file in files {
                        if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                            totalSize += Int64(fileSize)
                        }
                        
                        if file.pathExtension == "json" {
                            // 计算JSON文件中的项目数量
                            if let data = try? Data(contentsOf: file),
                               let items = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
                                itemCount += items.count
                            }
                        }
                    }
                }
            }
        } catch {
            #if DEBUG
            print("获取存储信息失败: \(error)")
            print("存储目录路径: \(storageDirectory.path)")
            #endif
        }
        
        return StorageInfo(itemCount: itemCount, totalSize: totalSize, cachePath: storageDirectory.path)
    }
    
    func performManualCleanup() {
        // 手动清理：删除所有存储的数据
        do {
            // 删除整个存储目录
            if fileManager.fileExists(atPath: storageDirectory.path) {
                try fileManager.removeItem(at: storageDirectory)
                print("已删除所有存储数据")
            }
            
            // 重新创建空的存储目录
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true, attributes: nil)
            print("已重新创建存储目录")
            
        } catch {
            print("手动清理失败: \(error)")
            // 如果删除失败，尝试清理所有子目录
            cleanupAllFiles()
        }
    }
    
    // 清理所有文件的备用方法
    private func cleanupAllFiles() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for item in contents {
                try fileManager.removeItem(at: item)
                print("已删除: \(item.lastPathComponent)")
            }
        } catch {
            print("清理所有文件失败: \(error)")
        }
    }
    
    func cleanupExpiredItems() {
        storeLock.lock()
        defer { storeLock.unlock() }
        cleanupOldFilesUnsafe()
    }

    private func schedulePeriodicCleanup() {
        // 每小时执行一次清理，但只有在启用自动清理时才执行
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self = self, self.getCleanupDays() > 0 else {
                return // 如果自动清理被禁用，则跳过清理
            }
            self.cleanupExpiredItems()
        }
    }

    private func cleanupOldFilesUnsafe() {
        let retentionDays = getCleanupDays()
        guard retentionDays > 0 else { return }

        let now = Date()

        do {
            let dateDirectories = try fileManager.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )

            for dateDirectory in dateDirectories {
                guard (try? dateDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }

                let itemsFile = dateDirectory.appendingPathComponent("items.json")
                guard let data = try? Data(contentsOf: itemsFile),
                      let items = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
                    if let directoryDate = dateFormatter.date(from: dateDirectory.lastPathComponent),
                       Calendar.current.dateComponents([.day], from: directoryDate, to: now).day ?? 0 >= retentionDays {
                        try fileManager.removeItem(at: dateDirectory)
                    }
                    continue
                }

                let retainedItems = items.filter {
                    HistoryRetentionPolicy.shouldRetain($0, retentionDays: retentionDays, now: now)
                }

                guard retainedItems.count != items.count else { continue }

                if retainedItems.isEmpty {
                    try fileManager.removeItem(at: dateDirectory)
                    print("已清理过期文件夹: \(dateDirectory.lastPathComponent)")
                    continue
                }

                let retainedFilePaths = Set(retainedItems.compactMap(\.filePath))
                let files = try fileManager.contentsOfDirectory(
                    at: dateDirectory,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                )
                for file in files where file != itemsFile && !retainedFilePaths.contains(file.path) {
                    try fileManager.removeItem(at: file)
                }

                let retainedData = try JSONEncoder().encode(retainedItems)
                try retainedData.write(to: itemsFile, options: .atomic)
                print("已清理 \(items.count - retainedItems.count) 条过期历史，保留收藏记录")
            }
        } catch {
            print("清理过期文件失败: \(error)")
        }
    }
    
}
