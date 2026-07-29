import Foundation

enum WebDAVMode: String, Codable, CaseIterable, Identifiable {
    case disabled
    case backup
    case sync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "关闭"
        case .backup: return "加密备份"
        case .sync: return "双向同步"
        }
    }

    var subtitle: String {
        switch self {
        case .disabled: return "数据仅保存在本机"
        case .backup: return "每日保存加密快照，可安全恢复"
        case .sync: return "在多台 PasteLight Mac 之间合并历史"
        }
    }

    var icon: String {
        switch self {
        case .disabled: return "icloud.slash"
        case .backup: return "externaldrive.badge.timemachine"
        case .sync: return "arrow.triangle.2.circlepath.icloud"
        }
    }
}

struct WebDAVConfiguration: Codable, Equatable {
    static let defaultRemotePath = "PasteLight"
    static let defaultImageLimitBytes = 20 * 1024 * 1024

    var serverURL: String
    var remotePath: String
    var username: String
    var mode: WebDAVMode
    var deviceID: UUID
    var deviceName: String
    var imageLimitBytes: Int
    var accountID: UUID?

    init(
        serverURL: String = "",
        remotePath: String = WebDAVConfiguration.defaultRemotePath,
        username: String = "",
        mode: WebDAVMode = .disabled,
        deviceID: UUID = UUID(),
        deviceName: String = Host.current().localizedName ?? "Mac",
        imageLimitBytes: Int = WebDAVConfiguration.defaultImageLimitBytes,
        accountID: UUID? = nil
    ) {
        self.serverURL = serverURL
        self.remotePath = remotePath
        self.username = username
        self.mode = mode
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.imageLimitBytes = imageLimitBytes
        self.accountID = accountID
    }

    var normalizedRemotePath: String {
        let components = remotePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return components.isEmpty ? Self.defaultRemotePath : components.joined(separator: "/")
    }

    var baseURL: URL? {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        return url
    }

    var syncRootURL: URL? {
        guard var url = baseURL else { return nil }
        for component in normalizedRemotePath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: true)
        }
        url.appendPathComponent("v1", isDirectory: true)
        return url
    }
}

enum WebDAVSyncPhase: Equatable {
    case disabled
    case idle
    case testing
    case preparing
    case uploading
    case downloading
    case merging
    case success
    case failed

    var title: String {
        switch self {
        case .disabled: return "未启用"
        case .idle: return "已就绪"
        case .testing: return "正在测试连接"
        case .preparing: return "正在准备"
        case .uploading: return "正在上传"
        case .downloading: return "正在下载"
        case .merging: return "正在合并"
        case .success: return "同步完成"
        case .failed: return "需要处理"
        }
    }

    var isWorking: Bool {
        switch self {
        case .testing, .preparing, .uploading, .downloading, .merging: return true
        default: return false
        }
    }
}

struct WebDAVSyncStatus: Equatable {
    var phase: WebDAVSyncPhase
    var message: String
    var progress: Double
    var lastSuccessAt: Date?
    var skippedItemCount: Int

    static let disabled = WebDAVSyncStatus(
        phase: .disabled,
        message: "WebDAV 同步与备份已关闭",
        progress: 0,
        lastSuccessAt: nil,
        skippedItemCount: 0
    )
}

enum ClipboardSyncMutation {
    case upsert(ClipboardItem)
    case delete(UUID)
    case clear([UUID])
}

extension Notification.Name {
    static let clipboardSyncMutation = Notification.Name("PasteLight.ClipboardSyncMutation")
    static let webDAVConfigurationDidChange = Notification.Name("PasteLight.WebDAVConfigurationDidChange")
}

final class ClipboardSyncMutationEvent: NSObject {
    let mutation: ClipboardSyncMutation

    init(_ mutation: ClipboardSyncMutation) {
        self.mutation = mutation
    }
}

struct SyncRevision: Codable, Hashable, Comparable {
    let counter: UInt64
    let deviceID: UUID

    static func < (lhs: SyncRevision, rhs: SyncRevision) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.deviceID.uuidString < rhs.deviceID.uuidString
    }
}

enum SyncRecordState: String, Codable {
    case upsert
    case tombstone
}

enum SyncPayloadKind: String, Codable, Hashable {
    case image
    case richText
}

struct SyncPayloadReference: Codable, Hashable {
    let remoteID: String
    let kind: SyncPayloadKind
    let byteCount: Int64
    let plaintextDigest: String
}

