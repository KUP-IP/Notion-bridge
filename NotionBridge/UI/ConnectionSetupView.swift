// ConnectionSetupView.swift — Connection Setup & Tunnel Status
// Notion Bridge v1: Minimal tunnel status display with provider selection
// PKT-329: V1-14b Connection Setup UI

import AppKit
import Security
import SwiftUI

// MARK: - Tunnel Provider

/// Tunnel provider options for connecting Notion agents to the local MCP server.
public enum TunnelProvider: String, CaseIterable, Identifiable {
    case cloudflare = "Cloudflare"
    case tailscale = "Tailscale"
    case manual = "Manual URL"

    public var id: String { rawValue }

    var displayDescription: String {
        switch self {
        case .cloudflare: return "Easiest setup for a public HTTPS URL"
        case .tailscale: return "Private network URL for your own devices/team"
        case .manual: return "Paste a URL from another tunnel provider"
        }
    }

    var icon: String {
        switch self {
        case .cloudflare: return "cloud.fill"
        case .tailscale: return "network"
        case .manual: return "link"
        }
    }
}

// MARK: - Connection Setup View

/// Displays tunnel status and provider selection for connecting remote Notion agents.
/// V1: Minimal — shows status indicator, selected provider, and manual URL input.
/// Settings are persisted via @AppStorage (UserDefaults).
public struct ConnectionSetupView: View {
    @AppStorage("tunnelProvider") private var selectedProvider: String = TunnelProvider.cloudflare.rawValue
    @AppStorage("tunnelURL") private var tunnelURL: String = ""
    @State private var isExpanded: Bool = false
    @State private var mcpBearerToken: String = ""
    @State private var saveBearerTask: Task<Void, Never>?

    /// SSE port resolution: config.json -> env var -> default.
    private var ssePort: Int {
        ConfigManager.shared.ssePort
    }

    public init() {}

    private var activeProvider: TunnelProvider {
        TunnelProvider(rawValue: selectedProvider) ?? .cloudflare
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusHeader
            if isExpanded { expandedContent }
        }
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tunnelURL.isEmpty ? .orange : .green)
                .frame(width: 8, height: 8)
            Text("Remote Access")
                .font(.callout)
            Spacer()
            Text(tunnelURL.isEmpty ? "Not configured" : activeProvider.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A tunnel gives remote MCP clients (e.g. Notion Agents) an HTTPS URL that forwards to your Mac. This is separate from API Connections (Stripe keys) and Notion workspace tokens.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Local endpoint info
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(verbatim: "Local: 127.0.0.1:\(ssePort)/mcp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            // Provider selection
            Text("TUNNEL PROVIDER")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(TunnelProvider.allCases) { provider in
                providerRow(provider)
            }

            // Tunnel URL input
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("TUNNEL URL")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("https://your-tunnel.example.com", text: $tunnelURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            if !tunnelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                mcpBearerSection
            }

            // Help text
            if activeProvider == .cloudflare {
                Text(verbatim: "Run in Terminal: cloudflared tunnel --url http://localhost:\(ssePort)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            } else if activeProvider == .tailscale {
                Text("Run in Terminal: tailscale funnel \(ssePort)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            } else {
                Text("Paste your tunnel URL here. It should forward to localhost:\(ssePort).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
        .onAppear {
            refreshMCPBearerFromStorage()
        }
        .onChange(of: tunnelURL) { _, _ in
            refreshMCPBearerFromStorage()
        }
    }

    // MARK: - MCP remote bearer (Streamable HTTP POST /mcp)

    private var mcpBearerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MCP REMOTE TOKEN")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("Required while a tunnel URL is set. In your MCP client, add a header: Authorization: Bearer <token>.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Browser-based clients such as Claude chat often cannot send Cloudflare service-token headers or complete browser challenges on /mcp. Prefer a path-scoped Cloudflare bypass for POST /mcp and rely on this bearer token at the app layer.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SecureField("Bearer token", text: $mcpBearerToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: mcpBearerToken) { _, newValue in
                        schedulePersistMCPBearer(newValue)
                    }
                Button("Generate") {
                    let token = Self.makeRandomBearerToken()
                    mcpBearerToken = token
                    persistMCPBearerImmediate(token)
                }
                .controlSize(.small)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mcpBearerToken, forType: .string)
                }
                .controlSize(.small)
                .disabled(mcpBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Clear") {
                    mcpBearerToken = ""
                    persistMCPBearerImmediate("")
                }
                .controlSize(.small)
            }
        }
    }

    private func refreshMCPBearerFromStorage() {
        mcpBearerToken = MCPHTTPValidation.resolveMCPBearerToken()
    }

    private func schedulePersistMCPBearer(_ value: String) {
        saveBearerTask?.cancel()
        saveBearerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            persistMCPBearerImmediate(value)
        }
    }

    private func persistMCPBearerImmediate(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            _ = KeychainManager.shared.delete(key: KeychainManager.Key.mcpBearerToken)
            UserDefaults.standard.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        } else {
            _ = KeychainManager.shared.save(key: KeychainManager.Key.mcpBearerToken, value: trimmed)
            UserDefaults.standard.set(trimmed, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        }
    }

    private static func makeRandomBearerToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let st = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(st == errSecSuccess, "SecRandomCopyBytes failed: \(st)")
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Provider Row

    private func providerRow(_ provider: TunnelProvider) -> some View {
        Button {
            selectedProvider = provider.rawValue
        } label: {
            HStack(spacing: 8) {
                Image(systemName: activeProvider == provider ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(activeProvider == provider ? .blue : .secondary)
                    .font(.callout)
                Image(systemName: provider.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.rawValue)
                        .font(.callout)
                    Text(provider.displayDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}
