// BridgeFeatureFlagsTests.swift — WS-C (v2.3, PKT-798)
// Enforces the fail-closed invariant for the PermissionView capability
// gates: default OFF, only an exact "1" enables, and HTTP stays bound to
// the same env key the WS-B transport router uses.

import Foundation
import TheBridgeLib

func runBridgeFeatureFlagsTests() async {
    print("\n\u{1F510} BridgeFeatureFlags (PKT-798 · WS-C)")

    await test("default (empty env): all gates OFF") {
        let f = BridgeFeatureFlags(environment: [:])
        try expect(
            f.httpEnabled == false
                && f.voiceEnabled == false
                && f.worktreeOwnershipEnabled == false,
                   "fail-closed default violated: \(f)")
        try expect(f.worktreeOwnershipMode == "disabled")
    }

    await test("BRIDGE_ENABLE_HTTP=1 enables only HTTP") {
        let f = BridgeFeatureFlags(environment: ["BRIDGE_ENABLE_HTTP": "1"])
        try expect(f.httpEnabled == true && f.voiceEnabled == false, "got \(f)")
    }

    await test("BRIDGE_ENABLE_VOICE=1 enables only Voice") {
        let f = BridgeFeatureFlags(environment: ["BRIDGE_ENABLE_VOICE": "1"])
        try expect(
            f.voiceEnabled == true
                && f.httpEnabled == false
                && f.worktreeOwnershipEnabled == false,
            "got \(f)"
        )
    }

    await test("BRIDGE_ENABLE_WORKTREE_OWNERSHIP=1 enables only experimental C0") {
        let f = BridgeFeatureFlags(environment: [
            "BRIDGE_ENABLE_WORKTREE_OWNERSHIP": "1"
        ])
        try expect(
            f.worktreeOwnershipEnabled == true
                && f.httpEnabled == false
                && f.voiceEnabled == false,
            "got \(f)"
        )
        try expect(f.worktreeOwnershipMode == "experimental")
    }

    await test("non-\"1\" values keep every gate disabled (true/0/yes)") {
        for v in ["true", "0", "yes", "", "TRUE"] {
            let f = BridgeFeatureFlags(environment: [
                "BRIDGE_ENABLE_HTTP": v, "BRIDGE_ENABLE_VOICE": v,
                "BRIDGE_ENABLE_WORKTREE_OWNERSHIP": v,
            ])
            try expect(
                f.httpEnabled == false
                    && f.voiceEnabled == false
                    && f.worktreeOwnershipEnabled == false,
                       "value \"\(v)\" must not enable, got \(f)")
        }
    }

    await test("HTTP key is shared with TransportRouter (no split source of truth)") {
        try expect(BridgeFeatureFlags.httpEnableEnvKey == TransportRouter.httpEnableEnvKey,
                   "HTTP env key drift between flags and transport router")
        try expect(BridgeFeatureFlags.voiceEnableEnvKey == "BRIDGE_ENABLE_VOICE",
                   "voice env key drift")
        try expect(
            BridgeFeatureFlags.worktreeOwnershipEnableEnvKey
                == "BRIDGE_ENABLE_WORKTREE_OWNERSHIP",
            "worktree ownership env key drift"
        )
    }
}
