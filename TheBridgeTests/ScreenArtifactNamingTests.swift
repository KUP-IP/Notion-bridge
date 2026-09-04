// ScreenArtifactNamingTests.swift — #256 Time Keepr–style b-W.D-NN names
// TheBridge · Tests
//
// Hermetic: injectable TimeZone / Calendar and temp directories. Never
// depends on UTC `Date()` or the operator Desktop.

import Foundation
import TheBridgeLib

private let chicago = TimeZone(identifier: "America/Chicago")!
private let utc = TimeZone(identifier: "UTC")!

private func civilDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 12,
    minute: Int = 0,
    timeZone: TimeZone
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = DateComponents(
        timeZone: timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    )
    return calendar.date(from: parts)!
}

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-b-naming-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func touch(_ dir: URL, _ name: String, mtime: Date? = nil) throws {
    let url = dir.appendingPathComponent(name)
    try Data().write(to: url)
    if let mtime {
        try FileManager.default.setAttributes(
            [.modificationDate: mtime],
            ofItemAtPath: url.path
        )
    }
}

func runScreenArtifactNamingTests() async {
    print("\n📸 ScreenArtifactNaming Tests (#256)")

    await test("Friday 2026-09-04 Chicago is ISO week 36 weekday 5") {
        let date = civilDate(2026, 9, 4, timeZone: chicago)
        let day = ScreenArtifactNaming.dayKey(for: date, timeZone: chicago)
        try expect(day.isoWeek == 36, "week: \(day.isoWeek)")
        try expect(day.isoWeekday == 5, "weekday: \(day.isoWeekday)")
        try expect(day.stem == "36.5")
        try expect(ScreenArtifactNaming.filename(day: day, sequence: 1, ext: "png") == "b-36.5-01.png")
    }

    await test("Sunday 2026-09-06 Chicago is ISO weekday 7") {
        let date = civilDate(2026, 9, 6, timeZone: chicago)
        let day = ScreenArtifactNaming.dayKey(for: date, timeZone: chicago)
        try expect(day.isoWeek == 36, "week: \(day.isoWeek)")
        try expect(day.isoWeekday == 7, "Sunday must be 7, got \(day.isoWeekday)")
        try expect(ScreenArtifactNaming.filename(day: day, sequence: 1, ext: "jpg") == "b-36.7-01.jpg")
    }

    await test("Year-boundary Monday 2024-12-30 Chicago is ISO week 1 weekday 1") {
        let date = civilDate(2024, 12, 30, timeZone: chicago)
        let day = ScreenArtifactNaming.dayKey(for: date, timeZone: chicago)
        try expect(day.isoWeek == 1, "ISO week 1 of 2025 starts Mon 2024-12-30, got \(day.isoWeek)")
        try expect(day.isoWeekday == 1, "Monday must be 1, got \(day.isoWeekday)")
        try expect(ScreenArtifactNaming.filename(day: day, sequence: 1, ext: "png") == "b-1.1-01.png")
    }

    await test("Year-boundary Sunday 2024-12-29 Chicago is ISO week 52 weekday 7") {
        let date = civilDate(2024, 12, 29, timeZone: chicago)
        let day = ScreenArtifactNaming.dayKey(for: date, timeZone: chicago)
        try expect(day.isoWeek == 52, "week: \(day.isoWeek)")
        try expect(day.isoWeekday == 7, "weekday: \(day.isoWeekday)")
        try expect(ScreenArtifactNaming.filename(day: day, sequence: 2, ext: "mp4") == "b-52.7-02.mp4")
    }

    await test("Thursday 2026-12-31 Chicago is ISO week 53 weekday 4") {
        let date = civilDate(2026, 12, 31, timeZone: chicago)
        let day = ScreenArtifactNaming.dayKey(for: date, timeZone: chicago)
        try expect(day.isoWeek == 53, "week: \(day.isoWeek)")
        try expect(day.isoWeekday == 4, "weekday: \(day.isoWeekday)")
        try expect(ScreenArtifactNaming.filename(day: day, sequence: 1, ext: "png") == "b-53.4-01.png")
    }

    await test("ISO week/day uses injected local zone, not UTC") {
        // 2026-09-04 04:30 UTC = 2026-09-03 23:30 CDT (Thursday).
        let instant = civilDate(2026, 9, 4, hour: 4, minute: 30, timeZone: utc)
        let chicagoDay = ScreenArtifactNaming.dayKey(for: instant, timeZone: chicago)
        let utcDay = ScreenArtifactNaming.dayKey(for: instant, timeZone: utc)
        try expect(chicagoDay.isoWeek == 36 && chicagoDay.isoWeekday == 4,
                   "Chicago must still be Thursday 36.4, got \(chicagoDay.stem)")
        try expect(utcDay.isoWeek == 36 && utcDay.isoWeekday == 5,
                   "UTC is Friday 36.5, got \(utcDay.stem)")
    }

    await test("Filename zero-pads sequence and leaves week unpadded") {
        let day = ScreenArtifactNaming.DayKey(isoWeek: 1, isoWeekday: 7)
        try expect(ScreenArtifactNaming.filename(day: day, sequence: 1, ext: "png") == "b-1.7-01.png")
        try expect(ScreenArtifactNaming.filename(day: day, sequence: 10, ext: "mp4") == "b-1.7-10.mp4")
        try expect(ScreenArtifactNaming.filename(day: day, sequence: 100, ext: "jpg") == "b-1.7-100.jpg")
    }

    await test("Parse accepts contract names and rejects leftover epoch names") {
        let parsed = ScreenArtifactNaming.parse("b-36.5-01.png")
        try expect(parsed == ScreenArtifactNaming.ParsedName(
            isoWeek: 36, isoWeekday: 5, sequence: 1, ext: "png"
        ))
        try expect(ScreenArtifactNaming.parse("b-36.5-02.mp4") == ScreenArtifactNaming.ParsedName(
            isoWeek: 36, isoWeekday: 5, sequence: 2, ext: "mp4"
        ), "mp4 must parse — the digit in the extension is legal")
        try expect(ScreenArtifactNaming.parse("nb-screen-1710000000000.png") == nil)
        try expect(ScreenArtifactNaming.parse("nb-screen-fixture.png") == nil)
        try expect(ScreenArtifactNaming.parse("b-36.5.png") == nil)
        try expect(ScreenArtifactNaming.parse("screenshot.png") == nil)
        try expect(ScreenArtifactNaming.parse("b-36.8-01.png") == nil)
        try expect(ScreenArtifactNaming.parse("b-0.5-01.png") == nil)
    }

    await test("Empty directory starts the shared daily sequence at 01") {
        let day = ScreenArtifactNaming.DayKey(isoWeek: 36, isoWeekday: 5)
        try expect(ScreenArtifactNaming.nextSequence(existingNames: [], day: day) == 1)
    }

    await test("png and mp4 share one daily sequence") {
        let day = ScreenArtifactNaming.DayKey(isoWeek: 36, isoWeekday: 5)
        let names = ["b-36.5-01.png", "b-36.5-02.mp4", "readme.txt"]
        try expect(ScreenArtifactNaming.nextSequence(existingNames: names, day: day) == 3)
    }

    await test("Leftover epoch names are ignored by the counter") {
        let day = ScreenArtifactNaming.DayKey(isoWeek: 36, isoWeekday: 5)
        let names = [
            "nb-screen-1710000000000.png",
            "nb-screen-1710000001000.mp4",
            "b-36.5-01.jpg"
        ]
        try expect(ScreenArtifactNaming.nextSequence(existingNames: names, day: day) == 2)
    }

    await test("Next local day resets the sequence to 01") {
        let friday = ScreenArtifactNaming.DayKey(isoWeek: 36, isoWeekday: 5)
        let saturday = ScreenArtifactNaming.DayKey(isoWeek: 36, isoWeekday: 6)
        let names = ["b-36.5-01.png", "b-36.5-02.mp4", "b-36.5-03.png"]
        try expect(ScreenArtifactNaming.nextSequence(existingNames: names, day: friday) == 4)
        try expect(ScreenArtifactNaming.nextSequence(existingNames: names, day: saturday) == 1)
    }

    await test("Malformed and other-day stems do not advance today's counter") {
        let day = ScreenArtifactNaming.DayKey(isoWeek: 36, isoWeekday: 5)
        let names = ["b-36.4-09.png", "b-36.5-xx.png", "b-36.5-01", "B-36.5-02.png"]
        try expect(ScreenArtifactNaming.nextSequence(existingNames: names, day: day) == 1)
    }

    await test("Cleanup keeps today's b-* even when mtime is older than one hour") {
        try withTempDir { dir in
            let now = civilDate(2026, 9, 4, hour: 16, timeZone: chicago)
            let twoHoursAgo = now.addingTimeInterval(-7200)
            try touch(dir, "b-36.5-01.png", mtime: twoHoursAgo)
            try touch(dir, "b-36.5-02.mp4", mtime: twoHoursAgo)
            ScreenArtifactNaming.cleanup(in: dir.path, now: now, timeZone: chicago)
            let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
            try expect(left.contains("b-36.5-01.png"), "today's capture must survive: \(left)")
            try expect(left.contains("b-36.5-02.mp4"), "today's recording must survive: \(left)")
        }
    }

    await test("Cleanup deletes prior local-day b-* files") {
        try withTempDir { dir in
            let now = civilDate(2026, 9, 4, hour: 10, timeZone: chicago)
            let yesterday = civilDate(2026, 9, 3, hour: 18, timeZone: chicago)
            try touch(dir, "b-36.4-01.png", mtime: yesterday)
            try touch(dir, "b-36.4-02.mp4", mtime: yesterday)
            try touch(dir, "b-36.5-01.png", mtime: now)
            ScreenArtifactNaming.cleanup(in: dir.path, now: now, timeZone: chicago)
            let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
            try expect(left == ["b-36.5-01.png"], "expected only today, got \(left)")
        }
    }

    await test("Cleanup leaves leftover epoch names on disk") {
        try withTempDir { dir in
            let now = civilDate(2026, 9, 4, timeZone: chicago)
            let yesterday = civilDate(2026, 9, 3, timeZone: chicago)
            try touch(dir, "nb-screen-1710000000000.png", mtime: yesterday)
            try touch(dir, "nb-screen-1710000001000.mp4", mtime: yesterday)
            try touch(dir, "b-36.4-01.png", mtime: yesterday)
            ScreenArtifactNaming.cleanup(in: dir.path, now: now, timeZone: chicago)
            let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
            try expect(left.contains("nb-screen-1710000000000.png"))
            try expect(left.contains("nb-screen-1710000001000.mp4"))
            try expect(!left.contains("b-36.4-01.png"), "prior-day b-* must go: \(left)")
        }
    }

    await test("allocatePath scans the dir and skips an occupied sequence") {
        try withTempDir { dir in
            let now = civilDate(2026, 9, 4, timeZone: chicago)
            try touch(dir, "b-36.5-01.png")
            try touch(dir, "nb-screen-1710000000000.png")
            let first = ScreenArtifactNaming.allocatePath(
                directory: dir.path,
                ext: "mp4",
                now: now,
                timeZone: chicago
            )
            try expect((first as NSString).lastPathComponent == "b-36.5-02.mp4", first)
            try Data().write(to: URL(fileURLWithPath: first))
            let second = ScreenArtifactNaming.allocatePath(
                directory: dir.path,
                ext: "png",
                now: now,
                timeZone: chicago
            )
            try expect((second as NSString).lastPathComponent == "b-36.5-03.png", second)
        }
    }

    await test("New local day allocatePath resets to 01") {
        try withTempDir { dir in
            try touch(dir, "b-36.5-03.png")
            let saturday = civilDate(2026, 9, 5, timeZone: chicago)
            let path = ScreenArtifactNaming.allocatePath(
                directory: dir.path,
                ext: "png",
                now: saturday,
                timeZone: chicago
            )
            try expect((path as NSString).lastPathComponent == "b-36.6-01.png", path)
        }
    }

    await test("Default screen output directory is unchanged (~/Desktop)") {
        try expect(ConfigManager.defaultScreenOutputDir == "~/Desktop")
    }

    await test("Capture and recording sources allocate via ScreenArtifactNaming") {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let screen = try String(
            contentsOf: repository.appendingPathComponent("TheBridge/Modules/ScreenModule.swift"),
            encoding: .utf8
        )
        let recording = try String(
            contentsOf: repository.appendingPathComponent("TheBridge/Modules/ScreenRecording.swift"),
            encoding: .utf8
        )
        try expect(screen.contains("ScreenArtifactNaming.allocatePath"))
        try expect(screen.contains("ScreenArtifactNaming.cleanup"))
        try expect(recording.contains("ScreenArtifactNaming.allocatePath"))
        try expect(!screen.contains("nb-screen-"), "ScreenModule must not emit leftover epoch names")
        try expect(!recording.contains("nb-screen-"), "ScreenRecording must not emit leftover epoch names")
    }
}
