#!/bin/bash
# Batch tool description optimization — Wave 3
# Targeted replacements for 16 tools that need return-format hints,
# disambiguation, or better LLM routing signals.
set -e
cd /Users/keepup/Developer/keepr-bridge

# === ShellModule.swift ===
sed -i '' 's/description: "Run a shell command and return its output\."/description: "Run a shell command. Returns \{stdout, stderr, exitCode, duration\}. Escalates for sudo\/rm -rf patterns."/g' NotionBridge/Modules/ShellModule.swift

# === ScreenModule.swift ===
sed -i '' 's/description: "Take a screenshot of the screen, a window, or a rectangle\."/description: "Screenshot the screen, a window, or a region. Returns \{filePath, width, height\}. Target: display|window|region|all_displays."/g' NotionBridge/Modules/ScreenModule.swift
sed -i '' 's/description: "Copy text from the screen with OCR\."/description: "OCR the screen and extract text with confidence scores and bounding boxes."/g' NotionBridge/Modules/ScreenModule.swift

# === ScreenAnalyze.swift ===
sed -i '' 's/description: "Summarize colors and brightness from a screenshot file\."/description: "Analyze a screenshot file for dominant colors and luminance. Input: filePath from screen_capture."/g' NotionBridge/Modules/ScreenAnalyze.swift

# === ScreenRecording.swift ===
sed -i '' 's/description: "Start recording the screen to a video file\."/description: "Start screen recording. Returns filePath immediately. Default 60s cap (max 300s). One at a time."/g' NotionBridge/Modules/ScreenRecording.swift
sed -i '' 's/description: "Stop the current screen recording\."/description: "Stop recording. Returns \{filePath, duration, fileSize\}."/g' NotionBridge/Modules/ScreenRecording.swift

# === AccessibilityModule.swift ===
sed -i '' "s/description: \"See which app is frontmost and its process id\.\"/description: \"Get the frontmost app's name, bundleId, and pid. Use pid in other ax_* tools.\"/g" NotionBridge/Modules/AccessibilityModule.swift
sed -i '' 's/description: "List on-screen UI elements for automation\."/description: "Dump the UI element tree for an app. Omit pid for frontmost. Use maxDepth to limit."/g' NotionBridge/Modules/AccessibilityModule.swift
sed -i '' 's/description: "Find a button, field, or other UI element by name\."/description: "Search for UI elements by role, title, or label. Returns paths for ax_perform_action."/g' NotionBridge/Modules/AccessibilityModule.swift
sed -i '' 's/description: "Inspect one UI element in detail\."/description: "Deep-inspect one AX element. Returns attributes, actions, position, size, and state."/g' NotionBridge/Modules/AccessibilityModule.swift
sed -i '' 's/description: "Click, type, or trigger a control\."/description: "Act on a UI element: press, focus, setValue, confirm, increment, or decrement."/g' NotionBridge/Modules/AccessibilityModule.swift

# === ChromeModule.swift ===
sed -i '' 's/description: "Read text or HTML from the current page\."/description: "Extract content from a Chrome tab as text or HTML. Use selector to target an element."/g' NotionBridge/Modules/ChromeModule.swift
sed -i '' 's/description: "Run JavaScript in the page and return the result\."/description: "Execute JavaScript in a Chrome tab for DOM manipulation. Prefer chrome_read_page for reads."/g' NotionBridge/Modules/ChromeModule.swift
sed -i '' 's/description: "Screenshot the visible Chrome tab\."/description: "Capture the Chrome tab as PNG. Returns \{filePath, width, height\}. Use screen_capture for non-Chrome."/g' NotionBridge/Modules/ChromeModule.swift

# === NotionModule.swift ===
sed -i '' "s/description: \"Read a page's body as markdown\.\"/description: \"Read a page's body as clean markdown without property metadata. Lighter than notion_page_read.\"/g" NotionBridge/Modules/NotionModule.swift

# === AppleScriptModule.swift ===
sed -i '' "s/description: \"Run AppleScript to control Mac apps\.\"/description: \"Run AppleScript in-process using NotionBridge's TCC grants. For app control and System Events.\"/g" NotionBridge/Modules/AppleScriptModule.swift

echo 'All 16 descriptions optimized.'