struct SyncRecord: Codable, Hashable {
    let itemID: UUID
    let revision: SyncRevision
    let state: SyncRecordState
    let type: ClipboardItemType?
    let content: String?
    let timestamp: Date?
    let isFavorite: Bool?
    let fingerprint: String?
    let payload: SyncPayloadReference?

    static func tombstone(itemID: UUID, revision: SyncRevision) -> SyncRecord {
        SyncRecord(
            itemID: itemID,
            revision: revision,
            state: .tombstone,
            type: nil,
            content: nil,
            timestamp: nil,
            isFavorite: nil,
            fingerprint: nil,
            payload: nil
        )
    }

    func clipboardItem(filePath: String? = nil) -> ClipboardItem? {
        guard state == .upsert,
              let type,
              let content,
              let timestamp else {
            return nil
        }
        return ClipboardItem(
            id: itemID,
            content: content,
            type: type,
            timestamp: timestamp,
            data: nil,
            filePath: filePath,
            isFavorite: isFavorite ?? false,
            fingerprint: fingerprint,
            lastUsedAt: nil
        )
    }
}

struct DeviceSyncManifest: Codable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var deviceID: UUID
    var deviceName: String
    var generation: UInt64
    var previousDigest: String?
    var lamportClock: UInt64
    var generatedAt: Date
    var records: [SyncRecord]

    init(deviceID: UUID, deviceName: String) {
        schemaVersion = Self.schemaVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        generation = 0
        previousDigest = nil
        lamportClock = 0
        generatedAt = Date()
        records = []
    }
}

struct WebDAVAccountDescriptor: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let accountID: UUID
    let createdAt: Date
    let kdf: String
    let salt: Data
    let iterations: UInt32
    let keyCheck: Data
}

struct BackupManifest: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let backupID: UUID
    let deviceID: UUID
    let deviceName: String
    let createdAt: Date
    let records: [SyncRecord]
}

struct RemoteBackupInfo: Identifiable, Equatable {
    let id: String
    let url: URL
    let deviceID: UUID
    let createdAt: Date
    let byteCount: Int64
}

struct EncryptedEnvelope: Codable {
    static let formatVersion = 1

    let formatVersion: Int
    let combined: Data
}

struct WebDAVLocalState: Codable {
    var manifest: DeviceSyncManifest
    var manifestETag: String?
    var highestRemoteGenerations: [String: UInt64]
    var remoteManifestDigests: [String: String]
    var lastBackupAt: Date?
    var hasPendingChanges: Bool
    var appliedRevisions: [String: SyncRevision]
    var orphanBlobFirstSeenAt: [String: Date]?
    var lastOrphanScanAt: Date?

    init(configuration: WebDAVConfiguration) {
        manifest = DeviceSyncManifest(deviceID: configuration.deviceID, deviceName: configuration.deviceName)
        manifestETag = nil
        highestRemoteGenerations = [:]
        remoteManifestDigests = [:]
        lastBackupAt = nil
        hasPendingChanges = false
        appliedRevisions = [:]
        orphanBlobFirstSeenAt = [:]
        lastOrphanScanAt = nil
    }

    private enum CodingKeys: String, CodingKey {
        case manifest
        case manifestETag
        case highestRemoteGenerations
        case remoteManifestDigests
        case lastBackupAt
        case hasPendingChanges
        case appliedRevisions
        case orphanBlobFirstSeenAt
        case lastOrphanScanAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try container.decode(DeviceSyncManifest.self, forKey: .manifest)
        manifestETag = try container.decodeIfPresent(String.self, forKey: .manifestETag)
        highestRemoteGenerations = try container.decodeIfPresent(
            [String: UInt64].self,
            forKey: .highestRemoteGenerations
        ) ?? [:]
        remoteManifestDigests = try container.decodeIfPresent(
            [String: String].self,
            forKey: .remoteManifestDigests
        ) ?? [:]
        lastBackupAt = try container.decodeIfPresent(Date.self, forKey: .lastBackupAt)
        hasPendingChanges = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasPendingChanges
        ) ?? false
        appliedRevisions = try container.decodeIfPresent(
            [String: SyncRevision].self,
            forKey: .appliedRevisions
        ) ?? [:]
        orphanBlobFirstSeenAt = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .orphanBlobFirstSeenAt
        ) ?? [:]
        lastOrphanScanAt = try container.decodeIfPresent(Date.self, forKey: .lastOrphanScanAt)
    }
}

struct WebDAVInitialEstimate: Equatable {
    let eligibleItemCount: Int
    let estimatedUploadBytes: Int64
    let skippedItemCount: Int
}

struct WebDAVConnectionTestResult: Equatable {
    let accountExists: Bool
    let message: String
}

