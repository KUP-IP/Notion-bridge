// StripeModule.swift — Stripe Catalog MCP Tools
// NotionBridge · Modules
// v1.5.5: Product and price management tools for Stripe catalog operations.

import Foundation
import MCP

// MARK: - StripeModule

public enum StripeModule {
    public static let moduleName = "stripe"

    /// Register all StripeModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: stripe_product_read

        await router.register(ToolRegistration(
            name: "stripe_product_read",
            module: moduleName,
            tier: .notify,
            description: "Retrieve a Stripe product by ID. Returns product name, description, active status, metadata, marketing features, default price, and timestamps.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object([
                        "type": .string("string"),
                        "description": .string("Stripe product ID (e.g. prod_ABC123)")
                    ])
                ]),
                "required": .array([.string("product_id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let productId) = args["product_id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "stripe_product_read",
                        reason: "missing required 'product_id' parameter"
                    )
                }

                do {
                    let product = try await StripeClient.shared.retrieveProduct(id: productId)
                    return productToValue(product)
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))

        // MARK: stripe_product_update

        await router.register(ToolRegistration(
            name: "stripe_product_update",
            module: moduleName,
            tier: .request,
            description: "Update a Stripe product's name, description, metadata, marketing features, or active status. Returns the updated product.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object([
                        "type": .string("string"),
                        "description": .string("Stripe product ID to update")
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("New product name (optional)")
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("New product description (optional)")
                    ]),
                    "active": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether the product is active (optional)")
                    ]),
                    "metadata": .object([
                        "type": .string("object"),
                        "description": .string("Key-value metadata to set on the product (optional)")
                    ]),
                    "marketing_features": .object([
                        "type": .string("array"),
                        "description": .string("Array of marketing feature objects, each with a 'name' key (optional). Max 15 features.")
                    ])
                ]),
                "required": .array([.string("product_id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let productId) = args["product_id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "stripe_product_update",
                        reason: "missing required 'product_id' parameter"
                    )
                }

                let name: String? = {
                    if case .string(let n) = args["name"], !n.isEmpty { return n }
                    return nil
                }()
                let description: String? = {
                    if case .string(let d) = args["description"] { return d }
                    return nil
                }()
                let active: Bool? = {
                    if case .bool(let a) = args["active"] { return a }
                    return nil
                }()
                let metadata: [String: String]? = {
                    if case .object(let m) = args["metadata"] {
                        var result: [String: String] = [:]
                        for (key, value) in m {
                            if case .string(let v) = value { result[key] = v }
                        }
                        return result.isEmpty ? nil : result
                    }
                    return nil
                }()
                let marketingFeatures: [[String: String]]? = {
                    if case .array(let features) = args["marketing_features"] {
                        return features.compactMap { feature in
                            if case .object(let f) = feature {
                                var result: [String: String] = [:]
                                for (key, value) in f {
                                    if case .string(let v) = value { result[key] = v }
                                }
                                return result.isEmpty ? nil : result
                            }
                            return nil
                        }
                    }
                    return nil
                }()

                do {
                    let product = try await StripeClient.shared.updateProduct(
                        id: productId,
                        name: name,
                        description: description,
                        metadata: metadata,
                        marketingFeatures: marketingFeatures,
                        active: active
                    )
                    return productToValue(product)
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))

        // MARK: stripe_price_read

        await router.register(ToolRegistration(
            name: "stripe_price_read",
            module: moduleName,
            tier: .notify,
            description: "Retrieve a Stripe price by ID. Returns price amount, currency, type, recurring info, and associated product.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "price_id": .object([
                        "type": .string("string"),
                        "description": .string("Stripe price ID (e.g. price_ABC123)")
                    ])
                ]),
                "required": .array([.string("price_id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let priceId) = args["price_id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "stripe_price_read",
                        reason: "missing required 'price_id' parameter"
                    )
                }

                do {
                    let price = try await StripeClient.shared.retrievePrice(id: priceId)
                    return priceToValue(price)
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))

        // MARK: stripe_prices_list

        await router.register(ToolRegistration(
            name: "stripe_prices_list",
            module: moduleName,
            tier: .notify,
            description: "List prices for a Stripe product. Optionally filter by active status. Returns up to 100 prices.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object([
                        "type": .string("string"),
                        "description": .string("Stripe product ID to list prices for (optional)")
                    ]),
                    "active": .object([
                        "type": .string("boolean"),
                        "description": .string("Filter by active status (optional)")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of prices to return (default: 10, max: 100)")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value]
                if case .object(let a) = arguments { args = a } else { args = [:] }

                let productId: String? = {
                    if case .string(let p) = args["product_id"], !p.isEmpty { return p }
                    return nil
                }()
                let active: Bool? = {
                    if case .bool(let a) = args["active"] { return a }
                    return nil
                }()
                let limit: Int = {
                    if case .int(let l) = args["limit"] { return l }
                    return 10
                }()

                do {
                    let prices = try await StripeClient.shared.listPrices(
                        productId: productId,
                        active: active,
                        limit: limit
                    )
                    let priceValues: [Value] = prices.map { priceToValue($0) }
                    return .object([
                        "prices": .array(priceValues),
                        "count": .int(prices.count)
                    ])
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))
    }

    // MARK: - Value Converters

    private static func productToValue(_ product: StripeProduct) -> Value {
        var result: [String: Value] = [
            "id": .string(product.id),
            "name": .string(product.name),
            "active": .bool(product.active),
            "created": .int(product.created),
            "updated": .int(product.updated)
        ]
        if let desc = product.description {
            result["description"] = .string(desc)
        }
        if let defaultPrice = product.defaultPrice {
            result["default_price"] = .string(defaultPrice)
        }
        if !product.metadata.isEmpty {
            var metaObj: [String: Value] = [:]
            for (key, value) in product.metadata {
                metaObj[key] = .string(value)
            }
            result["metadata"] = .object(metaObj)
        }
        if !product.marketingFeatures.isEmpty {
            let features: [Value] = product.marketingFeatures.map { feature in
                var featureObj: [String: Value] = [:]
                for (key, value) in feature {
                    featureObj[key] = .string(value)
                }
                return .object(featureObj)
            }
            result["marketing_features"] = .array(features)
        }
        return .object(result)
    }

    private static func priceToValue(_ price: StripePrice) -> Value {
        var result: [String: Value] = [
            "id": .string(price.id),
            "product": .string(price.product),
            "active": .bool(price.active),
            "currency": .string(price.currency),
            "type": .string(price.type)
        ]
        if let amount = price.unitAmount {
            result["unit_amount"] = .int(amount)
        }
        if let nickname = price.nickname {
            result["nickname"] = .string(nickname)
        }
        if let recurring = price.recurring {
            var recurObj: [String: Value] = [:]
            for (key, value) in recurring {
                recurObj[key] = .string(value)
            }
            result["recurring"] = .object(recurObj)
        }
        return .object(result)
    }
}
