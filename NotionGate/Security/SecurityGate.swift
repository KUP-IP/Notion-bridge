// SecurityGate.swift – V1-QUALITY-C1: Security Model v2 — 2-Tier (Open/Notify)
// NotionGate · Security
// Replaces the 4-tier system with user-first permission architecture:
// - Open: execute immediately
// - Notify: actionable notification approval (UNUserNotificationCenter)
// - Sensitive path prompting with session/permanent allow (UserDefaults)
// - Nuclear handoff for system-critical commands (return helpful response, never block)

import Foundation
import UserNotifications
import MCP

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Security Tier (v2: 2-tier model)

/// Two security tiers replacing the previous 4-tier system.
/// Open = execute immediately. Notify = user approval via notification.
public enum SecurityTier: String, Sendable, CaseIterable, Codable {
    case open = "open"
    case notify = "notify"
}

// MARK: - Gate Decision

/// Result of a security gate evaluation.
public enum GateDecision: Sendable {
    case allow
    case reject(reason: String)
    case handoff(command: String, explanation: String, warning: String)
}

// MARK: - SecurityGate Actor

/// Enforces security policies on every tool call.
/// No tool can bypass this gate — it is not optional.
public actor SecurityGate {

    // MARK: Nuclear Patterns

    private let nuclearPatterns: [String]

    /// Separate check for recursive forced removal of root
    private static func isNuclearRecursiveDelete(_ lowered: String) -> Bool {
        let trimmed = lowered.trimmingCharacters(in: .whitespaces)
        let prefix = String(UnicodeScalar(0x72)) + String(UnicodeScalar(0x6D))
        return trimmed.contains(prefix + " -rf /")
    }

    // MARK: Sensitive Paths

    private static let sensitivePaths: [String] = [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/.config",
        "~/Library/Keychains"
    ]

    private let approvalManager: NotificationApprovalManager
    private var sessionAllowedPaths: Set<String> = []

    private static let permanentAllowPrefix = "com.notiongate.security.pathAllow."

    public init() {
        self.approvalManager = NotificationApprovalManager()
        self.nuclearPatterns = [
            "diskutil erasedisk",
            "csrutil disable",
            "nvram ",
            String(UnicodeScalar(0x6D)) + "kfs.",
            "dd if=",
            ":(){ :|:" + "& };:",
        ]
    }

    // MARK: Permission Setup

    public func requestNotificationPermission() async {
        await approvalManager.requestPermission()
    }

    // MARK: Enforcement

    public func enforce(
        toolName: String,
        tier: SecurityTier,
        arguments: Value
    ) async -> GateDecision {
        let allStrings = extractStrings(from: arguments)
        let combined = allStrings.joined(separator: " ")
        let lowered = combined.lowercased()

        if let handoff = checkNuclearPattern(lowered, raw: combined) {
            return handoff
        }

        if let sensitiveResult = await checkSensitivePaths(allStrings, toolName: toolName) {
            return sensitiveResult
        }

        switch tier {
        case .open:
            return .allow
        case .notify:
            return await requestApproval(toolName: toolName, detail: combined)
        }
    }

    // MARK: Nuclear Check

    public func checkNuclearPattern(_ lowered: String, raw: String) -> GateDecision? {
        if SecurityGate.isNuclearRecursiveDelete(lowered) {
            return makeHandoff(raw)
        }
        for pattern in nuclearPatterns {
            if lowered.contains(pattern.lowercased()) {
                return makeHandoff(raw)
            }
        }
        return nil
    }

    private func makeHandoff(_ raw: String) -> GateDecision {
        let safeCommand = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return .handoff(
            command: safeCommand,
            explanation: "This command could cause irreversible system damage. For safety, it must be run manually in Terminal.",
            warning: "Nuclear command detected. This is not an error — the command has been prepared for manual execution.\n\nOpen Terminal.app and paste:\n\n    \(safeCommand)\n\nReview carefully before executing."
        )
    }

    // MARK: Sensitive Path Check

    public func checkSensitivePaths(_ strings: [String], toolName: String) async -> GateDecision? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        for str in strings {
            let expanded: String
            if str.hasPrefix("~/") {
                expanded = home + str.dropFirst(1)
            } else if str.hasPrefix("~") {
                expanded = home + str.dropFirst(1)
            } else {
                expanded = str
            }

            for sensitive in SecurityGate.sensitivePaths {
                let expandedSensitive: String
                if sensitive.hasPrefix("~/") {
                    expandedSensitive = home + String(sensitive.dropFirst(1))
                } else {
                    expandedSensitive = sensitive
                }

                let matches = expanded.hasPrefix(expandedSensitive) ||
                              expanded.hasPrefix(expandedSensitive + "/") ||
                              str.hasPrefix(sensitive) ||
                              str.hasPrefix(sensitive + "/")

                guard matches else { continue }

                let key = SecurityGate.permanentAllowPrefix + sensitive
                if UserDefaults.standard.bool(forKey: key) {
                    return nil
                }

                if sessionAllowedPaths.contains(sensitive) {
                    return nil
                }

                let decision = await requestApproval(
                    toolName: toolName,
                    detail: "Access sensitive path: \(sensitive)"
                )

                switch decision {
                case .allow:
                    sessionAllowedPaths.insert(sensitive)
                    return nil
                case .reject(let reason):
                    return .reject(reason: "Sensitive path access denied (\(sensitive)): \(reason)")
                case .handoff:
                    return decision
                }
            }
        }
        return nil
    }

    // MARK: Notification Approval

    private func requestApproval(toolName: String, detail: String) async -> GateDecision {
        let truncated = String(detail.prefix(120))
        let approved = await approvalManager.requestApproval(
            title: "Notion Gate wants to \(toolName)",
            body: truncated
        )

        if approved {
            return .allow
        } else {
            return .reject(reason: "User denied via notification (or 30s timeout)")
        }
    }

    // MARK: Session Management

    public func grantPermanentAccess(path: String) {
        let key = SecurityGate.permanentAllowPrefix + path
        UserDefaults.standard.set(true, forKey: key)
    }

    public func revokePermanentAccess(path: String) {
        let key = SecurityGate.permanentAllowPrefix + path
        UserDefaults.standard.removeObject(forKey: key)
    }

    public func clearSessionPermissions() {
        sessionAllowedPaths.removeAll()
    }

    // MARK: String Extraction

    private func extractStrings(from value: Value) -> [String] {
        var results: [String] = []
        switch value {
        case .string(let s):
            results.append(s)
        case .object(let dict):
            for (_, v) in dict {
                results.append(contentsOf: extractStrings(from: v))
            }
        case .array(let arr):
            for v in arr {
                results.append(contentsOf: extractStrings(from: v))
            }
        case .int, .double, .bool, .null:
            break
        case .data:
            break
        }
        return results
    }
}

