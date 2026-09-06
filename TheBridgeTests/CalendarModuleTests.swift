// CalendarModuleTests.swift
// TheBridge · Tests
//
// PKT-962 (v3.7·I) + 2026-09-06 calendar_free_busy v0: unit tests for the
// calendar_* tool family against the
// injectable `CalendarStoring` seam — no live EventKit / TCC. Covers tool
// registration + tiering, CRUD round-trips, date-range filtering, and the
// access-denied path. Handlers are invoked directly off their
// `ToolRegistration` so dispatch (security gate / license / UserDefaults)
// stays out of the unit boundary — the seam is what's under test. Mirrors
// RemindersModuleTests (PKT-957), the v3.7·D template this packet reuses.

import Foundation
import MCP
import TheBridgeLib

// MARK: - In-memory mock seam

/// Deterministic in-memory `CalendarStoring` for tests. `authStatus` drives
/// the access-denied branch; the dictionaries model calendars + events. The
/// range filter is implemented exactly as the production EventKit predicate
/// behaves: an event overlaps [start, end] when its start < query.end AND its
/// end > query.start.
final class MockCalendarStore: CalendarStoring, @unchecked Sendable {
    var authStatus: CalendarAuthStatus
    private(set) var cals: [CalendarInfo]
    private(set) var items: [String: CalendarEvent] = [:]
    private var seq = 0
    private(set) var lastSpan: CalendarEventSpan = .thisEvent
    private(set) var createCount = 0
    private(set) var updateCount = 0
    private(set) var deleteCount = 0

    init(authStatus: CalendarAuthStatus = .authorized, calendars: [CalendarInfo]? = nil) {
        self.authStatus = authStatus
        self.cals = calendars ?? [
            CalendarInfo(id: "cal-home", title: "Home", isDefault: true, allowsModify: true),
            CalendarInfo(id: "cal-work", title: "Work", isDefault: false, allowsModify: true)
        ]
    }

    func seed(_ event: CalendarEvent) {
        items[event.id] = event
    }

    func authorizationStatus() -> CalendarAuthStatus { authStatus }

    func ensureAccess() async throws {
        switch authStatus {
        case .authorized: return
        case .notDetermined, .denied, .restricted:
            throw CalendarModuleError.accessDenied
        }
    }

    func calendars() async throws -> [CalendarInfo] {
        try await ensureAccess()
        return cals
    }

    private func calTitle(_ id: String) -> String {
        cals.first(where: { $0.id == id })?.title ?? ""
    }

    func event(id: String) async throws -> CalendarEvent? {
        try await ensureAccess()
        return items[id]
    }

    func events(_ query: CalendarEventQuery) async throws -> [CalendarEvent] {
        try await ensureAccess()
        var out = Array(items.values)
        if let calId = query.calendarId {
            guard cals.contains(where: { $0.id == calId }) else {
                throw CalendarModuleError.calendarNotFound(calId)
            }
            out = out.filter { $0.calendarId == calId }
        }
        // Overlap test (string ISO-8601 compares lexicographically when
        // zero-padded + same offset — the harness uses Z-suffixed times).
        out = out.filter { $0.start < query.end && $0.end > query.start }
        return out.sorted { $0.start < $1.start }
    }

