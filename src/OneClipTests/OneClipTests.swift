//
//  OneClipTests.swift
//  OneClipTests
//
//  Created by Wcowin on 2025/8/12.
//

import Testing
@testable import OneClip

struct OneClipTests {

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

}
