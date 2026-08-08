import AppKit
import KeyboardShortcuts

enum StepType: String, Codable, CaseIterable, Identifiable {
    case openApp
    case runCommand
    case openURL
    case quitApps
    case joinWifi
    case wifiPower
    case darkMode
    case keystroke
    case typeText
    case runShortcut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openApp: "Open App"
        case .runCommand: "Run Command"
        case .openURL: "Open URL"
        case .quitApps: "Quit All Apps"
        case .joinWifi: "Join Wi-Fi Network"
        case .wifiPower: "Wi-Fi On/Off"
        case .darkMode: "Toggle Dark Mode"
        case .keystroke: "Send Keystroke"
        case .typeText: "Type Text"
        case .runShortcut: "Run Apple Shortcut"
        }
    }

    var symbol: String {
        switch self {
        case .openApp: "app"
        case .runCommand: "terminal"
        case .openURL: "link"
        case .quitApps: "xmark.circle"
        case .joinWifi: "personalhotspot"
        case .wifiPower: "wifi"
        case .darkMode: "circle.lefthalf.filled"
        case .keystroke: "keyboard"
        case .typeText: "character.cursor.ibeam"
        case .runShortcut: "sparkles"
        }
    }
}

struct KeptApp: Codable, Identifiable, Equatable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

struct Step: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: StepType
    var text = ""                 // command, URL, SSID, or Apple Shortcut name
    var appBundleID = ""          // openApp target
    var appName = ""
    var browserBundleID = ""      // openURL; empty = default browser
    var keepApps: [KeptApp] = []  // quitApps
    var clearDock = true          // quitApps
    var wifiOn = true             // wifiPower
    var keyCode = -1              // keystroke
    var modifiers: UInt64 = 0     // keystroke, CGEventFlags raw value
}

struct Workflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New Workflow"
    var steps: [Step] = []
}

@MainActor
final class Store: ObservableObject {
    @Published var workflows: [Workflow] {
        didSet {
            save()
            registerHotkeys()
        }
    }

    private static let key = "workflows"
    private var registeredHotkeys: Set<String> = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Workflow].self, from: data) {
            workflows = decoded
        } else {
            workflows = Self.seedWorkflows()
            save()
        }
        registerHotkeys()
    }

    static func shortcutName(_ id: UUID) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("workflow-\(id.uuidString)")
    }

    func run(_ workflow: Workflow) {
        Task { await Engine.run(workflow) }
    }

    func addWorkflow() -> UUID {
        let workflow = Workflow()
        workflows.append(workflow)
        return workflow.id
    }

    func deleteWorkflow(_ id: UUID) {
        KeyboardShortcuts.reset(Self.shortcutName(id))
        workflows.removeAll { $0.id == id }
    }

    /// Signal views to re-read derived state (shortcut labels) when a panel opens.
    func refresh() {
        objectWillChange.send()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(workflows) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func registerHotkeys() {
        for workflow in workflows {
            let name = Self.shortcutName(workflow.id)
            guard registeredHotkeys.insert(name.rawValue).inserted else { continue }
            let id = workflow.id
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                guard let self, let current = self.workflows.first(where: { $0.id == id }) else { return }
                self.run(current)
            }
        }
    }

    // MARK: - First-launch seed

    private static func seedWorkflows() -> [Workflow] {
        var seeds: [Workflow] = []

        // Migrate the QuitAll keep-list (this app replaces QuitAll).
        var keep: [KeptApp] = []
        if let data = CFPreferencesCopyAppValue("excludedApps" as CFString,
                                                "com.karlfoster.QuitAll" as CFString) as? Data,
           let apps = try? JSONDecoder().decode([KeptApp].self, from: data) {
            keep = apps
        }
        let quit = Workflow(name: "Quit All Apps", steps: [Step(type: .quitApps, keepApps: keep)])
        if KeyboardShortcuts.getShortcut(for: shortcutName(quit.id)) == nil {
            KeyboardShortcuts.setShortcut(.init(.k, modifiers: [.option, .command]),
                                          for: shortcutName(quit.id))
        }
        seeds.append(quit)

        if let netbird = Bundle(url: URL(fileURLWithPath: "/Applications/NetBird.app")),
           let netbirdID = netbird.bundleIdentifier {
            seeds.append(Workflow(name: "Connect VPN", steps: [
                Step(type: .openApp, appBundleID: netbirdID, appName: "NetBird"),
                Step(type: .runCommand, text: "netbird up"),
            ]))
        }

        seeds.append(Workflow(name: "Google Calendar", steps: [
            Step(type: .openURL, text: "https://calendar.google.com", browserBundleID: "com.apple.Safari"),
        ]))

        return seeds
    }
}
