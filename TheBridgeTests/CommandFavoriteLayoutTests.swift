// CommandFavoriteLayoutTests.swift — C0 / GitHub #140
//
// Search favorite assignment is a reversible layout transaction. It never
// mutates or duplicates command bodies. One command occupies at most one slot.

import Foundation
import TheBridgeLib

func runCommandFavoriteLayoutTests() async {
    print("\n[Command Search favorites C0 / #140]")

    await test("C0 empty slot assigns without a conflict prompt") {
        var session = FavoriteLayoutSession()
        let applied = session.chooseSlot(1, for: "alpha")
        try expect(applied?.slug(in: 1) == "alpha")
        try expect(session.pending == nil)
        try expect(session.current.slot(of: "alpha") == 1)
    }

    await test("C0 occupied slot prompts Replace and optional Swap") {
        var session = FavoriteLayoutSession(current: FavoriteLayout(slots: [1: "alpha", 2: "beta"]))
        try expect(session.chooseSlot(1, for: "beta") == nil)
        try expect(session.pending?.occupiedBy == "alpha")
        try expect(session.pending?.swap != nil)
        let swapped = session.resolveSwap()
        try expect(swapped?.slug(in: 1) == "beta")
        try expect(swapped?.slug(in: 2) == "alpha")
    }

    await test("C0 Replace evicts the occupant and frees the mover's old slot") {
        var session = FavoriteLayoutSession(current: FavoriteLayout(slots: [1: "alpha", 2: "beta"]))
        _ = session.chooseSlot(1, for: "beta")
        let replaced = session.resolveReplace()
        try expect(replaced?.slug(in: 1) == "beta")
        try expect(replaced?.slot(of: "alpha") == nil)
        try expect(replaced?.slug(in: 2) == nil)
    }

    await test("C0 unfavorited command cannot Swap onto an occupied slot") {
        var session = FavoriteLayoutSession(current: FavoriteLayout(slots: [1: "alpha"]))
        _ = session.chooseSlot(1, for: "gamma")
        try expect(session.pending?.swap == nil)
        try expect(session.resolveSwap() == nil)
        let replaced = session.resolveReplace()
        try expect(replaced?.slug(in: 1) == "gamma")
        try expect(replaced?.slot(of: "alpha") == nil)
    }

    await test("C0 Cancel leaves the prior layout intact") {
        var session = FavoriteLayoutSession(current: FavoriteLayout(slots: [1: "alpha"]))
        _ = session.chooseSlot(1, for: "beta")
        session.cancelPrompt()
        try expect(session.current.slug(in: 1) == "alpha")
        try expect(session.pending == nil)
    }

    await test("C0 Remove and Undo restore the prior layout") {
        var session = FavoriteLayoutSession()
        _ = session.chooseSlot(3, for: "alpha")
        _ = session.remove(slug: "alpha")
        try expect(session.current.slot(of: "alpha") == nil)
        let undone = session.undo()
        try expect(undone?.slug(in: 3) == "alpha")
        try expect(session.canUndo)
        _ = session.undo()
        try expect(session.current.slots.isEmpty)
        try expect(!session.canUndo)
    }

    await test("C0 one command occupies at most one slot") {
        let layout = FavoriteLayout(slots: [1: "alpha", 4: "alpha", 0: "beta"])
        try expect(layout.slot(of: "alpha") == 1)
        try expect(layout.slug(in: 4) == nil)
        try expect(layout.slug(in: 0) == "beta")
    }

    await test("C0 applyFavoriteLayout persists through A0 map without rewriting bodies") {
        try await withTempHomeC0 { _ in
            try CommandStore.shared.resetForTesting()
            let a = try CommandStore.shared.create(name: "Alpha", icon: .emoji("a"), body: "body-a", keySlot: 1)
            let b = try CommandStore.shared.create(name: "Beta", icon: .emoji("b"), body: "body-b", keySlot: 2)
            try CommandStore.shared.applyFavoriteLayout(FavoriteLayout(slots: [0: a.slug, 9: b.slug]))
            try expect(try CommandStore.shared.get(slug: a.slug)?.body == "body-a")
            try expect(try CommandStore.shared.get(slug: b.slug)?.body == "body-b")
            try expect(try CommandStore.shared.get(slug: a.slug)?.keySlot == 0)
            try expect(try CommandStore.shared.get(slug: b.slug)?.keySlot == 9)
            try expect(try CommandStore.shared.command(forKeySlot: 1) == nil)
            try expect(try CommandStore.shared.favoriteLayout().slot(of: a.slug) == 0)
        }
    }

    await test("C0 setKeySlot still evicts; layout round-trip survives a second apply") {
        try await withTempHomeC0 { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "Keep", icon: .emoji("k"), body: "keep-body", keySlot: 5)
            _ = try CommandStore.shared.create(name: "Move", icon: .emoji("m"), body: "move-body")
            try CommandStore.shared.setKeySlot(slug: "move", slot: 5)
            try expect(try CommandStore.shared.get(slug: "keep")?.body == "keep-body")
            try expect(try CommandStore.shared.get(slug: "move")?.keySlot == 5)
            let layout = try CommandStore.shared.favoriteLayout()
            try CommandStore.shared.applyFavoriteLayout(layout)
            try expect(try CommandStore.shared.get(slug: "keep")?.body == "keep-body")
            try expect(try CommandStore.shared.get(slug: "move")?.body == "move-body")
            try expect(try CommandStore.shared.get(slug: "move")?.keySlot == 5)
        }
    }

    await test("C0 Search digits fire slots until the favorite picker is open") {
        try await withTempHomeC0 { _ in
            try CommandStore.shared.resetForTesting()
            let created = try CommandStore.shared.create(
                name: "Alpha", icon: .emoji("a"), body: "body-a")
            let stole = await MainActor.run { () -> Bool in
                let vm = CommandBridgeViewModel(
                    store: CommandStore.shared,
                    recents: CommandBridgeRecents(cap: 1)
                )
                return vm.handleFavoriteDigit(1)
            }
            try expect(!stole)
            try expect(try CommandStore.shared.get(slug: created.slug)?.keySlot == nil)
            try expect(try CommandStore.shared.get(slug: created.slug)?.body == "body-a")

            let assigned = await MainActor.run { () -> Bool in
                let vm = CommandBridgeViewModel(
                    store: CommandStore.shared,
                    recents: CommandBridgeRecents(cap: 1)
                )
                vm.beginFavoritePicker(slug: created.slug)
                return vm.handleFavoriteDigit(3)
            }
            try expect(assigned)
            try expect(try CommandStore.shared.get(slug: created.slug)?.keySlot == 3)
            try expect(try CommandStore.shared.get(slug: created.slug)?.body == "body-a")
        }
    }

    await test("C0 ViewModel Replace names the displaced command and keeps bodies intact") {
        try await withTempHomeC0 { _ in
            try CommandStore.shared.resetForTesting()
            let a = try CommandStore.shared.create(
                name: "Alpha", icon: .emoji("a"), body: "body-a", keySlot: 1)
            let b = try CommandStore.shared.create(
                name: "Beta", icon: .emoji("b"), body: "body-b")
            let names = await MainActor.run { () -> (String, String, Bool) in
                let vm = CommandBridgeViewModel(
                    store: CommandStore.shared,
                    recents: CommandBridgeRecents(cap: 1)
                )
                vm.beginFavoritePicker(slug: b.slug)
                _ = vm.assignFavorite(slug: b.slug, slot: 1)
                let occupant = vm.favoriteSession.pending.map {
                    vm.commandDisplayName($0.occupiedBy)
                } ?? ""
                let mover = vm.favoriteSession.pending.map {
                    vm.commandDisplayName($0.slug)
                } ?? ""
                vm.resolveFavoriteReplace()
                return (mover, occupant, vm.favoriteSession.pending == nil)
            }
            try expect(names.0 == "Beta")
            try expect(names.1 == "Alpha")
            try expect(names.2)
            try expect(try CommandStore.shared.get(slug: a.slug)?.body == "body-a")
            try expect(try CommandStore.shared.get(slug: b.slug)?.body == "body-b")
            try expect(try CommandStore.shared.get(slug: a.slug)?.keySlot == nil)
            try expect(try CommandStore.shared.get(slug: b.slug)?.keySlot == 1)
        }
    }
}

private func withTempHomeC0(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("CommandFavoriteLayout-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
