// RoutingCustodyStore.swift
//
// Durable, content-free custody for routing bootstrap and verified-principal
// continuation. Client route acknowledgements intentionally do NOT live here:
// they are connection-scoped and remain in ToolRouter memory.

import CryptoKit
import Foundation
import MCP

public struct RoutingAcknowledgementReceipt: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let authorityIDs: [String]
    public let scopeID: String
    public let principalDigest: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let nonce: String

    public init(
        authorityIDs: [String],
        scopeID: String,
        principalDigest: String,
        issuedAt: Date,
        expiresAt: Date,
        nonce: String = UUID().uuidString.lowercased()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.authorityIDs = authorityIDs.sorted()
        self.scopeID = scopeID
        self.principalDigest = principalDigest
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.nonce = nonce
    }

    public var value: Value {
        .object([
            "schemaVersion": .int(schemaVersion),
            "authorityIDs": .array(authorityIDs.map(Value.string)),
            "scopeID": .string(scopeID),
            "principalDigest": .string(principalDigest),
            "issuedAt": .string(Self.iso(issuedAt)),
            "expiresAt": .string(Self.iso(expiresAt)),
            "nonce": .string(nonce),
        ])
    }

    public static func parse(_ value: Value) -> RoutingAcknowledgementReceipt? {
        guard case .object(let object) = value,
              case .int(let schemaVersion)? = object["schemaVersion"],
              schemaVersion == Self.schemaVersion,
              case .array(let authorities)? = object["authorityIDs"],
              case .string(let scopeID)? = object["scopeID"],
              case .string(let principalDigest)? = object["principalDigest"],
              case .string(let issuedAt)? = object["issuedAt"],
              case .string(let expiresAt)? = object["expiresAt"],
              case .string(let nonce)? = object["nonce"],
              let issued = isoFormatter.date(from: issuedAt),
              let expires = isoFormatter.date(from: expiresAt)
        else { return nil }
        let ids = authorities.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
        guard ids.count == authorities.count, !ids.isEmpty else { return nil }
        return RoutingAcknowledgementReceipt(
            authorityIDs: ids,
            scopeID: scopeID,
            principalDigest: principalDigest,
            issuedAt: issued,
            expiresAt: expires,
            nonce: nonce
        )
    }

    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
    private static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

public struct ServerRoutingReadiness: Codable, Sendable, Equatable {
    public let snapshotDigest: String
    public let source: String
    public let count: Int
    public let verifiedAt: Date

    public init(snapshotDigest: String, source: String, count: Int, verifiedAt: Date) {
        self.snapshotDigest = snapshotDigest
        self.source = source
        self.count = count
        self.verifiedAt = verifiedAt
    }
}

public struct PrincipalRoutingContinuation: Codable, Sendable, Equatable {
    public let principalDigest: String
    public let authorityID: String
    public let snapshotDigest: String
    public let continuedAt: Date
}

public enum RoutingCustodyError: Error, LocalizedError, Equatable {
    case corrupt(String)
    case injectedFailure(RoutingCustodyStore.TestFaultPoint)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let detail): return "Routing custody is corrupt: \(detail)"
        case .injectedFailure(let point): return "Injected routing-custody failure at \(point.rawValue)"
        }
    }
}

/// Atomic, schema-versioned store with checksum validation and prior-valid
/// recovery. Payloads contain identifiers/digests only; no doctrine, message,
/// command, or other user-authored body is persisted.
public final class RoutingCustodyStore: @unchecked Sendable {
    public static let shared = RoutingCustodyStore()
    public static let schemaVersion = 1

    public enum TestFaultPoint: String, Sendable, Equatable {
        case beforeRevisionFinalize
        case beforeActivation
    }

    private let lock = NSLock()
    private let root: URL
    private var faultPoint: TestFaultPoint?

    public init(root: URL = BridgePaths.applicationSupport(.routingCustody)) {
        self.root = root
    }

    private var revisionsRoot: URL { root.appendingPathComponent("revisions", isDirectory: true) }
    private var stateURL: URL { root.appendingPathComponent("state.json") }

    public func serverReadiness() throws -> ServerRoutingReadiness? {
        lock.lock(); defer { lock.unlock() }
        return try readableSnapshotLocked()?.serverRoutingReady
    }

    public func hasPrincipalContinuation(_ principalKey: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot = try readableSnapshotLocked() else { return false }
        return snapshot.principalContinuations[Self.principalDigest(principalKey)] != nil
    }

