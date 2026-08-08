import SwiftUI
import KeyboardShortcuts
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject private var store: Store
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.workflows) { workflow in
                    Text(workflow.name)
                        .tag(workflow.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 2) {
                    Button {
                        selection = store.addWorkflow()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 22, height: 20)
                    }
                    Button {
                        if let selection {
                            store.deleteWorkflow(selection)
                            self.selection = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 22, height: 20)
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
                .background(.bar)
            }
        } detail: {
            if let index = store.workflows.firstIndex(where: { $0.id == selection }) {
                WorkflowDetailView(workflow: $store.workflows[index])
                    .id(selection)
            } else {
                Text("Select a workflow")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if selection == nil {
                selection = store.workflows.first?.id
            }
        }
    }
}

private struct WorkflowDetailView: View {
    @Binding var workflow: Workflow

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $workflow.name)
                LabeledContent("Keyboard Shortcut") {
                    KeyboardShortcuts.Recorder("", name: Store.shortcutName(workflow.id))
                        .labelsHidden()
                }
            }

            Section("Steps") {
                ForEach($workflow.steps) { $step in
                    StepRowView(step: $step) {
                        workflow.steps.removeAll { $0.id == step.id }
                    }
                }
                .onMove { from, to in
                    workflow.steps.move(fromOffsets: from, toOffset: to)
                }

                Menu {
                    ForEach(StepType.allCases) { type in
                        Button {
                            workflow.steps.append(Step(type: type))
                        } label: {
                            Label(type.label, systemImage: type.symbol)
                        }
                    }
                } label: {
                    Label("Add Step", systemImage: "plus")
                }
                .fixedSize()
            }
        }
        .formStyle(.grouped)
    }
}

private struct StepRowView: View {
    @Binding var step: Step
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(step.type.label, systemImage: step.type.symbol)
                .font(.subheadline.weight(.medium))
                .frame(width: 150, alignment: .leading)

            fields
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove step")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var fields: some View {
        switch step.type {
        case .openApp:
            HStack(spacing: 8) {
                if !step.appName.isEmpty {
                    Image(nsImage: AppInfo.icon(bundleID: step.appBundleID))
                        .resizable()
                        .frame(width: 17, height: 17)
                    Text(step.appName)
                }
                Button(step.appName.isEmpty ? "Choose App…" : "Change…") { chooseApp() }
                    .controlSize(.small)
            }

        case .runCommand:
            TextField("Shell command, e.g. netbird up", text: $step.text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

        case .openURL:
            HStack(spacing: 8) {
                TextField("https://…", text: $step.text)
                    .textFieldStyle(.roundedBorder)
                BrowserPicker(selection: $step.browserBundleID)
            }

        case .quitApps:
            KeepListEditor(keepApps: $step.keepApps, clearDock: $step.clearDock)

        case .joinWifi:
            TextField("Network name (SSID), e.g. Karl's iPhone", text: $step.text)
                .textFieldStyle(.roundedBorder)

        case .wifiPower:
            Picker("", selection: $step.wifiOn) {
                Text("Turn On").tag(true)
                Text("Turn Off").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

        case .darkMode:
            Text("Switches between light and dark appearance")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .keystroke:
            KeystrokeRecorderButton(keyCode: $step.keyCode, modifiers: $step.modifiers)

        case .typeText:
            VStack(alignment: .leading, spacing: 4) {
                TextField("Text to type, e.g. an email address or username", text: $step.text)
                    .textFieldStyle(.roundedBorder)
                Text("Typed into the focused field of the frontmost app. Requires Accessibility access.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .runShortcut:
            AppleShortcutPicker(name: $step.text)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        step.appBundleID = bundleID
        step.appName = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }
}

// MARK: - Keep-list editor (quit-all step)

private struct KeepListEditor: View {
    @Binding var keepApps: [KeptApp]
    @Binding var clearDock: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Keep running:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                addMenu
            }
            if keepApps.isEmpty {
                Text("Every app will be quit. Finder always stays.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(keepApps) { app in
                    HStack(spacing: 7) {
                        Image(nsImage: AppInfo.icon(bundleID: app.bundleID))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(app.name)
                            .font(.subheadline)
                        Spacer()
                        Button {
                            keepApps.removeAll { $0 == app }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.quaternary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Toggle("Clear quit apps from Dock", isOn: $clearDock)
                .font(.subheadline)
                .controlSize(.small)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(AppInfo.runningApps(excluding: Set(keepApps.map(\.bundleID))), id: \.bundleID) { app in
                Button(app.name) {
                    keepApps.append(KeptApp(bundleID: app.bundleID, name: app.name))
                    keepApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }
            Divider()
            Button("Choose from Applications…") { chooseApps() }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                  !keepApps.contains(where: { $0.bundleID == bundleID }) else { continue }
            let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
            keepApps.append(KeptApp(bundleID: bundleID, name: name))
        }
        keepApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Browser picker

private struct BrowserPicker: View {
    @Binding var selection: String
    @State private var browsers: [(name: String, bundleID: String)] = []

    var body: some View {
        Picker("", selection: $selection) {
            Text("Default Browser").tag("")
            ForEach(browsers, id: \.bundleID) { browser in
                Text(browser.name).tag(browser.bundleID)
            }
        }
        .labelsHidden()
        .fixedSize()
        .onAppear {
            guard browsers.isEmpty, let url = URL(string: "https://example.com") else { return }
            var seen = Set<String>()
            browsers = NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { appURL in
                guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier,
                      seen.insert(bundleID).inserted else { return nil }
                let name = (FileManager.default.displayName(atPath: appURL.path) as NSString).deletingPathExtension
                return (name, bundleID)
            }
            // Keep the current selection choosable even if that browser vanished.
            if !selection.isEmpty, !browsers.contains(where: { $0.bundleID == selection }) {
                browsers.append((selection, selection))
            }
        }
    }
}

// MARK: - Apple Shortcut picker

private struct AppleShortcutPicker: View {
    @Binding var name: String
    @State private var shortcuts: [String] = []

    var body: some View {
        HStack(spacing: 8) {
            TextField("Shortcut name", text: $name)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(shortcuts, id: \.self) { shortcut in
                    Button(shortcut) { name = shortcut }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(shortcuts.isEmpty)
        }
        .task {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            shortcuts = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
        }
    }
}

// MARK: - Keystroke recorder

private struct KeystrokeRecorderButton: View {
    @Binding var keyCode: Int
    @Binding var modifiers: UInt64
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Press keys…" : KeyDisplay.describe(keyCode: keyCode, modifiers: modifiers))
                    .frame(minWidth: 80)
            }
            Text("Sent to the frontmost app. Requires Accessibility access.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stopRecording() // Escape cancels
                return nil
            }
            keyCode = Int(event.keyCode)
            modifiers = UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

// MARK: - Shared app info helpers

enum AppInfo {
    static func icon(bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    static func runningApps(excluding: Set<String>) -> [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .compactMap { app -> (name: String, bundleID: String)? in
                guard app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !excluding.contains(bundleID) else { return nil }
                return (app.localizedName ?? bundleID, bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
