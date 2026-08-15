// PageUpdateApplicationTests.swift — issue #138
// Distinguishes Notion canonical rewrites from genuine property rejection.

import Foundation
import MCP
import TheBridgeLib

func runPageUpdateApplicationTests() async {
    print("\n\u{1F4DD} PageUpdateApplication Tests (issue #138)")

    await test("canonicalized select option object is success, not partially applied") {
        let requested: [String: Any] = [
            "Status": ["status": ["name": "Active"]],
        ]
        let returned: [String: Any] = [
            "properties": [
                "Status": [
                    "id": "st",
                    "type": "status",
                    "status": ["id": "opt-1", "name": "Active", "color": "green"],
                ] as [String: Any],
            ],
        ]
        let c = PageUpdateApplication.classify(requested: requested, returnedPage: returned)
        try expect(c.success, "canonicalized-only is success")
        try expect(c.status != .rejected, "must not be rejected/partially-applied, got \(c.status)")
        try expect(c.rejected.isEmpty, "not rejected")
        try expect(!c.asValue.isEmpty, "receipt has status keys")
    }

    await test("dashed vs undashed relation id is canonicalized success") {
        let requested: [String: Any] = [
            "PROJECT": ["relation": [["id": "37fcbb58-889e-81f1-867e-d71b11dd9baf"]]],
        ]
        let returned: [String: Any] = [
            "properties": [
                "PROJECT": [
                    "id": "rel",
                    "type": "relation",
                    "relation": [["id": "37fcbb58889e81f1867ed71b11dd9baf"]],
                ] as [String: Any],
            ],
        ]
        let c = PageUpdateApplication.classify(requested: requested, returnedPage: returned)
        try expect(c.success, "UUID rewrite is success")
        try expect(c.status == .canonicalized, "got \(c.status)")
    }

    await test("missing returned property is rejected, not canonicalized") {
        let requested: [String: Any] = [
            "PROJECT": ["relation": [["id": "37fcbb58-889e-81f1-867e-d71b11dd9baf"]]],
        ]
        let returned: [String: Any] = ["properties": [:] as [String: Any]]
        let c = PageUpdateApplication.classify(requested: requested, returnedPage: returned)
        try expect(!c.success, "missing field is not success")
        try expect(c.status == .rejected, "got \(c.status)")
        try expect(c.rejected.contains(where: { $0.field == "PROJECT" }), "PROJECT rejected: \(c.rejected)")
    }

    await test("exact matching title is applied") {
        let requested: [String: Any] = [
            "Name": ["title": [["text": ["content": "Hello"], "plain_text": "Hello"]]],
        ]
        let returned: [String: Any] = [
            "properties": [
                "Name": [
                    "id": "ti",
                    "type": "title",
                    "title": [["plain_text": "Hello", "text": ["content": "Hello"]]],
                ] as [String: Any],
            ],
        ]
        let c = PageUpdateApplication.classify(requested: requested, returnedPage: returned)
        try expect(c.success, "exact title succeeds")
        try expect(c.status == .applied || c.status == .canonicalized, "got \(c.status)")
        try expect(c.rejected.isEmpty, "no rejects")
    }
}
