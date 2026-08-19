// CommandCursorInsert.swift — issue #129 (cursor insert, never clipboard)
// TheBridge · Modules · Commands
//
// Command activation delivers the resolved body into the focused editable
// control of the previously-frontmost app. The clipboard is not read,
// written, cleared, or used as a paste vehicle — even temporarily.
//
// Two layers:
//   • CommandTextSplicer — pure UTF-16 splice (caret insert / selection
//     replace). Headlessly testable with no Accessibility grant.
//   • CommandTextInserting — injectable delivery seam. Production is
//     AccessibilityCommandInserter. It snapshots the focused AX element
//     *before* the palette becomes key (the query field otherwise clears
//     the destination caret). Tests inject RecordingTextInserter so the
//     suite never types into the host.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// ============================================================
// MARK: - Outcome
// ============================================================

/// Result of attempting to insert a command body at the cursor.
public enum CommandInsertOutcome: Sendable, Equatable {
    /// Body landed in the focused editable control.
    case inserted(replacedSelection: Bool, characters: Int)
    /// Resolved body was empty — nothing to insert, clipboard untouched.
    case emptyBody
    /// No focused editable AX target in the destination process.
    case noEditableTarget
    /// Accessibility TCC is missing. Prompted once; never clipboard-fallback.
    case accessibilityDenied
    /// Focused element existed but AX / synthetic insert failed.
    case insertFailed(reason: String)

    public var succeeded: Bool {
        if case .inserted = self { return true }
        return false
    }

    /// Operator-visible status. Failures are explicit; success is quiet.
    public var userMessage: String {
        switch self {
        case .inserted:
            return "Inserted at cursor"
        case .emptyBody:
            return "Command body is empty"
        case .noEditableTarget:
            return "No editable field in the frontmost app"
        case .accessibilityDenied:
            return "Accessibility permission required to insert commands"
        case .insertFailed(let reason):
            return "Could not insert command — \(reason)"
        }
    }
}

// ============================================================
// MARK: - Pure splice (UTF-16, matching AX CFRange)
// ============================================================

public struct CommandTextSplice: Sendable, Equatable {
    public let newValue: String
    public let replacedSelection: Bool
    public let newCaretUTF16: Int

    public init(newValue: String, replacedSelection: Bool, newCaretUTF16: Int) {
        self.newValue = newValue
        self.replacedSelection = replacedSelection
        self.newCaretUTF16 = newCaretUTF16
    }
}

/// UTF-16 splice used by the AX `AXValue` + `AXSelectedTextRange` path.
/// `location` / `length` are AX `CFRange` units (UTF-16), not Swift
/// `Character` indices — emoji / combining marks stay on AX's index space.
public enum CommandTextSplicer {
    public static func splice(
        value: String,
        selectedLocationUTF16: Int,
        selectedLengthUTF16: Int,
        insertion: String
    ) -> CommandTextSplice {
        let utf16 = Array(value.utf16)
        let loc = max(0, min(selectedLocationUTF16, utf16.count))
        let len = max(0, min(selectedLengthUTF16, utf16.count - loc))
        let insertUTF16 = Array(insertion.utf16)
        var combined: [UInt16] = []
        combined.reserveCapacity(utf16.count - len + insertUTF16.count)
        combined.append(contentsOf: utf16[..<loc])
        combined.append(contentsOf: insertUTF16)
        combined.append(contentsOf: utf16[(loc + len)...])
        let newValue = String(utf16CodeUnits: combined, count: combined.count)
        return CommandTextSplice(
            newValue: newValue,
            replacedSelection: len > 0,
            newCaretUTF16: loc + insertUTF16.count
        )
    }
}

// ============================================================
// MARK: - Insert seam
// ============================================================

public protocol CommandTextInserting: AnyObject, Sendable {
    /// Snapshot the focused AX element of `pid` *before* the command
    /// palette becomes key. The palette's query field steals AX focus;
    /// insert uses this snapshot instead of re-querying the live tree.
    @MainActor
    func captureFocusedElement(of pid: pid_t?)

