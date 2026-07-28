//
//  OneClipTests.swift
//  OneClipTests
//
//  Created by Wcowin on 2025/8/12.
//

import Testing
@testable import OneClip

struct OneClipTests {

    @Test func officeVMLRulesAreRemovedFromClipboardText() {
        let source = """
        v\\:* {behavior:url(#default#VML);} o\\:* {behavior:url(#default#VML);} x\\:* {behavior:url(#default#VML);} .shape {behavior:url(#default#VML);}
        系统架构图（图片放大后清晰）
        """

        #expect(ClipboardTextSanitizer.clean(source) == "系统架构图（图片放大后清晰）")
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

}
