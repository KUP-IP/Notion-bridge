// CloudEnvSelfHeal.swift — boot-order self-heal for the bridge-env LaunchAgent race
// TheBridge · App
//
// Root cause (found live via a real restart-and-reconnect failure, 2026-07-02):
// `solutions.kup.bridge-env` is a RunAtLoad LaunchAgent whose entire job is a
// one-shot `launchctl setenv ...` for BRIDGE_ENABLE_HTTP + the WorkOS/cloud
// vars — env a freshly-spawned process only inherits if that job has already
// run. On some restarts macOS relaunches The Bridge (login item / window
// Resume) before bridge-env's LaunchAgent fires, so Bridge spawns with none
// of its cloud env, `ServerManager.setup()`'s `connectorAuth` stays `nil` for
// that process's entire lifetime (gated on `BRIDGE_ENABLE_HTTP`), and every
// real bearer token a connector (ChatGPT, Claude.ai) presents is rejected as
// structurally invalid — there is no issuer/JWKS to validate against — which
// surfaces to the user as a confusing "reconnect" error with no path back to
// the actual cause. Confirmed live: `launchctl getenv WORKOS_CLIENT_ID`
// returned empty after a restart even though the plist is valid and enabled;
// manually bootstrapping it fixed the session immediately.
//
// This module detects that exact signature at launch and self-heals: kick
// the LaunchAgent (idempotent — safe even if it already ran), relaunch once,
// done. A one-shot marker argument prevents a relaunch loop if the
// LaunchAgent itself is missing or broken — in that case cloud access is
// simply unavailable this session, same as today, but without a raw looping
// process.

import Foundation
import AppKit

public enum CloudEnvSelfHeal {
    /// Passed to the relaunched process so it never attempts a second repair.
    public static let relaunchMarkerArg = "--cloud-env-selfheal-attempted"

    /// True when THIS process was itself spawned by a self-heal relaunch —
    /// read once at call time, not cached, so tests can drive it via an
    /// explicit argument list.
    public static func wasRelaunchedBySelfHeal(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(relaunchMarkerArg)
    }

    /// Pure decision — no side effects, fully unit-testable.
    /// - cloudAccessEnabled: `BridgeDefaults.cloudAccessEnabledValue`. Only
    ///   users who have actually turned on Remote Access are affected; a
    ///   default (cloud-off) install never needs this env and must never be
    ///   relaunched over it.
    /// - environment: the process's own environment (`ProcessInfo.environment`
    ///   in production; injectable for tests).
    /// - alreadyAttempted: `wasRelaunchedBySelfHeal()` — the loop guard.
    public static func shouldAttemptRepair(
        cloudAccessEnabled: Bool,
        environment: [String: String],
        alreadyAttempted: Bool
    ) -> Bool {
        guard cloudAccessEnabled, !alreadyAttempted else { return false }
        // BRIDGE_ENABLE_HTTP is the single canary: it's the first thing
        // ServerManager.setup() gates connectorAuth on, and bridge-env sets
        // it in the same setenv call as every other cloud var — if it's
        // missing, none of the others made it through either.
        return environment["BRIDGE_ENABLE_HTTP"] == nil
    }

    /// Side-effecting repair. Kicks the LaunchAgent (idempotent — a fresh
    /// `bootstrap` on an already-loaded job is a harmless no-op/re-load),
    /// schedules a relaunch DETACHED from this process's lifetime (a
    /// `kill -0`-polling loop + `open`, shelled out and not waited on) so it
    /// survives this process's termination, waits for OUR pid to actually
    /// disappear before launching the new instance, and so never races
    /// `AppDelegate.ensureSingleInstance()` (which checks live
    /// `NSRunningApplication` state), then terminates.
    /// All three steps are injectable so this is testable without touching
    /// launchd, NSWorkspace, or NSApplication. `@MainActor` because the real
    /// `terminate` default touches `NSApplication.shared`; the only
    /// production call site (`AppDelegate.applicationDidFinishLaunching`) is
    /// itself MainActor-isolated already.
    @MainActor
    public static func attemptRepairAndRelaunch(
        launchAgentPlist: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/solutions.kup.bridge-env.plist"),
        bootstrap: (URL) -> Void = { plist in
            guard FileManager.default.fileExists(atPath: plist.path) else {
                print("[CloudEnvSelfHeal] bridge-env plist not found at \(plist.path) — nothing to kick, proceeding to relaunch anyway (env may still be set by the time the new process spawns)")
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "gui/\(getuid())", plist.path]
            do {
                try process.run()
                process.waitUntilExit()
                print("[CloudEnvSelfHeal] bootstrap \(plist.lastPathComponent) exit=\(process.terminationStatus)")
            } catch {
                print("[CloudEnvSelfHeal] bootstrap failed: \(error)")
            }
        },
        scheduleDetachedRelaunch: () -> Void = {
            // Poll for OUR OWN pid to actually exit rather than guessing a
            // fixed delay: `applicationDidFinishLaunching` runs before this
            // process's real teardown work (server listener, SQLite WAL,
            // observers) has a chance to happen, so termination duration
            // isn't guaranteed short. A fixed sleep that's too short would
            // let the new instance's ensureSingleInstance() see US still
            // registered with NSRunningApplication and immediately self-exit
            // — leaving NOTHING running, strictly worse than the original
            // bug. 10s cap so a wedged shutdown can't hang the relaunch
            // forever; falls through to launching anyway past the cap.
            let myPID = ProcessInfo.processInfo.processIdentifier
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "for i in $(seq 1 50); do kill -0 \(myPID) 2>/dev/null || break; sleep 0.2; done; /usr/bin/open -a 'The Bridge' --args \(relaunchMarkerArg)"
            ]
            try? process.run()
            // Deliberately not waiting — this must outlive our own process.
        },
        terminate: () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        print("[CloudEnvSelfHeal] BRIDGE_ENABLE_HTTP missing at launch with cloud access enabled — repairing bridge-env and relaunching once")
        bootstrap(launchAgentPlist)
        scheduleDetachedRelaunch()
        terminate()
    }
}
