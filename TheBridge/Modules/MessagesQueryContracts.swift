import Foundation
import MCP

/// Pure Wave 3 Messages contracts (#204, #215–#218).
public enum MessagesQueryContracts {
    /// Default lists show only normal chat rows (not tapbacks / Apple Pay / system).
    public static let normalRowPredicate =
        "COALESCE(m.associated_message_type, 0) = 0 AND COALESCE(m.item_type, 0) = 0"
    public static let normalRowPredicateM2 =
        "COALESCE(m2.associated_message_type, 0) = 0 AND COALESCE(m2.item_type, 0) = 0"

    public enum ChatSelector: Equatable {
        case contact(String)
        case chatIdentifier(String)

        public static func parse(contact: String?, chatIdentifier: String?) throws -> ChatSelector {
            let c = contact?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let g = chatIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasC = !c.isEmpty
            let hasG = !g.isEmpty
            guard hasC != hasG else {
                throw ToolRouterError.invalidArguments(
                    toolName: "messages_chat",
                    reason: "exactly one of 'contact' (exact handle) or 'chatIdentifier' (exact id) is required"
                )
            }
            return hasC ? .contact(c) : .chatIdentifier(g)
        }

        public var sqlParam: String {
            switch self {
            case .contact(let s), .chatIdentifier(let s): return s
            }
        }

        /// Exact match only — no LIKE (#215).
        public var whereClause: String {
            switch self {
            case .contact:
                return "h.id = ?1"
            case .chatIdentifier:
                return "c.chat_identifier = ?1"
            }
        }
    }

    /// `date_read = 0` → null, never 2001-01-01.
    public static func dateReadValue(_ raw: Any?) -> Value {
        if raw == nil || raw is NSNull { return .null }
        if let i = raw as? Int, i == 0 { return .null }
        if let d = raw as? Double, d == 0 { return .null }
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("2001-01-01") { return .null }
            return .string(t)
        }
        if let i = raw as? Int { return .int(i) }
        return .null
    }

    public static func isReadValue(_ raw: Any?) -> Value {
        if let i = raw as? Int { return .bool(i != 0) }
        if let b = raw as? Bool { return .bool(b) }
        return .null
    }

    public static let attachmentMaxBytes = 100 * 1024 * 1024

    public static func payloadXORError(body: String?, filePath: String?) -> String? {
        let bodyTrim = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fileTrim = filePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasBody = !bodyTrim.isEmpty
        let hasFile = !fileTrim.isEmpty
        if hasBody && hasFile {
            return "filePath XOR body — send the file, then a second confirmed send for caption text"
        }
        if !hasBody && !hasFile {
            return "missing body or filePath"
        }
        return nil
    }

    public static func fileSendPolicyError(
        filePath: String,
        chatIdentifier: String?,
        resolvedService: String?,
        checkFilesystem: Bool
    ) -> String? {
        if let chatIdentifier, !chatIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "file attachments are 1:1 iMessage only — chatIdentifier/groups are refused"
        }
        let svc = (resolvedService ?? "").lowercased()
        if svc == "sms" || svc == "rcs" {
            return "file attachments are 1:1 iMessage only — SMS/RCS/MMS refused"
        }
        guard checkFilesystem else { return nil }
        let expanded = (filePath as NSString).expandingTildeInPath
        if expanded.contains("/Library/Messages") || expanded.hasSuffix("chat.db") {
            return "refused: do not send files from ~/Library/Messages or chat.db"
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue else {
            return "file not found or unreadable: \(filePath)"
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
           let size = attrs[.size] as? NSNumber,
           size.intValue > attachmentMaxBytes {
            return "file exceeds \(attachmentMaxBytes) byte attachment cap"
        }
        return nil
    }
}
