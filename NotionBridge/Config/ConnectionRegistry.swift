import Foundation

public enum ConnectionRegistryError: Error, LocalizedError {
    case invalidConnectionId(String)
    case connectionNotFound(String)
    case unsupportedAction(String)
    case invalidAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidConnectionId(let id):
            return "Invalid connection id: \(id)"
        case .connectionNotFound(let id):
            return "Connection not found: \(id)"
        case .unsupportedAction(let action):
            return action
        case .invalidAPIKey:
            return "API key cannot be empty"
        }
    }
}

public actor ConnectionRegistry {
    public static let shared = ConnectionRegistry()

    private let formatter = ISO8601DateFormatter()

    public init() {}

    public func listConnections(
        provider: BridgeConnectionProvider? = nil,
        kind: BridgeConnectionKind? = nil,
        validateLive: Bool = true
    ) async throws -> [BridgeConnection] {
        var connections = try await buildConnections(validateLive: validateLive)
        if let provider {
            connections.removeAll { $0.provider != provider }
        }
        if let kind {
            connections.removeAll { $0.kind != kind }
        }
        return connections.sorted { lhs, rhs in
            self.sortConnections(lhs: lhs, rhs: rhs)
        }
    }

    public func getConnection(id: String, validateLive: Bool = true) async throws -> BridgeConnection {
        let provider = try parseProvider(from: id)
        switch provider {
        case .notion:
            let notionConnections = try await buildNotionConnections(validateLive: validateLive)
            if let match = notionConnections.first(where: { $0.id == id }) {
                return match
            }
        case .stripe:
            let stripeConnection = try await buildStripeConnection(validateLive: validateLive)
            if stripeConnection.id == id {
                return stripeConnection
            }
        case .tunnel:
            let tunnelConnection = buildTunnelConnection()
            if tunnelConnection.id == id {
                return tunnelConnection
            }
        }
        throw ConnectionRegistryError.connectionNotFound(id)
    }

    public func validateConnection(id: String) async throws -> BridgeConnection {
        try await getConnection(id: id, validateLive: true)
    }

    public func capabilities(forConnectionId id: String) async throws -> [String] {
        try await getConnection(id: id, validateLive: false).capabilities
    }

    public func configureStripeAPIKey(_ apiKey: String) async throws -> BridgeConnection {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConnectionRegistryError.invalidAPIKey
        }

        let updated = KeychainManager.shared.update(key: KeychainManager.Key.stripeAPIKey, value: trimmed)
        guard updated else {
            throw ConnectionRegistryError.unsupportedAction("Failed to store Stripe API key in Keychain")
        }

        ConfigManager.shared.stripeAPIKey = nil
        return try await buildStripeConnection(validateLive: true)
    }

    public func removeConnection(id: String) async throws {
        let provider = try parseProvider(from: id)
        switch provider {
        case .notion:
            let name = try parseName(from: id)
            try await NotionClientRegistry.shared.removeConnection(name: name)
            await ConnectionHealthChecker.shared.invalidate(connectionName: name)
        case .stripe:
            _ = KeychainManager.shared.delete(key: KeychainManager.Key.stripeAPIKey)
            ConfigManager.shared.stripeAPIKey = nil
        case .tunnel:
            throw ConnectionRegistryError.unsupportedAction("Remote access is managed through the Remote Access settings section")
        }
    }

    public func renameConnection(id: String, to newName: String) async throws {
        let provider = try parseProvider(from: id)
        switch provider {
        case .notion:
            let oldName = try parseName(from: id)
            try await NotionClientRegistry.shared.renameConnection(from: oldName, to: newName)
            await ConnectionHealthChecker.shared.invalidateAll()
        case .stripe, .tunnel:
            throw ConnectionRegistryError.unsupportedAction("Renaming is not supported for this connection type")
        }
    }

    public func setPrimary(id: String) async throws {
        let provider = try parseProvider(from: id)
        switch provider {
        case .notion:
            let name = try parseName(from: id)
            try await NotionClientRegistry.shared.setPrimary(name: name)
            await ConnectionHealthChecker.shared.invalidateAll()
        case .stripe, .tunnel:
            throw ConnectionRegistryError.unsupportedAction("Only workspace connections can be set as primary")
        }
    }

    private func buildConnections(validateLive: Bool) async throws -> [BridgeConnection] {
        var connections = try await buildNotionConnections(validateLive: validateLive)
        connections.append(try await buildStripeConnection(validateLive: validateLive))
        connections.append(buildTunnelConnection())
        return connections
    }

    private func buildNotionConnections(validateLive: Bool) async throws -> [BridgeConnection] {
        let notionConnections = try await NotionClientRegistry.shared.listConnections()
        var connections: [BridgeConnection] = []
        connections.reserveCapacity(notionConnections.count)

        for info in notionConnections {
            let health = validateLive
                ? await ConnectionHealthChecker.shared.checkNotionHealth(connectionName: info.name)
                : .checking
            let validatedAt = validateLive ? formatter.string(from: Date()) : nil
            connections.append(
                BridgeConnection(
                    id: "\(BridgeConnectionProvider.notion.rawValue):\(info.name)",
                    provider: .notion,
                    kind: .workspace,
                    name: info.name,
                    isPrimary: info.isPrimary,
                    status: mapHealth(health),
                    authType: "token",
                    maskedCredential: info.maskedToken,
                    capabilities: [
                        "search",
                        "page_read",
                        "page_update",
                        "query",
                        "comments",
                        "file_upload"
                    ],
                    lastValidatedAt: validatedAt,
                    summary: "Notion workspace connection",
                    metadata: ["workspace": info.name]
                )
            )
        }

        return connections
    }

    private func buildStripeConnection(validateLive: Bool) async throws -> BridgeConnection {
        let secret = KeychainManager.shared.read(key: KeychainManager.Key.stripeAPIKey)
            ?? ConfigManager.shared.stripeAPIKey
        let maskedCredential = secret.map { BridgeConnection.maskSecret($0) }

        guard let secret, !secret.isEmpty else {
            return BridgeConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default",
                provider: .stripe,
                kind: .api,
                name: "Stripe",
                status: .notConfigured,
                authType: "api_key",
                maskedCredential: nil,
                capabilities: ["payment_execute", "card_tokenization", "stripe_product_read", "stripe_product_update", "stripe_price_read", "stripe_prices_list"],
                summary: "Configure a Stripe API key to enable payment and tokenization flows"
            )
        }

        guard validateLive else {
            return BridgeConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default",
                provider: .stripe,
                kind: .api,
                name: "Stripe",
                status: .checking,
                authType: "api_key",
                maskedCredential: maskedCredential,
                capabilities: ["payment_execute", "card_tokenization", "stripe_product_read", "stripe_product_update", "stripe_price_read", "stripe_prices_list"],
                summary: "Stripe API connection"
            )
        }

        do {
            let account = try await StripeClient.shared.retrieveAccountInfo()
            let status: BridgeConnectionStatus = account.chargesEnabled ? .connected : .warning
            return BridgeConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default",
                provider: .stripe,
                kind: .api,
                name: account.displayName ?? "Stripe",
                status: status,
                authType: "api_key",
                maskedCredential: maskedCredential,
                capabilities: ["payment_execute", "card_tokenization", "stripe_product_read", "stripe_product_update", "stripe_price_read", "stripe_prices_list"],
                lastValidatedAt: formatter.string(from: Date()),
                summary: account.email ?? account.id,
                metadata: [
                    "account_id": account.id,
                    "country": account.country ?? "",
                    "charges_enabled": account.chargesEnabled ? "true" : "false"
                ]
            )
        } catch {
            return BridgeConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default",
                provider: .stripe,
                kind: .api,
                name: "Stripe",
                status: .disconnected,
                authType: "api_key",
                maskedCredential: maskedCredential,
                capabilities: ["payment_execute", "card_tokenization", "stripe_product_read", "stripe_product_update", "stripe_price_read", "stripe_prices_list"],
                lastValidatedAt: formatter.string(from: Date()),
                summary: error.localizedDescription
            )
        }
    }

    private func buildTunnelConnection() -> BridgeConnection {
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: "tunnelProvider") ?? "Cloudflare"
        let tunnelURL = defaults.string(forKey: "tunnelURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isValidURL = URL(string: tunnelURL) != nil
        let status: BridgeConnectionStatus = tunnelURL.isEmpty ? .notConfigured : (isValidURL ? .connected : .warning)

        return BridgeConnection(
            id: "\(BridgeConnectionProvider.tunnel.rawValue):remote-access",
            provider: .tunnel,
            kind: .remoteAccess,
            name: provider,
            status: status,
            authType: "url",
            maskedCredential: tunnelURL.isEmpty ? nil : tunnelURL,
            capabilities: ["remote_access"],
            summary: tunnelURL.isEmpty ? "Configure a public or private tunnel URL for remote agent access" : tunnelURL,
            metadata: [
                "provider": provider,
                "url": tunnelURL
            ]
        )
    }

    private func parseProvider(from id: String) throws -> BridgeConnectionProvider {
        guard let raw = id.split(separator: ":", maxSplits: 1).first,
              let provider = BridgeConnectionProvider(rawValue: String(raw).lowercased()) else {
            throw ConnectionRegistryError.invalidConnectionId(id)
        }
        return provider
    }

    private func parseName(from id: String) throws -> String {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else {
            throw ConnectionRegistryError.invalidConnectionId(id)
        }
        return parts[1]
    }

    private func mapHealth(_ health: ConnectionHealth) -> BridgeConnectionStatus {
        switch health {
        case .healthy:
            return .connected
        case .warning:
            return .warning
        case .error:
            return .disconnected
        case .unconfigured:
            return .notConfigured
        case .checking:
            return .checking
        }
    }

    private func sortConnections(lhs: BridgeConnection, rhs: BridgeConnection) -> Bool {
        let kindOrder: [BridgeConnectionKind: Int] = [.workspace: 0, .api: 1, .remoteAccess: 2]
        let leftKind = kindOrder[lhs.kind] ?? 9
        let rightKind = kindOrder[rhs.kind] ?? 9
        if leftKind != rightKind {
            return leftKind < rightKind
        }
        if lhs.isPrimary != rhs.isPrimary {
            return lhs.isPrimary && !rhs.isPrimary
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
