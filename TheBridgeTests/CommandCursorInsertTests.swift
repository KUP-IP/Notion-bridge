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
        try expect(!CommandInsertPointerFocus.trustsAXSet(
            role: "AXTextArea",
            frame: CGRect(x: 1699, y: 1310, width: 768, height: 60),
            chromium: true,
            bundleIdentifier: "notion.id"
        ), "Notion Electron AXTextArea reports AXValue success without mutating the composer")
        try expect(CommandInsertPointerFocus.trustsAXSet(
            role: "AXTextArea",
            frame: CGRect(x: 445, y: 909, width: 261, height: 24),
            chromium: true,
            bundleIdentifier: "com.todesktop.230313mzl4w4u92"
        ), "Cursor compact AXTextArea still lands via AX set")
        try expect(!CommandInsertPointerFocus.trustsAXSet(
            role: "AXTextArea",
            frame: CGRect(x: 331, y: 207, width: 2028, height: 1179),
            chromium: true,
            bundleIdentifier: "com.google.Chrome"
        ), "Chrome page AXTextArea is not a real AppKit field")
    }

    await test("UnicodeTyping: 20 UTF-16 stay one chunk; 21 split 20+1") {
        let twenty = String(repeating: "a", count: 20)
        let twentyOne = twenty + "b"
        let one = CommandInsertUnicodeTyping.utf16Chunks(twenty)
        let two = CommandInsertUnicodeTyping.utf16Chunks(twentyOne)
        try expect(one.count == 1, "got \(one.count)")
        try expect(one[0].count == 20, "got \(one[0].count)")
        try expect(two.count == 2, "got \(two.count)")
        try expect(two[0].count == 20 && two[1].count == 1, "got \(two.map(\.count))")
        try expect(String(utf16CodeUnits: two.flatMap { $0 }, count: 21) == twentyOne, "join must reconstruct")
    }

    await test("UnicodeTyping: does not split a surrogate pair at the chunk boundary") {
        let text = String(repeating: "a", count: 19) + "👍"
        let chunks = CommandInsertUnicodeTyping.utf16Chunks(text)
        try expect(chunks.count == 2, "got \(chunks.count)")
        try expect(chunks[0].count == 19, "would have taken high surrogate, got \(chunks[0].count)")
        try expect(chunks[1].count == 2, "emoji is one surrogate pair, got \(chunks[1].count)")
        let joined = String(utf16CodeUnits: chunks.flatMap { $0 }, count: text.utf16.count)
        try expect(joined == text, "got \(joined)")
    }

    await test("UnicodeTyping: keyUp carries unicode; keyDown is empty; carrier is not A") {
        let chunk: [UInt16] = Array("ab".utf16)
        try expect(CommandInsertUnicodeTyping.attachUnicodeToKeyUp)
        try expect(!CommandInsertUnicodeTyping.attachUnicodeToKeyDown)
        try expect(CommandInsertUnicodeTyping.carrierKeyCode != CommandInsertUnicodeTyping.ansiAKeyCode)
        try expect(CommandInsertUnicodeTyping.unicodeUnits(forKeyDown: chunk).isEmpty)
        try expect(CommandInsertUnicodeTyping.unicodeUnits(forKeyUp: chunk) == chunk)
        try expect(CommandInsertUnicodeTyping.interChunkDelay(role: "AXWebArea") == 0.008, "got \(CommandInsertUnicodeTyping.interChunkDelay(role: "AXWebArea"))")
        try expect(CommandInsertUnicodeTyping.interChunkDelay(role: "AXTextArea") == 0, "native fields need no delay")
    }

    await test("UnicodeTyping: Electron attaches unicode on keyDown; keyUp is empty") {
        let chunk: [UInt16] = Array("ab".utf16)
        try expect(CommandInsertUnicodeTyping.unicodeUnits(forKeyDown: chunk, electron: true) == chunk)
        try expect(CommandInsertUnicodeTyping.unicodeUnits(forKeyUp: chunk, electron: true).isEmpty)
        try expect(
            CommandInsertUnicodeTyping.interChunkDelay(role: "AXTextArea", electron: true) == 0.008,
            "Electron composers need the web-like inter-chunk delay"
        )
        try expect(!CommandInsertPointerFocus.hostsElectron(pid: ProcessInfo.processInfo.processIdentifier))
        try expect(!CommandInsertPointerFocus.hostsChromium(pid: ProcessInfo.processInfo.processIdentifier))
        try expect(CommandInsertPointerFocus.browserBundleID(fromHelper: "com.google.Chrome.helper.Renderer") == "com.google.Chrome")
        try expect(CommandInsertPointerFocus.browserBundleID(fromHelper: "com.google.Chrome") == nil)
        try expect(CommandInsertPointerFocus.browserBundleID(fromHelper: "com.brave.Browser.helper") == "com.brave.Browser")
        try expect(CommandInsertPointerFocus.axApplicationPID(for: ProcessInfo.processInfo.processIdentifier) == ProcessInfo.processInfo.processIdentifier)
        try expect(CommandInsertPointerFocus.looksAutomatedChromiumArguments(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/tmp/ms-playwright-mcp/mcp-chrome-7bf611f --remote-debugging-pipe about:blank"
        ))
        try expect(CommandInsertPointerFocus.looksAutomatedChromiumArguments(
            "chrome --enable-automation /Users/foo/Library/Caches/ms-playwright/chromium"
        ))
        try expect(!CommandInsertPointerFocus.looksAutomatedChromiumArguments(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-pipe"
        ), "DevTools attached to the operator browser is not Playwright")
        try expect(!CommandInsertPointerFocus.isAutomatedChromiumProcess(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        try expect(CommandInsertPointerFocus.hostsChromium(bundleIdentifier: "com.google.Chrome.helper.Renderer", bundleURL: nil))
        try expect(!CommandInsertPointerFocus.hostsChromium(bundleIdentifier: "com.apple.TextEdit", bundleURL: nil))
        try expect(CommandInsertPointerFocus.chromiumAXRetrySlices == 16)
        try expect(CommandInsertUnicodeTyping.unicodeEdgePolicy(chromium: true, bundleIdentifier: "notion.id") == .both)
        try expect(CommandInsertUnicodeTyping.unicodeEdgePolicy(chromium: true, bundleIdentifier: "com.google.Chrome") == .both)
        try expect(CommandInsertUnicodeTyping.unicodeEdgePolicy(chromium: true, bundleIdentifier: "com.todesktop.230313mzl4w4u92") == .keyDownOnly)
        try expect(CommandInsertPlaceholder.isPlaceholder(value: "Debug issues", placeholder: "Debug issues"))
        try expect(!CommandInsertPlaceholder.isPlaceholder(value: "real text", placeholder: "Debug issues"))
        try expect(CommandInsertPlaceholder.effectiveValue(value: "Debug issues", placeholder: "Debug issues") == "")
        try expect(CommandInsertUnicodeTyping.carrierKeyCode(for: .both) == CommandInsertUnicodeTyping.ansiAKeyCode)
        let chunk: [UInt16] = Array("ab".utf16)
        try expect(CommandInsertUnicodeTyping.unicodeUnits(forKeyDown: chunk, policy: .both) == chunk)
        try expect(CommandInsertUnicodeTyping.unicodeUnits(forKeyUp: chunk, policy: .both) == chunk)
    }

    await test("PointerFocus: pointer outside the focused frame prefers the pointer target") {
        let frame = CGRect(x: 579, y: 681, width: 706, height: 232)
        let pointer = CGPoint(x: 800, y: 430)
        try expect(CommandInsertPointerFocus.shouldPreferPointerTarget(
            focusedFrame: frame, pointer: pointer))
        try expect(!CommandInsertPointerFocus.shouldPreferPointerTarget(
            focusedFrame: frame, pointer: CGPoint(x: 800, y: 700)))
        try expect(CommandInsertPointerFocus.shouldPreferPointerTarget(
            focusedFrame: nil, pointer: pointer))
        try expect(!CommandInsertPointerFocus.shouldPreferPointerTarget(
            focusedFrame: frame, pointer: nil))
        try expect(CommandInsertPointerFocus.shouldPreferPointerTarget(
            focusedFrame: CGRect(x: 300, y: 72, width: 550, height: 910),
            pointer: CGPoint(x: 500, y: 875),
            focusedRole: "AXGroup"
        ), "Cursor chat column must retarget to the composer under the pointer")
        try expect(!CommandInsertPointerFocus.shouldPreferPointerTarget(
            focusedFrame: CGRect(x: 612, y: 918, width: 537, height: 43),
            pointer: CGPoint(x: 750, y: 910),
            focusedRole: "AXTextArea"
        ), "compact ChatGPT composer is already the right target")
    }

    await test("Placeholder: missing AXPlaceholderValue matches compact Chromium hint attributes") {
        try expect(CommandInsertPlaceholder.isHintValue(
            value: "Debug issues",
            placeholder: nil,
            description: "Debug issues",
            title: nil,
            compactChromiumComposer: true
        ), "missing AXPlaceholderValue still blanks when AXValue equals AXDescription")
        try expect(CommandInsertPlaceholder.isHintValue(
            value: "Debug issues",
            placeholder: nil,
            description: nil,
            title: "Debug issues",
            compactChromiumComposer: true
        ), "missing AXPlaceholderValue still blanks when AXValue equals AXTitle")
        try expect(CommandInsertPlaceholder.isHintValue(
            value: "Debug issues",
            placeholder: nil,
            description: nil,
            title: nil,
            help: "Debug issues",
            compactChromiumComposer: true
        ), "missing AXPlaceholderValue still blanks when AXValue equals AXHelp")
        try expect(!CommandInsertPlaceholder.isHintValue(
            value: "real draft",
            placeholder: nil,
            description: "Debug issues",
            title: nil,
            compactChromiumComposer: true
        ), "a real one-line draft must not match a different hint attribute")
        try expect(!CommandInsertPlaceholder.isHintValue(
            value: "Debug issues",
            placeholder: nil,
            description: "Debug issues",
            title: nil,
            compactChromiumComposer: false
        ), "native fields must not blank on description equality")
        try expect(
            CommandInsertPlaceholder.effectiveValue(
                value: "Debug issues",
                placeholder: nil,
                description: "Debug issues",
                title: nil,
                compactChromiumComposer: true
            ) == ""
        )
        try expect(
            CommandInsertPlaceholder.effectiveValue(
                value: "real draft",
                placeholder: nil,
                description: nil,
                title: nil,
                compactChromiumComposer: true
            ) == "real draft"
        )
        try expect(CommandInsertPlaceholder.isHintValue(
            value: "Send follow-up\n",
            placeholder: nil,
            description: nil,
            title: nil,
            compactChromiumComposer: true,
            selectedLocationUTF16: 0,
            selectedLengthUTF16: 0
        ), "Cursor empty composer reports the hint as AXValue with caret 0,0")
        try expect(!CommandInsertPlaceholder.isHintValue(
            value: "hello",
            placeholder: nil,
            description: nil,
            title: nil,
            compactChromiumComposer: true,
            selectedLocationUTF16: 5,
            selectedLengthUTF16: 0
        ), "caret at the end of a real draft is not a ghost")
        try expect(!CommandInsertPlaceholder.isHintValue(
            value: "Send follow-up\n",
            placeholder: "Todo description...",
            description: "Todo content",
            title: nil,
            compactChromiumComposer: true,
            selectedLocationUTF16: 0,
            selectedLengthUTF16: 0
        ), "a real placeholder attribute keeps compact Chromium drafts")
    }

    await test("PointerFocus: pointer inside a web area is the click target") {
        let frame = CGRect(x: 331, y: 207, width: 2028, height: 1179)
        let pointer = CGPoint(x: 1480, y: 1320)
        let p = CommandInsertPointerFocus.point(role: "AXWebArea", frame: frame, pointer: pointer)
        try expect(p == pointer, "got \(p)")
        let fallback = CommandInsertPointerFocus.point(
            role: "AXWebArea", frame: frame, pointer: CGPoint(x: 10, y: 10))
        try expect(fallback.x == frame.midX, "got \(fallback.x)")
    }

    await test("PointerFocus: cocoa mouse converts to quartz using the containing screen") {
        let screens = [CGRect(x: 0, y: 0, width: 2560, height: 1440)]
        let cocoa = CGPoint(x: 1480, y: 120)
        let quartz = CommandInsertPointerFocus.quartzFromCocoa(cocoa, screens: screens)
        try expect(quartz.x == 1480, "got \(quartz.x)")
        try expect(quartz.y == 1320, "got \(quartz.y)")
    }

    await test("UnicodeTyping: does not end a chunk with ** when a header follows") {
        let text = "aping or acting.\n\n**Use when:** important"
        let chunks = CommandInsertUnicodeTyping.utf16Chunks(text)
        let decoded = chunks.map { String(utf16CodeUnits: $0, count: $0.count) }
        try expect(!decoded.dropLast().contains(where: { $0.hasSuffix("**") }), "got \(decoded)")
        try expect(decoded.contains(where: { $0.contains("**Use when:**") }), "got \(decoded)")
        let joined = String(utf16CodeUnits: chunks.flatMap { $0 }, count: text.utf16.count)
        try expect(joined == text, "got \(joined)")
    }

    await test("UnicodeTyping: does not split a ** pair across chunks") {
        let text = String(repeating: "x", count: 19) + "**"
        let chunks = CommandInsertUnicodeTyping.utf16Chunks(text)
        let decoded = chunks.map { String(utf16CodeUnits: $0, count: $0.count) }
        try expect(!decoded.contains(where: { $0.hasSuffix("*") && !$0.hasSuffix("**") && $0 != "*" }), "split pair: \(decoded)")
        let joined = String(utf16CodeUnits: chunks.flatMap { $0 }, count: text.utf16.count)
        try expect(joined == text, "got \(joined)")
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