    func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await ensureAccess()
        createCount += 1
        let calId = draft.calendarId ?? "cal-home"
        guard cals.contains(where: { $0.id == calId }) else {
            throw CalendarModuleError.calendarNotFound(calId)
        }
        guard let start = draft.start else { throw CalendarModuleError.missingRequired("start") }
        guard let end = draft.end else { throw CalendarModuleError.missingRequired("end") }
        seq += 1
        let id = "evt-\(seq)"
        let event = CalendarEvent(
            id: id,
            title: draft.title ?? "",
            start: start,
            end: end,
            allDay: draft.allDay ?? false,
            calendarId: calId,
            calendarTitle: calTitle(calId),
            location: draft.location,
            notes: draft.notes,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            isRecurring: !(draft.recurrenceFreq ?? "").isEmpty,
            recurrenceRule: Self.ruleString(draft),
            alarms: Self.alarmItems(draft.alarms)
        )
        items[id] = event
        return event
    }

    func update(id: String, _ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await update(id: id, draft, span: .thisEvent)
    }

    func update(id: String, _ draft: CalendarEventDraft, span: CalendarEventSpan) async throws -> CalendarEvent {
        try await ensureAccess()
        updateCount += 1
        lastSpan = span
        guard var event = items[id] else { throw CalendarModuleError.notFound(id) }
        if let t = draft.title { event.title = t }
        if let s = draft.start { event.start = s }
        if let e = draft.end { event.end = e }
        if let a = draft.allDay { event.allDay = a }
        if let loc = draft.location { event.location = loc }
        if let n = draft.notes { event.notes = n }
        if let tz = draft.timeZoneIdentifier { event.timeZoneIdentifier = tz.isEmpty ? nil : tz }
        if let freq = draft.recurrenceFreq {
            if freq.isEmpty {
                event.isRecurring = false
                event.recurrenceRule = nil
            } else {
                event.isRecurring = true
                event.recurrenceRule = Self.ruleString(draft)
            }
        }
        if let alarms = draft.alarms { event.alarms = Self.alarmItems(alarms) }
        if let c = draft.calendarId {
            guard cals.contains(where: { $0.id == c }) else {
                throw CalendarModuleError.calendarNotFound(c)
            }
            event.calendarId = c
            event.calendarTitle = calTitle(c)
        }
        items[id] = event
        return event
    }

    func delete(id: String) async throws {
        try await delete(id: id, span: .thisEvent)
    }

    func delete(id: String, span: CalendarEventSpan) async throws {
        try await ensureAccess()
        deleteCount += 1
        lastSpan = span
        guard items[id] != nil else { throw CalendarModuleError.notFound(id) }
        items[id] = nil
    }

    private static func ruleString(_ draft: CalendarEventDraft) -> String? {
        guard let freq = draft.recurrenceFreq, !freq.isEmpty else { return nil }
        return "\(freq.lowercased());interval:\(draft.recurrenceInterval ?? 1)"
    }

    private static func alarmItems(_ drafts: [AlarmDraft]?) -> [AlarmItem] {
        guard let drafts else { return [] }
        return drafts.enumerated().map { idx, d in
            AlarmItem(
                id: "alarm-\(idx)",
                type: d.type,
                triggerMinutesBefore: d.triggerMinutesBefore,
                triggerAbsoluteDate: d.triggerAbsoluteDate
            )
        }
    }
}

// MARK: - Test helpers

private func makeCalendarRouter(_ store: CalendarStoring) async -> ToolRouter {
    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await CalendarModule.register(on: router, store: store)
    return router
}

/// Invoke a tool's handler directly (bypasses dispatch gating — the seam is
/// the unit under test).
private func callCalendarHandler(_ router: ToolRouter, _ name: String, _ args: Value) async throws -> Value {
    let regs = await router.registrations(forModule: "calendar")
    guard let reg = regs.first(where: { $0.name == name }) else {
        throw TestError.assertion("tool \(name) not registered")
    }
    return try await reg.handler(args)
}

private func calField(_ v: Value, _ key: String) -> Value? {
    if case .object(let d) = v { return d[key] }
    return nil
}

/// Fixture busy interval. ISO-8601 Z times so string order matches Date order.
private func busyFixture(
    id: String,
    title: String,
    start: String,
    end: String,
    calendarId: String = "cal-home",
    calendarTitle: String = "Home"
) -> CalendarEvent {
    CalendarEvent(
        id: id,
        title: title,
        start: start,
        end: end,
        allDay: false,
        calendarId: calendarId,
        calendarTitle: calendarTitle,
        location: nil,
        notes: nil
    )
}

private func parseWindow(_ start: String, _ end: String) throws -> (Date, Date) {
    (try CalendarISOParsing.parse(start), try CalendarISOParsing.parse(end))
}

private func stringList(_ v: Value?) throws -> [String] {
    guard case .array(let arr)? = v else {
        throw TestError.assertion("expected string array")
    }
    return try arr.map { item in
        guard case .string(let s) = item else {
            throw TestError.assertion("expected string in array")
        }
        return s
    }
}

