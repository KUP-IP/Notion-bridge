// ConnectorContinuityTests.swift — PKT-1296
// Connector execution receipts, governed serialize queue, HTTP/1.1 overlap drain.

import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import TheBridgeLib

private final class ContinuityFlag: @unchecked Sendable {
    var ran = false
    var names = ["alpha", "beta"]
}

func runConnectorContinuityTests() async {
    print("\n🔌 ConnectorContinuity (PKT-1296 · delivery + executed truth)")

    await test("Continuity: pre-dispatch lease expiry is executed=false") {
        let classified = ConnectorContinuity.classify(
            leaseExpiredBeforeDispatch: true,
            generationChanged: false,
            dispatched: false,
            handlerFailed: false,
            transportFailed: false,
            responseLost: false
        )
        try expect(classified.executed == .false)
        try expect(classified.outcome == .preDispatchLeaseExpiry)
    }

    await test("Continuity: response-loss after dispatch is executed=unknown") {
        let classified = ConnectorContinuity.classify(
            leaseExpiredBeforeDispatch: false,
            generationChanged: false,
            dispatched: true,
            handlerFailed: false,
            transportFailed: false,
            responseLost: true
        )
        try expect(classified.executed == .unknown)
        try expect(classified.outcome == .responseLoss)
    }

    await test("Continuity: handler failure is executed=true and does not classify as transport") {
        let classified = ConnectorContinuity.classify(
            leaseExpiredBeforeDispatch: false,
            generationChanged: false,
            dispatched: true,
            handlerFailed: true,
            transportFailed: false,
            responseLost: false
        )
        try expect(classified.executed == .true, "handler ran ⇒ executed=true")
        try expect(classified.outcome == .handlerFailure)
    }

    await test("Continuity: auth health keeps oauth-ready, inactive, mismatch, and loopback distinct") {
        try expect(ConnectorContinuity.classifyAuthHealth(
            remote: true, oauthConfigured: true, tokenValid: true, tokenMatchesSession: true
        ) == .oauthReady)
        try expect(ConnectorContinuity.classifyAuthHealth(
            remote: true, oauthConfigured: false, tokenValid: false, tokenMatchesSession: false
        ) == .oauthInactive)
        try expect(ConnectorContinuity.classifyAuthHealth(
            remote: true, oauthConfigured: true, tokenValid: true, tokenMatchesSession: false
        ) == .tokenMismatch)
        try expect(ConnectorContinuity.classifyAuthHealth(
            remote: false, oauthConfigured: false, tokenValid: false, tokenMatchesSession: false
        ) == .loopbackExempt)
    }

    await test("Continuity: expired lease proves executed=false without running the operation") {
        let queue = ConnectorCallQueue(connectorGeneration: "gen-test", leaseTTL: 60)
        await queue.expireLease(for: "sess-1", at: Date())
        let flag = ContinuityFlag()
        let (_, receipt) = await queue.runSerialized(sessionKey: "sess-1", toolName: "ping") {
            () -> Result<String, ConnectorDeliveryError> in
            flag.ran = true
            return .success("should-not-run")
        }
        try expect(!flag.ran, "pre-dispatch expiry must not invoke the handler")
        try expect(receipt.executed == .false)
        try expect(receipt.outcome == .preDispatchLeaseExpiry)
        try expect(receipt.schemaVersion == ConnectorContinuity.schemaVersion)
        try expect(receipt.connectorGeneration == "gen-test")
    }

    await test("Continuity: handler failure leaves a sibling tool executable") {
        let queue = ConnectorCallQueue(connectorGeneration: "gen-iso")
        let tools = ContinuityFlag()
        let (_, failed) = await queue.runSerialized(sessionKey: "iso", toolName: "alpha") {
            () -> Result<String, ConnectorDeliveryError> in
            tools.names.removeAll { $0 == "alpha" }
            return .failure(.handler)
        }
        try expect(failed.executed == .true)
        try expect(failed.outcome == .handlerFailure)
        try expect(tools.names.contains("beta"), "sibling tool must remain available")
        let (ok, okReceipt) = await queue.runSerialized(sessionKey: "iso", toolName: "beta") {
            () -> Result<String, ConnectorDeliveryError> in
            .success("beta-ok")
        }
        try expect(ok == "beta-ok")
        try expect(okReceipt.executed == .true)
        try expect(okReceipt.outcome == .success)
    }

    await test("Continuity: 4-parallel ×3 consecutive runs have zero unexplained drops") {
        let queue = ConnectorCallQueue(connectorGeneration: "gen-parallel")
        for round in 1...3 {
            let results = await withTaskGroup(
                of: ConnectorCallReceipt.self,
                returning: [ConnectorCallReceipt].self
            ) { group in
                for i in 1...4 {
                    group.addTask {
                        let (_, receipt) = await queue.runSerialized(
                            sessionKey: "parallel",
                            toolName: "ping-\(round)-\(i)",
                            queued: true
                        ) {
                            () -> Result<Int, ConnectorDeliveryError> in
                            try? await Task.sleep(nanoseconds: 2_000_000)
                            return .success(i)
                        }
                        return receipt
                    }
                }
                var collected: [ConnectorCallReceipt] = []
                for await receipt in group { collected.append(receipt) }
                return collected
            }
            try expect(results.count == 4, "round \(round) dropped calls: \(results.count)")
            for receipt in results {
                try expect(receipt.executed == .true, "round \(round) unexplained drop: \(receipt.outcome.rawValue)")
                try expect(receipt.retryDisposition == .serialized)
            }
        }
    }

    await test("Continuity: overlapping HTTP/1.1 heads do not drop a sibling /health") {
        func decodeHead(_ raw: String) throws -> HTTPRequestHead {
            let channel = EmbeddedChannel()
            try channel.pipeline.configureHTTPServerPipeline().wait()
            var buf = channel.allocator.buffer(capacity: raw.utf8.count)
            buf.writeString(raw)
            try channel.writeInbound(buf)
            defer { _ = try? channel.finish() }
            guard let part = try channel.readInbound(as: HTTPServerRequestPart.self),
                  case .head(let head) = part else {
                throw TestError.assertion("expected a decoded .head")
            }
            return head
        }

        let raw = "GET /health HTTP/1.1\r\nHost: 127.0.0.1:9700\r\n\r\n"
        let headA = try decodeHead(raw)
        let headB = try decodeHead(raw)
        let channel = EmbeddedChannel()
        try await SSEServer.ingestHTTPPartsForTesting(on: channel, parts: [
            .head(headA),
            .head(headB),
            .end(nil),
            .end(nil)
        ])
        (channel.eventLoop as! EmbeddedEventLoop).run()
        var statuses: [Int] = []
        while let out = try? channel.readOutbound(as: HTTPServerResponsePart.self) {
            if case .head(let h) = out { statuses.append(Int(h.status.code)) }
        }
        _ = try? channel.finish()
        try expect(statuses.count == 2, "overlapping heads must emit two responses, got \(statuses)")
        try expect(statuses.allSatisfy { $0 == 200 }, "both /health responses must be 200, got \(statuses)")
    }
}
