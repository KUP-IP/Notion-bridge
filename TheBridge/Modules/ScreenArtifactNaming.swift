// ScreenArtifactNaming.swift — #256 Time Keepr–style Bridge screen filenames
// TheBridge · Modules
//
// Locked contract:
//   b-{ISOWeek}.{ISOWeekday}-{NN}.{ext}
// Example Fri 2026-09-04 (ISO week 36, weekday 5): b-36.5-01.png
// Next same local day, any type: b-36.5-02.mp4 (shared counter; type is extension).
//
// Rules:
//   - Prefix `b-` (Bridge)
//   - Week = ISO-8601 week number (same as Time Keepr calendar titles)
//   - Weekday = ISO weekday Mon=1 … Sun=7 (same as Time Keepr)
//   - Sequence NN = zero-padded decimal, SHARED per local calendar day across
//     screenshots (.png/.jpg) AND recordings (.mp4)
//   - Day boundary + ISO week/day use the Mac local calendar (injectable
//     TimeZone / Calendar in tests — never `Date()` UTC by itself)
//   - Legacy epoch names are left on disk (no migrate) and ignored by the
//     counter and by cleanup
//
// Retention (#256): keep every same-day `b-W.D-NN.*` file. The old 1-hour
// same-day wipe is gone so 01…NN stay useful mid-day. Previous local calendar
// days' `b-*` files are deleted on the next `screen_capture` (end-of-day).
// There is no newest-N cap on today.

import Foundation

/// Pure (injectable) naming + cleanup for screen captures and recordings.
public enum ScreenArtifactNaming {

    public static let filenamePrefix = "b-"
    public static let sequenceWidth = 2

    public struct DayKey: Sendable, Equatable {
        public let isoWeek: Int
        public let isoWeekday: Int

        public var stem: String { "\(isoWeek).\(isoWeekday)" }

        public init(isoWeek: Int, isoWeekday: Int) {
            self.isoWeek = isoWeek
            self.isoWeekday = isoWeekday
        }
    }

    public struct ParsedName: Sendable, Equatable {
        public let isoWeek: Int
        public let isoWeekday: Int
        public let sequence: Int
        public let ext: String

        public var day: DayKey { DayKey(isoWeek: isoWeek, isoWeekday: isoWeekday) }

        public init(isoWeek: Int, isoWeekday: Int, sequence: Int, ext: String) {
            self.isoWeek = isoWeek
            self.isoWeekday = isoWeekday
            self.sequence = sequence
            self.ext = ext
        }
    }

    private static let allocationLock = NSLock()

    /// ISO-8601 calendar bound to an injectable time zone (Mac local in production).
    public static func isoCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Gregorian civil calendar for local midnight / same-day checks.
    public static func civilCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// ISO week + ISO weekday (Mon=1 … Sun=7) for `date` in `timeZone`.
    ///
    /// Week comes from the ISO-8601 calendar. Weekday is derived from the
    /// Gregorian Sunday=1 convention so tests do not depend on whether a given
    /// Foundation build reports ISO `weekday` as Monday-first.
    public static func dayKey(for date: Date, timeZone: TimeZone = .current) -> DayKey {
        let iso = isoCalendar(timeZone: timeZone)
        let week = iso.component(.weekOfYear, from: date)

        let civil = civilCalendar(timeZone: timeZone)
        let sundayBased = civil.component(.weekday, from: date) // 1=Sun … 7=Sat
        let isoWeekday = sundayBased == 1 ? 7 : sundayBased - 1
        return DayKey(isoWeek: week, isoWeekday: isoWeekday)
    }

    public static func filename(day: DayKey, sequence: Int, ext: String) -> String {
        let padded = String(format: "%0\(sequenceWidth)d", sequence)
        return "\(filenamePrefix)\(day.stem)-\(padded).\(ext)"
    }

    /// Parse `b-W.D-NN.ext`. Rejects legacy epoch names and any other prefix.
    public static func parse(_ filename: String) -> ParsedName? {
        guard filename.hasPrefix(filenamePrefix) else { return nil }
        let rest = filename.dropFirst(filenamePrefix.count)
        guard let weekDot = rest.firstIndex(of: ".") else { return nil }
        let weekStr = rest[..<weekDot]
        let afterWeek = rest[rest.index(after: weekDot)...]
        guard let dash = afterWeek.firstIndex(of: "-") else { return nil }
        let weekdayStr = afterWeek[..<dash]
        let afterDash = afterWeek[afterWeek.index(after: dash)...]
        guard let extDot = afterDash.lastIndex(of: ".") else { return nil }
        let seqStr = afterDash[..<extDot]
        let ext = afterDash[afterDash.index(after: extDot)...]

        guard weekStr.allSatisfy(\.isNumber),
              let week = Int(weekStr), (1...53).contains(week) else { return nil }
        guard weekdayStr.allSatisfy(\.isNumber),
              let weekday = Int(weekdayStr), (1...7).contains(weekday) else { return nil }
        guard !seqStr.isEmpty, seqStr.allSatisfy(\.isNumber),
              let sequence = Int(seqStr), sequence >= 1 else { return nil }
        // png/jpg/mp4 — digits are allowed so `.mp4` parses (not letters-only).
        guard !ext.isEmpty, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return ParsedName(
            isoWeek: week,
            isoWeekday: weekday,
            sequence: sequence,
            ext: String(ext)
        )
    }

    /// Next sequence for `day` from an in-memory directory listing.
    /// Legacy epoch names and other files are ignored.
    public static func nextSequence(existingNames: [String], day: DayKey) -> Int {
        let maxSeq = existingNames.compactMap(parse)
            .filter { $0.day == day }
            .map(\.sequence)
            .max() ?? 0
        return maxSeq + 1
    }

    public static func nextSequence(
        in directory: String,
        day: DayKey,
        fileManager: FileManager = .default
    ) -> Int {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        return nextSequence(existingNames: names, day: day)
    }

    /// Allocate `directory/b-W.D-NN.ext`, scanning the dir so the counter
    /// survives relaunch. Skips an occupied path (race / leftover).
    public static func allocatePath(
        directory: String,
        ext: String,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) -> String {
        allocationLock.lock()
        defer { allocationLock.unlock() }

        let day = dayKey(for: now, timeZone: timeZone)
        var sequence = nextSequence(in: directory, day: day, fileManager: fileManager)
        var name = filename(day: day, sequence: sequence, ext: ext)
        var path = (directory as NSString).appendingPathComponent(name)
        while fileManager.fileExists(atPath: path) {
            sequence += 1
            name = filename(day: day, sequence: sequence, ext: ext)
            path = (directory as NSString).appendingPathComponent(name)
        }
        return path
    }

    /// End-of-day retention for `b-W.D-NN.*` in `directory`.
    ///
    /// - Never deletes today's files (filename stem matches `now` in `timeZone`).
    ///   Host clock and file mtime are not consulted — tests inject Chicago.
    ///   The old 1-hour same-day wipe is gone so 01…NN stay useful mid-day.
    /// - Deletes prior local-calendar-day `b-*` files on the next cleanup.
    /// - Leaves legacy epoch names and unrelated files untouched.
    public static func cleanup(
        in directory: String,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory)
        } catch {
            return
        }

        // "Today" is the ISO week.day of `now` in `timeZone` — not the host
        // clock and not file mtime — so tests can pin America/Chicago.
        let today = dayKey(for: now, timeZone: timeZone)

        for name in names {
            guard let parsed = parse(name) else { continue }
            if parsed.day == today { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            try? fileManager.removeItem(atPath: path)
        }
    }
}