    @discardableResult
    public func recordBootstrap(
        snapshotID: String,
        source: String,
        count: Int,
        verifiedAt: Date = Date()
    ) throws -> ServerRoutingReadiness {
        guard count > 0 else { throw RoutingCustodyError.corrupt("zero routing skills cannot be ready") }
        lock.lock(); defer { lock.unlock() }
        var snapshot = try mutableSnapshotLocked()
        if let existing = snapshot.serverRoutingReady,
           existing.snapshotDigest == Self.digest("routing-snapshot:\(snapshotID)"),
           existing.source == source,
           existing.count == count {
            return existing
        }
        let readiness = ServerRoutingReadiness(
            snapshotDigest: Self.digest("routing-snapshot:\(snapshotID)"),
            source: source,
            count: count,
            verifiedAt: verifiedAt
        )
        snapshot.serverRoutingReady = readiness
        // Continuations are bound to the routing authority snapshot that
        // was verified when they were issued. A changed snapshot requires
        // a fresh bridge_initialize before principal continuation resumes.
        snapshot.principalContinuations = snapshot.principalContinuations.filter {
            $0.value.snapshotDigest == readiness.snapshotDigest
        }
        try publishLocked(snapshot)
        return readiness
    }

    public func recordPrincipalContinuation(
        principalKey: String,
        authorityID: String,
        at date: Date = Date()
    ) throws {
        let digest = Self.principalDigest(principalKey)
        lock.lock(); defer { lock.unlock() }
        var snapshot = try mutableSnapshotLocked()
        guard let readiness = snapshot.serverRoutingReady else {
            throw RoutingCustodyError.corrupt("principal continuation cannot precede server routing readiness")
        }
        if let existing = snapshot.principalContinuations[digest],
           existing.authorityID == authorityID,
           existing.snapshotDigest == readiness.snapshotDigest {
            return
        }
        let continuation = PrincipalRoutingContinuation(
            principalDigest: digest,
            authorityID: authorityID,
            snapshotDigest: readiness.snapshotDigest,
            continuedAt: date
        )
        snapshot.principalContinuations[digest] = continuation
        try publishLocked(snapshot)
    }

    public static func principalDigest(_ principalKey: String) -> String {
        digest("routing-principal:\(principalKey)")
    }

