import SwiftUI

public struct APIConnectionsManagementView: View {
    @State private var stripeConnection: BridgeConnection?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var apiKey = ""
    @State private var saveError: String?
    @State private var saveSuccessMessage: String?
    @State private var showApiKeyEditor = false

    public init() {}

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
            } else if let stripeConnection {
                connectionRow(stripeConnection)

                if showApiKeyEditor {
                    SecureField("Paste Stripe secret key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

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

                    HStack {
                        Button("Save") {
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
            } else {
                Text("Stripe connection unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    showApiKeyEditor.toggle()
                    saveError = nil
                    saveSuccessMessage = nil
                } label: {
                    Label(showApiKeyEditor ? "Hide Editor" : "Set API Key", systemImage: "key.horizontal")
                        .font(.callout)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    Task { await loadConnections() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh API connection status")
            }
        }
        .task { await loadConnections() }
    }

    private func connectionRow(_ connection: BridgeConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: connection.status.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor(connection.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.name)
                        .font(.callout)
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

            if !connection.capabilities.isEmpty {
                Text(connection.capabilities.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadConnections() async {
        isLoading = true
        do {
            let connections = try await ConnectionRegistry.shared.listConnections(provider: .stripe, validateLive: true)
            stripeConnection = connections.first
        } catch {
            saveError = error.localizedDescription
        }
        isLoading = false
    }

    private func saveStripeKey() async {
        isSaving = true
        saveError = nil
        saveSuccessMessage = nil

        do {
            stripeConnection = try await ConnectionRegistry.shared.configureStripeAPIKey(apiKey)
            apiKey = ""
            saveSuccessMessage = "Stripe API key saved and validated."
            showApiKeyEditor = false
        } catch {
            saveError = error.localizedDescription
        }

        isSaving = false
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
