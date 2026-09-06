// CalendarModule.swift – Calendar Tools (native EventKit Calendar CRUD)
// TheBridge · Modules
//
// Six tools: calendar_list (open), calendar_events (open),
// calendar_free_busy (open, read-only FOCUS overlap check),
// calendar_create (notify), calendar_update (notify),
// calendar_delete (request).
//
// Created by PKT-962 (v3.7·I): first-class native Calendar module over
// EventKit `.event` entities, replacing connector/cloud-only calendar access
// so agents enumerate calendars, query events by date range, and CRUD events
// without a cloud round-trip.
//
// ── REUSES v3.7·D (PKT-957)'s EventKit infrastructure ─────────────────────
// This module DOES NOT recreate the EventKit store or re-declare any
// entitlement. It mirrors RemindersModule's injectable-seam pattern — all
// store access routes through a `CalendarStoring` protocol so the unit tests
// never touch live EventKit / TCC. Production uses `EventKitCalendarStore`,
// which constructs an `EKEventStore` exactly as `EventKitRemindersStore` does
// (the same EventKit type backs both `.reminder` and `.event` entities); a
// single process may share one `EKEventStore` between the two production
// stores. Tests inject a deterministic in-memory mock.
//
// ── ENTITLEMENT / OPERATOR GATE (shared with PKT-957) ─────────────────────
// Live use requires:
//   1. com.apple.security.personal-information.calendars in
//      TheBridge.entitlements — ALREADY DECLARED by PKT-957 (v3.7·D).
//      This packet REUSES it; it does NOT add a second entitlement key.
//   2. a runtime Calendar TCC grant (operator, first-call prompt).
// As with reminders, the calendars entitlement MUST be validated against
// notarize BEFORE shipping; if notarize refuses it, the documented fallback
// is AppleScript via the existing apple-events entitlement. This is an
// OPERATOR step — the same notarize-validate residual as PKT-957, NOT
// validated by this packet.

import AppKit
@preconcurrency import EventKit
import Foundation
import MCP

// MARK: - Store Seam (injectable)

/// Authorization state for the Calendar store, decoupled from EventKit so the
/// mock seam can drive every branch (incl. the access-denied path). Mirrors
/// `RemindersAuthStatus` but kept distinct so a future write-only calendar
/// access state could be modelled independently of reminders.
public enum CalendarAuthStatus: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// A plain calendar (EKCalendar of type `.event`). Decoupled from EKCalendar
/// so the seam is testable without EventKit objects.
public struct CalendarInfo: Sendable, Equatable {
    public let id: String       // EKCalendar.calendarIdentifier
    public let title: String
    public let isDefault: Bool
    public let allowsModify: Bool
    public let calendarType: String
    public let sourceIdentifier: String?
    public let sourceTitle: String?
    public let sourceType: String?

    public init(
        id: String,
        title: String,
        isDefault: Bool,
        allowsModify: Bool,
        calendarType: String = "unknown",
        sourceIdentifier: String? = nil,
        sourceTitle: String? = nil,
        sourceType: String? = nil
    ) {
        self.id = id
        self.title = title
        self.isDefault = isDefault
        self.allowsModify = allowsModify
        self.calendarType = calendarType
        self.sourceIdentifier = sourceIdentifier
        self.sourceTitle = sourceTitle
        self.sourceType = sourceType
    }
}

/// A plain calendar-event record. `start` / `end` are ISO-8601. Decoupled
/// from EKEvent so the seam is testable without EventKit objects.
public struct CalendarEvent: Sendable, Equatable {
    public let id: String       // EKEvent.eventIdentifier
    public var title: String
    public var start: String    // ISO-8601
    public var end: String      // ISO-8601
    public var allDay: Bool
    public var calendarId: String
    public var calendarTitle: String
    public var location: String?
    public var notes: String?
    public var timeZoneIdentifier: String?
    public var externalId: String?
    public var organizer: String?
    public var attendees: [String]
    public var conferenceURL: String?
    public var lastModified: String?
    public var isRecurring: Bool
    public var isDetached: Bool
    public var recurrenceRule: String?
    public var alarms: [AlarmItem]

    public init(
        id: String,
        title: String,
        start: String,
        end: String,
        allDay: Bool,
        calendarId: String,
        calendarTitle: String,
        location: String?,
        notes: String?,
        timeZoneIdentifier: String? = nil,
        externalId: String? = nil,
        organizer: String? = nil,
        attendees: [String] = [],
        conferenceURL: String? = nil,
        lastModified: String? = nil,
        isRecurring: Bool = false,
        isDetached: Bool = false,
        recurrenceRule: String? = nil,
        alarms: [AlarmItem] = []
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.location = location
        self.notes = notes
        self.timeZoneIdentifier = timeZoneIdentifier
        self.externalId = externalId
        self.organizer = organizer
        self.attendees = attendees
        self.conferenceURL = conferenceURL
        self.lastModified = lastModified
        self.isRecurring = isRecurring
        self.isDetached = isDetached
        self.recurrenceRule = recurrenceRule
        self.alarms = alarms
    }
}

