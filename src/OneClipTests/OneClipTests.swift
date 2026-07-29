//
//  OneClipTests.swift
//  OneClipTests
//
//  Created by Wcowin on 2025/8/12.
//

import AppKit
import CryptoKit
import Testing
@testable import OneClip

struct OneClipTests {

    @Test func invalidClipboardWritePlanPreservesExistingClipboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteLightTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(pasteboard.setString("sentinel", forType: .string))

        let result = ClipboardWritePlan(values: []).commit(to: pasteboard)

        #expect(!result)
        #expect(pasteboard.string(forType: .string) == "sentinel")
    }

    @Test func validTextClipboardWritePlanReportsSuccess() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteLightTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let result = ClipboardWritePlan(values: [
            .string("PasteLight", .string)
        ]).commit(to: pasteboard)

        #expect(result)
        #expect(pasteboard.string(forType: .string) == "PasteLight")
    }

    @Test func formattedPayloadLimitsEnforceBoundaries() {
        #expect(ClipboardPayloadLimits.acceptsFormattedText(byteCount: 1))
        #expect(ClipboardPayloadLimits.acceptsFormattedText(
            byteCount: ClipboardPayloadLimits.maxFormattedTextBytes
        ))
        #expect(!ClipboardPayloadLimits.acceptsFormattedText(byteCount: 0))
        #expect(!ClipboardPayloadLimits.acceptsFormattedText(
            byteCount: ClipboardPayloadLimits.maxFormattedTextBytes + 1
        ))
        #expect(ClipboardPayloadLimits.acceptsStoredFormattedText(
            byteCount: ClipboardPayloadLimits.maxStoredFormattedTextBytes
        ))
        #expect(!ClipboardPayloadLimits.acceptsStoredFormattedText(
            byteCount: ClipboardPayloadLimits.maxStoredFormattedTextBytes + 1
        ))
    }

    @Test func imagePayloadLimitsRejectOversizedAndOverflowingImages() {
        #expect(ClipboardPayloadLimits.acceptsImage(
            byteCount: 1,
            pixelWidth: 8_000,
            pixelHeight: 5_000
        ))
        #expect(!ClipboardPayloadLimits.acceptsImage(
            byteCount: Int(ClipboardPayloadLimits.maxImageBytes + 1),
            pixelWidth: 1,
            pixelHeight: 1
        ))
        #expect(!ClipboardPayloadLimits.acceptsImage(
            byteCount: 1,
            pixelWidth: 8_001,
            pixelHeight: 5_000
        ))
        #expect(!ClipboardPayloadLimits.acceptsImage(
            byteCount: 1,
            pixelWidth: Int64.max,
            pixelHeight: 2
        ))
    }

    @Test func imagePreviewDecoderCreatesMemoryBoundedThumbnail() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 400,
            pixelsHigh: 200,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        let metadata = try #require(ImageThumbnailDecoder.metadata(from: pngData))

        let thumbnail = try #require(ImageThumbnailDecoder.makeThumbnail(
            from: pngData,
            maxPixelSize: 64
        ))
        let maxDecodedDimension = thumbnail.representations
            .flatMap { [$0.pixelsWide, $0.pixelsHigh] }
            .max() ?? 0

        #expect(metadata.pixelWidth == 400)
        #expect(metadata.pixelHeight == 200)
        #expect(maxDecodedDimension <= 64)
        #expect(ImageThumbnailDecoder.estimatedMemoryCost(of: thumbnail) <= 64 * 64 * 4)
    }

    @Test func menuThumbnailCacheReusesDecodedImage() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 80,
            pixelsHigh: 40,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        let itemID = UUID()
        let cacheKey = ImageThumbnailDecoder.cacheKey(itemID: itemID, maxPixelSize: 48)
        ImageCacheManager.shared.removeImage(forKey: cacheKey)

        let first = try #require(ImageCacheManager.shared.thumbnail(
            itemID: itemID,
            data: pngData,
            maxPixelSize: 48
        ))
        let second = try #require(ImageCacheManager.shared.thumbnail(
            itemID: itemID,
            data: pngData,
            maxPixelSize: 48
        ))

        #expect(first === second)
        ImageCacheManager.shared.removeImage(forKey: cacheKey)
    }

    @Test func imagePayloadReaderFetchesOnlyPreferredDeclaredType() throws {
        let provider = CountingImageDataProvider(
            types: [.png, .tiff],
            payloads: [
                .png: Data(repeating: 0x01, count: 32),
                .tiff: Data(repeating: 0x02, count: 32)
            ]
        )

        let payload = try #require(ClipboardImagePayloadReader.read(from: provider))

        #expect(payload.type == .png)
        #expect(payload.formatName == "PNG")
        #expect(provider.readCount == 1)
    }

    @Test func clipboardItemDateCodingPreservesTimestampAndLegacyNumericDates() throws {
        let timestamp = Date(timeIntervalSince1970: 1_721_234_567.123)
        let item = ClipboardItem(
            id: UUID(),
            content: "date",
            type: .text,
            timestamp: timestamp,
            lastUsedAt: timestamp.addingTimeInterval(10)
        )

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: encoded)
        #expect(abs(decoded.timestamp.timeIntervalSince(timestamp)) < 0.001)
        #expect(abs(try #require(decoded.lastUsedAt).timeIntervalSince(timestamp.addingTimeInterval(10))) < 0.001)

        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "content": "legacy",
          "type": "text",
          "timestamp": 1234.5,
          "data": "",
          "isFavorite": false
        }
        """
        let legacy = try JSONDecoder().decode(ClipboardItem.self, from: Data(legacyJSON.utf8))
        #expect(legacy.timestamp == Date(timeIntervalSince1970: 1234.5))
    }

    @Test func targetApplicationMustMatchFrontmostPID() {
        #expect(WindowManager.isTargetApplicationFrontmost(targetPID: 42, frontmostPID: 42))
        #expect(!WindowManager.isTargetApplicationFrontmost(targetPID: 42, frontmostPID: 43))
        #expect(!WindowManager.isTargetApplicationFrontmost(targetPID: 42, frontmostPID: nil))
    }

    @Test func pasteRequestGateRejectsDuplicatesUntilFinished() {
        let gate = PasteRequestGate()

        #expect(gate.begin())
        #expect(!gate.begin())
        gate.finish()
        #expect(gate.begin())
        gate.finish()
    }

    @Test func officeVMLRulesAreRemovedFromClipboardText() {
        let source = """
        v\\:* {behavior:url(#default#VML);} o\\:* {behavior:url(#default#VML);} x\\:* {behavior:url(#default#VML);} .shape {behavior:url(#default#VML);}
        系统架构图（图片放大后清晰）
        """

        #expect(ClipboardTextSanitizer.clean(source) == "系统架构图（图片放大后清晰）")
    }

    @Test func largeClipboardTextIsBoundedForHistoryProcessing() {
        let source = String(repeating: "a", count: ClipboardTextSanitizer.maxProcessingCharacters + 50_000)
        let cleaned = ClipboardTextSanitizer.cleanForHistory(source)

        #expect(cleaned.count == ClipboardTextSanitizer.maxStoredCharacters + 3)
        #expect(cleaned.hasSuffix("..."))
    }

    @Test func clipboardListSnapshotFiltersAndCountsInOnePass() {
        let textItem = ClipboardItem(
            id: UUID(),
            content: "Alpha note",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 100),
            isFavorite: true
        )
        let imageItem = ClipboardItem(
            id: UUID(),
            content: "Alpha image",
            type: .image,
            timestamp: Date(timeIntervalSince1970: 200)
        )
        let otherTextItem = ClipboardItem(
            id: UUID(),
            content: "Beta note",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 300)
        )

        let snapshot = ClipboardListSnapshot.make(
            historyItems: [otherTextItem, imageItem, textItem],
            favoriteItems: [],
            selectedType: .text,
            favoritesOnly: false,
            query: "alpha"
        )

        #expect(snapshot.items.map(\.id) == [textItem.id])
        #expect(snapshot.indexedItems.map(\.index) == [0])
        #expect(snapshot.typeCounts[.text] == 2)
        #expect(snapshot.typeCounts[.image] == 1)
        #expect(snapshot.favoriteCount == 1)
    }

    @Test func debouncedActionSchedulerFlushesOnlyLatestAction() {
        let scheduler = DebouncedActionScheduler(delay: 60, queue: .main)
        var values: [Int] = []

        scheduler.schedule { values.append(1) }
        scheduler.schedule { values.append(2) }
        scheduler.flush()

        #expect(values == [2])
    }

    @Test func spreadsheetRowsAndColumnsRemainPlainText() {
        let source = "名称\t数量\r\nPasteLight\t2"

        #expect(ClipboardTextSanitizer.clean(source) == "名称\t数量\nPasteLight\t2")
    }

    @Test func retentionRemovesExpiredNonFavoriteItems() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let item = ClipboardItem(
            id: UUID(),
            content: "expired",
            type: .text,
            timestamp: Calendar.current.date(byAdding: .day, value: -61, to: now)!
        )

        #expect(!HistoryRetentionPolicy.shouldRetain(item, retentionDays: 60, now: now))
    }

    @Test func retentionAlwaysKeepsFavoritesAndPermanentHistory() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldDate = Calendar.current.date(byAdding: .day, value: -500, to: now)!
        let favorite = ClipboardItem(
            id: UUID(),
            content: "favorite",
            type: .text,
            timestamp: oldDate,
            isFavorite: true
        )
        let regular = ClipboardItem(
            id: UUID(),
            content: "regular",
            type: .text,
            timestamp: oldDate
        )

        #expect(HistoryRetentionPolicy.shouldRetain(favorite, retentionDays: 7, now: now))
        #expect(HistoryRetentionPolicy.shouldRetain(regular, retentionDays: 0, now: now))
    }

    @Test func unsupportedRetentionFallsBackToSixtyDays() {
        #expect(HistoryRetentionPolicy.normalizedDays(90) == 60)
        #expect(HistoryRetentionPolicy.normalizedDays(0) == 0)
    }

    @Test func duplicateTextIgnoresRichTextFormattingData() {
        let plain = ClipboardItemFingerprint.make(
            content: "same text",
            type: .text,
            data: nil
        )
        let rich = ClipboardItemFingerprint.make(
            content: "same text",
            type: .text,
            data: Data("{\\rtf1 same text}".utf8)
        )

        #expect(plain == rich)
    }

    @Test func duplicateImagesUseCompleteBinaryContent() {
        let first = ClipboardItemFingerprint.make(
            content: "image from browser",
            type: .image,
            data: Data([0x01, 0x02, 0x03, 0x04])
        )
        let sameImageWithDifferentDescription = ClipboardItemFingerprint.make(
            content: "image from file",
            type: .image,
            data: Data([0x01, 0x02, 0x03, 0x04])
        )
        let differentImage = ClipboardItemFingerprint.make(
            content: "image from browser",
            type: .image,
            data: Data([0x01, 0x02, 0x03, 0x05])
        )

        #expect(first == sameImageWithDifferentDescription)
        #expect(first != differentImage)
    }

    @Test func sameFileNameWithDifferentContentsIsNotDuplicate() {
        let first = ClipboardItemFingerprint.make(
            content: "文件: report.pdf",
            type: .document,
            data: Data("version one".utf8)
        )
        let updated = ClipboardItemFingerprint.make(
            content: "文件: report.pdf",
            type: .document,
            data: Data("version two".utf8)
        )

        #expect(first != updated)
    }

    @Test func streamedFileFingerprintMatchesInMemoryFingerprint() throws {
        let data = Data(repeating: 0x5a, count: ClipboardItemFingerprint.fileReadChunkSize * 2 + 137)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let inMemory = ClipboardItemFingerprint.make(
            content: "large image",
            type: .image,
            data: data
        )
        let streamed = ClipboardItemFingerprint.make(fileAt: fileURL, type: .image)

        #expect(streamed == inMemory)
    }

    @Test func persistedFingerprintAvoidsReadingMissingFile() {
        let fingerprint = ClipboardItemFingerprint.make(
            content: "image",
            type: .image,
            data: Data([0x01, 0x02, 0x03])
        )
        let item = ClipboardItem(
            id: UUID(),
            content: "image",
            type: .image,
            timestamp: Date(),
            filePath: "/path/that/does/not/exist",
            fingerprint: fingerprint
        )

        #expect(ClipboardItemFingerprint.make(for: item) == fingerprint)
    }

    @Test func historyDeduplicationPrefersFavoriteItem() {
        let fingerprint = ClipboardItemFingerprint.make(
            content: "same",
            type: .text,
            data: nil
        )
        let recent = ClipboardItem(
            id: UUID(),
            content: "same",
            type: .text,
            timestamp: Date(),
            fingerprint: fingerprint
        )
        let favorite = ClipboardItem(
            id: UUID(),
            content: "same",
            type: .text,
            timestamp: Date().addingTimeInterval(-100),
            isFavorite: true,
            fingerprint: fingerprint
        )

        let result = ClipboardHistoryDeduplicator.deduplicate([recent, favorite])

        #expect(result.count == 1)
        #expect(result[0].id == favorite.id)
    }

    @Test func fingerprintMigrationPreservesStoredImageFiles() {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let store = ClipboardStore(getCleanupDays: { 0 }, storageDirectory: storageURL)
        let imageData = Data(repeating: 0x7f, count: 2048)
        let first = ClipboardItem(
            id: UUID(),
            content: "image",
            type: .image,
            timestamp: Date(),
            data: imageData
        )
        let duplicate = ClipboardItem(
            id: UUID(),
            content: "same image, different description",
            type: .image,
            timestamp: Date().addingTimeInterval(-1),
            data: imageData
        )
        let storedFirst = store.saveItem(first)
        let storedDuplicate = store.saveItem(duplicate)
        let fingerprint = ClipboardItemFingerprint.make(
            content: first.content,
            type: .image,
            data: imageData
        )

        store.applyFingerprintMigration([
            first.id: fingerprint,
            duplicate.id: fingerprint
        ])

        let migratedItems = store.loadItems()
        #expect(migratedItems.count == 1)
        #expect(migratedItems[0].fingerprint == fingerprint)
        #expect(migratedItems[0].filePath.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(storedFirst.filePath.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(storedDuplicate.filePath.map { FileManager.default.fileExists(atPath: $0) } == true)
    }

    @Test func clearingHistoryKeepsFavoriteImageFile() {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let store = ClipboardStore(getCleanupDays: { 0 }, storageDirectory: storageURL)
        let favorite = ClipboardItem(
            id: UUID(),
            content: "favorite image",
            type: .image,
            timestamp: Date(),
            data: Data(repeating: 0x01, count: 1024),
            isFavorite: true,
            fingerprint: "image:favorite"
        )
        let regular = ClipboardItem(
            id: UUID(),
            content: "regular image",
            type: .image,
            timestamp: Date(),
            data: Data(repeating: 0x02, count: 1024),
            fingerprint: "image:regular"
        )
        let storedFavorite = store.saveItem(favorite)
        let storedRegular = store.saveItem(regular)

        store.clearAllItems()

        let remainingItems = store.loadItems()
        #expect(remainingItems.count == 1)
        #expect(remainingItems[0].id == favorite.id)
        #expect(storedFavorite.filePath.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(storedRegular.filePath.map { FileManager.default.fileExists(atPath: $0) } == false)
    }

    @Test func recentlyUsedItemMovesToTopWithoutChangingCreationTime() {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let store = ClipboardStore(getCleanupDays: { 0 }, storageDirectory: storageURL)
        let oldTimestamp = Date(timeIntervalSince1970: 1_000)
        let newerItem = ClipboardItem(
            id: UUID(),
            content: "newer",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 2_000)
        )
        let olderItem = ClipboardItem(
            id: UUID(),
            content: "older",
            type: .text,
            timestamp: oldTimestamp
        )
        store.saveItem(olderItem)
        store.saveItem(newerItem)

        store.markItemUsed(olderItem, at: Date(timeIntervalSince1970: 3_000))

        let reloadedItems = store.loadItems()
        #expect(reloadedItems.first?.id == olderItem.id)
        #expect(reloadedItems.first?.timestamp == oldTimestamp)
        #expect(reloadedItems.first?.lastUsedAt == Date(timeIntervalSince1970: 3_000))
    }

    @Test func incrementalSaveDoesNotRewriteOtherDateIndex() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let store = ClipboardStore(getCleanupDays: { 0 }, storageDirectory: storageURL)
        let calendar = Calendar(identifier: .gregorian)
        let firstDate = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2024,
            month: 1,
            day: 2,
            hour: 12
        )))
        let secondDate = firstDate.addingTimeInterval(24 * 60 * 60)
        let firstItem = ClipboardItem(
            id: UUID(),
            content: "first day",
            type: .text,
            timestamp: firstDate
        )
        store.saveItem(firstItem)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let firstIndex = storageURL
            .appendingPathComponent(formatter.string(from: firstDate), isDirectory: true)
            .appendingPathComponent("items.json")
        let sentinelDate = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes(
            [.modificationDate: sentinelDate],
            ofItemAtPath: firstIndex.path
        )

        let secondItem = ClipboardItem(
            id: UUID(),
            content: "second day",
            type: .text,
            timestamp: secondDate
        )
        store.saveItem(secondItem)

        let attributes = try FileManager.default.attributesOfItem(atPath: firstIndex.path)
        #expect(attributes[.modificationDate] as? Date == sentinelDate)
        #expect(store.loadItems().count == 2)

        let secondIndex = storageURL
            .appendingPathComponent(formatter.string(from: secondDate), isDirectory: true)
            .appendingPathComponent("items.json")
        let secondSentinelDate = Date(timeIntervalSince1970: 200)
        try FileManager.default.setAttributes(
            [.modificationDate: secondSentinelDate],
            ofItemAtPath: secondIndex.path
        )

        store.markItemUsed(firstItem, at: secondDate.addingTimeInterval(60))
        let attributesAfterUse = try FileManager.default.attributesOfItem(atPath: secondIndex.path)
        #expect(attributesAfterUse[.modificationDate] as? Date == secondSentinelDate)

        store.deleteItem(firstItem)
        let attributesAfterDelete = try FileManager.default.attributesOfItem(atPath: secondIndex.path)
        #expect(attributesAfterDelete[.modificationDate] as? Date == secondSentinelDate)
        #expect(store.loadItems().map(\.id) == [secondItem.id])
    }

}

@Suite(.serialized)
struct WebDAVFeatureTests {
    @Test func pbkdf2IsStableAcrossNFKCEquivalentPassphrases() throws {
        let salt = Data((0..<16).map(UInt8.init))
        let composed = "PasteLight-Å-安全密码"
        let decomposed = "PasteLight-A\u{30A}-安全密码"

        let first = try PasteLightCrypto.deriveKey(
            passphrase: composed,
            salt: salt,
            iterations: PasteLightCrypto.minimumPBKDF2Iterations
        )
        let second = try PasteLightCrypto.deriveKey(
            passphrase: decomposed,
            salt: salt,
            iterations: PasteLightCrypto.minimumPBKDF2Iterations
        )

        #expect(PasteLightCrypto.rawData(first) == PasteLightCrypto.rawData(second))
    }

    @Test func aesGCMRejectsWrongKeyAADAndTamperingAndUsesRandomNonces() throws {
        let key = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        let plaintext = Data("PasteLight encrypted manifest".utf8)
        let aad = Data("manifest-aad".utf8)
        let first = try PasteLightCrypto.encrypt(plaintext, using: key, aad: aad)
        let second = try PasteLightCrypto.encrypt(plaintext, using: key, aad: aad)

        #expect(first != second)
        #expect(try PasteLightCrypto.decrypt(first, using: key, aad: aad) == plaintext)

        var wrongKeyRejected = false
        do { _ = try PasteLightCrypto.decrypt(first, using: wrongKey, aad: aad) }
        catch { wrongKeyRejected = true }
        #expect(wrongKeyRejected)

        var wrongAADRejected = false
        do { _ = try PasteLightCrypto.decrypt(first, using: key, aad: Data("other".utf8)) }
        catch { wrongAADRejected = true }
        #expect(wrongAADRejected)

        var envelope = try JSONDecoder().decode(EncryptedEnvelope.self, from: first)
        var combined = envelope.combined
        combined[combined.startIndex + combined.count / 2] ^= 0x01
        envelope = EncryptedEnvelope(formatVersion: envelope.formatVersion, combined: combined)
        let tampered = try JSONEncoder().encode(envelope)
        var tamperRejected = false
        do { _ = try PasteLightCrypto.decrypt(tampered, using: key, aad: aad) }
        catch { tamperRejected = true }
        #expect(tamperRejected)
    }

    @Test func chunkedEncryptionRoundTripsAcrossOneMegabyteBoundaries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plaintext = Data(repeating: 0x5a, count: PasteLightCrypto.chunkSize * 2 + 17)
        let source = root.appendingPathComponent("source.bin")
        let encrypted = root.appendingPathComponent("payload.plblob")
        let restored = root.appendingPathComponent("restored.bin")
        try plaintext.write(to: source)
        let key = SymmetricKey(size: .bits256)
        let accountID = UUID()
        let objectID = "object-1"

        let encryptedHeader = try PasteLightCrypto.encryptFile(
            sourceURL: source,
            destinationURL: encrypted,
            objectID: objectID,
            accountID: accountID,
            key: key
        )
        let decryptedHeader = try PasteLightCrypto.decryptFile(
            sourceURL: encrypted,
            destinationURL: restored,
            expectedObjectID: objectID,
            accountID: accountID,
            key: key
        )

        #expect(encryptedHeader.plaintextByteCount == Int64(plaintext.count))
        #expect(decryptedHeader.plaintextDigest == encryptedHeader.plaintextDigest)
        #expect(try Data(contentsOf: restored) == plaintext)
    }

    @Test func mergeUsesHighestRevisionAndKeepsTombstones() {
        let firstDevice = UUID()
        let secondDevice = UUID()
        let itemID = UUID()
        var first = DeviceSyncManifest(deviceID: firstDevice, deviceName: "A")
        var second = DeviceSyncManifest(deviceID: secondDevice, deviceName: "B")
        first.records = [makeRecord(
            id: itemID,
            revision: SyncRevision(counter: 3, deviceID: firstDevice),
            content: "old",
            fingerprint: "text:same"
        )]
        second.records = [.tombstone(
            itemID: itemID,
            revision: SyncRevision(counter: 4, deviceID: secondDevice)
        )]

        let result = WebDAVRecordMerger.merge([first, second])

        #expect(result.visibleRecords.isEmpty)
        #expect(result.deletedItemIDs == [itemID])
        #expect(result.recordsByID[itemID]?.state == .tombstone)
    }

    @Test func mergeDeduplicatesDifferentUUIDsAndPrefersFavorite() {
        let deviceID = UUID()
        let recentID = UUID()
        let favoriteID = UUID()
        var manifest = DeviceSyncManifest(deviceID: deviceID, deviceName: "Mac")
        manifest.records = [
            makeRecord(
                id: recentID,
                revision: SyncRevision(counter: 1, deviceID: deviceID),
                content: "same",
                fingerprint: "text:same",
                timestamp: Date(timeIntervalSince1970: 200)
            ),
            makeRecord(
                id: favoriteID,
                revision: SyncRevision(counter: 2, deviceID: deviceID),
                content: "same",
                fingerprint: "text:same",
                timestamp: Date(timeIntervalSince1970: 100),
                favorite: true
            )
        ]

        let result = WebDAVRecordMerger.merge([manifest])

        #expect(result.visibleRecords.map(\.itemID) == [favoriteID])
        #expect(result.duplicateItemIDs == [recentID])
    }

    @Test func configurationJSONContainsNoPasswordsOrDerivedKeys() throws {
        let configuration = WebDAVConfiguration(
            serverURL: "https://dav.example.com",
            remotePath: "PasteLight",
            username: "ace",
            mode: .sync
        )
        let encoded = try JSONEncoder().encode(configuration)
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(!text.localizedCaseInsensitiveContains("password"))
        #expect(!text.localizedCaseInsensitiveContains("masterKey"))
        #expect(!text.localizedCaseInsensitiveContains("derivedKey"))
    }

    @Test func webDAVParsesNamespacedMultiStatusAndIgnoresMissingOptionalProperties() async throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/root/file.plenc</d:href>
            <d:propstat>
              <d:prop><d:getetag>"strong-1"</d:getetag><d:getcontentlength>42</d:getcontentlength></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
            <d:propstat>
              <d:prop><d:getlastmodified/></d:prop>
              <d:status>HTTP/1.1 404 Not Found</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "PROPFIND")
            #expect(request.value(forHTTPHeaderField: "Depth") == "1")
            return (207, ["Content-Type": "application/xml"], Data(xml.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let client = try makeClient()

        let resources = try await client.list(URL(string: "https://dav.example.com/root/")!, depth: 1)

        #expect(resources.count == 1)
        #expect(resources[0].etag == "\"strong-1\"")
        #expect(resources[0].contentLength == 42)
        #expect(resources[0].url.path == "/root/file.plenc")
    }

    @Test func webDAVRejectsResourcesEscapingRequestedCollection() async throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/other/device.manifest.plenc</d:href>
            <d:propstat>
              <d:prop><d:getetag>"strong-1"</d:getetag></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        StubURLProtocol.handler = { _ in
            (207, ["Content-Type": "application/xml"], Data(xml.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await makeClient().list(
                URL(string: "https://dav.example.com/root/")!,
                depth: 1
            )
            Issue.record("Expected escaped collection member to be rejected")
        } catch WebDAVFeatureError.invalidRemotePath {
            // Expected.
        }
    }

    @Test func webDAVMapsConditionalConflictAndQuotaErrors() async throws {
        let client = try makeClient()
        let url = URL(string: "https://dav.example.com/root/item")!

        StubURLProtocol.handler = { _ in (412, [:], Data()) }
        var conflictDetected = false
        do { _ = try await client.put(Data(), to: url, ifMatch: "\"old\"", ifNoneMatch: false) }
        catch WebDAVFeatureError.remoteConflict { conflictDetected = true }
        #expect(conflictDetected)

        StubURLProtocol.handler = { _ in (507, [:], Data()) }
        var quotaDetected = false
        do { _ = try await client.put(Data(), to: url, ifMatch: nil, ifNoneMatch: true) }
        catch WebDAVFeatureError.serverMessage(let message) { quotaDetected = message.contains("配额") }
        #expect(quotaDetected)
        StubURLProtocol.handler = nil
    }

    @Test func webDAVMapsAuthenticationPermissionPathAndMethodErrors() async throws {
        let client = try makeClient()
        let url = URL(string: "https://dav.example.com/root/item")!

        for status in [401, 403, 404, 405, 409] {
            StubURLProtocol.handler = { _ in (status, [:], Data()) }
            do {
                _ = try await client.get(url, maximumBytes: 16)
                Issue.record("Expected HTTP \(status) to fail")
            } catch WebDAVFeatureError.authenticationFailed {
                #expect(status == 401)
            } catch WebDAVFeatureError.serverMessage(let message) {
                #expect(status == 403 || status == 409)
                #expect(!message.isEmpty)
            } catch WebDAVFeatureError.unsupportedResponse(let received) {
                #expect(received == status)
                #expect(status == 404 || status == 405)
            }
        }
        StubURLProtocol.handler = nil
    }

    @Test func recursiveMKCOLAcceptsExistingCollectionAfter405() async throws {
        let client = try makeClient()
        let baseURL = URL(string: "https://dav.example.com/root/")!
        let targetURL = URL(string: "https://dav.example.com/root/first/second/")!
        var requests: [(method: String, path: String)] = []
        let collectionXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/root/first/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        StubURLProtocol.handler = { request in
            let method = request.httpMethod ?? ""
            let path = request.url?.path ?? ""
            requests.append((method, path))
            if method == "MKCOL", path == "/root/first" { return (405, [:], Data()) }
            if method == "PROPFIND", path == "/root/first" {
                return (207, ["Content-Type": "application/xml"], Data(collectionXML.utf8))
            }
            if method == "MKCOL", path == "/root/first/second" { return (201, [:], Data()) }
            return (500, [:], Data())
        }
        defer { StubURLProtocol.handler = nil }

        try await client.ensureCollection(targetURL, under: baseURL)

        #expect(requests.map(\.method) == ["MKCOL", "PROPFIND", "MKCOL"])
        #expect(requests.last?.path == "/root/first/second")
    }

    @Test func deleteRejectsFailedMemberInMultiStatus() async throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/root/locked.plblob</d:href>
            <d:status>HTTP/1.1 423 Locked</d:status>
          </d:response>
        </d:multistatus>
        """
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            return (207, ["Content-Type": "application/xml"], Data(xml.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            try await makeClient().delete(
                URL(string: "https://dav.example.com/root/locked.plblob")!,
                ignoreMissing: false
            )
            Issue.record("Expected failed DELETE member to be rejected")
        } catch WebDAVFeatureError.unsupportedResponse(let status) {
            #expect(status == 423)
        }
    }

    @Test func localStateDecodesWhenNewOptionalFieldsAreAbsent() throws {
        let configuration = WebDAVConfiguration(
            serverURL: "https://dav.example.com/root/",
            username: "ace",
            mode: .sync
        )
        let state = WebDAVLocalState(configuration: configuration)
        let encoded = try JSONEncoder().encode(state)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "appliedRevisions")
        object.removeValue(forKey: "orphanBlobFirstSeenAt")
        object.removeValue(forKey: "lastOrphanScanAt")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WebDAVLocalState.self, from: legacyData)

        #expect(decoded.appliedRevisions.isEmpty)
        #expect(decoded.orphanBlobFirstSeenAt?.isEmpty == true)
        #expect(decoded.lastOrphanScanAt == nil)
    }

    @Test func activationRepairsDuplicateUUIDsInLegacyLocalState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = root.appendingPathComponent("store", isDirectory: true)
        let stateRootURL = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let deviceID = UUID()
        let itemID = UUID()
        let configuration = WebDAVConfiguration(
            serverURL: "https://dav.example.com/root/",
            remotePath: "PasteLight-Duplicate-State-Test",
            username: "ace",
            mode: .sync,
            deviceID: deviceID,
            deviceName: "Legacy Mac"
        )
        var state = WebDAVLocalState(configuration: configuration)
        state.manifest.records = [
            makeRecord(
                id: itemID,
                revision: SyncRevision(counter: 1, deviceID: deviceID),
                content: "older",
                fingerprint: "text:duplicate"
            ),
            makeRecord(
                id: itemID,
                revision: SyncRevision(counter: 2, deviceID: deviceID),
                content: "newer",
                fingerprint: "text:duplicate"
            )
        ]
        state.manifest.lamportClock = 2
        state.hasPendingChanges = true

        let syncRoot = try #require(configuration.syncRootURL)
        let stateDigest = PasteLightCrypto.sha256Hex(Data(syncRoot.absoluteString.utf8))
        let stateURL = stateRootURL
            .appendingPathComponent(stateDigest, isDirectory: true)
            .appendingPathComponent("\(deviceID.uuidString).json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)

        let item = ClipboardItem(
            id: itemID,
            content: "newer",
            type: .text,
            timestamp: try #require(state.manifest.records.last?.timestamp),
            fingerprint: "text:duplicate"
        )
        let gate = OneShotAsyncGate()
        await gate.release()
        let client = InMemoryWebDAVClient(blobUploadGate: gate)
        let secrets = InMemoryWebDAVSecretStore()
        let coordinator = WebDAVSyncCoordinator(
            store: ClipboardStore(getCleanupDays: { 0 }, storageDirectory: storageURL),
            secrets: secrets,
            stateRootURL: stateRootURL,
            clientFactory: { _, _ in client },
            remoteBatchHandler: { _, _ in }
        )
        let activated = try await coordinator.activate(
            configuration: configuration,
            password: "webdav-password",
            passphrase: "PasteLight-Sync-Password",
            initialItems: [item]
        )
        try await coordinator.synchronize(currentItems: [item])

        let manifest = try await decodedManifest(
            client: client,
            configuration: activated,
            secrets: secrets
        )
        #expect(manifest.records.count == 1)
        #expect(manifest.records.first?.content == "newer")
        #expect(manifest.records.first?.revision.counter == 2)
    }

    @Test func mutationDuringBlobUploadIsPublishedOnlyAfterItsBlobIsReady() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = root.appendingPathComponent("store", isDirectory: true)
        let stateURL = root.appendingPathComponent("state", isDirectory: true)
        let firstPayloadURL = root.appendingPathComponent("first.png")
        let secondPayloadURL = root.appendingPathComponent("second.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 4096).write(to: firstPayloadURL)
        try Data(repeating: 0x22, count: 4096).write(to: secondPayloadURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstItem = ClipboardItem(
            id: UUID(),
            content: "first image",
            type: .image,
            timestamp: Date(),
            filePath: firstPayloadURL.path,
            fingerprint: "image:first"
        )
        let secondItem = ClipboardItem(
            id: UUID(),
            content: "second image",
            type: .image,
            timestamp: Date().addingTimeInterval(1),
            filePath: secondPayloadURL.path,
            fingerprint: "image:second"
        )
        let configuration = WebDAVConfiguration(
            serverURL: "https://dav.example.com/root/",
            remotePath: "PasteLight-Test",
            username: "ace",
            mode: .sync,
            deviceID: UUID(),
            deviceName: "Test Mac"
        )
        let uploadGate = OneShotAsyncGate()
        let client = InMemoryWebDAVClient(blobUploadGate: uploadGate)
        let secrets = InMemoryWebDAVSecretStore()
        let coordinator = WebDAVSyncCoordinator(
            store: ClipboardStore(getCleanupDays: { 0 }, storageDirectory: storageURL),
            secrets: secrets,
            stateRootURL: stateURL,
            clientFactory: { _, _ in client },
            remoteBatchHandler: { _, _ in }
        )
        let activated = try await coordinator.activate(
            configuration: configuration,
            password: "webdav-password",
            passphrase: "PasteLight-Sync-Password",
            initialItems: [firstItem]
        )

        let firstSync = Task {
            try await coordinator.synchronize(currentItems: [firstItem])
        }
        await uploadGate.waitUntilBlocked()
        _ = try await coordinator.record(.upsert(secondItem))
        await uploadGate.release()
        try await firstSync.value

        let firstManifest = try await decodedManifest(
            client: client,
            configuration: activated,
            secrets: secrets
        )
        #expect(firstManifest.records.map(\.itemID) == [firstItem.id])

        try await coordinator.synchronize(currentItems: [firstItem, secondItem])

        let secondManifest = try await decodedManifest(
            client: client,
            configuration: activated,
            secrets: secrets
        )
        #expect(Set(secondManifest.records.map(\.itemID)) == [firstItem.id, secondItem.id])
        for record in secondManifest.records {
            let remoteID = try #require(record.payload?.remoteID)
            let blobURL = try #require(activated.syncRootURL)
                .appendingPathComponent("blobs", isDirectory: true)
                .appendingPathComponent("\(remoteID).plblob")
            #expect(try await client.exists(blobURL))
        }
    }

    @Test func backupRetentionAndRepeatedRestoreAreSafeAndIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = root.appendingPathComponent("store", isDirectory: true)
        let stateURL = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let item = ClipboardItem(
            id: UUID(),
            content: "encrypted backup text",
            type: .text,
            timestamp: Date(),
            fingerprint: "text:backup"
        )
        let store = ClipboardStore(getCleanupDays: { 0 }, storageDirectory: storageURL)
        let storedItem = store.saveItem(item)
        let gate = OneShotAsyncGate()
        await gate.release()
        let client = InMemoryWebDAVClient(blobUploadGate: gate)
        let coordinator = WebDAVSyncCoordinator(
            store: store,
            secrets: InMemoryWebDAVSecretStore(),
            stateRootURL: stateURL,
            clientFactory: { _, _ in client },
            remoteBatchHandler: { _, _ in }
        )
        _ = try await coordinator.activate(
            configuration: WebDAVConfiguration(
                serverURL: "https://dav.example.com/root/",
                remotePath: "PasteLight-Backup-Test",
                username: "ace",
                mode: .backup,
                deviceID: UUID(),
                deviceName: "Backup Mac"
            ),
            password: "webdav-password",
            passphrase: "PasteLight-Sync-Password",
            initialItems: [storedItem]
        )

        for _ in 0..<8 {
            try await coordinator.createBackup(currentItems: [storedItem], automatic: false)
        }
        let retained = try await coordinator.listBackups()
        #expect(retained.count == 7)

        try await coordinator.createBackup(currentItems: [storedItem], automatic: true)
        #expect(try await coordinator.listBackups().count == 7)

        #expect(store.deleteItem(storedItem))
        let backup = try #require(retained.first)
        try await coordinator.restoreBackup(backup, currentItems: [])
        let afterFirstRestore = store.loadItems()
        try await coordinator.restoreBackup(backup, currentItems: afterFirstRestore)
        let afterSecondRestore = store.loadItems()

        #expect(afterFirstRestore.map(\.id) == [storedItem.id])
        #expect(afterSecondRestore.map(\.id) == [storedItem.id])
    }

    @Test func verifiedRemoteBatchPublishesPayloadAndIndexesTogether() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer {
            try? FileManager.default.removeItem(at: storageURL)
            try? FileManager.default.removeItem(at: payloadURL)
        }
        let payload = Data(repeating: 0x4f, count: 4096)
        try payload.write(to: payloadURL)

        let store = ClipboardStore(getCleanupDays: { 0 }, storageDirectory: storageURL)
        let oldItem = ClipboardItem(
            id: UUID(),
            content: "old",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let storedOldItem = store.saveItem(oldItem)
        let remoteItem = ClipboardItem(
            id: UUID(),
            content: "remote image",
            type: .image,
            timestamp: Date(timeIntervalSince1970: 200),
            fingerprint: "image:remote"
        )

        let imported = try store.applyRemoteSyncBatch(
            imports: [(remoteItem, payloadURL, .image)],
            deleting: [storedOldItem],
            currentItems: [storedOldItem]
        )

        let stored = try #require(imported.first)
        let storedPath = try #require(stored.filePath)
        #expect(store.loadItems().map(\.id) == [remoteItem.id])
        #expect(try Data(contentsOf: URL(fileURLWithPath: storedPath)) == payload)
    }

    @Test func verifiedRemoteBatchRejectsCorruptLocalIndexBeforePublishing() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let store = ClipboardStore(getCleanupDays: { 0 }, storageDirectory: storageURL)
        let timestamp = Date(timeIntervalSince1970: 100)
        let current = store.saveItem(ClipboardItem(
            id: UUID(),
            content: "current",
            type: .text,
            timestamp: timestamp
        ))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let indexURL = storageURL
            .appendingPathComponent(formatter.string(from: timestamp), isDirectory: true)
            .appendingPathComponent("items.json")
        let corrupted = Data("not-json".utf8)
        try corrupted.write(to: indexURL, options: .atomic)

        var rejected = false
        do {
            _ = try store.applyRemoteSyncBatch(
                imports: [(ClipboardItem(
                    id: UUID(),
                    content: "remote",
                    type: .text,
                    timestamp: timestamp
                ), nil, nil)],
                deleting: [current],
                currentItems: [current]
            )
        } catch {
            rejected = true
        }

        #expect(rejected)
        #expect(try Data(contentsOf: indexURL) == corrupted)
    }

    @Test func strongETagValidationRejectsWeakValues() {
        #expect(WebDAVHTTPClient.isStrongETag("\"abc\""))
        #expect(!WebDAVHTTPClient.isStrongETag("W/\"abc\""))
        #expect(!WebDAVHTTPClient.isStrongETag("abc"))
    }

    private func makeClient() throws -> WebDAVHTTPClient {
        let configuration = WebDAVConfiguration(
            serverURL: "https://dav.example.com/root/",
            username: "ace"
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        return try WebDAVHTTPClient(
            configuration: configuration,
            credential: WebDAVCredential(username: "ace", password: "secret"),
            sessionConfiguration: sessionConfiguration
        )
    }

    private func makeRecord(
        id: UUID,
        revision: SyncRevision,
        content: String,
        fingerprint: String,
        timestamp: Date = Date(),
        favorite: Bool = false
    ) -> SyncRecord {
        SyncRecord(
            itemID: id,
            revision: revision,
            state: .upsert,
            type: .text,
            content: content,
            timestamp: timestamp,
            isFavorite: favorite,
            fingerprint: fingerprint,
            payload: nil
        )
    }

    private func decodedManifest(
        client: InMemoryWebDAVClient,
        configuration: WebDAVConfiguration,
        secrets: InMemoryWebDAVSecretStore
    ) async throws -> DeviceSyncManifest {
        let accountID = try #require(configuration.accountID)
        let key = try #require(secrets.masterKey(accountID: accountID))
        let root = try #require(configuration.syncRootURL)
        let manifestURL = root
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(configuration.deviceID.uuidString).manifest.plenc")
        let encrypted = try #require(await client.storedData(at: manifestURL))
        let aad = Data(
            "PasteLight|manifest|1|\(accountID.uuidString)|\(configuration.deviceID.uuidString)".utf8
        )
        let plaintext = try PasteLightCrypto.decrypt(encrypted, using: key, aad: aad)
        return try JSONDecoder().decode(DeviceSyncManifest.self, from: plaintext)
    }
}