    /// Insert `text` into the focused editable control of `pid` (the
    /// previously-frontmost app). `pid == nil` means "no destination" —
    /// production fails closed; the recording double still records.
    @MainActor
    func insert(_ text: String, intoProcess pid: pid_t?) -> CommandInsertOutcome
}

/// Test double. Never touches NSPasteboard or the live AX tree.
public final class RecordingTextInserter: CommandTextInserting, @unchecked Sendable {
    public private(set) var inserts: [(text: String, pid: pid_t?)] = []
    public private(set) var capturedFocusPIDs: [pid_t?] = []
    /// Forced outcome for the next (and subsequent) inserts. `.inserted`
    /// character counts are rewritten from the actual payload.
    public var forcedOutcome: CommandInsertOutcome

    public init(forcedOutcome: CommandInsertOutcome = .inserted(replacedSelection: false, characters: 0)) {
        self.forcedOutcome = forcedOutcome
    }

    @MainActor
    public func captureFocusedElement(of pid: pid_t?) {
        capturedFocusPIDs.append(pid)
    }

    @MainActor
    public func insert(_ text: String, intoProcess pid: pid_t?) -> CommandInsertOutcome {
        if text.isEmpty { return .emptyBody }
        inserts.append((text, pid))
        if case .inserted(let replaced, _) = forcedOutcome {
            return .inserted(replacedSelection: replaced, characters: text.count)
        }
        return forcedOutcome
    }
}

// ============================================================
// MARK: - Production AX inserter
// ============================================================

/// Inserts via the focused AX element of the destination process.
/// Never reads or writes `NSPasteboard`. Fail-closed: missing grant or
/// missing editable target returns a status outcome, not a clipboard copy.
public final class AccessibilityCommandInserter: CommandTextInserting, @unchecked Sendable {
    /// Focused element of the destination app, captured before the
    /// palette becomes key. AXUIElement is not Sendable; this class is
    /// already `@unchecked Sendable` and only touched on the main actor.
    private var capturedElement: AXUIElement?
    private var capturedPID: pid_t?

    public init() {}

    @MainActor
    public func captureFocusedElement(of pid: pid_t?) {
        capturedElement = nil
        capturedPID = pid
        guard AXIsProcessTrusted(), let pid, pid > 0 else { return }
        capturedElement = copyFocusedElement(of: pid)
    }