struct WebDAVMergeResult: Equatable {
    let recordsByID: [UUID: SyncRecord]
    let visibleRecords: [SyncRecord]
    let deletedItemIDs: Set<UUID>
    let duplicateItemIDs: Set<UUID>
}

enum WebDAVRecordMerger {
    /// Selects the highest Lamport revision for each UUID, then applies PasteLight's
    /// existing fingerprint rule across different UUIDs. Tombstones always remain in
    /// the revision map so an offline device cannot resurrect a manually deleted item.
    static func merge(_ manifests: [DeviceSyncManifest]) -> WebDAVMergeResult {
        var recordsByID: [UUID: SyncRecord] = [:]

        for record in manifests.flatMap(\.records) {
            guard let current = recordsByID[record.itemID] else {
                recordsByID[record.itemID] = record
                continue
            }
            if current.revision < record.revision {
                recordsByID[record.itemID] = record
            }
        }

        let deletedIDs = Set(recordsByID.values.compactMap { record in
            record.state == .tombstone ? record.itemID : nil
        })
        let candidates = recordsByID.values.filter { $0.state == .upsert }
        var winnersByFingerprint: [String: SyncRecord] = [:]
        var visibleWithoutFingerprint: [SyncRecord] = []
        var duplicateIDs = Set<UUID>()

        for record in candidates {
            guard let fingerprint = record.fingerprint, !fingerprint.isEmpty else {
                visibleWithoutFingerprint.append(record)
                continue
            }
            guard let current = winnersByFingerprint[fingerprint] else {
                winnersByFingerprint[fingerprint] = record
                continue
            }

            if prefers(record, over: current) {
                duplicateIDs.insert(current.itemID)
                winnersByFingerprint[fingerprint] = record
            } else {
                duplicateIDs.insert(record.itemID)
            }
        }

        let visible = (Array(winnersByFingerprint.values) + visibleWithoutFingerprint)
            .sorted {
                let lhsDate = $0.timestamp ?? .distantPast
                let rhsDate = $1.timestamp ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.revision > $1.revision
            }

        return WebDAVMergeResult(
            recordsByID: recordsByID,
            visibleRecords: visible,
            deletedItemIDs: deletedIDs,
            duplicateItemIDs: duplicateIDs
        )
    }

    private static func prefers(_ candidate: SyncRecord, over current: SyncRecord) -> Bool {
        let candidateFavorite = candidate.isFavorite ?? false
        let currentFavorite = current.isFavorite ?? false
        if candidateFavorite != currentFavorite { return candidateFavorite }

        let candidateDate = candidate.timestamp ?? .distantPast
        let currentDate = current.timestamp ?? .distantPast
        if candidateDate != currentDate { return candidateDate > currentDate }
        return candidate.revision > current.revision
    }
}

enum WebDAVFeatureError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case invalidRemotePath
    case missingCredentials
    case passphraseTooShort
    case authenticationFailed
    case serverNotWebDAV
    case strongETagRequired
    case unsupportedResponse(Int)
    case remoteConflict
    case encryptionFailed
    case decryptionFailed
    case wrongPassphrase
    case corruptedPayload
    case payloadTooLarge
    case rollbackDetected
    case notConfigured
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 WebDAV 地址"
        case .insecureURL: return "为保护账号口令，仅支持 HTTPS WebDAV 地址"
        case .invalidRemotePath: return "远端目录名称无效"
        case .missingCredentials: return "请输入 WebDAV 用户名和密码"
        case .passphraseTooShort: return "同步密码至少需要 12 个字符"
        case .authenticationFailed: return "WebDAV 认证失败，请检查用户名或密码"
        case .serverNotWebDAV: return "服务器未提供兼容的 WebDAV DAV:1 能力"
        case .strongETagRequired: return "该服务器不支持可靠的强 ETag，无法启用双向同步"
        case let .unsupportedResponse(status): return "WebDAV 返回了不支持的状态码：\(status)"
        case .remoteConflict: return "远端数据已更新，请重新同步"
        case .encryptionFailed: return "数据加密失败"
        case .decryptionFailed: return "数据解密失败"
        case .wrongPassphrase: return "同步密码不正确"
        case .corruptedPayload: return "远端数据不完整或已损坏"
        case .payloadTooLarge: return "内容超过同步大小限制"
        case .rollbackDetected: return "检测到远端清单回滚，已停止同步以保护历史"
        case .notConfigured: return "请先完成 WebDAV 配置"
        case let .serverMessage(message): return message
        }
    }
}
