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
import Darwin

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

/// Ghost / placeholder strings Chromium reports as `AXValue` even when the
/// composer is visually empty. Splicing into that string bakes the hint
/// into the insert (`Debug issues` + command body).
///
/// Cursor's compact `AXTextArea` often omits `AXPlaceholderValue`. The hint
/// still shows up as `AXValue` equal to `AXDescription` or `AXTitle`. Native
/// fields and real one-line drafts must not be blanked by that fallback.
public enum CommandInsertPlaceholder {
    public static func effectiveValue(value: String?, placeholder: String?) -> String? {
        effectiveValue(
            value: value,
            placeholder: placeholder,
            description: nil,
            title: nil,
            compactChromiumComposer: false
        )
    }

    public static func effectiveValue(
        value: String?,
        placeholder: String?,
        description: String?,
        title: String?,
        compactChromiumComposer: Bool
    ) -> String? {
        guard let value else { return nil }
        if isHintValue(
            value: value,
            placeholder: placeholder,
            description: description,
            title: title,
            compactChromiumComposer: compactChromiumComposer
        ) { return "" }
        return value
    }

    public static func isPlaceholder(value: String?, placeholder: String?) -> Bool {
        guard let value, !value.isEmpty,
              let placeholder, !placeholder.isEmpty else { return false }
        return value == placeholder
    }