    @MainActor
    public func insert(_ text: String, intoProcess pid: pid_t?) -> CommandInsertOutcome {
        if text.isEmpty { return .emptyBody }

        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            )
            return .accessibilityDenied
        }

        guard let pid, pid > 0 else { return .noEditableTarget }

        let usedCapture = (capturedPID == pid && capturedElement != nil)
        let focused = usedCapture ? capturedElement : copyFocusedElement(of: pid)
        guard let focused else { return .noEditableTarget }

        let role = stringAttr(focused, kAXRoleAttribute as String) ?? ""
        if role == "AXSecureTextField" {
            return .noEditableTarget
        }

        let selectedRange = cfRangeAttr(focused, kAXSelectedTextRangeAttribute as String)
        let loc = selectedRange?.location ?? 0
        let len = selectedRange?.length ?? 0
        let replaced = len > 0
        let before = stringAttr(focused, kAXValueAttribute as String)
        let frame = axFrame(focused)
        let electron = CommandInsertPointerFocus.hostsElectron(pid: pid)
        let trustAX = CommandInsertPointerFocus.trustsAXSet(role: role, frame: frame)

        if trustAX, isSettable(focused, kAXSelectedTextAttribute as String) {
            let setErr = AXUIElementSetAttributeValue(
                focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if setErr == .success,
               axVerifyLanded(
                focused,
                before: before,
                insertion: text,
                loc: loc,
                len: len,
                electron: electron
               ) {
                placeCaret(focused, afterUTF16: loc + text.utf16.count)
                return .inserted(replacedSelection: replaced, characters: text.count)
            }
        }

        if trustAX, isSettable(focused, kAXValueAttribute as String),
           let current = before ?? stringAttr(focused, kAXValueAttribute as String),
           let range = selectedRange {
            let spliced = CommandTextSplicer.splice(
                value: current,
                selectedLocationUTF16: range.location,
                selectedLengthUTF16: range.length,
                insertion: text
            )
            let setErr = AXUIElementSetAttributeValue(
                focused, kAXValueAttribute as CFString, spliced.newValue as CFTypeRef)
            if setErr == .success,
               axVerifyLanded(
                focused,
                before: before,
                insertion: text,
                loc: range.location,
                len: range.length,
                electron: electron
               ) {
                placeCaret(focused, afterUTF16: spliced.newCaretUTF16)
                return .inserted(replacedSelection: spliced.replacedSelection, characters: text.count)
            }
        }

        // Native AX fields that actually changed are done above. Chromium
        // AXValue can lag; only type after delayed verify still fails.
        if usedCapture || looksEditable(role: role, element: focused) {
            restoreFocus(focused, pid: pid)
            clickForPointerFocus(focused, role: role, electron: electron)
            do {
                try postUnicode(
                    text,
                    interChunkDelay: CommandInsertUnicodeTyping.interChunkDelay(
                        role: role, electron: electron),
                    electron: electron
                )
                return .inserted(replacedSelection: replaced, characters: text.count)
            } catch {
                return .insertFailed(reason: "synthetic typing failed")
            }
        }

        return .noEditableTarget
    }

    @MainActor
    private func copyFocusedElement(of pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        if let el = focusedUIElement(appEl) { return el }

        // Cursor Agents publishes a chrome-only AX tree until a client
        // sets AXManualAccessibility. Focused UI is kAXErrorNoValue.
        _ = AXUIElementSetAttributeValue(
            appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        for _ in 0..<CommandInsertPointerFocus.chromiumAXRetrySlices {
            _ = CFRunLoopRunInMode(
                CFRunLoopMode.defaultMode,
                CommandInsertPointerFocus.chromiumAXRetrySliceSeconds,
                false)
            if let el = focusedUIElement(appEl) { return el }
        }
        return nil
    }

    private func focusedUIElement(_ appEl: AXUIElement) -> AXUIElement? {
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focusedRef else { return nil }
        return (focusedRef as! AXUIElement)
    }

    /// Chromium often reports AX set success before AXValue updates.
    /// Re-read on Electron so a delayed land does not fall through to unicode.
    private func axVerifyLanded(
        _ focused: AXUIElement,
        before: String?,
        insertion: String,
        loc: Int,
        len: Int,
        electron: Bool
    ) -> Bool {
        let check = {
            CommandInsertAXVerify.landed(
                before: before,
                after: self.stringAttr(focused, kAXValueAttribute as String),
                insertion: insertion,
                selectedLocationUTF16: loc,
                selectedLengthUTF16: len
            )
        }
        if check() { return true }
        guard electron else { return false }
        for _ in 0..<CommandInsertPointerFocus.chromiumAXRetrySlices {
            _ = CFRunLoopRunInMode(
                CFRunLoopMode.defaultMode,
                CommandInsertPointerFocus.chromiumAXRetrySliceSeconds,
                false)
            if check() { return true }
        }
        return false
    }

    /// Put the caret back on `element` so CGEvent unicode typing lands
    /// there instead of the (now dismissed) palette query field.
    @MainActor
    private func restoreFocus(_ element: AXUIElement, pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Click the captured control so Electron/Chromium contenteditables
    /// actually receive the following unicode key events.
    @MainActor
    private func clickForPointerFocus(_ element: AXUIElement, role: String, electron: Bool) {
        guard let rect = axFrame(element), rect.width > 1, rect.height > 1 else { return }
        let point = CommandInsertPointerFocus.point(role: role, frame: rect)
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        guard let down = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        let settle = (electron || CommandInsertPointerFocus.isWebLike(role)) ? 0.08 : 0.04
        _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, settle, false)
    }

    private func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(
            el, kAXPositionAttribute as CFString, &posRef)
        let sizeErr = AXUIElementCopyAttributeValue(
            el, kAXSizeAttribute as CFString, &sizeRef)
        guard posErr == .success, sizeErr == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: AX helpers

    private func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }

    private func cfRangeAttr(_ el: AXUIElement, _ name: String) -> CFRange? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &ref)
        guard err == .success, let ref else { return nil }
        let axVal = ref as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }
        return range
    }

    private func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(el, name as CFString, &settable)
        return err == .success && settable.boolValue
    }

    private func looksEditable(role: String, element: AXUIElement) -> Bool {
        let editable: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXText"
        ]
        if editable.contains(role) { return true }
        return isSettable(element, kAXValueAttribute as String)
            || isSettable(element, kAXSelectedTextAttribute as String)
    }

    private func placeCaret(_ el: AXUIElement, afterUTF16 loc: Int) {
        var range = CFRange(location: loc, length: 0)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(
            el, kAXSelectedTextRangeAttribute as CFString, axRange)
    }

    /// Unicode CGEvent typing — no pasteboard. Last-resort when AX set
    /// fails but the focused element still looks like an editor.
    ///
    /// Native editors attach unicode on keyUp. Electron ignores keyUp-only
    /// unicode, so Electron attaches on keyDown and leaves keyUp empty.
    /// `virtualKey` 0 is kVK_ANSI_A — carrier 0xFFFF plus an empty payload
    /// on the unused edge avoids an A-key leak.
    private func postUnicode(
        _ text: String,
        interChunkDelay: TimeInterval = 0,
        electron: Bool = false
    ) throws {
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw CommandInsertSynthError.source
        }
        let chunks = CommandInsertUnicodeTyping.utf16Chunks(text)
        let vk = CommandInsertUnicodeTyping.carrierKeyCode
        for (i, chunk) in chunks.enumerated() {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)
            else { throw CommandInsertSynthError.event }
            setUnicode(down, CommandInsertUnicodeTyping.unicodeUnits(forKeyDown: chunk, electron: electron))
            setUnicode(up, CommandInsertUnicodeTyping.unicodeUnits(forKeyUp: chunk, electron: electron))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if interChunkDelay > 0, i + 1 < chunks.count {
                Thread.sleep(forTimeInterval: interChunkDelay)
            }
        }
    }

    private func setUnicode(_ event: CGEvent, _ units: [UInt16]) {
        if units.isEmpty {
            var zero: UniChar = 0
            event.keyboardSetUnicodeString(stringLength: 0, unicodeString: &zero)
            return
        }
        units.withUnsafeBufferPointer { buf in
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buf.baseAddress)
        }
    }
}

