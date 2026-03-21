import Foundation
import NotionBridgeLib

final class StripeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
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
}

private func makeStripeTestSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StripeMockURLProtocol.self]
    return URLSession(configuration: config)
}

func runStripeClientTests() async {
    print("\n💳 StripeClient Tests")

    await test("createPaymentIntent sets Bearer + idempotency headers and form body") {
        let session = makeStripeTestSession()
        let client = StripeClient(
            session: session,
            apiKeyProvider: { "sk_test_123" },
            isAppBundleOverride: true
        )

        StripeMockURLProtocol.requestHandler = { request in
            try expect(request.httpMethod == "POST", "Expected POST")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test_123")
            try expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "123e4567-e89b-12d3-a456-426614174000")
            try expect(
                request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
                "Expected form-urlencoded content type"
            )

            let bodyString = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            try expect(bodyString.contains("amount=2500"), "Body missing amount")
            try expect(bodyString.contains("currency=usd"), "Body missing currency")
            try expect(bodyString.contains("payment_method=pm_test_4242"), "Body missing payment_method")
            try expect(bodyString.contains("confirm=true"), "Body missing confirm=true")
            try expect(
                bodyString.contains("automatic_payment_methods%5Benabled%5D=true"),
                "Body missing automatic_payment_methods[enabled]"
            )
            try expect(
                bodyString.contains("metadata%5Bdescription%5D=integration%20test"),
                "Body missing encoded metadata description"
            )

            let payload = """
            {
              "id": "pi_123",
              "amount": 2500,
              "currency": "usd",
              "status": "succeeded",
              "created": 1234567890
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        let result = try await client.createPaymentIntent(
            amount: 2500,
            currency: "usd",
            paymentMethod: "pm_test_4242",
            idempotencyKey: "123e4567-e89b-12d3-a456-426614174000",
            metadata: ["description": "integration test"]
        )
        StripeMockURLProtocol.requestHandler = nil

        try expect(result.id == "pi_123")
        try expect(result.amount == 2500)
        try expect(result.currency == "usd")
        try expect(result.status == "succeeded")
        try expect(result.created == 1234567890)
    }

    await test("createPaymentIntent maps insufficient_funds Stripe error") {
        let session = makeStripeTestSession()
        let client = StripeClient(
            session: session,
            apiKeyProvider: { "sk_test_123" },
            isAppBundleOverride: true
        )

        StripeMockURLProtocol.requestHandler = { request in
            let payload = """
            {
              "error": {
                "code": "card_declined",
                "decline_code": "insufficient_funds",
                "message": "Your card has insufficient funds."
              }
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 402,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        do {
            _ = try await client.createPaymentIntent(
                amount: 2500,
                currency: "usd",
                paymentMethod: "pm_test_4242",
                idempotencyKey: UUID().uuidString
            )
            throw TestError.assertion("Expected insufficient funds error")
        } catch let error as StripeError {
            if case .insufficientFunds = error {
                // expected
            } else {
                throw TestError.assertion("Expected .insufficientFunds, got \(error)")
            }
        }
        StripeMockURLProtocol.requestHandler = nil
    }

    await test("createPaymentIntent maps 401 to authenticationFailed") {
        let session = makeStripeTestSession()
        let client = StripeClient(
            session: session,
            apiKeyProvider: { "sk_test_invalid" },
            isAppBundleOverride: true
        )

        StripeMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await client.createPaymentIntent(
                amount: 2500,
                currency: "usd",
                paymentMethod: "pm_test_4242",
                idempotencyKey: UUID().uuidString
            )
            throw TestError.assertion("Expected authentication failure")
        } catch let error as StripeError {
            if case .authenticationFailed = error {
                // expected
            } else {
                throw TestError.assertion("Expected .authenticationFailed, got \(error)")
            }
        }
        StripeMockURLProtocol.requestHandler = nil
    }

    await test("createPaymentIntent rejects missing idempotency key") {
        let client = StripeClient(
            session: makeStripeTestSession(),
            apiKeyProvider: { "sk_test_123" },
            isAppBundleOverride: true
        )

        do {
            _ = try await client.createPaymentIntent(
                amount: 100,
                currency: "usd",
                paymentMethod: "pm_test_4242",
                idempotencyKey: "   "
            )
            throw TestError.assertion("Expected missing idempotency key error")
        } catch let error as StripeError {
            if case .missingIdempotencyKey = error {
                // expected
            } else {
                throw TestError.assertion("Expected .missingIdempotencyKey, got \(error)")
            }
        }
    }
}
