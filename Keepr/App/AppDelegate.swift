// AppDelegate.swift — App Lifecycle + MCP Server + SMAppService Auto-Launch
// Notion Bridge v1: Unified binary — starts MCP server on launch, stops on quit
// PKT-317: Merged KeeprServer runtime into KeeprApp via ServerManager
// PKT-318: Added SSE transport startup on :9700
// PKT-329: SSE port now configurable via NOTION_BRIDGE_PORT env var

import AppKit
import ServiceManagement

/// Manages app lifecycle, auto-launch registration, and MCP server lifecycle.
/// The server starts in a detached Task on launch (Nudge Server pattern) so the
/// SwiftUI main thread is never blocked. StatusBarController receives live updates
/// for connections, tool calls, and uptime.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var serverTask: Task<Void, Never>?
    private var serverManager: ServerManager?

    /// Observable state for the DashboardView popover.
    /// Owned here so it's available before the first SwiftUI render.
    public let statusBar = StatusBarController()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        registerAutoLaunch()
        startMCPServer()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        print("[Notion Bridge] Shutting down MCP server...")
        serverTask?.cancel()
        serverTask = nil
        if let manager = serverManager {
            Task { await manager.stopSSE() }
        }
        statusBar.markServerStopped()
        print("[Notion Bridge] Server stopped.")
    }

    // MARK: - MCP Server

    private func startMCPServer() {
        let statusBar = self.statusBar
        let manager = ServerManager(onToolCall: {
            statusBar.incrementToolCalls()
        })
        self.serverManager = manager

        serverTask = Task.detached {
            let toolCount = await manager.setup()
            let port = manager.ssePort

            await MainActor.run {
                statusBar.markServerStarted(toolCount: toolCount)
            }
            print("[Notion Bridge] MCP server started with \(toolCount) tools (stdio + SSE :\(port))")

            // Run both transports concurrently
            await withTaskGroup(of: Void.self) { group in
                // stdio transport (existing)
                group.addTask {
                    do {
                        try await manager.run()
                    } catch is CancellationError {
                        print("[Notion Bridge] stdio transport cancelled")
                    } catch {
                        print("[Notion Bridge] stdio error: \(error.localizedDescription)")
                    }
                }

                // SSE transport (configurable port via NOTION_BRIDGE_PORT)
                group.addTask {
                    do {
                        try await manager.runSSE()
                    } catch is CancellationError {
                        print("[SSE] Transport cancelled")
                    } catch {
                        print("[SSE] Transport error: \(error.localizedDescription)")
                    }
                }
            }

            await MainActor.run {
                statusBar.markServerStopped()
            }
        }
    }

    // MARK: - Auto-Launch

    private func registerAutoLaunch() {
        let service = SMAppService.mainApp
        do {
            try service.register()
            print("[Notion Bridge] Auto-launch registered via SMAppService (\(service.status.rawValue))")
        } catch {
            print("[Notion Bridge] SMAppService registration failed: \(error.localizedDescription)")
            print("[Notion Bridge] To enable: System Settings > General > Login Items > toggle Notion Bridge on")
        }
    }
}
