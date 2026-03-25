#!/usr/bin/env swift
// ============================================================
// reminders-bridge.swift — Full EventKit CLI for Apple Reminders
// Version: 1.1.0 | Author: MAC Keepr | Date: 2026-03-25
// Invocation: swift reminders-bridge.swift '<json>'
//
// Commands: list-lists, create-list, create, read, update,
//           complete, delete, search
//
// Covers: recurrence rules, location alarms, URL,
//         priority, due dates, notes
// ============================================================

import EventKit
import Foundation
import CoreLocation

// MARK: - Globals

let store = EKEventStore()
let dateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let dateOnlyFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f
}()

// MARK: - Helpers: Output

func outputSuccess(_ data: Any) -> Never {
    let result: [String: Any] = ["success": true, "data": data]
    printJSON(result)
    exit(0)
}

func outputError(_ message: String) -> Never {
    let result: [String: Any] = ["success": false, "error": message]
    printJSON(result)
    exit(1)
}

func printJSON(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

// MARK: - Helpers: Date Parsing

func parseDate(_ string: String) -> Date? {
    if let d = dateFormatter.date(from: string) { return d }
    if let d = dateOnlyFormatter.date(from: string) { return d }
    let fallback = DateFormatter()
    fallback.locale = Locale(identifier: "en_US_POSIX")
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        fallback.dateFormat = fmt
        if let d = fallback.date(from: string) { return d }
    }
    return nil
}

func formatDate(_ date: Date?) -> String? {
    guard let date = date else { return nil }
    return dateFormatter.string(from: date)
}

// MARK: - Helpers: Find Calendar (List)

func findList(named name: String) -> EKCalendar? {
    let calendars = store.calendars(for: .reminder)
    return calendars.first { $0.title.lowercased() == name.lowercased() }
}

func findListById(_ id: String) -> EKCalendar? {
    let calendars = store.calendars(for: .reminder)
    return calendars.first { $0.calendarIdentifier == id }
}

// MARK: - Helpers: Fetch Reminders (sync wrapper)

func fetchReminders(matching predicate: NSPredicate) -> [EKReminder] {
    var results: [EKReminder] = []
    let sem = DispatchSemaphore(value: 0)
    store.fetchReminders(matching: predicate) { reminders in
        results = reminders ?? []
        sem.signal()
    }
    sem.wait()
    return results
}

// MARK: - Helpers: Serialize Reminder

func serializeReminder(_ r: EKReminder) -> [String: Any] {
    var dict: [String: Any] = [
        "id": r.calendarItemExternalIdentifier ?? "",
        "internalId": r.calendarItemIdentifier,
        "name": r.title ?? "",
        "completed": r.isCompleted,
        "priority": r.priority,
        "list": r.calendar?.title ?? "",
        "listId": r.calendar?.calendarIdentifier ?? ""
    ]

    if let body = r.notes { dict["body"] = body }
    if let url = r.url { dict["url"] = url.absoluteString }
    if let dueDate = r.dueDateComponents?.date { dict["dueDate"] = formatDate(dueDate)! }
    if let completionDate = r.completionDate { dict["completionDate"] = formatDate(completionDate)! }
    if let creationDate = r.creationDate { dict["creationDate"] = formatDate(creationDate)! }
    if let modDate = r.lastModifiedDate { dict["modificationDate"] = formatDate(modDate)! }

    // Recurrence rules
    if let rules = r.recurrenceRules, !rules.isEmpty {
        dict["recurrenceRules"] = rules.map { serializeRecurrenceRule($0) }
    }

    // Alarms
    if let alarms = r.alarms, !alarms.isEmpty {
        dict["alarms"] = alarms.map { serializeAlarm($0) }
    }

    return dict
}

func serializeRecurrenceRule(_ rule: EKRecurrenceRule) -> [String: Any] {
    var dict: [String: Any] = [
        "frequency": frequencyString(rule.frequency),
        "interval": rule.interval
    ]
    if let daysOfWeek = rule.daysOfTheWeek {
        dict["daysOfWeek"] = daysOfWeek.map { $0.dayOfTheWeek.rawValue }
    }
    if let daysOfMonth = rule.daysOfTheMonth {
        dict["daysOfMonth"] = daysOfMonth.map { $0.intValue }
    }
    if let monthsOfYear = rule.monthsOfTheYear {
        dict["monthsOfYear"] = monthsOfYear.map { $0.intValue }
    }
    if let end = rule.recurrenceEnd {
        if let endDate = end.endDate {
            dict["endDate"] = formatDate(endDate)!
        } else if end.occurrenceCount > 0 {
            dict["occurrenceCount"] = end.occurrenceCount
        }
    }
    return dict
}

