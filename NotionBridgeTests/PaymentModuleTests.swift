import Foundation
import MCP
import NotionBridgeLib

func runPaymentModuleTests() async {
    print("\n💸 PaymentModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await PaymentModule.register(on: router)

    await test("PaymentModule registers 1 tool: payment_execute") {
        let tools = await router.registrations(forModule: "payment")
        try expect(tools.count == 1, "Expected 1 payment tool, got \(tools.count)")
        try expect(tools.first?.name == "payment_execute")
    }

    await test("payment_execute tier is request") {
        let tools = await router.registrations(forModule: "payment")
        let tool = tools.first(where: { $0.name == "payment_execute" })!
        try expect(tool.tier == .request, "Expected request tier")
    }

    await test("payment_execute neverAutoApprove is true") {
        let tools = await router.registrations(forModule: "payment")
        let tool = tools.first(where: { $0.name == "payment_execute" })!
        try expect(tool.neverAutoApprove == true, "Expected neverAutoApprove=true")
    }

    await test("payment_execute schema has required fields") {
        let tools = await router.registrations(forModule: "payment")
        let tool = tools.first(where: { $0.name == "payment_execute" })!
        guard case .object(let schema) = tool.inputSchema,
              case .array(let required) = schema["required"] else {
            throw TestError.assertion("Expected object schema with required array")
        }

        let requiredNames = required.compactMap {
            if case .string(let value) = $0 { return value }
            return nil
        }
        try expect(requiredNames.contains("credential_service"))
        try expect(requiredNames.contains("credential_account"))
        try expect(requiredNames.contains("amount"))
        try expect(requiredNames.contains("idempotency_key"))
    }

    await test("payment_execute rejects empty idempotency key") {
        do {
            _ = try await router.dispatch(
                toolName: "payment_execute",
                arguments: .object([
                    "credential_service": .string("cards"),
                    "credential_account": .string("primary"),
                    "amount": .int(100),
                    "idempotency_key": .string("   ")
                ])
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

    await test("payment_execute accepts valid UUID idempotency key") {
        let result = try await router.dispatch(
            toolName: "payment_execute",
            arguments: .object([
                "credential_service": .string("cards"),
                "credential_account": .string("primary"),
                "amount": .int(100),
                "idempotency_key": .string(UUID().uuidString)
            ])
        )
        if case .object(let dict) = result,
           case .string(let paymentIntentID) = dict["payment_intent_id"] {
            try expect(paymentIntentID.hasPrefix("pi_"), "Expected Stripe-like payment intent id")
        } else {
            throw TestError.assertion("Expected payment execution object response")
        }
    }

    await test("payment_execute rejects amount <= 0") {
        do {
            _ = try await router.dispatch(
                toolName: "payment_execute",
                arguments: .object([
                    "credential_service": .string("cards"),
                    "credential_account": .string("primary"),
                    "amount": .int(0),
                    "idempotency_key": .string(UUID().uuidString)
                ])
            )
            throw TestError.assertion("Expected invalid amount error")
        } catch let error as ToolRouterError {
            if case .invalidArguments(let name, _) = error {
                try expect(name == "payment_execute")
            } else {
                throw TestError.assertion("Expected invalid arguments error")
            }
        }
    }

    await test("payment_execute amount=ceiling is accepted") {
        let ceiling = PaymentModule.amountCeilingCents
        let result = try await router.dispatch(
            toolName: "payment_execute",
            arguments: .object([
                "credential_service": .string("cards"),
                "credential_account": .string("primary"),
                "amount": .int(ceiling),
                "idempotency_key": .string(UUID().uuidString)
            ])
        )
        if case .object(let dict) = result,
           case .int(let amount) = dict["amount"] {
            try expect(amount == ceiling, "Expected amount to equal ceiling")
        } else {
            throw TestError.assertion("Expected successful response with amount field")
        }
    }

    await test("payment_execute amount=ceiling+1 is rejected") {
        let ceiling = PaymentModule.amountCeilingCents
        do {
            _ = try await router.dispatch(
                toolName: "payment_execute",
                arguments: .object([
                    "credential_service": .string("cards"),
                    "credential_account": .string("primary"),
                    "amount": .int(ceiling + 1),
                    "idempotency_key": .string(UUID().uuidString)
                ])
            )
            throw TestError.assertion("Expected amount ceiling rejection")
        } catch let error as StripeError {
            if case .amountExceedsCeiling(let amount, let seenCeiling) = error {
                try expect(amount == ceiling + 1)
                try expect(seenCeiling == ceiling)
            } else {
                throw TestError.assertion("Expected .amountExceedsCeiling, got \(error)")
            }
        }
    }

    await test("payment_execute amount=1 is accepted") {
        let result = try await router.dispatch(
            toolName: "payment_execute",
            arguments: .object([
                "credential_service": .string("cards"),
                "credential_account": .string("primary"),
                "amount": .int(1),
                "idempotency_key": .string(UUID().uuidString)
            ])
        )
        if case .object(let dict) = result,
           case .int(let amount) = dict["amount"] {
            try expect(amount == 1)
        } else {
            throw TestError.assertion("Expected successful payment response")
        }
    }
}
