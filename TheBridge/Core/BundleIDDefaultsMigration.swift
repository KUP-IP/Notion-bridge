// BundleIDDefaultsMigration.swift — W5B: copy UserDefaults from prior CFBundleIdentifier
//
// Changing CFBundleIdentifier gives the process a fresh `UserDefaults.standard`
// suite. Without a one-time copy, feature flags (credentials, tunnel URL,
// module grants, onboarding) reset to first-launch defaults and look like data
// loss even though Keychain + Application Support are intact.
//
// Properties:
//   • Idempotent — sentinel key in the *current* suite; second launch no-ops.
//   • One-shot prefer-prior — on the cutover launch, prior-suite values win for
//     every key present there (the new suite is otherwise a false fresh install).
//   • Scoped — only runs when current id is `kup.solutions.the-bridge`.

import Foundation

public enum BundleIDDefaultsMigration: Sendable {

    public static let priorBundleID = "kup.solutions.notion-bridge"
    public static let canonicalBundleID = "kup.solutions.the-bridge"
    public static let sentinelKey = "com.notionbridge.bundleIdDefaultsMigration.w5b"

    public struct Report: Equatable, Sendable {
        public let keysCopied: Int
        public let alreadyComplete: Bool
        public let skipped: Bool

        public static let noopComplete = Report(keysCopied: 0, alreadyComplete: true, skipped: false)
        public static let noopSkipped = Report(keysCopied: 0, alreadyComplete: false, skipped: true)
    }

    /// Read the prior app's persistent domain (production default).
    public static func loadPriorPersistentDomain(
        suiteName: String = priorBundleID
    ) -> [String: Any]? {
        UserDefaults(suiteName: suiteName)?.persistentDomain(forName: suiteName)
    }

    /// Copy keys from the prior bundle-id suite into `current` (one shot).
    /// Safe to call every launch.
    @discardableResult
    public static func runOnce(
        currentBundleID: String? = Bundle.main.bundleIdentifier,
        current: UserDefaults = .standard,
        priorDomain: [String: Any]? = nil,
        log: (String) -> Void = { print("[BundleIDDefaultsMigration] \($0)") }
    ) -> Report {
        guard let currentID = currentBundleID else {
            return .noopSkipped
        }
        guard currentID == canonicalBundleID else {
            return .noopSkipped
        }
        if current.bool(forKey: sentinelKey) {
            return .noopComplete
        }

        let domain = priorDomain ?? loadPriorPersistentDomain()
        guard let domain, !domain.isEmpty else {
            current.set(true, forKey: sentinelKey)
            log("no prior suite content; sentinel set")
            return Report(keysCopied: 0, alreadyComplete: false, skipped: false)
        }

        var copied = 0
        for key in domain.keys.sorted() where key != sentinelKey {
            current.set(domain[key], forKey: key)
            copied += 1
        }

        current.set(true, forKey: sentinelKey)
        current.synchronize()
        log("copied \(copied) key(s) from \(priorBundleID)")
        return Report(keysCopied: copied, alreadyComplete: false, skipped: false)
    }
}