func serializeAlarm(_ alarm: EKAlarm) -> [String: Any] {
    var dict: [String: Any] = [:]
    if let absDate = alarm.absoluteDate {
        dict["type"] = "date"
        dict["date"] = formatDate(absDate)!
    } else if let loc = alarm.structuredLocation {
        dict["type"] = "location"
        dict["title"] = loc.title ?? ""
        dict["latitude"] = loc.geoLocation?.coordinate.latitude ?? 0
        dict["longitude"] = loc.geoLocation?.coordinate.longitude ?? 0
        dict["radius"] = loc.radius
        dict["proximity"] = alarm.proximity == .enter ? "enter" : "leave"
    } else {
        dict["type"] = "relative"
        dict["offset"] = alarm.relativeOffset
    }
    return dict
}

func frequencyString(_ freq: EKRecurrenceFrequency) -> String {
    switch freq {
    case .daily: return "daily"
    case .weekly: return "weekly"
    case .monthly: return "monthly"
    case .yearly: return "yearly"
    @unknown default: return "unknown"
    }
}

// MARK: - Helpers: Build Recurrence Rule

func buildRecurrenceRule(from spec: [String: Any]) -> EKRecurrenceRule? {
    guard let freqStr = spec["frequency"] as? String else { return nil }

    let frequency: EKRecurrenceFrequency
    switch freqStr.lowercased() {
    case "daily": frequency = .daily
    case "weekly": frequency = .weekly
    case "monthly": frequency = .monthly
    case "yearly": frequency = .yearly
    default: return nil
    }

    let interval = (spec["interval"] as? Int) ?? 1

    var daysOfWeek: [EKRecurrenceDayOfWeek]? = nil
    if let days = spec["daysOfWeek"] as? [Int] {
        daysOfWeek = days.compactMap { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0)!) }
    }

    var daysOfMonth: [NSNumber]? = nil
    if let days = spec["daysOfMonth"] as? [Int] {
        daysOfMonth = days.map { NSNumber(value: $0) }
    }

    var monthsOfYear: [NSNumber]? = nil
    if let months = spec["monthsOfYear"] as? [Int] {
        monthsOfYear = months.map { NSNumber(value: $0) }
    }

    var end: EKRecurrenceEnd? = nil
    if let endDateStr = spec["endDate"] as? String, let endDate = parseDate(endDateStr) {
        end = EKRecurrenceEnd(end: endDate)
    } else if let count = spec["occurrenceCount"] as? Int {
        end = EKRecurrenceEnd(occurrenceCount: count)
    }

    return EKRecurrenceRule(
        recurrenceWith: frequency,
        interval: interval,
        daysOfTheWeek: daysOfWeek,
        daysOfTheMonth: daysOfMonth,
        monthsOfTheYear: monthsOfYear,
        weeksOfTheYear: nil,
        daysOfTheYear: nil,
        setPositions: nil,
        end: end
    )
}

// MARK: - Helpers: Build Location Alarm

func buildLocationAlarm(from spec: [String: Any]) -> EKAlarm? {
    guard let lat = spec["latitude"] as? Double,
          let lon = spec["longitude"] as? Double else { return nil }

    let radius = (spec["radius"] as? Double) ?? 100.0
    let title = (spec["title"] as? String) ?? "Location"
    let proximityStr = (spec["proximity"] as? String) ?? "leave"

    let location = EKStructuredLocation(title: title)
    location.geoLocation = CLLocation(latitude: lat, longitude: lon)
    location.radius = radius

    let alarm = EKAlarm()
    alarm.structuredLocation = location
    alarm.proximity = proximityStr.lowercased() == "enter" ? .enter : .leave

    return alarm
}

// MARK: - Command: list-lists

func cmdListLists() -> Never {
    let calendars = store.calendars(for: .reminder)
    let data = calendars.map { cal -> [String: Any] in
        var d: [String: Any] = [
            "id": cal.calendarIdentifier,
            "name": cal.title,
            "isDefault": cal == store.defaultCalendarForNewReminders()
        ]
        if let source = cal.source {
            d["account"] = source.title
        }
        return d
    }
    outputSuccess(data)
}

// MARK: - Command: create-list

func cmdCreateList(params: [String: Any]) -> Never {
    guard let name = params["name"] as? String else {
        outputError("Missing required parameter: name")
    }

    let calendar = EKCalendar(for: .reminder, eventStore: store)
    calendar.title = name

    // Find a writable source (prefer iCloud, then local)
    let sources = store.sources.filter { $0.sourceType == .calDAV || $0.sourceType == .local }
    guard let source = sources.first(where: { $0.sourceType == .calDAV }) ?? sources.first else {
        outputError("No writable calendar source found")
    }
    calendar.source = source

    do {
        try store.saveCalendar(calendar, commit: true)
        outputSuccess([
            "id": calendar.calendarIdentifier,
            "name": calendar.title,
            "account": source.title
        ] as [String: Any])
    } catch {
        outputError("Failed to create list: \(error.localizedDescription)")
    }
}