private final class InMemoryWebDAVSecretStore: WebDAVSecretStoring {
    private var credentials: [String: WebDAVCredential] = [:]
    private var keys: [UUID: SymmetricKey] = [:]

    func saveCredential(_ credential: WebDAVCredential, for configuration: WebDAVConfiguration) throws {
        credentials[configuration.deviceID.uuidString] = credential
    }

    func credential(for configuration: WebDAVConfiguration) -> WebDAVCredential? {
        credentials[configuration.deviceID.uuidString]
    }

    func deleteCredential(for configuration: WebDAVConfiguration) {
        credentials.removeValue(forKey: configuration.deviceID.uuidString)
    }

    func saveMasterKey(_ key: SymmetricKey, accountID: UUID) throws {
        keys[accountID] = key
    }

    func masterKey(accountID: UUID) -> SymmetricKey? { keys[accountID] }
    func deleteMasterKey(accountID: UUID) { keys.removeValue(forKey: accountID) }
}

private actor OneShotAsyncGate {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockOnce() async {
        guard !isReleased else { return }
        isBlocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor InMemoryWebDAVClient: WebDAVClientProtocol {
    private var objects: [String: Data] = [:]
    private var etags: [String: String] = [:]
    private var collections = Set<String>()
    private var etagCounter = 0
    private let blobUploadGate: OneShotAsyncGate
    private var didBlockBlobUpload = false

    init(blobUploadGate: OneShotAsyncGate) {
        self.blobUploadGate = blobUploadGate
    }

    func testConnection(baseURL: URL, requireStrongETag: Bool) async throws {}
    func ensureCollection(_ collectionURL: URL, under baseURL: URL) async throws {
        collections.insert(collectionURL.absoluteString)
    }

    func list(_ collectionURL: URL, depth: Int) async throws -> [WebDAVResource] {
        if let data = objects[collectionURL.absoluteString] {
            return [resource(url: collectionURL, data: data)]
        }
        if depth == 0, collections.contains(collectionURL.absoluteString) {
            return [WebDAVResource(
                url: collectionURL,
                isCollection: true,
                etag: nil,
                contentLength: nil,
                lastModified: nil
            )]
        }
        guard depth == 1 else { return [] }
        let parentPath = normalizedDirectoryPath(collectionURL)
        var resources = collections.compactMap { entry -> WebDAVResource? in
            guard let url = URL(string: entry),
                  normalizedDirectoryPath(url) != parentPath,
                  normalizedDirectoryPath(url.deletingLastPathComponent()) == parentPath else {
                return nil
            }
            return WebDAVResource(
                url: url,
                isCollection: true,
                etag: nil,
                contentLength: nil,
                lastModified: nil
            )
        }
        resources.append(contentsOf: objects.compactMap { entry in
            guard let url = URL(string: entry.key),
                  normalizedDirectoryPath(url.deletingLastPathComponent()) == parentPath else {
                return nil
            }
            return resource(url: url, data: entry.value)
        })
        return resources
    }

    func get(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard let data = objects[url.absoluteString] else {
            throw WebDAVFeatureError.unsupportedResponse(404)
        }
        guard data.count <= maximumBytes else { throw WebDAVFeatureError.payloadTooLarge }
        return data
    }

    func download(_ url: URL, to destinationURL: URL, maximumBytes: Int64) async throws {
        let data = try await get(url, maximumBytes: Int(maximumBytes))
        try data.write(to: destinationURL, options: .atomic)
    }

    func put(
        _ data: Data,
        to url: URL,
        ifMatch: String?,
        ifNoneMatch: Bool
    ) async throws -> WebDAVResponse {
        let key = url.absoluteString
        if ifNoneMatch, objects[key] != nil { throw WebDAVFeatureError.remoteConflict }
        if let ifMatch, etags[key] != ifMatch { throw WebDAVFeatureError.remoteConflict }
        etagCounter += 1
        let etag = "\"etag-\(etagCounter)\""
        objects[key] = data
        etags[key] = etag
        return WebDAVResponse(statusCode: objects[key] == nil ? 201 : 200, etag: etag)
    }

    func putFile(
        _ fileURL: URL,
        to url: URL,
        ifMatch: String?,
        ifNoneMatch: Bool
    ) async throws -> WebDAVResponse {
        if url.path.contains("/blobs/"), !didBlockBlobUpload {
            didBlockBlobUpload = true
            await blobUploadGate.blockOnce()
        }
        return try await put(
            Data(contentsOf: fileURL),
            to: url,
            ifMatch: ifMatch,
            ifNoneMatch: ifNoneMatch
        )
    }

    func delete(_ url: URL, ignoreMissing: Bool) async throws {
        let key = url.absoluteString
        if objects.removeValue(forKey: key) == nil, !ignoreMissing {
            throw WebDAVFeatureError.unsupportedResponse(404)
        }
        etags.removeValue(forKey: key)
    }

    func exists(_ url: URL) async throws -> Bool { objects[url.absoluteString] != nil }
    func storedData(at url: URL) -> Data? { objects[url.absoluteString] }

    private func resource(url: URL, data: Data) -> WebDAVResource {
        WebDAVResource(
            url: url,
            isCollection: false,
            etag: etags[url.absoluteString],
            contentLength: Int64(data.count),
            lastModified: Date()
        )
    }

    private func normalizedDirectoryPath(_ url: URL) -> String {
        url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (status, headers, data) = try handler(request)
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class CountingImageDataProvider: ClipboardImageDataProviding {
    let types: [NSPasteboard.PasteboardType]?
    private let payloads: [NSPasteboard.PasteboardType: Data]
    private(set) var readCount = 0

    init(
        types: [NSPasteboard.PasteboardType],
        payloads: [NSPasteboard.PasteboardType: Data]
    ) {
        self.types = types
        self.payloads = payloads
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        readCount += 1
        return payloads[type]
    }
}
