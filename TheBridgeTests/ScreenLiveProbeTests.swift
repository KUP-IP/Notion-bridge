// ScreenLiveProbeTests.swift — opt-in live Screen adapter verification
// TheBridge · Tests
//
// Excluded from the canonical floor unless BRIDGE_SCREEN_LIVE_PROBE=1.
// The process-level deadline lives in scripts/screen-live-probe.sh so a
// synchronous Vision or framework stall cannot wedge verification forever.

import Foundation
import MCP
import TheBridgeLib

func runScreenLiveProbe() async {
    print("\n📸 Screen live adapter probe")

    await test("live screen_ocr returns a normal response on a granted host") {
        guard ProcessInfo.processInfo.environment["BRIDGE_SCREEN_LIVE_PROBE"] == "1" else {
            throw TestError.assertion("live Screen probe requires BRIDGE_SCREEN_LIVE_PROBE=1")
        }

        let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        let registered = await ScreenModule.registerLiveProbe(on: router)
        try expect(registered, "live Screen runtime refused explicit probe registration")

        let result = try await router.dispatch(
            toolName: "screen_ocr",
            arguments: .object(["target": .string("display"), "displayIndex": .int(0)])
        )

        guard case .object(let response) = result else {
            throw TestError.assertion("live screen_ocr returned a non-object response: \(result)")
        }
        try expect(response["error"] == nil, "live screen_ocr returned an error envelope: \(result)")
        guard case .string(let text)? = response["text"] else {
            throw TestError.assertion("live screen_ocr response missing string text: \(result)")
        }
        guard case .double(let confidence)? = response["confidence"] else {
            throw TestError.assertion("live screen_ocr response missing double confidence: \(result)")
        }
        guard case .array(let bounds)? = response["bounds"] else {
            throw TestError.assertion("live screen_ocr response missing bounds array: \(result)")
        }

        let receipt: [String: Any] = [
            "status": "passed",
            "probe": "screen_ocr_live_granted",
            "textLength": text.count,
            "confidence": confidence,
            "boundsCount": bounds.count,
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw TestError.assertion("failed to encode live probe receipt")
        }
        print("SCREEN_LIVE_PROBE_RECEIPT=\(json)")
    }
}
