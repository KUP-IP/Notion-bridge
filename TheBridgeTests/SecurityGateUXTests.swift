// SecurityGateUXTests.swift
// TheBridge · Tests
//
// fb-securitygate — SecurityGate UX fixes. Evidence (05-16, 06-03):
//   (1) re-tier genuinely read-only tools to .open  — already shipped (FB-5);
//       guarded by ReadOnlyTierAuditTests. A regression check is added here too.
//   (2) make "Always Allow" module/session-scoped instead of strictly per-tool
//       so an Always-Allow on one tool covers siblings, AND so a 3-way-parallel
//       Request-tier burst coalesces into ONE prompt instead of three that time
//       out. Covered by:
//         · ApprovalCoalescer: pure concurrency-collapsing contract (begin /
//           drain / idempotency / per-key isolation / waiter resumption count);
//         · ToolRouter.resolveEffectiveTier: per-tool > per-module > default
//           precedence. neverAutoApprove is not an execution floor (#258).
//   (3) make the approval UX less easy to miss than the silent 30s timeout —
//       MCP callers wait 25s then receive awaiting_approval (not auto-deny);
//       prompts are posted time-sensitive; the wait is injectable so tests stay fast.
//   (4) #258 live-verify: remote-origin Request publishes a menu-bar Confirm
//       surface + ATTENTION count even when the UN banner is not visible.
//
// Harness: standalone executable runner (no XCTest). Entry point
// `runSecurityGateUXTests()` is invoked from TestRunner.swift.

import Foundation
import AppKit
import UserNotifications
import MCP
import TheBridgeLib

