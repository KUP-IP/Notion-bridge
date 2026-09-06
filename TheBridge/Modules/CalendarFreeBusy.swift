// CalendarFreeBusy.swift — v0 read-only FOCUS free/busy + overlap check
// TheBridge · Modules
//
// Pure overlap evaluator for `calendar_free_busy`. Half-open window
// semantics: a candidate invite occupies [start, end). An EventKit busy
// interval overlaps that window iff eventStart < windowEnd AND
// eventEnd > windowStart. Touching edges (event ends exactly when the
// window starts, or starts exactly when the window ends) do not overlap.
//
// Isaiah GO 2026-09-06: EventKit path only. No calendar/Notion/Google writes.

import Foundation

/// Read-only free/busy overlap check over already-fetched EventKit events.
public enum CalendarFreeBusy {

    /// FOCUS EventKit calendar identifier — v0 occupancy SSOT
    /// (ISAIAH Keepr live probe 2026-09-06). Meetings calendar /
    /// Google `suggest_time` / `freeBusy` on Meetings
    /// (isaiah@kup.solutions) is out of scope: that surface offered
    /// Mon 9:15–17:00 as free over SLAY/LIFT FOCUS blocks.
    public static let focusCalendarId = "A33CAC6E-9D15-44F4-BC35-54F204F4DA39"

    /// Resolve occupancy calendar. Omitted / blank / exact FOCUS id → FOCUS.
    /// Any other id (Meetings, Home, …) throws `occupancyNotFocus`.
    /// Never returns an empty id (that would silently scan every calendar).
    public static func resolveCalendarId(_ raw: String?) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == focusCalendarId {
            return focusCalendarId
        }
        throw CalendarModuleError.occupancyNotFocus(trimmed)
    }

    /// Fail closed unless the target calendar is present in the store list.
    /// A missing calendar must not be reported as "free" (empty busy).
    public static func requireKnownCalendar(id: String, calendars: [CalendarInfo]) throws {
        guard calendars.contains(where: { $0.id == id }) else {
            throw CalendarModuleError.calendarNotFound(id)
        }
    }

    /// Compact busy interval returned to MCP callers.
    public struct BusyEvent: Sendable, Equatable {
        public let id: String
        public let title: String
        public let start: String
        public let end: String

        public init(id: String, title: String, start: String, end: String) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
        }
    }

    /// Result of evaluating a candidate window against a busy-event fixture.
    public struct Check: Sendable, Equatable {
        public let busy: [BusyEvent]
        public let overlaps: Bool
        public let overlappingEventIds: [String]

        public init(busy: [BusyEvent], overlaps: Bool, overlappingEventIds: [String]) {
            self.busy = busy
            self.overlaps = overlaps
            self.overlappingEventIds = overlappingEventIds
        }
    }

    /// Half-open overlap: `[eventStart, eventEnd)` intersects
    /// `[windowStart, windowEnd)` iff `eventStart < windowEnd && eventEnd > windowStart`.
    public static func intervalsOverlap(
        eventStart: Date,
        eventEnd: Date,
        windowStart: Date,
        windowEnd: Date
    ) -> Bool {
        eventStart < windowEnd && eventEnd > windowStart
    }

    /// Fail closed unless the candidate window is a positive half-open range.
    public static func requirePositiveRange(windowStart: Date, windowEnd: Date) throws {
        guard windowStart < windowEnd else {
            throw CalendarModuleError.invertedRange
        }
    }

    /// Filter `events` to those whose parsed `[start, end)` overlaps the
    /// candidate window. Throws `invertedRange` when `windowStart >= windowEnd`.
    public static func evaluate(
        events: [CalendarEvent],
        windowStart: Date,
        windowEnd: Date
    ) throws -> Check {
        try requirePositiveRange(windowStart: windowStart, windowEnd: windowEnd)
        let busy: [BusyEvent] = try events
            .sorted { $0.start < $1.start }
            .compactMap { event in
                let eventStart = try CalendarISOParsing.parse(event.start)
                let eventEnd = try CalendarISOParsing.parse(event.end)
                guard intervalsOverlap(
                    eventStart: eventStart,
                    eventEnd: eventEnd,
                    windowStart: windowStart,
                    windowEnd: windowEnd
                ) else {
                    return nil
                }
                return BusyEvent(
                    id: event.id,
                    title: event.title,
                    start: event.start,
                    end: event.end
                )
            }
        return Check(
            busy: busy,
            overlaps: !busy.isEmpty,
            overlappingEventIds: busy.map(\.id)
        )
    }
}