// MARK: - Command: create

func cmdCreate(params: [String: Any]) -> Never {
    guard let name = params["name"] as? String else {
        outputError("Missing required parameter: name")
    }

    let reminder = EKReminder(eventStore: store)
    reminder.title = name

    // List assignment (listId UUID > list name > default)
    if let listId = params["listId"] as? String {
        guard let cal = store.calendar(withIdentifier: listId) else {
            outputError("List not found for listId: \(listId)")
        }
        reminder.calendar = cal
    } else if let listName = params["list"] as? String {
        guard let cal = findList(named: listName) else {
            outputError("List not found: \(listName)")
        }
        reminder.calendar = cal
    } else {
        reminder.calendar = store.defaultCalendarForNewReminders()
    }

    // Body/notes (accepts "notes" or "body")
    if let notes = params["notes"] as? String ?? params["body"] as? String {
        reminder.notes = notes
    }

    // Due date
    if let dueDateStr = params["dueDate"] as? String, let dueDate = parseDate(dueDateStr) {
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: dueDate
        )
    }

    // All-day due date
    if let allDayStr = params["allDayDueDate"] as? String, let allDay = parseDate(allDayStr) {
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day], from: allDay
        )
    }

    // Remind me date
    if let remindStr = params["remindMeDate"] as? String, let remindDate = parseDate(remindStr) {
        let alarm = EKAlarm(absoluteDate: remindDate)
        reminder.addAlarm(alarm)
    }

    // Priority (0=none, 1=high/flagged, 5=medium, 9=low)
    if let priority = params["priority"] as? Int {
        reminder.priority = priority
    }

    // URL
    if let urlStr = params["url"] as? String, let url = URL(string: urlStr) {
        reminder.url = url
    }

    // Recurrence rule
    if let recurrenceSpec = params["recurrence"] as? [String: Any],
       let rule = buildRecurrenceRule(from: recurrenceSpec) {
        reminder.addRecurrenceRule(rule)
    }

    // Location alarm
    if let locationSpec = params["locationAlarm"] as? [String: Any],
       let alarm = buildLocationAlarm(from: locationSpec) {
        reminder.addAlarm(alarm)
    }

    do {
        try store.save(reminder, commit: true)
        outputSuccess(serializeReminder(reminder))
    } catch {
        outputError("Failed to create reminder: \(error.localizedDescription)")
    }
}

// MARK: - Command: read

func cmdRead(params: [String: Any]) -> Never {
    let includeCompleted = (params["includeCompleted"] as? Bool) ?? false

    var predicate: NSPredicate
    if let listName = params["list"] as? String {
        guard let cal = findList(named: listName) else {
            outputError("List not found: \(listName)")
        }
        predicate = store.predicateForReminders(in: [cal])
    } else {
        predicate = store.predicateForReminders(in: nil)
    }

    let reminders = fetchReminders(matching: predicate)
    let filtered = includeCompleted ? reminders : reminders.filter { !$0.isCompleted }
    let data = filtered.map { serializeReminder($0) }
    outputSuccess(data)
}

// MARK: - Command: update

func cmdUpdate(params: [String: Any]) -> Never {
    guard let targetId = params["id"] as? String else {
        outputError("Missing required parameter: id")
    }

    // Fetch all reminders (including completed) and find by ID
    let predicate = store.predicateForReminders(in: nil)
    let reminders = fetchReminders(matching: predicate)
    guard let reminder = reminders.first(where: {
        $0.calendarItemExternalIdentifier == targetId || $0.calendarItemIdentifier == targetId
    }) else {
        outputError("Reminder not found: \(targetId)")
    }

    // Update fields
    if let name = params["name"] as? String { reminder.title = name }
    if let notes = params["notes"] as? String ?? params["body"] as? String { reminder.notes = notes }
    if let priority = params["priority"] as? Int { reminder.priority = priority }

    if let urlStr = params["url"] as? String {
        reminder.url = URL(string: urlStr)
    }

    if let dueDateStr = params["dueDate"] as? String, let dueDate = parseDate(dueDateStr) {
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: dueDate
        )
    }

    if let allDayStr = params["allDayDueDate"] as? String, let allDay = parseDate(allDayStr) {
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day], from: allDay
        )
    }

    // Move to different list (listId UUID > list name)
    if let listId = params["listId"] as? String {
        guard let cal = store.calendar(withIdentifier: listId) else {
            outputError("List not found for listId: \(listId)")
        }
        reminder.calendar = cal
    } else if let listName = params["list"] as? String, let cal = findList(named: listName) {
        reminder.calendar = cal
    }

    // Replace recurrence rules
    if let recurrenceSpec = params["recurrence"] as? [String: Any] {
        if let existing = reminder.recurrenceRules {
            for rule in existing { reminder.removeRecurrenceRule(rule) }
        }
        if let rule = buildRecurrenceRule(from: recurrenceSpec) {
            reminder.addRecurrenceRule(rule)
        }
    }

    // Add/replace location alarm
    if let locationSpec = params["locationAlarm"] as? [String: Any] {
        if let alarms = reminder.alarms {
            for alarm in alarms where alarm.structuredLocation != nil {
                reminder.removeAlarm(alarm)
            }
        }
        if let alarm = buildLocationAlarm(from: locationSpec) {
            reminder.addAlarm(alarm)
        }
    }

    // Add remind-me date alarm
    if let remindStr = params["remindMeDate"] as? String, let remindDate = parseDate(remindStr) {
        let alarm = EKAlarm(absoluteDate: remindDate)
        reminder.addAlarm(alarm)
    }

    do {
        try store.save(reminder, commit: true)
        outputSuccess(serializeReminder(reminder))
    } catch {
        outputError("Failed to update reminder: \(error.localizedDescription)")
    }
}

