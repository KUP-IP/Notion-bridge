// CommandCursorInsertTests.swift — issue #129
// TheBridge · Tests
//
// Headless coverage for cursor-insert command activation:
//   (A) CommandTextSplicer — caret insert, selection replace, Unicode,
//       multiline, UTF-16 emoji, range clamp.
//   (B) CommandInsertOutcome.userMessage — fail-closed copy.
//   (C) CommandBridgeController.applyCommit — inserts via seam, never
//       writes the clipboard; no-target / AX-denied leave the clipboard
//       byte-for-byte unchanged.
// Live AX insertion against a native field + a browser input remains
// the operator smoke ceiling (docs/operator/command-bridge-smoke-checklist.md).

import Foundation
import AppKit
import TheBridgeLib

func runCommandCursorInsertTests() async {
    print("\n\u{1F4DD} Command Cursor Insert Tests (issue #129)")

    func coord() -> CommandPaletteCoordinator {
        CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(),
            manager: CommandsManager(fetcher: { _ in "{}" }))
    }

    // ── (A) Pure splice ─────────────────────────────────────────────

    await test("Splicer: caret insert (zero-length selection) leaves surroundings") {
        let s = CommandTextSplicer.splice(
            value: "hello world",
            selectedLocationUTF16: 6,
            selectedLengthUTF16: 0,
            insertion: "there "
        )
        try expect(s.newValue == "hello there world", "got \(s.newValue)")
        try expect(!s.replacedSelection, "caret insert is not a replace")
        try expect(s.newCaretUTF16 == 12, "caret after inserted UTF-16, got \(s.newCaretUTF16)")
    }

    await test("Splicer: non-empty selection is replaced") {
        let s = CommandTextSplicer.splice(
            value: "hello world",
            selectedLocationUTF16: 6,
            selectedLengthUTF16: 5,
            insertion: "bridge"
        )
        try expect(s.newValue == "hello bridge", "got \(s.newValue)")
        try expect(s.replacedSelection, "non-empty range must flag replace")
        try expect(s.newCaretUTF16 == 12, "got \(s.newCaretUTF16)")
    }

    await test("Splicer: multiline + Unicode + Markdown survive byte-for-byte") {
        let insertion = "# H1\n\n- a — b\n[link](https://www.notion.so/p)\n✅ ünïçødé"
        let s = CommandTextSplicer.splice(
            value: ">>><<<",
            selectedLocationUTF16: 3,
            selectedLengthUTF16: 0,
            insertion: insertion
        )
        try expect(s.newValue == ">>>" + insertion + "<<<", "got \(s.newValue)")
        try expect(s.newValue.contains("\n"), "newlines must be preserved")
        try expect(s.newValue.contains("ünïçødé"), "unicode must be preserved")
        try expect(s.newValue.contains("✅"), "emoji must be preserved")
    }

    await test("Splicer: emoji selection uses UTF-16 units (👍 is 2)") {
        let thumb = "👍"
        try expect(thumb.utf16.count == 2, "sanity: thumbs-up is a surrogate pair")
        let s = CommandTextSplicer.splice(
            value: "ab👍cd",
            selectedLocationUTF16: 2,
            selectedLengthUTF16: 2,
            insertion: "X"
        )
        try expect(s.newValue == "abXcd", "got \(s.newValue)")
        try expect(s.replacedSelection)
        try expect(s.newCaretUTF16 == 3, "got \(s.newCaretUTF16)")
    }

    await test("Splicer: out-of-range location/length clamp instead of trap") {
        let s = CommandTextSplicer.splice(
            value: "ab",
            selectedLocationUTF16: 99,
            selectedLengthUTF16: 50,
            insertion: "Z"
        )
        try expect(s.newValue == "abZ", "got \(s.newValue)")
        try expect(!s.replacedSelection)
    }

    await test("PointerFocus: native field uses the control center") {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        let p = CommandInsertPointerFocus.point(role: "AXTextArea", frame: frame)
        try expect(p.x == 60, "got \(p.x)")
        try expect(p.y == 40, "got \(p.y)")
    }

    await test("PointerFocus: Chromium web area aims near the bottom (composer)") {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let p = CommandInsertPointerFocus.point(role: "AXWebArea", frame: frame)
        try expect(p.x == 200, "got \(p.x)")
        try expect(p.y == 736, "got \(p.y)")
        let group = CommandInsertPointerFocus.point(role: "AXGroup", frame: frame)
        try expect(group == p, "AXGroup must share the web-area heuristic")
    }

    await test("PointerFocus: short web-like control keeps a small inset") {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        let p = CommandInsertPointerFocus.point(role: "AXWebArea", frame: frame)
        try expect(p.x == 60, "got \(p.x)")
        try expect(p.y == 52, "got \(p.y)")
    }

    await test("PointerFocus: page-sized Agents web area clears the follow-up strip") {
        let frame = CGRect(x: 251, y: 30, width: 2030, height: 1387)
        let p = CommandInsertPointerFocus.point(role: "AXWebArea", frame: frame)
        let inset = min(120 as CGFloat, max(48, frame.height * 0.08))
        try expect(p.x == frame.midX, "got \(p.x)")
        try expect(p.y == frame.maxY - inset, "got \(p.y)")
        try expect(inset > 28, "28px cap lands in the 24px follow-up strip, got \(inset)")
        try expect(inset >= 48, "got \(inset)")
    }

    await test("AXSet: AXWebArea is untrusted even when AXValue looks settable") {
        let frame = CGRect(x: 251, y: 30, width: 2030, height: 1387)
        try expect(!CommandInsertPointerFocus.trustsAXSet(role: "AXWebArea", frame: frame))
        try expect(!CommandInsertPointerFocus.trustsAXSet(role: "AXGroup", frame: frame))
        try expect(CommandInsertPointerFocus.trustsAXSet(role: "AXTextArea", frame: frame))
        try expect(CommandInsertPointerFocus.trustsAXSet(
            role: "AXGroup",
            frame: CGRect(x: 0, y: 0, width: 200, height: 40)
        ))
    }

    await test("AXVerify: splice match counts as landed") {
        let landed = CommandInsertAXVerify.landed(
            before: "ab",
            after: "aXYb",
            insertion: "XY",
            selectedLocationUTF16: 1,
            selectedLengthUTF16: 0
        )
        try expect(landed)
    }

    await test("AXVerify: Chromium false success (after == before) is not landed") {
        let landed = CommandInsertAXVerify.landed(
            before: "Send follow-up\n",
            after: "Send follow-up\n",
            insertion: "Initiate",
            selectedLocationUTF16: 0,
            selectedLengthUTF16: 0
        )
        try expect(!landed, "unmutated AXValue must not count as insert")
    }

    await test("AXVerify: unread after a claimed set is not landed") {
        let landed = CommandInsertAXVerify.landed(
            before: "ab",
            after: nil,
            insertion: "XY",
            selectedLocationUTF16: 1,
            selectedLengthUTF16: 0
        )
        try expect(!landed)
    }

    await test("AXVerify: substring already in before does not count without a change") {
        let landed = CommandInsertAXVerify.landed(
            before: "Send follow-up\n",
            after: "Send follow-up\n",
            insertion: "Send",
            selectedLocationUTF16: 15,
            selectedLengthUTF16: 0
        )
        try expect(!landed)
    }

    // ── (B) Status copy ─────────────────────────────────────────────

    await test("Outcome.userMessage: no-target and AX-denied are explicit") {
        try expect(CommandInsertOutcome.noEditableTarget.userMessage
                   == "No editable field in the frontmost app")
        try expect(CommandInsertOutcome.accessibilityDenied.userMessage
                   == "Accessibility permission required to insert commands")
        try expect(CommandInsertOutcome.emptyBody.userMessage
                   == "Command body is empty")
        try expect(!CommandInsertOutcome.noEditableTarget.succeeded)
        try expect(CommandInsertOutcome.inserted(replacedSelection: true, characters: 3).succeeded)
    }

    await test("Presenter presentInsert: failures stay open, success dismisses") {
        let ok = CommandPalettePresenter.presentInsert(
            .inserted(replacedSelection: false, characters: 4), name: "Sig")
        try expect(ok.message == "Inserted Sig", "got '\(ok.message)'")
        try expect(!ok.staysOpen)
        try expect(ok.isConfirmation)

        let miss = CommandPalettePresenter.presentInsert(.noEditableTarget, name: "Sig")
        try expect(miss.message == "No editable field in the frontmost app")
        try expect(miss.staysOpen)
        try expect(!miss.isConfirmation)

        let ax = CommandPalettePresenter.presentInsert(.accessibilityDenied, name: "Sig")
        try expect(ax.message.contains("Accessibility"))
        try expect(ax.staysOpen)
    }

    // ── (C) applyCommit never touches the clipboard ─────────────────

    await test("applyCommit(.paste) inserts the body and leaves the clipboard untouched") {
        let cb = InMemoryClipboard(initial: "user-prior-clip")
        let ins = RecordingTextInserter()
        let ctrl = await CommandBridgeController(clipboard: cb, inserter: ins, coordinator: coord())
        let outcome = await ctrl.applyCommit(.paste("hello-bridge"))
        try expect(cb.writeCount == 0, "fire path must not write clipboard, got \(cb.writeCount)")
        try expect(cb.readString() == "user-prior-clip",
                   "prior clipboard must be byte-for-byte unchanged, got \(cb.readString() ?? "nil")")
        try expect(ins.inserts.map(\.text) == ["hello-bridge"])
        try expect(await ctrl.lastInsertedText == "hello-bridge")
        guard case .inserted(_, let n) = outcome else {
            throw TestError.assertion("expected .inserted, got \(String(describing: outcome))")
        }
        try expect(n == "hello-bridge".count)
    }

    await test("applyCommit(.paste) preserves exact markdown / Unicode / newlines on insert") {
        let cb = InMemoryClipboard(initial: "PRIOR")
        let ins = RecordingTextInserter()
        let ctrl = await CommandBridgeController(clipboard: cb, inserter: ins, coordinator: coord())
        let body = "# H1\n\n- a — b\n[link](https://www.notion.so/p)\n✅ ünïçødé"
        await ctrl.applyCommit(.paste(body))
        try expect(ins.inserts.first?.text == body, "got \(ins.inserts.first?.text ?? "nil")")
        try expect(cb.readString() == "PRIOR")
        try expect(cb.writeCount == 0)
    }

    await test("applyCommit(.paste) with empty body skips insert and does not clobber clipboard") {
        let cb = InMemoryClipboard(initial: "prior")
        let ins = RecordingTextInserter()
        let ctrl = await CommandBridgeController(clipboard: cb, inserter: ins, coordinator: coord())
        let outcome = await ctrl.applyCommit(.paste(""))
        try expect(outcome == .emptyBody)
        try expect(ins.inserts.isEmpty, "empty body must not reach the inserter")
        try expect(cb.writeCount == 0)
        try expect(cb.readString() == "prior")
        try expect(await ctrl.lastInsertedText == nil)
    }

    await test("applyCommit(.notFound) inserts nothing and leaves clipboard untouched") {
        let cb = InMemoryClipboard(initial: "prior")
        let ins = RecordingTextInserter()
        let ctrl = await CommandBridgeController(clipboard: cb, inserter: ins, coordinator: coord())
        let outcome = await ctrl.applyCommit(.notFound(query: "zzzz"))
        try expect(outcome == nil, "notFound is not an insert attempt")
        try expect(ins.inserts.isEmpty)
        try expect(cb.writeCount == 0)
        try expect(cb.readString() == "prior")
    }

    await test("no editable target: reports failure and does not write clipboard") {
        let cb = InMemoryClipboard(initial: "prior")
        let ins = RecordingTextInserter(forcedOutcome: .noEditableTarget)
        let ctrl = await CommandBridgeController(clipboard: cb, inserter: ins, coordinator: coord())
        let outcome = await ctrl.applyCommit(.paste("BODY"))
        try expect(outcome == .noEditableTarget)
        try expect(ins.inserts.map(\.text) == ["BODY"], "attempt still recorded")
        try expect(cb.writeCount == 0, "must not silently copy as fallback")
        try expect(cb.readString() == "prior")
        try expect(await ctrl.lastInsertedText == nil)
        try expect(await ctrl.lastInsertOutcome == .noEditableTarget)
    }

    await test("accessibility denied: reports failure and does not write clipboard") {
        let cb = InMemoryClipboard(initial: "prior")
        let ins = RecordingTextInserter(forcedOutcome: .accessibilityDenied)
        let ctrl = await CommandBridgeController(clipboard: cb, inserter: ins, coordinator: coord())
        let outcome = await ctrl.applyCommit(.paste("BODY"))
        try expect(outcome == .accessibilityDenied)
        try expect(cb.writeCount == 0)
        try expect(cb.readString() == "prior")
        try expect(await ctrl.lastInsertedText == nil)
    }

    await test("selection-replace outcome is forwarded from the inserter") {
        let cb = InMemoryClipboard(initial: "prior")
        let ins = RecordingTextInserter(
            forcedOutcome: .inserted(replacedSelection: true, characters: 0))
        let ctrl = await CommandBridgeController(clipboard: cb, inserter: ins, coordinator: coord())
        let outcome = await ctrl.applyCommit(.paste("repl"))
        guard case .inserted(let replaced, _) = outcome else {
            throw TestError.assertion("expected inserted, got \(String(describing: outcome))")
        }
        try expect(replaced, "forced replace flag must round-trip")
        try expect(cb.writeCount == 0)
    }

    await test("snapshotInsertDestination: frontmost=self captures nil pid (never insert into us)") {
        let cb = InMemoryClipboard(initial: "prior")
        let ins = RecordingTextInserter()
        let ctrl = await CommandBridgeController(clipboard: cb, inserter: ins, coordinator: coord())
        await ctrl.snapshotInsertDestination(frontmost: NSRunningApplication.current)
        try expect(ins.capturedFocusPIDs.count == 1, "show-path must snapshot before key, got \(ins.capturedFocusPIDs.count)")
        try expect(ins.capturedFocusPIDs[0] == nil, "self as frontmost must not be an insert target")
        try expect(cb.writeCount == 0)
    }

    await test("snapshotInsertDestination then applyCommit still never writes the clipboard") {
        let cb = InMemoryClipboard(initial: "user-prior-clip")
        let ins = RecordingTextInserter()
        let ctrl = await CommandBridgeController(clipboard: cb, inserter: ins, coordinator: coord())
        await ctrl.snapshotInsertDestination(frontmost: NSRunningApplication.current)
        await ctrl.applyCommit(.paste("after-snapshot"))
        try expect(ins.inserts.map(\.text) == ["after-snapshot"])
        try expect(cb.readString() == "user-prior-clip")
        try expect(cb.writeCount == 0)
    }
}
