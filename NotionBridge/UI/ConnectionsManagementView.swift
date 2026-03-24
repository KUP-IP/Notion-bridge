// ConnectionsManagementView.swift — Workspace Connections Management UI
// NotionBridge · UI
// PKT-368 D1-D6: Health badges, add/remove/rename, detail view, multi-workspace
//
// Self-contained SwiftUI view for managing Notion + Google Drive connections.
// Embedded in SettingsWindow's Connections section.

import SwiftUI

// MARK: - Connection Display Model

/// Unified display model for a workspace connection (Notion or Google Drive).
struct ConnectionItem: Identifiable {
    let id: String
    let name: String
    let type: ConnectionType
    let isPrimary: Bool
    let maskedToken: String
    var health: ConnectionHealth

    enum ConnectionType: String, CaseIterable, Identifiable {
        case notion = "Notion"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .notion:      return "doc.text"
            }
        }
    }
}

// MARK: - Connections Management View

/// D1-D6: Full connection management interface.
/// Shows all configured connections with health badges, supports CRUD operations.
public struct ConnectionsManagementView: View {
    @State private var connections: [ConnectionItem] = []
    @State private var isLoading = true
    @State private var showAddSheet = false
    @State private var showDeleteAlert = false
    @State private var connectionToDelete: ConnectionItem?
    @State private var showRenameAlert = false
    @State private var renameTarget: ConnectionItem?
    @State private var renameText = ""
    @State private var expandedConnectionId: String?
    @State private var showLastConnectionWarning = false
    @State private var showPrimaryBlockedAlert = false
    @State private var primaryBlockedMessage = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading connections…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else if connections.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "network.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No connections configured")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                // D1 + D5: Connection list with health badges
                ForEach(connections) { conn in
                    VStack(spacing: 0) {
                        connectionRow(conn)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedConnectionId = expandedConnectionId == conn.id ? nil : conn.id
                                }
                            }
                            .contextMenu { contextMenu(for: conn) }

                        // D5: Expanded detail view
                        if expandedConnectionId == conn.id {
                            connectionDetail(conn)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if conn.id != connections.last?.id {
                            Divider()
                                .padding(.leading, 24)
                        }
                    }
                }
            }

            // D2: Add Connection + Refresh
            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Connection", systemImage: "plus.circle")
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
                .help("Refresh connection status")
            }
            .padding(.top, 8)
        }
        .task { await loadConnections() }
        .sheet(isPresented: $showAddSheet) {
            AddConnectionSheet {
                Task { await loadConnections() }
            }
        }
        // D3: Delete confirmation with preflight guard
        .alert("Remove Connection", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let conn = connectionToDelete {
                    Task {
                        let preflight = await NotionClientRegistry.shared.preflightRemove(name: conn.name)
                        switch preflight {
                        case .primaryBlocked(let msg):
                            primaryBlockedMessage = msg
                            showPrimaryBlockedAlert = true
                        case .lastConnectionWarning:
                            showLastConnectionWarning = true
                        case .removed:
                            await removeConnection(conn)
                        }
                    }
                }
            }
        } message: {
            if let conn = connectionToDelete {
                Text("Remove \"\(conn.name)\"? The stored token will be deleted.")
            }
        }
        // Primary blocked alert
        .alert("Cannot Delete Primary", isPresented: $showPrimaryBlockedAlert) {
            Button("OK") {}
        } message: {
            Text(primaryBlockedMessage)
        }
        // Last connection warning
        .alert("Delete Last Connection?", isPresented: $showLastConnectionWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Anyway", role: .destructive) {
                if let conn = connectionToDelete {
                    Task {
                        do {
                            try await NotionClientRegistry.shared.removeConnection(name: conn.name)
                        } catch {
                            print("[ConnectionsManagement] Last-connection remove failed: \(error)")
                        }
                        await ConnectionHealthChecker.shared.invalidateAll()
                        await loadConnections()
                    }
                }
            }
        } message: {
            Text("You\u{2019}re about to delete your only connection. Nothing will work until you add a new one. Are you sure?")
        }
        // D4: Rename alert
        .alert("Rename Connection", isPresented: $showRenameAlert) {
            TextField("Connection name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let conn = renameTarget, !renameText.isEmpty {
                    Task { await renameConnection(conn, to: renameText) }
                }
            }
        } message: {
            Text("Enter a new name for this connection.")
        }
    }

    // MARK: - Connection Row (D1)

    private func connectionRow(_ conn: ConnectionItem) -> some View {
        HStack(spacing: 10) {
            // Health badge
            Image(systemName: conn.health.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(healthColor(conn.health))
                .help(conn.health.label)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(conn.name)
                        .font(.callout)
                        .fontWeight(conn.isPrimary ? .semibold : .regular)

                    // D6: Primary indicator (multi-workspace)
                    if conn.isPrimary && conn.type == .notion {
                        Text("PRIMARY")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.12))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: conn.type.icon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(conn.type.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(conn.maskedToken)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Status text
            Text(conn.health.label)
                .font(.caption2)
                .foregroundStyle(healthColor(conn.health))

            // Expand chevron
            Image(systemName: expandedConnectionId == conn.id ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Connection Detail (D5)

    private func connectionDetail(_ conn: ConnectionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Type")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(conn.type.rawValue)
                    .font(.caption)
            }
            HStack {
                Text("Status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Image(systemName: conn.health.systemImage)
                    .font(.caption2)
                    .foregroundStyle(healthColor(conn.health))
                Text(conn.health.label)
                    .font(.caption)
            }
            HStack {
                Text("Token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(conn.maskedToken)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if conn.isPrimary {
                HStack {
                    Text("Role")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Text("Primary workspace — used when no workspace is specified")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Context Menu (D3 + D4)

    @ViewBuilder
    private func contextMenu(for conn: ConnectionItem) -> some View {
        // D4: Rename
        Button {
            renameTarget = conn
            renameText = conn.name
            showRenameAlert = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        // D6: Set as primary
        if conn.type == .notion && !conn.isPrimary {
            Button {
                Task { await setPrimary(conn) }
            } label: {
                Label("Set as Primary", systemImage: "star")
            }
        }

        Divider()

        // D3: Remove
        Button(role: .destructive) {
            connectionToDelete = conn
            showDeleteAlert = true
        } label: {
            Label("Remove Connection", systemImage: "trash")
        }
    }

    // MARK: - Data Loading

    private func loadConnections() async {
        isLoading = true
        var items: [ConnectionItem] = []

        // Load Notion connections from registry
        do {
            let notionConns = try await NotionClientRegistry.shared.listConnections()
            for conn in notionConns {
                let health: ConnectionHealth = conn.status == "connected" ? .healthy : .error
                items.append(ConnectionItem(
                    id: "notion:\(conn.name)",
                    name: conn.name,
                    type: .notion,
                    isPrimary: conn.isPrimary,
                    maskedToken: conn.maskedToken,
                    health: health
                ))
            }
        } catch {
            print("[ConnectionsManagement] Failed to load Notion connections: \(error)")
        }

        connections = items
        isLoading = false
    }

    // MARK: - Actions

    /// D3: Remove a connection with guard logic
    private func removeConnection(_ conn: ConnectionItem) async {
        if conn.type == .notion {
            // Preflight check
            let result = await NotionClientRegistry.shared.preflightRemove(name: conn.name)
            switch result {
            case .primaryBlocked(let message):
                primaryBlockedMessage = message
                showPrimaryBlockedAlert = true
                return
            case .lastConnectionWarning:
                // Show last-connection warning — caller handles via showLastConnectionWarning
                // If we got here from the last-connection confirmation, proceed
                break
            case .removed:
                break
            }

            do {
                try await NotionClientRegistry.shared.removeConnection(name: conn.name)
            } catch {
                print("[ConnectionsManagement] Remove failed: \(error)")
            }
        }
        await ConnectionHealthChecker.shared.invalidateAll()
        await loadConnections()
    }

    /// D4: Rename a connection (Notion only — config name update)
    private func renameConnection(_ conn: ConnectionItem, to newName: String) async {
        if conn.type == .notion {
            do {
                try await NotionClientRegistry.shared.renameConnection(from: conn.name, to: newName)
                await ConnectionHealthChecker.shared.invalidateAll()
            } catch {
                print("[ConnectionsManagement] Rename failed: \(error)")
            }
        }
        await loadConnections()
    }

    /// D6: Set a Notion connection as primary
    private func setPrimary(_ conn: ConnectionItem) async {
        do {
            let registryName = conn.type == .notion ? conn.name : conn.name
            try await NotionClientRegistry.shared.setPrimary(name: registryName)
            await ConnectionHealthChecker.shared.invalidateAll()
            await loadConnections()
        } catch {
            print("[ConnectionsManagement] Set primary failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func healthColor(_ health: ConnectionHealth) -> Color {
        switch health {
        case .healthy:      return .green
        case .warning:      return .yellow
        case .error:        return .red
        case .unconfigured: return .gray
        case .checking:     return .orange
        }
    }

}

// MARK: - Add Connection Sheet (D2)

/// Guided form for adding a new Notion workspace connection.
struct AddConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: () -> Void

    @State private var connectionName = ""
    @State private var token = ""
    @State private var makePrimary = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Connection")
                .font(.headline)

            // Name
            TextField("Connection name (e.g. Work, Personal)", text: $connectionName)
                .textFieldStyle(.roundedBorder)

            // Token
            SecureField("Notion API token (ntn_...)", text: $token)
                .textFieldStyle(.roundedBorder)

            Toggle("Set as primary workspace", isOn: $makePrimary)
                .font(.callout)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Link(destination: URL(string: "https://www.notion.so/profile/integrations")!) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.caption2)
                    Text("Create an internal integration at notion.so")
                        .font(.caption)
                }
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Test & Save") {
                    Task { await saveConnection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(connectionName.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty || isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func saveConnection() async {
        isSaving = true
        errorMessage = nil
        let trimmedName = connectionName.trimmingCharacters(in: .whitespaces)

        do {
            try await NotionClientRegistry.shared.addConnection(
                name: trimmedName,
                token: token,
                primary: makePrimary
            )
            await ConnectionHealthChecker.shared.invalidateAll()
            onComplete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isSaving = false
    }

}
