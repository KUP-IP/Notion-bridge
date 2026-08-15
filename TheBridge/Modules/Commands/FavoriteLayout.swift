// FavoriteLayout.swift — GitHub #140 C0
//
// Pure favorite-map transactions. Slots are CommandStore keys 0…9 (displayed
// 1…0). One command occupies at most one slot. Layout never carries command
// bodies — persistence goes through A0's favorite map.

import Foundation

public struct FavoriteLayout: Equatable, Sendable {
    public static let storeSlots = 0...9
    public static let displayOrder = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]

    /// storeSlot → command slug
    public private(set) var slots: [Int: String]

    public init(slots: [Int: String] = [:]) {
        var next: [Int: String] = [:]
        var seen = Set<String>()
        for slot in Self.storeSlots {
            guard let slug = slots[slot], !slug.isEmpty, seen.insert(slug).inserted else { continue }
            next[slot] = slug
        }
        self.slots = next
    }

    public func slug(in slot: Int) -> String? { slots[slot] }

    public func slot(of slug: String) -> Int? {
        slots.first(where: { $0.value == slug })?.key
    }

    public enum Assignment: Equatable, Sendable {
        case applied(FavoriteLayout)
        /// `swap` is nil when the moving command has no current slot — Replace
        /// is the only occupancy resolution that can run.
        case conflict(occupiedBy: String, replace: FavoriteLayout, swap: FavoriteLayout?)
    }

    public func assigning(slug: String, to slot: Int) -> Assignment? {
        guard Self.storeSlots.contains(slot), !slug.isEmpty else { return nil }
        if self.slot(of: slug) == slot {
            return .applied(self)
        }
        guard let occupant = slots[slot], occupant != slug else {
            return .applied(placing(slug, in: slot, evicting: nil))
        }
        let replace = placing(slug, in: slot, evicting: occupant)
        let swap: FavoriteLayout?
        if let origin = self.slot(of: slug) {
            var next = slots
            next[slot] = slug
            next[origin] = occupant
            swap = FavoriteLayout(slots: next)
        } else {
            swap = nil
        }
        return .conflict(occupiedBy: occupant, replace: replace, swap: swap)
    }

    public func removing(slug: String) -> FavoriteLayout {
        FavoriteLayout(slots: slots.filter { $0.value != slug })
    }

    public func moving(slug: String, to slot: Int) -> FavoriteLayout? {
        guard case .applied(let next) = assigning(slug: slug, to: slot) else { return nil }
        return next
    }

    private func placing(_ slug: String, in slot: Int, evicting: String?) -> FavoriteLayout {
        var next = slots.filter { $0.value != slug }
        if let evicting {
            next = next.filter { $0.value != evicting }
        }
        next[slot] = slug
        return FavoriteLayout(slots: next)
    }
}

public struct FavoriteConflictPrompt: Equatable, Sendable {
    public let slug: String
    public let slot: Int
    public let occupiedBy: String
    public let replace: FavoriteLayout
    public let swap: FavoriteLayout?
}

public struct FavoriteLayoutSession: Equatable, Sendable {
    public var current: FavoriteLayout
    public var pending: FavoriteConflictPrompt?
    public var pickerSlug: String?
    private var undoStack: [FavoriteLayout]

    public init(current: FavoriteLayout = FavoriteLayout()) {
        self.current = current
        self.pending = nil
        self.pickerSlug = nil
        self.undoStack = []
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    public mutating func openPicker(slug: String) {
        pending = nil
        pickerSlug = slug
    }

    public mutating func closePicker() {
        pickerSlug = nil
        pending = nil
    }

    /// Returns the layout to persist, or nil when a conflict prompt is now pending.
    public mutating func chooseSlot(_ slot: Int, for slug: String) -> FavoriteLayout? {
        guard let assignment = current.assigning(slug: slug, to: slot) else { return nil }
        switch assignment {
        case .applied(let next):
            pending = nil
            pickerSlug = nil
            commit(next)
            return current
        case .conflict(let occupiedBy, let replace, let swap):
            pending = FavoriteConflictPrompt(
                slug: slug,
                slot: slot,
                occupiedBy: occupiedBy,
                replace: replace,
                swap: swap
            )
            return nil
        }
    }

    public mutating func resolveReplace() -> FavoriteLayout? {
        guard let pending else { return nil }
        commit(pending.replace)
        self.pending = nil
        pickerSlug = nil
        return current
    }

    public mutating func resolveSwap() -> FavoriteLayout? {
        guard let pending, let swap = pending.swap else { return nil }
        commit(swap)
        self.pending = nil
        pickerSlug = nil
        return current
    }

    public mutating func cancelPrompt() {
        pending = nil
    }

    public mutating func remove(slug: String) -> FavoriteLayout {
        pickerSlug = nil
        pending = nil
        commit(current.removing(slug: slug))
        return current
    }

    public mutating func undo() -> FavoriteLayout? {
        guard let previous = undoStack.popLast() else { return nil }
        current = previous
        pending = nil
        pickerSlug = nil
        return current
    }

    private mutating func commit(_ next: FavoriteLayout) {
        if next != current {
            undoStack.append(current)
            if undoStack.count > 20 {
                undoStack.removeFirst()
            }
            current = next
        }
    }
}
