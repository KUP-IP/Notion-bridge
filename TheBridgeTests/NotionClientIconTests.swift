// NotionClientIconTests.swift — coverage for the Notion page icon write
// feature (createPage/updatePage `icon` param), which shipped (c3b5699,
// v3.9.5) with zero automated tests — only "live-verified against real
// Notion." A URLProtocol stub intercepts the outbound request so no live
// network call is made, mirroring WorkerTokenExchangeTests.swift's pattern.

import Foundation
import TheBridgeLib

/// URLProtocol stub: captures the outbound request/body and returns a canned reply.
final class StubNotionIconProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: @unchecked Sendable { var status: Int; var body: Data }
    nonisolated(unsafe) static var stub: Stub?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n > 0 { data.append(buf, count: n) } else { break }
            }
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let s = Self.stub ?? Stub(status: 200, body: #"{"id":"stub-page-id"}"#.data(using: .utf8)!)
        let resp = HTTPURLResponse(url: request.url!, statusCode: s.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: s.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedNotionSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubNotionIconProtocol.self]
    return URLSession(configuration: cfg)
}

private func stubbedClient() throws -> NotionClient {
    StubNotionIconProtocol.stub = .init(status: 200, body: #"{"id":"stub-page-id"}"#.data(using: .utf8)!)
    StubNotionIconProtocol.lastRequest = nil
    StubNotionIconProtocol.lastBody = nil
    return try NotionClient(apiKey: "test-key-not-real", session: stubbedNotionSession())
}

@MainActor
func runNotionClientIconTests() async {
    await test("NotionClient.createPage: icon supplied merges into request body") {
        let client = try stubbedClient()
        let props = #"{"Name":{"title":[{"text":{"content":"x"}}]}}"#.data(using: .utf8)!
        _ = try await client.createPage(parentId: "parent-1", properties: props, icon: "🎯")

        let sent = try JSONSerialization.jsonObject(with: StubNotionIconProtocol.lastBody ?? Data()) as? [String: Any]
        let icon = sent?["icon"] as? [String: Any]
        try expect(icon?["type"] as? String == "emoji", "icon.type must be emoji, got \(sent ?? [:])")
        try expect(icon?["emoji"] as? String == "🎯", "icon.emoji must carry the supplied emoji")
    }

    await test("NotionClient.createPage: icon omitted — no icon key in request body (byte-identical to prior behavior)") {
        let client = try stubbedClient()
        let props = #"{"Name":{"title":[{"text":{"content":"x"}}]}}"#.data(using: .utf8)!
        _ = try await client.createPage(parentId: "parent-1", properties: props)

        let sent = try JSONSerialization.jsonObject(with: StubNotionIconProtocol.lastBody ?? Data()) as? [String: Any]
        try expect(sent?["icon"] == nil, "omitted icon must not add an icon key, got \(sent ?? [:])")
    }

    await test("NotionClient.updatePage: icon supplied merges into properties body") {
        let client = try stubbedClient()
        let props = #"{"Name":{"title":[{"text":{"content":"y"}}]}}"#.data(using: .utf8)!
        _ = try await client.updatePage(pageId: "page-1", properties: props, icon: "✅")

        let sent = try JSONSerialization.jsonObject(with: StubNotionIconProtocol.lastBody ?? Data()) as? [String: Any]
        let icon = sent?["icon"] as? [String: Any]
        try expect(icon?["type"] as? String == "emoji", "icon.type must be emoji, got \(sent ?? [:])")
        try expect(icon?["emoji"] as? String == "✅", "icon.emoji must carry the supplied emoji")
        // The original properties must still be present alongside the merged icon.
        try expect(sent?["Name"] != nil, "original properties must survive the icon merge, got \(sent ?? [:])")
    }

    await test("NotionClient.updatePage: icon omitted — no icon key in request body (byte-identical to prior behavior)") {
        let client = try stubbedClient()
        let props = #"{"Name":{"title":[{"text":{"content":"y"}}]}}"#.data(using: .utf8)!
        _ = try await client.updatePage(pageId: "page-1", properties: props)

        let sent = try JSONSerialization.jsonObject(with: StubNotionIconProtocol.lastBody ?? Data()) as? [String: Any]
        try expect(sent?["icon"] == nil, "omitted icon must not add an icon key, got \(sent ?? [:])")
    }

    await test("NotionClient.createPage: icon:\"\" is sent through as an explicit-but-empty emoji (documented edge-case behavior, not validated)") {
        let client = try stubbedClient()
        let props = #"{"Name":{"title":[{"text":{"content":"x"}}]}}"#.data(using: .utf8)!
        _ = try await client.createPage(parentId: "parent-1", properties: props, icon: "")

        let sent = try JSONSerialization.jsonObject(with: StubNotionIconProtocol.lastBody ?? Data()) as? [String: Any]
        let icon = sent?["icon"] as? [String: Any]
        // Bridge does no emptiness validation on `icon` by design (matches the
        // read-side extractIconEmoji precedent) — an explicit empty string is
        // NOT treated as "no icon"; it's passed through verbatim to Notion's API,
        // which will reject or accept it on its own terms. This test documents
        // that behavior so a future change to it is a deliberate decision, not
        // an untested surprise.
        try expect(icon?["type"] as? String == "emoji", "icon:\"\" must still merge as an emoji icon shape, got \(sent ?? [:])")
        try expect(icon?["emoji"] as? String == "", "icon:\"\" must be sent through verbatim as an empty string, got \(sent ?? [:])")
    }

    await test("NotionClient.updatePage: icon merge fails loudly if properties body is not a JSON object") {
        let client = try stubbedClient()
        let notAnObject = #"[1,2,3]"#.data(using: .utf8)!
        var threw = false
        do { _ = try await client.updatePage(pageId: "page-1", properties: notAnObject, icon: "🎯") }
        catch { threw = true }
        try expect(threw, "a non-object properties body with an icon supplied must throw, not silently drop the icon")
    }
}
