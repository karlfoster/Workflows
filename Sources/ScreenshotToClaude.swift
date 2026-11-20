import AppKit

/// The Send Screenshot to Claude step. It lets you pick part of the screen as ⇧⌘4 does (drag an
/// area, or press Space and click a window; Escape cancels), then opens a new Claude Code session
/// and pastes the picture into its prompt box, ready for you to say what you want. Nothing is
/// sent until you send it in Claude.
///
/// Claude's new-session link can carry text but not a picture, so the picture goes on the
/// clipboard and the step presses ⌘V once Claude is in front. It stays on the clipboard, so if
/// the paste lands before Claude is ready, ⌘V puts it in by hand.
enum ScreenshotToClaude {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    @MainActor
    static func run() async {
        guard let png = await capture() else { return }

        NSPasteboard.general.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.writeObjects([item])

        guard let link = URL(string: SlackPrompt.newSession),
              NSWorkspace.shared.urlForApplication(toOpen: link) != nil else { return }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).isEmpty
        guard (try? await NSWorkspace.shared.open(link, configuration: NSWorkspace.OpenConfiguration())) != nil else { return }
        guard await waitForClaudeInFront() else { return }
        guard await waitForNewPromptBox(seconds: wasRunning ? 6 : 20) else { return }
        paste()
    }

    /// Waits until the new session's empty prompt box has the cursor. A fixed wait doesn't do:
    /// when Claude is already in front, the old session's box keeps the cursor for a moment, and
    /// a ⌘V then lands on nothing (seen 20 Nov 2026 at 0.9 s). The new box is told apart by its
    /// placeholder; if a later Claude words it differently, any empty prompt box will do after a
    /// few seconds.
    @MainActor
    private static func waitForNewPromptBox(seconds: Double) async -> Bool {
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first else { return false }
        let app = AXUIElementCreateApplication(claude.processIdentifier)
        func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var result: AnyObject?
            AXUIElementCopyAttributeValue(element, name as CFString, &result)
            return result
        }
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if let focused = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let box = focused as! AXUIElement
                let isEmptyPrompt = value(box, kAXRoleAttribute) as? String == kAXTextAreaRole
                    && value(box, kAXDescriptionAttribute) as? String == "Prompt"
                    && (value(box, kAXValueAttribute) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let placeholder = value(box, "AXPlaceholderValue") as? String ?? ""
                if isEmptyPrompt && (placeholder.contains("Describe a task") || Date().timeIntervalSince(start) > 3) {
                    return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Runs macOS's own picker and returns the picture, or nil when it was cancelled.
    private static func capture() async -> Data? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Workflows screenshot \(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let finished: Bool = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: pick an area or (Space) a window; -o: no window shadow; -x: no shutter sound.
            process.arguments = ["-i", "-o", "-x", file.path]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
        guard finished, let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return data
    }

    @MainActor
    private static func waitForClaudeInFront() async -> Bool {
        for _ in 0..<100 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Presses ⌘V in the frontmost app. Needs Accessibility access, as Send Keystroke does.
    private static func paste() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let v: CGKeyCode = 9
        for keyDown in [true, false] {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: keyDown) {
                event.flags = .maskCommand
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
