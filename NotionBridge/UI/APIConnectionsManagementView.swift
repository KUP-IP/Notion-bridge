import SwiftUI

/// API keys and service accounts (Stripe, future providers). Not Notion workspace tokens.
public struct APIConnectionsManagementView: View {
    @State private var apiConnections: [BridgeConnection] = []
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var isSaving = false
    @State private var apiKey = ""
    @State private var saveError: String?
    @State private var saveSuccessMessage: String?
    @State private var showApiKeyEditor = false

    public init() {}

    private var stripeConnection: BridgeConnection? {
        apiConnections.first { $0.provider == .stripe }
    }

    /// Show Stripe key field + “Set Stripe API key” only when user may need to add or replace a key.
    private var showStripeKeyEditorChrome: Bool {
        guard let s = stripeConnection else { return false }
        switch s.status {
        case .notConfigured, .disconnected, .warning:
            return true
        case .connected, .checking:
            return false
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading API connections…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else if apiConnections.isEmpty {
                Text("No API connections configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(apiConnections) { connection in
                    if connection.provider == .stripe {
                        stripeConnectionRow(connection)
                    } else {
                        genericConnectionRow(connection)
                    }
                }
            }

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let saveSuccessMessage {
                Text(saveSuccessMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if showStripeKeyEditorChrome, showApiKeyEditor {
                SecureField("Paste Stripe secret key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Stripe key") {
                        Task { await saveStripeKey() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

                    Button("Cancel") {
                        apiKey = ""
                        saveError = nil
                        saveSuccessMessage = nil
                        showApiKeyEditor = false
                    }
                }
            }

            HStack {
                if showStripeKeyEditorChrome {
                    Button {
                        showApiKeyEditor.toggle()
                        saveError = nil
                        saveSuccessMessage = nil
                    } label: {
                        Label(showApiKeyEditor ? "Hide Stripe key editor" : "Set Stripe API key", systemImage: "key.horizontal")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                if isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Validating…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await reloadConnections() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh API connection status")
            }
        }
        .task { await reloadConnections() }
        .onChange(of: showStripeKeyEditorChrome) { _, show in
            if !show {
                showApiKeyEditor = false
                apiKey = ""
            }
        }
    }

    private func stripeConnectionRow(_ connection: BridgeConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: connection.status.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor(connection.status))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(connection.provider.displayName)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(connection.name)
                            .font(.callout)
                    }
                }
                Spacer()
                Text(stripeStatusRightLabel(connection.status))
                    .font(.caption2)
                    .foregroundStyle(statusColor(connection.status))
            }
        }
        .padding(.vertical, 4)
    }

    private func stripeStatusRightLabel(_ status: BridgeConnectionStatus) -> String {
        switch status {
        case .notConfigured:
            return "Not set"
        case .checking:
            return "Checking…"
        case .connected:
            return "Configured"
        case .warning:
            return "Attention"
        case .disconnected:
            return "Disconnected"
        }
    }

    private func genericConnectionRow(_ connection: BridgeConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: connection.status.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor(connection.status))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(connection.provider.displayName)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(connection.name)
                            .font(.callout)
                    }
                    HStack(spacing: 6) {
                        Text(connection.authType.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let maskedCredential = connection.maskedCredential {
                            Text("·")
                                .foregroundStyle(.quaternary)
                            Text(maskedCredential)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Spacer()
                Text(connection.status.label)
                    .font(.caption2)
                    .foregroundStyle(statusColor(connection.status))
            }

            if let summary = connection.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validatedAt = connection.lastValidatedAt, !validatedAt.isEmpty {
                Text("Last checked: \(validatedAt)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !connection.capabilities.isEmpty {
                Text(connection.capabilities.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func reloadConnections() async {
        isLoading = true
        saveError = nil
        do {
            let snapshot = try await ConnectionRegistry.shared.listConnections(kind: .api, validateLive: false)
            apiConnections = snapshot.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            isLoading = false
            await refreshStatuses(for: snapshot.map(\.id))
        } catch {
            saveError = error.localizedDescription
            apiConnections = []
            isLoading = false
        }
    }

    private func refreshStatuses(for ids: [String]? = nil) async {
        let targetIds = await MainActor.run {
            ids ?? apiConnections.map(\.id)
        }
        guard !targetIds.isEmpty else { return }

        await MainActor.run { isRefreshing = true }

        let validated = await withTaskGroup(of: BridgeConnection?.self, returning: [BridgeConnection].self) { group in
            for id in targetIds {
                group.addTask {
                    try? await ConnectionRegistry.shared.validateConnection(id: id)
                }
            }

            var results: [BridgeConnection] = []
            for await connection in group {
                if let connection {
                    results.append(connection)
                }
            }
            return results
        }

        await MainActor.run {
            for connection in validated {
                if let index = apiConnections.firstIndex(where: { $0.id == connection.id }) {
                    apiConnections[index] = connection
                }
            }
            apiConnections.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            isRefreshing = false
        }
    }

    private func saveStripeKey() async {
        await MainActor.run {
            isSaving = true
            saveError = nil
            saveSuccessMessage = nil
        }

        do {
            _ = try await ConnectionRegistry.shared.configureStripeAPIKey(apiKey)
            await MainActor.run {
                apiKey = ""
                saveSuccessMessage = "Stripe API key saved. Live validation is running in the background."
                showApiKeyEditor = false
                isSaving = false
            }
            await reloadConnections()
        } catch {
            await MainActor.run {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func statusColor(_ status: BridgeConnectionStatus) -> Color {
        switch status {
        case .connected:
            return .green
        case .warning:
            return .yellow
        case .disconnected:
            return .red
        case .notConfigured:
            return .gray
        case .checking:
            return .orange
        }
    }
}
