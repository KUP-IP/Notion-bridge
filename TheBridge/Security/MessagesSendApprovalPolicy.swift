// MessagesSendApprovalPolicy.swift — operator-selectable messages_send gate
// TheBridge · Security
//
// Default remains Always ask. Permissive modes never cover group chats,
// THREAD, remote/tunnel, jobs/internal (nil transport session), or raw
// chatNNN recipients. confirm:"SEND" is still required in every mode.

import Foundation
import MCP

public enum MessagesSendApprovalMode: String, Sendable, CaseIterable, Equatable {
    case alwaysAsk
    case session
    case trustedDirect

    public var title: String {
        switch self {
        case .alwaysAsk: return "Always ask"
        case .session: return "Ask once per session"
        case .trustedDirect: return "Trusted direct sends"
        }
    }

    public var riskCopy: String {
        switch self {
        case .alwaysAsk:
            return "Every ordinary send shows an on-device approval prompt. Safest default."
        case .session:
            return "The first ordinary one-to-one send in this live agent session prompts on-device. Later ordinary sends in the same session skip the modal. Group, THREAD, remote, and job sends still prompt."
        case .trustedDirect:
            return "Ordinary one-to-one sends from a live local agent skip the on-device modal when confirm:SEND is present. A wrong or unexpected send can leave the Mac immediately. Revert to Always ask anytime."
        }
    }
}

public enum MessagesSendApprovalPolicy {
    public static let threadTransactionArguments: Set<String> = [
        "threadPageId", "actionId", "approvalBasis", "actor", "workspace"
    ]

    public static func load(from defaults: UserDefaults = .standard) -> MessagesSendApprovalMode {
        guard let raw = defaults.string(forKey: BridgeDefaults.messagesSendApprovalMode),
              let mode = MessagesSendApprovalMode(rawValue: raw) else {
            return .alwaysAsk
        }
        return mode
    }

    public static func save(_ mode: MessagesSendApprovalMode, to defaults: UserDefaults = .standard) {
        if mode == .alwaysAsk {
            defaults.removeObject(forKey: BridgeDefaults.messagesSendApprovalMode)
        } else {
            defaults.set(mode.rawValue, forKey: BridgeDefaults.messagesSendApprovalMode)
        }
        let next = defaults.integer(forKey: BridgeDefaults.messagesSendApprovalGeneration) &+ 1
        defaults.set(next, forKey: BridgeDefaults.messagesSendApprovalGeneration)
        NotificationCenter.default.post(name: .messagesSendApprovalModeDidChange, object: mode.rawValue)
    }

    /// Ordinary one-to-one iMessage/SMS: explicit service, confirm SEND, phone or
    /// email recipient, no group chatIdentifier, no THREAD transaction args.
    public static func isOrdinaryOneToOne(_ arguments: Value) -> Bool {
        guard case .object(let args) = arguments else { return false }
        if args.keys.contains(where: { threadTransactionArguments.contains($0) }) {
            return false
        }
        guard case .string(let confirm) = args["confirm"], confirm == "SEND" else {
            return false
        }
        if case .string(let chatIdentifier) = args["chatIdentifier"],
           !chatIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        guard case .string(let recipient) = args["recipient"] else { return false }
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isRawChatIdentifier(trimmed) { return false }
        let service: String? = {
            if case .string(let value) = args["service"] { return value }
            return nil
        }()
        return MessagesService.parseStrict(service) != nil
    }

    public static func isRawChatIdentifier(_ recipient: String) -> Bool {
        let pattern = try! NSRegularExpression(pattern: "^chat[0-9]+$", options: .caseInsensitive)
        let range = NSRange(recipient.startIndex..., in: recipient)
        return pattern.firstMatch(in: recipient, range: range) != nil
    }

    /// True when SecurityGate must show the on-device messages_send prompt.
    public static func requiresOnDevicePrompt(
        arguments: Value,
        context: ToolDispatchContext,
        mode: MessagesSendApprovalMode,
        sessionAlreadyApproved: Bool
    ) -> Bool {
        if context.origin != .local { return true }
        let sessionId = context.transportSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if sessionId.isEmpty { return true }
        if !isOrdinaryOneToOne(arguments) { return true }
        switch mode {
        case .alwaysAsk:
            return true
        case .session:
            return !sessionAlreadyApproved
        case .trustedDirect:
            return false
        }
    }
}
