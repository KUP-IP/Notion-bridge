import Foundation
import LocalAuthentication
import MCP

public enum PaymentModule {
    public static let moduleName = "payment"
    public static var amountCeilingCents = 50_000

    private static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "payment_execute",
            module: moduleName,
            tier: .request,
            neverAutoApprove: true,
            description: "Execute a Stripe payment intent using a stored pm_ credential token. Enforces request-tier approval, biometric authentication, amount ceiling checks, and mandatory idempotency keys.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "credential_service": .object([
                        "type": .string("string"),
                        "description": .string("Service name of stored card credential")
                    ]),
                    "credential_account": .object([
                        "type": .string("string"),
                        "description": .string("Account name of stored card credential")
                    ]),
                    "amount": .object([
                        "type": .string("integer"),
                        "description": .string("Amount in cents (e.g., 2500 = $25.00)")
                    ]),
                    "currency": .object([
                        "type": .string("string"),
                        "default": .string("usd"),
                        "description": .string("ISO 4217 currency code")
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Payment description for Stripe metadata")
                    ]),
                    "idempotency_key": .object([
                        "type": .string("string"),
                        "description": .string("Required caller-generated UUID for dedup")
                    ])
                ]),
                "required": .array([
                    .string("credential_service"),
                    .string("credential_account"),
                    .string("amount"),
                    .string("idempotency_key")
                ])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let credentialService) = args["credential_service"],
                      case .string(let credentialAccount) = args["credential_account"],
                      case .int(let amount) = args["amount"],
                      case .string(let idempotencyKeyRaw) = args["idempotency_key"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "payment_execute",
                        reason: "missing required 'credential_service', 'credential_account', 'amount', or 'idempotency_key' parameter"
                    )
                }

                let idempotencyKey = idempotencyKeyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !idempotencyKey.isEmpty else {
                    throw StripeError.missingIdempotencyKey
                }

                guard amount > 0 else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "payment_execute",
                        reason: "amount must be greater than zero"
                    )
                }

                let ceiling = PaymentModule.amountCeilingCents
                guard amount <= ceiling else {
                    throw StripeError.amountExceedsCeiling(amount: amount, ceiling: ceiling)
                }

                try await requireBiometric()

                let currency: String = {
                    if case .string(let value) = args["currency"] {
                        return value.lowercased()
                    }
                    return "usd"
                }()

                let metadataDescription: String? = {
                    if case .string(let value) = args["description"] {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    return nil
                }()

                let paymentMethod: String
                if isAppBundle {
                    let entry: CredentialEntry
                    do {
                        entry = try CredentialManager.shared.read(
                            service: credentialService,
                            account: credentialAccount
                        )
                    } catch {
                        throw StripeError.missingCredential
                    }

                    guard let token = entry.password,
                          token.hasPrefix("pm_") else {
                        throw StripeError.missingCredential
                    }
                    paymentMethod = token
                } else {
                    paymentMethod = "pm_test_non_app"
                }

                var metadata: [String: String] = [:]
                if let metadataDescription {
                    metadata["description"] = metadataDescription
                }

                let result = try await StripeClient.shared.createPaymentIntent(
                    amount: amount,
                    currency: currency,
                    paymentMethod: paymentMethod,
                    idempotencyKey: idempotencyKey,
                    metadata: metadata
                )

                return .object([
                    "payment_intent_id": .string(result.id),
                    "amount": .int(result.amount),
                    "currency": .string(result.currency),
                    "status": .string(result.status),
                    "created": .int(result.created)
                ])
            }
        ))
    }

    private static func requireBiometric() async throws {
        guard isAppBundle else { return }
        let context = LAContext()

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Authorize Stripe payment execution"
            )
        } catch {
            throw StripeError.biometricFailed
        }
    }
}