private enum CommandInsertSynthError: Error {
    case source
    case event
}

/// Read-back after a claimed AX text set. Chromium AXTextArea reports
/// settable + success without changing AXValue (Cursor composer).
public enum CommandInsertAXVerify {
    public static func landed(
        before: String?,
        after: String?,
        insertion: String,
        selectedLocationUTF16: Int,
        selectedLengthUTF16: Int
    ) -> Bool {
        guard !insertion.isEmpty else { return true }
        guard let after else { return false }
        let base = before ?? ""
        let expected = CommandTextSplicer.splice(
            value: base,
            selectedLocationUTF16: selectedLocationUTF16,
            selectedLengthUTF16: selectedLengthUTF16,
            insertion: insertion
        ).newValue
        if after == expected { return true }
        return after != base && after.contains(insertion)
    }
}

/// Pure click-target math for the Chromium fallback. Native AX fields
/// use the control center; web areas put the composer at the bottom.
public enum CommandInsertPointerFocus {
    public static let webLikeRoles: Set<String> = ["AXWebArea", "AXGroup", "AXUnknown"]
    public static let tallWebAreaThreshold: CGFloat = 120
    public static let chromiumAXRetrySlices = 16
    public static let chromiumAXRetrySliceSeconds: CFTimeInterval = 0.05