    public func activeRevisionIDForTesting() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try readStateLocked().activeRevisionID
    }

    public func priorRevisionIDsForTesting() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try readStateLocked().priorRevisionIDs
    }

    public func setFaultForTesting(_ point: TestFaultPoint?) {
        lock.lock(); defer { lock.unlock() }
        faultPoint = point
    }

    public func corruptPayloadForTesting(revisionID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try Data("corrupt".utf8).write(
            to: revisionURL(revisionID).appendingPathComponent("custody.json"),
            options: .atomic
        )
    }

    public func resetForTesting() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        faultPoint = nil
    }

    private func readableSnapshotLocked() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        do {
            let state = try readStateLocked()
            return try readRevisionLocked(state.activeRevisionID)
        } catch {
            guard let state = try? readStateLocked() else {
                throw RoutingCustodyError.corrupt("active state has no trusted recovery chain: \(error.localizedDescription)")
            }
            for revisionID in state.priorRevisionIDs {
                if let prior = try? readRevisionLocked(revisionID) { return prior }
            }
            throw RoutingCustodyError.corrupt("no manifest-valid prior revision: \(error.localizedDescription)")
        }
    }

    private func mutableSnapshotLocked() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return .empty }
        do {
            let state = try readStateLocked()
            return try readRevisionLocked(state.activeRevisionID)
        } catch {
            guard let state = try? readStateLocked() else {
                throw RoutingCustodyError.corrupt("active state has no trusted recovery chain: \(error.localizedDescription)")
            }
            for revisionID in state.priorRevisionIDs {
                if let prior = try? readRevisionLocked(revisionID) {
                    let history = unique([state.activeRevisionID] + state.priorRevisionIDs).filter { $0 != revisionID }
                    try writeJSON(
                        ActiveState(schemaVersion: Self.schemaVersion, activeRevisionID: revisionID, priorRevisionIDs: history),
                        to: stateURL
                    )
                    return prior
                }
            }
            throw RoutingCustodyError.corrupt("no manifest-valid prior revision: \(error.localizedDescription)")
        }
    }

    private func publishLocked(_ snapshot: Snapshot) throws {
        try validate(snapshot)
        try ensureDirectory(root)
        try ensureDirectory(revisionsRoot)
        let revisionID = "revision-\(UUID().uuidString.lowercased())"
        let staging = revisionsRoot.appendingPathComponent(".\(revisionID).staging", isDirectory: true)
        let final = revisionURL(revisionID)
        let fm = FileManager.default
        try ensureDirectory(staging)
        do {
            let payloadURL = staging.appendingPathComponent("custody.json")
            try writeJSON(snapshot, to: payloadURL)
            let manifest = RevisionManifest(
                schemaVersion: Self.schemaVersion,
                revisionID: revisionID,
                createdAt: Date(),
                payloadSHA256: Self.digest(try Data(contentsOf: payloadURL))
            )
            try writeJSON(manifest, to: staging.appendingPathComponent("manifest.json"))
            try injectFault(.beforeRevisionFinalize)
            try fm.moveItem(at: staging, to: final)
            try injectFault(.beforeActivation)
            let previous = try? readStateLocked()
            let history = unique(([previous?.activeRevisionID].compactMap { $0 }) + (previous?.priorRevisionIDs ?? []))
                .filter { $0 != revisionID }
            try writeJSON(
                ActiveState(schemaVersion: Self.schemaVersion, activeRevisionID: revisionID, priorRevisionIDs: history),
                to: stateURL
            )
        } catch {
            if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) }
            throw error
        }
    }

    private func readRevisionLocked(_ revisionID: String) throws -> Snapshot {
        guard isSafeRevisionID(revisionID) else { throw RoutingCustodyError.corrupt("unsafe revision ID") }
        let revision = revisionURL(revisionID)
        let manifest: RevisionManifest
        do {
            manifest = try decoder.decode(RevisionManifest.self, from: Data(contentsOf: revision.appendingPathComponent("manifest.json")))
        } catch {
            throw RoutingCustodyError.corrupt("cannot decode manifest for \(revisionID)")
        }
        guard manifest.schemaVersion == Self.schemaVersion, manifest.revisionID == revisionID else {
            throw RoutingCustodyError.corrupt("manifest identity mismatch for \(revisionID)")
        }
        let payload = try Data(contentsOf: revision.appendingPathComponent("custody.json"))
        guard Self.digest(payload) == manifest.payloadSHA256 else {
            throw RoutingCustodyError.corrupt("payload checksum mismatch for \(revisionID)")
        }
        let snapshot = try decoder.decode(Snapshot.self, from: payload)
        try validate(snapshot)
        return snapshot
    }

    private func readStateLocked() throws -> ActiveState {
        let state = try decoder.decode(ActiveState.self, from: Data(contentsOf: stateURL))
        guard state.schemaVersion == Self.schemaVersion,
              isSafeRevisionID(state.activeRevisionID),
              state.priorRevisionIDs.allSatisfy(isSafeRevisionID) else {
            throw RoutingCustodyError.corrupt("invalid active-state identity")
        }
        return state
    }

    private func validate(_ snapshot: Snapshot) throws {
        guard snapshot.schemaVersion == Self.schemaVersion else {
            throw RoutingCustodyError.corrupt("snapshot schema mismatch")
        }
        if let ready = snapshot.serverRoutingReady {
            guard ready.count > 0, Self.isSHA256(ready.snapshotDigest), !ready.source.isEmpty else {
                throw RoutingCustodyError.corrupt("invalid server readiness")
            }
        } else if !snapshot.principalContinuations.isEmpty {
            throw RoutingCustodyError.corrupt("continuations exist without readiness")
        }
        for (key, continuation) in snapshot.principalContinuations {
            guard key == continuation.principalDigest,
                  Self.isSHA256(key),
                  !continuation.authorityID.isEmpty,
                  continuation.snapshotDigest == snapshot.serverRoutingReady?.snapshotDigest else {
                throw RoutingCustodyError.corrupt("invalid principal continuation")
            }
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        value.dateEncodingStrategy = .iso8601
        return value
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    private func revisionURL(_ id: String) -> URL { revisionsRoot.appendingPathComponent(id, isDirectory: true) }
    private func isSafeRevisionID(_ value: String) -> Bool {
        value.hasPrefix("revision-") && !value.contains("..") && !value.contains("/")
    }
    private func injectFault(_ point: TestFaultPoint) throws {
        if faultPoint == point { throw RoutingCustodyError.injectedFailure(point) }
    }
    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
    private static func digest(_ string: String) -> String { digest(Data(string.utf8)) }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ActiveState: Codable {
        let schemaVersion: Int
        let activeRevisionID: String
        let priorRevisionIDs: [String]
    }
    private struct RevisionManifest: Codable {
        let schemaVersion: Int
        let revisionID: String
        let createdAt: Date
        let payloadSHA256: String
    }
    private struct Snapshot: Codable, Equatable {
        let schemaVersion: Int
        var serverRoutingReady: ServerRoutingReadiness?
        var principalContinuations: [String: PrincipalRoutingContinuation]
        static let empty = Snapshot(schemaVersion: RoutingCustodyStore.schemaVersion, serverRoutingReady: nil, principalContinuations: [:])
    }
}
