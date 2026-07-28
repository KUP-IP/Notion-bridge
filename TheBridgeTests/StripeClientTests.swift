// StripeClientTests.swift – PKT-381 StripeClient Tests
// TheBridge · Tests

import Foundation
import TheBridgeLib

func runStripeClientTests() async {
    print("\n💸 StripeClient Tests")

    _ = URLProtocol.registerClass(StripeMockURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(StripeMockURLProtocol.self)
        StripeMockURLProtocol.reset()
    }

    await test("PaymentIntentResult initializer stores values") {
        let result = PaymentIntentResult(
            id: "pi_123",
            amount: 2500,
            currency: "usd",
            status: "succeeded",
            created: 1_717_171_717
        )
        try expect(result.id == "pi_123")
        try expect(result.amount == 2500)
        try expect(result.currency == "usd")
        try expect(result.status == "succeeded")
        try expect(result.created == 1_717_171_717)
    }

    await test("StripeError descriptions are user-facing") {
        let errors: [StripeError] = [
            .authenticationFailed,
            .cardDeclined("do_not_honor"),
            .insufficientFunds,
            .processingError("boom"),
            .rateLimited,
            .networkError(URLError(.notConnectedToInternet)),
            .invalidResponse,
            .amountExceedsCeiling(amount: 60000, ceiling: 50000),
            .missingIdempotencyKey,
            .invalidAmount
        ]
        for error in errors {
            try expect(!(error.localizedDescription).isEmpty, "Description should not be empty for \(error)")
        }
    }

    await test("formURLEncoded escapes reserved characters") {
        let encoded = StripeClient.formURLEncoded([
            "description": "Coffee & croissant",
            "metadata[order id]": "A/B #42"
        ])
        try expect(encoded.contains("description=Coffee+%26+croissant"))
        try expect(encoded.contains("metadata%5Border+id%5D=A%2FB+%2342"))
    }

    await test("createPaymentIntent sends auth and idempotency headers") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            let idem = request.value(forHTTPHeaderField: "Idempotency-Key")
            try expect(auth == "Bearer sk_test_auth", "Expected Bearer auth header")
            try expect(idem == "idem-123", "Expected idempotency key header")
            let payload = """
            {"id":"pi_auth","amount":2500,"currency":"usd","status":"succeeded","created":1700000000}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        let client = StripeClient(
            session: makeStripeMockSession(),
            apiKeyProvider: { "sk_test_auth" }
        )
        let result = try await client.createPaymentIntent(
            amount: 2500,
            currency: "usd",
            paymentMethod: "pm_1",
            idempotencyKey: "idem-123",
            description: "Test payment",
            metadata: ["order_id": "ord_1"]
        )
        try expect(result.id == "pi_auth")
    }

    await test("retrieveAccountInfo parses Stripe account metadata") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            try expect(request.url?.absoluteString == "https://api.stripe.com/v1/account")
            let payload = """
            {"id":"acct_123","email":"ops@example.com","country":"US","charges_enabled":true,"business_profile":{"name":"KEEP Ops"}}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_account" })
        let account = try await client.retrieveAccountInfo()
        try expect(account.id == "acct_123")
        try expect(account.email == "ops@example.com")
        try expect(account.displayName == "KEEP Ops")
        try expect(account.country == "US")
        try expect(account.chargesEnabled == true)
    }

    await test("createPaymentIntent maps card_declined to StripeError.cardDeclined") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { _ in
            let payload = """
            {"error":{"type":"card_error","code":"card_declined","decline_code":"do_not_honor","message":"Card declined"}}
            """
            let response = HTTPURLResponse(
                url: URL(string: "https://api.stripe.com/v1/payment_intents")!,
                statusCode: 402,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_decline" })
        do {
            _ = try await client.createPaymentIntent(
                amount: 2500,
                currency: "usd",
                paymentMethod: "pm_decline",
                idempotencyKey: "idem-decline",
                description: nil,
                metadata: nil
            )
            throw TestError.assertion("Expected cardDeclined error")
        } catch let error as StripeError {
            if case .cardDeclined(let reason) = error {
                try expect(reason.contains("do_not_honor"), "Expected decline reason in error")
            } else {
                throw TestError.assertion("Expected cardDeclined, got \(error)")
            }
        }
    }

    await test("createPaymentIntent maps 429 to StripeError.rateLimited") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { _ in
            let payload = #"{"error":{"message":"Too many requests"}}"#
            let response = HTTPURLResponse(
                url: URL(string: "https://api.stripe.com/v1/payment_intents")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_rate" })
        do {
            _ = try await client.createPaymentIntent(
                amount: 1000,
                currency: "usd",
                paymentMethod: "pm_rate",
                idempotencyKey: "idem-rate",
                description: nil,
                metadata: nil
            )
            throw TestError.assertion("Expected rateLimited error")
        } catch let error as StripeError {
            if case .rateLimited = error { } else {
                throw TestError.assertion("Expected rateLimited, got \(error)")
            }
        }
    }

    await test("createPaymentIntent surfaces URLSession failures as networkError") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestError = URLError(.notConnectedToInternet)

        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_network" })
        do {
            _ = try await client.createPaymentIntent(
                amount: 1000,
                currency: "usd",
                paymentMethod: "pm_net",
                idempotencyKey: "idem-net",
                description: nil,
                metadata: nil
            )
            throw TestError.assertion("Expected networkError")
        } catch let error as StripeError {
            if case .networkError = error { } else {
                throw TestError.assertion("Expected networkError, got \(error)")
            }
        }
    }

    // ── Payment P1: hosted Stripe Checkout Session ───────────────────────
    await test("createCheckoutSession posts mode/price/urls + brand metadata + client_reference_id") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            try expect(request.url?.absoluteString == "https://api.stripe.com/v1/checkout/sessions",
                       "expected checkout/sessions endpoint, got \(request.url?.absoluteString ?? "nil")")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test_co",
                       "expected bearer auth")
            let body = stripeRequestBody(request)
            try expect(body.contains("mode=payment"), "missing mode=payment in \(body)")
            try expect(body.contains("line_items%5B0%5D%5Bprice%5D=price_live_123"), "missing price line item in \(body)")
            try expect(body.contains("line_items%5B0%5D%5Bquantity%5D=1"), "missing quantity in \(body)")
            try expect(body.contains("success_url=https%3A%2F%2Fok"), "missing success_url in \(body)")
            try expect(body.contains("cancel_url=https%3A%2F%2Fno"), "missing cancel_url in \(body)")
            try expect(body.contains("metadata%5Bproduct%5D=the-bridge"), "missing brand metadata in \(body)")
            try expect(body.contains("client_reference_id=ord_42"), "missing client_reference_id in \(body)")
            let json = #"{"id":"cs_test_123","url":"https://checkout.stripe.com/c/pay/cs_test_123"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_co" })
        let session = try await client.createCheckoutSession(
            priceID: "price_live_123",
            successURL: "https://ok",
            cancelURL: "https://no",
            metadata: BridgeCheckout.brandMetadata(appVersion: "9.9.9"),
            clientReferenceID: "ord_42",
            idempotencyKey: "idem-co"
        )
        try expect(session.id == "cs_test_123", "expected cs_test_123, got \(session.id)")
        try expect(session.url == "https://checkout.stripe.com/c/pay/cs_test_123")
    }

    await test("createCheckoutSession with empty priceID throws missingPriceID (no network)") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { _ in
            throw TestError.assertion("network must NOT be called when priceID is empty")
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_co" })
        do {
            _ = try await client.createCheckoutSession(priceID: "  ", successURL: "https://ok", cancelURL: "https://no")
            throw TestError.assertion("expected missingPriceID")
        } catch let error as StripeError {
            if case .missingPriceID = error { } else {
                throw TestError.assertion("expected missingPriceID, got \(error)")
            }
        }
    }

    await test("createCheckoutSession surfaces a Stripe error response") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            let json = #"{"error":{"type":"invalid_request_error","message":"No such price"}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_co" })
        do {
            _ = try await client.createCheckoutSession(priceID: "price_bad", successURL: "https://ok", cancelURL: "https://no")
            throw TestError.assertion("expected a StripeError")
        } catch let error as StripeError {
            if case .processingError = error { } else {
                throw TestError.assertion("expected processingError, got \(error)")
            }
        }
    }

    await test("BridgeCheckout brand metadata + priceID provider") {
        let md = BridgeCheckout.brandMetadata(appVersion: "4.0.0")
        try expect(md["product"] == "the-bridge")
        try expect(md["app_version"] == "4.0.0")
        try expect(md["channel"] == "in-app")
        try expect(BridgeCheckout.priceID({ nil }) == nil, "nil provider → nil")
        try expect(BridgeCheckout.priceID({ "   " }) == nil, "whitespace → nil")
        try expect(BridgeCheckout.priceID({ " price_x " }) == "price_x", "trimmed value")
        try expect(BridgeCheckout.paymentLinkURL({ nil }) == nil, "nil link → nil")
        try expect(BridgeCheckout.paymentLinkURL({ " https://buy.stripe.com/x " }) == "https://buy.stripe.com/x",
                   "trimmed payment link")
    }


    // ── PKT-1212 B0: close-to-cash Stripe hardening ───────────────────
    await test("all Stripe requests pin the API version and mutation receipts retain response evidence") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            try expect(request.value(forHTTPHeaderField: "Stripe-Version") == "2025-06-30.basil")
            try expect(request.value(forHTTPHeaderField: "Idempotency-Key")?.hasPrefix("bridge-customer-create-") == true)
            let body = stripeRequestBody(request)
            try expect(body.contains("email=adam%40example.com"))
            try expect(body.contains("metadata%5Bbridge_operation_id%5D=plan-adam-v1"))
            return stripeHTTPResponse(
                request: request,
                status: 200,
                headers: ["Request-Id": "req_customer_1", "Stripe-Version": "2025-06-30.basil"],
                body: #"{"id":"cus_adam","email":"adam@example.com","name":"Adam","metadata":{"bridge_operation_id":"plan-adam-v1"}}"#
            )
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_customer" })
        let result = await client.createCustomer(
            email: "adam@example.com",
            name: "Adam",
            intentID: "plan-adam-v1"
        )
        try expect(result.state == .succeeded)
        try expect(result.value?.id == "cus_adam")
        try expect(result.evidence.statusCode == 200)
        try expect(result.evidence.requestID == "req_customer_1")
        try expect(result.evidence.requestAPIVersion == "2025-06-30.basil")
        try expect(result.evidence.responseAPIVersion == "2025-06-30.basil")
    }

    await test("deterministic idempotency keys are stable for identical intent and change with immutable payload") {
        let fields = ["customer": "cus_1", "metadata[plan_id]": "plan_1"]
        let first = StripeClient.deterministicIdempotencyKey(
            operation: "invoice.create",
            intentID: "intent_1",
            targetID: "cus_1",
            fields: fields
        )
        let reordered = StripeClient.deterministicIdempotencyKey(
            operation: "invoice.create",
            intentID: "intent_1",
            targetID: "cus_1",
            fields: ["metadata[plan_id]": "plan_1", "customer": "cus_1"]
        )
        let changed = StripeClient.deterministicIdempotencyKey(
            operation: "invoice.create",
            intentID: "intent_1",
            targetID: "cus_1",
            fields: ["customer": "cus_1", "metadata[plan_id]": "plan_2"]
        )
        try expect(first == reordered)
        try expect(first != changed)
        try expect(first.count < 255)
    }

    await test("exact-email customer lookup distinguishes zero one and multiple matches") {
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_list" })
        let fixtures = [
            #"{"object":"list","data":[],"has_more":false}"#,
            #"{"object":"list","data":[{"id":"cus_1","email":"Adam@example.com","metadata":{}}],"has_more":false}"#,
            #"{"object":"list","data":[{"id":"cus_1","email":"Adam@example.com","metadata":{}},{"id":"cus_2","email":"Adam@example.com","metadata":{}}],"has_more":false}"#
        ]
        for (index, fixture) in fixtures.enumerated() {
            StripeMockURLProtocol.reset()
            StripeMockURLProtocol.requestHandler = { request in
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                try expect(components?.queryItems?.first(where: { $0.name == "email" })?.value == "Adam@example.com")
                return stripeHTTPResponse(request: request, status: 200, body: fixture)
            }
            let match = try await client.listCustomers(email: "Adam@example.com")
            switch (index, match) {
            case (0, .zero): break
            case (1, .one(let customer)): try expect(customer.id == "cus_1")
            case (2, .multiple(let customers)): try expect(customers.map(\.id) == ["cus_1", "cus_2"])
            default: throw TestError.assertion("unexpected match state \(match) for fixture \(index)")
            }
        }
    }

    await test("customer reconciliation filters deterministic metadata and preserves ambiguity") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            let body = #"{"object":"list","data":[{"id":"cus_other","email":"adam@example.com","metadata":{"bridge_operation_id":"other"}},{"id":"cus_expected","email":"adam@example.com","metadata":{"bridge_operation_id":"intent_1"}}],"has_more":false}"#
            return stripeHTTPResponse(request: request, status: 200, body: body)
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_reconcile" })
        let match = try await client.reconcileCustomerCreate(email: "adam@example.com", intentID: "intent_1")
        if case .one(let customer) = match {
            try expect(customer.id == "cus_expected")
        } else {
            throw TestError.assertion("expected one reconciled customer")
        }
    }

    await test("mutating 500 is indeterminate and retains idempotency plus Stripe request id") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            stripeHTTPResponse(
                request: request,
                status: 500,
                headers: ["Request-Id": "req_indeterminate", "Stripe-Version": "2025-06-30.basil"],
                body: #"{"error":{"message":"Internal error"}}"#
            )
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_500" })
        let result = await client.createCustomer(email: "adam@example.com", name: nil, intentID: "intent_500")
        try expect(result.state == .indeterminateExternalEffect)
        try expect(result.value == nil)
        try expect(result.evidence.requestID == "req_indeterminate")
        try expect(result.evidence.idempotencyKey?.hasPrefix("bridge-customer-create-") == true)
    }

    await test("401 and 403 mutations fail definitively") {
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_authz" })
        for status in [401, 403] {
            StripeMockURLProtocol.reset()
            StripeMockURLProtocol.requestHandler = { request in
                stripeHTTPResponse(request: request, status: status, body: #"{"error":{"message":"Denied"}}"#)
            }
            let result = await client.createCustomer(email: "adam@example.com", name: nil, intentID: "intent_\(status)")
            try expect(result.state == .failedDefinitively)
            try expect(result.evidence.statusCode == status)
        }
    }

    await test("network failure during a mutation is indeterminate") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestError = URLError(.networkConnectionLost)
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_network_mutation" })
        let result = await client.createCustomer(email: "adam@example.com", name: nil, intentID: "intent_net")
        try expect(result.state == .indeterminateExternalEffect)
        try expect(result.evidence.statusCode == nil)
        if case .networkError = result.error { } else {
            throw TestError.assertion("expected networkError")
        }
    }

    await test("invalid JSON after a successful mutation remains indeterminate") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            stripeHTTPResponse(
                request: request,
                status: 200,
                headers: ["Request-Id": "req_bad_json"],
                body: "not-json"
            )
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_json" })
        let result = await client.createCustomer(email: "adam@example.com", name: nil, intentID: "intent_json")
        try expect(result.state == .indeterminateExternalEffect)
        try expect(result.evidence.requestID == "req_bad_json")
    }

    await test("invoice create and invoice item encode four-hour plan fields") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            let body = stripeRequestBody(request)
            if request.url?.path == "/v1/invoices" {
                try expect(body.contains("collection_method=send_invoice"))
                try expect(body.contains("customer=cus_adam"))
                try expect(body.contains("metadata%5Bplan_id%5D=adam-4h-v1"))
                return stripeHTTPResponse(request: request, status: 200, body: stripeInvoiceJSON(id: "in_adam", status: "draft", amountDue: 0))
            }
            try expect(request.url?.path == "/v1/invoiceitems")
            try expect(body.contains("quantity=4"))
            try expect(body.contains("unit_amount=5000"))
            try expect(body.contains("currency=usd"))
            try expect(body.contains("invoice=in_adam"))
            let json = #"{"id":"ii_adam","invoice":"in_adam","amount":20000,"currency":"usd","quantity":4,"unit_amount":5000,"description":"Four hours","metadata":{"plan_id":"adam-4h-v1","bridge_operation_id":"intent_adam"}}"#
            return stripeHTTPResponse(request: request, status: 200, body: json)
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_invoice" })
        let invoice = await client.createInvoice(customerID: "cus_adam", planID: "adam-4h-v1", intentID: "intent_adam")
        try expect(invoice.state == .succeeded)
        try expect(invoice.value?.planID == "adam-4h-v1")
        let item = await client.createInvoiceItem(
            invoiceID: "in_adam",
            customerID: "cus_adam",
            planID: "adam-4h-v1",
            intentID: "intent_adam",
            description: "Four hours"
        )
        try expect(item.state == .succeeded)
        try expect(item.value?.quantity == 4)
        try expect(item.value?.unitAmount == 5_000)
    }

    await test("paid invoices are refused before a void mutation is issued") {
        StripeMockURLProtocol.reset()
        var postCount = 0
        StripeMockURLProtocol.requestHandler = { request in
            if request.httpMethod == "POST" { postCount += 1 }
            try expect(request.httpMethod == "GET")
            return stripeHTTPResponse(
                request: request,
                status: 200,
                body: stripeInvoiceJSON(id: "in_paid", status: "paid", amountDue: 20_000, amountPaid: 20_000)
            )
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_void" })
        let result = await client.voidInvoice(id: "in_paid", intentID: "void_paid")
        try expect(result.state == .failedDefinitively)
        try expect(postCount == 0)
        if case .illegalInvoiceState = result.error { } else {
            throw TestError.assertion("expected illegalInvoiceState")
        }
    }

    await test("invoice.sent reconciliation paginates and proves only a matching invoice event") {
        StripeMockURLProtocol.reset()
        var requests = 0
        StripeMockURLProtocol.requestHandler = { request in
            requests += 1
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let startingAfter = components?.queryItems?.first(where: { $0.name == "starting_after" })?.value
            if startingAfter == nil {
                let body = #"{"data":[{"id":"evt_1","type":"invoice.sent","created":1700000100,"data":{"object":{"id":"in_other"}}}],"has_more":true}"#
                return stripeHTTPResponse(request: request, status: 200, body: body)
            }
            try expect(startingAfter == "evt_1")
            let body = #"{"data":[{"id":"evt_2","type":"invoice.sent","created":1700000200,"data":{"object":{"id":"in_target"}}}],"has_more":false}"#
            return stripeHTTPResponse(
                request: request,
                status: 200,
                headers: ["Request-Id": "req_events_page_2"],
                body: body
            )
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_events" })
        let result = try await client.reconcileInvoiceSend(invoiceID: "in_target", createdAtOrAfter: 1_700_000_000)
        if case .proven(let event, let evidence) = result {
            try expect(event.id == "evt_2")
            try expect(evidence.requestID == "req_events_page_2")
        } else {
            throw TestError.assertion("expected proven event")
        }
        try expect(requests == 2)
    }

    await test("zero invoice.sent events remain not proven") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            stripeHTTPResponse(request: request, status: 200, body: #"{"data":[],"has_more":false}"#)
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_events_zero" })
        let result = try await client.reconcileInvoiceSend(invoiceID: "in_target", createdAtOrAfter: 1_700_000_000)
        try expect(result == .notProven)
    }

    await test("four-hour workflow preserves invoice and item ids when finalize is indeterminate") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/v1/invoices":
                return stripeHTTPResponse(request: request, status: 200, body: stripeInvoiceJSON(id: "in_partial", status: "draft", amountDue: 0))
            case "/v1/invoiceitems":
                let json = #"{"id":"ii_partial","invoice":"in_partial","amount":20000,"currency":"usd","quantity":4,"unit_amount":5000,"metadata":{"bridge_operation_id":"intent_partial"}}"#
                return stripeHTTPResponse(request: request, status: 200, body: json)
            case "/v1/invoices/in_partial/finalize":
                return stripeHTTPResponse(
                    request: request,
                    status: 500,
                    headers: ["Request-Id": "req_finalize_unknown"],
                    body: #"{"error":{"message":"Internal error"}}"#
                )
            default:
                throw TestError.assertion("unexpected request \(request.url?.absoluteString ?? "nil")")
            }
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_partial" })
        let result = await client.createFourHourInvoice(
            customerID: "cus_partial",
            planID: "plan_partial",
            intentID: "intent_partial",
            description: "Four hours"
        )
        try expect(result.state == .indeterminateExternalEffect)
        try expect(result.invoiceID == "in_partial")
        try expect(result.invoiceItemID == "ii_partial")
        try expect(result.failedOperation == "invoice.finalize")
        try expect(result.completedOperations.map(\.operation) == ["invoice.create", "invoice_item.create"])
    }

    await test("indeterminate invoice send is upgraded only by a matching invoice.sent event") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/v1/invoices":
                return stripeHTTPResponse(request: request, status: 200, body: stripeInvoiceJSON(id: "in_recovered", status: "draft", amountDue: 0))
            case "/v1/invoiceitems":
                let json = #"{"id":"ii_recovered","invoice":"in_recovered","amount":20000,"currency":"usd","quantity":4,"unit_amount":5000,"metadata":{"bridge_operation_id":"intent_recovered"}}"#
                return stripeHTTPResponse(request: request, status: 200, body: json)
            case "/v1/invoices/in_recovered/finalize":
                return stripeHTTPResponse(request: request, status: 200, body: stripeInvoiceJSON(id: "in_recovered", status: "open", amountDue: 20_000))
            case "/v1/invoices/in_recovered/send":
                return stripeHTTPResponse(
                    request: request,
                    status: 500,
                    headers: ["Request-Id": "req_send_unknown"],
                    body: #"{"error":{"message":"Internal error"}}"#
                )
            case "/v1/events":
                let body = #"{"data":[{"id":"evt_sent","type":"invoice.sent","created":1700000300,"data":{"object":{"id":"in_recovered"}}}],"has_more":false}"#
                return stripeHTTPResponse(request: request, status: 200, body: body)
            default:
                throw TestError.assertion("unexpected request \(request.url?.absoluteString ?? "nil")")
            }
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_recovered" })
        let result = await client.createFourHourInvoice(
            customerID: "cus_recovered",
            planID: "plan_recovered",
            intentID: "intent_recovered",
            description: "Four hours"
        )
        try expect(result.state == .succeeded)
        try expect(result.invoiceID == "in_recovered")
        try expect(result.invoiceItemID == "ii_recovered")
        try expect(result.completedOperations.last?.operation == "invoice.send.reconciled")
    }


    await test("retrieveInvoice parses customer amounts currency status urls and plan id") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            try expect(request.httpMethod == "GET")
            try expect(request.url?.path == "/v1/invoices/in_parse")
            return stripeHTTPResponse(
                request: request,
                status: 200,
                body: stripeInvoiceJSON(
                    id: "in_parse",
                    status: "open",
                    amountDue: 20_000,
                    amountPaid: 5_000,
                    customerID: "cus_parse"
                )
            )
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_parse" })
        let invoice = try await client.retrieveInvoice(id: "in_parse")
        try expect(invoice.customerID == "cus_parse")
        try expect(invoice.amountDue == 20_000)
        try expect(invoice.amountPaid == 5_000)
        try expect(invoice.currency == "usd")
        try expect(invoice.status == "open")
        try expect(invoice.hostedInvoiceURL == "https://invoice.stripe.com/i/in_parse")
        try expect(invoice.invoicePDFURL == "https://invoice.stripe.com/i/in_parse.pdf")
        try expect(invoice.planID == "adam-4h-v1")
    }

    await test("unpaid invoice void retrieves state then performs one idempotent void mutation") {
        StripeMockURLProtocol.reset()
        var requestMethods: [String] = []
        StripeMockURLProtocol.requestHandler = { request in
            requestMethods.append(request.httpMethod ?? "")
            if request.httpMethod == "GET" {
                return stripeHTTPResponse(
                    request: request,
                    status: 200,
                    body: stripeInvoiceJSON(id: "in_void", status: "open", amountDue: 20_000)
                )
            }
            try expect(request.url?.path == "/v1/invoices/in_void/void")
            try expect(request.value(forHTTPHeaderField: "Idempotency-Key")?.hasPrefix("bridge-invoice-void-") == true)
            return stripeHTTPResponse(
                request: request,
                status: 200,
                body: stripeInvoiceJSON(id: "in_void", status: "void", amountDue: 20_000)
            )
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_void_unpaid" })
        let result = await client.voidInvoice(id: "in_void", intentID: "void_unpaid")
        try expect(result.state == .succeeded)
        try expect(result.value?.status == "void")
        try expect(requestMethods == ["GET", "POST"])
    }

    await test("invoice create reconciliation rejects multiple deterministic metadata matches") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            let first = stripeInvoiceJSON(id: "in_dup_1", status: "draft", amountDue: 0)
            let second = stripeInvoiceJSON(id: "in_dup_2", status: "draft", amountDue: 0)
            let body = "{\"data\":[\(first),\(second)],\"has_more\":false}"
            return stripeHTTPResponse(request: request, status: 200, body: body)
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_ambiguous" })
        do {
            _ = try await client.reconcileInvoiceCreate(customerID: "cus_adam", intentID: "intent_adam")
            throw TestError.assertion("expected ambiguousResult")
        } catch let error as StripeError {
            if case .ambiguousResult(let operation, let count) = error {
                try expect(operation == "invoice.create")
                try expect(count == 2)
            } else {
                throw TestError.assertion("expected ambiguousResult, got \(error)")
            }
        }
    }

    await test("429 during a customer mutation is definitive rather than indeterminate") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            stripeHTTPResponse(request: request, status: 429, body: #"{"error":{"message":"Rate limited"}}"#)
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_429_mutation" })
        let result = await client.createCustomer(email: "adam@example.com", name: nil, intentID: "intent_429")
        try expect(result.state == .failedDefinitively)
        if case .rateLimited = result.error { } else {
            throw TestError.assertion("expected rateLimited")
        }
    }

    await test("indeterminate send with no matching event remains indeterminate and is not replayed") {
        StripeMockURLProtocol.reset()
        var sendRequests = 0
        StripeMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/v1/invoices":
                return stripeHTTPResponse(request: request, status: 200, body: stripeInvoiceJSON(id: "in_no_event", status: "draft", amountDue: 0))
            case "/v1/invoiceitems":
                let json = #"{"id":"ii_no_event","invoice":"in_no_event","amount":20000,"currency":"usd","quantity":4,"unit_amount":5000,"metadata":{"bridge_operation_id":"intent_no_event"}}"#
                return stripeHTTPResponse(request: request, status: 200, body: json)
            case "/v1/invoices/in_no_event/finalize":
                return stripeHTTPResponse(request: request, status: 200, body: stripeInvoiceJSON(id: "in_no_event", status: "open", amountDue: 20_000))
            case "/v1/invoices/in_no_event/send":
                sendRequests += 1
                return stripeHTTPResponse(request: request, status: 500, body: #"{"error":{"message":"Internal error"}}"#)
            case "/v1/events":
                return stripeHTTPResponse(request: request, status: 200, body: #"{"data":[],"has_more":false}"#)
            default:
                throw TestError.assertion("unexpected request \(request.url?.absoluteString ?? "nil")")
            }
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_no_event" })
        let result = await client.createFourHourInvoice(
            customerID: "cus_no_event",
            planID: "plan_no_event",
            intentID: "intent_no_event",
            description: "Four hours"
        )
        try expect(result.state == .indeterminateExternalEffect)
        try expect(result.failedOperation == "invoice.send")
        try expect(sendRequests == 1)
    }
}

