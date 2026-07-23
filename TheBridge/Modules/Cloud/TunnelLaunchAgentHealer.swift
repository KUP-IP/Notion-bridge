// TunnelLaunchAgentHealer.swift — sleep/wake remote-tunnel self-heal
// TheBridge · Modules · Cloud
//
// Laptop sleep drops Cloudflare edge sockets for the operator's LaunchAgent
// `cloudflared` (`com.kup.cloudflared-bridge`). Local Bridge `/health` can
// stay fine while ChatGPT connectors fail until the tunnel re-registers and
// the client reconnects. Bridge's wake path historically only healed jobs /
// credentials — not the tunnel agent.
//
// v1 policy (Red Team hardened):
// - ALWAYS one kickstart attempt per eligible wake (do NOT treat launchctl
//   "state=running" as healthy — process can be up with dead edge sockets).
// - Throttle so lid thrash cannot storm kickstart.
// - Skip when heal is disabled, or when the network is clearly unavailable.
// - Target the LaunchAgent label (configurable); do not use FakeTunnelProcess.
// - Residual: ChatGPT may still need one plugin reconnect after the edge is up.
//
// Production kick: `/bin/launchctl kickstart -k gui/<uid>/<label>`.

import Foundation
import SystemConfiguration

public enum TunnelLaunchAgentHealer: Sendable {

    /// Default LaunchAgent label for Isaiah's install (and docs).
    public static let defaultLabel = "com.kup.cloudflared-bridge"

    /// Minimum seconds between kickstarts (lid open/close thrash).
    public static let defaultThrottleSeconds: TimeInterval = 90

    /// Delay after `didWake` before kick — let networking stack come up.
    public static let defaultPostWakeDelayNanoseconds: UInt64 = 3_000_000_000

    public enum Decision: String, Equatable, Sendable {
        case kick
        case skippedDisabled
        case skippedThrottled
        case skippedNoNetwork
    }

    public enum Outcome: Equatable, Sendable {
        case kicked
        case skippedDisabled
        case skippedThrottled
        case skippedNoNetwork
        case failed(String)
    }

    public enum HealError: Error, Equatable, Sendable {
        case kickstartFailed(status: Int32, domain: String)
    }

    // MARK: - Pure decision (hermetic)

    /// Pure policy — no launchd, no network, fully unit-testable.
    ///
    /// - enabled: operator master for wake heal (default ON).
    /// - networkAvailable: false ⇒ skip (airplane / offline wake).
    /// - lastKickAt + throttleSeconds: prevent kick storms.
    ///
    /// When eligible, always returns `.kick` (Red Team: no "agent running ⇒ healthy").
    public static func decide(
        enabled: Bool,
        networkAvailable: Bool,
        now: Date,
        lastKickAt: Date?,
        throttleSeconds: TimeInterval
    ) -> Decision {
        guard enabled else { return .skippedDisabled }
        guard networkAvailable else { return .skippedNoNetwork }
        if let lastKickAt, now.timeIntervalSince(lastKickAt) < throttleSeconds {
            return .skippedThrottled
        }
        return .kick
    }

    public static func launchctlDomain(uid: uid_t = getuid(), label: String) -> String {
        "gui/\(uid)/\(label)"
    }

    // MARK: - Side-effecting heal (injectable)

    /// Run wake heal. Defaults read BridgeDefaults; all effects injectable for tests.
    @discardableResult
    public static func handleWake(
        enabled: Bool = BridgeDefaults.tunnelWakeHealEnabledValue,
        networkAvailable: Bool = liveNetworkAvailable(),
        now: Date = Date(),
        lastKickAt: Date? = BridgeDefaults.tunnelWakeHealLastKickAt,
        throttleSeconds: TimeInterval = BridgeDefaults.tunnelWakeHealThrottleSecondsValue,
        label: String = BridgeDefaults.tunnelLaunchAgentLabelValue,
        recordKick: (Date) -> Void = { BridgeDefaults.recordTunnelWakeHealKick(at: $0) },
        kickstart: (String) throws -> Void = { try liveKickstart(label: $0) },
        log: (String) -> Void = { print($0) }
    ) -> Outcome {
        let decision = decide(
            enabled: enabled,
            networkAvailable: networkAvailable,
            now: now,
            lastKickAt: lastKickAt,
            throttleSeconds: throttleSeconds
        )
        switch decision {
        case .skippedDisabled:
            log("[TunnelLaunchAgentHealer] wake tunnel heal: skipped_disabled")
            return .skippedDisabled
        case .skippedThrottled:
            log("[TunnelLaunchAgentHealer] wake tunnel heal: skipped_throttled")
            return .skippedThrottled
        case .skippedNoNetwork:
            log("[TunnelLaunchAgentHealer] wake tunnel heal: skipped_no_network")
            return .skippedNoNetwork
        case .kick:
            do {
                try kickstart(label)
                recordKick(now)
                log("[TunnelLaunchAgentHealer] wake tunnel heal: kicked label=\(label)")
                return .kicked
            } catch {
                let message = (error as? HealError).map { String(describing: $0) }
                    ?? error.localizedDescription
                log("[TunnelLaunchAgentHealer] wake tunnel heal: failed \(message)")
                return .failed(message)
            }
        }
    }

    /// Production launchctl kickstart. Throws if process cannot start or exits non-zero.
    public static func liveKickstart(label: String) throws {
        let domain = launchctlDomain(label: label)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", domain]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw HealError.kickstartFailed(status: -1, domain: domain)
        }
        guard process.terminationStatus == 0 else {
            throw HealError.kickstartFailed(status: process.terminationStatus, domain: domain)
        }
    }

    /// Best-effort IPv4 default-route reachability. On failure to query, returns
    /// `true` so throttle (not a stuck "always offline") governs offline loops.
    public static func liveNetworkAvailable() -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard let reachability = withUnsafePointer(to: &address, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                SCNetworkReachabilityCreateWithAddress(nil, sockPtr)
            }
        }) else {
            return true
        }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else {
            return true
        }
        let reachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        return reachable && !needsConnection
    }
}
