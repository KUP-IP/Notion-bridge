// JobsView.swift — Settings > Jobs panel (v1.10.0)
// NotionBridge · UI
//
// Restored sidebar section after v1.8.5 audit removal. Adds:
//  • status dots + cron human-preview
//  • Run Now, Duplicate, Delete per row
//  • inline schedule editor with live validation
//  • action-chain JSON editor
//  • skip_on_battery toggle
//  • Copy ID, Reveal Log
//  • search + sort toolbar
//  • Pause All / Resume All kill-switches
//  • Export / Import JSON
//
// All mutations call JobsManager actor methods directly (no MCP round-trip from UI).

import SwiftUI
import AppKit

// MARK: - Root view

public struct JobsView: View {
    @State private var jobs: [JobRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedJobId: String?
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .nameAsc
    @State private var showImportSheet = false
    @State private var importJSONText = ""
    @State private var bulkInProgress = false
    @State private var bulkMessage: String?

    enum SortOption: String, CaseIterable, Identifiable {
        case nameAsc = "Name (A–Z)"
        case nameDesc = "Name (Z–A)"
        case updatedDesc = "Recently updated"
        case statusActive = "Active first"
        var id: String { rawValue }
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            toolbar
            Divider()
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await reload() }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(jsonText: $importJSONText, onCancel: {
                showImportSheet = false
                importJSONText = ""
            }, onImport: { text in
                Task {
                    await doImport(json: text)
                    showImportSheet = false
                    importJSONText = ""
                }
            })
        }
    }

    // MARK: Subviews

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scheduled Jobs").font(.title2.bold())
                Text("Background automations triggered by launchd. Every job is a cron schedule + action chain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let msg = bulkMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search jobs", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 180)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))

            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)

            Spacer()

            Button {
                Task { await pauseAll() }
            } label: {
                Label("Pause All", systemImage: "pause.circle")
            }
            .disabled(bulkInProgress || jobs.filter { $0.status == .active }.isEmpty)

            Button {
                Task { await resumeAll() }
            } label: {
                Label("Resume All", systemImage: "play.circle")
            }
            .disabled(bulkInProgress || jobs.filter { $0.status == .paused }.isEmpty)

            Button {
                Task { await exportAll() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(jobs.isEmpty)

            Button {
                showImportSheet = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading jobs…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(err).font(.callout).foregroundStyle(.secondary)
                Button("Retry") { Task { await reload() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredJobs.isEmpty {
            emptyState
        } else {
            HSplitView {
                jobsList.frame(minWidth: 280, idealWidth: 320)
                if let id = selectedJobId, let job = jobs.first(where: { $0.id == id }) {
                    JobDetailView(
                        job: job,
                        onChanged: { Task { await reload() } }
                    )
                    .frame(minWidth: 320)
                } else {
                    Text("Select a job")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("No scheduled jobs yet").font(.headline)
            Text("Create one with the `job_create` tool, or import a job export file.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Import…") { showImportSheet = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var jobsList: some View {
        List(selection: $selectedJobId) {
            ForEach(filteredJobs, id: \.id) { job in
                JobRow(job: job).tag(job.id)
            }
        }
        .listStyle(.inset)
    }

    // MARK: Derived

    private var filteredJobs: [JobRecord] {
        let base: [JobRecord]
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            base = jobs
        } else {
            let q = searchText.lowercased()
            base = jobs.filter {
                $0.name.lowercased().contains(q) ||
                $0.schedule.lowercased().contains(q) ||
                $0.id.lowercased().contains(q)
            }
        }
        switch sortOption {
        case .nameAsc: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .updatedDesc: return base.sorted { $0.updatedAt > $1.updatedAt }
        case .statusActive: return base.sorted {
            ($0.status == .active ? 0 : 1, $0.name) < ($1.status == .active ? 0 : 1, $1.name)
        }
        }
    }

    // MARK: Actions

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await JobStore.shared.listAll(statusFilter: nil)
            await MainActor.run {
                self.jobs = all
                self.errorMessage = nil
                if let sel = self.selectedJobId, !all.contains(where: { $0.id == sel }) {
                    self.selectedJobId = nil
                }
            }
        } catch {
            await MainActor.run { self.errorMessage = "\(error)" }
        }
    }

    private func pauseAll() async {
        bulkInProgress = true; defer { bulkInProgress = false }
        do {
            _ = try await JobsManager.shared.pauseAllTool(args: .object([:]))
            await reload()
            await MainActor.run { bulkMessage = "Paused all active jobs." }
        } catch {
            await MainActor.run { bulkMessage = "Pause all failed: \(error)" }
        }
    }

    private func resumeAll() async {
        bulkInProgress = true; defer { bulkInProgress = false }
        do {
            _ = try await JobsManager.shared.resumeAllTool(args: .object([:]))
            await reload()
            await MainActor.run { bulkMessage = "Resumed all paused jobs." }
        } catch {
            await MainActor.run { bulkMessage = "Resume all failed: \(error)" }
        }
    }

    private func exportAll() async {
        do {
            let result = try await JobsManager.shared.exportJobsTool(args: .object([:]))
            guard case .object(let o) = result, case .string(let json)? = o["json"] else { return }
            let panel = NSSavePanel()
            panel.title = "Export Jobs"
            panel.nameFieldStringValue = "notion-bridge-jobs.json"
            panel.allowedContentTypes = [.json]
            if panel.runModal() == .OK, let url = panel.url {
                try json.data(using: .utf8)?.write(to: url)
                await MainActor.run { bulkMessage = "Exported \(self.jobs.count) jobs." }
            }
        } catch {
            await MainActor.run { bulkMessage = "Export failed: \(error)" }
        }
    }

    private func doImport(json: String) async {
        do {
            _ = try await JobsManager.shared.importJobsTool(args: .object(["json": .string(json)]))
            await reload()
            await MainActor.run { bulkMessage = "Import complete." }
        } catch {
            await MainActor.run { bulkMessage = "Import failed: \(error)" }
        }
    }
}

// MARK: - JobRow

private struct JobRow: View {
    let job: JobRecord

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(job.status == .active ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.body).lineLimit(1)
                HStack(spacing: 6) {
                    Text(job.schedule).font(.caption.monospaced())
                    Text("•").font(.caption).foregroundStyle(.tertiary)
                    Text((CronHumanizer.describe(job.schedule) ?? job.schedule)).font(.caption)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text("\(job.actionChain.count) step\(job.actionChain.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - JobDetailView

private struct JobDetailView: View {
    let job: JobRecord
    let onChanged: () -> Void

    @State private var editedName: String
    @State private var editedSchedule: String
    @State private var editedSkipBattery: Bool
    @State private var editedActionsJSON: String
    @State private var scheduleError: String?
    @State private var actionsError: String?
    @State private var saveMessage: String?
    @State private var running = false

    init(job: JobRecord, onChanged: @escaping () -> Void) {
        self.job = job
        self.onChanged = onChanged
        _editedName = State(initialValue: job.name)
        _editedSchedule = State(initialValue: job.schedule)
        _editedSkipBattery = State(initialValue: job.skipOnBattery)
        _editedActionsJSON = State(initialValue: JobDetailView.prettyPrint(job.actionChain))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerBlock
                Divider()
                scheduleBlock
                Divider()
                actionsBlock
                Divider()
                optionsBlock
                Divider()
                footerActions
                if let msg = saveMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Job name", text: $editedName).textFieldStyle(.roundedBorder)
                Circle()
                    .fill(job.status == .active ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(job.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label(job.id, systemImage: "number")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.id, forType: .string)
                    saveMessage = "Copied job id."
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy job id")

                Button {
                    revealLog()
                } label: { Label("Reveal Log", systemImage: "doc.text.magnifyingglass") }
                .buttonStyle(.borderless)
            }
        }
    }

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Schedule").font(.headline)
            TextField("* * * * *", text: $editedSchedule)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onChange(of: editedSchedule) { _, newValue in
                    validateSchedule(newValue)
                }
            if let err = scheduleError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text((CronHumanizer.describe(editedSchedule) ?? editedSchedule)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Action Chain").font(.headline)
                Spacer()
                Text("JSON").font(.caption).foregroundStyle(.tertiary)
            }
            TextEditor(text: $editedActionsJSON)
                .font(.body.monospaced())
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: editedActionsJSON) { _, newValue in
                    validateActions(newValue)
                }
            if let err = actionsError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Skip when on battery", isOn: $editedSkipBattery)
            Text("launchd will defer the job if the Mac is running on battery power.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await runNow() }
            } label: { Label("Run Now", systemImage: "play.fill") }
            .disabled(running)

            Button {
                Task { await duplicate() }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }

            if job.status == .active {
                Button {
                    Task { await pause() }
                } label: { Label("Pause", systemImage: "pause.fill") }
            } else {
                Button {
                    Task { await resume() }
                } label: { Label("Resume", systemImage: "play.fill") }
            }

            Spacer()

            Button(role: .destructive) {
                Task { await delete() }
            } label: { Label("Delete", systemImage: "trash") }

            Button {
                Task { await saveChanges() }
            } label: { Label("Save Changes", systemImage: "checkmark.circle.fill") }
            .keyboardShortcut(.defaultAction)
            .disabled(scheduleError != nil || actionsError != nil || !hasChanges)
        }
    }

    private var hasChanges: Bool {
        editedName != job.name ||
        editedSchedule != job.schedule ||
        editedSkipBattery != job.skipOnBattery ||
        editedActionsJSON != JobDetailView.prettyPrint(job.actionChain)
    }

    // MARK: Validation

    private func validateSchedule(_ s: String) {
        do {
            _ = try CronParser.parse(s)
            scheduleError = nil
        } catch {
            scheduleError = "\(error)"
        }
    }

    private func validateActions(_ s: String) {
        guard let data = s.data(using: .utf8) else {
            actionsError = "Invalid UTF-8"
            return
        }
        do {
            _ = try JSONDecoder().decode([ActionStep].self, from: data)
            actionsError = nil
        } catch {
            actionsError = "Parse error: \(error.localizedDescription)"
        }
    }

    // MARK: Mutations

    private func saveChanges() async {
        guard let actionsData = editedActionsJSON.data(using: .utf8) else { return }
        let parsed: [ActionStep]
        do {
            parsed = try JSONDecoder().decode([ActionStep].self, from: actionsData)
        } catch {
            await MainActor.run { actionsError = "\(error)" }
            return
        }
        // Re-encode as MCP Value array for the update tool.
        var mcpActions: [MCP.Value] = []
        for step in parsed {
            var argsObj: [String: MCP.Value] = [:]
            for (k, v) in step.arguments { argsObj[k] = JSONValue.toMCP(v) }
            mcpActions.append(.object([
                "tool": .string(step.tool),
                "arguments": .object(argsObj),
                "onFail": .string(step.onFail.rawValue)
            ]))
        }
        let payload: MCP.Value = .object([
            "id": .string(job.id),
            "name": .string(editedName),
            "schedule": .string(editedSchedule),
            "actions": .array(mcpActions),
            "skipOnBattery": .bool(editedSkipBattery)
        ])
        do {
            _ = try await JobsManager.shared.updateJobTool(args: payload)
            await MainActor.run { saveMessage = "Saved." }
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Save failed: \(error)" }
        }
    }

    private func runNow() async {
        running = true; defer { running = false }
        do {
            _ = try await JobsManager.shared.runNowTool(args: .object(["id": .string(job.id)]))
            await MainActor.run { saveMessage = "Run triggered." }
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Run failed: \(error)" }
        }
    }

    private func duplicate() async {
        do {
            _ = try await JobsManager.shared.duplicateJobTool(args: .object(["id": .string(job.id)]))
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Duplicate failed: \(error)" }
        }
    }

    private func pause() async {
        do {
            _ = try await JobsManager.shared.pauseJob(args: .object(["id": .string(job.id)]))
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Pause failed: \(error)" }
        }
    }

    private func resume() async {
        do {
            _ = try await JobsManager.shared.resumeJob(args: .object(["id": .string(job.id)]))
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Resume failed: \(error)" }
        }
    }

    private func delete() async {
        do {
            _ = try await JobsManager.shared.deleteJob(args: .object(["id": .string(job.id)]))
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Delete failed: \(error)" }
        }
    }

    private func revealLog() {
        let logsDir = ("~/Library/Logs/NotionBridge/jobs" as NSString).expandingTildeInPath
        let outLog = "\(logsDir)/\(job.id).out.log"
        let url = URL(fileURLWithPath: outLog)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: JSON helpers

    static func prettyPrint(_ chain: [ActionStep]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(chain), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[]"
    }
}

// MARK: - Import sheet

private struct ImportSheet: View {
    @Binding var jsonText: String
    var onCancel: () -> Void
    var onImport: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Jobs").font(.title2.bold())
            Text("Paste a jobs export JSON envelope. IDs will be regenerated to avoid collisions.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $jsonText)
                .font(.body.monospaced())
                .frame(minWidth: 500, minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Load from File…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url, let s = try? String(contentsOf: url) {
                        jsonText = s
                    }
                }
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Import") { onImport(jsonText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(jsonText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - JSONValue ↔ MCP.Value bridge (read-only helpers for UI)

import MCP

extension JSONValue {
    static func toMCP(_ v: JSONValue) -> MCP.Value {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(Int(i))
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let arr): return .array(arr.map { toMCP($0) })
        case .object(let o):
            var out: [String: MCP.Value] = [:]
            for (k, vv) in o { out[k] = toMCP(vv) }
            return .object(out)
        }
    }
}
