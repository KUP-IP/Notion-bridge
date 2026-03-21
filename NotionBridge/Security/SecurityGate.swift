// SecurityGate.swift – PKT-376: Security Model v3
// NotionBridge · Security
// 3-tier model:
// - Open: execute immediately
// - Notify: execute immediately + fire-and-forget notification
// - Request: actionable pre-execution approval (Allow / Deny / Always Allow)
//   - Safe commands (read-only): auto-allow for shell/cli tools
// - Sensitive path prompting with session/permanent allow (UserDefaults)
// - Nuclear handoff for fork bomb patterns only

import UserNotifications
import MCP

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Security Tier (v3: 3-tier model)

/// Three security tiers replacing the previous 2-tier system.
///
/// - `open`: Execute immediately. No user interaction. Used for read-only operations.
/// - `notify`: Execute immediately and send fire-and-forget notification after execution.
/// - `request`: Request explicit approval before execution.
///
/// Nuclear pattern enforcement remains runtime-driven by `SecurityGate.enforce()`.
public enum SecurityTier: String, Sendable, CaseIterable, Codable {
    case open = "open"
    case notify = "notify"
    case request = "request"
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

    private static let normalizedForkBomb = ":(){:|:&};:"

    // MARK: Command-Aware Classification (V1-PATCH-001)

    /// Read-only commands that are safe to execute without notification.
    private static let safeCommandPatterns: [String] = [
        // File inspection (read-only)
        #"^cat\s"#,
        #"^head\s"#,
        #"^tail\s"#,
        #"^less\s"#,
        #"^more\s"#,
        #"^wc[\s]"#,
        #"^file\s"#,
        #"^stat\s"#,
        #"^md5\s"#,
        #"^shasum\s"#,
        // Directory listing and search
        #"^ls(\s|$)"#,
        #"^find\s"#,
        #"^tree(\s|$)"#,
        #"^du[\s]"#,
        #"^df(\s|$)"#,
        // System info (read-only)
        #"^uptime$"#,
        #"^whoami$"#,
        #"^pwd$"#,
        #"^hostname"#,
        #"^uname"#,
        #"^id(\s|$)"#,
        #"^groups(\s|$)"#,
        #"^w$"#,
        #"^who$"#,
        #"^date"#,
        #"^cal(\s|$)"#,
        #"^sw_vers"#,
        #"^system_profiler"#,
        #"^sysctl\s"#,
        #"^vm_stat"#,
        #"^top\s+-l"#,
        #"^ps[\s]"#,
        #"^ioreg"#,
        #"^pmset\s+-g"#,
        // Environment (read-only)
        #"^echo\s"#,
        #"^printf\s"#,
        #"^env$"#,
        #"^printenv"#,
        #"^which\s"#,
        #"^type\s"#,
        // Network diagnostics (read-only)
        #"^ifconfig"#,
        #"^networksetup\s+-(get|list)"#,
        #"^scutil\s+--"#,
        #"^nslookup\s"#,
        #"^dig\s"#,
        #"^ping\s+-c"#,
        #"^traceroute\s"#,
        #"^netstat"#,
        #"^lsof\s+-i"#,
        // Disk info (read-only)
        #"^diskutil\s+(list|info)"#,
        // Process/service listing (read-only)
        #"^launchctl\s+list"#,
        // Preferences reading
        #"^defaults\s+read"#,
        // Spotlight (read-only)
        #"^mdls\s"#,
        #"^mdfind\s"#,
        // Developer tools (read-only / version checks)
        #"^xcode-select\s+-p"#,
        #"^xcodebuild\s+-version"#,
        #"^swift\s+--version"#,
        #"^swiftc\s+--version"#,
        #"^python3?\s+--version"#,
        #"^pip3?\s+(list|show|freeze)"#,
        #"^node\s+--version"#,
        #"^npm\s+(list|ls|outdated|view)"#,
        // Git (read-only)
        #"^git\s+(status|log|diff|branch|remote|show|stash\s+list|tag|describe)"#,
        // SQLite read-only
        #"^sqlite3\s+.*-readonly"#,
        // Make (dry-run only)
        #"^make\s+-n"#,
    ]

    // MARK: Sensitive Paths

    // PKT-363 D2: sensitivePaths moved to ConfigManager (config.json-backed)

    private let approvalManager: NotificationApprovalManager
    private var sessionAllowedPaths: Set<String> = []

    private static let permanentAllowPrefix = "com.notionbridge.security.pathAllow."

    public init() {
        self.approvalManager = NotificationApprovalManager()

        // PKT-363 D1: Seed sensitivePaths defaults on first launch with new schema
        ConfigManager.shared.seedDefaultsIfNeeded()
    }

    // MARK: Permission Setup

    public func requestNotificationPermission() async {
        await approvalManager.requestPermission()
    }

    // MARK: Enforcement

