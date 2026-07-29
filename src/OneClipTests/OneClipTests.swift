//
//  OneClipTests.swift
//  OneClipTests
//
//  Created by Wcowin on 2025/8/12.
//

import AppKit
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
