import Foundation
import AppKit
import Combine

class ClipboardStore: ObservableObject {
    struct StorageInfo {
        let itemCount: Int
        let totalSize: Int64
        let cachePath: String
    }

    struct SaveResult {
        let item: ClipboardItem
        let persisted: Bool
    }

    struct ClearResult {
        let favoriteItems: [ClipboardItem]
        let persisted: Bool
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
    
    init(
        getCleanupDays: @escaping () -> Int = { HistoryRetentionPolicy.defaultDays },
        storageDirectory customStorageDirectory: URL? = nil
    ) {
        self.getCleanupDays = getCleanupDays
        
        // 创建专用的存储目录
        if let customStorageDirectory {
            storageDirectory = customStorageDirectory
        } else {
            let documentsURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            storageDirectory = documentsURL.appendingPathComponent("OneClip", isDirectory: true)
        }
        
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
    
    @discardableResult
    func saveItem(_ item: ClipboardItem) -> ClipboardItem {
        saveItemReportingStatus(item).item
    }

    @discardableResult
    func saveItemReportingStatus(_ item: ClipboardItem) -> SaveResult {
        storeLock.lock()
        defer { storeLock.unlock() }

        // UUID 在项目生命周期内不变，timestamp 也不会因排序更新。
        // 因此新增和更新只需读写所属日期的索引，过期清理由定时任务处理。
        let processedItem = processPersistentStorage(for: item)
        do {
            var dateItems = try loadDateItemsUnsafe(for: item.timestamp)
            dateItems.removeAll { $0.id == item.id }
            dateItems.insert(processedItem, at: 0)
            try writeDateItemsUnsafe(dateItems, for: item.timestamp)
            return SaveResult(item: processedItem, persisted: true)
        } catch {
            Logger.shared.error("保存项目索引失败: \(error.localizedDescription)")
            return SaveResult(item: processedItem, persisted: false)
        }
    }
    
    func loadItems() -> [ClipboardItem] {
        storeLock.lock()
        defer { storeLock.unlock() }
        return loadItemsUnsafe()
    }

    /// Imports an already verified remote record without loading image payloads into memory.
    /// The payload is copied into the existing date-based storage layout before the JSON
    /// index is updated, so a partially downloaded item can never become visible.
    @discardableResult
    func importSyncedItem(
        _ item: ClipboardItem,
        payloadURL: URL?,
        payloadKind: SyncPayloadKind?
    ) throws -> ClipboardItem {
        storeLock.lock()
        defer { storeLock.unlock() }

        var importedItem = item
        if let payloadURL, let payloadKind {
            let dateDirectory = ensureDateDirectoryExists(for: item.timestamp)
            let extensionName = payloadKind == .image ? "png" : "richtext"
            let destinationURL = dateDirectory
                .appendingPathComponent(item.id.uuidString)
                .appendingPathExtension(extensionName)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: payloadURL, to: destinationURL)
            importedItem.filePath = destinationURL.path
            importedItem.data = nil
        } else if let existingItem = try loadDateItemsUnsafe(for: item.timestamp)
            .first(where: { $0.id == item.id }) {
            importedItem.filePath = existingItem.filePath
            importedItem.data = nil
        }

        var dateItems = try loadDateItemsUnsafe(for: importedItem.timestamp)
        dateItems.removeAll { $0.id == importedItem.id }
        dateItems.insert(importedItem, at: 0)
        try writeDateItemsUnsafe(dateItems, for: importedItem.timestamp)
        return importedItem
    }