    public static func isHintValue(
        value: String?,
        placeholder: String?,
        description: String?,
        title: String?,
        help: String? = nil,
        compactChromiumComposer: Bool
    ) -> Bool {
        if isPlaceholder(value: value, placeholder: placeholder) { return true }
        guard compactChromiumComposer else { return false }
        guard let value, !value.isEmpty else { return false }
        guard (placeholder ?? "").isEmpty else { return false }
        for hint in [description, title, help] {
            if let hint, !hint.isEmpty, value == hint { return true }
        }
        return false
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
    /// Quartz pointer at snapshot time. Notion-in-Chrome composers sit in a
    /// page-sized AXWebArea; mid-bottom click misses the right-sidebar field.
    private var capturedPointer: CGPoint?
    private var capturedSelectedLocation: Int?
    private var capturedSelectedLength: Int?
    private var capturedValue: String?

    public init() {}

    @MainActor
    public func captureFocusedElement(of pid: pid_t?) {
        capturedElement = nil
        capturedPID = pid
        capturedPointer = quartzPointer()
        capturedSelectedLocation = nil
        capturedSelectedLength = nil
        capturedValue = nil
        let trusted = AXIsProcessTrusted()
        guard trusted, let pid, pid > 0 else {
            return
        }
        capturedElement = copyFocusedElement(of: pid)
        if let pointer = capturedPointer,
           CommandInsertPointerFocus.shouldPreferPointerTarget(
            focusedFrame: capturedElement.flatMap(axFrame),
            pointer: pointer,
            focusedRole: capturedElement.flatMap { stringAttr($0, kAXRoleAttribute as String) }
           ),
           let pointerEl = (
            editableAtPointer(pointer: pointer, pid: pid)
                ?? capturedElement.flatMap { compactEditable(in: $0, pointer: pointer) }
                ?? compactEditable(pid: pid, pointer: pointer)
           ) {
            capturedElement = pointerEl
        }
        if let el = capturedElement {
            snapshotCapturedCaret(el)
        }
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

        var usedCapture = (capturedPID == pid && capturedElement != nil)
        var focused = usedCapture ? capturedElement : copyFocusedElement(of: pid)
        let pointerForRetarget = capturedPID == pid ? capturedPointer : quartzPointer()
        if let focusedEl = focused,
           CommandInsertPointerFocus.shouldPreferPointerTarget(
            focusedFrame: axFrame(focusedEl),
            pointer: pointerForRetarget,
            focusedRole: stringAttr(focusedEl, kAXRoleAttribute as String)
           ),
           let pointerEl = pointerForRetarget.flatMap({ pointer in
               editableAtPointer(pointer: pointer, pid: pid)
                   ?? compactEditable(in: focusedEl, pointer: pointer)
                   ?? compactEditable(pid: pid, pointer: pointer)
           }) {
            focused = pointerEl
            usedCapture = false
        }
        guard let focused else {
            return .noEditableTarget
        }

        let role = stringAttr(focused, kAXRoleAttribute as String) ?? ""
        if role == "AXSecureTextField" {
            return .noEditableTarget
        }

        let liveRange = cfRangeAttr(focused, kAXSelectedTextRangeAttribute as String)
        let liveValue = stringAttr(focused, kAXValueAttribute as String)
        let placeholder = stringAttr(focused, kAXPlaceholderValueAttribute as String)
        let description = stringAttr(focused, kAXDescriptionAttribute as String)
        let title = stringAttr(focused, kAXTitleAttribute as String)
        let help = stringAttr(focused, kAXHelpAttribute as String)
        let chromium = CommandInsertPointerFocus.hostsChromium(pid: pid)
        let compactChromium = chromium && isCompactEditable(focused)
        var loc: Int
        var len: Int
        var before: String?
        if usedCapture, let snapLoc = capturedSelectedLocation {
            loc = snapLoc
            len = capturedSelectedLength ?? 0
            before = capturedValue ?? liveValue
        } else {
            loc = liveRange?.location ?? 0
            len = liveRange?.length ?? 0
            before = liveValue
        }
        let valueIsPlaceholder = CommandInsertPlaceholder.isHintValue(
            value: before,
            placeholder: placeholder,
            description: description,
            title: title,
            help: help,
            compactChromiumComposer: compactChromium)
            || CommandInsertPlaceholder.isHintValue(
                value: liveValue,
                placeholder: placeholder,
                description: description,
                title: title,
                help: help,
                compactChromiumComposer: compactChromium)
        if valueIsPlaceholder {
            loc = 0
            len = 0
            before = ""
        }
        let replaced = len > 0
        if usedCapture, capturedSelectedLocation != nil {
            restoreSelectedRange(focused, locationUTF16: loc, lengthUTF16: len)
        }
        let frame = axFrame(focused)
        let app = NSRunningApplication(processIdentifier: pid)
        let trustAX = CommandInsertPointerFocus.trustsAXSet(
            role: role,
            frame: frame,
            chromium: chromium,
            bundleIdentifier: app?.bundleIdentifier
        )
        let pointer = capturedPID == pid ? capturedPointer : quartzPointer()
        let policy = CommandInsertUnicodeTyping.unicodeEdgePolicy(
            chromium: chromium,
            bundleIdentifier: app?.bundleIdentifier
        )

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
                electron: chromium
               ) {
                placeCaret(focused, afterUTF16: loc + text.utf16.count)
                return .inserted(replacedSelection: replaced, characters: text.count)
            }
        }

        if trustAX, isSettable(focused, kAXValueAttribute as String),
           let current = before ?? liveValue {
            let spliced = CommandTextSplicer.splice(
                value: current,
                selectedLocationUTF16: loc,
                selectedLengthUTF16: len,
                insertion: text
            )
            let setErr = AXUIElementSetAttributeValue(
                focused, kAXValueAttribute as CFString, spliced.newValue as CFTypeRef)
            if setErr == .success,
               axVerifyLanded(
                focused,
                before: before,
                insertion: text,
                loc: loc,
                len: len,
                electron: chromium
               ) {
                placeCaret(focused, afterUTF16: spliced.newCaretUTF16)
                return .inserted(replacedSelection: spliced.replacedSelection, characters: text.count)
            }
        }