func runSecurityGateUXTests() async {
    print("\n🛡️  SecurityGate UX Tests (fb-securitygate)")

    // ============================================================
    // MARK: - C1 modal approval must fail closed
    // ============================================================

    await test("Modal approval: first/default button denies") {
        let decision = NotificationApprovalManager.decisionForModalResponse(.alertFirstButtonReturn)
        if case .deny = decision {} else {
            try expect(false, "the first/default modal response must deny")
        }
    }

    await test("Modal approval: only explicit second button allows") {
        let decision = NotificationApprovalManager.decisionForModalResponse(.alertSecondButtonReturn)
        if case .allow = decision {} else {
            try expect(false, "only the explicit Allow button may approve")
        }
    }

    await test("Modal approval: cancel and unknown responses deny") {
        for response in [NSApplication.ModalResponse.cancel, NSApplication.ModalResponse(rawValue: 9999)] {
            let decision = NotificationApprovalManager.decisionForModalResponse(response)
            if case .deny = decision {} else {
                try expect(false, "cancel/unknown modal responses must deny")
            }
        }
    }

    // ============================================================
    // MARK: - (race fix) drain-before-park lost-wakeup regression
    // ============================================================

    await test("Coalescer race: owner resolves before waiter parks → waiter still resumes") {
        let mgr = NotificationApprovalManager()
        _ = mgr.reserveCoalesced(coalesceKey: "kRace", identifier: "ownerRace")
        let (isFirst, token) = mgr.reserveCoalesced(coalesceKey: "kRace", identifier: "ownerRace")
        try expect(isFirst == false, "second caller for the same key is a coalesced waiter")
        // Owner resolves BEFORE the waiter parks → must buffer the decision (nothing to resume yet).
        let resumeNow = mgr.drainCoalescedWaiters(forIdentifier: "ownerRace", decision: .allow)
        try expect(resumeNow.isEmpty, "no continuation parked yet, so nothing to resume synchronously")
        // Waiter parks AFTER the drain → must resume immediately with the buffered decision (no hang).
        let decision = await withCheckedContinuation { (c: CheckedContinuation<NotificationApprovalManager.ApprovalDecision, Never>) in
            mgr.parkCoalescedWaiter(token: token, continuation: c)
        }
        if case .allow = decision {} else {
            try expect(false, "drain-before-park must resume with the buffered .allow decision")
        }
    }

    // ============================================================
    // MARK: - (2) ApprovalCoalescer — in-flight prompt collapsing
    // ============================================================

    await test("Coalescer: first caller for a key owns the prompt") {
        var c = ApprovalCoalescer()
        let first = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        try expect(first, "first call for a fresh key must return true (owns prompt)")
        try expect(c.inFlightPromptCount == 1, "exactly one prompt in flight")
    }

    await test("Coalescer: later callers for same key join (no second prompt)") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        let second = c.begin(coalesceKey: "k1", identifier: "id2", waiterToken: "w2")
        let third = c.begin(coalesceKey: "k1", identifier: "id3", waiterToken: "w3")
        try expect(!second, "second call for same key must join (return false)")
        try expect(!third, "third call for same key must join (return false)")
        try expect(c.inFlightPromptCount == 1, "still exactly one prompt in flight for the burst")
    }

    await test("Coalescer: drain returns every parked waiter exactly once") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        _ = c.begin(coalesceKey: "k1", identifier: "id2", waiterToken: "w2")
        _ = c.begin(coalesceKey: "k1", identifier: "id3", waiterToken: "w3")
        let drained = c.drain(forIdentifier: "id1")
        try expect(Set(drained) == ["w2", "w3"],
                   "drain must return the two joined waiters (not the owner): \(drained)")
        try expect(c.inFlightPromptCount == 0, "prompt cleared after drain")
    }

    await test("Coalescer: drain is idempotent (second drain is empty)") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        _ = c.begin(coalesceKey: "k1", identifier: "id2", waiterToken: "w2")
        _ = c.drain(forIdentifier: "id1")
        let again = c.drain(forIdentifier: "id1")
        try expect(again.isEmpty, "draining an already-resolved identifier must be empty (no double-resume)")
    }

    await test("Coalescer: drain of unknown identifier is empty (timeout-vs-answer race safe)") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        let unknown = c.drain(forIdentifier: "id-nope")
        try expect(unknown.isEmpty, "unknown identifier drains to empty")
        // The real key is still in flight (its identifier was not the unknown one).
        try expect(c.inFlightPromptCount == 1, "unrelated drain must not clear a live prompt")
    }

    await test("Coalescer: distinct keys do not collapse into each other") {
        var c = ApprovalCoalescer()
        let a = c.begin(coalesceKey: "kA", identifier: "idA", waiterToken: "wA")
        let b = c.begin(coalesceKey: "kB", identifier: "idB", waiterToken: "wB")
        try expect(a && b, "two different keys each own their own prompt")
        try expect(c.inFlightPromptCount == 2, "two distinct prompts in flight")
        let drainedA = c.drain(forIdentifier: "idA")
        try expect(drainedA.isEmpty, "key A had no extra waiters")
        try expect(c.inFlightPromptCount == 1, "draining A leaves B in flight")
    }

    await test("Coalescer: a new burst can start after the prior key resolved") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        _ = c.drain(forIdentifier: "id1")
        // Same key again — must be treated as a fresh first caller.
        let firstAgain = c.begin(coalesceKey: "k1", identifier: "id2", waiterToken: "w2")
        try expect(firstAgain, "after resolution the same key starts a fresh prompt")
    }

    await test("Coalescer: takeWaitersKeepingInFlight leaves the prompt in flight") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "owner")
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        let taken = c.takeWaitersKeepingInFlight(forIdentifier: "id1")
        try expect(taken == ["w1"], "parked waiters must be returned")
        try expect(c.inFlightPromptCount == 1, "pending MCP return must keep the prompt in flight")
        try expect(c.coalesceKey(forIdentifier: "id1") == "k1")
        let retryIsFirst = c.begin(coalesceKey: "k1", identifier: "id2", waiterToken: "retry")
        try expect(!retryIsFirst, "retry must coalesce into the still-open prompt")
    }

    // ============================================================
    // MARK: - (2) Effective-tier resolution: tool > module > default
    // ============================================================

    await test("resolveEffectiveTier: no overrides → registered default") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_update", module: "snippets",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: [:]
        )
        try expect(t == .request, "with no overrides, the registered tier wins: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: module override covers a sibling tool") {
        // Always-Allow was granted on snippets_update → snippets module = .notify.
        // snippets_rename (a sibling, never individually prompted) inherits it.
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_rename", module: "snippets",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: ["snippets": "notify"]
        )
        try expect(t == .notify,
                   "a module-scoped Always-Allow must cover sibling tools: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: per-tool override beats module override") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_rename", module: "snippets",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: ["snippets_rename": "request"],
            moduleOverrides: ["snippets": "notify"]
        )
        try expect(t == .request,
                   "a more-specific per-tool override must win over the module override: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: neverAutoApprove no longer forces .request") {
        // #258 — former neverAuto tools honor per-tool / per-module overrides.
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_delete", module: "snippets",
            registeredTier: .request, neverAutoApprove: true,
            toolOverrides: ["snippets_delete": "notify"],
            moduleOverrides: ["snippets": "open"]
        )
        try expect(t == .notify,
                   "Always Allow / Tools override must win over neverAutoApprove: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: module override ignored when module is empty") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "some_tool", module: "",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: ["snippets": "notify"]
        )
        try expect(t == .request,
                   "an empty module must not match any module override: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: unrelated module override does not leak") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send", module: "messages",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: ["snippets": "notify"]
        )
        try expect(t == .request,
                   "a snippets module grant must not affect the messages module: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: messages_send Open override is honored (downgradable)") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send", module: "messages",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: ["messages_send": "open"], moduleOverrides: [:]
        )
        try expect(t == .open, "messages_send must follow an operator Open override: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: mail_trash and snippets_delete honor Open overrides") {
        for name in ["mail_trash", "snippets_delete"] {
            let t = ToolRouter.resolveEffectiveTier(
                toolName: name, module: name == "mail_trash" ? "mail" : "snippets",
                registeredTier: .request, neverAutoApprove: true,
                toolOverrides: [name: "open"],
                moduleOverrides: ["mail": "open", "snippets": "open"]
            )
            try expect(t == .open,
                       "\(name) must honor a Tools Open override: got \(t.rawValue)")
        }
    }

    // ============================================================
    // MARK: - (2) End-to-end: persisted module override resolves allow
    // ============================================================

    await test("module Always-Allow makes a sibling Request-tier call execute without prompt") {
        // Persist a module-scoped Always-Allow exactly as SecurityGate would,
        // then confirm a sibling tool resolves to .notify (which SecurityGate
        // enforces as .allow, no prompt). Uses a scratch suite to avoid touching
        // real user defaults.
        let suiteName = "fb-securitygate.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestError.assertion("could not create scratch UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let modOverrides = ["snippets": SecurityTier.notify.rawValue]
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_import", module: "snippets",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: modOverrides
        )
        try expect(t == .notify, "sibling resolves to .notify under a module grant")

        // And .notify enforces to .allow with no approval interaction.
        let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let decision = await gate.enforce(
            toolName: "snippets_import", tier: t, neverAutoApprove: false,
            arguments: .object(["payload": .string("x")]), module: "snippets"
        )
        switch decision {
        case .allow: break
        default: throw TestError.assertion("expected .allow for a .notify-resolved sibling, got \(decision)")
        }
    }

    // ============================================================
    // MARK: - (1) Regression: read-only snippets tools remain .open
    // ============================================================

    await test("regression: snippets read-only tools stay tier .open") {
        let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await SnippetsModule.register(on: router)
        let regs = await router.registrations(forModule: "snippets")
        let byName = Dictionary(regs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for name in ["snippets_list", "snippets_get", "snippets_search"] {
            guard let reg = byName[name] else {
                throw TestError.assertion("\(name) not registered")
            }
            try expect(reg.tier == .open, "\(name) must remain .open, got \(reg.tier.rawValue)")
        }
    }

    // ============================================================
    // MARK: - (3) Approval timeout is configurable (less-missable UX)
    // ============================================================


    await test("SecurityGate source contains no runtime approval inference inputs") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("TheBridge/Security/SecurityGate.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in ["thebridgetests", "notionbridgetests", "CommandLine.arguments",
                          "ProcessInfo.processInfo", "--multi-instance", "runningInTestProcess"] {
            try expect(!source.contains(forbidden), "production approval source must not inspect \(forbidden)")
        }
    }

    await test("explicit denial prevents the request-tier handler from running") {
        final class HandlerProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int { lock.withLock { _count } }
            func hit() { lock.withLock { _count += 1 } }
        }
        let provider = TestSecurityApprovalProvider(decision: .deny)
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        let probe = HandlerProbe()
        await router.register(ToolRegistration(
            name: "c1_denial_probe",
            module: "security",
            tier: .request,
            description: "C1 denial handler probe",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in probe.hit(); return .object(["ran": .bool(true)]) }
        ))
        do {
            _ = try await router.dispatch(
                toolName: "c1_denial_probe",
                arguments: .object([
                    "processName": .string("thebridgetests"),
                    "legacyProcess": .string("notionbridgetests"),
                    "arguments": .string("--multi-instance")
                ])
            )
            throw TestError.assertion("denied request unexpectedly returned")
        } catch let error as ToolRouterError {
            guard case .securityRejection = error else { throw error }
        }
        try expect(probe.count == 0, "modal/provider denial must invoke no handler")
    }

    await test("explicit fake provider supplies deterministic test approval") {
        let provider = TestSecurityApprovalProvider(decision: .allow)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await gate.enforce(
            toolName: "test_request",
            tier: .request,
            arguments: .object(["value": .string("x")])
        )
        switch decision {
        case .allow: break
        default: throw TestError.assertion("explicit fake approval must allow, got \(decision)")
        }
        try expect(provider.approvalRequestCount == 1, "fake provider must be called exactly once")
    }

    // ============================================================
    // MARK: - #258 notify-default + Always Allow everywhere
    // ============================================================

    await test("ToolRegistration default tier is Notify unless explicitly Request") {
        let reg = ToolRegistration(
            name: "issue258_default_tier",
            module: "issue258",
            description: "default-tier probe",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in .object(["ok": .bool(true)]) }
        )
        try expect(reg.tier == .notify, "new tools default to .notify; got \(reg.tier.rawValue)")
        try expect(reg.neverAutoApprove == false, "default neverAutoApprove must be false")
    }

    await test("migration: former neverAuto .notify registration is not hard-forced to Request") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "standing_orders_delete", module: "standing_orders",
            registeredTier: .notify, neverAutoApprove: true,
            toolOverrides: [:], moduleOverrides: [:]
        )
        try expect(t == .notify,
                   "existing installs must stop forcing Request for former neverAuto tools: got \(t.rawValue)")
    }

    await test("standing_orders_delete Confirm card offers Always Allow") {
        let provider = TestSecurityApprovalProvider(decision: .allow)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await gate.enforce(
            toolName: "standing_orders_delete",
            tier: .request,
            neverAutoApprove: true,
            arguments: .object(["id": .string("ord-258")]),
            module: "standing_orders"
        )
        switch decision {
        case .allow: break
        default: throw TestError.assertion("expected .allow, got \(decision)")
        }
        try expect(provider.lastAllowAlwaysAllowAction == true,
                   "standing_orders_delete Confirm must offer Always Allow")
        try expect(provider.approvalRequestCount == 1)
    }

    await test("Always Allow on former neverAuto tool sticks Notify and skips the next card") {
        let toolName = "issue258_never_auto_delete"
        let module = "issue258_mod"
        let perTool = BridgeDefaults.tierOverrides
        let perModule = BridgeDefaults.moduleTierOverrides
        var tools = UserDefaults.standard.dictionary(forKey: perTool) as? [String: String] ?? [:]
        var mods = UserDefaults.standard.dictionary(forKey: perModule) as? [String: String] ?? [:]
        let priorTool = tools[toolName]
        let priorMod = mods[module]
        defer {
            var t = UserDefaults.standard.dictionary(forKey: perTool) as? [String: String] ?? [:]
            var m = UserDefaults.standard.dictionary(forKey: perModule) as? [String: String] ?? [:]
            if let priorTool { t[toolName] = priorTool } else { t.removeValue(forKey: toolName) }
            if let priorMod { m[module] = priorMod } else { m.removeValue(forKey: module) }
            UserDefaults.standard.set(t, forKey: perTool)
            UserDefaults.standard.set(m, forKey: perModule)
        }

        let firstProvider = TestSecurityApprovalProvider(decision: .alwaysAllow)
        let firstGate = SecurityGate(approvalProvider: firstProvider)
        let first = await firstGate.enforce(
            toolName: toolName,
            tier: .request,
            neverAutoApprove: true,
            arguments: .object(["id": .string("x")]),
            module: module
        )
        switch first {
        case .allow: break
        default: throw TestError.assertion("Always Allow must admit the first call, got \(first)")
        }
        try expect(firstProvider.lastAllowAlwaysAllowAction == true)

        tools = UserDefaults.standard.dictionary(forKey: perTool) as? [String: String] ?? [:]
        mods = UserDefaults.standard.dictionary(forKey: perModule) as? [String: String] ?? [:]
        try expect(tools[toolName] == SecurityTier.notify.rawValue,
                   "Always Allow must persist per-tool Notify")
        try expect(mods[module] == SecurityTier.notify.rawValue,
                   "Always Allow must persist module Notify")

        let sticky = ToolRouter.resolveEffectiveTier(
            toolName: toolName, module: module,
            registeredTier: .request, neverAutoApprove: true,
            toolOverrides: tools, moduleOverrides: mods
        )
        try expect(sticky == .notify, "sticky effective tier must be Notify; got \(sticky.rawValue)")

        let secondProvider = TestSecurityApprovalProvider(decision: .deny)
        let secondGate = SecurityGate(approvalProvider: secondProvider)
        let second = await secondGate.enforce(
            toolName: toolName,
            tier: sticky,
            neverAutoApprove: true,
            arguments: .object(["id": .string("x")]),
            module: module
        )
        switch second {
        case .allow: break
        default: throw TestError.assertion("sticky Notify must not prompt; got \(second)")
        }
        try expect(secondProvider.approvalRequestCount == 0,
                   "second former-neverAuto call must not show a Confirm card")
    }

    await test("Tools UI tier matches runtime effective tier after Always Allow") {
        let toolOverrides = ["standing_orders_delete": "notify"]
        let moduleOverrides = ["standing_orders": "notify"]
        let runtime = ToolRouter.resolveEffectiveTier(
            toolName: "standing_orders_delete",
            module: "standing_orders",
            registeredTier: .request,
            neverAutoApprove: true,
            toolOverrides: toolOverrides,
            moduleOverrides: moduleOverrides
        )
        let ui = ToolTierResolution.effectiveTier(
            toolName: "standing_orders_delete",
            module: "standing_orders",
            registeredTier: "request",
            toolOverrides: toolOverrides,
            moduleOverrides: moduleOverrides
        )
        try expect(runtime == .notify && ui == "notify",
                   "UI pill (\(ui)) must match runtime (\(runtime.rawValue))")
    }

    await test("standing_orders_delete is registered Request without neverAutoApprove floor") {
        let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await StandingOrdersModule.register(on: router)
        let regs = await router.registrations(forModule: "standing_orders")
        guard let del = regs.first(where: { $0.name == "standing_orders_delete" }) else {
            throw TestError.assertion("standing_orders_delete must be registered")
        }
        try expect(del.tier == .request, "delete stays Confirm-first; got \(del.tier.rawValue)")
        try expect(del.neverAutoApprove == false, "no hard no-Always-Allow floor")
    }

    // ============================================================
    // MARK: - Remote-origin Confirm surface (#258 live-verify blocker)
    // ============================================================

    await test("PendingApprovalSurface publish then snapshot") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        let prompt = PendingApprovalPrompt(
            id: "p1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=ad74d213",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .remote
        )
        PendingApprovalSurface.shared.publish(prompt)
        try expect(PendingApprovalSurface.shared.pendingCount == 1)
        try expect(PendingApprovalSurface.shared.snapshot().map(\.id) == ["p1"])
        try expect(PendingApprovalSurface.shared.prompt(id: "p1")?.origin == .remote)
    }

    await test("PendingApprovalSurface remove is idempotent") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        PendingApprovalSurface.shared.publish(PendingApprovalPrompt(
            id: "p2", title: "t", body: "b", toolName: "tool",
            allowAlwaysAllow: true, origin: .local
        ))
        PendingApprovalSurface.shared.remove(id: "p2")
        PendingApprovalSurface.shared.remove(id: "p2")
        try expect(PendingApprovalSurface.shared.pendingCount == 0)
    }

    await test("remote-origin Request publishes menu-bar Confirm surface") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        let provider = TestSecurityApprovalProvider(decision: .pending)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await gate.enforce(
            toolName: "standing_orders_delete",
            tier: .request,
            arguments: .object(["id": .string("ad74d213")]),
            module: "standing_orders",
            context: ToolDispatchContext(
                transportSessionId: ToolDispatchContext.remoteConnectorJSONSessionID,
                origin: .remote,
                client: "remote-connector"
            )
        )
        switch decision {
        case .awaitingApproval: break
        default: throw TestError.assertion("expected awaitingApproval, got \(decision)")
        }
        try expect(PendingApprovalSurface.shared.pendingCount == 1,
                   "remote-origin Confirm must land on the menu-bar surface")
        try expect(PendingApprovalSurface.shared.snapshot().first?.origin == .remote,
                   "surface must record remote origin, not drop it")
        try expect(PendingApprovalSurface.shared.snapshot().first?.allowAlwaysAllow == true)
    }

    await test("local-origin Request also publishes Confirm surface") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        let provider = TestSecurityApprovalProvider(decision: .pending)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await gate.enforce(
            toolName: "standing_orders_delete",
            tier: .request,
            arguments: .object(["id": .string("local-1")]),
            module: "standing_orders",
            context: .localDefault
        )
        switch decision {
        case .awaitingApproval: break
        default: throw TestError.assertion("expected awaitingApproval, got \(decision)")
        }
        try expect(PendingApprovalSurface.shared.pendingCount == 1,
                   "local Confirm must also publish — origin is not a second gate")
    }

    await test("awaiting_approval keeps Confirm surface after MCP pending") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        let provider = TestSecurityApprovalProvider(decision: .pending)
        let gate = SecurityGate(approvalProvider: provider)
        _ = await gate.enforce(
            toolName: "standing_orders_delete",
            tier: .request,
            arguments: .object(["id": .string("keep-1")]),
            module: "standing_orders",
            context: ToolDispatchContext(
                transportSessionId: "cloud-agent-1",
                origin: .remote
            )
        )
        try expect(PendingApprovalSurface.shared.pendingCount == 1,
                   "after awaiting_approval the Confirm card must stay so ATTENTION > 0")
    }

    await test("Allow clears Confirm surface") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        let provider = TestSecurityApprovalProvider(decision: .allow)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await gate.enforce(
            toolName: "standing_orders_delete",
            tier: .request,
            arguments: .object(["id": .string("clear-1")]),
            module: "standing_orders",
            context: ToolDispatchContext(
                transportSessionId: ToolDispatchContext.remoteConnectorJSONSessionID,
                origin: .remote
            )
        )
        switch decision {
        case .allow: break
        default: throw TestError.assertion("expected .allow, got \(decision)")
        }
        try expect(PendingApprovalSurface.shared.pendingCount == 0,
                   "terminal Allow must clear the menu-bar Confirm card")
    }

    await test("Security ATTENTION includes pending Confirm count") {
        try expect(SecurityPostureMetrics.attentionTotal(credentialIssues: 0, pendingApprovals: 0) == 0)
        try expect(SecurityPostureMetrics.attentionTotal(credentialIssues: 2, pendingApprovals: 0) == 2)
        try expect(SecurityPostureMetrics.attentionTotal(credentialIssues: 0, pendingApprovals: 1) == 1,
                   "MAC ATTENTION must count in-flight Confirm, not only vault issues")
        try expect(SecurityPostureMetrics.attentionTotal(credentialIssues: 3, pendingApprovals: 2) == 5)
    }

    await test("Coalescer can look up identifier from coalesce key") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k-surface", identifier: "id-surface", waiterToken: "w1")
        try expect(c.identifier(forCoalesceKey: "k-surface") == "id-surface")
        try expect(c.identifier(forCoalesceKey: "missing") == nil)
    }

    await test("coalesceKey is shared between banner and menu-bar card") {
        let key = NotificationApprovalManager.coalesceKey(
            allowAlwaysAllowAction: true,
            title: "The Bridge wants to standing_orders_delete",
            body: "id=x"
        )
        let prompt = PendingApprovalPrompt(
            id: "k",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=x",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .remote
        )
        try expect(prompt.coalesceKey == key,
                   "menu-bar Allow must hash the same prompt as SECURITY_APPROVAL")
        try expect(key.hasPrefix("1"), "Always Allow cards use the SECURITY_APPROVAL key prefix")
    }

    await test("Notification content extension keeps default banner title/body visible") {
        let plist = try String(
            contentsOfFile: "NotificationContentExtension/Info.plist",
            encoding: .utf8
        )
        try expect(
            plist.contains("UNNotificationExtensionDefaultContentHidden"),
            "extension must declare DefaultContentHidden"
        )
        try expect(
            plist.contains("<key>UNNotificationExtensionDefaultContentHidden</key>\n\t\t\t<false/>"),
            "DefaultContentHidden=false so compact banners still show title/body when the custom UI does not load"
        )
    }

    // ============================================================
    // MARK: - Confirm body host (PR #260 live-fail: badge without actions)
    // ============================================================

    await test("pending Confirm status click presents Deny/Allow/Always Allow") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }
        PendingApprovalSurface.shared.publish(PendingApprovalPrompt(
            id: "click-1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=c96df73d",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .remote
        ))
        try expect(StatusBarController.shouldPresentConfirmOnStatusItemClick(pendingCount: 1),
                   "status-item click while pending must present Confirm")
        let titles = await MainActor.run { () -> [String] in
            ConfirmPanelHost.shared.handleStatusItemClick()
            return ConfirmPanelHost.shared.visibleActionTitles
        }
        let presented = await MainActor.run { ConfirmPanelHost.shared.isPresented }
        try expect(presented, "status-item click must open the Confirm body")
        try expect(titles == ["Deny", "Allow", "Always Allow"],
                   "Confirm body must show Deny/Allow/Always Allow, got \(titles)")
        try expect(PendingApprovalSurface.shared.pendingCount == 1,
                   "click must not clear the pending Confirm")
    }

    await test("badge stays until Confirm is resolved") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }
        PendingApprovalSurface.shared.publish(PendingApprovalPrompt(
            id: "badge-1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=keep",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .remote
        ))
        await MainActor.run { ConfirmPanelHost.shared.handleStatusItemClick() }
        let badgeAfterClick = await MainActor.run { ConfirmPanelHost.shared.badgeCount }
        try expect(badgeAfterClick == 1, "badge must survive status-item click, got \(badgeAfterClick)")
        await MainActor.run { ConfirmPanelHost.shared.handlePresentBodyRequest() }
        try expect(PendingApprovalSurface.shared.pendingCount == 1,
                   "present-body must not clear the badge")
        await MainActor.run { ConfirmPanelHost.shared.handleStatusItemClick() }
        try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented },
                   "second click while pending must keep the body open")
        try expect(PendingApprovalSurface.shared.pendingCount == 1)
    }

    await test("Always Allow from Confirm body sticks Notify") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }
        let overridesKey = BridgeDefaults.tierOverrides
        let prior = UserDefaults.standard.dictionary(forKey: overridesKey)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: overridesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overridesKey)
            }
        }
        var cleared = UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
        cleared.removeValue(forKey: "standing_orders_delete")
        UserDefaults.standard.set(cleared, forKey: overridesKey)

        let prompt = PendingApprovalPrompt(
            id: "aa-1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=sticky",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .remote
        )
        PendingApprovalSurface.shared.publish(prompt)
        let approvalManager = NotificationApprovalManager(approvalTimeout: 1)
        await MainActor.run { ConfirmPanelHost.shared.handleStatusItemClick() }
        try expect(await MainActor.run { ConfirmPanelHost.shared.visibleActionTitles.contains("Always Allow") })
        PendingApprovalSurface.shared.submit(id: prompt.id, decision: .alwaysAllow)
        _ = approvalManager
        try expect(PendingApprovalSurface.shared.pendingCount == 0,
                   "Always Allow must clear the Confirm surface")
        let stored = UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
        try expect(stored["standing_orders_delete"] == SecurityTier.notify.rawValue,
                   "Always Allow must persist Notify, got \(stored["standing_orders_delete"] ?? "nil")")
        await MainActor.run { ConfirmPanelHost.shared.handleSurfaceChange() }
        try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented } == false,
                   "resolved Confirm must hide the body")
    }

    await test("notification default tap and dismiss present body, do not Deny") {
        try expect(
            ConfirmPresentation.outcome(forNotificationActionIdentifier: UNNotificationDefaultActionIdentifier)
                == .presentBody,
            "banner tap must open Confirm, not Deny"
        )
        try expect(
            ConfirmPresentation.outcome(forNotificationActionIdentifier: UNNotificationDismissActionIdentifier)
                == .presentBody,
            "banner dismiss must not clear pending"
        )
        try expect(
            ConfirmPresentation.outcome(forNotificationActionIdentifier: "ALLOW_ACTION")
                == .resolve(.allow)
        )
        try expect(
            ConfirmPresentation.outcome(forNotificationActionIdentifier: "ALWAYS_ALLOW")
                == .resolve(.alwaysAllow)
        )
        try expect(
            ConfirmPresentation.outcome(forNotificationActionIdentifier: "CANCEL_ACTION")
                == .resolve(.deny)
        )
    }

    await test("remote Request publish auto-presents Confirm body") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }
        PendingApprovalSurface.shared.publish(PendingApprovalPrompt(
            id: "auto-1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=remote",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .remote
        ))
        let titles = await MainActor.run { () -> [String] in
            ConfirmPanelHost.shared.handleSurfaceChange()
            return ConfirmPanelHost.shared.visibleActionTitles
        }
        try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented })
        try expect(await MainActor.run { ConfirmPanelHost.shared.lastPresentReason } == .pendingRequest)
        try expect(titles.contains("Always Allow"))
        try expect(PendingApprovalSurface.shared.pendingCount == 1,
                   "auto-present must not clear pending")
    }

    await test("test process never opens a live Confirm NSPanel") {
        try expect(ConfirmPanelController.canPresentPanel == false,
                   "TheBridgeTests must not create a WindowServer Confirm panel")
        try expect(ConfirmPanelController.windowTitle == "Confirm")
    }
}
