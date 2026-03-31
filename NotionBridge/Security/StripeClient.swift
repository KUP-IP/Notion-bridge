import Foundation

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


public struct StripeProduct: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let active: Bool
    public let metadata: [String: String]
    public let marketingFeatures: [[String: String]]
    public let defaultPrice: String?
    public let created: Int
    public let updated: Int

    public init(id: String, name: String, description: String?, active: Bool,
                metadata: [String: String], marketingFeatures: [[String: String]],
                defaultPrice: String?, created: Int, updated: Int) {
        self.id = id
        self.name = name
        self.description = description
        self.active = active
        self.metadata = metadata
        self.marketingFeatures = marketingFeatures
        self.defaultPrice = defaultPrice
        self.created = created
        self.updated = updated
    }
}

public struct StripePrice: Sendable, Equatable {
    public let id: String
    public let product: String
    public let active: Bool
    public let currency: String
    public let unitAmount: Int?
    public let type: String
    public let recurring: [String: String]?
    public let nickname: String?

    public init(id: String, product: String, active: Bool, currency: String,
                unitAmount: Int?, type: String, recurring: [String: String]?,
                nickname: String?) {
        self.id = id
        self.product = product
        self.active = active
        self.currency = currency
        self.unitAmount = unitAmount
        self.type = type
        self.recurring = recurring
        self.nickname = nickname
    }
}

public final class StripeClient: @unchecked Sendable {
    public static let shared = StripeClient()

    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?

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


    // MARK: - Product Catalog

    public func retrieveProduct(id: String) async throws -> StripeProduct {
        let request = try authorizedRequest(method: "GET", endpoint: "products/\(id)")
        let data = try await performRequest(request)
        return try Self.parseProduct(data: data)
    }

    public func updateProduct(
        id: String,
        name: String? = nil,
        description: String? = nil,
        metadata: [String: String]? = nil,
        marketingFeatures: [[String: String]]? = nil,
        active: Bool? = nil
    ) async throws -> StripeProduct {
        var formFields: [String: String] = [:]
        if let name, !name.isEmpty { formFields["name"] = name }
        if let description { formFields["description"] = description }
        if let active { formFields["active"] = active ? "true" : "false" }
        if let metadata {
            for (key, value) in metadata {
                formFields["metadata[\(key)]"] = value
            }
        }
        if let marketingFeatures {
            for (index, feature) in marketingFeatures.enumerated() {
                for (key, value) in feature {
                    formFields["marketing_features[\(index)][\(key)]"] = value
                }
            }
        }

        let bodyString = Self.formURLEncoded(formFields)
        var request = try authorizedRequest(method: "POST", endpoint: "products/\(id)")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)
        let data = try await performRequest(request)
        return try Self.parseProduct(data: data)
    }

    public func retrievePrice(id: String) async throws -> StripePrice {
        let request = try authorizedRequest(method: "GET", endpoint: "prices/\(id)")
        let data = try await performRequest(request)
        return try Self.parsePrice(data: data)
    }

    public func listPrices(
        productId: String? = nil,
        active: Bool? = nil,
        limit: Int = 10
    ) async throws -> [StripePrice] {
        var queryItems: [String] = ["limit=\(min(limit, 100))"]
        if let productId { queryItems.append("product=\(productId)") }
        if let active { queryItems.append("active=\(active ? "true" : "false")") }
        let queryString = queryItems.joined(separator: "&")
        let request = try authorizedRequest(method: "GET", endpoint: "prices?\(queryString)")
        let data = try await performRequest(request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw StripeError.invalidResponse
        }
        return try dataArray.map { item in
            let itemData = try JSONSerialization.data(withJSONObject: item)
            return try Self.parsePrice(data: itemData)
        }
    }

    private func executePaymentIntentRequest(_ request: URLRequest) async throws -> PaymentIntentResult {
        let data = try await performRequest(request)
        return try Self.parsePaymentIntent(data: data)
    }

    private func performRequest(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StripeError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StripeError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.parseStripeError(statusCode: http.statusCode, data: data)
        }
        return data
    }

    private func authorizedRequest(
        method: String,
        endpoint: String,
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw StripeError.authenticationFailed
        }
        guard let url = URL(string: "https://api.stripe.com/v1/\(endpoint)") else {
            throw StripeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        return request
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


    public static func parseProduct(data: Data) throws -> StripeProduct {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let name = json["name"] as? String else {
            throw StripeError.invalidResponse
        }
        let metadata = json["metadata"] as? [String: String] ?? [:]
        let rawFeatures = json["marketing_features"] as? [[String: Any]] ?? []
        let marketingFeatures: [[String: String]] = rawFeatures.map { feature in
            var result: [String: String] = [:]
            if let name = feature["name"] as? String { result["name"] = name }
            return result
        }
        return StripeProduct(
            id: id,
            name: name,
            description: json["description"] as? String,
            active: json["active"] as? Bool ?? true,
            metadata: metadata,
            marketingFeatures: marketingFeatures,
            defaultPrice: json["default_price"] as? String,
            created: json["created"] as? Int ?? 0,
            updated: json["updated"] as? Int ?? 0
        )
    }

    public static func parsePrice(data: Data) throws -> StripePrice {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw StripeError.invalidResponse
        }
        let product: String
        if let p = json["product"] as? String {
            product = p
        } else if let pObj = json["product"] as? [String: Any], let pId = pObj["id"] as? String {
            product = pId
        } else {
            product = ""
        }
        let recurring: [String: String]? = {
            guard let r = json["recurring"] as? [String: Any] else { return nil }
            var result: [String: String] = [:]
            if let interval = r["interval"] as? String { result["interval"] = interval }
            if let count = r["interval_count"] as? Int { result["interval_count"] = String(count) }
            return result.isEmpty ? nil : result
        }()
        return StripePrice(
            id: id,
            product: product,
            active: json["active"] as? Bool ?? true,
            currency: json["currency"] as? String ?? "usd",
            unitAmount: json["unit_amount"] as? Int,
            type: json["type"] as? String ?? "one_time",
            recurring: recurring,
            nickname: json["nickname"] as? String
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

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? value
    }
}
