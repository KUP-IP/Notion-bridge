// ChromeModule.swift — Browser automation via Chrome Apple Events
// NotionBridge · Modules
//
// Provides Google Chrome automation through Apple Events using in-process
// NSAppleScript (same TCC-friendly pattern as AppleScriptModule).
//
// Tools:
//   chrome_tabs          (open)   — List all open tabs
//   chrome_navigate      (notify) — Navigate a tab to a URL or open new tab
//   chrome_read_page     (open)   — Extract page content via JavaScript
//   chrome_execute_js    (notify) — Execute arbitrary JavaScript in a tab
//   chrome_screenshot_tab(open)   — Capture visible tab content
//
// Created for FEATURE: ChromeModule — full browser automation via Apple Events.

import Foundation
import MCP
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - ChromeModule

/// Provides Google Chrome browser automation via Apple Events.
/// Uses in-process NSAppleScript to avoid TCC re-prompting.
public enum ChromeModule {

    public static let moduleName = "chrome"

    /// Register all ChromeModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: chrome_tabs – open
        await router.register(ToolRegistration(
            name: "chrome_tabs",
            module: moduleName,
            tier: .open,
            description: "List all open tabs in Google Chrome. Returns tab title, URL, window ID, and tab index for every open tab across all windows.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let script = """
                    tell application "Google Chrome"
                        set output to ""
                        set winIndex to 0
                        repeat with w in windows
                            set winIndex to winIndex + 1
                            set winId to id of w
                            set tabIndex to 0
                            repeat with t in tabs of w
                                set tabIndex to tabIndex + 1
                                set tabTitle to title of t
                                set tabURL to URL of t
                                set output to output & winId & "\t" & tabIndex & "\t" & tabTitle & "\t" & tabURL & linefeed
                            end repeat
                        end repeat
                        return output
                    end tell
                """

                let result = executeAppleScript(script)
                if let error = result.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(result.errorNumber ?? -1)
                    ])
                }

                // Parse tab-separated output into structured data
                let raw = result.value ?? ""
                let lines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
                var tabs: [Value] = []
                for line in lines {
                    let parts = line.components(separatedBy: "\t")
                    if parts.count >= 4 {
                        tabs.append(.object([
                            "windowId": .string(parts[0]),
                            "tabIndex": .string(parts[1]),
                            "title": .string(parts[2]),
                            "url": .string(parts[3])
                        ]))
                    }
                }
                return .object([
                    "tabs": .array(tabs),
                    "count": .int(tabs.count)
                ])
            }
        ))

        // MARK: chrome_navigate – notify
        await router.register(ToolRegistration(
            name: "chrome_navigate",
            module: moduleName,
            tier: .notify,
            description: "Navigate a Chrome tab to a URL, or open a new tab. If windowId and tabIndex are omitted, navigates the active tab of the front window. Set newTab to true to open a new tab instead.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The URL to navigate to")
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Optional window ID to target (from chrome_tabs)")
                    ]),
                    "tabIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Optional tab index within the window (from chrome_tabs)")
                    ]),
                    "newTab": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, open a new tab instead of navigating the current one (default: false)")
                    ])
                ]),
                "required": .array([.string("url")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let url) = args["url"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "chrome_navigate",
                        reason: "missing required 'url' parameter"
                    )
                }

                let newTab: Bool
                if case .bool(let val) = args["newTab"] {
                    newTab = val
                } else {
                    newTab = false
                }

                let escapedURL = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

                let script: String
                if newTab {
                    script = """
                        tell application "Google Chrome"
                            tell front window
                                make new tab with properties {URL:"\(escapedURL)"}
                            end tell
                            return "ok"
                        end tell
                    """
                } else if let windowIdVal = args["windowId"],
                          let tabIndexVal = args["tabIndex"],
                          case .int(let windowId) = windowIdVal,
                          case .int(let tabIndex) = tabIndexVal {
                    script = """
                        tell application "Google Chrome"
                            repeat with w in windows
                                if id of w is \(windowId) then
                                    set URL of tab \(tabIndex) of w to "\(escapedURL)"
                                    return "ok"
                                end if
                            end repeat
                            return "window not found"
                        end tell
                    """
                } else {
                    script = """
                        tell application "Google Chrome"
                            set URL of active tab of front window to "\(escapedURL)"
                            return "ok"
                        end tell
                    """
                }

                let result = executeAppleScript(script)
                if let error = result.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(result.errorNumber ?? -1)
                    ])
                }
                return .object([
                    "result": .string(result.value ?? "ok"),
                    "navigatedTo": .string(url)
                ])
            }
        ))

        // MARK: chrome_read_page – open
        await router.register(ToolRegistration(
            name: "chrome_read_page",
            module: moduleName,
            tier: .open,
            description: "Extract page content from a Chrome tab via JavaScript. By default returns document.body.innerText. Optionally pass a CSS selector to target a specific element, or set mode to 'html' for full HTML.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "selector": .object([
                        "type": .string("string"),
                        "description": .string("Optional CSS selector to target a specific element (default: document.body)")
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "description": .string("'text' for innerText (default) or 'html' for innerHTML")
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Optional window ID (from chrome_tabs)")
                    ]),
                    "tabIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Optional tab index (from chrome_tabs)")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value]
                if case .object(let a) = arguments {
                    args = a
                } else {
                    args = [:]
                }

                let selector: String
                if case .string(let s) = args["selector"] {
                    selector = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                } else {
                    selector = ""
                }

                let useHTML: Bool
                if case .string(let m) = args["mode"], m == "html" {
                    useHTML = true
                } else {
                    useHTML = false
                }

                let prop = useHTML ? "innerHTML" : "innerText"
                let jsElement = selector.isEmpty
                    ? "document.body"
                    : "document.querySelector('\(selector)')"
                let js = "(\(jsElement) || {}).\(prop) || ''"

                let escapedJS = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

                let tabTarget: String
                if let windowIdVal = args["windowId"],
                   let tabIndexVal = args["tabIndex"],
                   case .int(let windowId) = windowIdVal,
                   case .int(let tabIndex) = tabIndexVal {
                    tabTarget = """
                        set targetTab to missing value
                        repeat with w in windows
                            if id of w is \(windowId) then
                                set targetTab to tab \(tabIndex) of w
                            end if
                        end repeat
                        tell targetTab
                    """
                } else {
                    tabTarget = "tell active tab of front window"
                }

                let script = """
                    tell application "Google Chrome"
                        \(tabTarget)
                            set pageContent to execute javascript "\(escapedJS)"
                        end tell
                        return pageContent
                    end tell
                """

                let result = executeAppleScript(script)
                if let error = result.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(result.errorNumber ?? -1)
                    ])
                }

                let content = result.value ?? ""
                return .object([
                    "content": .string(content),
                    "length": .int(content.count),
                    "mode": .string(useHTML ? "html" : "text")
                ])
            }
        ))

        // MARK: chrome_execute_js – notify
        await router.register(ToolRegistration(
            name: "chrome_execute_js",
            module: moduleName,
            tier: .notify,
            description: "Execute arbitrary JavaScript in a Chrome tab and return the result. Use for dynamic page interaction, form filling, DOM manipulation, etc.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "javascript": .object([
                        "type": .string("string"),
                        "description": .string("The JavaScript code to execute in the tab")
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Optional window ID (from chrome_tabs)")
                    ]),
                    "tabIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Optional tab index (from chrome_tabs)")
                    ])
                ]),
                "required": .array([.string("javascript")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let javascript) = args["javascript"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "chrome_execute_js",
                        reason: "missing required 'javascript' parameter"
                    )
                }

                let escapedJS = javascript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

                let tabTarget: String
                if let windowIdVal = args["windowId"],
                   let tabIndexVal = args["tabIndex"],
                   case .int(let windowId) = windowIdVal,
                   case .int(let tabIndex) = tabIndexVal {
                    tabTarget = """
                        set targetTab to missing value
                        repeat with w in windows
                            if id of w is \(windowId) then
                                set targetTab to tab \(tabIndex) of w
                            end if
                        end repeat
                        tell targetTab
                    """
                } else {
                    tabTarget = "tell active tab of front window"
                }

                let script = """
                    tell application "Google Chrome"
                        \(tabTarget)
                            set jsResult to execute javascript "\(escapedJS)"
                        end tell
                        return jsResult
                    end tell
                """

                let result = executeAppleScript(script)
                if let error = result.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(result.errorNumber ?? -1)
                    ])
                }
                return .object([
                    "result": .string(result.value ?? "")
                ])
            }
        ))

        // MARK: chrome_screenshot_tab – open
        await router.register(ToolRegistration(
            name: "chrome_screenshot_tab",
            module: moduleName,
            tier: .open,
            description: "Capture the visible content of a Chrome tab. Uses ScreenCaptureKit to capture the Chrome window as a PNG. Returns the file path and dimensions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Optional window ID (from chrome_tabs)")
                    ]),
                    "tabIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Optional tab index (from chrome_tabs)")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value]
                if case .object(let a) = arguments {
                    args = a
                } else {
                    args = [:]
                }

                // Use ScreenCaptureKit to capture Chrome window (proven pattern from ScreenModule)
                guard CGPreflightScreenCaptureAccess() else {
                    return .object(["error": .string("Screen Recording permission not granted. Grant access in System Settings > Privacy & Security > Screen Recording.")])
                }

                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                // Find Chrome windows
                let chromeWindows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == "com.google.Chrome"
                }

                guard !chromeWindows.isEmpty else {
                    return .object(["error": .string("No Chrome windows found on screen")])
                }

                // Select target window
                let targetWindow: SCWindow
                if let windowIdVal = args["windowId"],
                   case .int(let windowId) = windowIdVal {
                    // Chrome AppleScript window IDs map to CGWindowIDs
                    if let w = chromeWindows.first(where: { Int($0.windowID) == windowId }) {
                        targetWindow = w
                    } else {
                        // Fallback to front Chrome window
                        targetWindow = chromeWindows[0]
                    }
                } else {
                    targetWindow = chromeWindows[0]
                }

                // Capture using ScreenCaptureKit
                let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
                let config = SCStreamConfiguration()
                config.width = Int(targetWindow.frame.width) * 2
                config.height = Int(targetWindow.frame.height) * 2
                config.scalesToFit = false

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

                // Save PNG to temp directory
                let tempDir = FileManager.default.temporaryDirectory
                let filename = "chrome_screenshot_\(Int(Date().timeIntervalSince1970)).png"
                let filePath = tempDir.appendingPathComponent(filename)

                let url = filePath as CFURL
                guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
                    return .object(["error": .string("Failed to create image destination")])
                }
                CGImageDestinationAddImage(destination, cgImage, nil)
                guard CGImageDestinationFinalize(destination) else {
                    return .object(["error": .string("Failed to encode PNG")])
                }

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath.path))?[.size] as? Int ?? 0

                return .object([
                    "path": .string(filePath.path),
                    "width": .int(cgImage.width),
                    "height": .int(cgImage.height),
                    "size": .int(fileSize)
                ])
            }
        ))
    }

    // MARK: - Internal helpers

    private struct AppleScriptResult {
        let value: String?
        let error: String?
        let errorNumber: Int?
    }

    private static func executeAppleScript(_ source: String) -> AppleScriptResult {
        let appleScript = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? -1
            return AppleScriptResult(value: nil, error: errorMessage, errorNumber: errorNumber)
        }

        return AppleScriptResult(value: result?.stringValue ?? "", error: nil, errorNumber: nil)
    }
}
