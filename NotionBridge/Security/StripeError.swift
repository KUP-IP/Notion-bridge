import Foundation

public enum StripeError: LocalizedError {
    case authenticationFailed
    case cardDeclined(String)
    case insufficientFunds
    case processingError(String)
    case rateLimited
    case networkError(Error)
    case invalidResponse
    case amountExceedsCeiling(amount: Int, ceiling: Int)
    case missingIdempotencyKey
    case missingCredential
    case biometricFailed

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Stripe authentication failed. Verify STRIPE_API_KEY."
        case .cardDeclined(let code):
            let suffix = code.isEmpty ? "" : " (\(code))"
            return "Card was declined\(suffix)."
        case .insufficientFunds:
            return "Payment failed: insufficient funds."
        case .processingError(let message):
            return "Stripe processing error: \(message)"
        case .rateLimited:
            return "Stripe rate limit exceeded. Retry later."
        case .networkError(let error):
            return "Network error contacting Stripe: \(error.localizedDescription)"
        case .invalidResponse:
            return "Stripe returned an invalid response."
        case .amountExceedsCeiling(let amount, let ceiling):
            return "Amount \(amount) exceeds configured ceiling \(ceiling)."
        case .missingIdempotencyKey:
            return "idempotency_key is required and must be non-empty."
        case .missingCredential:
            return "Stored credential not found for the provided service/account."
        case .biometricFailed:
            return "Biometric authentication failed."
        }
    }
}
