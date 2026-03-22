// StripeTokenizationTests.swift – PKT-372 D4 backfill
// NotionBridge · Tests

import Foundation
import NotionBridgeLib

func runStripeTokenizationTests() async {
    print("\n🧪 Stripe Tokenization Tests")

    let enableKey = "com.notionbridge.tests.enableStripeTokenizationOutsideApp"
    let apiKey = "com.notionbridge.tests.stripeApiKey"

    UserDefaults.standard.set(true, forKey: enableKey)
    UserDefaults.standard.set("sk_test_tokenize", forKey: apiKey)
    _ = URLProtocol.registerClass(TokenizationMockURLProtocol.self)

    defer {
        URLProtocol.unregisterClass(TokenizationMockURLProtocol.self)
        TokenizationMockURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: enableKey)
        UserDefaults.standard.removeObject(forKey: apiKey)
    }

    await test("credential_save(card) tokenizes card into pm_ token") {
        TokenizationMockURLProtocol.reset()
        TokenizationMockURLProtocol.requestHandler = { _ in
            let responseBody = """
            {"id":"pm_12345","card":{"last4":"4242","brand":"visa"}}
            """
            let response = HTTPURLResponse(
                url: URL(string: "https://api.stripe.com/v1/payment_methods")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let manager = CredentialManager.shared
        let entry = try await manager.save(
            service: "stripe-tokenization-success",
            account: "card_1",
            password: "4242 4242 4242 4242",
            type: .card,
            metadata: CredentialMetadata(brand: "visa", expMonth: 12, expYear: 2030)
        )

        try expect(entry.type == .card)
        try expect(entry.metadata.stripePm == "pm_12345", "Expected pm_ token in metadata")
        try expect(entry.metadata.last4 == "4242")
        try expect(entry.metadata.brand?.lowercased() == "visa")
    }

    await test("credential_save(card) tokenization failure propagates StripeError") {
        TokenizationMockURLProtocol.reset()
        TokenizationMockURLProtocol.requestHandler = { _ in
            let responseBody = """
            {"error":{"type":"card_error","code":"card_declined","decline_code":"insufficient_funds","message":"Declined"}}
            """
            let response = HTTPURLResponse(
                url: URL(string: "https://api.stripe.com/v1/payment_methods")!,
                statusCode: 402,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let manager = CredentialManager.shared
        do {
            _ = try await manager.save(
                service: "stripe-tokenization-failure",
                account: "card_2",
                password: "4000 0000 0000 9995",
                type: .card,
                metadata: CredentialMetadata(brand: "visa", expMonth: 12, expYear: 2030)
            )
            throw TestError.assertion("Expected StripeError on tokenization failure")
        } catch let error as StripeError {
            if case .insufficientFunds = error { } else {
                throw TestError.assertion("Expected insufficientFunds, got \(error)")
            }
        }
    }

    await test("credential_save(card) sends form-urlencoded card fields") {
        TokenizationMockURLProtocol.reset()
        TokenizationMockURLProtocol.requestHandler = { request in
            // URLSession.shared converts httpBody to httpBodyStream before passing to URLProtocol
            let bodyData: Data
            if let body = request.httpBody {
                bodyData = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buf, maxLength: 4096)
                    if read <= 0 { break }
                    data.append(buf, count: read)
                }
                bodyData = data
            } else {
                throw TestError.assertion("Missing request body")
            }
            guard let bodyString = String(data: bodyData, encoding: .utf8) else {
                throw TestError.assertion("Could not decode request body as UTF-8")
            }
            try expect(bodyString.contains("type=card"), "Expected card type in body")
            try expect(bodyString.contains("card[number]=4242424242424242"), "Expected card number in body")
            try expect(bodyString.contains("card[exp_month]=1"), "Expected exp_month in body")
            try expect(bodyString.contains("card[exp_year]=2031"), "Expected exp_year in body")

            let responseBody = """
            {"id":"pm_formcheck","card":{"last4":"4242","brand":"visa"}}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let manager = CredentialManager.shared
        _ = try await manager.save(
            service: "stripe-tokenization-form",
            account: "card_3",
            password: "4242424242424242",
            type: .card,
            metadata: CredentialMetadata(brand: "visa", expMonth: 1, expYear: 2031)
        )
    }
}

private final class TokenizationMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.stripe.com" && request.url?.path == "/v1/payment_methods"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
    }
}
