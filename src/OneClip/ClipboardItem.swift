import Foundation
import CryptoKit

enum ClipboardItemType: String, Codable {
    case text = "text"
    case image = "image"
    case file = "file"
    case video = "video"
    case audio = "audio"
    case document = "document"
    case code = "code"
    case archive = "archive"
    case executable = "executable"
}

extension ClipboardItemType {
    var icon: String {
        switch self {
        case .text:
            return "doc.text"
        case .image:
            return "photo"
        case .file:
            return "doc"
        case .video:
            return "video"
        case .audio:
            return "music.note"
        case .document:
            return "doc.text"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .archive:
            return "archivebox"
        case .executable:
            return "app"
        }
    }
    
    var displayName: String {
        switch self {
        case .text:
            return "文本"
        case .image:
            return "图片"
        case .file:
            return "文件"
        case .video:
            return "视频"
        case .audio:
            return "音频"
        case .document:
            return "文档"
        case .code:
            return "代码"
        case .archive:
            return "压缩包"
        case .executable:
            return "应用程序"
        }
    }
}

enum ClipboardTextSanitizer {
    private static let officeVMLRulePattern = #"(?i)(?:[a-z]\\?:\*|\.[a-z][\w-]*)\s*\{\s*behavior\s*:\s*url\([^)]*#default#VML[^)]*\)\s*;?\s*\}"#

    static func clean(_ source: String) -> String {
        let normalizedScalars = source.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.value >= 0x20
        }

        var text = String(String.UnicodeScalarView(normalizedScalars))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Excel/Office HTML may leak legacy VML behavior declarations into RTF plain text.
        // Remove only those declarations and preserve tabs/newlines used by copied table cells.
        text = text.replacingOccurrences(
            of: officeVMLRulePattern,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?m)^[ \t]+$"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ClipboardItemDateCodec {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let content: String
    let type: ClipboardItemType
    let timestamp: Date
    var data: Data?
    var filePath: String? // 新增：文件存储路径
    var isFavorite: Bool // 新增：收藏状态
    var fingerprint: String?
    var lastUsedAt: Date?
    
    init(id: UUID, content: String, type: ClipboardItemType, timestamp: Date, data: Data? = nil, filePath: String? = nil, isFavorite: Bool = false, fingerprint: String? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.content = content
        self.type = type
        self.timestamp = timestamp
        self.data = data
        self.filePath = filePath
        self.isFavorite = isFavorite
        self.fingerprint = fingerprint
        self.lastUsedAt = lastUsedAt
    }

    /// 列表按最近使用时间排序；从未使用过的记录仍按复制时间排序。
    var sortTimestamp: Date { lastUsedAt ?? timestamp }
    
    // 用于 Codable 的自定义编码
    enum CodingKeys: String, CodingKey {
        case id
        case content
        case type
        case timestamp
        case data
        case filePath
        case isFavorite
        case fingerprint
        case lastUsedAt
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        type = try container.decode(ClipboardItemType.self, forKey: .type)
        
        // 处理 Date 的 JSON 序列化
        if let dateString = try? container.decode(String.self, forKey: .timestamp) {
            timestamp = ClipboardItemDateCodec.date(from: dateString) ?? Date()
        } else if let timeInterval = try? container.decode(Double.self, forKey: .timestamp) {
            // 如果是时间戳格式
            timestamp = Date(timeIntervalSince1970: timeInterval)
        } else {
            // 默认使用当前时间
            timestamp = Date()
        }
        
        data = try container.decode(Data?.self, forKey: .data)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)

        if let dateString = try? container.decode(String.self, forKey: .lastUsedAt) {
            lastUsedAt = ClipboardItemDateCodec.date(from: dateString)
        } else if let timeInterval = try? container.decode(Double.self, forKey: .lastUsedAt) {
            lastUsedAt = Date(timeIntervalSince1970: timeInterval)
        } else {
            lastUsedAt = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(type, forKey: .type)
        
        try container.encode(ClipboardItemDateCodec.string(from: timestamp), forKey: .timestamp)
        
        try container.encode(data, forKey: .data)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(fingerprint, forKey: .fingerprint)
        if let lastUsedAt {
            try container.encode(ClipboardItemDateCodec.string(from: lastUsedAt), forKey: .lastUsedAt)
        }
    }
}

