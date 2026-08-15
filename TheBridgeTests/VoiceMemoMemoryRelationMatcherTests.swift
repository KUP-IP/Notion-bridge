// VoiceMemoMemoryRelationMatcherTests.swift — cache-only Memory relation attach
// TheBridge · Tests
//
// Unique contacts attach; first-name collisions are listed and never written.
// Distinctive project/doc tokens attach; stoplist tokens do not. Blocks require
// a two-token exact title. executeMemoryKeep writes bound relation keys only.

import Foundation
import MCP
import TheBridgeLib

private let kAndrew = "aaaaaaaa-1111-2222-3333-444444444444"
private let kHannahA = "bbbbbbbb-1111-2222-3333-444444444441"
private let kHannahB = "bbbbbbbb-1111-2222-3333-444444444442"
private let kEmmiwood = "cccccccc-1111-2222-3333-444444444444"
private let kBridge = "dddddddd-1111-2222-3333-444444444444"
private let kFBD = "eeeeeeee-1111-2222-3333-444444444444"
private let kWalk = "ffffffff-1111-2222-3333-444444444441"
private let kDeepWork = "ffffffff-1111-2222-3333-444444444442"
private let kIsaiahPlayerId = "dc8e8f3f-e607-4b5d-809e-ae289574f40c"

private func sampleCatalog() -> VoiceMemoRelationCatalog {
    VoiceMemoRelationCatalog(
        contacts: [
            VoiceMemoCacheEntry(id: kAndrew, title: "Andrew Moeller"),
            VoiceMemoCacheEntry(id: kHannahA, title: "Hannah Smith"),
            VoiceMemoCacheEntry(id: kHannahB, title: "Hannah Jones"),
        ],
        projects: [
            VoiceMemoCacheEntry(id: kEmmiwood, title: "Emmiwood / OBK Website + Booking System", aliases: ["emmiwood"]),
            VoiceMemoCacheEntry(id: kBridge, title: "The Bridge"),
            VoiceMemoCacheEntry(id: kFBD, title: "FBD"),
        ],
        docs: [],
        blocks: [
            VoiceMemoCacheEntry(id: kWalk, title: "Walk"),
            VoiceMemoCacheEntry(id: kDeepWork, title: "Deep Work"),
        ]
    )
}

private func memoryEntityWithRelations(contactsBound: Bool = true) -> RegistryEntity {
    RegistryEntity(
        key: "memory",
        displayName: "Memory",
        dataSourceId: "8a39359f-2246-40a2-8614-a487ba9abd23",
        properties: [
            RegistryProperty(key: "title", notionName: "Memory", notionPropertyId: "title", type: "title", role: .title),
            RegistryProperty(key: "summary", notionName: "Relevant", notionPropertyId: "sum1", type: "select"),
            RegistryProperty(key: "players", notionName: "PLAYERS", notionPropertyId: "rel1", type: "relation", role: .relation),
            RegistryProperty(
                key: "contacts",
                notionName: "CONTACTS",
                notionPropertyId: contactsBound ? "c1" : nil,
                type: "relation",
                role: .relation
            ),
            RegistryProperty(key: "projects", notionName: "PROJECTS", notionPropertyId: "p1", type: "relation", role: .relation),
            RegistryProperty(key: "docs", notionName: "DOCS", notionPropertyId: "d1", type: "relation", role: .relation),
            RegistryProperty(key: "blocks", notionName: "BLOCKS", notionPropertyId: "b1", type: "relation", role: .relation),
        ],
        cacheTTLSeconds: 3600,
        hasBody: true
    )
}

private actor RelationStubState {
    var createdFields: [String: Value] = [:]
    var appendedChildrenJSON = ""

    func recordCreate(fields: [String: Value]) { createdFields = fields }
    func recordAppend(_ json: String) { appendedChildrenJSON = json }
}

private func installRelationStubs(on router: ToolRouter, state: RelationStubState, pageId: String) async {
    let create = ToolRegistration(
        name: "registry_create", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { args in
            guard case .object(let a) = args,
                  case .object(let fields)? = a["fields"] else {
                return .object(["created": .bool(false)])
            }
            await state.recordCreate(fields: fields)
            return .object([
                "created": .bool(true),
                "row": .object([
                    "entity": .string("memory"),
                    "id": .string(pageId),
                    "title": .string("Memo"),
                    "url": .string(""),
                    "properties": .object([:]),
                ]),
            ])
        })
    let get = ToolRegistration(
        name: "registry_get", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in
            .object([
                "entity": .string("memory"),
                "id": .string(pageId),
                "properties": .object([
                    "players": .array([.string(kIsaiahPlayerId)]),
                ]),
            ])
        })
    let append = ToolRegistration(
        name: "notion_blocks_append", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { args in
            if case .object(let a) = args,
               case .string(let children)? = a["children"] {
                await state.recordAppend(children)
            }
            return .object(["ok": .bool(true)])
        })
    await router.register(create)
    await router.register(get)
    await router.register(append)
}

