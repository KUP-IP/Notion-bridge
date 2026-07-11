import Foundation

/// Build-time source provenance stamped into the packaged app's Info.plist.
/// Raw SwiftPM/test binaries have no packaged plist seam and therefore report
/// the explicit `unknown` fallback instead of probing git at runtime (a
/// notarized app may not have a repository checkout at all).
public struct BuildProvenance: Sendable, Equatable {
    public static let gitSHAInfoKey = "BridgeGitSHA"
    public static let gitDirtyInfoKey = "BridgeGitDirty"

    public let gitSHA: String
    public let gitDirty: Bool

    public init(gitSHA: String, gitDirty: Bool) {
        self.gitSHA = gitSHA
        self.gitDirty = gitDirty
    }

    public static var current: BuildProvenance {
        from(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    public static func from(infoDictionary: [String: Any]) -> BuildProvenance {
        let rawSHA = (infoDictionary[gitSHAInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = (rawSHA?.isEmpty == false) ? rawSHA! : "unknown"
        let dirty = infoDictionary[gitDirtyInfoKey] as? Bool ?? false
        return BuildProvenance(gitSHA: sha, gitDirty: dirty)
    }
}
