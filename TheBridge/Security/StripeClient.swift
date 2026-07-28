import Foundation

public struct StripeRequestEvidence: Sendable, Equatable {
    public let operation: String
    public let method: String
    public let path: String
    public let idempotencyKey: String?
    public let requestAPIVersion: String
    public let statusCode: Int?
    public let requestID: String?
    public let responseAPIVersion: String?

    public init(
        operation: String,
        method: String,
        path: String,
        idempotencyKey: String?,
        requestAPIVersion: String,
        statusCode: Int?,
        requestID: String?,
        responseAPIVersion: String?
    ) {
        self.operation = operation
        self.method = method
        self.path = path
        self.idempotencyKey = idempotencyKey
        self.requestAPIVersion = requestAPIVersion
        self.statusCode = statusCode
        self.requestID = requestID
        self.responseAPIVersion = responseAPIVersion
    }
}

struct StripeHTTPResponse: Sendable {
    let data: Data
    let evidence: StripeRequestEvidence
}

enum StripeFailureDisposition: Sendable {
    case definitive
    case indeterminateExternalEffect
}

struct StripeTransportFailure: Error, @unchecked Sendable {
    let error: StripeError
    let disposition: StripeFailureDisposition
    let evidence: StripeRequestEvidence
}


public struct PaymentIntentResult: Sendable, Equatable {
    public let id: String
    public let amount: Int
    public let currency: String
    public let status: String
    public let created: Int

    public init(id: String, amount: Int, currency: String, status: String, created: Int) {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.status = status
        self.created = created
    }
}

public struct CheckoutSession: Sendable, Equatable {
    /// Stripe Checkout Session id (`cs_…`). Correlates to the buyer's payment.
    public let id: String
    /// Hosted Checkout URL the buyer opens to pay.
    public let url: String

    public init(id: String, url: String) {
        self.id = id
        self.url = url
    }
}

public struct StripeAccountInfo: Sendable, Equatable {
    public let id: String
    public let email: String?
    public let displayName: String?
    public let country: String?
    public let chargesEnabled: Bool

    public init(id: String, email: String?, displayName: String?, country: String?, chargesEnabled: Bool) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.country = country
        self.chargesEnabled = chargesEnabled
    }
}

public final class StripeClient: @unchecked Sendable {
    public static let shared = StripeClient()
    public static let apiVersion = "2025-06-30.basil"

    let session: URLSession
    let apiKeyProvider: @Sendable () -> String?

    public init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = {
            KeychainManager.shared.read(key: KeychainManager.Key.stripeAPIKey)
        }
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    public func createPaymentIntent(
        amount: Int,
        currency: String,
        paymentMethod: String,
        idempotencyKey: String,
        description: String?,
        metadata: [String: String]?
    ) async throws -> PaymentIntentResult {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StripeError.missingIdempotencyKey
        }
        guard amount > 0 else {
            throw StripeError.invalidAmount
        }

        var formFields: [String: String] = [
            "amount": String(amount),
            "currency": currency,
            "payment_method": paymentMethod,
            "confirm": "true"
        ]
        if let description, !description.isEmpty {
            formFields["description"] = description
        }
        if let metadata {
            for (key, value) in metadata {
                formFields["metadata[\(key)]"] = value
            }
        }

