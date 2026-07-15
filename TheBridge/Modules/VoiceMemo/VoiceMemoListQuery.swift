// VoiceMemoListQuery.swift — filtered/paginated list for voice_memo_list
// TheBridge · Modules · VoiceMemo
//
// Voice Memo Reliability packet (Ship The Bridge v4): unbounded
// `voice_memo_list` returned 200+ memos forcing client-side date filtering.
// This pure helper applies date range, processed-state, transcript presence,
// text contains, sort, limit, and opaque cursor — no disk I/O of its own.

import Foundation

public struct VoiceMemoListQuery: Sendable, Equatable {
    public var includeProcessed: Bool
    /// Max rows to return (clamped 1...500). Nil → default 50.
    public var limit: Int?
    /// Opaque cursor from a prior response (`nextCursor`).
    public var cursor: String?
    public var dateFrom: Date?
    public var dateTo: Date?
    public var hasTranscript: Bool?
    public var transcriptContains: String?
    /// Default newest-first (`false`).
    public var sortAscending: Bool

    public static let defaultLimit = 50
    public static let maxLimit = 500

    public init(
        includeProcessed: Bool = false,
        limit: Int? = nil,
        cursor: String? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        hasTranscript: Bool? = nil,
        transcriptContains: String? = nil,
        sortAscending: Bool = false
    ) {
        self.includeProcessed = includeProcessed
        self.limit = limit
        self.cursor = cursor
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.hasTranscript = hasTranscript
        self.transcriptContains = transcriptContains
        self.sortAscending = sortAscending
    }

    public var effectiveLimit: Int {
        let raw = limit ?? Self.defaultLimit
        return min(max(raw, 1), Self.maxLimit)
    }
}

public struct VoiceMemoListPage: Sendable, Equatable {
    public let memos: [VoiceMemoRecording]
    public let totalMatched: Int
    public let nextCursor: String?
    public let hasMore: Bool

    public init(memos: [VoiceMemoRecording], totalMatched: Int, nextCursor: String?, hasMore: Bool) {
        self.memos = memos
        self.totalMatched = totalMatched
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public enum VoiceMemoListFilter {

    /// Apply query filters + pagination over a pre-discovered recording set.
    /// `isProcessed` is injected so tests can stub the processed store.
    public static func page(
        recordings: [VoiceMemoRecording],
        query: VoiceMemoListQuery,
        isProcessed: (String) -> Bool = { VoiceMemoProcessedStore.isProcessed(id: $0) }
    ) -> VoiceMemoListPage {
        var filtered = recordings.filter { rec in
            if !query.includeProcessed, isProcessed(rec.id) { return false }
            if let from = query.dateFrom, rec.recordedAt < from { return false }
            if let to = query.dateTo, rec.recordedAt > to { return false }
            if let wantTranscript = query.hasTranscript, rec.hasTranscript != wantTranscript { return false }
            if let needle = query.transcriptContains?.trimmingCharacters(in: .whitespacesAndNewlines),
               !needle.isEmpty {
                let hay = ((rec.transcript ?? "") + " " + rec.title)
                    .lowercased()
                if !hay.contains(needle.lowercased()) { return false }
            }
            return true
        }

        filtered.sort {
            if query.sortAscending {
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                return $0.id < $1.id
            } else {
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
                return $0.id > $1.id
            }
        }

        let total = filtered.count
        let start: Int
        if let cursor = query.cursor, let decoded = decodeCursor(cursor) {
            if let idx = filtered.firstIndex(where: {
                $0.id == decoded.id && abs($0.recordedAt.timeIntervalSince(decoded.recordedAt)) < 1.0
            }) {
                start = idx + 1
            } else {
                // Cursor not found: treat as start of list (idempotent resume).
                start = 0
            }
        } else {
            start = 0
        }

        let limit = query.effectiveLimit
        guard start < filtered.count else {
            return VoiceMemoListPage(memos: [], totalMatched: total, nextCursor: nil, hasMore: false)
        }
        let end = min(start + limit, filtered.count)
        let slice = Array(filtered[start..<end])
        let hasMore = end < filtered.count
        let next: String? = hasMore ? encodeCursor(slice.last!) : nil
        return VoiceMemoListPage(memos: slice, totalMatched: total, nextCursor: next, hasMore: hasMore)
    }

    // Cursor: base64url("ISO8601|id")
    public static func encodeCursor(_ rec: VoiceMemoRecording) -> String {
        let iso = ISO8601DateFormatter().string(from: rec.recordedAt)
        let raw = "\(iso)|\(rec.id)"
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeCursor(_ cursor: String) -> (recordedAt: Date, id: String)? {
        var b64 = cursor
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let date = ISO8601DateFormatter().date(from: parts[0]) else { return nil }
        return (date, parts[1])
    }
}

