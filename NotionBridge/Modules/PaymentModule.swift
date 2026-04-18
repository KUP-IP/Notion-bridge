// PaymentModule.swift — Payment MCP Tools
// NotionBridge · Modules

import Foundation
import MCP

// MARK: - PaymentModule

public enum PaymentModule {
    public static let moduleName = "payment"
    public nonisolated(unsafe) static var amountCeiling = 50_000

    /// Register all PaymentModule tools on the given router.
    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "payment_execute",
            module: moduleName,
            tier: .request,
            neverAutoApprove: true,
            description: "Charge a Stripe payment method stored in the Keychain via a server-side PaymentIntent (no hosted checkout). Requires idempotency_key and user approval.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "credential_service": .object([
                        "type": .string("string"),
                        "description": .string("Service name for the stored payment method credential")
                    ]),
                    "credential_account": .object([
                        "type": .string("string"),
                        "description": .string("Account name for the stored payment method credential")
                    ]),
                    "amount": .object([
                        "type": .string("integer"),
                        "description": .string("Amount in cents (e.g. 2500 = $25.00)")
                    ]),
                    "currency": .object([
                        "type": .string("string"),
                        "description": .string("ISO 4217 currency code (default: usd)")
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Optional payment description")
                    ]),
                    "idempotency_key": .object([
                        "type": .string("string"),
                        "description": .string("Client-supplied idempotency key (UUID recommended)")
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
                      case .string(let idempotencyKey) = args["idempotency_key"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "payment_execute",
                        reason: "missing required 'credential_service', 'credential_account', 'amount', or 'idempotency_key' parameter"
                    )
                }

                guard CredentialsFeature.isEnabled else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "payment_execute",
                        reason: "Credentials are disabled. Enable Keychain credentials in Notion Bridge Settings → Credentials to charge stored payment methods."
                    )
                }

                let currency: String = {
                    if case .string(let c) = args["currency"], !c.isEmpty { return c }
                    return "usd"
                }()
                let description: String? = {
                    if case .string(let d) = args["description"], !d.isEmpty { return d }
                    return nil
                }()

                do {
                    let trimmedIdempotencyKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedIdempotencyKey.isEmpty else {
                        throw StripeError.missingIdempotencyKey
                    }
                    guard amount > 0 else {
                        throw StripeError.invalidAmount
                    }
                    guard amount <= amountCeiling else {
                        throw StripeError.amountExceedsCeiling(amount: amount, ceiling: amountCeiling)
                    }

                    try await CredentialManager.shared.requireBiometric(
                        reason: "Execute payment of \(amount) \(currency.uppercased())"
                    )

                    let credential = try CredentialManager.shared.read(
                        service: credentialService,
                        account: credentialAccount
                    )
                    guard let paymentMethod = credential.password, !paymentMethod.isEmpty else {
                        throw StripeError.processingError("Stored credential is missing payment method token")
                    }

                    let result = try await StripeClient.shared.createPaymentIntent(
                        amount: amount,
                        currency: currency,
                        paymentMethod: paymentMethod,
                        idempotencyKey: trimmedIdempotencyKey,
                        description: description,
                        metadata: [
                            "credential_service": credentialService,
                            "credential_account": credentialAccount
                        ]
                    )

                    return .object([
                        "payment_intent_id": .string(result.id),
                        "amount": .int(result.amount),
                        "currency": .string(result.currency),
                        "status": .string(result.status),
                        "created": .int(result.created)
                    ])
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))
    }
}
