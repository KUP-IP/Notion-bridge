// AppleScriptModule.swift – In-process AppleScript execution
// NotionBridge · Modules
//
// Solves TCC permission re-prompting by executing AppleScript via NSAppleScript
// instead of shelling out to /usr/bin/osascript. When NSAppleScript runs in-process,
// macOS grants Automation TCC to NotionBridge.app itself — one grant, permanent.
//
// Created by PKT-356 hotfix: TCC prompt storm on osascript child processes.

import Foundation
import MCP

// MARK: - AppleScriptModule

/// Provides in-process AppleScript execution to avoid TCC re-prompting.
/// Use this instead of `shell_exec` + `osascript` for any Apple Event automation
/// (controlling Chrome, System Events, Finder, etc.).
public enum AppleScriptModule {

    public static let moduleName = "applescript"

    /// Register all AppleScriptModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: applescript_exec – notify
        await router.register(ToolRegistration(
            name: "applescript_exec",
            module: moduleName,
            tier: .notify,
            description: "Execute AppleScript code in-process via NSAppleScript. Avoids TCC re-prompting by running as NotionBridge.app (not /usr/bin/osascript). Use for controlling apps (Chrome, Finder, System Events, etc.). Returns the result string or error info.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "script": .object([
                        "type": .string("string"),
                        "description": .string("The AppleScript source code to execute")
                    ])
                ]),
                "required": .array([.string("script")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let script) = args["script"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "applescript_exec",
                        reason: "missing required 'script' parameter"
                    )
                }

                let appleScript = NSAppleScript(source: script)
                var errorInfo: NSDictionary?
                let result = appleScript?.executeAndReturnError(&errorInfo)

                if let error = errorInfo {
                    let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? -1
                    return .object([
                        "error": .string(errorMessage),
                        "errorNumber": .int(errorNumber)
                    ])
                }

                let resultString = result?.stringValue ?? ""
                return .object([
                    "result": .string(resultString)
                ])
            }
        ))
    }
}
