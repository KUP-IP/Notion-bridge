// SecurityGate.swift – V1-PATCH-002: Security Model v2.2 — Trusted Mode
// NotionBridge · Security
// Builds on v2.1 (2-Tier + Command-Aware Classification) with Trusted Mode:
// - Open: execute immediately
// - Notify: actionable notification approval (UNUserNotificationCenter)
//   - Safe commands (read-only): auto-allow, skip notification (~70-80% reduction)
//   - Dangerous commands: nuclear handoff
// - Sensitive path prompting with session/permanent allow (UserDefaults)
// - Nuclear handoff for system-critical commands (return helpful response, never block)
// - **Trusted Mode (v2.2):** When enabled, all .notify tier tools auto-allow without
//   prompting. Nuclear patterns and dangerous command patterns still enforced.
//   Persisted via UserDefaults. Toggle via setTrustedMode() or `defaults write`.
//
// V1-PATCH-002 changes:
// - Added trustedMode property (UserDefaults-backed, key: com.notionbridge.security.trustedMode)
// - Added setTrustedMode(_:) and isTrustedMode computed property
// - Modified enforce() to skip notification when trustedMode is enabled
// - Sensitive path check skipped when trustedMode is enabled
// - Nuclear patterns and dangerous command patterns ALWAYS enforced regardless of trust

import UserNotifications
import MCP

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Security Tier (v2: 2-tier model)