    /// Applies a verified remote batch under one store lock. All payloads and JSON
    /// indexes are prepared before any index is published; index files are restored
    /// if a later date write fails, keeping a failed batch out of visible history.
    func applyRemoteSyncBatch(
        imports: [(item: ClipboardItem, payloadURL: URL?, payloadKind: SyncPayloadKind?)],
        deleting deletedItems: [ClipboardItem],
        currentItems: [ClipboardItem]
    ) throws -> [ClipboardItem] {
        storeLock.lock()
        defer { storeLock.unlock() }

        let transactionURL = storageDirectory
            .appendingPathComponent(".webdav-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: transactionURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: transactionURL) }

        let importedIDs = Set(imports.map { $0.item.id })
        let deletedIDs = Set(deletedItems.map(\.id))
        let existingByID = Dictionary(
            currentItems.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var affectedDates = Set(imports.map { dateFormatter.string(from: $0.item.timestamp) })
        affectedDates.formUnion(deletedItems.map { dateFormatter.string(from: $0.timestamp) })
        affectedDates.formUnion(currentItems.compactMap { item in
            importedIDs.contains(item.id) ? dateFormatter.string(from: item.timestamp) : nil
        })

        struct OriginalIndex {
            let data: Data?
        }
        var originalIndexes: [String: OriginalIndex] = [:]
        var updatedIndexes: [String: [ClipboardItem]] = [:]
        for dateString in affectedDates {
            let indexURL = storageDirectory
                .appendingPathComponent(dateString, isDirectory: true)
                .appendingPathComponent("items.json")
            let originalData = try? Data(contentsOf: indexURL)
            originalIndexes[dateString] = OriginalIndex(data: originalData)
            let items: [ClipboardItem]
            if let originalData {
                items = try JSONDecoder().decode([ClipboardItem].self, from: originalData)
            } else {
                items = []
            }
            updatedIndexes[dateString] = items.filter {
                !deletedIDs.contains($0.id) && !importedIDs.contains($0.id)
            }
        }

        struct PayloadReplacement {
            let destination: URL
            let backup: URL?
            let wasCreated: Bool
        }
        var payloadReplacements: [PayloadReplacement] = []
        var processedImports: [ClipboardItem] = []

        do {
            for (offset, importValue) in imports.enumerated() {
                var importedItem = importValue.item
                importedItem.data = nil

                if let payloadURL = importValue.payloadURL,
                   let payloadKind = importValue.payloadKind {
                    let dateDirectory = ensureDateDirectoryExists(for: importedItem.timestamp)
                    let extensionName = payloadKind == .image ? "png" : "richtext"
                    let destinationURL = dateDirectory
                        .appendingPathComponent(importedItem.id.uuidString)
                        .appendingPathExtension(extensionName)
                    let stagedURL = transactionURL
                        .appendingPathComponent("payload-\(offset)")
                        .appendingPathExtension(extensionName)
                    try fileManager.copyItem(at: payloadURL, to: stagedURL)

                    var backupURL: URL?
                    let destinationExisted = fileManager.fileExists(atPath: destinationURL.path)
                    if destinationExisted {
                        let candidateBackup = transactionURL
                            .appendingPathComponent("payload-backup-\(offset)")
                            .appendingPathExtension(extensionName)
                        try fileManager.copyItem(at: destinationURL, to: candidateBackup)
                        backupURL = candidateBackup
                        try fileManager.removeItem(at: destinationURL)
                    }
                    do {
                        try fileManager.moveItem(at: stagedURL, to: destinationURL)
                    } catch {
                        if let backupURL {
                            try? fileManager.copyItem(at: backupURL, to: destinationURL)
                        }
                        throw error
                    }
                    payloadReplacements.append(
                        PayloadReplacement(
                            destination: destinationURL,
                            backup: backupURL,
                            wasCreated: !destinationExisted
                        )
                    )
                    importedItem.filePath = destinationURL.path
                } else if let existingPath = existingByID[importedItem.id]?.filePath,
                          fileManager.fileExists(atPath: existingPath) {
                    importedItem.filePath = existingPath
                }

                let dateString = dateFormatter.string(from: importedItem.timestamp)
                updatedIndexes[dateString, default: []].insert(importedItem, at: 0)
                processedImports.append(importedItem)
            }

            // Encode every date first so encoding failure cannot partially publish a batch.
            var encodedIndexes: [String: Data] = [:]
            for (dateString, items) in updatedIndexes {
                encodedIndexes[dateString] = try JSONEncoder().encode(items)
            }
            for (dateString, data) in encodedIndexes {
                let directory = storageDirectory.appendingPathComponent(dateString, isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("items.json"), options: .atomic)
            }
        } catch {
            for (dateString, originalIndex) in originalIndexes {
                let indexURL = storageDirectory
                    .appendingPathComponent(dateString, isDirectory: true)
                    .appendingPathComponent("items.json")
                if let originalData = originalIndex.data {
                    try? fileManager.createDirectory(
                        at: indexURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? originalData.write(to: indexURL, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: indexURL)
                }
            }
            for replacement in payloadReplacements.reversed() {
                if replacement.wasCreated {
                    try? fileManager.removeItem(at: replacement.destination)
                } else if let backup = replacement.backup {
                    try? fileManager.removeItem(at: replacement.destination)
                    try? fileManager.copyItem(at: backup, to: replacement.destination)
                }
            }
            throw error
        }

        let retainedPaths = Set(
            currentItems
                .filter { !deletedIDs.contains($0.id) && !importedIDs.contains($0.id) }
                .compactMap(\.filePath)
                + processedImports.compactMap(\.filePath)
        )
        for deletedItem in deletedItems {
            guard let filePath = deletedItem.filePath, !retainedPaths.contains(filePath) else { continue }
            try? fileManager.removeItem(atPath: filePath)
        }
        return processedImports
    }

    /// 一次性持久化文本清洗结果，不触碰仍被历史项目引用的富文本或图片文件。
    func persistSanitizedHistory(_ items: [ClipboardItem]) {
        storeLock.lock()
        defer { storeLock.unlock() }
        replaceItemRecordsUnsafe(items)
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
            
            // 最近使用的项目优先；未使用过的项目按复制时间排序。
            allItems.sort { $0.sortTimestamp > $1.sortTimestamp }
            
            let retentionDays = getCleanupDays()
            allItems.removeAll {
                !HistoryRetentionPolicy.shouldRetain($0, retentionDays: retentionDays)
            }
            
        } catch {
            Logger.shared.error("加载剪贴板项目失败: \(error.localizedDescription)")
        }
        
        return allItems
    }
    
    @discardableResult
    func clearAllItems(preserving additionalFavorites: [ClipboardItem] = []) -> [ClipboardItem] {
        clearAllItemsReportingStatus(preserving: additionalFavorites).favoriteItems
    }

    @discardableResult
    func clearAllItemsReportingStatus(
        preserving additionalFavorites: [ClipboardItem] = []
    ) -> ClearResult {
        storeLock.lock()
        defer { storeLock.unlock() }
        
        let allItems = loadItemsUnsafe()
        var favoritesByID = Dictionary(
            uniqueKeysWithValues: allItems.filter { $0.isFavorite }.map { ($0.id, $0) }
        )
        for var favorite in additionalFavorites {
            favorite.isFavorite = true
            favoritesByID[favorite.id] = favorite
        }
        let favoriteItems = favoritesByID.values
            .map { processPersistentStorage(for: $0) }
            .sorted { $0.sortTimestamp > $1.sortTimestamp }

        // 收藏图片通常只保留 filePath。不能先删除日期目录再保存，否则收藏会指向
        // 已删除文件。先替换 JSON 索引，再只删除未被收藏引用的二进制文件。
        let persisted = replaceItemRecordsUnsafe(favoriteItems)
        if persisted {
            removeUnreferencedBinaryFilesUnsafe(retaining: favoriteItems)
        }

        Logger.shared.info("所有剪贴板项目已清空，保留了 \(favoriteItems.count) 个收藏项目")
        return ClearResult(favoriteItems: favoriteItems, persisted: persisted)
    }
    
    @discardableResult
    func deleteItem(_ item: ClipboardItem) -> Bool {
        storeLock.lock()
        defer { storeLock.unlock() }

        do {
            var dateItems = try loadDateItemsUnsafe(for: item.timestamp)
            dateItems.removeAll { $0.id == item.id }
            try writeDateItemsUnsafe(dateItems, for: item.timestamp)
            Logger.shared.info("项目已删除: \(item.id)")
            return true
        } catch {
            Logger.shared.error("删除项目索引失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 记录一次成功的使用，并持久化最近使用排序。使用 max 合并时间，避免异步写入乱序。
    @discardableResult
    func markItemUsed(_ item: ClipboardItem, at usedAt: Date) -> ClipboardItem {
        storeLock.lock()
        defer { storeLock.unlock() }

        do {
            var dateItems = try loadDateItemsUnsafe(for: item.timestamp)
            let persistedItem = dateItems.first { $0.id == item.id }
            dateItems.removeAll { $0.id == item.id }

            var updatedItem = item
            updatedItem.lastUsedAt = [persistedItem?.lastUsedAt, item.lastUsedAt, usedAt]
                .compactMap { $0 }
                .max() ?? usedAt

            let processedItem = processPersistentStorage(for: updatedItem)
            dateItems.append(processedItem)
            try writeDateItemsUnsafe(dateItems, for: item.timestamp)
            return processedItem
        } catch {
            Logger.shared.error("更新最近使用时间失败: \(error.localizedDescription)")
            var fallbackItem = item
            fallbackItem.lastUsedAt = [item.lastUsedAt, usedAt].compactMap { $0 }.max() ?? usedAt
            return fallbackItem
        }
    }

    /// 为旧历史补齐持久化指纹，并在一次写入中移除重复记录。
    /// 只替换 items.json，不删除图片等二进制文件，避免迁移时破坏 filePath。
    func applyFingerprintMigration(_ fingerprints: [UUID: String]) {
        guard !fingerprints.isEmpty else { return }

        storeLock.lock()
        defer { storeLock.unlock() }

        var items = loadItemsUnsafe()
        for index in items.indices {
            if let fingerprint = fingerprints[items[index].id] {
                items[index].fingerprint = fingerprint
            }
        }

        let uniqueItems = ClipboardHistoryDeduplicator.deduplicate(items)
        replaceItemRecordsUnsafe(uniqueItems)
        Logger.shared.info("历史指纹迁移完成：\(items.count) 项，去重后 \(uniqueItems.count) 项")
    }
    
    // MARK: - 私有辅助方法
    
    private func saveItems(_ items: [ClipboardItem]) {
        storeLock.lock()
        defer { storeLock.unlock() }
        saveItemsUnsafe(items)
    }
    
    @discardableResult
    private func saveItemsUnsafe(_ items: [ClipboardItem]) -> Bool {
        // 按日期分组保存项目
        let groupedItems = Dictionary(grouping: items) { item in
            dateFormatter.string(from: item.timestamp)
        }
        var succeeded = true
        for (dateString, dateItems) in groupedItems {
            do {
                try writeDateItemsUnsafe(dateItems, dateString: dateString)
            } catch {
                succeeded = false
                Logger.shared.error("保存日期项目失败 \(dateString): \(error.localizedDescription)")
            }
        }
        return succeeded
    }

    private func loadDateItemsUnsafe(for date: Date) throws -> [ClipboardItem] {
        let itemsFile = getStorageDirectory(for: date).appendingPathComponent("items.json")
        guard fileManager.fileExists(atPath: itemsFile.path) else { return [] }
        let data = try Data(contentsOf: itemsFile)
        return try JSONDecoder().decode([ClipboardItem].self, from: data)
    }

    private func writeDateItemsUnsafe(_ items: [ClipboardItem], for date: Date) throws {
        try writeDateItemsUnsafe(items, dateString: dateFormatter.string(from: date))
    }

    private func writeDateItemsUnsafe(_ items: [ClipboardItem], dateString: String) throws {
        let dateDirectory = storageDirectory.appendingPathComponent(dateString, isDirectory: true)
        try fileManager.createDirectory(
            at: dateDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let itemsFile = dateDirectory.appendingPathComponent("items.json")
        let data = try JSONEncoder().encode(items)
        try data.write(to: itemsFile, options: .atomic)
    }

    @discardableResult
    private func replaceItemRecordsUnsafe(_ items: [ClipboardItem]) -> Bool {
        let retainedDateDirectories = Set(items.map { dateFormatter.string(from: $0.timestamp) })

        // 先覆盖仍然存在的日期记录，避免迁移中途失败时先删掉可恢复的索引。
        var succeeded = saveItemsUnsafe(items)
        guard succeeded else { return false }

        do {
            let dateDirectories = try fileManager.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )

            for dateDirectory in dateDirectories {
                let values = try? dateDirectory.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                guard !retainedDateDirectories.contains(dateDirectory.lastPathComponent) else { continue }

                let itemsFile = dateDirectory.appendingPathComponent("items.json")
                if fileManager.fileExists(atPath: itemsFile.path) {
                    try fileManager.removeItem(at: itemsFile)
                }
            }
        } catch {
            succeeded = false
            Logger.shared.error("清理空日期的历史索引失败: \(error.localizedDescription)")
        }
        return succeeded
    }

    private func removeUnreferencedBinaryFilesUnsafe(retaining items: [ClipboardItem]) {
        let retainedPaths = Set(items.compactMap { item in
            item.filePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        })

        do {
            let dateDirectories = try fileManager.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )

            for dateDirectory in dateDirectories {
                let values = try? dateDirectory.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }

                let files = try fileManager.contentsOfDirectory(
                    at: dateDirectory,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                )
                for file in files where file.lastPathComponent != "items.json" {
                    if !retainedPaths.contains(file.standardizedFileURL.path) {
                        try fileManager.removeItem(at: file)
                    }
                }
            }
        } catch {
            Logger.shared.error("清理未引用的历史文件失败: \(error.localizedDescription)")
        }
    }
    
    private func processPersistentStorage(for item: ClipboardItem) -> ClipboardItem {
        var processedItem = item
        
        // 为图片和文件类型处理持久化存储
        switch item.type {
        case .text:
            if let formattedTextData = item.data, !formattedTextData.isEmpty {
                let dateDirectory = ensureDateDirectoryExists(for: item.timestamp)
                let payloadURL = dateDirectory
                    .appendingPathComponent(item.id.uuidString)
                    .appendingPathExtension("richtext")

                do {
                    try formattedTextData.write(to: payloadURL, options: .atomic)
                    processedItem.filePath = payloadURL.path
                    // 富文本仅在默认粘贴或复制时按需加载，不长期占用历史列表内存。
                    processedItem.data = nil
                } catch {
                    Logger.shared.warning("保存富文本格式数据失败，将保留内存数据: \(error.localizedDescription)")
                }
            }

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
