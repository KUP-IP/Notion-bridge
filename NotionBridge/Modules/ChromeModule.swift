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
                let js = "(\(jsElement) || {}).\\(prop) || ''"

                let escapedJS = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

                let tabTarget: String
                if let windowIdVal = args["windowId"],
                   let tabIndexVal = args["tabIndex"],
                   case .int(let windowId) = windowIdVal,
                   case .int(let tabIndex) = tabIndexVal {
                    tabTarget = """
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
            description: "Capture the visible content of a Chrome tab. Uses JavaScript to capture the viewport as a PNG data URL, then saves to a temporary file. Returns the file path and dimensions.",
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

                // Use html2canvas-style JS to capture viewport as data URL
                let captureJS = """
                    (async function() {
                        try {
                            const canvas = document.createElement('canvas');
                            const ctx = canvas.getContext('2d');
                            canvas.width = window.innerWidth;
                            canvas.height = window.innerHeight;
                            // Use foreignObject SVG approach for same-origin capture
                            const data = '<svg xmlns="http://www.w3.org/2000/svg" width="' + canvas.width + '" height="' + canvas.height + '">' +
                                '<foreignObject width="100%" height="100%">' +
                                '<div xmlns="http://www.w3.org/1999/xhtml">' +
                                document.documentElement.outerHTML +
                                '</div></foreignObject></svg>';
                            const blob = new Blob([data], {type: 'image/svg+xml'});
                            const url = URL.createObjectURL(blob);
                            const img = new Image();
                            return await new Promise((resolve) => {
                                img.onload = function() {
                                    ctx.drawImage(img, 0, 0);
                                    URL.revokeObjectURL(url);
                                    resolve(JSON.stringify({width: canvas.width, height: canvas.height, dataUrl: canvas.toDataURL('image/png')}));
                                };
                                img.onerror = function() {
                                    resolve(JSON.stringify({error: 'Canvas rendering failed'}));
                                };
                                img.src = url;
                            });
                        } catch(e) {
                            return JSON.stringify({error: e.message});
                        }
                    })()
                    """.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")

                let tabTarget: String
                if let windowIdVal = args["windowId"],
                   let tabIndexVal = args["tabIndex"],
                   case .int(let windowId) = windowIdVal,
                   case .int(let tabIndex) = tabIndexVal {
                    tabTarget = """
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
                            set captureResult to execute javascript "\(captureJS)"
                        end tell
                        return captureResult
                    end tell
                """

                let result = executeAppleScript(script)
                if let error = result.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(result.errorNumber ?? -1)
                    ])
                }

                // Parse the JSON result from JS
                guard let jsonString = result.value,
                      let jsonData = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    return .object([
                        "error": .string("Failed to parse screenshot result")
                    ])
                }

                if let jsError = json["error"] as? String {
                    return .object([
                        "error": .string(jsError)
                    ])
                }

                guard let dataUrl = json["dataUrl"] as? String,
                      let width = json["width"] as? Int,
                      let height = json["height"] as? Int else {
                    return .object([
                        "error": .string("Missing screenshot data in result")
                    ])
                }

                // Save data URL to temp file
                let prefix = "data:image/png;base64,"
                if dataUrl.hasPrefix(prefix) {
                    let base64 = String(dataUrl.dropFirst(prefix.count))
                    if let imageData = Data(base64Encoded: base64) {
                        let tempDir = FileManager.default.temporaryDirectory
                        let filename = "chrome_screenshot_\(Int(Date().timeIntervalSince1970)).png"
                        let filePath = tempDir.appendingPathComponent(filename)
                        try? imageData.write(to: filePath)
                        return .object([
                            "path": .string(filePath.path),
                            "width": .int(width),
                            "height": .int(height),
                            "size": .int(imageData.count)
                        ])
                    }
                }

                return .object([
                    "error": .string("Failed to decode screenshot data")
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
