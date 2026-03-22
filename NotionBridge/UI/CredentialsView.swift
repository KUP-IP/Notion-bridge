// CredentialsView.swift — Credentials Settings Tab
// PKT-372: Type-grouped credential display (Passwords, Cards)
// Scope IN D5: "Credentials" tab in SettingsWindow — grouped by type

import SwiftUI

/// Settings tab showing stored credentials grouped by type (Passwords, Cards).
/// Cards display last4 + brand + expiry. All entries support delete.
struct CredentialsView: View {
    @State private var credentials: [CredentialEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var entryToDelete: (service: String, account: String)?
    @State private var showDeleteConfirmation = false

    private let manager = CredentialManager.shared

    private var passwords: [CredentialEntry] {
        credentials.filter { $0.type == .password }
    }

    private var cards: [CredentialEntry] {
        credentials.filter { $0.type == .card }
    }

    var body: some View {
        Form {
            Section("Passwords") {
                if passwords.isEmpty {
                    Text("No saved passwords")
                        .foregroundStyle(BridgeColors.secondary)
                        .font(.caption)
                } else {
                    ForEach(0..<passwords.count, id: \.self) { idx in
                        passwordRow(passwords[idx])
                    }
                }
            }

            Section("Cards") {
                if cards.isEmpty {
                    Text("No saved cards")
                        .foregroundStyle(BridgeColors.secondary)
                        .font(.caption)
                } else {
                    ForEach(0..<cards.count, id: \.self) { idx in
                        cardRow(cards[idx])
                    }
                }
            }

            Section {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.error)
                }

                HStack {
                    Button("Refresh") {
                        loadCredentials()
                    }
                    .font(.caption)

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text("Credentials are stored in macOS Keychain using kSecClassGenericPassword. Manage credentials via MCP tools (credential_save, credential_read, credential_delete).")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
            }
        }
        .formStyle(.grouped)
        .task {
            loadCredentials()
        }
        .confirmationDialog(
            "Delete Credential?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = entryToDelete {
                    Task { await deleteCredential(service: target.service, account: target.account) }
                }
            }
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
        } message: {
            if let target = entryToDelete {
                Text("Delete \"\(target.service) / \(target.account)\"? This cannot be undone.")
            }
        }
    }

    // MARK: - Row Views

    @ViewBuilder
    private func passwordRow(_ entry: CredentialEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.service)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text(entry.account)
                    .font(.caption)
                    .foregroundStyle(BridgeColors.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(role: .destructive) {
                entryToDelete = (service: entry.service, account: entry.account)
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func cardRow(_ entry: CredentialEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BridgeSpacing.xs) {
                    if let brand = entry.metadata.brand {
                        Text(brand.uppercased())
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    if let last4 = entry.metadata.last4 {
                        Text("•••• \(last4)")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                HStack(spacing: BridgeSpacing.xs) {
                    Text(entry.account)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                        .lineLimit(1)
                    if let expMonth = entry.metadata.expMonth,
                       let expYear = entry.metadata.expYear {
                        Text("Exp \(String(format: "%02d", expMonth))/\(expYear)")
                            .font(.caption)
                            .foregroundStyle(BridgeColors.muted)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                entryToDelete = (service: entry.service, account: entry.account)
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Data Loading

    private func loadCredentials() {
        isLoading = true
        errorMessage = nil
        do {
            credentials = try manager.list()
            isLoading = false
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func deleteCredential(service: String, account: String) async {
        do {
            _ = try await manager.deleteCredential(service: service, account: account)
            loadCredentials()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
        entryToDelete = nil
    }
}
