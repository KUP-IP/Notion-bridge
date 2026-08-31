// MessagesSendApprovalPolicyTests.swift
// TheBridge · Tests
//
// `messages_send` uses the ordinary SecurityGate ladder (open / notify /
// request). Catalog default stays .request with neverAutoApprove false so
// Settings can lower it, including for remote/tunnel sessions. confirm:SEND
// remains handler-required. Ordinary send inherits live inbound iMessage/SMS
// or fails closed (#198). No live Messages.app send.

import Foundation
import MCP
import TheBridgeLib

func runMessagesSendApprovalPolicyTests() async {
    print("\n📬 Messages send 3-tier SecurityGate ladder")

    await test("messages_send is catalog request and downgradable") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await MessagesModule.register(on: router)
        let tool = await router.registrations(forModule: "messages").first { $0.name == "messages_send" }!
        try expect(tool.tier == .request, "catalog default must stay .request")
        try expect(!tool.neverAutoApprove, "Settings must be able to lower messages_send")
        try expect(tool.description.localizedCaseInsensitiveContains("confirm"),
                   "tool description must name confirm:SEND")
        try expect(tool.description.localizedCaseInsensitiveContains("iMessage")
                   || tool.description.localizedCaseInsensitiveContains("SMS"),
                   "tool description must name the explicit service contract")
        try expect(!tool.description.contains("Always ask"),
                   "send-only Always ask copy must not remain on the tool")
    }

    await test("effective Open also skips the prompt for a local session") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate, tier: .open, arguments: ordinarySend(), context: localSession("s1")
        )
        try expectAllow(decision, "Open local ordinary send")
        try expect(provider.approvalRequestCount == 0)
    }

    await test("Always Allow on messages_send persists a Notify override") {
        let toolKey = BridgeDefaults.tierOverrides
        let moduleKey = BridgeDefaults.moduleTierOverrides
        let previousTool = UserDefaults.standard.object(forKey: toolKey)
        let previousModule = UserDefaults.standard.object(forKey: moduleKey)
        defer {
            if let previousTool {
                UserDefaults.standard.set(previousTool, forKey: toolKey)
            } else {
                UserDefaults.standard.removeObject(forKey: toolKey)
            }
            if let previousModule {
                UserDefaults.standard.set(previousModule, forKey: moduleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: moduleKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: toolKey)
        UserDefaults.standard.removeObject(forKey: moduleKey)
        let provider = TestSecurityApprovalProvider(decision: .alwaysAllow)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate, tier: .request, arguments: ordinarySend(), context: localSession("s1")
        )
        try expectAllow(decision, "Always Allow send")
        let stored = UserDefaults.standard.dictionary(forKey: toolKey) as? [String: String] ?? [:]
        try expect(stored["messages_send"] == SecurityTier.notify.rawValue,
                   "Always Allow must persist a notify override for messages_send, got \(stored)")
    }

    await test("SecurityGate no longer consults a send-only approval policy") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("TheBridge/Security/SecurityGate.swift"),
            encoding: .utf8
        )
        try expect(!source.contains("MessagesSendApprovalPolicy"),
                   "SecurityGate must use resolveEffectiveTier only for messages_send")
        try expect(!source.contains("messagesSendSessionApprovals"),
                   "send-only session skip state must be gone")
        try expect(!source.contains("forceModalReview: neverAutoApprove && toolName == \"messages_send\""),
                   "Request must not force a send-only NSAlert lock")
        try expect(!source.contains("neverAutoApprove || toolName == \"messages_send\""),
                   "Request body must not special-case messages_send vs mail_send")
        try expect(!source.contains("origin != .local"),
                   "do not add a named remote origin floor")
    }

    await test("effective Open + confirm SEND + explicit service skips the on-device prompt for a remote session") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate,
            tier: .open,
            arguments: ordinarySend(),
            context: ToolDispatchContext(transportSessionId: "cloud-agent-1", origin: .remote)
        )
        try expectAllow(decision, "Open remote ordinary send")
        try expect(provider.approvalRequestCount == 0,
                   "effective Open must not force a Mac modal for remote origin")
    }

    await test("effective Notify skips the prompt for remote, jobs, group, and THREAD") {
        let cases: [(String, Value, ToolDispatchContext)] = [
            ("remote", ordinarySend(), ToolDispatchContext(transportSessionId: "s1", origin: .remote)),
            ("job", ordinarySend(), .localDefault),
            ("group", ordinarySend(extra: ["chatIdentifier": .string("iMessage;-;+1555")]), localSession("s1")),
            ("THREAD", ordinarySend(extra: ["threadPageId": .string("thread-page")]), localSession("s1")),
        ]
        for (label, arguments, context) in cases {
            let provider = TestSecurityApprovalProvider()
            let gate = SecurityGate(approvalProvider: provider)
            let decision = await enforceMessages(
                gate: gate, tier: .notify, arguments: arguments, context: context
            )
            try expectAllow(decision, "\(label) at Notify")
            try expect(provider.approvalRequestCount == 0,
                       "\(label) must follow the tool's Notify tier, not a send-only remote/group lock")
        }
    }

    await test("effective Request still prompts, including remote") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate,
            tier: .request,
            arguments: ordinarySend(),
            context: ToolDispatchContext(transportSessionId: "cloud-agent-1", origin: .remote)
        )
        try expectAllow(decision, "Request remote send after prompt")
        try expect(provider.approvalRequestCount == 1,
                   "catalog/request effective tier must still show the on-device prompt")
        try expect(!provider.lastForceModalReview,
                   "Request messages_send must use the same prompt style as mail_send, not a forced NSAlert")
        try expect(provider.lastAllowAlwaysAllowAction,
                   "messages_send must offer Always Allow like other non-locked request tools")
    }

    await test("effective Request denial still rejects") {
        let provider = TestSecurityApprovalProvider(decision: .deny)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate,
            tier: .request,
            arguments: ordinarySend(),
            context: ToolDispatchContext(transportSessionId: "cloud-agent-1", origin: .remote)
        )
        guard case .reject = decision else {
            throw TestError.assertion("Request deny must reject, got \(String(describing: decision))")
        }
        try expect(provider.approvalRequestCount == 1)
    }

    await test("Request still prompts every send — no send-only session skip") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        _ = await enforceMessages(gate: gate, tier: .request, arguments: ordinarySend(), context: localSession("s1"))
        _ = await enforceMessages(gate: gate, tier: .request, arguments: ordinarySend(), context: localSession("s1"))
        try expect(provider.approvalRequestCount == 2,
                   "ordinary Request has no send-only session grant")
    }

    await test("router Open override reaches the handler without a prompt") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        try await withToolOverride("messages_send", SecurityTier.open) {
            let result = try await router.dispatch(
                toolName: "messages_send",
                arguments: ordinarySend(service: "auto")
            )
            guard case .object(let object) = result else {
                throw TestError.assertion("invalid-service result must be an object")
            }
            try expect(object["sent"] == .bool(false), "auto service must still fail closed")
            try expect(object["approvalMode"] == nil,
                       "retired send-only approvalMode must not appear on results")
            try expect(provider.approvalRequestCount == 0,
                       "Open override must skip the Mac modal")
        }
    }

    await test("handler still requires confirm SEND and explicit service under Open") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        try await withToolOverride("messages_send", SecurityTier.open) {
            let missingConfirm = try await router.dispatch(
                toolName: "messages_send",
                arguments: ordinarySend(confirm: "yes")
            )
            guard case .object(let denied) = missingConfirm else {
                throw TestError.assertion("missing SEND must return an object")
            }
            try expect(denied["sent"] == .bool(false), "confirm:SEND remains required at Open")
            try expect(provider.approvalRequestCount == 0)

            let missingService = try await router.dispatch(
                toolName: "messages_send",
                arguments: ordinarySend(recipient: "nobody-issue-198@example.invalid", omitService: true)
            )
            guard case .object(let noService) = missingService else {
                throw TestError.assertion("missing service must return an object")
            }
            try expect(noService["sent"] == .bool(false), "omit service without live inbound must fail closed")
            if case .string(let error) = noService["error"] {
                try expect(error.localizedCaseInsensitiveContains("inherit")
                           || error.localizedCaseInsensitiveContains("explicit"),
                           "omit-without-inbound error must name inherit or explicit, got \(error)")
            } else {
                throw TestError.assertion("omit-without-inbound must return an error string")
            }
        }
    }

    await test("raw chatNNN is still rejected at Open without an on-device prompt") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        try await withToolOverride("messages_send", SecurityTier.open) {
            let result = try await router.dispatch(
                toolName: "messages_send",
                arguments: ordinarySend(recipient: "chat99")
            )
            guard case .object(let object) = result else {
                throw TestError.assertion("raw chatNNN result must be an object")
            }
            try expect(object["sent"] == .bool(false), "raw chatNNN must stay rejected")
            try expect(provider.approvalRequestCount == 0)
        }
    }

    await test("live mail_trash and snippets_delete remain neverAutoApprove") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await MailModule.register(on: router)
        await SnippetsModule.register(on: router)
        await MessagesModule.register(on: router)
        let trash = await router.registrations(forModule: "mail").first { $0.name == "mail_trash" }
        let sendMail = await router.registrations(forModule: "mail").first { $0.name == "mail_send" }
        let snippets = await router.registrations(forModule: "snippets").first { $0.name == "snippets_delete" }
        let send = await router.registrations(forModule: "messages").first { $0.name == "messages_send" }
        try expect(trash?.neverAutoApprove == true, "mail_trash must stay locked")
        try expect(snippets?.neverAutoApprove == true, "snippets_delete must stay locked")
        try expect(sendMail?.neverAutoApprove == false && sendMail?.tier == .request,
                   "mail_send is the sibling pattern: request without neverAutoApprove")
        try expect(send?.neverAutoApprove == false && send?.tier == .request,
                   "messages_send must match mail_send: request without neverAutoApprove")
        try expect(trash?.tier == .request)
        try expect(snippets?.tier == .request)
    }

    await test("neverAutoApprove tools stay locked while messages_send does not") {
        let send = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send", module: "messages",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: ["messages_send": "open"], moduleOverrides: [:]
        )
        try expect(send == .open)

        let trash = ToolRouter.resolveEffectiveTier(
            toolName: "mail_trash", module: "mail",
            registeredTier: .request, neverAutoApprove: true,
            toolOverrides: ["mail_trash": "open"], moduleOverrides: ["mail": "open"]
        )
        try expect(trash == .request, "mail_trash must remain locked")

        let snippets = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_delete", module: "snippets",
            registeredTier: .request, neverAutoApprove: true,
            toolOverrides: ["snippets_delete": "notify"], moduleOverrides: ["snippets": "open"]
        )
        try expect(snippets == .request, "snippets_delete must remain locked")
    }

    await test("Gates UI no longer hosts a send-only approval card") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let ui = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("TheBridge/UI/Sections/PermissionsSection.swift"),
            encoding: .utf8
        )
        try expect(!ui.contains("messagesApprovalCard"),
                   "Gates tab must not render a send-only approval card")
        try expect(!ui.contains("MessagesSendApprovalMode"),
                   "Gates tab must not mention the retired send-only mode enum")
        try expect(ui.contains("alwaysAllowCard"),
                   "ordinary Always-Allow grants card must remain")
    }

    await test("Request pending maps to awaitingApproval and does not allow") {
        let provider = TestSecurityApprovalProvider(decision: .pending)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate,
            tier: .request,
            arguments: ordinarySend(),
            context: ToolDispatchContext(transportSessionId: "cloud-agent-1", origin: .remote)
        )
        guard case .awaitingApproval(let id) = decision else {
            throw TestError.assertion("Request pending must be awaitingApproval, got \(String(describing: decision))")
        }
        try expect(!id.isEmpty, "awaitingApproval id must be a stable digest")
        try expect(provider.approvalRequestCount == 1)
    }

    await test("router returns awaiting_approval without running messages_send") {
        let provider = TestSecurityApprovalProvider(decision: .pending)
        let gate = SecurityGate(approvalProvider: provider)
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await MessagesModule.register(on: router)
        let result = try await router.dispatch(
            toolName: "messages_send",
            arguments: ordinarySend()
        )
        guard case .object(let object) = result else {
            throw TestError.assertion("awaiting_approval must be an object, got \(result)")
        }
        try expect(object["approvalStatus"] == .string("awaiting_approval"))
        try expect(object["sent"] == .bool(false), "handler must not send")
        try expect(object["consequencePossible"] == .bool(false))
        try expect(object["resume"] != nil, "client must be told to retry after Allow")
        try expect(provider.approvalRequestCount == 1)
        let awaiting = await log.entries(withStatus: .awaiting)
        try expect(awaiting.count == 1, "audit must record awaiting_approval")
    }

    await test("retry after pending Allow reaches the handler without a second hang") {
        let provider = SequenceApprovalProvider([.pending, .allow])
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        let first = try await router.dispatch(
            toolName: "messages_send",
            arguments: ordinarySend(service: "auto")
        )
        guard case .object(let pendingObject) = first else {
            throw TestError.assertion("first call must be an object")
        }
        try expect(pendingObject["approvalStatus"] == .string("awaiting_approval"))
        try expect(pendingObject["sent"] == .bool(false))

        let second = try await router.dispatch(
            toolName: "messages_send",
            arguments: ordinarySend(service: "auto")
        )
        guard case .object(let allowedObject) = second else {
            throw TestError.assertion("retry after Allow must reach the handler")
        }
        try expect(allowedObject["approvalStatus"] == nil,
                   "handler result must not look like awaiting_approval")
        try expect(allowedObject["sent"] == .bool(false),
                   "auto service still fail-closes; proves handler ran")
        try expect(provider.requestCount == 2)
    }
}