    /// Evaluate a tool call against all security policies.
    ///
    /// **Enforcement order (PKT-376):**
    /// 1. Nuclear pattern check (fork bomb only)
    /// 2. Safe command auto-allow for shell/cli tools
    /// 3. Sensitive path check
    /// 4. Tier-based logic — Open = allow, Notify = allow, Request = approval
    public func enforce(
        toolName: String,
        tier: SecurityTier,
        arguments: Value
    ) async -> GateDecision {
        let allStrings = extractStrings(from: arguments)
        let combined = allStrings.joined(separator: " ")
        let detail = requestDetail(toolName: toolName, arguments: arguments, fallback: combined)
        let lowered = detail.lowercased()

        // 1. Nuclear pattern check (highest priority)
        if let handoff = checkNuclearPattern(lowered, raw: combined) {
            return handoff
        }

        // 2. Command-aware classification for shell execution tools
        if toolName == "shell_exec" || toolName == "cli_exec" {
            if checkSafeCommand(detail) {
                return .allow
            }
        }

        // 3. Sensitive path check
        if let sensitiveResult = await checkSensitivePaths(allStrings, toolName: toolName) {
            return sensitiveResult
        }

        // 4. Tier-based logic
        switch tier {
        case .open:
            return .allow
        case .notify:
            return .allow
        case .request:
            if checkLearnedAllow(detail) {
                return .allow
            }
            return await requestApproval(toolName: toolName, detail: detail)
        }
    }

    // MARK: Nuclear Check

    public func checkNuclearPattern(_ lowered: String, raw: String) -> GateDecision? {
        let normalized = lowered.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
        if normalized.contains(SecurityGate.normalizedForkBomb) {
            return makeHandoff(raw)
        }
        return nil
    }

    private func makeHandoff(_ raw: String) -> GateDecision {
        let safeCommand = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return .handoff(
            command: safeCommand,
            explanation: "This command matches a fork-bomb pattern that can destabilize your system. For safety, it must be run manually in Terminal.",
            warning: "Fork bomb pattern detected. This is not an error — the command has been prepared for manual execution.\n\nOpen Terminal.app and paste:\n\n    \(safeCommand)\n\nReview carefully before executing."
        )
    }

    // MARK: Command Classification (V1-PATCH-001)

    private func checkSafeCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in SecurityGate.safeCommandPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
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

            // PKT-363 D2: Dynamic read from config-backed list (fallback to defaults on error)
            for sensitive in ConfigManager.shared.sensitivePaths {
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
        let decision = await approvalManager.requestApproval(
            title: "Notion Bridge wants to \(toolName)",
            body: truncated
        )

        switch decision {
        case .allow:
            return .allow
        case .alwaysAllow:
            let prefix = learnedPrefix(for: detail)
            if !prefix.isEmpty {
                ConfigManager.shared.addLearnedAllowPrefix(prefix)
            }
            return .allow
        case .deny:
            return .reject(reason: "User denied via notification (or 30s timeout)")
        }
    }

    // MARK: Learned Allow Prefixes

    private func checkLearnedAllow(_ command: String) -> Bool {
        let normalizedCommand = normalizeForPrefixMatch(command)
        guard !normalizedCommand.isEmpty else { return false }
        for prefix in ConfigManager.shared.learnedAllowPrefixes {
            let normalizedPrefix = normalizeForPrefixMatch(prefix)
            guard !normalizedPrefix.isEmpty else { continue }
            if normalizedCommand.hasPrefix(normalizedPrefix) {
                return true
            }
        }
        return false
    }

    private func learnedPrefix(for command: String) -> String {
        let normalized = normalizeWhitespace(command)
        guard !normalized.isEmpty else { return "" }

        if normalized.contains("\n") {
            let firstLine = normalized
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? ""
            return String(firstLine.prefix(80))
        }

        let tokens = normalized.split(separator: " ")
        if tokens.isEmpty { return "" }
        return tokens.prefix(3).joined(separator: " ")
    }