/// Date-range filter for `calendar_events`. `start` / `end` are ISO-8601 and
/// both required (an unbounded EventKit event query is not meaningful).
public struct CalendarEventQuery: Sendable {
    public var start: String       // ISO-8601 (range lower bound)
    public var end: String         // ISO-8601 (range upper bound)
    public var calendarId: String? // nil = all event calendars

    public init(start: String, end: String, calendarId: String? = nil) {
        self.start = start
        self.end = end
        self.calendarId = calendarId
    }
}

/// Draft for `calendar_create` / `calendar_update`. Optional fields mean
/// "leave unchanged" on update. RecurrenceFreq `""` clears a series rule;
/// alarms `[]` clears alarms. `span` applies only to update/delete of a series.
public struct CalendarEventDraft: Sendable {
    public var title: String?
    public var start: String?      // ISO-8601
    public var end: String?        // ISO-8601
    public var allDay: Bool?
    public var calendarId: String?
    public var location: String?
    public var notes: String?
    public var timeZoneIdentifier: String?
    public var recurrenceFreq: String?
    public var recurrenceInterval: Int?
    public var recurrenceEndDate: String?
    public var recurrenceCount: Int?
    public var alarms: [AlarmDraft]?

    public init(
        title: String? = nil,
        start: String? = nil,
        end: String? = nil,
        allDay: Bool? = nil,
        calendarId: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        timeZoneIdentifier: String? = nil,
        recurrenceFreq: String? = nil,
        recurrenceInterval: Int? = nil,
        recurrenceEndDate: String? = nil,
        recurrenceCount: Int? = nil,
        alarms: [AlarmDraft]? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendarId = calendarId
        self.location = location
        self.notes = notes
        self.timeZoneIdentifier = timeZoneIdentifier
        self.recurrenceFreq = recurrenceFreq
        self.recurrenceInterval = recurrenceInterval
        self.recurrenceEndDate = recurrenceEndDate
        self.recurrenceCount = recurrenceCount
        self.alarms = alarms
    }
}

/// EventKit span for series mutations. `thisEvent` is the default when omitted.
public enum CalendarEventSpan: String, Sendable, Equatable {
    case thisEvent
    case futureEvents

    public static func parse(_ raw: String?) throws -> CalendarEventSpan {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return .thisEvent }
        switch trimmed {
        case "thisEvent": return .thisEvent
        case "futureEvents": return .futureEvents
        default: throw CalendarModuleError.invalidSpan(trimmed)
        }
    }

    public var ekSpan: EKSpan {
        switch self {
        case .thisEvent: return .thisEvent
        case .futureEvents: return .futureEvents
        }
    }
}

/// The injectable store seam. Production = `EventKitCalendarStore`;
/// tests = a deterministic in-memory mock. All methods are async + throwing
/// so the mock can drive the access-denied path uniformly.
public protocol CalendarStoring: Sendable {
    func authorizationStatus() -> CalendarAuthStatus
    /// Ensures access is authorized, triggering the TCC prompt if
    /// `.notDetermined`. Throws `CalendarModuleError.accessDenied` otherwise.
    func ensureAccess() async throws
    func calendars() async throws -> [CalendarInfo]
    func events(_ query: CalendarEventQuery) async throws -> [CalendarEvent]
    /// Provider-backed direct lookup. Implementations must query their durable
    /// calendar store; process-local caches are not authoritative.
    func event(id: String) async throws -> CalendarEvent?
    func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent
    func update(id: String, _ draft: CalendarEventDraft) async throws -> CalendarEvent
    func delete(id: String) async throws
    func update(id: String, _ draft: CalendarEventDraft, span: CalendarEventSpan) async throws -> CalendarEvent
    func delete(id: String, span: CalendarEventSpan) async throws
}


public extension CalendarStoring {
    /// Compatibility default for non-production test seams. Production EventKit
    /// overrides this with `EKEventStore.event(withIdentifier:)`.
    func event(id: String) async throws -> CalendarEvent? { nil }

    func update(id: String, _ draft: CalendarEventDraft, span: CalendarEventSpan) async throws -> CalendarEvent {
        try await update(id: id, draft)
    }

    func delete(id: String, span: CalendarEventSpan) async throws {
        try await delete(id: id)
    }
}

// MARK: - Errors

public enum CalendarModuleError: LocalizedError, Equatable {
    case accessDenied
    case notFound(String)
    case calendarNotFound(String)
    case immutableCalendar(String)
    case invalidDate(String)
    case missingRequired(String)
    case invalidTimeZone(String)
    case invalidSpan(String)
    /// Candidate window is not a positive half-open range (`start >= end`).
    case invertedRange
    /// v0 occupancy SSOT is FOCUS EventKit only (ISAIAH Keepr live probe).
    case occupancyNotFocus(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access not granted. Enable in System Settings > Privacy & Security > Calendars for The Bridge."
        case .notFound(let id):
            return "Event not found: \(id)"
        case .calendarNotFound(let id):
            return "Calendar not found: \(id)"
        case .immutableCalendar(let id):
            return "Calendar does not allow modification: \(id)"
        case .invalidDate(let s):
            return "Invalid ISO-8601 date: \(s)"
        case .missingRequired(let field):
            return "Missing required field: \(field)"
        case .invalidTimeZone(let identifier):
            return "Invalid IANA time zone identifier: \(identifier)"
        case .invalidSpan(let raw):
            return "span must be thisEvent or futureEvents, got: \(raw)"
        case .invertedRange:
            return "Invalid range: start must be before end (half-open [start, end))."
        case .occupancyNotFocus(let id):
            return "Occupancy SSOT is the FOCUS EventKit calendar (\(CalendarFreeBusy.focusCalendarId)). Refusing calendarId \(id). Meetings / Google Meetings freeBusy is out of scope for v0."
        }
    }
}

