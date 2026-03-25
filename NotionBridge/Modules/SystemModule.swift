// SystemModule.swift – V1-05 System Tools
// NotionBridge · Modules
//
// Three tools: system_info (open), process_list (open), notify (open).
// Uses sw_vers, sysctl, ps, and UserNotifications for macOS integration.

import Foundation
import MCP
import UserNotifications
import Contacts

// MARK: - SystemModule

/// Provides macOS system information, process listing, and notification tools.
public enum SystemModule {

    public static let moduleName = "system"

    /// Register all SystemModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. system_info – open
        await router.register(ToolRegistration(
            name: "system_info",
            module: moduleName,
            tier: .open,
            description: "Get macOS system info. Returns {osVersion, model, cpu, memory, hostname, uptime}. Use for environment diagnostics.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                var info: [String: Value] = [:]

                // OS version via sw_vers
                if let swVers = try? shellOutput("/usr/bin/sw_vers") {
                    let lines = swVers.components(separatedBy: "\n")
                    for line in lines {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2 {
                            let key = parts[0].trimmingCharacters(in: .whitespaces)
                            let val = parts[1].trimmingCharacters(in: .whitespaces)
                            switch key {
                            case "ProductName": info["osName"] = .string(val)
                            case "ProductVersion": info["osVersion"] = .string(val)
                            case "BuildVersion": info["osBuild"] = .string(val)
                            default: break
                            }
                        }
                    }
                }

                // Hostname
                info["hostname"] = .string(ProcessInfo.processInfo.hostName)

                // CPU info via sysctl
                if let cpuBrand = try? shellOutput("/usr/sbin/sysctl", args: ["-n", "machdep.cpu.brand_string"]) {
                    info["cpu"] = .string(cpuBrand.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                // CPU core count
                info["cpuCores"] = .int(ProcessInfo.processInfo.processorCount)
                info["cpuActiveCores"] = .int(ProcessInfo.processInfo.activeProcessorCount)

                // Physical memory
                let memBytes = ProcessInfo.processInfo.physicalMemory
                let memGB = Double(memBytes) / (1024 * 1024 * 1024)
                info["memoryGB"] = .double((memGB * 100).rounded() / 100)

                // System uptime
                let uptime = ProcessInfo.processInfo.systemUptime
                let days = Int(uptime) / 86400
                let hours = (Int(uptime) % 86400) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                info["uptime"] = .string("\(days)d \(hours)h \(minutes)m")
                info["uptimeSeconds"] = .double(uptime)

                // Hardware model via sysctl
                if let model = try? shellOutput("/usr/sbin/sysctl", args: ["-n", "hw.model"]) {
                    info["hardwareModel"] = .string(model.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                return .object(info)
            }
        ))

        // MARK: 2. process_list – open
        await router.register(ToolRegistration(
            name: "process_list",
            module: moduleName,
            tier: .open,
            description: "List running macOS processes. Returns an array of {pid, name, cpu, mem, user} sorted by sortBy (default: cpu). Use filter for name substring matching.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filter": .object(["type": .string("string"), "description": .string("Optional process name filter (case-insensitive substring match)")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max processes to return (default: 50)")]),
                    "sortBy": .object(["type": .string("string"), "description": .string("Sort by: cpu, mem, pid, name (default: cpu)")])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let filter: String? = {
                    if case .object(let args) = arguments,
                       case .string(let f) = args["filter"] { return f }
                    return nil
                }()
                let limit: Int = {
                    if case .object(let args) = arguments,
                       case .int(let l) = args["limit"] { return l }
                    return 50
                }()
                let sortBy: String = {
                    if case .object(let args) = arguments,
                       case .string(let s) = args["sortBy"] { return s }
                    return "cpu"
                }()

                // ps output sorted by CPU by default
                let sortFlag: String
                switch sortBy.lowercased() {
                case "mem": sortFlag = "-m"
                case "pid": sortFlag = "-p"
                default: sortFlag = "-r" // sort by CPU
                }

                guard let output = try? shellOutput("/bin/ps", args: ["aux", sortFlag]) else {
                    return .object(["error": .string("Failed to execute ps")])
                }

                var lines = output.components(separatedBy: "\n")
                // Remove header
                let header = lines.removeFirst()
                _ = header // suppress unused warning

                var processes: [Value] = []
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }

                    // Parse ps aux columns: USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND
                    let parts = trimmed.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                    if parts.count < 11 { continue }

                    let user = String(parts[0])
                    let pid = String(parts[1])
                    let cpu = String(parts[2])
                    let mem = String(parts[3])
                    let command = String(parts[10])

                    // Apply filter
                    if let f = filter {
                        let lowerFilter = f.lowercased()
                        if !command.lowercased().contains(lowerFilter) &&
                           !user.lowercased().contains(lowerFilter) {
                            continue
                        }
                    }

                    processes.append(.object([
                        "user": .string(user),
                        "pid": .string(pid),
                        "cpu": .string(cpu),
                        "mem": .string(mem),
                        "command": .string(command)
                    ]))

                    if processes.count >= limit { break }
                }

                return .object([
                    "count": .int(processes.count),
                    "sortedBy": .string(sortBy),
                    "processes": .array(processes)
                ])
            }
        ))

        // MARK: 3. notify – open
        await router.register(ToolRegistration(
            name: "notify",
            module: moduleName,
            tier: .open,
            description: "Send a local macOS notification banner. Returns confirmation. Optionally specify a sound name (e.g. 'Glass', 'Ping').",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("Notification title")]),
                    "body": .object(["type": .string("string"), "description": .string("Notification body text")]),
                    "sound": .object(["type": .string("string"), "description": .string("Optional sound name (e.g., 'Glass', 'Basso', 'Ping')")])
                ]),
                "required": .array([.string("title"), .string("body")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let title) = args["title"],
                      case .string(let body) = args["body"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notify", reason: "missing 'title' or 'body'")
                }

                let soundName: String? = {
                    if case .string(let s) = args["sound"] { return s }
                    return nil
                }()

                do {
                    try await sendLocalNotification(title: title, body: body, soundName: soundName)
                    return .object([
                        "sent": .bool(true),
                        "title": .string(title),
                        "bodyLength": .int(body.utf8.count)
                    ])
                } catch let error as NotificationError {
                    return .object([
                        "sent": .bool(false),
                        "error": .string(error.localizedDescription)
                    ])
                } catch {
                    return .object([
                        "sent": .bool(false),
                        "error": .string("Notification delivery failed: \(error.localizedDescription)")
                    ])
                }
            }
        ))

        // MARK: 4. contacts_search – open
        await router.register(ToolRegistration(
            name: "contacts_search",
            module: moduleName,
            tier: .open,
            description: "Search macOS Contacts by name, phone, or email. Returns matching contacts with name, phones, emails, and addresses. Specify fields to control which fields are searched (default: name only).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search query to match against contact fields")]),
                    "fields": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Fields to search: 'name', 'phone', 'email' (default: [\"name\"])")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"] else {
                    throw ToolRouterError.invalidArguments(toolName: "contacts_search", reason: "missing 'query'")
                }

                let fields: [String] = {
                    if case .array(let arr) = args["fields"] {
                        return arr.compactMap { val in
                            if case .string(let s) = val { return s }
                            return nil
                        }
                    }
                    return ["name"]
                }()

                let store = CNContactStore()

                // Check authorization
                let status = CNContactStore.authorizationStatus(for: .contacts)
                if status == .notDetermined {
                    // Request access (blocks until user responds to TCC prompt)
                    let granted: Bool
                    do {
                        granted = try await store.requestAccess(for: .contacts)
                    } catch {
                        return .object(["error": .string("Contacts access request failed: \(error.localizedDescription)")])
                    }
                    if !granted {
                        return .object(["error": .string("Contacts access denied. Enable in System Settings > Privacy & Security > Contacts.")])
                    }
                } else if status != .authorized {
                    return .object(["error": .string("Contacts access not granted (status: \(status.rawValue)). Enable in System Settings > Privacy & Security > Contacts.")])
                }

                // Keys to fetch
                let keysToFetch: [CNKeyDescriptor] = [
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor,
                    CNContactPostalAddressesKey as CNKeyDescriptor,
                    CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
                ]

                // Build predicates based on fields
                var predicates: [NSPredicate] = []
                if fields.contains("name") {
                    predicates.append(CNContact.predicateForContacts(matchingName: query))
                }
                if fields.contains("email") {
                    predicates.append(CNContact.predicateForContacts(matchingEmailAddress: query))
                }
                if fields.contains("phone") {
                    let digits = query.filter { $0.isNumber || $0 == "+" }
                    if !digits.isEmpty {
                        let phoneNumber = CNPhoneNumber(stringValue: digits)
                        predicates.append(CNContact.predicateForContacts(matching: phoneNumber))
                    }
                }

                // Fallback to name search if no predicates
                if predicates.isEmpty {
                    predicates.append(CNContact.predicateForContacts(matchingName: query))
                }

                // Fetch contacts for each predicate
                var allContacts: [CNContact] = []
                for predicate in predicates {
                    do {
                        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
                        allContacts.append(contentsOf: contacts)
                    } catch {
                        // Skip failed predicates, continue with others
                    }
                }

                // Deduplicate by identifier
                var seen = Set<String>()
                let unique = allContacts.filter { seen.insert($0.identifier).inserted }

                // Format results
                let results: [Value] = Array(unique.prefix(50)).map { contact in
                    let name = CNContactFormatter.string(from: contact, style: .fullName)
                        ?? "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)

                    let phones: [Value] = contact.phoneNumbers.map { phone in
                        .object([
                            "label": .string(CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phone.label ?? "other")),
                            "number": .string(phone.value.stringValue)
                        ])
                    }

                    let emails: [Value] = contact.emailAddresses.map { email in
                        .object([
                            "label": .string(CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "other")),
                            "address": .string(email.value as String)
                        ])
                    }

                    let addresses: [Value] = contact.postalAddresses.map { addr in
                        let postal = addr.value
                        var parts: [String] = []
                        if !postal.street.isEmpty { parts.append(postal.street) }
                        if !postal.city.isEmpty { parts.append(postal.city) }
                        if !postal.state.isEmpty { parts.append(postal.state) }
                        if !postal.postalCode.isEmpty { parts.append(postal.postalCode) }
                        if !postal.country.isEmpty { parts.append(postal.country) }
                        return .object([
                            "label": .string(CNLabeledValue<CNPostalAddress>.localizedString(forLabel: addr.label ?? "other")),
                            "formatted": .string(parts.joined(separator: ", "))
                        ])
                    }

                    var entry: [String: Value] = ["name": .string(name)]
                    if !phones.isEmpty { entry["phones"] = .array(phones) }
                    if !emails.isEmpty { entry["emails"] = .array(emails) }
                    if !addresses.isEmpty { entry["addresses"] = .array(addresses) }
                    if !contact.organizationName.isEmpty { entry["organization"] = .string(contact.organizationName) }

                    return .object(entry)
                }

                return .object([
                    "count": .int(results.count),
                    "query": .string(query),
                    "fieldsSearched": .array(fields.map { .string($0) }),
                    "contacts": .array(results)
                ])
            }
        ))

    }

    // MARK: - Notification Helper

    private enum NotificationError: LocalizedError {
        case permissionDenied
        case authRequestFailed(String)
        case deliveryFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Notifications are denied for Notion Bridge. Enable them in System Settings > Notifications."
            case .authRequestFailed(let msg):
                return "Notification authorization failed: \(msg)"
            case .deliveryFailed(let msg):
                return "Notification delivery failed: \(msg)"
            }
        }
    }

    private static func sendLocalNotification(title: String, body: String, soundName: String?) async throws {
        // Standalone test executables crash on UNUserNotificationCenter.currentNotificationCenter
        // outside an .app bundle. Fallback keeps tests stable while production app uses native API.
        if Bundle.main.bundleURL.pathExtension != "app" {
            try sendFallbackNotification(title: title, body: body, soundName: soundName)
            return
        }

        let center = UNUserNotificationCenter.current()

        // PKT-369 N2 workaround: requestAuthorization() is unreliable when authorization
        // was granted externally (e.g., via System Settings). It may throw UNErrorDomain
        // error 1 even though permission IS granted. Always use notificationSettings()
        // as the source of truth after attempting authorization.
        var settings = await center.notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            // Attempt authorization — ignore the result/error per N2 pattern
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                // N2: Do NOT throw here — requestAuthorization error is unreliable.
                // Fall through to re-check notificationSettings() below.
            }
            // N2: Source of truth — re-check actual macOS grant state
            settings = await center.notificationSettings()
        }

        // Final gate: only proceed if actually authorized
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break // Authorized — proceed to send
        case .denied:
            throw NotificationError.permissionDenied
        case .notDetermined:
            // Still not determined after request — fall back to osascript
            try sendFallbackNotification(title: title, body: body, soundName: soundName)
            return
        @unknown default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if soundName != nil {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: "notionbridge-notify-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func sendFallbackNotification(title: String, body: String, soundName: String?) throws {
        let safeTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        var script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
        if let soundName {
            let safeSound = soundName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script += " sound name \"\(safeSound)\""
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? "osascript failed"
            throw NotificationError.deliveryFailed(stderr)
        }
    }

    // MARK: - Shell Helper

    /// Run a command and capture stdout.
    private static func shellOutput(_ executable: String, args: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
