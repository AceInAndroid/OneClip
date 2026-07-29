import AppKit
import Combine
import CryptoKit
import Foundation
import Network

private struct PreparedSyncImport {
    let item: ClipboardItem
    let payloadURL: URL?
    let payloadKind: SyncPayloadKind?
    let revision: SyncRevision
}

private struct PendingSyncDownload {
    let item: ClipboardItem
    let reference: SyncPayloadReference
    let revision: SyncRevision
}

actor WebDAVSyncCoordinator {
    typealias ClientFactory = (WebDAVConfiguration, WebDAVCredential) throws -> WebDAVClientProtocol
    typealias StatusHandler = (WebDAVSyncStatus) -> Void
    typealias RemoteBatchHandler = ([ClipboardItem], Set<UUID>) async -> Void

    private static let manifestMaximumBytes = 32 * 1024 * 1024
    private static let backupMaximumBytes = 32 * 1024 * 1024
    private static let encryptedPayloadOverhead: Int64 = 2 * 1024 * 1024

    private let store: ClipboardStore
    private let secrets: WebDAVSecretStoring
    private let clientFactory: ClientFactory
    private let remoteBatchHandler: RemoteBatchHandler
    private let stateRootURL: URL
    private var statusHandler: StatusHandler?

    private var configuration: WebDAVConfiguration?
    private var client: WebDAVClientProtocol?
    private var account: WebDAVAccountDescriptor?
    private var masterKey: SymmetricKey?
    private var localState: WebDAVLocalState?
    private var isOperationRunning = false
    private var skippedItemCount = 0

    init(
        store: ClipboardStore,
        secrets: WebDAVSecretStoring = WebDAVSecretStore.shared,
        stateRootURL: URL? = nil,
        clientFactory: @escaping ClientFactory = { configuration, credential in
            try WebDAVHTTPClient(configuration: configuration, credential: credential)
        },
        remoteBatchHandler: @escaping RemoteBatchHandler = { importedItems, deletedIDs in
            await MainActor.run {
                ClipboardManager.shared.applyRemoteSyncBatchToMemory(
                    importedItems: importedItems,
                    deletedIDs: deletedIDs
                )
            }
        }
    ) {
        self.store = store
        self.secrets = secrets
        self.clientFactory = clientFactory
        self.remoteBatchHandler = remoteBatchHandler
        if let stateRootURL {
            self.stateRootURL = stateRootURL
        } else {
            self.stateRootURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("OneClip", isDirectory: true)
            .appendingPathComponent("WebDAV", isDirectory: true)
        }
    }

    func setStatusHandler(_ handler: @escaping StatusHandler) {
        statusHandler = handler
    }

    func testConnection(
        configuration: WebDAVConfiguration,
        password: String,
        passphrase: String
    ) async throws -> WebDAVConnectionTestResult {
        try Self.validate(configuration: configuration, password: password, passphrase: passphrase)
        guard let baseURL = configuration.baseURL,
              let accountURL = configuration.syncRootURL?.appendingPathComponent("account.json") else {
            throw WebDAVFeatureError.invalidURL
        }

        publishStatus(.testing, "正在验证 WebDAV 能力与安全写入…", progress: 0.15)
        let credential = WebDAVCredential(username: configuration.username, password: password)
        let testClient = try clientFactory(configuration, credential)
        try await testClient.testConnection(
            baseURL: baseURL,
            requireStrongETag: configuration.mode == .sync
        )

        if try await testClient.exists(accountURL) {
            let descriptorData = try await testClient.get(accountURL, maximumBytes: 64 * 1024)
            let descriptor = try Self.decodeAccount(descriptorData)
            let key = try PasteLightCrypto.deriveKey(
                passphrase: passphrase,
                salt: descriptor.salt,
                iterations: descriptor.iterations
            )
            guard PasteLightCrypto.keyCheckIsValid(
                descriptor.keyCheck,
                key: key,
                accountID: descriptor.accountID
            ) else {
                throw WebDAVFeatureError.wrongPassphrase
            }
            publishStatus(.success, "连接与同步密码验证成功", progress: 1)
            return WebDAVConnectionTestResult(accountExists: true, message: "连接与同步密码验证成功")
        }

        publishStatus(.success, "连接成功，保存后将创建加密空间", progress: 1)
        return WebDAVConnectionTestResult(
            accountExists: false,
            message: "连接成功，远端尚未初始化；保存后将创建加密空间"
        )
    }

    func activate(
        configuration requestedConfiguration: WebDAVConfiguration,
        password: String,
        passphrase: String,
        initialItems: [ClipboardItem]
    ) async throws -> WebDAVConfiguration {
        try Self.validate(
            configuration: requestedConfiguration,
            password: password,
            passphrase: passphrase
        )
        guard let baseURL = requestedConfiguration.baseURL else {
            throw WebDAVFeatureError.invalidURL
        }

        publishStatus(.preparing, "正在建立端到端加密空间…", progress: 0.05)
        let credential = WebDAVCredential(username: requestedConfiguration.username, password: password)
        let newClient = try clientFactory(requestedConfiguration, credential)
        try await newClient.testConnection(
            baseURL: baseURL,
            requireStrongETag: requestedConfiguration.mode == .sync
        )
        try await ensureRemoteLayout(configuration: requestedConfiguration, client: newClient)

        let descriptor = try await loadOrCreateAccount(
            configuration: requestedConfiguration,
            client: newClient,
            passphrase: passphrase
        )
        let key = try PasteLightCrypto.deriveKey(
            passphrase: passphrase,
            salt: descriptor.salt,
            iterations: descriptor.iterations
        )
        guard PasteLightCrypto.keyCheckIsValid(
            descriptor.keyCheck,
            key: key,
            accountID: descriptor.accountID
        ) else {
            throw WebDAVFeatureError.wrongPassphrase
        }

        var activatedConfiguration = requestedConfiguration
        activatedConfiguration.accountID = descriptor.accountID
        try secrets.saveCredential(credential, for: activatedConfiguration)
        try secrets.saveMasterKey(key, accountID: descriptor.accountID)

        configuration = activatedConfiguration
        client = newClient
        account = descriptor
        masterKey = key
        localState = loadState(for: activatedConfiguration)
        try captureInitialSnapshot(initialItems)
        try saveState()
        publishStatus(.idle, "加密空间已就绪", progress: 1)
        return activatedConfiguration
    }

    func resume(configuration: WebDAVConfiguration) async throws {
        guard configuration.mode != .disabled else { throw WebDAVFeatureError.notConfigured }
        guard let credential = secrets.credential(for: configuration),
              let accountURL = configuration.syncRootURL?.appendingPathComponent("account.json") else {
            throw WebDAVFeatureError.missingCredentials
        }
        let resumedClient = try clientFactory(configuration, credential)
        let descriptorData = try await resumedClient.get(accountURL, maximumBytes: 64 * 1024)
        let descriptor = try Self.decodeAccount(descriptorData)
        guard configuration.accountID == nil || configuration.accountID == descriptor.accountID,
              let key = secrets.masterKey(accountID: descriptor.accountID),
              PasteLightCrypto.keyCheckIsValid(
                descriptor.keyCheck,
                key: key,
                accountID: descriptor.accountID
              ) else {
            throw WebDAVFeatureError.wrongPassphrase
        }

        self.configuration = configuration
        client = resumedClient
        account = descriptor
        masterKey = key
        localState = loadState(for: configuration)
        publishStatus(.idle, "已就绪，等待同步", progress: 0)
    }

    func deactivate() {
        configuration = nil
        client = nil
        account = nil
        masterKey = nil
        localState = nil
        publishStatus(.disabled, "WebDAV 同步与备份已关闭", progress: 0)
    }

    func removeLocalState(for configuration: WebDAVConfiguration) {
        if let url = try? stateURL(for: configuration) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        deactivate()
    }

    @discardableResult
    func record(_ mutation: ClipboardSyncMutation) throws -> Int {
        guard configuration?.mode != .disabled,
              var state = localState else { throw WebDAVFeatureError.notConfigured }

        switch mutation {
        case let .upsert(item):
            if let record = try makeRecord(for: item, state: &state) {
                replaceRecord(record, in: &state.manifest)
                state.hasPendingChanges = true
            } else {
                skippedItemCount += 1
            }
        case let .delete(itemID):
            state.manifest.lamportClock &+= 1
            let revision = SyncRevision(
                counter: state.manifest.lamportClock,
                deviceID: state.manifest.deviceID
            )
            replaceRecord(.tombstone(itemID: itemID, revision: revision), in: &state.manifest)
            state.hasPendingChanges = true
        case let .clear(itemIDs):
            for itemID in Set(itemIDs) {
                state.manifest.lamportClock &+= 1
                let revision = SyncRevision(
                    counter: state.manifest.lamportClock,
                    deviceID: state.manifest.deviceID
                )
                replaceRecord(.tombstone(itemID: itemID, revision: revision), in: &state.manifest)
            }
            state.hasPendingChanges = state.hasPendingChanges || !itemIDs.isEmpty
        }

        localState = state
        try saveState()
        return skippedItemCount
    }

    func synchronize(currentItems: [ClipboardItem]) async throws {
        guard configuration?.mode == .sync else { throw WebDAVFeatureError.notConfigured }
        guard !isOperationRunning else { return }
        isOperationRunning = true
        defer { isOperationRunning = false }

        do {
            publishStatus(.preparing, "正在准备加密清单…", progress: 0.08)
            guard let publishableSnapshot = localState?.manifest else {
                throw WebDAVFeatureError.notConfigured
            }
            try await uploadReferencedBlobs(
                records: publishableSnapshot.records,
                currentItems: currentItems
            )
            publishStatus(.uploading, "正在安全发布本机变更…", progress: 0.3)
            try await publishLocalManifest(publishing: publishableSnapshot)
            publishStatus(.downloading, "正在读取其他 Mac 的加密清单…", progress: 0.5)
            let manifests = try await fetchAllDeviceManifests()
            publishStatus(.merging, "正在安全合并历史…", progress: 0.72)
            try await applyMergedManifests(manifests, currentItems: currentItems)

            if var state = localState {
                let remoteClock = manifests.map(\.lamportClock).max() ?? 0
                state.manifest.lamportClock = max(state.manifest.lamportClock, remoteClock)
                localState = state
                try saveState()
            }
            try? await reclaimOrphanedBlobs(manifests: manifests)
            publishStatus(.success, "所有设备的历史已安全合并", progress: 1, successDate: Date())
        } catch {
            publishFailure(error)
            throw error
        }
    }

    func createBackup(currentItems: [ClipboardItem], automatic: Bool) async throws {
        guard configuration?.mode == .backup else { throw WebDAVFeatureError.notConfigured }
        guard !isOperationRunning else { return }
        if automatic,
           let lastBackupAt = localState?.lastBackupAt,
           Calendar.current.isDateInToday(lastBackupAt) {
            return
        }

        isOperationRunning = true
        defer { isOperationRunning = false }
        do {
            publishStatus(.preparing, "正在准备加密备份…", progress: 0.1)
            let records = try snapshotRecords(from: currentItems)
            try await uploadReferencedBlobs(records: records, currentItems: currentItems)
            publishStatus(.uploading, "正在上传加密快照…", progress: 0.55)
            try await uploadBackup(records: records)
            try await retainLatestBackups(limit: 7)
            if var state = localState {
                state.lastBackupAt = Date()
                localState = state
                try saveState()
            }
            if let manifests = try? await fetchAllDeviceManifests() {
                try? await reclaimOrphanedBlobs(manifests: manifests)
            }
            publishStatus(.success, "加密备份已完成", progress: 1, successDate: Date())
        } catch {
            publishFailure(error)
            throw error
        }
    }

    func listBackups() async throws -> [RemoteBackupInfo] {
        let context = try activeContext()
        let root = context.configuration.syncRootURL!
            .appendingPathComponent("backups", isDirectory: true)
        let resources = try await context.client.list(root, depth: 1)
        let directories = resources.filter { resource in
            resource.isCollection && resource.url.standardized.path != root.standardized.path
        }
        var backups: [RemoteBackupInfo] = []
        for directory in directories {
            guard let deviceID = UUID(uuidString: directory.url.lastPathComponent) else {
                throw WebDAVFeatureError.corruptedPayload
            }
            backups.append(contentsOf: try await listBackups(
                deviceID: deviceID,
                directory: directory.url,
                client: context.client
            ))
        }
        return backups.sorted { $0.createdAt > $1.createdAt }
    }

    private func listBackups(
        deviceID: UUID,
        directory: URL,
        client: WebDAVClientProtocol
    ) async throws -> [RemoteBackupInfo] {
        let resources = try await client.list(directory, depth: 1)
        return resources.compactMap { resource in
            guard !resource.isCollection, resource.url.pathExtension == "plbackup" else { return nil }
            return RemoteBackupInfo(
                id: "\(deviceID.uuidString)|\(resource.url.deletingPathExtension().lastPathComponent)",
                url: resource.url,
                deviceID: deviceID,
                createdAt: resource.lastModified ?? Self.backupDate(from: resource.url.lastPathComponent) ?? .distantPast,
                byteCount: resource.contentLength ?? 0
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func restoreBackup(_ backup: RemoteBackupInfo, currentItems: [ClipboardItem]) async throws {
        guard !isOperationRunning else { return }
        isOperationRunning = true
        defer { isOperationRunning = false }

        do {
            let context = try activeContext()
            publishStatus(.downloading, "正在下载并验证加密备份…", progress: 0.25)
            let encrypted = try await context.client.get(
                backup.url,
                maximumBytes: Self.backupMaximumBytes
            )
            let aad = backupAAD(
                accountID: context.account.accountID,
                deviceID: backup.deviceID,
                fileName: backup.url.lastPathComponent
            )
            let plaintext = try PasteLightCrypto.decrypt(encrypted, using: context.key, aad: aad)
            let backupManifest = try JSONDecoder().decode(BackupManifest.self, from: plaintext)
            guard backupManifest.schemaVersion == BackupManifest.schemaVersion,
                  backupManifest.deviceID == backup.deviceID else {
                throw WebDAVFeatureError.corruptedPayload
            }
            try validate(records: backupManifest.records, context: context)

            var backupDeviceManifest = DeviceSyncManifest(
                deviceID: backupManifest.deviceID,
                deviceName: backupManifest.deviceName
            )
            backupDeviceManifest.records = backupManifest.records
            backupDeviceManifest.lamportClock = backupManifest.records.map(\.revision.counter).max() ?? 0
            var localManifest = DeviceSyncManifest(
                deviceID: context.configuration.deviceID,
                deviceName: context.configuration.deviceName
            )
            localManifest.records = try snapshotRecords(from: currentItems)
            localManifest.lamportClock = localManifest.records.map(\.revision.counter).max() ?? 0
            publishStatus(.merging, "正在与本机历史安全合并…", progress: 0.65)
            try await applyMergedManifests(
                [localManifest, backupDeviceManifest],
                currentItems: currentItems
            )
            publishStatus(.success, "备份已合并，未覆盖本机历史", progress: 1, successDate: Date())
        } catch {
            publishFailure(error)
            throw error
        }
    }

    func currentSkippedItemCount() -> Int { skippedItemCount }

    static func estimate(items: [ClipboardItem], imageLimitBytes: Int) -> WebDAVInitialEstimate {
        var count = 0
        var bytes: Int64 = 0
        var skipped = 0
        for item in items {
            switch item.type {
            case .text, .code:
                if item.type == .text,
                   let filePath = item.filePath,
                   URL(fileURLWithPath: filePath).pathExtension == "richtext",
                   let size = Self.fileSize(URL(fileURLWithPath: filePath)),
                   size > Int64(ClipboardPayloadLimits.maxStoredFormattedTextBytes) {
                    skipped += 1
                    continue
                }
                count += 1
                bytes += Int64(item.content.utf8.count)
                if let filePath = item.filePath,
                   URL(fileURLWithPath: filePath).pathExtension == "richtext",
                   let size = Self.fileSize(URL(fileURLWithPath: filePath)),
                   size <= Int64(ClipboardPayloadLimits.maxStoredFormattedTextBytes) {
                    bytes += size
                }
            case .image:
                guard let filePath = item.filePath,
                      let size = Self.fileSize(URL(fileURLWithPath: filePath)),
                      size <= Int64(imageLimitBytes) else {
                    skipped += 1
                    continue
                }
                count += 1
                bytes += size
            default:
                skipped += 1
            }
        }
        return WebDAVInitialEstimate(
            eligibleItemCount: count,
            estimatedUploadBytes: bytes,
            skippedItemCount: skipped
        )
    }

    // MARK: - Account and layout

    private func loadOrCreateAccount(
        configuration: WebDAVConfiguration,
        client: WebDAVClientProtocol,
        passphrase: String
    ) async throws -> WebDAVAccountDescriptor {
        guard let accountURL = configuration.syncRootURL?.appendingPathComponent("account.json") else {
            throw WebDAVFeatureError.invalidURL
        }
        if try await client.exists(accountURL) {
            let data = try await client.get(accountURL, maximumBytes: 64 * 1024)
            let descriptor = try Self.decodeAccount(data)
            let key = try PasteLightCrypto.deriveKey(
                passphrase: passphrase,
                salt: descriptor.salt,
                iterations: descriptor.iterations
            )
            guard PasteLightCrypto.keyCheckIsValid(
                descriptor.keyCheck,
                key: key,
                accountID: descriptor.accountID
            ) else {
                throw WebDAVFeatureError.wrongPassphrase
            }
            return descriptor
        }

        let accountID = UUID()
        let salt = PasteLightCrypto.randomSalt()
        let iterations = PasteLightCrypto.calibratedIterations(passphrase: passphrase, salt: salt)
        let key = try PasteLightCrypto.deriveKey(
            passphrase: passphrase,
            salt: salt,
            iterations: iterations
        )
        let descriptor = WebDAVAccountDescriptor(
            schemaVersion: WebDAVAccountDescriptor.schemaVersion,
            accountID: accountID,
            createdAt: Date(),
            kdf: "PBKDF2-HMAC-SHA256",
            salt: salt,
            iterations: iterations,
            keyCheck: PasteLightCrypto.keyCheck(for: key, accountID: accountID)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            _ = try await client.put(
                try encoder.encode(descriptor),
                to: accountURL,
                ifMatch: nil,
                ifNoneMatch: true
            )
            return descriptor
        } catch WebDAVFeatureError.remoteConflict {
            let data = try await client.get(accountURL, maximumBytes: 64 * 1024)
            return try Self.decodeAccount(data)
        }
    }

    private static func decodeAccount(_ data: Data) throws -> WebDAVAccountDescriptor {
        let descriptor = try JSONDecoder().decode(WebDAVAccountDescriptor.self, from: data)
        guard descriptor.schemaVersion == WebDAVAccountDescriptor.schemaVersion,
              descriptor.kdf == "PBKDF2-HMAC-SHA256",
              descriptor.salt.count >= 16,
              descriptor.iterations >= PasteLightCrypto.minimumPBKDF2Iterations,
              descriptor.keyCheck.count == 32 else {
            throw WebDAVFeatureError.corruptedPayload
        }
        return descriptor
    }

    private func ensureRemoteLayout(
        configuration: WebDAVConfiguration,
        client: WebDAVClientProtocol
    ) async throws {
        guard let baseURL = configuration.baseURL,
              let rootURL = configuration.syncRootURL else {
            throw WebDAVFeatureError.invalidURL
        }
        try await client.ensureCollection(rootURL, under: baseURL)
        try await client.ensureCollection(rootURL.appendingPathComponent("devices", isDirectory: true), under: baseURL)
        try await client.ensureCollection(rootURL.appendingPathComponent("blobs", isDirectory: true), under: baseURL)
        let backups = rootURL.appendingPathComponent("backups", isDirectory: true)
        try await client.ensureCollection(backups, under: baseURL)
        try await client.ensureCollection(
            backups.appendingPathComponent(configuration.deviceID.uuidString, isDirectory: true),
            under: baseURL
        )
    }

    // MARK: - Local mutation model

    private func captureInitialSnapshot(_ items: [ClipboardItem]) throws {
        guard var state = localState else { return }
        let existing = Dictionary(
            state.manifest.records.map { ($0.itemID, $0) },
            uniquingKeysWith: { current, candidate in
                current.revision < candidate.revision ? candidate : current
            }
        )
        state.manifest.records = existing.values.sorted {
            $0.itemID.uuidString < $1.itemID.uuidString
        }
        for item in items {
            if let current = existing[item.id], current.state == .upsert,
               current.content == item.content,
               current.isFavorite == item.isFavorite,
               current.fingerprint == (item.fingerprint ?? ClipboardItemFingerprint.make(for: item)) {
                continue
            }
            if let record = try makeRecord(for: item, state: &state) {
                replaceRecord(record, in: &state.manifest)
                state.hasPendingChanges = true
            } else {
                skippedItemCount += 1
            }
        }
        localState = state
    }

    private func snapshotRecords(from items: [ClipboardItem]) throws -> [SyncRecord] {
        guard var state = localState else { throw WebDAVFeatureError.notConfigured }
        var records: [SyncRecord] = []
        var snapshotSkipped = 0
        for item in items {
            if let record = try makeRecord(for: item, state: &state) {
                records.append(record)
            } else {
                snapshotSkipped += 1
            }
        }
        skippedItemCount = snapshotSkipped
        localState = state
        try saveState()
        return records
    }

    private func makeRecord(for item: ClipboardItem, state: inout WebDAVLocalState) throws -> SyncRecord? {
        guard let configuration, let key = masterKey else { throw WebDAVFeatureError.notConfigured }
        guard item.type == .text || item.type == .code || item.type == .image else { return nil }

        let fingerprint = item.fingerprint ?? ClipboardItemFingerprint.make(for: item)
        var payload: SyncPayloadReference?
        if item.type == .text,
           let filePath = item.filePath,
           URL(fileURLWithPath: filePath).pathExtension == "richtext",
           let size = Self.fileSize(URL(fileURLWithPath: filePath)),
           size > Int64(ClipboardPayloadLimits.maxStoredFormattedTextBytes) {
            return nil
        }
        if let payloadInfo = try payloadInfo(for: item, configuration: configuration) {
            let remoteID = PasteLightCrypto.remoteObjectID(
                fingerprint: payloadInfo.digest,
                kind: payloadInfo.kind,
                key: key
            )
            payload = SyncPayloadReference(
                remoteID: remoteID,
                kind: payloadInfo.kind,
                byteCount: payloadInfo.byteCount,
                plaintextDigest: payloadInfo.digest
            )
        } else if item.type == .image {
            return nil
        }

        state.manifest.lamportClock &+= 1
        let revision = SyncRevision(
            counter: state.manifest.lamportClock,
            deviceID: state.manifest.deviceID
        )
        return SyncRecord(
            itemID: item.id,
            revision: revision,
            state: .upsert,
            type: item.type,
            content: item.content,
            timestamp: item.timestamp,
            isFavorite: item.isFavorite,
            fingerprint: fingerprint,
            payload: payload
        )
    }

    private func payloadInfo(
        for item: ClipboardItem,
        configuration: WebDAVConfiguration
    ) throws -> (url: URL, kind: SyncPayloadKind, digest: String, byteCount: Int64)? {
        guard let filePath = item.filePath, !filePath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let kind: SyncPayloadKind
        let maximumBytes: Int64
        if item.type == .image {
            kind = .image
            maximumBytes = Int64(configuration.imageLimitBytes)
        } else if item.type == .text, url.pathExtension == "richtext" {
            kind = .richText
            maximumBytes = Int64(ClipboardPayloadLimits.maxStoredFormattedTextBytes)
        } else {
            return nil
        }

        guard let size = Self.fileSize(url), size > 0, size <= maximumBytes else { return nil }
        let info = try PasteLightCrypto.sha256Hex(fileAt: url)
        guard info.byteCount == size else { throw WebDAVFeatureError.corruptedPayload }
        return (url, kind, info.digest, info.byteCount)
    }

    private func replaceRecord(_ record: SyncRecord, in manifest: inout DeviceSyncManifest) {
        if let index = manifest.records.firstIndex(where: { $0.itemID == record.itemID }) {
            if manifest.records[index].revision < record.revision {
                manifest.records[index] = record
            }
        } else {
            manifest.records.append(record)
        }
    }

    // MARK: - Upload

    private func uploadReferencedBlobs(
        records: [SyncRecord],
        currentItems: [ClipboardItem]
    ) async throws {
        let context = try activeContext()
        let itemsByID = Dictionary(
            currentItems.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var seen = Set<String>()
        let payloadRecords = records.filter {
            $0.state == .upsert && $0.payload != nil && seen.insert($0.payload!.remoteID).inserted
        }

        var completed = 0
        var index = 0
        while index < payloadRecords.count {
            let firstRecord = payloadRecords[index]
            async let firstResult = captureBlobUpload(
                record: firstRecord,
                item: itemsByID[firstRecord.itemID],
                context: context
            )

            if index + 1 < payloadRecords.count {
                let secondRecord = payloadRecords[index + 1]
                async let secondResult = captureBlobUpload(
                    record: secondRecord,
                    item: itemsByID[secondRecord.itemID],
                    context: context
                )
                let results = await (firstResult, secondResult)
                try results.0.get()
                try results.1.get()
                completed += 2
                index += 2
            } else {
                try await firstResult.get()
                completed += 1
                index += 1
            }
            let progress = 0.12 + (Double(completed) / Double(payloadRecords.count)) * 0.16
            publishStatus(.uploading, "正在上传加密附件 \(completed)/\(payloadRecords.count)", progress: progress)
        }
    }

    private func captureBlobUpload(
        record: SyncRecord,
        item: ClipboardItem?,
        context: ActiveContext
    ) async -> Result<Void, Error> {
        do {
            try await uploadBlob(record: record, item: item, context: context)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func uploadBlob(
        record: SyncRecord,
        item: ClipboardItem?,
        context: ActiveContext
    ) async throws {
        guard let reference = record.payload else { return }
        let remoteURL = blobURL(reference.remoteID, configuration: context.configuration)
        if try await context.client.exists(remoteURL) { return }
        guard let item else {
            // An automatically expired local item remains in the shared manifest so
            // expiry is not propagated as a tombstone. Its already-uploaded blob is
            // sufficient; a missing remote object is a genuine consistency failure.
            throw WebDAVFeatureError.corruptedPayload
        }
        guard let sourceURL = try payloadInfo(for: item, configuration: context.configuration)?.url else {
            throw WebDAVFeatureError.corruptedPayload
        }

        let encryptedURL = temporaryURL(extension: "plblob")
        defer { try? FileManager.default.removeItem(at: encryptedURL) }
        let header = try PasteLightCrypto.encryptFile(
            sourceURL: sourceURL,
            destinationURL: encryptedURL,
            objectID: reference.remoteID,
            accountID: context.account.accountID,
            key: context.key
        )
        guard header.plaintextDigest == reference.plaintextDigest,
              header.plaintextByteCount == reference.byteCount else {
            throw WebDAVFeatureError.corruptedPayload
        }
        do {
            _ = try await context.client.putFile(
                encryptedURL,
                to: remoteURL,
                ifMatch: nil,
                ifNoneMatch: true
            )
        } catch WebDAVFeatureError.remoteConflict {
            // Content addressed object already uploaded by another device.
        }
    }

    private func publishLocalManifest(publishing initialSnapshot: DeviceSyncManifest) async throws {
        let context = try activeContext()
        let manifestURL = deviceManifestURL(context.configuration.deviceID, configuration: context.configuration)
        guard let initialState = localState, initialState.hasPendingChanges else { return }

        // Only records whose blobs were checked/uploaded above are eligible for this
        // publication. Mutations arriving across an await stay in localState and are
        // published by the manager's requested rerun, never as dangling references.
        var publishableManifest = initialSnapshot
        var knownETag = initialState.manifestETag
        var knownRemoteDigest = initialState.remoteManifestDigests[initialSnapshot.deviceID.uuidString]
        var knownGeneration = initialState.manifest.generation

        for _ in 0..<3 {
            var candidate = publishableManifest
            candidate.generation = max(candidate.generation, knownGeneration) &+ 1
            candidate.previousDigest = knownRemoteDigest
            candidate.generatedAt = Date()
            let plaintext = try sortedJSONEncoder().encode(candidate)
            let encrypted = try PasteLightCrypto.encrypt(
                plaintext,
                using: context.key,
                aad: manifestAAD(accountID: context.account.accountID, deviceID: candidate.deviceID)
            )
            guard encrypted.count <= Self.manifestMaximumBytes else {
                throw WebDAVFeatureError.payloadTooLarge
            }
            let digest = PasteLightCrypto.sha256Hex(encrypted)

            do {
                let response = try await context.client.put(
                    encrypted,
                    to: manifestURL,
                    ifMatch: knownETag,
                    ifNoneMatch: knownETag == nil
                )
                let etag: String?
                if let responseETag = response.etag {
                    etag = responseETag
                } else {
                    etag = try await context.client.list(manifestURL, depth: 0).first?.etag
                }
                guard let etag, WebDAVHTTPClient.isStrongETag(etag) else {
                    throw WebDAVFeatureError.strongETagRequired
                }
                guard var current = localState else { throw WebDAVFeatureError.notConfigured }
                let changedDuringUpload = current.manifest.records != candidate.records
                    || current.manifest.lamportClock != candidate.lamportClock
                current.manifest.generation = candidate.generation
                current.manifest.previousDigest = candidate.previousDigest
                current.manifest.generatedAt = candidate.generatedAt
                current.manifestETag = etag
                current.highestRemoteGenerations[candidate.deviceID.uuidString] = candidate.generation
                current.remoteManifestDigests[candidate.deviceID.uuidString] = digest
                current.hasPendingChanges = changedDuringUpload
                localState = current
                try saveState()
                return
            } catch WebDAVFeatureError.remoteConflict {
                let remote = try await fetchDeviceManifest(
                    url: manifestURL,
                    expectedDeviceID: context.configuration.deviceID,
                    etag: nil,
                    enforceRollback: false
                )
                for record in remote.manifest.records {
                    replaceRecord(record, in: &publishableManifest)
                }
                publishableManifest.lamportClock = max(
                    publishableManifest.lamportClock,
                    remote.manifest.lamportClock
                )
                knownGeneration = max(knownGeneration, remote.manifest.generation)
                knownETag = remote.etag
                knownRemoteDigest = remote.digest

                guard var state = localState else { throw WebDAVFeatureError.notConfigured }
                for record in remote.manifest.records {
                    replaceRecord(record, in: &state.manifest)
                }
                state.manifest.generation = max(state.manifest.generation, remote.manifest.generation)
                state.manifest.lamportClock = max(state.manifest.lamportClock, remote.manifest.lamportClock)
                state.manifestETag = remote.etag
                state.highestRemoteGenerations[remote.manifest.deviceID.uuidString] = remote.manifest.generation
                state.remoteManifestDigests[remote.manifest.deviceID.uuidString] = remote.digest
                state.hasPendingChanges = true
                localState = state
            }
        }
        throw WebDAVFeatureError.remoteConflict
    }

    // MARK: - Download and merge

    private struct FetchedManifest {
        let manifest: DeviceSyncManifest
        let etag: String?
        let digest: String
    }

    private func fetchAllDeviceManifests() async throws -> [DeviceSyncManifest] {
        let context = try activeContext()
        let devicesURL = context.configuration.syncRootURL!
            .appendingPathComponent("devices", isDirectory: true)
        let resources = try await context.client.list(devicesURL, depth: 1)
        var manifests: [DeviceSyncManifest] = []

        for resource in resources where !resource.isCollection && resource.url.lastPathComponent.hasSuffix(".manifest.plenc") {
            let fileName = resource.url.lastPathComponent
            let idText = String(fileName.dropLast(".manifest.plenc".count))
            guard let deviceID = UUID(uuidString: idText) else { continue }
            let fetched = try await fetchDeviceManifest(
                url: resource.url,
                expectedDeviceID: deviceID,
                etag: resource.etag,
                enforceRollback: true
            )
            manifests.append(fetched.manifest)
            if deviceID == context.configuration.deviceID, var state = localState {
                state.manifestETag = fetched.etag
                localState = state
            }
        }
        if !manifests.contains(where: { $0.deviceID == context.configuration.deviceID }),
           let ownManifest = localState?.manifest {
            manifests.append(ownManifest)
        }
        try saveState()
        return manifests
    }

    private func fetchDeviceManifest(
        url: URL,
        expectedDeviceID: UUID,
        etag suppliedETag: String?,
        enforceRollback: Bool
    ) async throws -> FetchedManifest {
        let context = try activeContext()
        let encrypted = try await context.client.get(url, maximumBytes: Self.manifestMaximumBytes)
        let plaintext = try PasteLightCrypto.decrypt(
            encrypted,
            using: context.key,
            aad: manifestAAD(accountID: context.account.accountID, deviceID: expectedDeviceID)
        )
        let manifest = try JSONDecoder().decode(DeviceSyncManifest.self, from: plaintext)
        guard manifest.schemaVersion == DeviceSyncManifest.schemaVersion,
              manifest.deviceID == expectedDeviceID else {
            throw WebDAVFeatureError.corruptedPayload
        }
        try validate(records: manifest.records, context: context)
        let digest = PasteLightCrypto.sha256Hex(encrypted)
        let etag: String?
        if let suppliedETag {
            etag = suppliedETag
        } else {
            etag = try await context.client.list(url, depth: 0).first?.etag
        }
        if context.configuration.mode == .sync {
            guard let etag, WebDAVHTTPClient.isStrongETag(etag) else {
                throw WebDAVFeatureError.strongETagRequired
            }
        }

        if enforceRollback, var state = localState {
            let key = expectedDeviceID.uuidString
            if let highest = state.highestRemoteGenerations[key] {
                guard manifest.generation >= highest else { throw WebDAVFeatureError.rollbackDetected }
                if manifest.generation == highest,
                   let priorDigest = state.remoteManifestDigests[key],
                   priorDigest != digest {
                    throw WebDAVFeatureError.rollbackDetected
                }
                if manifest.generation == highest &+ 1,
                   let priorDigest = state.remoteManifestDigests[key],
                   manifest.previousDigest != priorDigest {
                    throw WebDAVFeatureError.rollbackDetected
                }
            }
            state.highestRemoteGenerations[key] = max(
                state.highestRemoteGenerations[key] ?? 0,
                manifest.generation
            )
            state.remoteManifestDigests[key] = digest
            localState = state
        }
        return FetchedManifest(manifest: manifest, etag: etag, digest: digest)
    }

    private func applyMergedManifests(
        _ manifests: [DeviceSyncManifest],
        currentItems: [ClipboardItem]
    ) async throws {
        let result = WebDAVRecordMerger.merge(manifests)
        let currentByID = Dictionary(
            currentItems.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let retentionDays = await MainActor.run { SettingsManager.shared.autoCleanupDays }
        let locallyExpiredIDs = Set(result.visibleRecords.compactMap { record -> UUID? in
            guard let item = record.clipboardItem(),
                  !HistoryRetentionPolicy.shouldRetain(item, retentionDays: retentionDays) else {
                return nil
            }
            return item.id
        })
        let removedIDs = result.deletedItemIDs
            .union(result.duplicateItemIDs)
            .union(locallyExpiredIDs)
        var prepared: [PreparedSyncImport] = []
        var pendingDownloads: [PendingSyncDownload] = []
        var temporaryFiles: [URL] = []
        defer { temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Finish every download, decrypt and hash validation before changing local history.
        for record in result.visibleRecords {
            guard let item = record.clipboardItem() else { continue }
            guard !locallyExpiredIDs.contains(item.id) else { continue }
            if localState?.appliedRevisions[item.id.uuidString] == record.revision,
               currentByID[item.id] != nil {
                continue
            }

            if let reference = record.payload {
                if let existing = currentByID[item.id],
                   let existingPath = existing.filePath,
                   FileManager.default.fileExists(atPath: existingPath),
                   let existingInfo = try? PasteLightCrypto.sha256Hex(fileAt: URL(fileURLWithPath: existingPath)),
                   existingInfo.digest == reference.plaintextDigest {
                    prepared.append(PreparedSyncImport(
                        item: item,
                        payloadURL: nil,
                        payloadKind: nil,
                        revision: record.revision
                    ))
                    continue
                }

                pendingDownloads.append(PendingSyncDownload(
                    item: item,
                    reference: reference,
                    revision: record.revision
                ))
            } else {
                prepared.append(PreparedSyncImport(
                    item: item,
                    payloadURL: nil,
                    payloadKind: nil,
                    revision: record.revision
                ))
            }
        }

        var downloadIndex = 0
        while downloadIndex < pendingDownloads.count {
            let firstPending = pendingDownloads[downloadIndex]
            async let firstResult = captureBlobDownload(firstPending.reference)

            if downloadIndex + 1 < pendingDownloads.count {
                let secondPending = pendingDownloads[downloadIndex + 1]
                async let secondResult = captureBlobDownload(secondPending.reference)
                let results = await (firstResult, secondResult)
                var firstURL: URL?
                var secondURL: URL?
                var downloadError: Error?
                switch results.0 {
                case let .success(url):
                    firstURL = url
                    temporaryFiles.append(url)
                case let .failure(error):
                    downloadError = error
                }
                switch results.1 {
                case let .success(url):
                    secondURL = url
                    temporaryFiles.append(url)
                case let .failure(error):
                    if downloadError == nil { downloadError = error }
                }
                if let downloadError { throw downloadError }
                guard let firstURL, let secondURL else {
                    throw WebDAVFeatureError.corruptedPayload
                }
                prepared.append(PreparedSyncImport(
                    item: firstPending.item,
                    payloadURL: firstURL,
                    payloadKind: firstPending.reference.kind,
                    revision: firstPending.revision
                ))
                prepared.append(PreparedSyncImport(
                    item: secondPending.item,
                    payloadURL: secondURL,
                    payloadKind: secondPending.reference.kind,
                    revision: secondPending.revision
                ))
                downloadIndex += 2
            } else {
                let firstURL = try await firstResult.get()
                temporaryFiles.append(firstURL)
                prepared.append(PreparedSyncImport(
                    item: firstPending.item,
                    payloadURL: firstURL,
                    payloadKind: firstPending.reference.kind,
                    revision: firstPending.revision
                ))
                downloadIndex += 1
            }
        }

        let deletedItems = currentItems.filter { removedIDs.contains($0.id) }
        let importedItems = try store.applyRemoteSyncBatch(
            imports: prepared.map { ($0.item, $0.payloadURL, $0.payloadKind) },
            deleting: deletedItems,
            currentItems: currentItems
        )

        if var state = localState {
            for importItem in prepared {
                state.appliedRevisions[importItem.item.id.uuidString] = importItem.revision
            }
            for itemID in removedIDs {
                state.appliedRevisions.removeValue(forKey: itemID.uuidString)
            }
            localState = state
            try saveState()
        }

        await remoteBatchHandler(importedItems, removedIDs)
    }

    private func downloadAndDecrypt(_ reference: SyncPayloadReference) async throws -> URL {
        let context = try activeContext()
        let encryptedURL = temporaryURL(extension: "plblob")
        let decryptedURL = temporaryURL(extension: reference.kind == .image ? "png" : "richtext")
        do {
            try await context.client.download(
                blobURL(reference.remoteID, configuration: context.configuration),
                to: encryptedURL,
                maximumBytes: reference.byteCount + Self.encryptedPayloadOverhead
            )
            let header = try PasteLightCrypto.decryptFile(
                sourceURL: encryptedURL,
                destinationURL: decryptedURL,
                expectedObjectID: reference.remoteID,
                accountID: context.account.accountID,
                key: context.key
            )
            guard header.plaintextByteCount == reference.byteCount,
                  header.plaintextDigest == reference.plaintextDigest else {
                throw WebDAVFeatureError.corruptedPayload
            }
            try? FileManager.default.removeItem(at: encryptedURL)
            return decryptedURL
        } catch {
            try? FileManager.default.removeItem(at: encryptedURL)
            try? FileManager.default.removeItem(at: decryptedURL)
            if let featureError = error as? WebDAVFeatureError { throw featureError }
            throw WebDAVFeatureError.corruptedPayload
        }
    }

    private func captureBlobDownload(_ reference: SyncPayloadReference) async -> Result<URL, Error> {
        do {
            return .success(try await downloadAndDecrypt(reference))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Backups

    private func uploadBackup(records: [SyncRecord]) async throws {
        let context = try activeContext()
        let backupID = UUID()
        let now = Date()
        let fileStem = "\(Self.backupTimestampFormatter.string(from: now))-\(backupID.uuidString)"
        let fileName = "\(fileStem).plbackup"
        let manifest = BackupManifest(
            schemaVersion: BackupManifest.schemaVersion,
            backupID: backupID,
            deviceID: context.configuration.deviceID,
            deviceName: context.configuration.deviceName,
            createdAt: now,
            records: records
        )
        let plaintext = try sortedJSONEncoder().encode(manifest)
        let encrypted = try PasteLightCrypto.encrypt(
            plaintext,
            using: context.key,
            aad: backupAAD(
                accountID: context.account.accountID,
                deviceID: context.configuration.deviceID,
                fileName: fileName
            )
        )
        guard encrypted.count <= Self.backupMaximumBytes else {
            throw WebDAVFeatureError.payloadTooLarge
        }
        _ = try await context.client.put(
            encrypted,
            to: backupDirectoryURL(configuration: context.configuration).appendingPathComponent(fileName),
            ifMatch: nil,
            ifNoneMatch: true
        )
    }

    private func retainLatestBackups(limit: Int) async throws {
        let context = try activeContext()
        let directory = backupDirectoryURL(configuration: context.configuration)
        let backups = try await listBackups(
            deviceID: context.configuration.deviceID,
            directory: directory,
            client: context.client
        )
        guard backups.count > limit else { return }
        for backup in backups.dropFirst(limit) {
            try await context.client.delete(backup.url, ignoreMissing: true)
        }
    }

    /// Reclaims only blobs that remain unreferenced across two complete scans for
    /// at least seven days. The grace period prevents deleting a blob uploaded by
    /// another Mac just before that Mac conditionally publishes its manifest.
    private func reclaimOrphanedBlobs(manifests: [DeviceSyncManifest]) async throws {
        if let lastScan = localState?.lastOrphanScanAt,
           Date().timeIntervalSince(lastScan) < 24 * 60 * 60 {
            return
        }
        let context = try activeContext()
        var referencedIDs = Set(
            manifests.flatMap(\.records).compactMap { $0.payload?.remoteID }
        )
        let backupsRoot = context.configuration.syncRootURL!
            .appendingPathComponent("backups", isDirectory: true)
        let backupRootResources = try await context.client.list(backupsRoot, depth: 1)
        let backupChildren = backupRootResources.filter { resource in
            resource.url.standardized.path != backupsRoot.standardized.path
        }
        guard backupChildren.allSatisfy(\.isCollection) else {
            throw WebDAVFeatureError.corruptedPayload
        }
        let backupDirectories = backupChildren

        for directory in backupDirectories {
            guard let deviceID = UUID(uuidString: directory.url.lastPathComponent) else {
                throw WebDAVFeatureError.corruptedPayload
            }
            let resources = try await context.client.list(directory.url, depth: 1)
            for resource in resources where !resource.isCollection && resource.url.pathExtension == "plbackup" {
                let encrypted = try await context.client.get(
                    resource.url,
                    maximumBytes: Self.backupMaximumBytes
                )
                let plaintext = try PasteLightCrypto.decrypt(
                    encrypted,
                    using: context.key,
                    aad: backupAAD(
                        accountID: context.account.accountID,
                        deviceID: deviceID,
                        fileName: resource.url.lastPathComponent
                    )
                )
                let backup = try JSONDecoder().decode(BackupManifest.self, from: plaintext)
                guard backup.schemaVersion == BackupManifest.schemaVersion,
                      backup.deviceID == deviceID else {
                    throw WebDAVFeatureError.corruptedPayload
                }
                try validate(records: backup.records, context: context)
                referencedIDs.formUnion(backup.records.compactMap { $0.payload?.remoteID })
            }
        }

        let blobsRoot = context.configuration.syncRootURL!
            .appendingPathComponent("blobs", isDirectory: true)
        let blobs = try await context.client.list(blobsRoot, depth: 1).filter {
            !$0.isCollection && $0.url.pathExtension == "plblob"
        }
        let now = Date()
        let gracePeriod: TimeInterval = 7 * 24 * 60 * 60
        var firstSeen = localState?.orphanBlobFirstSeenAt ?? [:]
        let remoteIDs = Set(blobs.map { $0.url.deletingPathExtension().lastPathComponent })
        firstSeen = firstSeen.filter { remoteIDs.contains($0.key) && !referencedIDs.contains($0.key) }

        for blob in blobs {
            let remoteID = blob.url.deletingPathExtension().lastPathComponent
            guard Self.isLowercaseSHA256(remoteID), !referencedIDs.contains(remoteID) else {
                firstSeen.removeValue(forKey: remoteID)
                continue
            }
            if let observedAt = firstSeen[remoteID],
               now.timeIntervalSince(observedAt) >= gracePeriod,
               blob.lastModified.map({ $0 <= observedAt }) ?? true {
                try await context.client.delete(blob.url, ignoreMissing: true)
                firstSeen.removeValue(forKey: remoteID)
            } else if let observedAt = firstSeen[remoteID] {
                if blob.lastModified.map({ $0 > observedAt }) == true {
                    firstSeen[remoteID] = now
                }
            } else {
                firstSeen[remoteID] = now
            }
        }
        if var state = localState {
            state.orphanBlobFirstSeenAt = firstSeen
            state.lastOrphanScanAt = now
            localState = state
            try saveState()
        }
    }

    // MARK: - Persistence and helpers

    private struct ActiveContext {
        let configuration: WebDAVConfiguration
        let client: WebDAVClientProtocol
        let account: WebDAVAccountDescriptor
        let key: SymmetricKey
    }

    private func activeContext() throws -> ActiveContext {
        guard let configuration, let client, let account, let masterKey else {
            throw WebDAVFeatureError.notConfigured
        }
        return ActiveContext(
            configuration: configuration,
            client: client,
            account: account,
            key: masterKey
        )
    }

    private func validate(records: [SyncRecord], context: ActiveContext) throws {
        var itemIDs = Set<UUID>()
        for record in records {
            guard itemIDs.insert(record.itemID).inserted,
                  record.revision.counter > 0 else {
                throw WebDAVFeatureError.corruptedPayload
            }
            if record.state == .tombstone { continue }
            guard let type = record.type,
                  type == .text || type == .code || type == .image,
                  let content = record.content,
                  content.count <= ClipboardTextSanitizer.maxStoredCharacters + 3,
                  record.timestamp != nil,
                  record.isFavorite != nil,
                  let fingerprint = record.fingerprint,
                  !fingerprint.isEmpty,
                  fingerprint.count <= 256 else {
                throw WebDAVFeatureError.corruptedPayload
            }

            guard let payload = record.payload else {
                if type == .image { throw WebDAVFeatureError.corruptedPayload }
                continue
            }
            guard Self.isLowercaseSHA256(payload.remoteID),
                  Self.isLowercaseSHA256(payload.plaintextDigest),
                  payload.byteCount > 0,
                  payload.remoteID == PasteLightCrypto.remoteObjectID(
                      fingerprint: payload.plaintextDigest,
                      kind: payload.kind,
                      key: context.key
                  ) else {
                throw WebDAVFeatureError.corruptedPayload
            }
            switch payload.kind {
            case .image:
                guard type == .image,
                      payload.byteCount <= Int64(context.configuration.imageLimitBytes) else {
                    throw WebDAVFeatureError.payloadTooLarge
                }
            case .richText:
                guard type == .text,
                      payload.byteCount <= Int64(ClipboardPayloadLimits.maxStoredFormattedTextBytes) else {
                    throw WebDAVFeatureError.payloadTooLarge
                }
            }
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func validate(
        configuration: WebDAVConfiguration,
        password: String,
        passphrase: String
    ) throws {
        let rawURL = configuration.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: rawURL), parsed.scheme != nil else {
            throw WebDAVFeatureError.invalidURL
        }
        guard parsed.scheme?.lowercased() == "https" else { throw WebDAVFeatureError.insecureURL }
        guard configuration.baseURL != nil else { throw WebDAVFeatureError.invalidURL }
        let pathParts = configuration.remotePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !pathParts.contains(where: { rawPart in
            let part = String(rawPart).removingPercentEncoding ?? String(rawPart)
            return part == "." || part == ".." || part.contains("/") || part.contains("\\")
        }) else {
            throw WebDAVFeatureError.invalidRemotePath
        }
        guard !configuration.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            throw WebDAVFeatureError.missingCredentials
        }
        guard passphrase.precomposedStringWithCompatibilityMapping.count >= 12 else {
            throw WebDAVFeatureError.passphraseTooShort
        }
    }

    private func loadState(for configuration: WebDAVConfiguration) -> WebDAVLocalState {
        guard let url = try? stateURL(for: configuration),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WebDAVLocalState.self, from: data),
              state.manifest.deviceID == configuration.deviceID else {
            return WebDAVLocalState(configuration: configuration)
        }
        return state
    }

    private func saveState() throws {
        guard let configuration, let localState else { return }
        let url = try stateURL(for: configuration)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sortedJSONEncoder().encode(localState).write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func stateURL(for configuration: WebDAVConfiguration) throws -> URL {
        guard let root = configuration.syncRootURL else { throw WebDAVFeatureError.invalidURL }
        let digest = PasteLightCrypto.sha256Hex(Data(root.absoluteString.utf8))
        return stateRootURL
            .appendingPathComponent(digest, isDirectory: true)
            .appendingPathComponent("\(configuration.deviceID.uuidString).json")
    }

    private func sortedJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func deviceManifestURL(_ deviceID: UUID, configuration: WebDAVConfiguration) -> URL {
        configuration.syncRootURL!
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(deviceID.uuidString).manifest.plenc")
    }

    private func blobURL(_ remoteID: String, configuration: WebDAVConfiguration) -> URL {
        configuration.syncRootURL!
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("\(remoteID).plblob")
    }

    private func backupDirectoryURL(configuration: WebDAVConfiguration) -> URL {
        configuration.syncRootURL!
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(configuration.deviceID.uuidString, isDirectory: true)
    }

    private func manifestAAD(accountID: UUID, deviceID: UUID) -> Data {
        Data("PasteLight|manifest|1|\(accountID.uuidString)|\(deviceID.uuidString)".utf8)
    }

    private func backupAAD(accountID: UUID, deviceID: UUID, fileName: String) -> Data {
        Data("PasteLight|backup|1|\(accountID.uuidString)|\(deviceID.uuidString)|\(fileName)".utf8)
    }

    private func temporaryURL(extension extensionName: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteLight-WebDAV-\(UUID().uuidString)")
            .appendingPathExtension(extensionName)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()

    private static func backupDate(from fileName: String) -> Date? {
        let stem = fileName.replacingOccurrences(of: ".plbackup", with: "")
        guard let timestamp = stem.split(separator: "-").first else { return nil }
        return backupTimestampFormatter.date(from: String(timestamp))
    }

    private func publishStatus(
        _ phase: WebDAVSyncPhase,
        _ message: String,
        progress: Double,
        successDate: Date? = nil
    ) {
        statusHandler?(
            WebDAVSyncStatus(
                phase: phase,
                message: message,
                progress: min(max(progress, 0), 1),
                lastSuccessAt: successDate,
                skippedItemCount: skippedItemCount
            )
        )
    }

    private func publishFailure(_ error: Error) {
        publishStatus(
            .failed,
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            progress: 0
        )
    }
}

@MainActor
final class WebDAVSyncManager: ObservableObject {
    static let shared = WebDAVSyncManager()

    @Published private(set) var status: WebDAVSyncStatus = .disabled
    @Published private(set) var backups: [RemoteBackupInfo] = []
    @Published private(set) var isConfigured = false

    private let coordinator: WebDAVSyncCoordinator
    private var observers: [NSObjectProtocol] = []
    private var periodicTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var actionTask: Task<Void, Never>?
    private var rerunRequested = false
    private var retryAttempt = 0
    private var coordinatorReady = false
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.oneclip.webdav.network", qos: .utility)
    private var started = false

    private init() {
        coordinator = WebDAVSyncCoordinator(store: ClipboardManager.shared.store)
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator.setStatusHandler { [weak self] newStatus in
                Task { @MainActor in self?.receive(newStatus) }
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true

        observers.append(NotificationCenter.default.addObserver(
            forName: .clipboardSyncMutation,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.object as? ClipboardSyncMutationEvent else { return }
            Task { @MainActor in self?.handle(event.mutation) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.triggerAutomaticAction(immediate: true) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .webDAVConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let configuration = notification.object as? WebDAVConfiguration else { return }
            Task { @MainActor in self?.configurationDidChange(configuration) }
        })

        periodicTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.triggerAutomaticAction(immediate: true) }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.triggerAutomaticAction(immediate: true) }
        }
        pathMonitor.start(queue: pathQueue)

        let configuration = SettingsManager.shared.webDAVConfiguration
        isConfigured = configuration.mode != .disabled
        coordinatorReady = false
        guard isConfigured else { return }
        Task {
            do {
                try await coordinator.resume(configuration: configuration)
                coordinatorReady = true
                triggerAutomaticAction(immediate: true)
            } catch {
                coordinatorReady = false
                receiveFailure(error)
            }
        }
    }

    func stop() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        debounceWorkItem?.cancel()
        retryWorkItem?.cancel()
        actionTask?.cancel()
        actionTask = nil
        rerunRequested = false
        pathMonitor.cancel()
    }

    func estimate(for configuration: WebDAVConfiguration) -> WebDAVInitialEstimate {
        WebDAVSyncCoordinator.estimate(
            items: ClipboardManager.shared.clipboardItems,
            imageLimitBytes: configuration.imageLimitBytes
        )
    }

    func testConnection(
        configuration: WebDAVConfiguration,
        password: String,
        passphrase: String
    ) {
        Task {
            do {
                _ = try await coordinator.testConnection(
                    configuration: configuration,
                    password: password,
                    passphrase: passphrase
                )
            } catch {
                receiveFailure(error)
            }
        }
    }

    func enable(
        configuration: WebDAVConfiguration,
        password: String,
        passphrase: String
    ) {
        let items = ClipboardManager.shared.clipboardItems
        let previous = SettingsManager.shared.webDAVConfiguration
        Task {
            do {
                let activated = try await coordinator.activate(
                    configuration: configuration,
                    password: password,
                    passphrase: passphrase,
                    initialItems: items
                )
                if previous.serverURL != activated.serverURL || previous.username != activated.username {
                    WebDAVSecretStore.shared.deleteCredential(for: previous)
                }
                if let previousAccountID = previous.accountID,
                   previousAccountID != activated.accountID {
                    WebDAVSecretStore.shared.deleteMasterKey(accountID: previousAccountID)
                }
                SettingsManager.shared.webDAVConfiguration = activated
                isConfigured = true
                coordinatorReady = true
                retryAttempt = 0
                triggerAutomaticAction(immediate: true)
            } catch {
                receiveFailure(error)
            }
        }
    }

    func disconnect() {
        let configuration = SettingsManager.shared.webDAVConfiguration
        WebDAVSecretStore.shared.deleteCredential(for: configuration)
        if let accountID = configuration.accountID {
            WebDAVSecretStore.shared.deleteMasterKey(accountID: accountID)
        }
        let disabled = WebDAVConfiguration(
            mode: .disabled,
            deviceID: configuration.deviceID,
            deviceName: configuration.deviceName
        )
        SettingsManager.shared.webDAVConfiguration = disabled
        isConfigured = false
        coordinatorReady = false
        status = .disabled
        backups = []
        debounceWorkItem?.cancel()
        retryWorkItem?.cancel()
        actionTask?.cancel()
        actionTask = nil
        rerunRequested = false
        Task { await coordinator.removeLocalState(for: configuration) }
    }

    func performNow() {
        runCurrentMode(manual: true)
    }

    func refreshBackups() {
        Task {
            do { backups = try await coordinator.listBackups() }
            catch { receiveFailure(error) }
        }
    }

    func restore(_ backup: RemoteBackupInfo) {
        let items = ClipboardManager.shared.clipboardItems
        Task {
            do {
                try await coordinator.restoreBackup(backup, currentItems: items)
                refreshBackups()
            } catch {
                receiveFailure(error)
            }
        }
    }

    private func handle(_ mutation: ClipboardSyncMutation) {
        let configuration = SettingsManager.shared.webDAVConfiguration
        guard configuration.mode != .disabled else { return }
        Task {
            do {
                try await ensureResumed(configuration)
                _ = try await coordinator.record(mutation)
                triggerAutomaticAction(immediate: false)
            } catch {
                receiveFailure(error)
                scheduleRetry()
            }
        }
    }

    private func ensureResumed(_ configuration: WebDAVConfiguration) async throws {
        if !coordinatorReady {
            try await coordinator.resume(configuration: configuration)
            isConfigured = true
            coordinatorReady = true
        }
    }

    private func configurationDidChange(_ configuration: WebDAVConfiguration) {
        isConfigured = configuration.mode != .disabled
        if configuration.mode == .disabled {
            coordinatorReady = false
            Task { await coordinator.deactivate() }
            return
        }
        guard !coordinatorReady else { return }
        Task {
            do {
                try await coordinator.resume(configuration: configuration)
                coordinatorReady = true
                triggerAutomaticAction(immediate: true)
            } catch {
                coordinatorReady = false
                receiveFailure(error)
            }
        }
    }

    private func triggerAutomaticAction(immediate: Bool) {
        guard SettingsManager.shared.webDAVConfiguration.mode != .disabled else { return }
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.runCurrentMode(manual: false) }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 3), execute: workItem)
    }

    private func runCurrentMode(manual: Bool) {
        let configuration = SettingsManager.shared.webDAVConfiguration
        let items = ClipboardManager.shared.clipboardItems
        guard configuration.mode != .disabled else { return }
        guard actionTask == nil else {
            rerunRequested = true
            return
        }
        retryWorkItem?.cancel()

        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureResumed(configuration)
                switch configuration.mode {
                case .sync:
                    try await self.coordinator.synchronize(currentItems: items)
                case .backup:
                    try await self.coordinator.createBackup(currentItems: items, automatic: !manual)
                    self.backups = (try? await self.coordinator.listBackups()) ?? self.backups
                case .disabled:
                    break
                }
                self.retryAttempt = 0
            } catch {
                if !Task.isCancelled {
                    self.receiveFailure(error)
                    self.scheduleRetry()
                }
            }
            self.finishCurrentAction()
        }
    }

    private func finishCurrentAction() {
        actionTask = nil
        guard rerunRequested else { return }
        rerunRequested = false
        triggerAutomaticAction(immediate: true)
    }

    private func scheduleRetry() {
        guard SettingsManager.shared.webDAVConfiguration.mode != .disabled else { return }
        retryWorkItem?.cancel()
        let delay = min(30 * pow(2, Double(retryAttempt)), 15 * 60)
        retryAttempt = min(retryAttempt + 1, 8)
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.runCurrentMode(manual: false) }
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func receive(_ newStatus: WebDAVSyncStatus) {
        var merged = newStatus
        if merged.lastSuccessAt == nil { merged.lastSuccessAt = status.lastSuccessAt }
        status = merged
    }

    private func receiveFailure(_ error: Error) {
        status = WebDAVSyncStatus(
            phase: .failed,
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            progress: 0,
            lastSuccessAt: status.lastSuccessAt,
            skippedItemCount: status.skippedItemCount
        )
    }
}
