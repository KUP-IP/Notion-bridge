// JobsView.swift — Settings sidebar section for scheduled jobs (PKT-340 · Wave 4)
// NotionBridge · UI
//
// Provides:
//   • Refreshable list of all jobs (active + paused)
//   • Detail pane with schedule, action-chain summary, and recent executions
//   • Pause / Resume / Delete controls (Delete confirms via NSAlert)
//
// Pattern reference: SkillsView.swift (NavigationSplitView sidebar item).

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct JobsView: View {
    public init() {}

    @State private var jobs: [JobRecord] = []
    @State private var selectedJobId: String?
    @State private var history: [ExecutionRecord] = []
    @State private var loadError: String?
    @State private var isLoading = false

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await reload() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Scheduled Jobs", systemImage: "clock.badge.checkmark")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(16)
            } else if jobs.isEmpty && !isLoading {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No scheduled jobs yet.")
                        .foregroundStyle(.secondary)
                    Text("Use the job_create tool from an MCP client to schedule your first job.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            } else {
                List(selection: $selectedJobId) {
                    ForEach(jobs, id: \.id) { job in
                        JobRow(job: job)
                            .tag(job.id as String?)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedJobId) { _, _ in
                    Task { await loadHistory() }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedJobId, let job = jobs.first(where: { $0.id == id }) {
            JobDetailView(
                job: job,
                history: history,
                onPause: { await pause(id: job.id) },
                onResume: { await resume(id: job.id) },
                onDelete: { await confirmAndDelete(job) }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Select a job to see its schedule and history.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Data

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            await JobsManager.shared.bootstrap()
            let list = try await JobStore.shared.listAll()
            self.jobs = list
            self.loadError = nil
            if let id = selectedJobId, list.contains(where: { $0.id == id }) {
                await loadHistory()
            } else {
                self.selectedJobId = list.first?.id
                await loadHistory()
            }
        } catch {
            self.loadError = "\(error)"
        }
    }

    @MainActor
    private func loadHistory() async {
        guard let id = selectedJobId else { self.history = []; return }
        do {
            self.history = try await JobStore.shared.executions(jobId: id, limit: 20)
        } catch {
            self.history = []
        }
    }

    @MainActor
    private func pause(id: String) async {
        _ = try? await JobsManager.shared.pauseJob(args: .object(["id": .string(id)]))
        await reload()
    }

    @MainActor
    private func resume(id: String) async {
        _ = try? await JobsManager.shared.resumeJob(args: .object(["id": .string(id)]))
        await reload()
    }

    @MainActor
    private func confirmAndDelete(_ job: JobRecord) async {
        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = "Delete job '\(job.name)'?"
        alert.informativeText = "This removes the LaunchAgent plist and the job record. Execution history will also be deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        #endif
        _ = try? await JobsManager.shared.deleteJob(args: .object(["id": .string(job.id)]))
        await reload()
    }
}

private struct JobRow: View {
    let job: JobRecord

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(job.status == .active ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.body)
                    .lineLimit(1)
                Text(job.schedule)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if job.status == .paused {
                Text("paused")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

private struct JobDetailView: View {
    let job: JobRecord
    let history: [ExecutionRecord]
    let onPause: () async -> Void
    let onResume: () async -> Void
    let onDelete: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name)
                            .font(.title2.weight(.semibold))
                        Text("Schedule: \(job.schedule)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if job.status == .active {
                        Button("Pause") { Task { await onPause() } }
                    } else {
                        Button("Resume") { Task { await onResume() } }
                    }
                    Button(role: .destructive) {
                        Task { await onDelete() }
                    } label: { Text("Delete") }
                }

                GroupBox(label: Text("Action chain").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(job.actionChain.enumerated()), id: \.offset) { idx, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(idx + 1).")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text(step.tool)
                                    .font(.body.monospaced())
                                Text("on_fail=\(step.onFail.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Recent executions").font(.headline)) {
                    if history.isEmpty {
                        Text("No executions yet.")
                            .foregroundStyle(.secondary)
                            .padding(6)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(history.enumerated()), id: \.offset) { _, exec in
                                HStack(spacing: 8) {
                                    statusBadge(exec.status)
                                    Text(formatted(exec.startedAt))
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                    if let err = exec.errorMessage {
                                        Text(err)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private func statusBadge(_ s: ExecutionRecord.Status) -> some View {
        let color: Color = {
            switch s {
            case .success: return .green
            case .failure: return .red
            case .partial: return .orange
            case .skipped: return .gray
            }
        }()
        return Text(s.rawValue)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private func formatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: d)
    }
}

#Preview {
    JobsView()
        .frame(width: 800, height: 500)
}
