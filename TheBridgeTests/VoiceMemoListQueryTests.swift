// VoiceMemoListQueryTests.swift — list filters + pagination (Voice Memo Reliability)
// TheBridge · Tests

import Foundation
import TheBridgeLib

func runVoiceMemoListQueryTests() async {
    print("\n📋 VoiceMemoListQuery Tests")

    // Local fixtures rebuilt inside each test body so closures stay Sendable.
    func makePool() -> (pool: [VoiceMemoRecording], isProcessed: @Sendable (String) -> Bool) {
        func rec(id: String, title: String, daysAgo: Int, transcript: String? = nil) -> VoiceMemoRecording {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
            return VoiceMemoRecording(
                id: id,
                path: "/tmp/\(id).m4a",
                title: title,
                recordedAt: date,
                transcript: transcript,
                transcriptSource: transcript == nil ? .none : .sidecar
            )
        }
        let pool = [
            rec(id: "p1", title: "Old done", daysAgo: 30, transcript: "done body"),
            rec(id: "u1", title: "July memo", daysAgo: 8, transcript: "greg flicek follow up"),
            rec(id: "u2", title: "June memo", daysAgo: 40, transcript: "unrelated"),
            rec(id: "u3", title: "No transcript", daysAgo: 2),
            rec(id: "u4", title: "Recent", daysAgo: 1, transcript: "short"),
        ]
        let isProcessed: @Sendable (String) -> Bool = { $0 == "p1" }
        return (pool, isProcessed)
    }

    await test("list filter: default excludes processed and pages with default limit") {
        let (pool, isProcessed) = makePool()
        let page = VoiceMemoListFilter.page(
            recordings: pool,
            query: VoiceMemoListQuery(limit: 2),
            isProcessed: isProcessed
        )
        try expect(page.totalMatched == 4, "unprocessed only → 4, got \(page.totalMatched)")
        try expect(page.memos.count == 2, "limit 2")
        try expect(page.hasMore, "hasMore")
        try expect(page.nextCursor != nil, "nextCursor present")
        try expect(page.memos.first?.id == "u4", "newest first, got \(page.memos.first?.id ?? "?")")
    }

    await test("list filter: cursor resumes after prior page") {
        let (pool, isProcessed) = makePool()
        let page1 = VoiceMemoListFilter.page(recordings: pool, query: VoiceMemoListQuery(limit: 2), isProcessed: isProcessed)
        let page2 = VoiceMemoListFilter.page(
            recordings: pool,
            query: VoiceMemoListQuery(limit: 2, cursor: page1.nextCursor),
            isProcessed: isProcessed
        )
        try expect(page2.memos.count == 2, "second page size")
        let ids1 = Set(page1.memos.map(\.id))
        let ids2 = Set(page2.memos.map(\.id))
        try expect(ids1.isDisjoint(with: ids2), "pages must not overlap: \(ids1) vs \(ids2)")
    }

    await test("list filter: dateFrom/dateTo scopes to window") {
        let (pool, isProcessed) = makePool()
        let from = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
        let to = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
        let page = VoiceMemoListFilter.page(
            recordings: pool,
            query: VoiceMemoListQuery(includeProcessed: true, dateFrom: from, dateTo: to),
            isProcessed: isProcessed
        )
        try expect(page.totalMatched == 1, "only July memo in window, got \(page.totalMatched)")
        try expect(page.memos.first?.id == "u1", "got \(page.memos.first?.id ?? "?")")
    }

    await test("list filter: hasTranscript + transcriptContains") {
        let (pool, isProcessed) = makePool()
        let page = VoiceMemoListFilter.page(
            recordings: pool,
            query: VoiceMemoListQuery(hasTranscript: true, transcriptContains: "Greg"),
            isProcessed: isProcessed
        )
        try expect(page.totalMatched == 1, "greg match")
        try expect(page.memos.first?.id == "u1", "got \(page.memos.first?.id ?? "?")")
    }

    await test("list filter: sort ascending") {
        let (pool, isProcessed) = makePool()
        let page = VoiceMemoListFilter.page(
            recordings: pool,
            query: VoiceMemoListQuery(limit: 10, sortAscending: true),
            isProcessed: isProcessed
        )
        try expect(page.memos.first?.id == "u2", "oldest unprocessed first, got \(page.memos.first?.id ?? "?")")
    }

    await test("list cursor encode/decode round-trip") {
        let (pool, _) = makePool()
        let r = pool[0]
        let c = VoiceMemoListFilter.encodeCursor(r)
        let decoded = VoiceMemoListFilter.decodeCursor(c)
        try expect(decoded?.id == r.id, "id round-trip")
        try expect(decoded != nil, "decode ok")
    }
}