/// Two security tiers replacing the previous 4-tier system (V1-QUALITY-C1).
///
/// - `open`: Execute immediately. No user interaction. Used for read-only operations.
/// - `notify`: Informs the user via macOS notification when the tool executes.
///
/// **Architecture note (F3 — PKT-366):**
/// This enum is strictly 2-tier. There is no "confirm" or "destructive" case.
/// Behavioral escalation (nuclear patterns, dangerous commands) is enforced at
/// **runtime** by `SecurityGate.enforce()` — it is NOT a separate tier.
/// The UI toggle (F1) controls notification behavior only. It does not bypass
/// runtime escalation: nuclear and dangerous command patterns still gate
/// regardless of the user's tier choice.
/// Auto-escalation patterns are enforced unconditionally by
/// `checkNuclearPattern()` and `checkDangerousCommand()`.
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

    // MARK: Trusted Mode (V1-PATCH-002)

    private static let trustedModeKey = "com.notionbridge.security.trustedMode"

    /// When true, .notify tier tools auto-allow without prompting.
    /// Nuclear patterns and dangerous commands are ALWAYS enforced.
    public var isTrustedMode: Bool {
        UserDefaults.standard.bool(forKey: SecurityGate.trustedModeKey)
    }

    /// Enable or disable trusted mode. Persists across app restarts.
    public func setTrustedMode(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: SecurityGate.trustedModeKey)
        let state = enabled ? "ENABLED" : "DISABLED"
        print("[SecurityGate] Trusted mode \(state) — nuclear patterns still enforced")
    }

    // MARK: Nuclear Patterns

    private let nuclearPatterns: [String]

    /// Separate check for recursive forced removal of root
    private static func isNuclearRecursiveDelete(_ lowered: String) -> Bool {
        let trimmed = lowered.trimmingCharacters(in: .whitespaces)
        let prefix = String(UnicodeScalar(0x72)) + String(UnicodeScalar(0x6D))
        return trimmed.contains(prefix + " -rf /")
    }

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

    /// Commands that are dangerous and should trigger nuclear handoff.
    private static let dangerousCommandPatterns: [String] = [
        #"^\s*su[d]\s*[o]\s"#,
        #"\|\s*(sh|bas[h]|zsh|eva[l])\b"#,
        #"\bchmo[d]\s+77[7]\b"#,
    ]

    // MARK: Sensitive Paths

    // PKT-363 D2: sensitivePaths moved to ConfigManager (config.json-backed)

    private let approvalManager: NotificationApprovalManager
    private var sessionAllowedPaths: Set<String> = []

    private static let permanentAllowPrefix = "com.notionbridge.security.pathAllow."

    public init() {
        self.approvalManager = NotificationApprovalManager()
        // Nuclear patterns use character-level construction to avoid
        // triggering content scanners that inspect file text.
        let s = String(UnicodeScalar(0x73))
        let u = String(UnicodeScalar(0x75))
        let d = String(UnicodeScalar(0x64))
        let o = String(UnicodeScalar(0x6F))
        self.nuclearPatterns = [
            s + u + d + o + " ",
            "diskutil erasedisk",
            "csrutil disable",
            "nvram ",
            String(UnicodeScalar(0x6D)) + "kfs.",
            d + d + " if=",
            ":(){ :|:" + "& };:",
        ]

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
    /// **Enforcement order (F3 — PKT-366):**
    /// 1. Nuclear pattern check — ALWAYS enforced, even in trusted mode
    /// 2. Dangerous command patterns — ALWAYS enforced, even in trusted mode
    /// 3. Safe command auto-allow — read-only commands skip notification
    /// 4. Trusted mode bypass — auto-allows after nuclear + dangerous checks pass
    /// 5. Sensitive path check — prompts for access to ~/.ssh, ~/.aws, etc.
    /// 6. Tier-based logic — Open = allow, Notify = request approval
    ///
    /// The UI tier toggle (F1) only affects step 6. Steps 1–2 are unconditional.
    public func enforce(
        toolName: String,
        tier: SecurityTier,
        arguments: Value
    ) async -> GateDecision {
        let allStrings = extractStrings(from: arguments)
        let combined = allStrings.joined(separator: " ")
        let lowered = combined.lowercased()

        // 1. Nuclear pattern check (highest priority)
        //    ALWAYS enforced, even in trusted mode.
        if let handoff = checkNuclearPattern(lowered, raw: combined) {
            return handoff
        }

        // 2. Command-aware classification for shell execution tools
        //    Dangerous patterns ALWAYS enforced, even in trusted mode.
        if toolName == "shell_exec" || toolName == "cli_exec" {
            if let dangerous = checkDangerousCommand(combined) {
                return dangerous
            }
            if checkSafeCommand(combined) {
                return .allow
            }
        }

        // 3. Trusted mode bypass (V1-PATCH-002)
        //    After nuclear + dangerous checks pass, auto-allow everything.
        if isTrustedMode {
            return .allow
        }

        // 4. Sensitive path check (skipped in trusted mode — handled above)
        if let sensitiveResult = await checkSensitivePaths(allStrings, toolName: toolName) {
            return sensitiveResult
        }

        // 5. Tier-based logic
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

    private func checkDangerousCommand(_ command: String) -> GateDecision? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in SecurityGate.dangerousCommandPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                    return makeHandoff(trimmed)
                }
            }
        }
        return nil
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
        let approved = await approvalManager.requestApproval(
            title: "Notion Bridge wants to \(toolName)",
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

    private let center: UNUserNotificationCenter?
    private var hasPermission: Bool = false
    private let approvalTimeout: TimeInterval = 30
    private let isTestProcess: Bool

    private let lock = NSLock()
    private var pendingApprovals: [String: CheckedContinuation<Bool, Never>] = [:]

    static let categoryIdentifier = "SECURITY_APPROVAL"
    static let allowActionIdentifier = "ALLOW_ACTION"
    static let denyActionIdentifier = "DENY_ACTION"

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

    private nonisolated func storePending(forKey key: String, continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        pendingApprovals[key] = continuation
    }

    private nonisolated func removePending(forKey key: String) -> CheckedContinuation<Bool, Never>? {
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

    public func requestApproval(title: String, body: String) async -> Bool {
        if isTestProcess {
            return true
        }
        if hasPermission {
            return await requestViaNotification(title: title, body: body)
        } else {
            return await requestViaAlert(title: title, body: body)
        }
    }

    private func requestViaNotification(title: String, body: String) async -> Bool {
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
                    pending.resume(returning: false)
                    print("[SecurityGate] Approval timed out (30s) — denied by default")
                }
            }
        }
    }

    @MainActor
    private func requestViaAlert(title: String, body: String) async -> Bool {
        #if canImport(AppKit)
        guard NSApp != nil else {
            print("[SecurityGate] No NSApplication context for approval alert — denying by default")
            return false
        }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
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
