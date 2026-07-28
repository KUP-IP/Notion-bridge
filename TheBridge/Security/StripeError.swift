import Foundation

public enum StripeError: Error, LocalizedError, @unchecked Sendable {
    case authenticationFailed
    case cardDeclined(String)
    case insufficientFunds
    case processingError(String)
    case rateLimited
    case networkError(Error)
    case invalidResponse
    case amountExceedsCeiling(amount: Int, ceiling: Int)
    case missingIdempotencyKey
    case invalidAmount
    case missingPriceID
    case invalidInput(String)
    case ambiguousResult(operation: String, count: Int)
    case illegalInvoiceState(operation: String, status: String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Stripe authentication failed. Check STRIPE_API_KEY."
        case .cardDeclined(let reason):
            return "Card was declined: \(reason)"
        case .insufficientFunds:
            return "Card was declined due to insufficient funds."
        case .processingError(let message):
            return "Stripe processing error: \(message)"
        case .rateLimited:
            return "Stripe rate limit exceeded. Please retry shortly."
        case .networkError(let error):
            return "Network error while calling Stripe: \(error.localizedDescription)"
        case .invalidResponse:
            return "Stripe returned an invalid response."
        case .amountExceedsCeiling(let amount, let ceiling):
            return "Amount \(amount) exceeds configured ceiling \(ceiling)."
        case .missingIdempotencyKey:
            return "Missing required idempotency key."
        case .invalidAmount:
            return "Amount must be greater than zero."
        case .missingPriceID:
            return "No Stripe Price is configured for checkout. Set the live Price id (operator)."
        case .invalidInput(let message):
            return "Invalid Stripe input: \(message)"
        case .ambiguousResult(let operation, let count):
            return "Stripe \(operation) reconciliation is ambiguous: \(count) matching objects."
        case .illegalInvoiceState(let operation, let status):
            return "Cannot \(operation) a Stripe invoice in status \(status)."
        }
    }
}
