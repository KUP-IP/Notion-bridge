// ConnectionSetupView.swift — Connection Setup & Tunnel Status
// Notion Bridge v1: Minimal tunnel status display with provider selection
// PKT-329: V1-14b Connection Setup UI

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
