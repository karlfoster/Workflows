import AppKit
import ApplicationServices

/// Executes workflow steps sequentially. Command-style steps wait for their
/// process to exit, so e.g. "netbird up" finishes before the next step runs.
enum Engine {
    @MainActor
    static func run(_ workflow: Workflow) async {
        for step in workflow.steps {
            await run(step)
        }
    }

    @MainActor
    static func run(_ step: Step) async {
        switch step.type {
        case .openApp:
            await openApp(step)
        case .runCommand:
            await shell(step.text)
        case .openURL:
            await openURL(step)
        case .quitApps:
            quitApps(step)
        case .joinWifi:
            await shell("networksetup -setairportnetwork \(wifiDevice) \(quoted(step.text))")
        case .wifiPower:
            await shell("networksetup -setairportpower \(wifiDevice) \(step.wifiOn ? "on" : "off")")
        case .darkMode:
            toggleDarkMode()
        case .keystroke:
            sendKeystroke(step)
        case .typeText:
            await typeText(step)
        case .runShortcut:
            await shell("shortcuts run \(quoted(step.text))")
        }
    }

    // MARK: - Steps

    private static func openApp(_ step: Step) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: step.appBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func openURL(_ step: Step) async {
        guard let url = URL(string: step.text) else { return }
        if !step.browserBundleID.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: step.browserBundleID) {
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                                   configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func quitApps(_ step: Step) {
        let keep = Set(step.keepApps.map(\.bundleID)).union(["com.apple.finder"])
        let targets = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.bundleIdentifier != Bundle.main.bundleIdentifier
                && !(app.bundleIdentifier.map(keep.contains) ?? false)
        }
        for app in targets {
            app.terminate()
        }
        // Non-pinned apps leave the Dock on quit, but the Dock's "recent
        // applications" section can keep them around — clear it after the
        // apps have had a moment to exit.
        if step.clearDock && !targets.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                clearRecentAppsFromDock()
            }
        }
    }

    private static func toggleDarkMode() {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private static func sendKeystroke(_ step: Step) {
        guard step.keyCode >= 0 else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: step.modifiers)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(step.keyCode), keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(step.keyCode), keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// Types the step's text into the focused field of the frontmost app,
    /// without touching the clipboard. Events carry the text as unicode
    /// payloads, so it works regardless of keyboard layout.
    private static func typeText(_ step: Step) async {
        guard !step.text.isEmpty else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }
        // Wait for hotkey modifiers to be physically released, so held ⌘/⌥
        // don't turn the typed characters into shortcuts. Near-instant when
        // run from the menu; capped so a stuck key can't stall the workflow.
        let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        var waited = 0
        while !CGEventSource.flagsState(.hidSystemState).intersection(modifierMask).isEmpty, waited < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(step.text.utf16)
        var index = 0
        while index < units.count {
            // CGEvent unicode payloads are limited to ~20 UTF-16 units.
            var end = min(index + 20, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            let chunk = Array(units[index..<end])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.flags = []
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.flags = []
                up.post(tap: .cghidEventTap)
            }
            index = end
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Helpers

    @discardableResult
    static func shell(_ command: String) async -> Int32 {
        guard !command.isEmpty else { return 0 }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The Wi-Fi interface (e.g. en0), resolved once.
    static let wifiDevice: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "en0" }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var inWifiSection = false
        for line in output.split(separator: "\n") {
            if line.contains("Hardware Port: Wi-Fi") {
                inWifiSection = true
            } else if inWifiSection, line.hasPrefix("Device: ") {
                return String(line.dropFirst("Device: ".count))
            }
        }
        return "en0"
    }()

    private static func clearRecentAppsFromDock() {
        let dock = "com.apple.dock" as CFString
        // show-recents defaults to on when unset; skip only when explicitly off.
        if let shown = CFPreferencesCopyAppValue("show-recents" as CFString, dock) as? Bool, !shown {
            return
        }
        CFPreferencesSetAppValue("recent-apps" as CFString, [] as CFArray, dock)
        CFPreferencesAppSynchronize(dock)
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        try? killall.run()
    }
}

/// Formats a stored keystroke for display, e.g. "⌥⌘K".
enum KeyDisplay {
    static func describe(keyCode: Int, modifiers: UInt64) -> String {
        guard keyCode >= 0 else { return "None" }
        var parts = ""
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskControl) { parts += "⌃" }
        if flags.contains(.maskAlternate) { parts += "⌥" }
        if flags.contains(.maskShift) { parts += "⇧" }
        if flags.contains(.maskCommand) { parts += "⌘" }
        return parts + keyName(keyCode)
    }

    private static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "5", 23: "6", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func keyName(_ code: Int) -> String {
        names[code] ?? "key \(code)"
    }
}