    private func normalizeForPrefixMatch(_ value: String) -> String {
        normalizeWhitespace(value).lowercased()
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestDetail(toolName: String, arguments: Value, fallback: String) -> String {
        guard case .object(let dict) = arguments else {
            return normalizeWhitespace(fallback)
        }

        let keyCandidatesByTool: [String: [String]] = [
            "shell_exec": ["command"],
            "cli_exec": ["command"],
            "run_script": ["scriptName"],
            "applescript_exec": ["script"],
            "messages_send": ["recipient", "body"],
        ]

        let keyCandidates = keyCandidatesByTool[toolName] ?? ["command", "script", "scriptName"]
        let parts = keyCandidates.compactMap { key -> String? in
            if case .string(let value) = dict[key] {
                let normalized = normalizeWhitespace(value)
                return normalized.isEmpty ? nil : normalized
            }
            return nil
        }

        if parts.isEmpty {
            return normalizeWhitespace(fallback)
        }
        return parts.joined(separator: " ")
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

    // MARK: Fire-and-Forget Notification (F2)

    /// F2: Sends a fire-and-forget macOS notification when a Notify-tier tool executes.
    /// This is informational only — no approval actions. Additive to the existing approval flow.
    /// Called by ToolRouter after successful execution of a Notify-tier tool.
    public func sendExecutionNotification(toolName: String) async {
        await approvalManager.sendFireAndForget(
            title: "Notion Bridge",
            body: "\"\(toolName)\" was called"
        )
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

    public enum ApprovalDecision: Sendable {
        case allow
        case deny
        case alwaysAllow
    }

    private let center: UNUserNotificationCenter?
    private var hasPermission: Bool = false
    private let approvalTimeout: TimeInterval = 30
    private let isTestProcess: Bool

    private let lock = NSLock()
    private var pendingApprovals: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]

    static let categoryIdentifier = "SECURITY_APPROVAL"
    static let allowActionIdentifier = "ALLOW_ACTION"
    static let denyActionIdentifier = "DENY_ACTION"
    static let alwaysAllowActionIdentifier = "ALWAYS_ALLOW"

    /// UserNotifications is only reliable when running as a bundled app process.
    /// CLI test executables (e.g. swift run NotionBridgeTests) can crash when calling
    /// UNUserNotificationCenter.current(), so we avoid touching it in that context.
    private static var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    /// Detect standalone test executable runs to keep tests non-interactive.
    private static var runningInTestProcess: Bool {
        let processName = ProcessInfo.processInfo.processName.lowercased()
        if processName.contains("notionbridgetests") { return true }
        return CommandLine.arguments.joined(separator: " ").lowercased().contains("notionbridgetests")
    }

    public override init() {
        self.isTestProcess = Self.runningInTestProcess
        if Self.canUseUserNotifications {
            self.center = UNUserNotificationCenter.current()
        } else {
            self.center = nil
        }
        super.init()
        if let center {
            center.delegate = self
            registerCategories()
        }
    }

    // MARK: Thread-Safe Helpers (nonisolated — safe from async contexts)

    private nonisolated func storePending(
        forKey key: String,
        continuation: CheckedContinuation<ApprovalDecision, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }
        pendingApprovals[key] = continuation
    }

    private nonisolated func removePending(forKey key: String) -> CheckedContinuation<ApprovalDecision, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return pendingApprovals.removeValue(forKey: key)
    }

    // MARK: Setup

    private func registerCategories() {
        guard let center else { return }
        let allowAction = UNNotificationAction(
            identifier: Self.allowActionIdentifier,
            title: "Allow",
            options: [.authenticationRequired]
        )
        let denyAction = UNNotificationAction(
            identifier: Self.denyActionIdentifier,
            title: "Decline",
            options: [.destructive]
        )
        let alwaysAllowAction = UNNotificationAction(
            identifier: Self.alwaysAllowActionIdentifier,
            title: "Always Allow",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [allowAction, denyAction, alwaysAllowAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: Fire-and-Forget (F2)

    /// F2: Fire-and-forget notification — informational only, no approval actions.
    /// Sends a brief notification that a tool was called. Does not wait for user response.
    public func sendFireAndForget(title: String, body: String) async {
        guard !isTestProcess, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // No categoryIdentifier — no Allow/Deny action buttons
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    public func requestPermission() async {
        guard let center else {
            hasPermission = false
            return
        }
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

    public func requestApproval(title: String, body: String) async -> ApprovalDecision {
        if isTestProcess {
            return .allow
        }
        if hasPermission {
            return await requestViaNotification(title: title, body: body)
        } else {
            return await requestViaAlert(title: title, body: body)
        }
    }

    private func requestViaNotification(title: String, body: String) async -> ApprovalDecision {
        guard let center else {
            return await requestViaAlert(title: title, body: body)
        }
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

        return await withCheckedContinuation { continuation in
            storePending(forKey: identifier, continuation: continuation)

            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.approvalTimeout))
                if let pending = self.removePending(forKey: identifier) {
                    pending.resume(returning: .deny)
                    print("[SecurityGate] Approval timed out (30s) — denied by default")
                }
            }
        }
    }

    @MainActor
    private func requestViaAlert(title: String, body: String) async -> ApprovalDecision {
        #if canImport(AppKit)
        guard NSApp != nil else {
            print("[SecurityGate] No NSApplication context for approval alert — denying by default")
            return .deny
        }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .allow : .deny
        #else
        return .deny
        #endif
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let decision: ApprovalDecision
        switch response.actionIdentifier {
        case Self.allowActionIdentifier:
            decision = .allow
        case Self.alwaysAllowActionIdentifier:
            decision = .alwaysAllow
        default:
            decision = .deny
        }

        if let continuation = removePending(forKey: identifier) {
            continuation.resume(returning: decision)
        }

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
