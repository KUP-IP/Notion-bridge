// FieldsFilterTests.swift — PKT: fields Param Across Registry Tools + fetch_skill
// TheBridge · Tests
//
// Hermetic unit tests for the shared `FieldsFilter` primitive (parse +
// project) against synthetic `Value` fixtures — no network, no gateway, no
// Notion. Proves the 13 Success Criteria that are mechanism-level (not
// tool-wiring-level); tool-specific wiring proofs live in
// RegistryModuleTests.swift (registry_* tools) and SkillsModuleTests.swift
// (fetch_skill).
//
// Criteria covered here:
//   #2  omitted fields → byte-identical output
//   #3  properties.X narrows; bare properties keeps all; mixing = union
//   #4  unknown top-level key / unknown property path → silently absent
//   #7  properties.X path matching is case-insensitive
//   #9  fields: [] behaves identically to omission
//   #11 structurally malformed fields → hard error (invalidArguments)

import Foundation
import MCP
import TheBridgeLib

func runFieldsFilterTests() async {
    print("\n\u{1F50D} FieldsFilter Tests (shared fields-param projection)")

    // A representative row-shaped envelope, matching RegistryModule's
    // `rowValue` shape: {entity, id, title, url, lastEditedTime, stale, properties}.
    func sampleRow() -> Value {
        .object([
            "entity": .string("skill"),
            "id": .string("aaaa0000000000000000000000000001"),
            "title": .string("Alpha"),
            "url": .string("https://n/aaaa"),
            "lastEditedTime": .string("2026-07-01T00:00:00.000Z"),
            "stale": .bool(false),
            "properties": .object([
                "summary": .string("desc of Alpha"),
                "status": .string("Stable"),
                "Domain": .string("infra"),
            ]),
        ])
    }

    func dict(_ v: Value) -> [String: Value] {
        if case .object(let o) = v { return o } else { return [:] }
    }

    // ============================================================
    // MARK: #2 — omitted fields → byte-identical
    // ============================================================

    await test("FieldsFilter: nil fields → envelope returned untouched (identity)") {
        let row = sampleRow()
        let projected = FieldsFilter.project(row, fields: nil)
        try expect(projected == row, "nil fields must be a pure identity projection")
    }

    // ============================================================
    // MARK: #9 — fields: [] behaves identically to omission
    // ============================================================

    await test("FieldsFilter: fields:[] behaves identically to nil (full response)") {
        let row = sampleRow()
        let viaNil = FieldsFilter.project(row, fields: nil)
        let viaEmpty = FieldsFilter.project(row, fields: [])
        try expect(viaEmpty == row, "empty array must be a pure identity projection")
        try expect(viaEmpty == viaNil, "fields:[] and omitted fields must be indistinguishable")
    }

    // ============================================================
    // MARK: #3 — top-level key selection
    // ============================================================

    await test("FieldsFilter: single top-level key retains identity keys by default") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["title"]))
        // title was requested; id+entity re-attached as identity keys.
        try expect(Set(projected.keys) == ["title", "id", "entity"], "got \(projected.keys.sorted())")
        try expect(projected["title"] == .string("Alpha"), "title value preserved")
        try expect(projected["id"] == .string("aaaa0000000000000000000000000001"), "id retained")
        try expect(projected["entity"] == .string("skill"), "entity retained")
    }

    await test("FieldsFilter: includeIdentity:false allows pure single-key projection") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["title"], includeIdentity: false))
        try expect(projected.count == 1, "expected exactly 1 key, got \(projected.count): \(projected.keys.sorted())")
        try expect(projected["title"] == .string("Alpha"), "title value preserved")
    }

    await test("FieldsFilter: multiple top-level keys all survive") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["title", "id", "stale"]))
        try expect(Set(projected.keys) == ["title", "id", "stale", "entity"], "got \(projected.keys.sorted())")
    }

    await test("FieldsFilter: bare 'properties' keeps the WHOLE properties map + identity") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["properties"]))
        try expect(Set(projected.keys) == ["properties", "id", "entity", "title"], "got \(projected.keys.sorted())")
        guard case .object(let props)? = projected["properties"] else {
            throw TestError.assertion("properties must be an object")
        }
        try expect(props.count == 3, "bare properties must keep all 3 sub-keys, got \(props.count)")
    }

    // ============================================================
    // MARK: #3 — dotted property sub-selection
    // ============================================================

    await test("FieldsFilter: properties.X sub-selects ONE property out of the map") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["properties.summary"]))
        try expect(projected["id"] != nil, "identity id retained with properties.X projection")
        guard case .object(let props)? = projected["properties"] else {
            throw TestError.assertion("properties must be present as an object")
        }
        try expect(props.count == 1, "expected exactly 1 sub-selected property, got \(props.count)")
        try expect(props["summary"] == .string("desc of Alpha"), "wrong/missing summary value")
    }

    await test("FieldsFilter: multiple properties.X entries union within the properties map") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["properties.summary", "properties.status"]))
        guard case .object(let props)? = projected["properties"] else {
            throw TestError.assertion("properties must be present")
        }
        try expect(Set(props.keys) == ["summary", "status"], "got \(props.keys.sorted())")
    }

    // ============================================================
    // MARK: #3 — mixing bare + dotted = permissive union (bare wins)
    // ============================================================

    await test("FieldsFilter: mixing bare 'properties' + dotted path keeps ALL properties (union)") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["properties.summary", "properties"]))
        guard case .object(let props)? = projected["properties"] else {
            throw TestError.assertion("properties must be present")
        }
        try expect(props.count == 3, "bare properties must win — expected all 3, got \(props.count)")
    }

    // ============================================================
    // MARK: #4 — unknown top-level key / unknown property path → silent no-match
    // ============================================================

    await test("FieldsFilter: unknown top-level key → silently absent, no error") {
        // With includeIdentity (default), only identity keys from the source remain.
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["doesNotExist"]))
        try expect(Set(projected.keys) == ["id", "entity", "title"], "got \(projected.keys.sorted())")
        let pure = dict(FieldsFilter.project(sampleRow(), fields: ["doesNotExist"], includeIdentity: false))
        try expect(pure.isEmpty, "unknown key must contribute nothing without identity; got \(pure.keys.sorted())")
    }

    await test("FieldsFilter: unknown property path → the requested property is silently absent (properties: {})") {
        // A `properties.X` selector was explicitly requested, so `properties`
        // itself stays present (distinguishing "you asked for a sub-property
        // and got zero matches" from "you never asked for properties at
        // all") — but it contains none of the sampleRow's real keys, i.e.
        // the unknown path silently contributes zero matches, never an error.
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["properties.doesNotExist"], includeIdentity: false))
        guard case .object(let props)? = projected["properties"] else {
            throw TestError.assertion("properties must be present as an object when a properties.X path was requested")
        }
        try expect(props.isEmpty, "an unknown property path must match nothing; got \(props.keys.sorted())")
    }

    await test("FieldsFilter: known + unknown top-level keys mixed → only known survive") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["title", "ghost", "id"]))
        // entity re-attached via includeIdentity even though not requested.
        try expect(Set(projected.keys) == ["title", "id", "entity"], "got \(projected.keys.sorted())")
    }

    // ============================================================
    // MARK: #7 — case-insensitive property-path matching
    // ============================================================

    await test("FieldsFilter: properties.X path matching is case-insensitive") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["properties.SUMMARY"]))
        guard case .object(let props)? = projected["properties"] else {
            throw TestError.assertion("properties must be present")
        }
        try expect(props.count == 1, "case-insensitive match must still project to 1 key")
        // Original casing of the Notion property key is preserved in the output.
        try expect(props["summary"] == .string("desc of Alpha"), "value must survive case-insensitive match")
    }

    await test("FieldsFilter: bare 'PROPERTIES' (any case) keeps the whole map") {
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["PROPERTIES"]))
        guard case .object(let props)? = projected["properties"] else {
            throw TestError.assertion("properties must be present")
        }
        try expect(props.count == 3, "case-insensitive bare match must keep all sub-keys")
    }

    await test("FieldsFilter: mixed-case top-level key is NOT matched case-insensitively (exact key match)") {
        // Top-level keys are exact-match (only the propertiesKey token itself
        // is treated case-insensitively) — this pins that distinction.
        // Identity keys are still re-attached from the source envelope.
        let projected = dict(FieldsFilter.project(sampleRow(), fields: ["Title"]))
        try expect(Set(projected.keys) == ["id", "entity", "title"], "got \(projected.keys.sorted())")
        let pure = dict(FieldsFilter.project(sampleRow(), fields: ["Title"], includeIdentity: false))
        try expect(pure.isEmpty, "top-level keys are case-SENSITIVE except the properties token")
    }

    // ============================================================
    // MARK: #11 — structurally malformed fields → hard error
    // ============================================================

    await test("FieldsFilter.parseFieldsArgument: nil/absent 'fields' key → nil (not an error)") {
        let parsed = try FieldsFilter.parseFieldsArgument([:], toolName: "test_tool")
        try expect(parsed == nil, "absent key must parse to nil")
    }

    await test("FieldsFilter.parseFieldsArgument: valid array of strings parses cleanly") {
        let parsed = try FieldsFilter.parseFieldsArgument(["fields": .array([.string("a"), .string("b")])], toolName: "test_tool")
        try expect(parsed == ["a", "b"], "got \(String(describing: parsed))")
    }

    await test("FieldsFilter.parseFieldsArgument: empty array parses to empty (not nil)") {
        let parsed = try FieldsFilter.parseFieldsArgument(["fields": .array([])], toolName: "test_tool")
        try expect(parsed != nil && parsed!.isEmpty, "explicit [] must parse to an empty array, not nil")
    }

    await test("FieldsFilter.parseFieldsArgument: wrong TYPE (object, not array) → hard invalidArguments error") {
        do {
            _ = try FieldsFilter.parseFieldsArgument(["fields": .object(["a": .string("b")])], toolName: "test_tool")
            throw TestError.assertion("expected a thrown invalidArguments error")
        } catch let e as ToolRouterError {
            if case .invalidArguments(let tool, _) = e {
                try expect(tool == "test_tool", "tool name should propagate")
            } else {
                throw TestError.assertion("wrong ToolRouterError case: \(e)")
            }
        }
    }

    await test("FieldsFilter.parseFieldsArgument: wrong TYPE (scalar string, not array) → hard error") {
        do {
            _ = try FieldsFilter.parseFieldsArgument(["fields": .string("title")], toolName: "test_tool")
            throw TestError.assertion("expected a thrown invalidArguments error")
        } catch is ToolRouterError {
            // expected
        }
    }

    await test("FieldsFilter.parseFieldsArgument: array containing a non-string element → hard error") {
        do {
            _ = try FieldsFilter.parseFieldsArgument(["fields": .array([.string("ok"), .int(5)])], toolName: "test_tool")
            throw TestError.assertion("expected a thrown invalidArguments error")
        } catch is ToolRouterError {
            // expected
        }
    }

    // ============================================================
    // MARK: defensive — non-object envelope input
    // ============================================================

    await test("FieldsFilter.project: non-object envelope is returned untouched (defensive)") {
        let scalar: Value = .string("not an object")
        let projected = FieldsFilter.project(scalar, fields: ["title"])
        try expect(projected == scalar, "non-object input must pass through unchanged")
    }

    // ============================================================
    // MARK: custom propertiesKey parameter (fetch_skill reuses this)
    // ============================================================

    await test("FieldsFilter.project: custom propertiesKey parameter works identically") {
        let envelope: Value = .object([
            "content": .string("body text"),
            "properties": .object(["Status": .string("Active")]),
        ])
        let projected = dict(FieldsFilter.project(envelope, fields: ["content"], propertiesKey: "properties"))
        try expect(projected.count == 1 && projected["content"] == .string("body text"),
                   "custom propertiesKey path must still project top-level keys correctly")
    }
}
