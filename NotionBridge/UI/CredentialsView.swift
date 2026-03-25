// CredentialsView.swift — Credentials Settings Tab
// PKT-372: Type-grouped credential display (Passwords, Cards)
// PKT-486: Manual credential creation forms (Add Password, Add Card)
// Scope IN D5: "Credentials" tab in SettingsWindow — grouped by type

import SwiftUI

// MARK: - FormFeedback

/// Inline feedback message for credential forms.
private struct FormFeedback {
    let message: String
    let isError: Bool
}

/// Settings tab showing stored credentials grouped by type (Passwords, Cards).
/// Cards display last4 + brand + expiry. All entries support delete.
/// PKT-486: Collapsible forms for adding passwords and cards inline.
struct CredentialsView: View {
    @State private var credentials: [CredentialEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var entryToDelete: (service: String, account: String)?
    @State private var showDeleteConfirmation = false

    // Add Password form state
    @State private var showAddPassword = false
    @State private var pwService = ""
    @State private var pwAccount = ""
    @State private var pwPassword = ""
    @State private var pwSaving = false
    @State private var pwFeedback: FormFeedback?

    // Add Card form state
    @State private var showAddCard = false
    @State private var cardNumber = ""
    @State private var cardExpiry = ""
    @State private var cardCVC = ""
    @State private var cardSaving = false
    @State private var cardFeedback: FormFeedback?

    private let manager = CredentialManager.shared

    private var passwords: [CredentialEntry] {
        credentials.filter { $0.type == .password }
    }

    private var cards: [CredentialEntry] {
        credentials.filter { $0.type == .card }
    }

    var body: some View {
        Form {
            // MARK: Passwords
            Section("Passwords") {
                if passwords.isEmpty && !showAddPassword {
                    Text("No saved passwords")
                        .foregroundStyle(BridgeColors.secondary)
                        .font(.caption)
                } else {
                    ForEach(0..<passwords.count, id: \.self) { idx in
                        passwordRow(passwords[idx])
                    }
                }

                DisclosureGroup("Add Password", isExpanded: $showAddPassword) {
                    addPasswordForm
                }
                .font(.caption)
            }

            // MARK: Cards
            Section("Cards") {
                if cards.isEmpty && !showAddCard {
                    Text("No saved cards")
                        .foregroundStyle(BridgeColors.secondary)
                        .font(.caption)
                } else {
                    ForEach(0..<cards.count, id: \.self) { idx in
                        cardRow(cards[idx])
                    }
                }

                DisclosureGroup("Add Card", isExpanded: $showAddCard) {
                    addCardForm
                }
                .font(.caption)
            }

            // MARK: Footer
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

                Text("Credentials are stored in macOS Keychain with biometric protection. Cards are tokenized via Stripe before storage.")
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

    // MARK: - Add Password Form

    @ViewBuilder
    private var addPasswordForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Service", text: $pwService)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            TextField("Account", text: $pwAccount)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            SecureField("Password", text: $pwPassword)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if let feedback = pwFeedback {
                feedbackLabel(feedback)
            }

            HStack {
                Button("Save Password") {
                    Task { await savePassword() }
                }
                .disabled(pwSaving || pwService.trimmingCharacters(in: .whitespaces).isEmpty
                          || pwAccount.trimmingCharacters(in: .whitespaces).isEmpty
                          || pwPassword.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if pwSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Add Card Form

    @ViewBuilder
    private var addCardForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Card Number", text: $cardNumber)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack(spacing: 8) {
                TextField("MM/YY", text: $cardExpiry)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 80)

                TextField("CVC", text: $cardCVC)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 60)
            }

            if let feedback = cardFeedback {
                feedbackLabel(feedback)
            }

            HStack {
                Button("Save Card") {
                    Task { await saveCard() }
                }
                .disabled(cardSaving || cardNumber.isEmpty
                          || cardExpiry.isEmpty || cardCVC.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if cardSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Feedback Label

    @ViewBuilder
    private func feedbackLabel(_ feedback: FormFeedback) -> some View {
        HStack(spacing: 4) {
            Image(systemName: feedback.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
            Text(feedback.message)
        }
        .font(.caption)
        .foregroundStyle(feedback.isError ? BridgeColors.error : .green)
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

    // MARK: - Save Actions

    private func savePassword() async {
        pwFeedback = nil
        pwSaving = true
        defer { pwSaving = false }

        let service = pwService.trimmingCharacters(in: .whitespaces)
        let account = pwAccount.trimmingCharacters(in: .whitespaces)

        do {
            _ = try await manager.save(
                service: service,
                account: account,
                password: pwPassword,
                type: .password
            )
            pwFeedback = FormFeedback(message: "Password saved.", isError: false)
            pwService = ""
            pwAccount = ""
            pwPassword = ""
            loadCredentials()
        } catch {
            pwFeedback = FormFeedback(message: error.localizedDescription, isError: true)
        }
    }

    private func saveCard() async {
        cardFeedback = nil

        // Strip spaces/dashes from card number
        let cleanNumber = cardNumber
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        // Validate card number via Luhn
        guard luhnCheck(cleanNumber) else {
            cardFeedback = FormFeedback(message: "Invalid card number.", isError: true)
            return
        }

        // Parse and validate expiry (MM/YY)
        guard let (expMonth, expYear) = parseExpiry(cardExpiry) else {
            cardFeedback = FormFeedback(message: "Invalid expiry. Use MM/YY.", isError: true)
            return
        }
        guard !isExpiryPast(month: expMonth, year: expYear) else {
            cardFeedback = FormFeedback(message: "Card is expired.", isError: true)
            return
        }

        // Validate CVC (3–4 digits)
        let cleanCVC = cardCVC.filter { $0.isNumber }
        guard cleanCVC.count >= 3, cleanCVC.count <= 4 else {
            cardFeedback = FormFeedback(message: "CVC must be 3 or 4 digits.", isError: true)
            return
        }

        cardSaving = true
        defer { cardSaving = false }

        let metadata = CredentialMetadata(expMonth: expMonth, expYear: expYear)

        do {
            // CredentialManager.save() handles Stripe tokenization internally
            // for .card type — raw card number is never stored in Keychain.
            _ = try await manager.save(
                service: "card",
                account: "card-\(cleanNumber.suffix(4))",
                password: cleanNumber,
                type: .card,
                metadata: metadata
            )
            cardFeedback = FormFeedback(message: "Card saved and tokenized.", isError: false)
            cardNumber = ""
            cardExpiry = ""
            cardCVC = ""
            loadCredentials()
        } catch {
            cardFeedback = FormFeedback(message: error.localizedDescription, isError: true)
        }
    }

    // MARK: - Validation Helpers

    /// Luhn algorithm check for card number validity.
    private func luhnCheck(_ number: String) -> Bool {
        guard number.count >= 13, number.count <= 19,
              number.allSatisfy({ $0.isNumber }) else { return false }
        var sum = 0
        let reversed = Array(number.reversed())
        for (i, ch) in reversed.enumerated() {
            guard let digit = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Parse "MM/YY" string into (month, four-digit year).
    private func parseExpiry(_ raw: String) -> (Int, Int)? {
        let parts = raw.split(separator: "/")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let shortYear = Int(parts[1]),
              (1...12).contains(month) else { return nil }
        let year = shortYear < 100 ? 2000 + shortYear : shortYear
        return (month, year)
    }

    /// Returns true if the given month/year is in the past.
    private func isExpiryPast(month: Int, year: Int) -> Bool {
        let cal = Calendar.current
        let now = Date()
        let currentMonth = cal.component(.month, from: now)
        let currentYear = cal.component(.year, from: now)
        if year < currentYear { return true }
        if year == currentYear && month < currentMonth { return true }
        return false
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