// MARK: - Helpers

private func ordinarySend(
    recipient: String = "+15551234567",
    service: String = "iMessage",
    confirm: String = "SEND",
    omitService: Bool = false,
    extra: [String: Value] = [:]
) -> Value {
    var args: [String: Value] = [
        "recipient": .string(recipient),
        "body": .string("policy probe"),
        "confirm": .string(confirm)
    ]
    if !omitService {
        args["service"] = .string(service)
    }
    for (key, value) in extra {
        args[key] = value
    }
    return .object(args)
}

private func localSession(_ id: String) -> ToolDispatchContext {
    ToolDispatchContext(transportSessionId: id, origin: .local)
}

private func enforceMessages(
    gate: SecurityGate,
    tier: SecurityTier,
    arguments: Value,
    context: ToolDispatchContext
) async -> GateDecision {
    await gate.enforce(
        toolName: "messages_send",
        tier: tier,
        neverAutoApprove: false,
        arguments: arguments,
        module: "messages",
        context: context
    )
}

private func expectAllow(_ decision: GateDecision, _ msg: String) throws {
    switch decision {
    case .allow:
        break
    default:
        throw TestError.assertion("\(msg): expected .allow, got \(String(describing: decision))")
    }
}

private func withToolOverride(
    _ toolName: String,
    _ tier: SecurityTier,
    _ body: () async throws -> Void
) async throws {
    let key = BridgeDefaults.tierOverrides
    let previous = UserDefaults.standard.object(forKey: key)
    defer {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    UserDefaults.standard.set([toolName: tier.rawValue], forKey: key)
    try await body()
}

/// Deterministic multi-call approval provider for pending → Allow retry tests.
final class SequenceApprovalProvider: @unchecked Sendable, SecurityApprovalProviding {
    private let lock = NSLock()
    private var remaining: [SecurityApprovalDecision]
    private(set) var requestCount = 0

    init(_ decisions: [SecurityApprovalDecision]) {
        remaining = decisions
    }

    func requestPermission() async {}

    func requestApproval(
        title: String,
        body: String,
        allowAlwaysAllowAction: Bool,
        forceModalReview: Bool
    ) async -> SecurityApprovalDecision {
        lock.withLock {
            requestCount += 1
            if remaining.isEmpty { return .deny }
            return remaining.removeFirst()
        }
    }

    func sendFireAndForget(context: ExecutionNotificationContext) async {}
}
