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
//     AccessibilityCommandInserter (AX focused element). Tests inject
//     RecordingTextInserter so the suite never types into the host.

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
    /// Insert `text` into the focused editable control of `pid` (the
    /// previously-frontmost app). `pid == nil` means "no destination" —
    /// production fails closed; the recording double still records.
    @MainActor
    func insert(_ text: String, intoProcess pid: pid_t?) -> CommandInsertOutcome
}

/// Test double. Never touches NSPasteboard or the live AX tree.
public final class RecordingTextInserter: CommandTextInserting, @unchecked Sendable {
    public private(set) var inserts: [(text: String, pid: pid_t?)] = []
    /// Forced outcome for the next (and subsequent) inserts. `.inserted`
    /// character counts are rewritten from the actual payload.
    public var forcedOutcome: CommandInsertOutcome

    public init(forcedOutcome: CommandInsertOutcome = .inserted(replacedSelection: false, characters: 0)) {
        self.forcedOutcome = forcedOutcome
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
    public init() {}

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

        let appEl = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusErr == .success, let focusedRef else {
            return .noEditableTarget
        }
        let focused = focusedRef as! AXUIElement

        let role = stringAttr(focused, kAXRoleAttribute as String) ?? ""
        if role == "AXSecureTextField" {
            return .noEditableTarget
        }

        let selectedRange = cfRangeAttr(focused, kAXSelectedTextRangeAttribute as String)
        let replaced = (selectedRange?.length ?? 0) > 0

        if isSettable(focused, kAXSelectedTextAttribute as String) {
            let setErr = AXUIElementSetAttributeValue(
                focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if setErr == .success {
                placeCaret(focused, afterUTF16: (selectedRange?.location ?? 0) + text.utf16.count)
                return .inserted(replacedSelection: replaced, characters: text.count)
            }
        }

        if isSettable(focused, kAXValueAttribute as String),
           let current = stringAttr(focused, kAXValueAttribute as String),
           let range = selectedRange {
            let spliced = CommandTextSplicer.splice(
                value: current,
                selectedLocationUTF16: range.location,
                selectedLengthUTF16: range.length,
                insertion: text
            )
            let setErr = AXUIElementSetAttributeValue(
                focused, kAXValueAttribute as CFString, spliced.newValue as CFTypeRef)
            if setErr == .success {
                placeCaret(focused, afterUTF16: spliced.newCaretUTF16)
                return .inserted(replacedSelection: spliced.replacedSelection, characters: text.count)
            }
        }

        if looksEditable(role: role, element: focused) {
            do {
                try postUnicode(text)
                return .inserted(replacedSelection: replaced, characters: text.count)
            } catch {
                return .insertFailed(reason: "synthetic typing failed")
            }
        }

        return .noEditableTarget
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
    private func postUnicode(_ text: String) throws {
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw CommandInsertSynthError.source
        }
        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var idx = 0
        while idx < utf16.count {
            let end = min(idx + chunkSize, utf16.count)
            let chunk = Array(utf16[idx..<end])
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { throw CommandInsertSynthError.event }
            chunk.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            idx = end
        }
    }
}

private enum CommandInsertSynthError: Error {
    case source
    case event
}
