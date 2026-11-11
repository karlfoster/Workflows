import AppKit
import SwiftUI

/// The Send Slack to Claude step. It reads which channel or chat Slack is showing, opens a small
/// panel for how far back to read and what to ask, then reads those messages and their threads
/// and opens a new Claude Code session with them, the prompt filled in but not sent. It only
/// ever reads from Slack.
@MainActor
final class SlackToClaude: ObservableObject {
    static let shared = SlackToClaude()

    /// The conversation Slack is showing, as the panel and the prompt name it.
    struct Place: Equatable {
        var id: String
        /// "#product-launch", "Ana Silva".
        var heading: String
        /// "Channel in Acme".
        var detail: String
        var symbol: String
        /// "#product-launch, a channel in the Acme Slack workspace".
        var inPrompt: String
        /// My Slack user ID.
        var me: String
        /// The token for this conversation's workspace.
        var token: String
    }

    @Published var range: SlackRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: Self.rangeKey) }
    }
    @Published var ask = ""
    @Published private(set) var place: Place?
    @Published private(set) var problem: String?
    /// What it's doing while it reads and opens Claude; nil when idle.
    @Published private(set) var working: String?
    /// Goes up each time the panel opens, so the view puts the cursor in the ask.
    @Published private(set) var opened = 0

    private static let rangeKey = "slackToClaudeRange"
    private var panel: SlackPanel?
    private var task: Task<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private init() {
        range = SlackRange(rawValue: UserDefaults.standard.string(forKey: Self.rangeKey) ?? "") ?? .last50
    }

    /// Runs the step: opens the panel and returns once it closes, so a workflow's later steps
    /// run after it.
    func run() async {
        open()
        await withCheckedContinuation { waiting.append($0) }
    }

    func send() {
        guard let place, working == nil else { return }
        problem = nil
        working = "Reading messages…"
        let range = range
        let ask = ask
        task = Task { await sendNow(place, range: range, ask: ask) }
    }

    func close() {
        let resumed = waiting
        waiting = []
        task?.cancel()
        task = nil
        working = nil
        panel?.orderOut(nil)
        resumed.forEach { $0.resume() }
    }

    // MARK: - Opening

    private func open() {
        // Pressed again while it's reading: just bring the panel back.
        if working != nil {
            present()
            return
        }
        task?.cancel()
        ask = ""
        problem = nil
        place = nil
        opened += 1
        let shown = SlackWindow.shown()
        present()
        switch shown {
        case let .failure(problem):
            self.problem = problem.explanation
        case let .success(shown):
            task = Task { await resolve(shown) }
        }
    }

    private func resolve(_ shown: SlackWindow.Shown) async {
        let stored = SlackKeychain.all()
        guard !stored.isEmpty else {
            problem = SlackError.notConnected.explanation
            return
        }
        do {
            let (account, api) = try await Self.workspace(for: shown, among: stored.map(\.token))
            var id = shown.conversationID
            if id == nil, let title = shown.title {
                if title.kind.lowercased().contains("channel") {
                    id = try await api.channelID(named: title.name)
                } else if title.kind.uppercased().contains("DM") {
                    let people = try await SlackDirectory.shared.everyone(api)
                    id = try await api.chatID(titled: title.name, me: account, people: people)
                }
            }
            guard let id else {
                problem = shown.title == nil
                    ? "Slack isn't showing a channel or chat. Open one, then press the shortcut again."
                    : "Couldn't find “\(shown.title!.name)” in Slack. Open it from the sidebar on Home, then press the shortcut again."
                return
            }
            let described = try await describe(try await api.conversation(id), account: account, api: api)
            guard !Task.isCancelled else { return }
            place = described
        } catch is CancellationError {
        } catch let error as SlackError {
            problem = error.explanation
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The connected account for the workspace Slack is showing, matched by the window's team ID,
    /// else its title's workspace name. With neither, Slack isn't showing a conversation, which
    /// any account can go on to say.
    private static func workspace(for shown: SlackWindow.Shown, among tokens: [String]) async throws -> (SlackAPI.AuthTest, SlackAPI) {
        var accounts: [(SlackAPI.AuthTest, SlackAPI)] = []
        var firstError: Error?
        for token in tokens {
            let api = SlackAPI(token: token)
            do { accounts.append((try await SlackDirectory.shared.account(api), api)) } catch is CancellationError {
                throw CancellationError()
            } catch { firstError = firstError ?? error }
        }
        if let id = shown.teamID, let match = accounts.first(where: { $0.0.teamId == id }) { return match }
        if shown.teamID == nil, let name = shown.title?.workspace,
           let match = accounts.first(where: { $0.0.team == name }) { return match }
        if shown.teamID == nil, shown.title == nil, let first = accounts.first { return first }
        if accounts.isEmpty, let firstError { throw firstError }
        let names = SlackToClaude.list(accounts.map(\.0.team))
        throw SlackError.otherWorkspace(connected: names.isEmpty ? "no workspace" : names)
    }

    private func describe(_ channel: SlackAPI.Channel, account: SlackAPI.AuthTest, api: SlackAPI) async throws -> Place {
        let workspace = account.team
        if channel.isIm == true, let user = channel.user {
            let name = try await SlackDirectory.shared.names([user], api)[user] ?? "someone"
            return Place(id: channel.id, heading: name, detail: "Direct message in \(workspace)", symbol: "person",
                         inPrompt: "my direct messages with \(name) in the \(workspace) Slack workspace", me: account.userId, token: api.token)
        }
        if channel.isMpim == true {
            let members = try await api.members(channel.id).filter { $0 != account.userId }
            let names = try await SlackDirectory.shared.names(Set(members), api)
            let list = Self.list(members.map { names[$0] ?? "someone" })
            return Place(id: channel.id, heading: list, detail: "Group chat in \(workspace)", symbol: "person.2",
                         inPrompt: "my group chat with \(list) in the \(workspace) Slack workspace", me: account.userId, token: api.token)
        }
        let name = "#" + (channel.name ?? "channel")
        let isPrivate = channel.isPrivate == true || channel.isGroup == true
        return Place(id: channel.id, heading: name, detail: "\(isPrivate ? "Private channel" : "Channel") in \(workspace)",
                     symbol: isPrivate ? "lock" : "number",
                     inPrompt: "\(name), a \(isPrivate ? "private " : "")channel in the \(workspace) Slack workspace",
                     me: account.userId, token: api.token)
    }

    /// "Ana Silva, Ben Okafor and Chloe Martin".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: "nobody else"
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    // MARK: - Sending

    private func sendNow(_ place: Place, range: SlackRange, ask: String) async {
        do {
            var api = SlackAPI(token: place.token)
            api.onWait = { [weak self] seconds in
                await MainActor.run { self?.working = "Slack asked to slow down, so waiting \(seconds) s…" }
            }
            let read = try await SlackReader(api: api).read(place.id, range: range, me: place.me) { [weak self] line in
                self?.working = line
            }
            guard !read.entries.isEmpty else {
                working = nil
                problem = range.nothing(in: place.heading)
                return
            }
            var ids: Set<String> = [place.me]
            let all = read.entries + read.entries.flatMap(\.replies)
            for entry in all {
                if case let .user(id) = entry.author { ids.insert(id) }
                for text in [entry.text] + entry.attachments {
                    ids.formUnion(SlackText.mentionedUsers(in: text))
                }
            }
            let names = try await SlackDirectory.shared.names(ids, api)
            let transcript = SlackTranscript(names: names, me: place.me)
            let threads = read.entries.contains { !$0.replies.isEmpty }
                ? ", with each thread's replies indented under the message that started it" : ""
            let intro = "This is a Slack conversation from \(place.inPrompt): "
                + range.described(count: read.entries.count, foundMine: read.foundMine, reachedStart: read.reachedStart)
                + ", oldest first\(threads). Times are \(transcript.zoneName). My messages are marked “(me)”."
            let file = Self.fileURL(for: place)
            let handed = SlackPrompt.handed(intro: intro, entries: read.entries, transcript: transcript, ask: ask,
                                            filePath: file.path)
            if handed.needsFile { try Self.save(handed.whole, to: file) }
            try Task.checkCancellation()
            working = "Opening Claude…"
            await handToClaude(handed)
        } catch is CancellationError {
            working = nil
        } catch let error as SlackError {
            working = nil
            problem = error.explanation
        } catch {
            working = nil
            problem = "Couldn't save the conversation for Claude: \(error.localizedDescription)"
        }
    }

    /// Opens Claude with the prompt filled in. Without Claude's app, or when it doesn't open,
    /// the prompt goes on the clipboard instead and the panel says so.
    private func handToClaude(_ handed: SlackPrompt.Handed) async {
        func copy() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(handed.prompt, forType: .string)
        }
        guard let claude = URL(string: SlackPrompt.newSession),
              NSWorkspace.shared.urlForApplication(toOpen: claude) != nil else {
            copy()
            working = nil
            problem = "Claude's desktop app isn't on this Mac, so the prompt is on the clipboard. Paste it wherever you use Claude."
            return
        }
        let link = SlackPrompt.link(prompt: handed.prompt)
        let opened = (try? await NSWorkspace.shared.open(link, configuration: NSWorkspace.OpenConfiguration())) != nil
        guard opened else {
            copy()
            working = nil
            problem = "Claude didn't open, so the prompt is on the clipboard. Paste it into Claude with ⌘V."
            return
        }
        close()
    }

    // MARK: - The file for long conversations

    /// Where a conversation too long for the prompt is saved for Claude to read.
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workflows/Slack", isDirectory: true)
    }

    private static func fileURL(for place: Place, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = SlackText.fileSafe(place.heading.replacingOccurrences(of: "#", with: ""))
        return folder.appendingPathComponent("\(formatter.string(from: now)) \(name.isEmpty ? "Slack" : name).md")
    }

    /// Saves the conversation, and clears out the ones saved more than three days ago.
    private static func save(_ text: String, to file: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        let saved = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in saved {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < old {
                try? manager.removeItem(at: url)
            }
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - The panel

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let width = panel.frame.width
            panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - width / 2, y: visible.minY + visible.height * 0.75))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> SlackPanel {
        let controller = NSHostingController(rootView: SlackPanelView(model: self))
        controller.sizingOptions = [.preferredContentSize]
        let panel = SlackPanel()
        panel.contentViewController = controller
        panel.onCancel = { [weak self] in self?.close() }
        // Clicking elsewhere closes it, like Spotlight, unless it's already reading.
        panel.onResign = { [weak self] in
            guard let self, self.working == nil else { return }
            self.close()
        }
        return panel
    }
}

/// A floating panel that takes typing without making Workflows the active app, so Slack stays
/// as it was underneath.
final class SlackPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onResign: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 540, height: 240),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

struct SlackPanelView: View {
    @ObservedObject var model: SlackToClaude
    @FocusState private var asking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.place?.symbol ?? "text.bubble")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.place?.heading ?? (model.problem == nil ? "Finding the conversation…" : "Send Slack to Claude"))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.place?.detail ?? "Slack")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How far back")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("How far back", selection: $model.range) {
                    ForEach(SlackRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(model.working != nil)

            TextField("What would you like Claude to do? You can also say it in Claude.", text: $model.ask, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .focused($asking)
                .onSubmit { model.send() }
                .disabled(model.working != nil)

            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if let working = model.working {
                    ProgressView()
                        .controlSize(.small)
                    Text(working)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Cancel") { model.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Open in Claude") { model.send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.place == nil || model.working != nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(width: 540)
        .onAppear { asking = true }
        .onChange(of: model.opened) { asking = true }
    }
}