    public static func isWebLike(_ role: String) -> Bool {
        webLikeRoles.contains(role)
    }

    /// Cursor / VS Code: Electron Framework.framework. Native AppKit editors do not.
    public static func hostsElectron(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let url = app.bundleURL else { return false }
        let framework = url.appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// Chromium `AXWebArea` (and page-sized groups) report settable AXValue
    /// without mutating the DOM. Native fields still use AX set + read-back.
    public static func trustsAXSet(role: String, frame: CGRect?) -> Bool {
        if role == "AXWebArea" { return false }
        if isWebLike(role), let frame, frame.height >= tallWebAreaThreshold {
            return false
        }
        return true
    }

    public static func point(role: String, frame: CGRect) -> CGPoint {
        if isWebLike(role) {
            let inset: CGFloat
            if frame.height >= tallWebAreaThreshold {
                // Page-sized Cursor Agents web area is ~1387px; a 28px
                // cap lands in the 24px "Send follow-up" strip.
                inset = min(120, max(48, frame.height * 0.08))
            } else {
                inset = min(28, max(8, frame.height * 0.12))
            }
            return CGPoint(x: frame.midX, y: frame.maxY - inset)
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// UTF-16 chunking + keyUp-only unicode policy for synthetic insert.
/// CGEvent `keyboardSetUnicodeString` caps at ~20 UTF-16 units; surrogate
/// pairs and markdown `**` markers must not be split across chunks.
public enum CommandInsertUnicodeTyping {
    public static let maxUTF16PerChunk = 20
    /// kVK_ANSI_A. An unset keyUp on this code posts `"a"`.
    public static let ansiAKeyCode: CGKeyCode = 0
    /// Non-character carrier so an empty unicode payload types nothing.
    public static let carrierKeyCode: CGKeyCode = 0xFFFF
    public static let attachUnicodeToKeyDown = false
    public static let attachUnicodeToKeyUp = true
    public static let webLikeInterChunkDelay: TimeInterval = 0.008

    public static func interChunkDelay(role: String, electron: Bool = false) -> TimeInterval {
        (electron || CommandInsertPointerFocus.isWebLike(role)) ? webLikeInterChunkDelay : 0
    }

    public static func unicodeUnits(forKeyDown chunk: [UInt16], electron: Bool = false) -> [UInt16] {
        electron ? chunk : (attachUnicodeToKeyDown ? chunk : [])
    }

    public static func unicodeUnits(forKeyUp chunk: [UInt16], electron: Bool = false) -> [UInt16] {
        electron ? [] : (attachUnicodeToKeyUp ? chunk : [])
    }

    public static func utf16Chunks(_ text: String, maxUTF16: Int = maxUTF16PerChunk) -> [[UInt16]] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }
        let cap = max(1, maxUTF16)
        var chunks: [[UInt16]] = []
        var idx = 0
        while idx < units.count {
            var end = min(idx + cap, units.count)
            if end < units.count, isHighSurrogate(units[end - 1]) {
                end -= 1
            }
            // Don't split a `**` pair across chunks.
            if end < units.count, end > idx, units[end - 1] == 0x2A, units[end] == 0x2A {
                end -= 1
            }
            // Don't end a chunk with `**` when more text follows — keep the
            // marker with the next header (`**Use when:**`, not `**` + `Use when:**`).
            if end < units.count, end - idx >= 2,
               units[end - 2] == 0x2A, units[end - 1] == 0x2A {
                end -= 2
            }
            if end <= idx {
                end = idx + 1
            }
            chunks.append(Array(units[idx..<end]))
            idx = end
        }
        return chunks
    }

    private static func isHighSurrogate(_ u: UInt16) -> Bool {
        u >= 0xD800 && u <= 0xDBFF
    }
}