// MARK: - Command: complete

func cmdComplete(params: [String: Any]) -> Never {
    guard let targetId = params["id"] as? String else {
        outputError("Missing required parameter: id")
    }

    let completed = (params["completed"] as? Bool) ?? true

    let predicate = store.predicateForReminders(in: nil)
    let reminders = fetchReminders(matching: predicate)
    guard let reminder = reminders.first(where: {
        $0.calendarItemExternalIdentifier == targetId || $0.calendarItemIdentifier == targetId
    }) else {
        outputError("Reminder not found: \(targetId)")
    }

    reminder.isCompleted = completed
    if completed {
        reminder.completionDate = Date()
    } else {
        reminder.completionDate = nil
    }

    do {
        try store.save(reminder, commit: true)
        outputSuccess(serializeReminder(reminder))
    } catch {
        outputError("Failed to update reminder: \(error.localizedDescription)")
    }
}

// MARK: - Command: delete

func cmdDelete(params: [String: Any]) -> Never {
    guard let targetId = params["id"] as? String else {
        outputError("Missing required parameter: id")
    }

    let predicate = store.predicateForReminders(in: nil)
    let reminders = fetchReminders(matching: predicate)
    guard let reminder = reminders.first(where: {
        $0.calendarItemExternalIdentifier == targetId || $0.calendarItemIdentifier == targetId
    }) else {
        outputError("Reminder not found: \(targetId)")
    }

    do {
        try store.remove(reminder, commit: true)
        outputSuccess(["deleted": targetId])
    } catch {
        outputError("Failed to delete reminder: \(error.localizedDescription)")
    }
}

// MARK: - Command: search

func cmdSearch(params: [String: Any]) -> Never {
    guard let query = params["query"] as? String else {
        outputError("Missing required parameter: query")
    }
    let includeCompleted = (params["includeCompleted"] as? Bool) ?? false

    let predicate = store.predicateForReminders(in: nil)
    let reminders = fetchReminders(matching: predicate)
    let queryLower = query.lowercased()

    let matched = reminders.filter { r in
        if !includeCompleted && r.isCompleted { return false }
        let nameMatch = r.title?.lowercased().contains(queryLower) ?? false
        let bodyMatch = r.notes?.lowercased().contains(queryLower) ?? false
        return nameMatch || bodyMatch
    }

    let data = matched.map { serializeReminder($0) }
    outputSuccess(data)
}

// MARK: - Main Entry Point

guard CommandLine.arguments.count > 1 else {
    outputError("Usage: swift reminders-bridge.swift '<json>'\nCommands: list-lists, create-list, create, read, update, complete, delete, search")
}

let jsonString = CommandLine.arguments[1]

guard let jsonData = jsonString.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
      let command = json["command"] as? String else {
    outputError("Invalid JSON input. Expected: {\"command\": \"...\", \"params\": {...}}")
}

let params = (json["params"] as? [String: Any]) ?? [:]

// Route to command handler
switch command {
case "list-lists":
    cmdListLists()
case "create-list":
    cmdCreateList(params: params)
case "create":
    cmdCreate(params: params)
case "read":
    cmdRead(params: params)
case "update":
    cmdUpdate(params: params)
case "complete":
    cmdComplete(params: params)
case "delete":
    cmdDelete(params: params)
case "search":
    cmdSearch(params: params)
default:
    outputError("Unknown command: \(command). Valid: list-lists, create-list, create, read, update, complete, delete, search")
}