        // Native AX fields that actually changed are done above. Chromium
        // AXValue can lag; only type after delayed verify still fails.
        // Do not type into a captured page-sized AXGroup — that claims
        // success while the compact composer stays empty (Cursor).
        let mayType = looksEditable(role: role, element: focused)
            && !(CommandInsertPointerFocus.isWebLike(role)
                 && (frame?.height ?? 0) >= CommandInsertPointerFocus.tallWebAreaThreshold)
        if mayType {
            restoreFocus(focused, pid: pid)
            clickForPointerFocus(focused, role: role, electron: chromium, pointer: pointer)
            do {
                try postUnicode(
                    text,
                    interChunkDelay: CommandInsertUnicodeTyping.interChunkDelay(
                        role: role, electron: chromium),
                    policy: policy
                )
                return .inserted(replacedSelection: replaced, characters: text.count)
            } catch {
                return .insertFailed(reason: "synthetic typing failed")
            }
        }

        return .noEditableTarget
    }

    private func snapshotCapturedCaret(_ el: AXUIElement) {
        let range = cfRangeAttr(el, kAXSelectedTextRangeAttribute as String)
        capturedSelectedLocation = range?.location
        capturedSelectedLength = range?.length
        let rawValue = stringAttr(el, kAXValueAttribute as String)
        let placeholder = stringAttr(el, kAXPlaceholderValueAttribute as String)
        let description = stringAttr(el, kAXDescriptionAttribute as String)
        let title = stringAttr(el, kAXTitleAttribute as String)
        let help = stringAttr(el, kAXHelpAttribute as String)
        let compactChromium = capturedPID.map(CommandInsertPointerFocus.hostsChromium) == true
            && isCompactEditable(el)
        if CommandInsertPlaceholder.isHintValue(
            value: rawValue,
            placeholder: placeholder,
            description: description,
            title: title,
            help: help,
            compactChromiumComposer: compactChromium
        ) {
            capturedValue = ""
            capturedSelectedLocation = 0
            capturedSelectedLength = 0
        } else {
            capturedValue = rawValue
        }
    }

    private func editableAtPointer(pointer: CGPoint, pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        var ref: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            appEl, Float(pointer.x), Float(pointer.y), &ref)
        guard err == .success, let start = ref else {
            return nil
        }
        if let compact = nearestCompactEditable(from: start, pointer: pointer) {
            return compact
        }
        return nil
    }

    private func isCompactEditable(_ el: AXUIElement) -> Bool {
        let role = stringAttr(el, kAXRoleAttribute as String) ?? ""
        let compact: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXText"
        ]
        guard compact.contains(role) else { return false }
        if let frame = axFrame(el),
           frame.height >= CommandInsertPointerFocus.tallWebAreaThreshold {
            return false
        }
        return true
    }

    /// Cursor's composer is a compact AXTextArea beside chips; the hit test
    /// often lands on the Debug chip or + button. Walk ancestors and BFS
    /// children for a compact field near the pointer.
    private func nearestCompactEditable(from start: AXUIElement, pointer: CGPoint) -> AXUIElement? {
        var current: AXUIElement? = start
        var hops = 0
        var fallback: AXUIElement?
        while let el = current, hops < 10 {
            hops += 1
            if isCompactEditable(el) { return el }
            var queue = [el]
            var seen = 0
            while !queue.isEmpty, seen < 60 {
                let node = queue.removeFirst()
                seen += 1
                if isCompactEditable(node) {
                    if let frame = axFrame(node) {
                        if frame.insetBy(dx: -24, dy: -24).contains(pointer) {
                            return node
                        }
                        if abs(frame.midY - pointer.y) < 48 {
                            fallback = fallback ?? node
                        }
                    }
                }
                var kidsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    node, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                   let kids = kidsRef as? [AXUIElement] {
                    queue.append(contentsOf: kids.prefix(20))
                }
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                el, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else { break }
            current = (parentRef as! AXUIElement)
        }
        return fallback
    }

    private func compactEditable(in root: AXUIElement, pointer: CGPoint) -> AXUIElement? {
        var owner: pid_t = 0
        AXUIElementGetPid(root, &owner)
        if owner > 0 {
            let appEl = AXUIElementCreateApplication(owner)
            _ = AXUIElementSetAttributeValue(
                appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var queue = [root]
        var seen = 0
        var near: AXUIElement?
        while !queue.isEmpty, seen < 500 {
            let el = queue.removeFirst()
            seen += 1
            if isCompactEditable(el), let frame = axFrame(el) {
                if frame.insetBy(dx: -16, dy: -16).contains(pointer) {
                    return el
                }
                if abs(frame.midY - pointer.y) < 48, abs(frame.midX - pointer.x) < 400 {
                    near = near ?? el
                }
            }
            var kidsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                queue.append(contentsOf: kids.prefix(40))
            }
        }
        return near
    }

    private func compactEditable(pid: pid_t, pointer: CGPoint) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        _ = AXUIElementSetAttributeValue(
            appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        var queue = windows
        var seen = 0
        var near: AXUIElement?
        while !queue.isEmpty, seen < 800 {
            let el = queue.removeFirst()
            seen += 1
            if isCompactEditable(el), let frame = axFrame(el) {
                if frame.insetBy(dx: -16, dy: -16).contains(pointer) {
                    return el
                }
                if abs(frame.midY - pointer.y) < 64, abs(frame.midX - pointer.x) < 500 {
                    near = near ?? el
                }
            }
            var kidsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                queue.append(contentsOf: kids.prefix(40))
            }
        }
        return near
    }

    @MainActor
    private func copyFocusedElement(of pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        let chromium = CommandInsertPointerFocus.hostsChromium(pid: pid)
        if let el = focusedUIElement(appEl) {
            let role = stringAttr(el, kAXRoleAttribute as String) ?? ""
            let frame = axFrame(el)
            let tallWeb = CommandInsertPointerFocus.isWebLike(role)
                && (frame?.height ?? 0) >= CommandInsertPointerFocus.tallWebAreaThreshold
            if !chromium || !tallWeb {
                return el
            }
            // Cursor chat column is a focused AXGroup until ManualAX
            // publishes the compact composer AXTextArea.
            _ = AXUIElementSetAttributeValue(
                appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            for _ in 0..<CommandInsertPointerFocus.chromiumAXRetrySlices {
                _ = CFRunLoopRunInMode(
                    CFRunLoopMode.defaultMode,
                    CommandInsertPointerFocus.chromiumAXRetrySliceSeconds,
                    false)
                if let next = focusedUIElement(appEl) {
                    let nextRole = stringAttr(next, kAXRoleAttribute as String) ?? ""
                    let nextFrame = axFrame(next)
                    let nextTall = CommandInsertPointerFocus.isWebLike(nextRole)
                        && (nextFrame?.height ?? 0) >= CommandInsertPointerFocus.tallWebAreaThreshold
                    if !nextTall {
                        return next
                    }
                }
            }
            return el
        }
        if let el = systemWideFocusedElement(matching: pid) {
            return el
        }
        if chromium {
            _ = AXUIElementSetAttributeValue(
                appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            for _ in 0..<CommandInsertPointerFocus.chromiumAXRetrySlices {
                _ = CFRunLoopRunInMode(
                    CFRunLoopMode.defaultMode,
                    CommandInsertPointerFocus.chromiumAXRetrySliceSeconds,
                    false)
                if let el = focusedUIElement(appEl) {
                    return el
                }
            }
            if let el = systemWideFocusedElement(matching: pid) {
                return el
            }
            if let el = firstWebArea(in: pid) {
                return el
            }
        }
        return nil
    }

    private func systemWideFocusedElement(matching pid: pid_t) -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 2.0)
        var appRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            sys, kAXFocusedApplicationAttribute as CFString, &appRef)
        guard err == .success, let appRef else { return nil }
        let focusedApp = appRef as! AXUIElement
        var appPid: pid_t = 0
        AXUIElementGetPid(focusedApp, &appPid)
        guard CommandInsertPointerFocus.isDestinationFamily(
            destinationPID: pid, elementPID: appPid) else { return nil }
        return focusedUIElement(focusedApp)
    }

    private func firstWebArea(in pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        var queue = windows
        var seen = 0
        while !queue.isEmpty, seen < 500 {
            let el = queue.removeFirst()
            seen += 1
            if stringAttr(el, kAXRoleAttribute as String) == "AXWebArea" { return el }
            var kidsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                queue.append(contentsOf: kids.prefix(50))
            }
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
    private func clickForPointerFocus(
        _ element: AXUIElement,
        role: String,
        electron: Bool,
        pointer: CGPoint?
    ) {
        guard let rect = axFrame(element), rect.width > 1, rect.height > 1 else { return }
        let point = CommandInsertPointerFocus.point(role: role, frame: rect, pointer: pointer)
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
        if role == "AXWebArea" { return true }
        let editable: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXText"
        ]
        if editable.contains(role) { return true }
        return isSettable(element, kAXValueAttribute as String)
            || isSettable(element, kAXSelectedTextAttribute as String)
    }

    private func quartzPointer() -> CGPoint {
        let cocoa = NSEvent.mouseLocation
        return CommandInsertPointerFocus.quartzFromCocoa(cocoa, screens: NSScreen.screens.map(\.frame))
    }

    private func restoreSelectedRange(
        _ el: AXUIElement,
        locationUTF16 loc: Int,
        lengthUTF16 len: Int
    ) {
        var range = CFRange(location: max(0, loc), length: max(0, len))
        guard let axRange = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(
            el, kAXSelectedTextRangeAttribute as CFString, axRange)
    }

    private func placeCaret(_ el: AXUIElement, afterUTF16 loc: Int) {
        restoreSelectedRange(el, locationUTF16: loc, lengthUTF16: 0)
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
        electron: Bool = false,
        policy: CommandInsertUnicodeTyping.EdgePolicy? = nil
    ) throws {
        let policy = policy ?? (electron ? .keyDownOnly : .keyUpOnly)
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw CommandInsertSynthError.source
        }
        let chunks = CommandInsertUnicodeTyping.utf16Chunks(text)
        let vk = CommandInsertUnicodeTyping.carrierKeyCode(for: policy)
        for (i, chunk) in chunks.enumerated() {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)
            else { throw CommandInsertSynthError.event }
            setUnicode(down, CommandInsertUnicodeTyping.unicodeUnits(forKeyDown: chunk, policy: policy))
            setUnicode(up, CommandInsertUnicodeTyping.unicodeUnits(forKeyUp: chunk, policy: policy))
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

    /// Chrome / Edge / Brave / Electron: unicode must ride keyDown.
    public static func hostsChromium(pid: pid_t) -> Bool {
        if hostsElectron(pid: pid) { return true }
        let app = NSRunningApplication(processIdentifier: pid)
        return hostsChromium(bundleIdentifier: app?.bundleIdentifier, bundleURL: app?.bundleURL)
    }

    public static func hostsChromium(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        if let url = bundleURL {
            let names = [
                "Contents/Frameworks/Electron Framework.framework",
                "Contents/Frameworks/Google Chrome Framework.framework",
                "Contents/Frameworks/Chromium Embedded Framework.framework"
            ]
            for name in names {
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path) {
                    return true
                }
            }
        }
        let id = bundleIdentifier ?? ""
        if id.hasPrefix("com.google.Chrome") { return true }
        switch id {
        case "com.brave.Browser",
             "com.microsoft.edgemac",
             "company.thebrowser.Browser",
             "com.operasoftware.Opera",
             "com.vivaldi.Vivaldi":
            return true
        default:
            return false
        }
    }

    /// Chrome/Edge/Brave renderer helpers have no AX tree. The browser
    /// process (`com.google.Chrome`) does. `com.google.Chrome.helper.Renderer`
    /// → `com.google.Chrome`.
    public static func browserBundleID(fromHelper id: String) -> String? {
        guard let range = id.range(of: ".helper") else { return nil }
        let root = String(id[..<range.lowerBound])
        return root.isEmpty ? nil : root
    }

    /// Playwright MCP / Chromedriver launch a second Chrome with the same
    /// bundle ID. `NSWorkspace.frontmostApplication` and
    /// `runningApplications(withBundleIdentifier:).first` often pick that
    /// instance (`about:blank`) instead of the operator's browser.
    public static func looksAutomatedChromiumArguments(_ blob: String) -> Bool {
        let lower = blob.lowercased()
        return lower.contains("playwright")
            || lower.contains("mcp-chrome")
            || lower.contains("/ms-playwright")
    }

    public static func processArgumentBlob(pid: pid_t) -> String? {
        let kernProcArgs2: Int32 = 49
        var mib: [Int32] = [CTL_KERN, kernProcArgs2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        for i in 0..<size where buffer[i] == 0 {
            buffer[i] = 32
        }
        return String(bytes: buffer.prefix(size), encoding: .utf8)
            ?? String(decoding: buffer.prefix(size), as: UTF8.self)
    }

    public static func isAutomatedChromiumProcess(pid: pid_t) -> Bool {
        guard let blob = processArgumentBlob(pid: pid) else { return false }
        return looksAutomatedChromiumArguments(blob)
    }

    /// Map helpers to the browser process, then skip Playwright/MCP Chrome
    /// siblings that share `com.google.Chrome`.
    public static func preferredBrowserPID(for pid: pid_t) -> pid_t {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let id = app.bundleIdentifier else { return pid }
        let rootID = browserBundleID(fromHelper: id) ?? id
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: rootID)
        guard !siblings.isEmpty else { return pid }
        let interactive = siblings.filter { !isAutomatedChromiumProcess(pid: $0.processIdentifier) }
        let pool = interactive.isEmpty ? siblings : interactive
        if pool.contains(where: { $0.processIdentifier == pid }) {
            return pid
        }
        if let active = pool.first(where: { $0.isActive }) {
            return active.processIdentifier
        }
        return pool.first?.processIdentifier ?? pid
    }

    public static func axApplicationPID(for pid: pid_t) -> pid_t {
        preferredBrowserPID(for: pid)
    }

    public static func isDestinationFamily(destinationPID: pid_t, elementPID: pid_t) -> Bool {
        if destinationPID == elementPID { return true }
        guard let dest = NSRunningApplication(processIdentifier: destinationPID),
              let el = NSRunningApplication(processIdentifier: elementPID) else {
            return false
        }
        let destID = dest.bundleIdentifier ?? ""
        let elID = el.bundleIdentifier ?? ""
        if !destID.isEmpty, (elID == destID || elID.hasPrefix(destID + ".")) { return true }
        guard let destURL = dest.bundleURL, let elURL = el.bundleURL else { return false }
        if destURL == elURL { return true }
        return elURL.path.hasPrefix(destURL.path)
    }

    /// Cocoa mouse (`NSEvent.mouseLocation`, y-up) → Quartz / AX (y-down).
    public static func quartzFromCocoa(_ cocoa: CGPoint, screens: [CGRect]) -> CGPoint {
        let screen = screens.first(where: { $0.insetBy(dx: -2, dy: -2).contains(cocoa) })
            ?? screens.max(by: { $0.height * $0.width < $1.height * $1.width })
        let maxY = screen?.maxY ?? screens.map(\.maxY).max() ?? cocoa.y
        return CGPoint(x: cocoa.x, y: maxY - cocoa.y)
    }

    /// Chromium `AXWebArea` (and page-sized groups) report settable AXValue
    /// without mutating the DOM. Notion Electron also lies for compact
    /// `AXTextArea`: AXValue read-back matches while the composer stays empty.
    /// Cursor / VS Code compact `AXTextArea` still lands via AX set — blanket
    /// Chromium distrust skipped that path and synthetic keyDown claimed success.
    /// Native AppKit fields still use AX set + read-back.
    public static func trustsAXSet(
        role: String,
        frame: CGRect?,
        chromium: Bool = false,
        bundleIdentifier: String? = nil
    ) -> Bool {
        if role == "AXWebArea" { return false }
        if isWebLike(role), let frame, frame.height >= tallWebAreaThreshold {
            return false
        }
        if chromium, chromiumAXValueIsALie(bundleIdentifier: bundleIdentifier) {
            return false
        }
        return true
    }

    /// Notion AI and Chromium *browsers* report AXTextArea success without
    /// mutating the focused composer. Cursor/Electron editors do not.
    public static func chromiumAXValueIsALie(bundleIdentifier: String?) -> Bool {
        let id = bundleIdentifier ?? ""
        if id == "notion.id" { return true }
        if id.hasPrefix("com.google.Chrome") { return true }
        switch id {
        case "com.brave.Browser",
             "com.microsoft.edgemac",
             "company.thebrowser.Browser",
             "com.operasoftware.Opera",
             "com.vivaldi.Vivaldi":
            return true
        default:
            return false
        }
    }

    /// Stale AX focus (other Chrome tab, Playwright remap) vs the field
    /// the operator actually clicked. Prefer the control under the pointer.
    /// Tall AXGroup/AXWebArea also retargets: the pointer can sit in a
    /// composer while AX focus is the whole chat column.
    public static func shouldPreferPointerTarget(
        focusedFrame: CGRect?,
        pointer: CGPoint?,
        focusedRole: String? = nil
    ) -> Bool {
        guard let pointer else { return false }
        guard let focusedFrame else { return true }
        if !focusedFrame.insetBy(dx: -12, dy: -12).contains(pointer) { return true }
        if isWebLike(focusedRole ?? ""), focusedFrame.height >= tallWebAreaThreshold {
            return true
        }
        return false
    }

    public static func point(role: String, frame: CGRect, pointer: CGPoint? = nil) -> CGPoint {
        if let pointer, frame.insetBy(dx: -12, dy: -12).contains(pointer) {
            return pointer
        }
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

    public enum EdgePolicy: String, Sendable {
        /// Native AppKit: unicode rides keyUp.
        case keyUpOnly
        /// Cursor / VS Code Electron: unicode rides keyDown; empty keyUp.
        case keyDownOnly
        /// Notion (and `keyboard_type`): unicode on both edges, vk 0.
        case both
    }

    public static func unicodeEdgePolicy(
        chromium: Bool,
        bundleIdentifier: String?
    ) -> EdgePolicy {
        if !chromium { return .keyUpOnly }
        // Chrome / Notion / other Chromium browsers: unicode on both edges
        // (same as keyboard_type). keyDown-only + 0xFFFF claims success
        // without mutating contenteditables.
        if CommandInsertPointerFocus.chromiumAXValueIsALie(bundleIdentifier: bundleIdentifier) {
            return .both
        }
        return .keyDownOnly
    }

    public static func carrierKeyCode(for policy: EdgePolicy) -> CGKeyCode {
        policy == .both ? ansiAKeyCode : carrierKeyCode
    }

    public static func unicodeUnits(forKeyDown chunk: [UInt16], electron: Bool = false) -> [UInt16] {
        unicodeUnits(forKeyDown: chunk, policy: electron ? .keyDownOnly : .keyUpOnly)
    }

    public static func unicodeUnits(forKeyUp chunk: [UInt16], electron: Bool = false) -> [UInt16] {
        unicodeUnits(forKeyUp: chunk, policy: electron ? .keyDownOnly : .keyUpOnly)
    }

    public static func unicodeUnits(forKeyDown chunk: [UInt16], policy: EdgePolicy) -> [UInt16] {
        switch policy {
        case .keyUpOnly: return []
        case .keyDownOnly, .both: return chunk
        }
    }

    public static func unicodeUnits(forKeyUp chunk: [UInt16], policy: EdgePolicy) -> [UInt16] {
        switch policy {
        case .keyDownOnly: return []
        case .keyUpOnly, .both: return chunk
        }
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