        let bodyString = Self.formURLEncoded(formFields)
        var request = try authorizedRequest(
            method: "POST",
            endpoint: "payment_intents",
            idempotencyKey: idempotencyKey
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)
        return try await executePaymentIntentRequest(request)
    }

    public func retrievePaymentIntent(id: String) async throws -> PaymentIntentResult {
        var request = try authorizedRequest(
            method: "GET",
            endpoint: "payment_intents/\(id)"
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await executePaymentIntentRequest(request)
    }

    public func retrieveAccountInfo() async throws -> StripeAccountInfo {
        let request = try authorizedRequest(method: "GET", endpoint: "account")
        let data = try await performRequest(request)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"] as? String
        else {
            throw StripeError.invalidResponse
        }

        let businessProfile = json["business_profile"] as? [String: Any]
        let displayName = businessProfile?["name"] as? String
            ?? json["display_name"] as? String
            ?? json["business_type"] as? String

        return StripeAccountInfo(
            id: id,
            email: json["email"] as? String,
            displayName: displayName,
            country: json["country"] as? String,
            chargesEnabled: json["charges_enabled"] as? Bool ?? false
        )
    }

    /// Create a hosted Stripe Checkout Session (Payment P1). Returns the
    /// session id + the hosted `url` the buyer opens to pay. Brand-scoped
    /// `metadata` + `clientReferenceID` ride on the session so the (external)
    /// fulfillment worker can mint + email the license after `checkout.session
    /// .completed`. `priceID` is the operator-configured live Stripe Price;
    /// Stripe live product/price config + the fulfillment worker are
    /// operator/external (out of P1 scope).
    public func createCheckoutSession(
        priceID: String,
        successURL: String,
        cancelURL: String,
        metadata: [String: String] = [:],
        clientReferenceID: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> CheckoutSession {
        guard !priceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StripeError.missingPriceID
        }
        var fields: [String: String] = [
            "mode": "payment",
            "line_items[0][price]": priceID,
            "line_items[0][quantity]": "1",
            "success_url": successURL,
            "cancel_url": cancelURL
        ]
        if let clientReferenceID, !clientReferenceID.isEmpty {
            fields["client_reference_id"] = clientReferenceID
        }
        for (key, value) in metadata {
            fields["metadata[\(key)]"] = value
        }

        var request = try authorizedRequest(
            method: "POST",
            endpoint: "checkout/sessions",
            idempotencyKey: idempotencyKey
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncoded(fields).data(using: .utf8)
        let data = try await performRequest(request)
        return try Self.parseCheckoutSession(data: data)
    }

    static func parseCheckoutSession(data: Data) throws -> CheckoutSession {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"] as? String,
            let url = json["url"] as? String
        else {
            throw StripeError.invalidResponse
        }
        return CheckoutSession(id: id, url: url)
    }

    private func executePaymentIntentRequest(_ request: URLRequest) async throws -> PaymentIntentResult {
        let data = try await performRequest(request)
        return try Self.parsePaymentIntent(data: data)
    }

    private func performRequest(_ request: URLRequest) async throws -> Data {
        do {
            return try await performEvidenceRequest(request, operation: request.url?.path ?? "stripe_request").data
        } catch let failure as StripeTransportFailure {
            throw failure.error
        }
    }

    func performEvidenceRequest(_ request: URLRequest, operation: String) async throws -> StripeHTTPResponse {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let idempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key")
        let baseEvidence = StripeRequestEvidence(
            operation: operation,
            method: method,
            path: path,
            idempotencyKey: idempotencyKey,
            requestAPIVersion: Self.apiVersion,
            statusCode: nil,
            requestID: nil,
            responseAPIVersion: nil
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StripeTransportFailure(
                error: .networkError(error),
                disposition: Self.isMutating(method) ? .indeterminateExternalEffect : .definitive,
                evidence: baseEvidence
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw StripeTransportFailure(
                error: .invalidResponse,
                disposition: Self.isMutating(method) ? .indeterminateExternalEffect : .definitive,
                evidence: baseEvidence
            )
        }

        let evidence = StripeRequestEvidence(
            operation: operation,
            method: method,
            path: path,
            idempotencyKey: idempotencyKey,
            requestAPIVersion: Self.apiVersion,
            statusCode: http.statusCode,
            requestID: http.value(forHTTPHeaderField: "Request-Id"),
            responseAPIVersion: http.value(forHTTPHeaderField: "Stripe-Version")
        )
        guard (200...299).contains(http.statusCode) else {
            throw StripeTransportFailure(
                error: Self.parseStripeError(statusCode: http.statusCode, data: data),
                disposition: Self.isMutating(method) && (500...599).contains(http.statusCode)
                    ? .indeterminateExternalEffect
                    : .definitive,
                evidence: evidence
            )
        }
        return StripeHTTPResponse(data: data, evidence: evidence)
    }

    func authorizedRequest(
        method: String,
        endpoint: String,
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        try authorizedRequest(method: method, path: endpoint, queryItems: [], idempotencyKey: idempotencyKey)
    }

    func authorizedRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw StripeError.authenticationFailed
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.stripe.com"
        components.path = "/v1/\(path)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw StripeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Stripe-Version")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        return request
    }

    private static func isMutating(_ method: String) -> Bool {
        switch method.uppercased() {
        case "POST", "PUT", "PATCH", "DELETE": return true
        default: return false
        }
    }

    public static func parseStripeError(statusCode: Int, data: Data) -> StripeError {
        if statusCode == 429 {
            return .rateLimited
        }
        if statusCode == 401 || statusCode == 403 {
            return .authenticationFailed
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorObj = json["error"] as? [String: Any]
        else {
            return .processingError("Stripe request failed with HTTP \(statusCode)")
        }

        let message = (errorObj["message"] as? String) ?? "Stripe request failed with HTTP \(statusCode)"
        let code = errorObj["code"] as? String
        let declineCode = errorObj["decline_code"] as? String
        let type = errorObj["type"] as? String

        if declineCode == "insufficient_funds" || code == "insufficient_funds" {
            return .insufficientFunds
        }
        if code == "card_declined" || type == "card_error" {
            return .cardDeclined(declineCode ?? message)
        }
        return .processingError(message)
    }

    private static func parsePaymentIntent(data: Data) throws -> PaymentIntentResult {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"] as? String,
            let amount = json["amount"] as? Int,
            let currency = json["currency"] as? String,
            let status = json["status"] as? String,
            let created = json["created"] as? Int
        else {
            throw StripeError.invalidResponse
        }
        return PaymentIntentResult(
            id: id,
            amount: amount,
            currency: currency,
            status: status,
            created: created
        )
    }

    public static func formURLEncoded(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
    }

    static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? value
    }
}