private func makeStripeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StripeMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Read a URLRequest body whether URLSession left it as httpBody or moved it
/// to httpBodyStream (it does the latter for bodies handed to a URLProtocol).
private func stripeRequestBody(_ request: URLRequest) -> String {
    if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return String(decoding: data, as: UTF8.self)
}


private func stripeHTTPResponse(
    request: URLRequest,
    status: Int,
    headers: [String: String] = [:],
    body: String
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: headers
    )!
    return (response, Data(body.utf8))
}

private func stripeInvoiceJSON(
    id: String,
    status: String,
    amountDue: Int,
    amountPaid: Int = 0,
    customerID: String = "cus_adam",
    created: Int = 1_700_000_000
) -> String {
    """
    {"id":"\(id)","customer":"\(customerID)","amount_due":\(amountDue),"amount_paid":\(amountPaid),"currency":"usd","status":"\(status)","hosted_invoice_url":"https://invoice.stripe.com/i/\(id)","invoice_pdf":"https://invoice.stripe.com/i/\(id).pdf","created":\(created),"metadata":{"plan_id":"adam-4h-v1","bridge_operation_id":"intent_adam"}}
    """
}

private final class StripeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestError: Error?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let requestError = Self.requestError {
            client?.urlProtocol(self, didFailWithError: requestError)
            return
        }
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
        requestError = nil
    }
}
