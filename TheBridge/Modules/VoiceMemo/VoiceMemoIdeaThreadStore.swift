// VoiceMemoIdeaThreadStore.swift — idea-comment ledger (PKT-MEM-136 / D48 / D50)
// TheBridge · Modules · VoiceMemo
//
// A small local JSON manifest tracking `idea`-purpose comments posted by
// `VoiceMemoProcessor.executeComment`, following the exact same load/save/
// enqueue shape as `VoiceMemoReviewStore` / `VoiceMemoProcessedStore` (D50 —
// "matches the existing local-state convention already proven twice in this
// module; avoids introducing a new registry entity or a different storage
// paradigm for a small piece of durable state").
//
// `reflow`-purpose comments are posted the same way (via
// `notion_comment_create`) but are NEVER logged here — fire-and-forget (D48).
// Sign-off (`signedOffAt`) is fully agent/manual-initiated for v1; no
// automatic trigger writes it (D51 — Scope OUT for this packet).

import Foundation

/// One idea-comment ledger entry (D50 exact shape).
public struct VoiceMemoIdeaThreadEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var memoId: String
    public var discussionId: String
    public var targetEntityKey: String
    public var targetPageId: String
    public var postedAt: String
    /// Nullable — set only by an explicit, agent-initiated sign-off (D51: no
    /// automatic trigger in v1). `nil` means the thread is still open.
    public var signedOffAt: String?

    public init(
        id: String = UUID().uuidString,
        memoId: String,
        discussionId: String,
        targetEntityKey: String,
        targetPageId: String,
        postedAt: String = ISO8601DateFormatter().string(from: Date()),
        signedOffAt: String? = nil
    ) {
        self.id = id
        self.memoId = memoId
        self.discussionId = discussionId
        self.targetEntityKey = targetEntityKey
        self.targetPageId = targetPageId
        self.postedAt = postedAt
        self.signedOffAt = signedOffAt
    }
}

public struct VoiceMemoIdeaThreadManifest: Codable, Sendable, Equatable {
    public var entries: [VoiceMemoIdeaThreadEntry]

    public init(entries: [VoiceMemoIdeaThreadEntry] = []) {
        self.entries = entries
    }

    public var openCount: Int {
        entries.filter { $0.signedOffAt == nil }.count
    }
}

/// Mirrors `VoiceMemoReviewStore`'s load/save/enqueue shape (D50 impact note).
/// File lives alongside `review.json` / `processed.json` in the same
/// `.voiceMemos` support subdirectory.
public enum VoiceMemoIdeaThreadStore {
    public static var manifestURL: URL {
        BridgePaths.applicationSupport(.voiceMemos).appendingPathComponent("idea-threads.json")
    }

    public static func load() -> VoiceMemoIdeaThreadManifest {
        let url = manifestURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(VoiceMemoIdeaThreadManifest.self, from: data) else {
            return VoiceMemoIdeaThreadManifest()
        }
        return decoded
    }

    public static func save(_ manifest: VoiceMemoIdeaThreadManifest) throws {
        let dir = manifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    /// Append one idea-comment entry. Not deduped — a memo may legitimately
    /// post more than one idea comment (e.g. to distinct target pages), and
    /// each is its own durable thread.
    @discardableResult
    public static func enqueue(_ entry: VoiceMemoIdeaThreadEntry) throws -> VoiceMemoIdeaThreadEntry {
        var manifest = load()
        manifest.entries.insert(entry, at: 0)
        try save(manifest)
        return entry
    }

    public static func openEntries() -> [VoiceMemoIdeaThreadEntry] {
        load().entries.filter { $0.signedOffAt == nil }
    }
}