func runCalendarModuleTests() async {
    print("\n\u{1F4C5} CalendarModule Tests (PKT-962 · v3.7·I)")

    // MARK: registration + tiering

    await test("CalendarModule registers exactly 6 tools") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let tools = await router.registrations(forModule: "calendar")
        try expect(tools.count == 6, "expected 6 calendar tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        try expect(names.contains("calendar_free_busy"), "calendar_free_busy must be registered")
    }

    await test("calendar tiering: list/events/free_busy open, create/update notify, delete request") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let tools = await router.registrations(forModule: "calendar")
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        try expect(byName["calendar_list"]?.tier == .open, "list must be .open")
        try expect(byName["calendar_events"]?.tier == .open, "events must be .open")
        try expect(byName["calendar_free_busy"]?.tier == .open, "free_busy must be .open")
        try expect(byName["calendar_create"]?.tier == .notify, "create must be .notify")
        try expect(byName["calendar_update"]?.tier == .notify, "update must be .notify")
        try expect(byName["calendar_delete"]?.tier == .request, "delete must be .request")
    }

    // MARK: calendar_list

    await test("calendar_list returns the seeded calendars with default flag") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let result = try await callCalendarHandler(router, "calendar_list", .object([:]))
        guard case .int(let count)? = calField(result, "count") else {
            throw TestError.assertion("missing count")
        }
        try expect(count == 2, "expected 2 calendars, got \(count)")
        guard case .array(let arr)? = calField(result, "calendars") else {
            throw TestError.assertion("missing calendars array")
        }
        let defaults = arr.filter { calField($0, "isDefault") == .bool(true) }
        try expect(defaults.count == 1, "exactly one default calendar expected")
    }

    // MARK: CRUD round-trip

    await test("calendar_create returns a new id + record") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let result = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Standup"),
            "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T09:30:00Z"),
            "location": .string("Zoom")
        ]))
        guard case .string(let id)? = calField(result, "id") else {
            throw TestError.assertion("create returned no id")
        }
        try expect(!id.isEmpty, "empty id")
        let rec = calField(result, "event")!
        try expect(calField(rec, "title") == .string("Standup"), "title mismatch")
        try expect(calField(rec, "start") == .string("2026-06-05T09:00:00Z"), "start mismatch")
        try expect(calField(rec, "end") == .string("2026-06-05T09:30:00Z"), "end mismatch")
        try expect(calField(rec, "location") == .string("Zoom"), "location mismatch")
        try expect(calField(rec, "calendar") == .string("Home"), "should default to Home calendar")
    }

    await test("calendar_create requires title, start, and end") {
        let router = await makeCalendarRouter(MockCalendarStore())
        // missing title
        do {
            _ = try await callCalendarHandler(router, "calendar_create", .object([
                "start": .string("2026-06-05T09:00:00Z"), "end": .string("2026-06-05T10:00:00Z")
            ]))
            throw TestError.assertion("expected invalidArguments for missing title")
        } catch is ToolRouterError { /* expected */ }
        // missing end
        do {
            _ = try await callCalendarHandler(router, "calendar_create", .object([
                "title": .string("x"), "start": .string("2026-06-05T09:00:00Z")
            ]))
            throw TestError.assertion("expected invalidArguments for missing end")
        } catch is ToolRouterError { /* expected */ }
    }

    await test("calendar_update mutates fields and can move calendars") {
        let store = MockCalendarStore()
        let router = await makeCalendarRouter(store)
        let created = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Draft"),
            "start": .string("2026-06-10T12:00:00Z"),
            "end": .string("2026-06-10T13:00:00Z")
        ]))
        guard case .string(let id)? = calField(created, "id") else { throw TestError.assertion("no id") }

        let updated = try await callCalendarHandler(router, "calendar_update", .object([
            "id": .string(id),
            "title": .string("Final review"),
            "start": .string("2026-06-10T14:00:00Z"),
            "end": .string("2026-06-10T15:00:00Z"),
            "calendarId": .string("cal-work")
        ]))
        let rec = calField(updated, "event")!
        try expect(calField(rec, "title") == .string("Final review"), "title not updated")
        try expect(calField(rec, "start") == .string("2026-06-10T14:00:00Z"), "start not updated")
        try expect(calField(rec, "calendar") == .string("Work"), "calendar not moved")
    }

    await test("calendar_update on a missing event surfaces notFound") {
        let router = await makeCalendarRouter(MockCalendarStore())
        do {
            _ = try await callCalendarHandler(router, "calendar_update", .object([
                "id": .string("evt-nope"), "title": .string("ghost")
            ]))
            throw TestError.assertion("expected notFound")
        } catch let e as CalendarModuleError {
            try expect(e == .notFound("evt-nope"), "expected notFound, got \(e)")
        }
    }

    // MARK: date-range filter

    await test("calendar_events filters by date range (overlap semantics)") {
        let router = await makeCalendarRouter(MockCalendarStore())
        // June 5 morning event
        _ = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Inside"),
            "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z")
        ]))
        // June 20 event — outside the queried window
        _ = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Outside"),
            "start": .string("2026-06-20T09:00:00Z"),
            "end": .string("2026-06-20T10:00:00Z")
        ]))

        let result = try await callCalendarHandler(router, "calendar_events", .object([
            "start": .string("2026-06-05T00:00:00Z"),
            "end": .string("2026-06-06T00:00:00Z")
        ]))
        guard case .int(let n)? = calField(result, "count") else { throw TestError.assertion("no count") }
        try expect(n == 1, "expected 1 event in the June 5 window, got \(n)")
        guard case .array(let arr)? = calField(result, "events") else { throw TestError.assertion("no events array") }
        try expect(calField(arr[0], "title") == .string("Inside"), "wrong event returned")
    }

    await test("calendar_events scoped to a calendarId only returns that calendar's events") {
        let router = await makeCalendarRouter(MockCalendarStore())
        _ = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Home thing"), "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z"), "calendarId": .string("cal-home")
        ]))
        _ = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Work thing"), "start": .string("2026-06-05T11:00:00Z"),
            "end": .string("2026-06-05T12:00:00Z"), "calendarId": .string("cal-work")
        ]))
        let result = try await callCalendarHandler(router, "calendar_events", .object([
            "start": .string("2026-06-05T00:00:00Z"),
            "end": .string("2026-06-06T00:00:00Z"),
            "calendarId": .string("cal-work")
        ]))
        try expect(calField(result, "count") == .int(1), "expected 1 work event")
        guard case .array(let arr)? = calField(result, "events") else { throw TestError.assertion("no events array") }
        try expect(calField(arr[0], "title") == .string("Work thing"), "wrong scoped event")
    }

    await test("calendar_events requires start and end") {
        let router = await makeCalendarRouter(MockCalendarStore())
        do {
            _ = try await callCalendarHandler(router, "calendar_events", .object([
                "start": .string("2026-06-05T00:00:00Z")
            ]))
            throw TestError.assertion("expected invalidArguments for missing end")
        } catch is ToolRouterError { /* expected */ }
    }

    await test("calendar full event output exposes provider identity and participant context") {
        let store = MockCalendarStore()
        store.seed(CalendarEvent(
            id: "evt-meta",
            title: "Partner meeting",
            start: "2026-06-05T09:00:00Z",
            end: "2026-06-05T10:00:00Z",
            allDay: false,
            calendarId: "cal-work",
            calendarTitle: "Work",
            location: "Conference Room",
            notes: "Agenda",
            externalId: "google-ical-uid@example.com",
            organizer: "mailto:owner@example.com",
            attendees: ["mailto:one@example.com", "mailto:two@example.com"],
            conferenceURL: "https://meet.example.com/abc",
            lastModified: "2026-06-04T18:00:00Z",
            isRecurring: true,
            isDetached: false
        ))
        let router = await makeCalendarRouter(store)
        let result = try await callCalendarHandler(router, "calendar_events", .object([
            "start": .string("2026-06-05T00:00:00Z"),
            "end": .string("2026-06-06T00:00:00Z")
        ]))
        guard case .array(let events)? = calField(result, "events"), let value = events.first else {
            throw TestError.assertion("full event output missing")
        }
        try expect(calField(value, "providerExternalId") == .string("google-ical-uid@example.com"))
        try expect(calField(value, "organizer") == .string("mailto:owner@example.com"))
        try expect(calField(value, "attendees") == .array([
            .string("mailto:one@example.com"), .string("mailto:two@example.com")
        ]))
        try expect(calField(value, "itemURL") == .string("https://meet.example.com/abc"))
        try expect(calField(value, "lastModified") == .string("2026-06-04T18:00:00Z"))
        try expect(calField(value, "isRecurring") == .bool(true))
        try expect(calField(value, "isDetached") == .bool(false))
    }

    // MARK: naive ISO parsing (CalendarISOParsing)

    await test("CalendarISOParsing accepts timezone-qualified ISO-8601") {
        let date = try CalendarISOParsing.parse("2026-06-05T09:00:00Z")
        let iso = ISO8601DateFormatter().string(from: date)
        try expect(iso.hasPrefix("2026-06-05"), "parsed Z timestamp: \(iso)")
    }

    await test("CalendarISOParsing accepts naive local wall-clock timestamps") {
        let date = try CalendarISOParsing.parse("2026-06-03T14:30:00")
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        try expect(comps.year == 2026 && comps.month == 6 && comps.day == 3, "year/month/day")
        try expect(comps.hour == 14 && comps.minute == 30, "hour/minute in local TZ")
    }

    await test("CalendarISOParsing accepts date-only strings at local midnight") {
        let date = try CalendarISOParsing.parse("2026-06-03")
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        try expect(comps.year == 2026 && comps.month == 6 && comps.day == 3, "date-only parse")
        try expect(comps.hour == 0 && comps.minute == 0, "date-only anchors local midnight")
    }

    await test("CalendarISOParsing rejects garbage input") {
        do {
            _ = try CalendarISOParsing.parse("not-a-date")
            throw TestError.assertion("expected invalidDate")
        } catch let e as CalendarModuleError {
            if case .invalidDate = e { return }
            throw TestError.assertion("expected invalidDate, got \(e)")
        }
    }

    // MARK: delete

    await test("calendar_delete removes the event (re-delete throws notFound)") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let created = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Temp"), "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z")
        ]))
        guard case .string(let id)? = calField(created, "id") else { throw TestError.assertion("no id") }

        let del = try await callCalendarHandler(router, "calendar_delete", .object(["id": .string(id)]))
        try expect(calField(del, "deleted") == .bool(true), "delete should report true")

        // gone from the range query
        let listed = try await callCalendarHandler(router, "calendar_events", .object([
            "start": .string("2026-06-05T00:00:00Z"), "end": .string("2026-06-06T00:00:00Z")
        ]))
        try expect(calField(listed, "count") == .int(0), "deleted event still listed")

        // re-delete surfaces a notFound (no silent success on a missing id)
        do {
            _ = try await callCalendarHandler(router, "calendar_delete", .object(["id": .string(id)]))
            throw TestError.assertion("expected notFound on re-delete")
        } catch let e as CalendarModuleError {
            try expect(e == .notFound(id), "expected notFound, got \(e)")
        }
    }

    // MARK: access-denied path

    await test("access-denied: every calendar tool surfaces accessDenied") {
        let store = MockCalendarStore(authStatus: .denied)
        let router = await makeCalendarRouter(store)

        func expectDenied(_ name: String, _ args: Value) async {
            await test("  \(name) → accessDenied when TCC denied") {
                do {
                    _ = try await callCalendarHandler(router, name, args)
                    throw TestError.assertion("expected accessDenied")
                } catch let e as CalendarModuleError {
                    try expect(e == .accessDenied, "expected accessDenied, got \(e)")
                }
            }
        }

        await expectDenied("calendar_list", .object([:]))
        await expectDenied("calendar_events", .object([
            "start": .string("2026-06-05T00:00:00Z"), "end": .string("2026-06-06T00:00:00Z")
        ]))
        await expectDenied("calendar_free_busy", .object([
            "start": .string("2026-06-05T09:00:00Z"), "end": .string("2026-06-05T10:00:00Z"),
            "calendarId": .string("cal-home")
        ]))
        await expectDenied("calendar_create", .object([
            "title": .string("x"), "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z")
        ]))
        await expectDenied("calendar_update", .object(["id": .string("evt-1"), "title": .string("y")]))
        await expectDenied("calendar_delete", .object(["id": .string("evt-1")]))
    }

    await test("notDetermined status also throws accessDenied (no live TCC prompt in tests)") {
        let router = await makeCalendarRouter(MockCalendarStore(authStatus: .notDetermined))
        do {
            _ = try await callCalendarHandler(router, "calendar_list", .object([:]))
            throw TestError.assertion("expected accessDenied for notDetermined")
        } catch let e as CalendarModuleError {
            try expect(e == .accessDenied)
        }
    }

    await test("#206 calendar_create wires and validates timeZoneIdentifier") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let ok = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("TZ"),
            "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z"),
            "timeZoneIdentifier": .string("America/Chicago")
        ]))
        let rec = calField(ok, "event")!
        try expect(calField(rec, "timeZone") == .string("America/Chicago"))
        do {
            _ = try await callCalendarHandler(router, "calendar_create", .object([
                "title": .string("Bad TZ"),
                "start": .string("2026-06-05T09:00:00Z"),
                "end": .string("2026-06-05T10:00:00Z"),
                "timeZoneIdentifier": .string("Not/AZone")
            ]))
            throw TestError.assertion("expected invalidTimeZone")
        } catch let e as CalendarModuleError {
            try expect(e == .invalidTimeZone("Not/AZone"))
        }
    }

    await test("#205 recurrence create and span default thisEvent") {
        let store = MockCalendarStore()
        let router = await makeCalendarRouter(store)
        let created = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Weekly"),
            "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z"),
            "recurrenceFreq": .string("weekly"),
            "recurrenceInterval": .int(1)
        ]))
        let rec = calField(created, "event")!
        try expect(calField(rec, "isRecurring") == .bool(true))
        try expect(calField(rec, "recurrenceRule") == .string("weekly;interval:1"))
        guard case .string(let id)? = calField(created, "id") else {
            throw TestError.assertion("missing id")
        }
        let updated = try await callCalendarHandler(router, "calendar_update", .object([
            "id": .string(id),
            "title": .string("Weekly renamed"),
            "span": .string("futureEvents")
        ]))
        try expect(calField(updated, "span") == .string("futureEvents"))
        try expect(store.lastSpan == .futureEvents)
        do {
            _ = try await callCalendarHandler(router, "calendar_update", .object([
                "id": .string(id),
                "span": .string("all")
            ]))
            throw TestError.assertion("expected invalidSpan")
        } catch let e as CalendarModuleError {
            try expect(e == .invalidSpan("all"))
        }
        _ = try await callCalendarHandler(router, "calendar_delete", .object([
            "id": .string(id)
        ]))
        try expect(store.lastSpan == .thisEvent)
    }

    await test("#207 alarms relative to start, empty array clears") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let created = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Alarm"),
            "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z"),
            "alarms": .array([.object([
                "type": .string("relative"),
                "triggerMinutesBefore": .int(15)
            ])])
        ]))
        let rec = calField(created, "event")!
        guard case .array(let alarms)? = calField(rec, "alarms"), alarms.count == 1 else {
            throw TestError.assertion("expected one alarm")
        }
        try expect(calField(alarms[0], "type") == .string("relative"))
        try expect(calField(alarms[0], "triggerMinutesBefore") == .int(15))
        guard case .string(let id)? = calField(created, "id") else {
            throw TestError.assertion("missing id")
        }
        let cleared = try await callCalendarHandler(router, "calendar_update", .object([
            "id": .string(id),
            "alarms": .array([])
        ]))
        try expect(calField(cleared, "event").flatMap { calField($0, "alarms") } == nil)
    }

    // MARK: calendar_free_busy — half-open [start, end) overlap

    // Fixture busy block: 2026-09-08T15:00:00Z – 2026-09-08T16:00:00Z
    let fixtureBusy = busyFixture(
        id: "evt-focus-standup",
        title: "Standup",
        start: "2026-09-08T15:00:00Z",
        end: "2026-09-08T16:00:00Z"
    )

    await test("CalendarFreeBusy: no overlap when event is entirely before the window") {
        let (ws, we) = try parseWindow("2026-09-08T16:30:00Z", "2026-09-08T17:30:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == false, "event before window must not overlap")
        try expect(check.busy.isEmpty, "busy must be empty")
        try expect(check.overlappingEventIds.isEmpty, "ids must be empty")
    }

    await test("CalendarFreeBusy: no overlap when event is entirely after the window") {
        let (ws, we) = try parseWindow("2026-09-08T13:00:00Z", "2026-09-08T14:00:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == false, "event after window must not overlap")
        try expect(check.busy.isEmpty)
    }

    await test("CalendarFreeBusy: partial overlap when window starts inside the event") {
        let (ws, we) = try parseWindow("2026-09-08T15:30:00Z", "2026-09-08T16:30:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == true, "partial end overlap")
        try expect(check.overlappingEventIds == ["evt-focus-standup"])
        try expect(check.busy.first?.title == "Standup")
        try expect(check.busy.first?.start == "2026-09-08T15:00:00Z")
        try expect(check.busy.first?.end == "2026-09-08T16:00:00Z")
    }

    await test("CalendarFreeBusy: partial overlap when window ends inside the event") {
        let (ws, we) = try parseWindow("2026-09-08T14:30:00Z", "2026-09-08T15:30:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == true, "partial start overlap")
        try expect(check.overlappingEventIds == ["evt-focus-standup"])
    }

    await test("CalendarFreeBusy: contained — event fully inside the window") {
        let (ws, we) = try parseWindow("2026-09-08T14:00:00Z", "2026-09-08T17:00:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == true, "contained event overlaps")
        try expect(check.overlappingEventIds == ["evt-focus-standup"])
    }

    await test("CalendarFreeBusy: contained — window fully inside the event") {
        let (ws, we) = try parseWindow("2026-09-08T15:15:00Z", "2026-09-08T15:45:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == true, "window inside event overlaps")
        try expect(check.overlappingEventIds == ["evt-focus-standup"])
    }

    await test("CalendarFreeBusy: exact window match overlaps") {
        let (ws, we) = try parseWindow("2026-09-08T15:00:00Z", "2026-09-08T16:00:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == true, "identical [start, end) overlaps")
        try expect(check.overlappingEventIds == ["evt-focus-standup"])
    }

    await test("CalendarFreeBusy: touching at event end is exclusive (no overlap)") {
        // Event occupies [15:00, 16:00). Window [16:00, 17:00) shares the
        // instant 16:00 only — half-open, so not busy.
        let (ws, we) = try parseWindow("2026-09-08T16:00:00Z", "2026-09-08T17:00:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == false, "touching end must be exclusive")
        try expect(check.overlappingEventIds.isEmpty)
    }

    await test("CalendarFreeBusy: touching at event start is exclusive (no overlap)") {
        // Event occupies [15:00, 16:00). Window [14:00, 15:00) shares the
        // instant 15:00 only — half-open, so not busy.
        let (ws, we) = try parseWindow("2026-09-08T14:00:00Z", "2026-09-08T15:00:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == false, "touching start must be exclusive")
        try expect(check.overlappingEventIds.isEmpty)
    }

    await test("CalendarFreeBusy: empty calendar yields overlaps false") {
        let (ws, we) = try parseWindow("2026-09-08T15:00:00Z", "2026-09-08T16:00:00Z")
        let check = try CalendarFreeBusy.evaluate(events: [], windowStart: ws, windowEnd: we)
        try expect(check.overlaps == false)
        try expect(check.busy.isEmpty)
        try expect(check.overlappingEventIds.isEmpty)
    }

    await test("CalendarFreeBusy.resolveCalendarId defaults omitted/blank to FOCUS-only id") {
        try expect(CalendarFreeBusy.focusCalendarId == "A33CAC6E-9D15-44F4-BC35-54F204F4DA39")
        try expect(CalendarFreeBusy.resolveCalendarId(nil) == CalendarFreeBusy.focusCalendarId)
        try expect(CalendarFreeBusy.resolveCalendarId("") == CalendarFreeBusy.focusCalendarId)
        try expect(CalendarFreeBusy.resolveCalendarId("   ") == CalendarFreeBusy.focusCalendarId)
        try expect(CalendarFreeBusy.resolveCalendarId("cal-home") == "cal-home")
    }

    await test("CalendarFreeBusy.requireKnownCalendar fails closed on a missing id") {
        let calendars = [CalendarInfo(id: "cal-home", title: "Home", isDefault: true, allowsModify: true)]
        do {
            try CalendarFreeBusy.requireKnownCalendar(id: CalendarFreeBusy.focusCalendarId, calendars: calendars)
            throw TestError.assertion("expected calendarNotFound for missing FOCUS id")
        } catch let e as CalendarModuleError {
            try expect(e == .calendarNotFound(CalendarFreeBusy.focusCalendarId))
        }
        try CalendarFreeBusy.requireKnownCalendar(id: "cal-home", calendars: calendars)
    }

    await test("CalendarFreeBusy: inverted range throws invertedRange") {
        let (ws, we) = try parseWindow("2026-09-08T16:00:00Z", "2026-09-08T15:00:00Z")
        do {
            _ = try CalendarFreeBusy.evaluate(events: [fixtureBusy], windowStart: ws, windowEnd: we)
            throw TestError.assertion("expected invertedRange")
        } catch let e as CalendarModuleError {
            try expect(e == .invertedRange, "expected invertedRange, got \(e)")
        }
    }

    await test("calendar_free_busy returns busy payload and overlapping ids") {
        let store = MockCalendarStore()
        store.seed(fixtureBusy)
        store.seed(busyFixture(
            id: "evt-later",
            title: "Later",
            start: "2026-09-08T18:00:00Z",
            end: "2026-09-08T19:00:00Z"
        ))
        let router = await makeCalendarRouter(store)
        let result = try await callCalendarHandler(router, "calendar_free_busy", .object([
            "start": .string("2026-09-08T15:30:00Z"),
            "end": .string("2026-09-08T16:30:00Z"),
            "calendarId": .string("cal-home")
        ]))
        try expect(calField(result, "overlaps") == .bool(true))
        try expect(calField(result, "calendarId") == .string("cal-home"))
        try expect(try stringList(calField(result, "overlappingEventIds")) == ["evt-focus-standup"])
        guard case .array(let busy)? = calField(result, "busy") else {
            throw TestError.assertion("missing busy array")
        }
        try expect(busy.count == 1, "expected one overlapping busy interval")
        try expect(calField(busy[0], "id") == .string("evt-focus-standup"))
        try expect(calField(busy[0], "title") == .string("Standup"))
        try expect(calField(busy[0], "start") == .string("2026-09-08T15:00:00Z"))
        try expect(calField(busy[0], "end") == .string("2026-09-08T16:00:00Z"))
    }

    await test("calendar_free_busy defaults to the FOCUS EventKit calendar id") {
        let focus = CalendarInfo(
            id: CalendarFreeBusy.focusCalendarId,
            title: "FOCUS",
            isDefault: true,
            allowsModify: true
        )
        let store = MockCalendarStore(calendars: [
            focus,
            CalendarInfo(id: "cal-home", title: "Home", isDefault: false, allowsModify: true)
        ])
        store.seed(busyFixture(
            id: "evt-focus",
            title: "FOCUS block",
            start: "2026-09-08T15:00:00Z",
            end: "2026-09-08T16:00:00Z",
            calendarId: CalendarFreeBusy.focusCalendarId,
            calendarTitle: "FOCUS"
        ))
        store.seed(busyFixture(
            id: "evt-home",
            title: "Home block",
            start: "2026-09-08T15:00:00Z",
            end: "2026-09-08T16:00:00Z",
            calendarId: "cal-home"
        ))
        let router = await makeCalendarRouter(store)
        let result = try await callCalendarHandler(router, "calendar_free_busy", .object([
            "start": .string("2026-09-08T15:00:00Z"),
            "end": .string("2026-09-08T16:00:00Z")
        ]))
        try expect(calField(result, "overlaps") == .bool(true))
        try expect(calField(result, "calendarId") == .string(CalendarFreeBusy.focusCalendarId))
        try expect(try stringList(calField(result, "overlappingEventIds")) == ["evt-focus"])
    }

    await test("calendar_free_busy missing FOCUS default fails closed (not empty-free)") {
        // Default store has cal-home / cal-work only — FOCUS id is absent.
        let router = await makeCalendarRouter(MockCalendarStore())
        do {
            let result = try await callCalendarHandler(router, "calendar_free_busy", .object([
                "start": .string("2026-09-08T15:00:00Z"),
                "end": .string("2026-09-08T16:00:00Z")
            ]))
            throw TestError.assertion("must not look free; got \(result)")
        } catch let e as CalendarModuleError {
            try expect(
                e == .calendarNotFound(CalendarFreeBusy.focusCalendarId),
                "expected FOCUS calendarNotFound, got \(e)"
            )
        }
    }

    await test("calendar_free_busy inverted window fails before a store read") {
        let router = await makeCalendarRouter(MockCalendarStore())
        do {
            _ = try await callCalendarHandler(router, "calendar_free_busy", .object([
                "start": .string("2026-09-08T16:00:00Z"),
                "end": .string("2026-09-08T15:00:00Z"),
                "calendarId": .string("cal-home")
            ]))
            throw TestError.assertion("expected invertedRange")
        } catch let e as CalendarModuleError {
            try expect(e == .invertedRange, "expected invertedRange, got \(e)")
        }
    }

    await test("calendar_free_busy requires start and end") {
        let router = await makeCalendarRouter(MockCalendarStore())
        do {
            _ = try await callCalendarHandler(router, "calendar_free_busy", .object([
                "start": .string("2026-09-08T15:00:00Z")
            ]))
            throw TestError.assertion("expected invalidArguments for missing end")
        } catch is ToolRouterError { /* expected */ }
    }

    await test("calendar_free_busy unknown calendarId surfaces calendarNotFound") {
        let router = await makeCalendarRouter(MockCalendarStore())
        do {
            _ = try await callCalendarHandler(router, "calendar_free_busy", .object([
                "start": .string("2026-09-08T15:00:00Z"),
                "end": .string("2026-09-08T16:00:00Z"),
                "calendarId": .string("cal-missing")
            ]))
            throw TestError.assertion("expected calendarNotFound")
        } catch let e as CalendarModuleError {
            try expect(e == .calendarNotFound("cal-missing"), "expected calendarNotFound, got \(e)")
        }
    }

    await test("calendar_free_busy empty calendar returns overlaps false") {
        let store = MockCalendarStore()
        let router = await makeCalendarRouter(store)
        let result = try await callCalendarHandler(router, "calendar_free_busy", .object([
            "start": .string("2026-09-08T15:00:00Z"),
            "end": .string("2026-09-08T16:00:00Z"),
            "calendarId": .string("cal-home")
        ]))
        try expect(calField(result, "overlaps") == .bool(false))
        try expect(calField(result, "calendarId") == .string("cal-home"))
        try expect(try stringList(calField(result, "overlappingEventIds")).isEmpty)
        guard case .array(let busy)? = calField(result, "busy") else {
            throw TestError.assertion("missing busy array")
        }
        try expect(busy.isEmpty, "empty calendar must return empty busy")
    }

    await test("calendar_free_busy invalid ISO date fails closed (not empty-free)") {
        let router = await makeCalendarRouter(MockCalendarStore())
        do {
            let result = try await callCalendarHandler(router, "calendar_free_busy", .object([
                "start": .string("not-a-date"),
                "end": .string("2026-09-08T16:00:00Z"),
                "calendarId": .string("cal-home")
            ]))
            throw TestError.assertion("must not look free; got \(result)")
        } catch let e as CalendarModuleError {
            if case .invalidDate = e { return }
            throw TestError.assertion("expected invalidDate, got \(e)")
        }
    }

    await test("calendar_free_busy is read-only — no EventKit writes") {
        let store = MockCalendarStore()
        store.seed(fixtureBusy)
        let router = await makeCalendarRouter(store)
        _ = try await callCalendarHandler(router, "calendar_free_busy", .object([
            "start": .string("2026-09-08T15:00:00Z"),
            "end": .string("2026-09-08T16:00:00Z"),
            "calendarId": .string("cal-home")
        ]))
        try expect(store.createCount == 0, "create must not run")
        try expect(store.updateCount == 0, "update must not run")
        try expect(store.deleteCount == 0, "delete must not run")
    }
}
