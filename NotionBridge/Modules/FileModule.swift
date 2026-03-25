// FileModule.swift – V1-04 File & Clipboard Tools
// NotionBridge · Modules

import Foundation
import MCP

// MARK: - FileModule

/// Provides 12 file and clipboard tools.
/// Migrated from sk mac files R2.
/// Forbidden path enforcement handled by SecurityGate at ToolRouter dispatch level.
public enum FileModule {

    public static let moduleName = "file"

    /// Register all file module tools on the given router.
    public static func register(on router: ToolRouter) async {

        // 1. file_list – open
        await router.register(ToolRegistration(
            name: "file_list",
            module: moduleName,
            tier: .open,
            description: "List directory contents. Returns an array of {name, type, size} entries. Set recursive=true for deep listing, showHidden=true to include dotfiles.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to directory")]),
                    "recursive": .object(["type": .string("boolean"), "description": .string("List recursively (default: false)")]),
                    "showHidden": .object(["type": .string("boolean"), "description": .string("Show hidden files (default: false)")])
                ]),
                "required": .array([.string("path")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_list", reason: "missing 'path'")
                }
                let recursive: Bool = { if case .bool(let b) = args["recursive"] { return b }; return false }()
                let showHidden: Bool = { if case .bool(let b) = args["showHidden"] { return b }; return false }()

                let fm = FileManager.default
                let url = URL(fileURLWithPath: path)
                var entries: [Value] = []

                if recursive {
                    if let enumerator = fm.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: showHidden ? [] : [.skipsHiddenFiles]
                    ) {
                        while let itemURL = enumerator.nextObject() as? URL {
                            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                            entries.append(.object([
                                "name": .string(itemURL.lastPathComponent),
                                "path": .string(itemURL.path),
                                "type": .string(isDir ? "directory" : "file")
                            ]))
                        }
                    }
                } else {
                    let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                    for item in items {
                        if !showHidden && item.lastPathComponent.hasPrefix(".") { continue }
                        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        entries.append(.object([
                            "name": .string(item.lastPathComponent),
                            "path": .string(item.path),
                            "type": .string(isDir ? "directory" : "file")
                        ]))
                    }
                }

                return .object([
                    "path": .string(path),
                    "count": .int(entries.count),
                    "entries": .array(entries)
                ])
            }
        ))

        // 2. file_search – open
        await router.register(ToolRegistration(
            name: "file_search",
            module: moduleName,
            tier: .open,
            description: "Search for files by name substring within a directory tree. Returns an array of matching absolute file paths.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "directory": .object(["type": .string("string"), "description": .string("Directory to search in")]),
                    "query": .object(["type": .string("string"), "description": .string("Query string to match file names against")])
                ]),
                "required": .array([.string("directory"), .string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let directory) = args["directory"],
                      case .string(let query) = args["query"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_search", reason: "missing 'directory' or 'query'")
                }

                let url = URL(fileURLWithPath: directory)
                var matches: [Value] = []

                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                    while let itemURL = enumerator.nextObject() as? URL {
                        if itemURL.lastPathComponent.localizedCaseInsensitiveContains(query) {
                            matches.append(.object([
                                "name": .string(itemURL.lastPathComponent),
                                "path": .string(itemURL.path)
                            ]))
                        }
                    }
                }

                return .object([
                    "query": .string(query),
                    "directory": .string(directory),
                    "count": .int(matches.count),
                    "matches": .array(matches)
                ])
            }
        ))

        // 3. file_metadata – open
        await router.register(ToolRegistration(
            name: "file_metadata",
            module: moduleName,
            tier: .open,
            description: "Get metadata for a file or directory. Returns {size, created, modified, type, permissions}. Use before file_read to check size or existence.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file or directory")])
                ]),
                "required": .array([.string("path")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_metadata", reason: "missing 'path'")
                }

                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                let size = (attrs[.size] as? Int) ?? 0
                let created = (attrs[.creationDate] as? Date)?.ISO8601Format() ?? "unknown"
                let modified = (attrs[.modificationDate] as? Date)?.ISO8601Format() ?? "unknown"
                let fileType = (attrs[.type] as? FileAttributeType) == .typeDirectory ? "directory" : "file"

                return .object([
                    "path": .string(path),
                    "type": .string(fileType),
                    "size": .int(size),
                    "created": .string(created),
                    "modified": .string(modified)
                ])
            }
        ))

        // 4. file_read – open
        await router.register(ToolRegistration(
            name: "file_read",
            module: moduleName,
            tier: .open,
            description: "Read text content from a file. Returns {content, bytesRead}. Use maxBytes to cap large files; set encoding to 'ascii' or 'latin1' for non-UTF-8 files.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file")]),
                    "encoding": .object(["type": .string("string"), "description": .string("Text encoding: utf8, ascii, latin1 (default: utf8)")]),
                    "maxBytes": .object(["type": .string("integer"), "description": .string("Maximum bytes to read (default: unlimited)")])
                ]),
                "required": .array([.string("path")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_read", reason: "missing 'path'")
                }

                let encoding: String.Encoding = {
                    if case .string(let enc) = args["encoding"] {
                        switch enc.lowercased() {
                        case "ascii": return .ascii
                        case "latin1": return .isoLatin1
                        default: return .utf8
                        }
                    }
                    return .utf8
                }()

                var data = try Data(contentsOf: URL(fileURLWithPath: path))
                if case .int(let max) = args["maxBytes"], max > 0, data.count > max {
                    data = data.prefix(max)
                }

                guard let content = String(data: data, encoding: encoding) else {
                    return .object(["error": .string("Failed to decode file with specified encoding")])
                }

                return .object([
                    "path": .string(path),
                    "content": .string(content),
                    "size": .int(data.count)
                ])
            }
        ))

        // 5. file_write – notify
        await router.register(ToolRegistration(
            name: "file_write",
            module: moduleName,
            tier: .notify,
            description: "Write text content to a file, creating or overwriting it. Set createDirs=true to auto-create parent directories. Returns {bytesWritten, path}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file")]),
                    "content": .object(["type": .string("string"), "description": .string("Text content to write")]),
                    "createDirs": .object(["type": .string("boolean"), "description": .string("Create parent directories if needed (default: false)")])
                ]),
                "required": .array([.string("path"), .string("content")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"],
                      case .string(let content) = args["content"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_write", reason: "missing 'path' or 'content'")
                }

                let createDirs: Bool = { if case .bool(let b) = args["createDirs"] { return b }; return false }()

                let url = URL(fileURLWithPath: path)
                if createDirs {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                }

                try content.write(to: url, atomically: true, encoding: .utf8)

                return .object([
                    "path": .string(path),
                    "bytesWritten": .int(content.utf8.count),
                    "success": .bool(true)
                ])
            }
        ))

        // 6. file_append – notify
        await router.register(ToolRegistration(
            name: "file_append",
            module: moduleName,
            tier: .notify,
            description: "Append text to the end of an existing file without overwriting. Returns {bytesWritten}. File must already exist -- use file_write for new files.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file")]),
                    "content": .object(["type": .string("string"), "description": .string("Text content to append")])
                ]),
                "required": .array([.string("path"), .string("content")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"],
                      case .string(let content) = args["content"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_append", reason: "missing 'path' or 'content'")
                }

                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                handle.seekToEndOfFile()
                handle.write(content.data(using: .utf8) ?? Data())
                handle.closeFile()

                return .object([
                    "path": .string(path),
                    "bytesAppended": .int(content.utf8.count),
                    "success": .bool(true)
                ])
            }
        ))

        // 7. file_move – notify
        await router.register(ToolRegistration(
            name: "file_move",
            module: moduleName,
            tier: .notify,
            description: "Move a file or directory to a new absolute path. Returns the new path on success. Works across volumes.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sourcePath": .object(["type": .string("string"), "description": .string("Source file or directory path")]),
                    "destinationPath": .object(["type": .string("string"), "description": .string("Destination path")])
                ]),
                "required": .array([.string("sourcePath"), .string("destinationPath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let src) = args["sourcePath"],
                      case .string(let dst) = args["destinationPath"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_move", reason: "missing 'sourcePath' or 'destinationPath'")
                }

                try FileManager.default.moveItem(
                    at: URL(fileURLWithPath: src),
                    to: URL(fileURLWithPath: dst)
                )

                return .object([
                    "source": .string(src),
                    "destination": .string(dst),
                    "success": .bool(true)
                ])
            }
        ))

        // 8. file_rename – notify
        await router.register(ToolRegistration(
            name: "file_rename",
            module: moduleName,
            tier: .notify,
            description: "Rename a file or directory in its current location. Pass the new name (not a full path). Returns the updated absolute path.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file or directory")]),
                    "newName": .object(["type": .string("string"), "description": .string("New file or directory name")])
                ]),
                "required": .array([.string("path"), .string("newName")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"],
                      case .string(let newName) = args["newName"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_rename", reason: "missing 'path' or 'newName'")
                }

                let url = URL(fileURLWithPath: path)
                let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
                try FileManager.default.moveItem(at: url, to: newURL)

                return .object([
                    "oldPath": .string(path),
                    "newPath": .string(newURL.path),
                    "success": .bool(true)
                ])
            }
        ))

        // 9. file_copy – notify (PKT-373 P1-1: elevated from .open)
        await router.register(ToolRegistration(
            name: "file_copy",
            module: moduleName,
            tier: .notify,
            description: "Copy a file or directory to a new absolute path. Returns the destination path on success. Copies directories recursively.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sourcePath": .object(["type": .string("string"), "description": .string("Source file or directory path")]),
                    "destinationPath": .object(["type": .string("string"), "description": .string("Destination path")])
                ]),
                "required": .array([.string("sourcePath"), .string("destinationPath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let src) = args["sourcePath"],
                      case .string(let dst) = args["destinationPath"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_copy", reason: "missing 'sourcePath' or 'destinationPath'")
                }

                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: src),
                    to: URL(fileURLWithPath: dst)
                )

                return .object([
                    "source": .string(src),
                    "destination": .string(dst),
                    "success": .bool(true)
                ])
            }
        ))

        // 10. dir_create – notify
        await router.register(ToolRegistration(
            name: "dir_create",
            module: moduleName,
            tier: .notify,
            description: "Create a directory, including any missing intermediate parents (like mkdir -p). Returns the created path.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path for new directory")])
                ]),
                "required": .array([.string("path")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"] else {
                    throw ToolRouterError.invalidArguments(toolName: "dir_create", reason: "missing 'path'")
                }

                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: path),
                    withIntermediateDirectories: true
                )

                return .object([
                    "path": .string(path),
                    "success": .bool(true)
                ])
            }
        ))

        // 11. clipboard_read – open
        await router.register(ToolRegistration(
            name: "clipboard_read",
            module: moduleName,
            tier: .open,
            description: "Read the current text content from the macOS system clipboard. Returns {content: string} or null if the clipboard is empty or non-text.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                // Read pipe data BEFORE waitUntilExit to prevent buffer deadlock
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let content = String(data: data, encoding: .utf8) ?? ""

                return .object([
                    "content": .string(content),
                    "size": .int(content.utf8.count)
                ])
            }
        ))

        // 12. clipboard_write – open
        await router.register(ToolRegistration(
            name: "clipboard_write",
            module: moduleName,
            tier: .open,
            description: "Write text to the macOS system clipboard, replacing any existing content. Returns confirmation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "content": .object(["type": .string("string"), "description": .string("Text content to write to clipboard")])
                ]),
                "required": .array([.string("content")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let content) = args["content"] else {
                    throw ToolRouterError.invalidArguments(toolName: "clipboard_write", reason: "missing 'content'")
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
                let pipe = Pipe()
                process.standardInput = pipe
                try process.run()
                pipe.fileHandleForWriting.write(content.data(using: .utf8) ?? Data())
                pipe.fileHandleForWriting.closeFile()
                process.waitUntilExit()

                return .object([
                    "bytesWritten": .int(content.utf8.count),
                    "success": .bool(true)
                ])
            }
        ))
    }
}