func runVoiceMemoMemoryRelationMatcherTests() async {
    print("\n\u{1F517} Memory relation matcher — unique contacts + distinctive projects")

    await test("matcher: unique full name and unique first name attach") {
        let match = VoiceMemoMemoryRelationMatcher.match(
            haystack: "Talked to Andrew Moeller about the lake gathering.",
            catalog: sampleCatalog()
        )
        try expect(match.contactIds == [kAndrew], "Andrew Moeller is unique, got \(match.contactIds)")
        try expect(match.notes.isEmpty, "unique contact must not emit a collision note, got \(match.notes)")
    }

    await test("matcher: first-name collision lists names and attaches none") {
        let match = VoiceMemoMemoryRelationMatcher.match(
            haystack: "Hannah is coming to the lake.",
            catalog: sampleCatalog()
        )
        try expect(match.contactIds.isEmpty, "Hannah collision must not attach, got \(match.contactIds)")
        try expect(match.notes.contains { $0.contains("Hannah") && $0.contains("2 contacts") },
                   "collision note must name Hannah, got \(match.notes)")
    }

    await test("matcher: unique full name wins among first-name collisions") {
        let match = VoiceMemoMemoryRelationMatcher.match(
            haystack: "Hannah Smith will bring dessert.",
            catalog: sampleCatalog()
        )
        try expect(match.contactIds == [kHannahA], "Hannah Smith is unique, got \(match.contactIds)")
        try expect(match.notes.isEmpty, "resolved full name should not also note the first-name collision")
    }

    await test("matcher: stoplist skips The Bridge; unique token attaches Emmiwood and FBD") {
        let match = VoiceMemoMemoryRelationMatcher.match(
            haystack: "Review the Emmiwood website and the FBD client report. The Bridge can wait.",
            catalog: sampleCatalog()
        )
        try expect(match.projectIds.contains(kEmmiwood), "emmiwood alias/token must attach, got \(match.projectIds)")
        try expect(match.projectIds.contains(kFBD), "unique FBD token must attach, got \(match.projectIds)")
        try expect(!match.projectIds.contains(kBridge), "stoplist must skip The Bridge, got \(match.projectIds)")
    }

    await test("matcher: Erin inside engineer is not a contact hit") {
        let catalog = VoiceMemoRelationCatalog(
            contacts: [VoiceMemoCacheEntry(id: kAndrew, title: "Erin")]
        )
        let match = VoiceMemoMemoryRelationMatcher.match(
            haystack: "The site engineer will review pricing.",
            catalog: catalog
        )
        try expect(match.contactIds.isEmpty, "substring Erin-in-engineer must not attach, got \(match.contactIds)")
    }

    await test("matcher: one-token block skipped; two-token exact title attaches") {
        let match = VoiceMemoMemoryRelationMatcher.match(
            haystack: "I went for a walk then sat down for Deep Work.",
            catalog: sampleCatalog()
        )
        try expect(!match.blockIds.contains(kWalk), "Walk is a one-token block title, got \(match.blockIds)")
        try expect(match.blockIds.contains(kDeepWork), "Deep Work exact title must attach, got \(match.blockIds)")
    }

    await test("executeMemoryKeep: writes unique contact + project; collision note in body") {
        let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        let state = RelationStubState()
        await installRelationStubs(on: router, state: state, pageId: "page-rel")

        _ = try await VoiceMemoProcessor.executeMemoryKeep(
            entityKey: "memory",
            intent: VoiceMemoIntent(
                kind: .memoryKeep,
                confidence: 0.95,
                entityKey: "memory",
                title: "Lake gathering",
                fields: [:]
            ),
            plan: VoiceMemoPlan(
                generatedTitle: "Lake gathering",
                skipMemoryKeep: false,
                summary: "Andrew Moeller and Hannah are coming. Review Emmiwood next.",
                actions: ["Isaiah will text Andrew Moeller the address so the lake gathering has a confirmed meetup point."],
                intents: []
            ),
            transcript: "Andrew Moeller and Hannah are coming. Review Emmiwood next.",
            router: router,
            entity: memoryEntityWithRelations(),
            catalog: sampleCatalog()
        )

        let fields = await state.createdFields
        try expect(fields["players"] == .string(kIsaiahPlayerId), "PLAYERS attach must remain")
        try expect(fields["contacts"] == .string(kAndrew), "unique Andrew must attach, got \(String(describing: fields["contacts"]))")
        try expect(fields["projects"] == .string(kEmmiwood), "Emmiwood must attach, got \(String(describing: fields["projects"]))")
        let appended = await state.appendedChildrenJSON
        try expect(appended.contains("Unresolved names"), "collision heading must land in the body")
        try expect(appended.contains("Hannah"), "Hannah collision must be listed in the body, got \(appended)")
        try expect(appended.contains("Isaiah will text Andrew Moeller"),
                   "action items must copy onto the body, got \(appended)")
    }

    await test("executeMemoryKeep: unbound CONTACTS is skipped, PLAYERS still writes") {
        let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        let state = RelationStubState()
        await installRelationStubs(on: router, state: state, pageId: "page-unbound-contacts")

        _ = try await VoiceMemoProcessor.executeMemoryKeep(
            entityKey: "memory",
            intent: VoiceMemoIntent(
                kind: .memoryKeep,
                confidence: 0.95,
                entityKey: "memory",
                title: "Andrew note",
                fields: [:]
            ),
            plan: VoiceMemoPlan(
                generatedTitle: "Andrew note",
                skipMemoryKeep: false,
                summary: "Talked to Andrew Moeller about the lake gathering this weekend.",
                actions: [],
                intents: []
            ),
            transcript: "Talked to Andrew Moeller about the lake gathering this weekend.",
            router: router,
            entity: memoryEntityWithRelations(contactsBound: false),
            catalog: sampleCatalog()
        )

        let fields = await state.createdFields
        try expect(fields["contacts"] == nil, "unbound CONTACTS must not be written, got \(fields)")
        try expect(fields["players"] == .string(kIsaiahPlayerId), "PLAYERS must still attach")
        try expect(fields["projects"] == nil, "no project mention in this memo")
    }
}
