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

    /// What the step worked out to send: the thread that's open, or the discussion on screen.
    struct Found {
        enum What {
            case thread(SlackEntry)
            /// Top-level messages, oldest first; their threads are read when it's sent.
            case span([SlackAPI.Message])
        }

        var what: What
        /// The panel's line, in two parts: "Launch date" and "9 messages, Tue 17 Nov 14:10 to now".
        var title: String
        var detail: String
        /// Both, for the menu: "Launch date: 9 messages, Tue 17 Nov 14:10 to now".
        var label: String
        /// The same for the prompt: "the 9 messages from … to now, the discussion on my screen".
        var described: String
    }

    /// A range picked by hand instead of what was found; nil sends what was found.
    @Published var manual: SlackRange? {
        didSet {
            if let manual { UserDefaults.standard.set(manual.rawValue, forKey: Self.rangeKey) }
        }
    }
    /// The panel's switch: Long looks back over 300 messages for the discussion, not the standard 100.
    @Published var long = false {
        didSet {
            guard long != oldValue, place != nil, working == nil, let shown else { return }
            manual = nil
            look(shown, resolving: false)
        }
    }
    @Published var ask = ""
    @Published private(set) var place: Place?
    @Published private(set) var found: Found?
    /// Still working out how much to send.
    @Published private(set) var finding = false
    @Published private(set) var problem: String?
    /// What it's doing while it reads and opens Claude; nil when idle.
    @Published private(set) var working: String?
    /// Goes up each time the panel opens, so the view puts the cursor in the ask.
    @Published private(set) var opened = 0

    private static let rangeKey = "slackToClaudeRange"
    private var panel: SlackPanel?
    /// What Slack's window showed when the shortcut was pressed.
    private var shown: SlackWindow.Shown?
    /// Finding the conversation and how much of it to send.
    private var looking: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// The range used when nothing could be found: the one last picked by hand.
    private var lastManual: SlackRange {
        SlackRange(rawValue: UserDefaults.standard.string(forKey: Self.rangeKey) ?? "") ?? .last50
    }

    /// Runs the step: opens the panel and returns once it closes, so a workflow's later steps
    /// run after it.
    func run() async {
        open()
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Return can be pressed while it's still working out how much to send: it sends once it knows.
    func send() {
        guard place != nil, working == nil else { return }
        problem = nil
        working = finding && manual == nil ? "Working out how much to send…" : "Reading messages…"
        let looking = looking
        task = Task {
            if manual == nil { await looking?.value }
            guard !Task.isCancelled, let place else { return }
            working = "Reading messages…"
            await sendNow(place, manual: manual, found: found, ask: ask)
        }
    }

    func close() {
        let resumed = waiting
        waiting = []
        looking?.cancel()
        looking = nil
        task?.cancel()
        task = nil
        working = nil
        finding = false
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
        looking?.cancel()
        ask = ""
        problem = nil
        place = nil
        shown = nil
        found = nil
        manual = nil
        long = false
        finding = false
        opened += 1
        let shown = SlackWindow.shown()
        present()
        switch shown {
        case let .failure(problem):
            self.problem = problem.explanation
        case let .success(shown):
            self.shown = shown
            look(shown, resolving: true)
        }
    }

    /// Finds the conversation (when it isn't known yet) and how much of it to send.
    private func look(_ shown: SlackWindow.Shown, resolving: Bool) {
        looking?.cancel()
        found = nil
        finding = true
        looking = Task {
            if resolving { await resolve(shown) }
            if let place, !Task.isCancelled { await find(place, shown: shown) }
            guard !Task.isCancelled else { return }
            finding = false
            // Nothing found: the range last picked by hand goes instead.
            if found == nil, place != nil { manual = lastManual }
        }
    }

    /// The open thread goes whole, so the switch has nothing to change.
    var foundThread: Bool {
        if case .thread = found?.what { return true }
        return false
    }

    /// Works out how much to send: the thread that's open beside the list, else the discussion
    /// on screen, from where it starts to where it ends. Claude places the start and the end
    /// when it has a key; without one, or when it doesn't answer, the messages on screen are
    /// joined by their neighbours until a long silence.
    private func find(_ place: Place, shown: SlackWindow.Shown) async {
        let api = SlackAPI(token: place.token)
        let reader = SlackReader(api: api)
        do {
            if let ts = shown.threadTs, let thread = try? await reader.thread(place.id, ts: ts) {
                guard !Task.isCancelled else { return }
                found = Found(what: .thread(thread), title: "This thread",
                              detail: SlackContext.threadSummary(replies: thread.replies.count),
                              label: SlackContext.threadLabel(replies: thread.replies.count),
                              described: SlackContext.describedThread(replies: thread.replies.count))
                return
            }
            let recent = try await reader.recent(place.id, lookBack: long ? SlackContext.longLookBack : SlackContext.lookBack,
                                                 covering: shown.onScreen.first)
            guard !recent.isEmpty else { return }
            let entries = recent.map(SlackReader.entry)
            var ids: Set<String> = [place.me]
            for entry in entries {
                if case let .user(id) = entry.author { ids.insert(id) }
                ids.formUnion(SlackText.mentionedUsers(in: entry.text))
            }
            let names = try await SlackDirectory.shared.names(ids, api)
            let transcript = SlackTranscript(names: names, me: place.me)
            let onScreen = Set(shown.onScreen)
            let lines = zip(recent, entries).map { message, entry in
                let text = entry.text.isEmpty ? (entry.attachments.first ?? entry.files.joined(separator: ", ")) : entry.text
                return SlackContext.Line(ts: message.ts, author: transcript.author(entry.author),
                                         text: SlackText.plain(text, names: names),
                                         replies: message.replyCount ?? 0, onScreen: onScreen.contains(message.ts))
            }
            var span = SlackContext.fallback(lines)
            if let key = ClaudeKeychain.key(),
               let answer = try? await ClaudeAPI(key: key).json(system: SlackContext.instructions,
                                                                user: SlackContext.digest(lines, time: transcript.time),
                                                                schema: SlackContext.schema),
               let placed = SlackContext.span(fromAnswer: answer, lines: lines) {
                span = placed
            }
            guard !Task.isCancelled, let span else { return }
            found = Found(what: .span(Array(recent[span.first...span.last])),
                          title: span.topic ?? "The discussion on screen",
                          detail: SlackContext.summary(span, lines: lines, time: transcript.time),
                          label: SlackContext.label(span, lines: lines, time: transcript.time),
                          described: SlackContext.described(span, lines: lines, time: transcript.time))
        } catch {
            // The range picked by hand is still there, and sending says what's wrong with Slack.
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

    private func sendNow(_ place: Place, manual: SlackRange?, found: Found?, ask: String) async {
        do {
            var api = SlackAPI(token: place.token)
            api.onWait = { [weak self] seconds in
                await MainActor.run { self?.working = "Slack asked to slow down, so waiting \(seconds) s…" }
            }
            let reader = SlackReader(api: api)
            let progress: @MainActor (String) -> Void = { [weak self] line in self?.working = line }
            let read: SlackRead
            let described: String
            if manual == nil, let found {
                switch found.what {
                case let .thread(entry):
                    read = SlackRead(entries: [entry])
                case let .span(messages):
                    read = SlackRead(entries: try await reader.entries(place.id, messages, threadCap: SlackRange.last50.threadCap,
                                                                       progress: progress))
                }
                described = found.described
            } else {
                let range = manual ?? lastManual
                read = try await reader.read(place.id, range: range, me: place.me, progress: progress)
                guard !read.entries.isEmpty else {
                    working = nil
                    problem = range.nothing(in: place.heading)
                    return
                }
                described = range.described(count: read.entries.count, foundMine: read.foundMine, reachedStart: read.reachedStart)
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
            let intro = "This is a Slack conversation from \(place.inPrompt): \(described)"
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
        // The title bar is hidden, so its strip is the panel's to fill: without this the
        // content keeps clear of it and leaves an empty band.
        controller.safeAreaRegions = []
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
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.place != nil { sending }
            askField
            if let problem = model.problem {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(problem)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 2)
            }
            footer
        }
        .padding(16)
        .frame(width: 540)
        .onAppear { asking = true }
        .onChange(of: model.opened) { asking = true }
    }

    /// Which conversation.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.place?.symbol ?? "text.bubble")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.place?.heading ?? (model.problem == nil ? "Finding the conversation…" : "Send Slack to Claude"))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.place?.detail ?? "Slack")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// How much of it goes: found by itself, with the switch for a longer look and, behind the
    /// chevron, the fixed ranges for when the guess is wrong.
    private var sending: some View {
        HStack(spacing: 10) {
            Group {
                if model.finding, model.manual == nil {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: model.manual == nil ? "text.viewfinder" : "hand.point.up.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(sendingTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = sendingDetail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Two lines tall from the start, so the panel doesn't jump when the answer arrives.
            .frame(minHeight: 32, alignment: .leading)
            Spacer(minLength: 8)
            if !model.foundThread {
                ReachSwitch(long: $model.long)
                    .help("Short looks for the discussion in the newest \(SlackContext.lookBack) messages, Long in the newest \(SlackContext.longLookBack).")
            }
            Menu {
                Picker("Sending", selection: $model.manual) {
                    if let found = model.found {
                        Text(found.label).tag(SlackRange?.none)
                    }
                    ForEach(SlackRange.allCases) { range in
                        Text(range.label).tag(SlackRange?.some(range))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Send a fixed range instead")
            .accessibilityLabel("Send a fixed range instead")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(model.working != nil)
    }

    private var sendingTitle: String {
        if let manual = model.manual { return manual.label }
        return model.found?.title ?? "Working out how much to send…"
    }

    private var sendingDetail: String? {
        if model.manual != nil { return "A fixed range, picked by hand" }
        return model.found?.detail
    }

    private var askField: some View {
        TextField("What would you like Claude to do?", text: $model.ask, axis: .vertical)
            .lineLimit(4...12)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($asking)
            .onSubmit { model.send() }
            .disabled(model.working != nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(asking ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let working = model.working {
                ProgressView()
                    .controlSize(.small)
                Text(working)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if model.place != nil {
                Text("Leave it blank to say it in Claude")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Button("Cancel") { model.close() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button { model.send() } label: {
                HStack(spacing: 6) {
                    Text("Open in Claude")
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.8)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.place == nil || model.working != nil)
        }
    }
}

/// Short or Long, as two quiet segments: the panel has one coloured control, its button.
private struct ReachSwitch: View {
    @Binding var long: Bool

    var body: some View {
        HStack(spacing: 2) {
            segment("Short", selected: !long) { long = false }
            segment("Long", selected: long) { long = true }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context")
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(selected ? Color.primary.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