// MARK: - EventKit-backed store (production)

/// Parses agent-supplied ISO-8601 timestamps for calendar tools. Accepts
/// timezone-qualified strings, naive local wall-clock (`2026-06-03T09:00:00`),
/// and date-only (`2026-06-03`) anchored to the user's local time zone.
public enum CalendarISOParsing {
    private static func makeISO(fractionalSeconds: Bool = false) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f
    }

    private static func makeNaiveLocal() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }

    private static func makeNaiveLocalDateOnly() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    public static func parse(_ iso: String) throws -> Date {
        if let date = makeISO(fractionalSeconds: true).date(from: iso)
            ?? makeISO().date(from: iso) {
            return date
        }
        if let date = makeNaiveLocal().date(from: iso) {
            return date
        }
        if let date = makeNaiveLocalDateOnly().date(from: iso) {
            return date
        }
        throw CalendarModuleError.invalidDate(iso)
    }
}

/// Live EventKit implementation over `.event` entities. Requires the
/// calendars entitlement (declared by PKT-957) + a Calendar TCC grant
/// (operator). Not exercised by the unit tests — those use the mock.
///
/// Shares the same `EKEventStore` *type* as `EventKitRemindersStore`; a
/// process that wants one store for both entity kinds can construct this with
/// the reminders store's `EKEventStore`. The default initializer makes its own.
public final class EventKitCalendarStore: CalendarStoring, @unchecked Sendable {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func authorizationStatus() -> CalendarAuthStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        case .writeOnly:
            // Write-only grants can create events but not read them back;
            // fail-closed for the read paths (treat as restricted).
            return .restricted
        @unknown default:
            return .restricted
        }
    }

    public func ensureAccess() async throws {
        switch authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            await MainActor.run {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = (try? await store.requestFullAccessToEvents()) ?? false
            } else {
                granted = await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
                }
            }
            if !granted { throw CalendarModuleError.accessDenied }
        case .denied, .restricted:
            throw CalendarModuleError.accessDenied
        }
    }

    /// A fresh formatter per call — `ISO8601DateFormatter` is not `Sendable`,
    /// so it cannot be a shared static across the actor-hopping handlers.
    /// (Same rationale as `EventKitRemindersStore.makeISO`.)
    private static func makeISO() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private func dateToISO(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.makeISO().string(from: date)
    }

    private func isoToDate(_ iso: String) throws -> Date {
        try CalendarISOParsing.parse(iso)
    }

    private func participantLabel(_ participant: EKParticipant?) -> String? {
        guard let participant else { return nil }
        let url = participant.url.absoluteString
        if !url.isEmpty { return url }
        if let name = participant.name, !name.isEmpty { return name }
        return nil
    }

    private func toEvent(_ e: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: e.eventIdentifier ?? "",
            title: e.title ?? "",
            start: dateToISO(e.startDate),
            end: dateToISO(e.endDate),
            allDay: e.isAllDay,
            calendarId: e.calendar?.calendarIdentifier ?? "",
            calendarTitle: e.calendar?.title ?? "",
            location: e.location,
            notes: e.notes,
            timeZoneIdentifier: e.timeZone?.identifier,
            externalId: e.calendarItemExternalIdentifier,
            organizer: participantLabel(e.organizer),
            attendees: (e.attendees ?? []).compactMap(participantLabel),
            conferenceURL: e.url?.absoluteString,
            lastModified: dateToISO(e.lastModifiedDate),
            isRecurring: !(e.recurrenceRules ?? []).isEmpty,
            isDetached: e.isDetached,
            recurrenceRule: Self.serializeRule(e.recurrenceRules?.first),
            alarms: Self.serializeAlarms(e.alarms)
        )
    }


    private static func calendarTypeName(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    private static func sourceTypeName(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "mobileme"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }

    public func calendars() async throws -> [CalendarInfo] {
        try await ensureAccess()
        return store.calendars(for: .event).map { cal in
            CalendarInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                isDefault: cal.calendarIdentifier
                    == store.defaultCalendarForNewEvents?.calendarIdentifier,
                allowsModify: cal.allowsContentModifications,
                calendarType: Self.calendarTypeName(cal.type),
                sourceIdentifier: cal.source?.sourceIdentifier,
                sourceTitle: cal.source?.title,
                sourceType: cal.source.map { Self.sourceTypeName($0.sourceType) }
            )
        }
    }

    public func event(id: String) async throws -> CalendarEvent? {
        try await ensureAccess()
        guard let event = store.event(withIdentifier: id) else { return nil }
        return toEvent(event)
    }

    public func events(_ query: CalendarEventQuery) async throws -> [CalendarEvent] {
        try await ensureAccess()
        let startDate = try isoToDate(query.start)
        let endDate = try isoToDate(query.end)
        let calendars: [EKCalendar]?
        if let calendarId = query.calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw CalendarModuleError.calendarNotFound(calendarId)
            }
            calendars = [cal]
        } else {
            calendars = nil
        }
        let predicate = store.predicateForEvents(
            withStart: startDate, end: endDate, calendars: calendars)
        // Map EKEvent → Sendable CalendarEvent before returning so no
        // non-Sendable EventKit object escapes this call.
        let ek = store.events(matching: predicate)
        return ek.map(toEvent).sorted { $0.start < $1.start }
    }

    private func resolveCalendar(_ calendarId: String?) throws -> EKCalendar {
        if let calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw CalendarModuleError.calendarNotFound(calendarId)
            }
            return cal
        }
        guard let def = store.defaultCalendarForNewEvents else {
            throw CalendarModuleError.calendarNotFound("default")
        }
        return def
    }

    public func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await ensureAccess()
        guard let start = draft.start else { throw CalendarModuleError.missingRequired("start") }
        guard let end = draft.end else { throw CalendarModuleError.missingRequired("end") }
        let event = EKEvent(eventStore: store)
        event.calendar = try resolveCalendar(draft.calendarId)
        event.title = draft.title ?? ""
        event.startDate = try isoToDate(start)
        event.endDate = try isoToDate(end)
        if let allDay = draft.allDay { event.isAllDay = allDay }
        if let location = draft.location { event.location = location }
        if let notes = draft.notes { event.notes = notes }
        try applyTimeZone(draft.timeZoneIdentifier, to: event)
        try applyRecurrence(draft, to: event, replacing: true)
        try applyAlarms(draft.alarms, to: event, replacing: true)
        try store.save(event, span: .thisEvent, commit: true)
        return toEvent(event)
    }

    private func fetchEvent(id: String) throws -> EKEvent {
        if let event = store.event(withIdentifier: id) {
            return event
        }
        throw CalendarModuleError.notFound(id)
    }

    public func update(id: String, _ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await update(id: id, draft, span: .thisEvent)
    }

    public func update(id: String, _ draft: CalendarEventDraft, span: CalendarEventSpan) async throws -> CalendarEvent {
        try await ensureAccess()
        let event = try fetchEvent(id: id)
        if let title = draft.title { event.title = title }
        if let start = draft.start { event.startDate = try isoToDate(start) }
        if let end = draft.end { event.endDate = try isoToDate(end) }
        if let allDay = draft.allDay { event.isAllDay = allDay }
        if let location = draft.location { event.location = location }
        if let notes = draft.notes { event.notes = notes }
        try applyTimeZone(draft.timeZoneIdentifier, to: event)
        try applyRecurrence(draft, to: event, replacing: false)
        try applyAlarms(draft.alarms, to: event, replacing: false)
        if let calendarId = draft.calendarId {
            event.calendar = try resolveCalendar(calendarId)
        }
        try store.save(event, span: span.ekSpan, commit: true)
        return toEvent(event)
    }

    public func delete(id: String) async throws {
        try await delete(id: id, span: .thisEvent)
    }

    public func delete(id: String, span: CalendarEventSpan) async throws {
        try await ensureAccess()
        let event = try fetchEvent(id: id)
        try store.remove(event, span: span.ekSpan, commit: true)
    }

    private func applyTimeZone(_ identifier: String?, to event: EKEvent) throws {
        guard let identifier else { return }
        if identifier.isEmpty {
            event.timeZone = nil
            return
        }
        guard let zone = TimeZone(identifier: identifier) else {
            throw CalendarModuleError.invalidTimeZone(identifier)
        }
        event.timeZone = zone
    }

    private func applyRecurrence(_ draft: CalendarEventDraft, to event: EKEvent, replacing: Bool) throws {
        guard let freqRaw = draft.recurrenceFreq else {
            if replacing { return }
            return
        }
        if freqRaw.isEmpty {
            event.recurrenceRules = nil
            return
        }
        guard let rule = Self.buildRecurrenceRule(draft) else {
            throw CalendarModuleError.missingRequired("recurrenceFreq")
        }
        event.recurrenceRules = [rule]
    }

    private func applyAlarms(_ drafts: [AlarmDraft]?, to event: EKEvent, replacing: Bool) throws {
        guard let drafts else { return }
        if drafts.isEmpty {
            event.alarms = []
            return
        }
        event.alarms = drafts.compactMap { d in
            switch d.type.lowercased() {
            case "relative":
                let minutes = d.triggerMinutesBefore ?? 0
                return EKAlarm(relativeOffset: TimeInterval(-60 * minutes))
            case "absolute":
                guard let iso = d.triggerAbsoluteDate, let date = try? CalendarISOParsing.parse(iso) else {
                    return nil
                }
                return EKAlarm(absoluteDate: date)
            default:
                return nil
            }
        }
        _ = replacing
    }

    static func buildRecurrenceRule(_ draft: CalendarEventDraft) -> EKRecurrenceRule? {
        guard let freqRaw = draft.recurrenceFreq, !freqRaw.isEmpty else { return nil }
        let frequency: EKRecurrenceFrequency
        switch freqRaw.lowercased() {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: return nil
        }
        let interval = max(1, draft.recurrenceInterval ?? 1)
        var end: EKRecurrenceEnd?
        if let count = draft.recurrenceCount, count > 0 {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else if let endRaw = draft.recurrenceEndDate, !endRaw.isEmpty,
                  let endDate = try? CalendarISOParsing.parse(endRaw) {
            end = EKRecurrenceEnd(end: endDate)
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
    }

    static func serializeRule(_ rule: EKRecurrenceRule?) -> String? {
        guard let rule else { return nil }
        let freq: String
        switch rule.frequency {
        case .daily: freq = "daily"
        case .weekly: freq = "weekly"
        case .monthly: freq = "monthly"
        case .yearly: freq = "yearly"
        @unknown default: freq = "daily"
        }
        var parts = ["\(freq);interval:\(rule.interval)"]
        if let end = rule.recurrenceEnd {
            if end.occurrenceCount > 0 {
                parts.append("count:\(end.occurrenceCount)")
            } else if let until = end.endDate {
                parts.append("until:\(makeISO().string(from: until))")
            }
        }
        return parts.joined(separator: ";")
    }

    static func serializeAlarms(_ alarms: [EKAlarm]?) -> [AlarmItem] {
        guard let alarms, !alarms.isEmpty else { return [] }
        return alarms.enumerated().map { idx, alarm in
            if let absolute = alarm.absoluteDate {
                return AlarmItem(
                    id: "alarm-\(idx)",
                    type: "absolute",
                    triggerAbsoluteDate: makeISO().string(from: absolute)
                )
            }
            return AlarmItem(
                id: "alarm-\(idx)",
                type: "relative",
                triggerMinutesBefore: Int((-alarm.relativeOffset) / 60.0)
            )
        }
    }
}

// MARK: - CalendarModule

/// Provides EventKit-backed calendar tools through an injectable store seam.
public enum CalendarModule {

    public static let moduleName = "calendar"

    /// Register all CalendarModule tools on the given router. `store`
    /// defaults to the live EventKit store; tests inject a mock seam.
    public static func register(
        on router: ToolRouter,
        store: CalendarStoring = EventKitCalendarStore()
    ) async {

        // MARK: 1. calendar_list – open (read-only)
        await router.register(ToolRegistration(
            name: "calendar_list",
            module: moduleName,
            tier: .open,
            description: "Enumerate Calendar calendars (EKCalendar of type .event). Returns id, title, isDefault, allowsModify. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let cals = try await store.calendars()
                return .object([
                    "count": .int(cals.count),
                    "calendars": .array(cals.map(formatCalendar))
                ])
            }
        ))

        // MARK: 2. calendar_events – open (read-only)
        await router.register(ToolRegistration(
            name: "calendar_events",
            module: moduleName,
            tier: .open,
            description: "List calendar events within a date range. Requires start + end (ISO-8601); optional calendarId scopes to one calendar (default: all). Returns local event identity plus providerExternalId and itemURL when available. `compact: true` trims each event to id/title/start/end; `limit` caps the count (default 50) to stay under token caps — `has_more`/`truncated` flag when the range held more. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "start": .object(["type": .string("string"), "description": .string("ISO-8601 range lower bound (required)")]),
                    "end": .object(["type": .string("string"), "description": .string("ISO-8601 range upper bound (required)")]),
                    "calendarId": .object(["type": .string("string"), "description": .string("EKCalendar.calendarIdentifier to scope to a single calendar (default: all event calendars)")]),
                    "compact": .object(["type": .string("boolean"), "description": .string("When true, each event is id/title/start/end only (drops allDay, calendar, location, notes) — the smallest shape for dense ranges. Default false.")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max events to return (default 50, max 500). Earliest-first; surplus is dropped and flagged via has_more/truncated. Narrow start/end or raise limit for more.")])
                ]),
                "required": .array([.string("start"), .string("end")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let start = stringArg(args, "start") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_events", reason: "missing 'start'")
                }
                guard let end = stringArg(args, "end") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_events", reason: "missing 'end'")
                }
                let query = CalendarEventQuery(
                    start: start,
                    end: end,
                    calendarId: stringArg(args, "calendarId")
                )
                let compact = boolArg(args, "compact") ?? false
                // fb-resultsize: cap the result set so a wide range can't blow
                // token caps. Default 50, clamped to [1, 500].
                let limit = max(1, min(intArg(args, "limit") ?? 50, 500))

                let allEvents = try await store.events(query)
                // Earliest-first so the cap keeps the most relevant window.
                let ordered = allEvents.sorted { $0.start < $1.start }
                let truncated = ordered.count > limit
                let page = Array(ordered.prefix(limit))

                var resultObj: [String: Value] = [
                    "count": .int(page.count),
                    "events": .array(page.map { compact ? formatEventCompact($0) : formatEvent($0) })
                ]
                if truncated {
                    resultObj["totalInRange"] = .int(ordered.count)
                    resultObj["has_more"] = .bool(true)
                    resultObj["truncated"] = .bool(true)
                }
                return .object(resultObj)
            }
        ))

        // MARK: 3. calendar_free_busy – open (read-only overlap check)
        await router.register(ToolRegistration(
            name: "calendar_free_busy",
            module: moduleName,
            tier: .open,
            description: "Read-only FOCUS EventKit occupancy check. Occupancy SSOT is the FOCUS calendar (A33CAC6E-9D15-44F4-BC35-54F204F4DA39) only — not Meetings, not Google Meetings freeBusy / suggest_time (isaiah@kup.solutions). Given a candidate invite window [start, end) (ISO-8601; end exclusive), list busy events on FOCUS that overlap that window. `overlaps` is true iff any busy interval overlaps; `overlappingEventIds` lists those event ids. calendarId is optional and must be the FOCUS id when supplied. Fail-closed: non-FOCUS calendarId, missing FOCUS calendar, or denied Calendar permission throws (never returns empty busy that looks free). Does not create, update, or delete events; no Notion or Google writes. When to use: check whether a proposed meeting window is free against FOCUS blocks. Not for: Meetings freeBusy, sending invites, Notion writes, or Google Calendar writes. Related: calendar_events, calendar_list.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "start": .object(["type": .string("string"), "description": .string("ISO-8601 candidate window start (required; inclusive)")]),
                    "end": .object(["type": .string("string"), "description": .string("ISO-8601 candidate window end (required; exclusive)")]),
                    "calendarId": .object(["type": .string("string"), "description": .string("Must be the FOCUS EventKit id A33CAC6E-9D15-44F4-BC35-54F204F4DA39 when supplied. Default: that FOCUS id. Meetings / other calendars are rejected.")])
                ]),
                "required": .array([.string("start"), .string("end")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let start = stringArg(args, "start") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_free_busy", reason: "missing 'start'")
                }
                guard let end = stringArg(args, "end") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_free_busy", reason: "missing 'end'")
                }
                let calendarId = try CalendarFreeBusy.resolveCalendarId(stringArg(args, "calendarId"))
                let windowStart = try CalendarISOParsing.parse(start)
                let windowEnd = try CalendarISOParsing.parse(end)
                // Fail closed on inverted windows before any store read.
                try CalendarFreeBusy.requirePositiveRange(
                    windowStart: windowStart,
                    windowEnd: windowEnd
                )
                // Prove the calendar exists (and that TCC is granted) before
                // treating an empty event list as "free".
                let calendars = try await store.calendars()
                try CalendarFreeBusy.requireKnownCalendar(id: calendarId, calendars: calendars)
                let query = CalendarEventQuery(
                    start: start,
                    end: end,
                    calendarId: calendarId
                )
                let events = try await store.events(query)
                let check = try CalendarFreeBusy.evaluate(
                    events: events,
                    windowStart: windowStart,
                    windowEnd: windowEnd
                )
                return .object([
                    "calendarId": .string(calendarId),
                    "busy": .array(check.busy.map { item in
                        .object([
                            "id": .string(item.id),
                            "title": .string(item.title),
                            "start": .string(item.start),
                            "end": .string(item.end)
                        ])
                    }),
                    "overlaps": .bool(check.overlaps),
                    "overlappingEventIds": .array(check.overlappingEventIds.map(Value.string))
                ])
            }
        ))

        // MARK: 4. calendar_create – notify (write, non-destructive)
        await router.register(ToolRegistration(
            name: "calendar_create",
            module: moduleName,
            tier: .notify,
            description: "Create a calendar event. Requires title, start, end (ISO-8601); optional allDay, calendarId, location, notes, timeZoneIdentifier (IANA), recurrence (freq/interval/end/count), alarms (relative minutes-before-start or absolute). Returns the new event id + record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("Event title (required)")]),
                    "start": .object(["type": .string("string"), "description": .string("Start ISO-8601 (required)")]),
                    "end": .object(["type": .string("string"), "description": .string("End ISO-8601 (required)")]),
                    "allDay": .object(["type": .string("boolean"), "description": .string("All-day event (default: false)")]),
                    "calendarId": .object(["type": .string("string"), "description": .string("Target calendar identifier (default: the default Calendar for new events)")]),
                    "location": .object(["type": .string("string"), "description": .string("Location (optional)")]),
                    "notes": .object(["type": .string("string"), "description": .string("Freeform notes (optional)")]),
                    "timeZoneIdentifier": .object(["type": .string("string"), "description": .string("IANA time zone (e.g. America/Chicago). Invalid identifiers fail closed.")]),
                    "recurrenceFreq": .object(["type": .string("string"), "description": .string("Repeat frequency: daily | weekly | monthly | yearly")]),
                    "recurrenceInterval": .object(["type": .string("integer"), "description": .string("Repeat interval (default 1)")]),
                    "recurrenceEndDate": .object(["type": .string("string"), "description": .string("Optional ISO-8601 end of series")]),
                    "recurrenceCount": .object(["type": .string("integer"), "description": .string("Optional occurrence count")]),
                    "alarms": .object(["type": .string("array"), "description": .string("Relative (minutes before start) or absolute alarms. Geofence omitted in v1.")])
                ]),
                "required": .array([.string("title"), .string("start"), .string("end")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let title = stringArg(args, "title") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_create", reason: "missing 'title'")
                }
                guard let start = stringArg(args, "start") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_create", reason: "missing 'start'")
                }
                guard let end = stringArg(args, "end") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_create", reason: "missing 'end'")
                }
                try validateTimeZone(stringArg(args, "timeZoneIdentifier"))
                try validateRecurrenceFreq(stringArg(args, "recurrenceFreq"))
                let draft = CalendarEventDraft(
                    title: title,
                    start: start,
                    end: end,
                    allDay: boolArg(args, "allDay"),
                    calendarId: stringArg(args, "calendarId"),
                    location: stringArg(args, "location"),
                    notes: stringArg(args, "notes"),
                    timeZoneIdentifier: stringArg(args, "timeZoneIdentifier"),
                    recurrenceFreq: stringArg(args, "recurrenceFreq"),
                    recurrenceInterval: intArg(args, "recurrenceInterval"),
                    recurrenceEndDate: stringArg(args, "recurrenceEndDate"),
                    recurrenceCount: intArg(args, "recurrenceCount"),
                    alarms: parseAlarmArray(args, "alarms")
                )
                let event = try await store.create(draft)
                return .object([
                    "id": .string(event.id),
                    "event": formatEvent(event)
                ])
            }
        ))

        // MARK: 5. calendar_update – notify (write, non-destructive)
        await router.register(ToolRegistration(
            name: "calendar_update",
            module: moduleName,
            tier: .notify,
            description: "Update a calendar event by id. Any of title, start, end, allDay, location, notes, calendarId, timeZoneIdentifier, recurrence, alarms. Optional span thisEvent (default) or futureEvents for a series. recurrenceFreq \"\" clears recurrence; alarms [] clears alarms. Returns the updated record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("EKEvent.eventIdentifier (required)")]),
                    "title": .object(["type": .string("string"), "description": .string("New title")]),
                    "start": .object(["type": .string("string"), "description": .string("New start ISO-8601")]),
                    "end": .object(["type": .string("string"), "description": .string("New end ISO-8601")]),
                    "allDay": .object(["type": .string("boolean"), "description": .string("Set all-day flag")]),
                    "calendarId": .object(["type": .string("string"), "description": .string("Move to a different calendar")]),
                    "location": .object(["type": .string("string"), "description": .string("New location")]),
                    "notes": .object(["type": .string("string"), "description": .string("New notes")]),
                    "timeZoneIdentifier": .object(["type": .string("string"), "description": .string("IANA time zone; empty string clears")]),
                    "recurrenceFreq": .object(["type": .string("string"), "description": .string("daily | weekly | monthly | yearly; empty string clears")]),
                    "recurrenceInterval": .object(["type": .string("integer"), "description": .string("Repeat interval")]),
                    "recurrenceEndDate": .object(["type": .string("string"), "description": .string("ISO-8601 end of series")]),
                    "recurrenceCount": .object(["type": .string("integer"), "description": .string("Occurrence count")]),
                    "alarms": .object(["type": .string("array"), "description": .string("Replace alarms; [] clears. Relative offset is from event start.")]),
                    "span": .object(["type": .string("string"), "description": .string("thisEvent (default) or futureEvents when the event is a series")])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_update", reason: "missing 'id'")
                }
                try validateTimeZone(stringArg(args, "timeZoneIdentifier"))
                try validateRecurrenceFreq(stringArg(args, "recurrenceFreq"))
                let span = try CalendarEventSpan.parse(stringArg(args, "span"))
                let draft = CalendarEventDraft(
                    title: stringArg(args, "title"),
                    start: stringArg(args, "start"),
                    end: stringArg(args, "end"),
                    allDay: boolArg(args, "allDay"),
                    calendarId: stringArg(args, "calendarId"),
                    location: stringArg(args, "location"),
                    notes: stringArg(args, "notes"),
                    timeZoneIdentifier: stringArg(args, "timeZoneIdentifier"),
                    recurrenceFreq: stringArg(args, "recurrenceFreq"),
                    recurrenceInterval: intArg(args, "recurrenceInterval"),
                    recurrenceEndDate: stringArg(args, "recurrenceEndDate"),
                    recurrenceCount: intArg(args, "recurrenceCount"),
                    alarms: parseAlarmArray(args, "alarms")
                )
                let event = try await store.update(id: id, draft, span: span)
                return .object([
                    "id": .string(event.id),
                    "event": formatEvent(event),
                    "span": .string(span.rawValue)
                ])
            }
        ))

        // MARK: 6. calendar_delete – request (DESTRUCTIVE)
        await router.register(ToolRegistration(
            name: "calendar_delete",
            module: moduleName,
            tier: .request,
            description: "Delete a calendar event by id. DESTRUCTIVE / irreversible — gated at tier .request (confirmation required). Optional span thisEvent (default) or futureEvents for a series. Returns the deleted id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("EKEvent.eventIdentifier (required)")]),
                    "span": .object(["type": .string("string"), "description": .string("thisEvent (default) or futureEvents")])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_delete", reason: "missing 'id'")
                }
                let span = try CalendarEventSpan.parse(stringArg(args, "span"))
                try await store.delete(id: id, span: span)
                return .object([
                    "id": .string(id),
                    "deleted": .bool(true),
                    "span": .string(span.rawValue)
                ])
            }
        ))
    }

    // MARK: - Formatting

    static func formatCalendar(_ cal: CalendarInfo) -> Value {
        .object([
            "id": .string(cal.id),
            "title": .string(cal.title),
            "isDefault": .bool(cal.isDefault),
            "allowsModify": .bool(cal.allowsModify)
        ])
    }

    static func formatEvent(_ event: CalendarEvent) -> Value {
        var entry: [String: Value] = [
            "id": .string(event.id),
            "title": .string(event.title),
            "start": .string(event.start),
            "end": .string(event.end),
            "allDay": .bool(event.allDay),
            "calendarId": .string(event.calendarId),
            "calendar": .string(event.calendarTitle)
        ]
        if let location = event.location { entry["location"] = .string(location) }
        if let notes = event.notes { entry["notes"] = .string(notes) }
        if let timeZone = event.timeZoneIdentifier { entry["timeZone"] = .string(timeZone) }
        if let externalId = event.externalId { entry["providerExternalId"] = .string(externalId) }
        if let organizer = event.organizer { entry["organizer"] = .string(organizer) }
        if !event.attendees.isEmpty { entry["attendees"] = .array(event.attendees.map(Value.string)) }
        if let url = event.conferenceURL { entry["itemURL"] = .string(url) }
        if let modified = event.lastModified { entry["lastModified"] = .string(modified) }
        entry["isRecurring"] = .bool(event.isRecurring)
        entry["isDetached"] = .bool(event.isDetached)
        if let rule = event.recurrenceRule { entry["recurrenceRule"] = .string(rule) }
        if !event.alarms.isEmpty {
            entry["alarms"] = .array(event.alarms.map { alarm in
                var item: [String: Value] = [
                    "id": .string(alarm.id),
                    "type": .string(alarm.type)
                ]
                if let minutes = alarm.triggerMinutesBefore { item["triggerMinutesBefore"] = .int(minutes) }
                if let abs = alarm.triggerAbsoluteDate { item["triggerAbsoluteDate"] = .string(abs) }
                return .object(item)
            })
        }
        return .object(entry)
    }

    /// fb-resultsize: minimal event shape — id/title/start/end only — for
    /// `calendar_events` compact mode. Drops allDay/calendar/location/notes
    /// so dense ranges stay well under token caps.
    static func formatEventCompact(_ event: CalendarEvent) -> Value {
        .object([
            "id": .string(event.id),
            "title": .string(event.title),
            "start": .string(event.start),
            "end": .string(event.end)
        ])
    }

    // MARK: - Argument helpers

    private static func objectArgs(_ value: Value) -> [String: Value] {
        if case .object(let args) = value { return args }
        return [:]
    }

    private static func stringArg(_ args: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = args[key] { return s }
        return nil
    }

    private static func boolArg(_ args: [String: Value], _ key: String) -> Bool? {
        if case .bool(let b)? = args[key] { return b }
        return nil
    }

    private static func intArg(_ args: [String: Value], _ key: String) -> Int? {
        if case .int(let n)? = args[key] { return n }
        if case .double(let d)? = args[key] { return Int(d) }
        return nil
    }

    static func validateTimeZone(_ identifier: String?) throws {
        guard let identifier, !identifier.isEmpty else { return }
        guard TimeZone(identifier: identifier) != nil else {
            throw CalendarModuleError.invalidTimeZone(identifier)
        }
    }

    static func validateRecurrenceFreq(_ freq: String?) throws {
        guard let freq, !freq.isEmpty else { return }
        switch freq.lowercased() {
        case "daily", "weekly", "monthly", "yearly": return
        default:
            throw ToolRouterError.invalidArguments(
                toolName: "calendar_create",
                reason: "recurrenceFreq must be daily, weekly, monthly, or yearly"
            )
        }
    }

    static func parseAlarmArray(_ args: [String: Value], _ key: String) -> [AlarmDraft]? {
        guard case .array(let arr)? = args[key] else { return nil }
        return arr.compactMap { element in
            guard case .object(let obj) = element, let type = stringArg(obj, "type") else { return nil }
            return AlarmDraft(
                type: type,
                triggerMinutesBefore: intArg(obj, "triggerMinutesBefore"),
                triggerAbsoluteDate: stringArg(obj, "triggerAbsoluteDate")
            )
        }
    }
}
