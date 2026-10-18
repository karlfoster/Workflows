import AppKit
import ApplicationServices

/// Which conversation Slack's desktop app is showing, read through Accessibility. Slack's page
/// address carries the workspace and conversation IDs
/// (`https://app.slack.com/client/T0123ABCD9/C0456EFGH12`); the window title
/// ("name (Channel) - Acme - Slack") is the fallback when the address can't be read.
enum SlackWindow {
    static let bundleID = "com.tinyspeck.slackmacgap"

    struct Shown: Equatable {
        var teamID: String?
        var conversationID: String?
        var title: Title?
    }

    struct Title: Equatable {
        /// The channel's or person's name, as Slack shows it.
        var name: String
        /// "Channel", "DM"…
        var kind: String
        var workspace: String
    }

    enum Problem: Error, Equatable {
        case notRunning
        case noAccess
        case noWindow

        var explanation: String {
            switch self {
            case .notRunning: "Slack isn't open. Open a channel or chat in Slack, then press the shortcut again."
            case .noAccess: "Workflows needs Accessibility access to see which conversation Slack is showing. Turn it on in System Settings › Privacy & Security › Accessibility, then try again."
            case .noWindow: "Slack has no window open. Open a channel or chat in Slack, then press the shortcut again."
            }
        }
    }

    @MainActor
    static func shown() -> Result<Shown, Problem> {
        guard let slack = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return .failure(.notRunning)
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return .failure(.noAccess) }
        let app = AXUIElementCreateApplication(slack.processIdentifier)
        let window = element(app, kAXFocusedWindowAttribute)
            ?? element(app, kAXMainWindowAttribute)
            ?? (value(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { return .failure(.noWindow) }

        var shown = Shown()
        if let text = value(window, kAXTitleAttribute) as? String {
            shown.title = parse(title: text)
        }
        if let address = pageAddress(in: window), let parsed = parse(address: address) {
            shown.teamID = parsed.team
            shown.conversationID = parsed.conversation
        }
        return .success(shown)
    }

    /// The address of the page in Slack's window: its web area's AXURL, a few levels down.
    private static func pageAddress(in window: AXUIElement) -> String? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if let url = value(element, "AXURL") {
                let text = (url as? URL)?.absoluteString ?? (url as? String) ?? "\(url)"
                if text.contains("app.slack.com/client/") { return text }
            }
            guard depth < 12 else { continue }
            for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let found = value(parent, attribute), CFGetTypeID(found) == AXUIElementGetTypeID() else { return nil }
        return (found as! AXUIElement)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    // MARK: - Parsing (no Accessibility needed)

    /// The workspace and conversation in an address like
    /// `https://app.slack.com/client/T0123ABCD9/C0456EFGH12/thread/…`. The conversation is nil on
    /// pages that aren't one (Activity, Later, a canvas).
    static func parse(address: String) -> (team: String, conversation: String?)? {
        guard let url = URL(string: address) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let client = parts.firstIndex(of: "client"), client + 1 < parts.count else { return nil }
        let team = parts[client + 1]
        guard team.range(of: "^[TE][A-Z0-9]{6,}$", options: .regularExpression) != nil else { return nil }
        var conversation: String?
        if client + 2 < parts.count {
            let candidate = parts[client + 2]
            if candidate.range(of: "^[CDG][A-Z0-9]{6,}$", options: .regularExpression) != nil {
                conversation = candidate
            }
        }
        return (team, conversation)
    }

    /// "product-launch (Channel) - Acme - Slack" → name, kind and workspace. Slack may put a
    /// mark for unread messages in front ("* " or "! ").
    static func parse(title: String) -> Title? {
        let pattern = #"^(?:[*!] )?(.+) \(([^()]+)\) - (.+?) - Slack$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let name = Range(match.range(at: 1), in: title),
              let kind = Range(match.range(at: 2), in: title),
              let workspace = Range(match.range(at: 3), in: title) else { return nil }
        return Title(name: String(title[name]), kind: String(title[kind]), workspace: String(title[workspace]))
    }
}