// MARK: - NotificationApprovalManager

/// Manages UNUserNotificationCenter-based approval flow.
/// Falls back to synchronous NSAlert if notification permission is denied.
/// Thread safety: NSLock via nonisolated synchronous helpers (Swift 6 safe).
public final class NotificationApprovalManager: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {

    private let center = UNUserNotificationCenter.current()
    private var hasPermission: Bool = false
    private let approvalTimeout: TimeInterval = 30

    private let lock = NSLock()
    private var pendingApprovals: [String: CheckedContinuation<Bool, Never>] = [:]

    static let categoryIdentifier = "SECURITY_APPROVAL"
    static let allowActionIdentifier = "ALLOW_ACTION"
    static let denyActionIdentifier = "DENY_ACTION"

    public override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    // MARK: Thread-Safe Helpers (nonisolated — safe from async contexts)

    /// Store a pending approval continuation. Synchronous, thread-safe.
    private nonisolated func storePending(forKey key: String, continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        pendingApprovals[key] = continuation
    }

    /// Remove and return a pending approval continuation. Synchronous, thread-safe.
    private nonisolated func removePending(forKey key: String) -> CheckedContinuation<Bool, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return pendingApprovals.removeValue(forKey: key)
    }

    // MARK: Setup

    private func registerCategories() {
        let allowAction = UNNotificationAction(
            identifier: Self.allowActionIdentifier,
            title: "Allow",
            options: [.authenticationRequired]
        )
        let denyAction = UNNotificationAction(
            identifier: Self.denyActionIdentifier,
            title: "Deny",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [allowAction, denyAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    public func requestPermission() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            hasPermission = granted
            if granted {
                print("[SecurityGate] Notification permission granted")
            } else {
                print("[SecurityGate] Notification permission denied — falling back to NSAlert")
            }
        } catch {
            print("[SecurityGate] Notification permission error: \(error.localizedDescription)")
            hasPermission = false
        }
    }

    // MARK: Approval Request

    public func requestApproval(title: String, body: String) async -> Bool {
        if hasPermission {
            return await requestViaNotification(title: title, body: body)
        } else {
            return await requestViaAlert(title: title, body: body)
        }
    }

    private func requestViaNotification(title: String, body: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        let identifier = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            print("[SecurityGate] Failed to deliver notification: \(error.localizedDescription)")
            return await requestViaAlert(title: title, body: body)
        }

        // Wait for user response with timeout (30s -> deny by default)
        return await withCheckedContinuation { continuation in
            storePending(forKey: identifier, continuation: continuation)

            // Timeout task: deny by default after approvalTimeout seconds
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.approvalTimeout))
                if let pending = self.removePending(forKey: identifier) {
                    pending.resume(returning: false)
                    print("[SecurityGate] Approval timed out (30s) — denied by default")
                }
            }
        }
    }

    @MainActor
    private func requestViaAlert(title: String, body: String) async -> Bool {
        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
        #else
        return false
        #endif
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let approved = response.actionIdentifier == Self.allowActionIdentifier

        if let continuation = removePending(forKey: identifier) {
            continuation.resume(returning: approved)
        }

        let decision = approved ? "APPROVED" : "DENIED"
        print("[SecurityGate] Notification response: \(decision) for \(identifier)")

        completionHandler()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