enum ClipboardItemFingerprint {
    static let fileReadChunkSize = 1024 * 1024

    static func make(for item: ClipboardItem) -> String {
        if let fingerprint = item.fingerprint, !fingerprint.isEmpty {
            return fingerprint
        }

        if item.type == .text || item.type == .code {
            return make(content: item.content, type: item.type, data: nil)
        }

        if let data = item.data {
            return make(content: item.content, type: item.type, data: data)
        }

        if let filePath = item.filePath, !filePath.isEmpty,
           let fingerprint = make(fileAt: URL(fileURLWithPath: filePath), type: item.type) {
            return fingerprint
        }

        // 文件曾经存在但现在不可读时不能只按描述去重，否则多张名为 “Image”
        // 的历史图片会被错误合并。
        if item.filePath != nil {
            return "\(item.type.rawValue):unavailable:\(item.id.uuidString)"
        }

        return make(content: item.content, type: item.type, data: nil)
    }

    static func make(content: String, type: ClipboardItemType, data: Data?) -> String {
        let payload: Data

        switch type {
        case .text, .code:
            // 富文本和 HTML 可能携带不同格式数据，但用户看到的文本相同时应视为同一项。
            payload = Data(content.utf8)
        case .image, .file, .video, .audio, .document, .archive, .executable:
            // 二进制内容优先，避免仅凭文件名或图片描述误判不同项目。
            payload = data ?? Data(content.utf8)
        }

        return format(SHA256.hash(data: payload), type: type)
    }

    static func make(fileAt url: URL, type: ClipboardItemType) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            var reachedEnd = false
            var readFailed = false

            autoreleasepool {
                do {
                    guard let chunk = try handle.read(upToCount: fileReadChunkSize), !chunk.isEmpty else {
                        reachedEnd = true
                        return
                    }
                    hasher.update(data: chunk)
                } catch {
                    readFailed = true
                }
            }

            if readFailed { return nil }
            if reachedEnd { break }
        }

        return format(hasher.finalize(), type: type)
    }

    private static func format<D: Sequence>(_ digest: D, type: ClipboardItemType) -> String where D.Element == UInt8 {
        let digestString = digest.map { String(format: "%02x", $0) }.joined()
        return "\(type.rawValue):\(digestString)"
    }
}

enum ClipboardHistoryDeduplicator {
    static func deduplicate(_ items: [ClipboardItem]) -> [ClipboardItem] {
        var uniqueItems: [ClipboardItem] = []
        var fingerprintIndexes: [String: Int] = [:]

        for item in items {
            guard let fingerprint = item.fingerprint, !fingerprint.isEmpty else {
                uniqueItems.append(item)
                continue
            }

            if let existingIndex = fingerprintIndexes[fingerprint] {
                if item.isFavorite && !uniqueItems[existingIndex].isFavorite {
                    uniqueItems[existingIndex] = item
                }
            } else {
                fingerprintIndexes[fingerprint] = uniqueItems.count
                uniqueItems.append(item)
            }
        }

        return uniqueItems
    }
}

enum HistoryRetentionPolicy {
    static let defaultDays = 60
    static let selectableDays = [7, 14, 30, 60, 180, 365, 0]

    static func normalizedDays(_ days: Int) -> Int {
        selectableDays.contains(days) ? days : defaultDays
    }

    static func shouldRetain(_ item: ClipboardItem, retentionDays: Int, now: Date = Date()) -> Bool {
        guard !item.isFavorite, retentionDays > 0 else { return true }
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else {
            return true
        }
        return item.timestamp >= cutoffDate
    }
}
