import Foundation
import TheBridgeLib

func runRoutingCustodyStoreTests() async {
    print("\n🧾 Routing custody — atomic durable bootstrap")

    await test("routing custody: interrupted activation leaves prior revision active") {
        try withRoutingCustodyRoot { root in
            let store = RoutingCustodyStore(root: root)
            let first = try store.recordBootstrap(
                snapshotID: "snapshot-a",
                source: "runtime_exposure_generation",
                count: 8,
                verifiedAt: routingCustodyDate(1)
            )
            let activeBefore = try store.activeRevisionIDForTesting()
            store.setFaultForTesting(.beforeActivation)
            do {
                _ = try store.recordBootstrap(
                    snapshotID: "snapshot-b",
                    source: "runtime_exposure_generation",
                    count: 9,
                    verifiedAt: routingCustodyDate(2)
                )
                throw TestError.assertion("injected activation failure did not fire")
            } catch RoutingCustodyError.injectedFailure(.beforeActivation) {
                // expected
            }
            store.setFaultForTesting(nil)
            try expect(try store.activeRevisionIDForTesting() == activeBefore)
            try expect(try store.serverReadiness() == first)
        }
    }

    await test("routing custody: corrupt active revision falls back to manifest-valid prior") {
        try withRoutingCustodyRoot { root in
            let store = RoutingCustodyStore(root: root)
            let prior = try store.recordBootstrap(
                snapshotID: "snapshot-prior",
                source: "runtime_exposure_generation",
                count: 8,
                verifiedAt: routingCustodyDate(1)
            )
            _ = try store.recordBootstrap(
                snapshotID: "snapshot-corrupt",
                source: "runtime_exposure_generation",
                count: 9,
                verifiedAt: routingCustodyDate(2)
            )
            guard let corruptID = try store.activeRevisionIDForTesting() else {
                throw TestError.assertion("missing active revision")
            }
            try store.corruptPayloadForTesting(revisionID: corruptID)
            try expect(try store.serverReadiness() == prior,
                       "read recovery must select the prior checksum-valid revision")
        }
    }

    await test("routing custody: replacement store reads the same durable state") {
        try withRoutingCustodyRoot { root in
            let firstStore = RoutingCustodyStore(root: root)
            let expected = try firstStore.recordBootstrap(
                snapshotID: "replacement-proof",
                source: "runtime_exposure_generation",
                count: 8,
                verifiedAt: routingCustodyDate(1)
            )
            try firstStore.recordPrincipalContinuation(
                principalKey: "oauth-sub:replacement-user",
                authorityID: BridgeInitializeModule.toolName,
                at: routingCustodyDate(2)
            )

            let replacementStore = RoutingCustodyStore(root: root)
            try expect(try replacementStore.serverReadiness() == expected)
            try expect(try replacementStore.hasPrincipalContinuation("oauth-sub:replacement-user"))
        }
    }

    await test("routing custody: unchanged bootstrap and continuation are idempotent") {
        try withRoutingCustodyRoot { root in
            let store = RoutingCustodyStore(root: root)
            _ = try store.recordBootstrap(
                snapshotID: "idempotent-snapshot",
                source: "runtime_exposure_generation",
                count: 8,
                verifiedAt: routingCustodyDate(1)
            )
            try store.recordPrincipalContinuation(
                principalKey: "oauth-sub:idempotent-user",
                authorityID: BridgeInitializeModule.toolName,
                at: routingCustodyDate(2)
            )
            let activeBefore = try store.activeRevisionIDForTesting()
            let historyBefore = try store.priorRevisionIDsForTesting()

            _ = try store.recordBootstrap(
                snapshotID: "idempotent-snapshot",
                source: "runtime_exposure_generation",
                count: 8,
                verifiedAt: routingCustodyDate(3)
            )
            try store.recordPrincipalContinuation(
                principalKey: "oauth-sub:idempotent-user",
                authorityID: BridgeInitializeModule.toolName,
                at: routingCustodyDate(4)
            )

            try expect(try store.activeRevisionIDForTesting() == activeBefore)
            try expect(try store.priorRevisionIDsForTesting() == historyBefore)
        }
    }

    await test("routing custody: files are owner-only and persist digests rather than principal text") {
        try withRoutingCustodyRoot { root in
            let store = RoutingCustodyStore(root: root)
            _ = try store.recordBootstrap(
                snapshotID: "permissions-proof",
                source: "runtime_exposure_generation",
                count: 8,
                verifiedAt: routingCustodyDate(1)
            )
            let rawPrincipal = "oauth-sub:DO-NOT-PERSIST-RAW"
            try store.recordPrincipalContinuation(
                principalKey: rawPrincipal,
                authorityID: BridgeInitializeModule.toolName,
                at: routingCustodyDate(2)
            )

            let fm = FileManager.default
            let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            var combined = Data()
            while let url = enumerator?.nextObject() as? URL {
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                let attributes = try fm.attributesOfItem(atPath: url.path)
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
                try expect(mode & 0o777 == (isDirectory ? 0o700 : 0o600),
                           "unexpected permissions \(String(mode, radix: 8)) at \(url.lastPathComponent)")
                if !isDirectory { combined.append(try Data(contentsOf: url)) }
            }
            try expect(!String(decoding: combined, as: UTF8.self).contains(rawPrincipal),
                       "raw principal leaked into routing custody")
        }
    }
}

private func withRoutingCustodyRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("routing-custody-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func routingCustodyDate(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_800_000_000 + offset)
}
