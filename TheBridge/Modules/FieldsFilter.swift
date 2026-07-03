// FieldsFilter.swift — shared opt-in `fields` projection helper (PKT: fields Param
// Across Registry Tools + fetch_skill)
// TheBridge · Modules
//
// One pure, unit-tested filter function reused by the 6 row-shaped
// `registry_*` MCP tools (RegistryModule.swift) AND `fetch_skill`
// (SkillsModule.swift). Lets a caller request only the top-level envelope
// keys it needs — including a dotted `properties.X` path that sub-selects a
// single property out of the full `properties` map — instead of always
// paying for the full envelope.
//
// Design (locked by the packet's Decision Ledger, Rounds 1–5):
//  - Omitted `fields` (nil) OR an explicit empty array → the envelope is
//    returned completely untouched (byte-identical to pre-`fields` output).
//  - Non-empty `fields` → project the envelope down to ONLY the requested
//    top-level keys. A bare `"properties"` keeps the whole properties map.
//    A dotted `"properties.X"` sub-selects just that one property key.
//    Mixing both is a permissive UNION (bare wins → keeps everything).
//  - Property-path matching (`properties.X`) is case-insensitive, matching
//    `registry_find`'s existing `where`-predicate convention.
//  - An unknown top-level key or unknown property path silently produces no
//    match — never an error (matches `fetch_skill`'s existing `section`
//    param posture). Structural validation (is `fields` an array of
//    strings?) is the CALLER's job via `parseFieldsArgument`, and IS a hard
//    error (`ToolRouterError.invalidArguments`) on a wrong type — a wrong
//    type is broken caller code, not a typo.
//  - No max-length cap: a Set-lookup filter is O(1) per key, nothing here
//    to defend against (Round 2 Decision 1).

import MCP

public enum FieldsFilter {

    /// Parse the raw `fields` argument (if present) into a validated
    /// `[String]`. Returns `nil` when the key is absent — the "omitted"
    /// case, which callers must treat identically to an empty array (full
    /// response, no filtering).
    ///
    /// Throws `ToolRouterError.invalidArguments` when `fields` IS present
    /// but is structurally malformed — not an array, or contains a
    /// non-string element. That is caller-side broken integration code,
    /// not a typo, so it rejects the whole call (Round 3 Decision 5).
    public static func parseFieldsArgument(
        _ args: [String: Value],
        toolName: String
    ) throws -> [String]? {
        guard let raw = args["fields"] else { return nil }
        guard case .array(let items) = raw else {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "‘fields’ must be an array of strings")
        }
        var out: [String] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard case .string(let s) = item else {
                throw ToolRouterError.invalidArguments(
                    toolName: toolName,
                    reason: "‘fields’ must be an array of strings — found a non-string element")
            }
            out.append(s)
        }
        return out
    }

    /// Project a `.object` envelope down to the requested top-level keys.
    ///
    /// - `fields` nil or empty → `envelope` returned untouched (the
    ///   omitted/explicit-empty-array case — Success Criteria #2 / #9).
    /// - `propertiesKey` names the envelope key holding the nested
    ///   properties map (`"properties"` on every current caller) that
    ///   dotted paths sub-select into. A bare entry equal to
    ///   `propertiesKey` (case-insensitive) keeps the WHOLE map and wins
    ///   over any narrower dotted selection for the same key (permissive
    ///   union — Success Criteria #3).
    /// - Non-object `envelope` (defensive — every real caller passes
    ///   `.object`) is returned untouched.
    public static func project(
        _ envelope: Value,
        fields: [String]?,
        propertiesKey: String = "properties"
    ) -> Value {
        guard let fields, !fields.isEmpty else { return envelope }
        guard case .object(let dict) = envelope else { return envelope }

        var topLevelKeys = Set<String>()
        var propertyPaths = Set<String>()   // lowercased sub-keys of propertiesKey
        var wantsWholeProperties = false

        for raw in fields {
            if let dotIndex = raw.firstIndex(of: ".") {
                let head = String(raw[raw.startIndex..<dotIndex])
                let tail = String(raw[raw.index(after: dotIndex)...])
                if head.lowercased() == propertiesKey.lowercased(), !tail.isEmpty {
                    propertyPaths.insert(tail.lowercased())
                    continue
                }
                // Unknown/malformed dotted path (e.g. not under
                // propertiesKey) → silently no match, per the packet's
                // "unknown path never errors" posture.
                continue
            }
            if raw.lowercased() == propertiesKey.lowercased() {
                wantsWholeProperties = true
            }
            topLevelKeys.insert(raw)
        }

        var result: [String: Value] = [:]
        for (key, value) in dict {
            if key == propertiesKey {
                if wantsWholeProperties {
                    result[key] = value
                } else if !propertyPaths.isEmpty {
                    result[key] = projectProperties(value, wanted: propertyPaths)
                }
                // Neither whole nor narrowed request → propertiesKey
                // omitted entirely from the projected result.
                continue
            }
            if topLevelKeys.contains(key) {
                result[key] = value
            }
        }
        return .object(result)
    }

    /// Sub-select a nested properties `.object` map down to the requested
    /// (already-lowercased) key set, matching case-insensitively — same
    /// convention as `registry_find`'s `where`-predicate matching. Unknown
    /// keys are silently absent. Non-object input (defensive) → empty map.
    private static func projectProperties(_ properties: Value, wanted: Set<String>) -> Value {
        guard case .object(let props) = properties else { return .object([:]) }
        var out: [String: Value] = [:]
        for (key, value) in props where wanted.contains(key.lowercased()) {
            out[key] = value
        }
        return .object(out)
    }
}
