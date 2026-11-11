import Foundation

enum SlackError: Error, Equatable {
    /// No token in the Keychain yet.
    case notConnected
    /// Slack answered with this error code ("invalid_auth", "channel_not_found"…).
    case slack(String)
    /// Slack couldn't be reached.
    case unreachable
    /// Slack is showing a workspace with no token; these are the ones connected.
    case otherWorkspace(connected: String)

    /// What the panel and the step's settings say.
    var explanation: String {
        switch self {
        case .notConnected:
            "Slack isn't connected yet. Add a token in Edit Workflows…, on the Send Slack to Claude step."
        case .slack("invalid_auth"), .slack("not_authed"), .slack("token_revoked"), .slack("token_expired"), .slack("account_inactive"):
            "Slack didn't accept the token. Add a new one in Edit Workflows…, on the Send Slack to Claude step."
        case .slack("channel_not_found"):
            "Slack couldn't find this conversation for your account."
        case .slack("ratelimited"):
            "Slack asked to slow down. Try again in a minute."
        case let .slack(code):
            "Slack said “\(code)”."
        case .unreachable:
            "Couldn't reach Slack. Check the connection and try again."
        case let .otherWorkspace(connected):
            "Slack is showing a workspace that isn't connected. Connected: \(connected). Add its token in Edit Workflows…, on the Send Slack to Claude step."
        }
    }
}

/// Slack's Web API, read-only: `get` refuses any method not in `readMethods`, so the step can
/// never post, react or change anything, whatever the token would allow.
struct SlackAPI {
    let token: String
    var session: URLSession = .shared
    /// Told how many seconds it waits when Slack asks it to slow down, so the panel can say so.
    var onWait: (@Sendable (Int) async -> Void)?

    static let readMethods: Set<String> = [
        "auth.test",
        "conversations.history",
        "conversations.info",
        "conversations.members",
        "conversations.replies",
        "users.conversations",
        "users.info",
        "users.list",
    ]

    func get<T: Decodable>(_ method: String, _ parameters: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        precondition(Self.readMethods.contains(method), "The Slack step only reads")
        var components = URLComponents(string: "https://slack.com/api/" + method)!
        if !parameters.isEmpty {
            components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for attempt in 0..<6 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SlackError.unreachable
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                guard attempt < 5 else { throw SlackError.slack("ratelimited") }
                let wait = Int(min(max(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2, 1), 60))
                await onWait?(wait)
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
                throw SlackError.slack("unreadable_response")
            }
            guard envelope.ok else { throw SlackError.slack(envelope.error ?? "unknown_error") }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw SlackError.slack("unreadable_response")
            }
        }
        throw SlackError.slack("ratelimited")
    }

    // MARK: - What Slack sends back

    struct Envelope: Decodable {
        let ok: Bool
        let error: String?
    }

    struct Cursor: Decodable {
        let nextCursor: String?
    }

    struct AuthTest: Decodable, Equatable {
        let team: String
        let teamId: String
        let user: String
        let userId: String
    }

    struct Message: Decodable {
        struct Named: Decodable { let name: String? }
        struct File: Decodable {
            let name: String?
            let title: String?
        }
        struct Attachment: Decodable {
            let title: String?
            let pretext: String?
            let text: String?
            let fallback: String?
            let fromUrl: String?
            let originalUrl: String?
        }
        struct Reaction: Decodable {
            let name: String
            let count: Int
        }

        let ts: String
        let user: String?
        let botId: String?
        let username: String?
        let botProfile: Named?
        let text: String?
        let subtype: String?
        let threadTs: String?
        let replyCount: Int?
        let files: [File]?
        let attachments: [Attachment]?
        let reactions: [Reaction]?
    }

    struct History: Decodable {
        let messages: [Message]
        let hasMore: Bool?
        let responseMetadata: Cursor?
    }

    struct Channel: Decodable {
        let id: String
        let name: String?
        let isChannel: Bool?
        let isGroup: Bool?
        let isIm: Bool?
        let isMpim: Bool?
        let isPrivate: Bool?
        /// The other person, for a direct message.
        let user: String?
    }

    struct ChannelInfo: Decodable { let channel: Channel }

    struct ChannelList: Decodable {
        let channels: [Channel]
        let responseMetadata: Cursor?
    }

    struct Members: Decodable {
        let members: [String]
        let responseMetadata: Cursor?
    }

    struct User: Decodable {
        struct Profile: Decodable {
            let realName: String?
            let displayName: String?
        }
        let id: String
        let name: String?
        let realName: String?
        let profile: Profile?
    }

    struct UserInfo: Decodable { let user: User }

    struct UserList: Decodable {
        let members: [User]
        let responseMetadata: Cursor?
    }
}

// MARK: - Reading a conversation

extension SlackAPI {
    func auth() async throws -> AuthTest {
        try await get("auth.test")
    }

    func conversation(_ id: String) async throws -> Channel {
        try await get("conversations.info", ["channel": id], as: ChannelInfo.self).channel
    }

    func members(_ id: String) async throws -> [String] {
        var members: [String] = []
        var cursor = ""
        repeat {
            var parameters = ["channel": id, "limit": "200"]
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            let page = try await get("conversations.members", parameters, as: Members.self)
            members += page.members
            cursor = page.responseMetadata?.nextCursor ?? ""
        } while !cursor.isEmpty && members.count < 1_000
        return members
    }

    /// The ID of my channel with this name, for when Slack's window gives only its title.
    func channelID(named name: String) async throws -> String? {
        var cursor = ""
        var pages = 0
        repeat {
            var parameters = ["types": "public_channel,private_channel", "exclude_archived": "true", "limit": "1000"]
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            let page = try await get("users.conversations", parameters, as: ChannelList.self)
            if let match = page.channels.first(where: { $0.name == name }) { return match.id }
            cursor = page.responseMetadata?.nextCursor ?? ""
            pages += 1
        } while !cursor.isEmpty && pages < 10
        return nil
    }

    /// Everyone in the workspace, for matching the names in a chat's title.
    func everyone() async throws -> [User] {
        var people: [User] = []
        var cursor = ""
        var pages = 0
        repeat {
            var parameters = ["limit": "1000"]
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            let page = try await get("users.list", parameters, as: UserList.self)
            people += page.members
            cursor = page.responseMetadata?.nextCursor ?? ""
            pages += 1
        } while !cursor.isEmpty && pages < 20
        return people
    }

    /// The direct message or group chat that Slack's title names ("Ana Silva, Ben Okafor,
    /// Chloe Martin"), for when Slack's page address doesn't carry it: in the Direct
    /// messages view it's only `…/client/T…/dms`.
    func chatID(titled title: String, me: AuthTest, people: [User]) async throws -> String? {
        let names = SlackChatMatch.names(inTitle: title)
        guard let candidates = SlackChatMatch.candidates(for: names, people: people) else { return nil }
        var chats: [Channel] = []
        var cursor = ""
        var pages = 0
        repeat {
            var parameters = ["types": "im,mpim", "exclude_archived": "true", "limit": "1000"]
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            let page = try await get("users.conversations", parameters, as: ChannelList.self)
            chats += page.channels
            cursor = page.responseMetadata?.nextCursor ?? ""
            pages += 1
        } while !cursor.isEmpty && pages < 10
        if let found = SlackChatMatch.chat(candidates: candidates, me: me, chats: chats) { return found }
        // A group chat named before someone changed their handle: check its members instead.
        guard candidates.count > 1 else { return nil }
        let groups = chats.filter { $0.isMpim == true && SlackChatMatch.handles(inGroupName: $0.name ?? "")?.count == candidates.count + 1 }
        for group in groups.prefix(40) {
            let members = Set(try await self.members(group.id))
            if SlackChatMatch.covers(members: members, candidates: candidates, me: me.userId) { return group.id }
        }
        return nil
    }

    /// The name shown for a person: their full name, else their display name, else their handle.
    func name(of userID: String) async -> String? {
        guard let user = try? await get("users.info", ["user": userID], as: UserInfo.self).user else { return nil }
        return Self.shownName(user)
    }

    static func shownName(_ user: User) -> String? {
        let candidates = [user.realName, user.profile?.realName, user.profile?.displayName, user.name]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

/// Finding a chat from the names in Slack's window title.
enum SlackChatMatch {
    /// "Ana Silva, Ben Okafor, Chloe Martin" → the three names.
    static func names(inTitle title: String) -> [String] {
        title.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Case, accents and extra spaces don't count: "Björn  Larsson" matches "bjorn larsson".
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The people each name could be (by full name, display name or handle); nil when a name
    /// matches nobody.
    static func candidates(for names: [String], people: [SlackAPI.User]) -> [[SlackAPI.User]]? {
        guard !names.isEmpty else { return nil }
        var result: [[SlackAPI.User]] = []
        for name in names {
            let wanted = normalized(name)
            let matches = people.filter { person in
                [person.realName, person.profile?.realName, person.profile?.displayName, person.name]
                    .compactMap { $0 }.contains { normalized($0) == wanted }
            }
            guard !matches.isEmpty else { return nil }
            result.append(matches)
        }
        return result
    }

    /// "mpdm-ana.silva--ben.okafor--sam.taylor-1" → the handles in it.
    static func handles(inGroupName name: String) -> [String]? {
        guard name.hasPrefix("mpdm-") else { return nil }
        var rest = String(name.dropFirst("mpdm-".count))
        if let suffix = rest.range(of: "-[0-9]+$", options: .regularExpression) { rest.removeSubrange(suffix) }
        let handles = rest.components(separatedBy: "--").filter { !$0.isEmpty }
        return handles.isEmpty ? nil : handles
    }

    /// One name: my direct message with that person. Several: my group chat with exactly
    /// those people, by the handles in its name.
    static func chat(candidates: [[SlackAPI.User]], me: SlackAPI.AuthTest, chats: [SlackAPI.Channel]) -> String? {
        if candidates.count == 1 {
            let ids = Set(candidates[0].map(\.id))
            return chats.first { $0.isIm == true && ids.contains($0.user ?? "") }?.id
        }
        for chat in chats where chat.isMpim == true {
            guard let handles = handles(inGroupName: chat.name ?? ""), handles.count == candidates.count + 1,
                  handles.contains(me.user) else { continue }
            let set = Set(handles)
            if candidates.allSatisfy({ people in people.contains { set.contains($0.name ?? "") } }) { return chat.id }
        }
        return nil
    }

    /// The members are me and one of each name's people, and nobody else.
    static func covers(members: Set<String>, candidates: [[SlackAPI.User]], me: String) -> Bool {
        guard members.count == candidates.count + 1, members.contains(me) else { return false }
        return candidates.allSatisfy { people in people.contains { members.contains($0.id) } }
    }
}

/// What the step read: the messages (oldest first, with their replies).
struct SlackRead {
    var entries: [SlackEntry]
    /// For "Since I last wrote": whether one of my messages was among those read.
    var foundMine = true
    /// Whether the reading got back to the conversation's first message, or stopped at its cap.
    var reachedStart = true
}

/// Reads the messages for a range, then their threads.
struct SlackReader {
    typealias Message = SlackAPI.Message
    typealias History = SlackAPI.History

    let api: SlackAPI

    /// Join and leave notices say nothing to Claude.
    static let skipped: Set<String> = ["channel_join", "channel_leave", "group_join", "group_leave"]

    func read(_ channel: String, range: SlackRange, me: String, now: Date = Date(), calendar: Calendar = .current,
              progress: @MainActor @escaping (String) -> Void) async throws -> SlackRead {
        var paged: (messages: [Message], reachedStart: Bool)
        var foundMine = true
        func history(oldest: Date?, limit: Int, until: @escaping ([Message]) -> Bool = { _ in false }) async throws -> (messages: [Message], reachedStart: Bool) {
            try await page(channel, oldest: oldest, limit: limit, cap: range.messageCap, until: until, progress: progress)
        }
        switch range {
        case .last50:
            paged = try await history(oldest: nil, limit: 50, until: { $0.count >= 50 })
            paged.messages = Array(paged.messages.prefix(50))
        case .today:
            paged = try await history(oldest: calendar.startOfDay(for: now), limit: 200)
        case .week:
            paged = try await history(oldest: now.addingTimeInterval(-7 * 24 * 3600), limit: 200)
        case .sinceMine:
            paged = try await history(oldest: nil, limit: 100, until: { read in read.contains { $0.user == me } })
            if let mine = paged.messages.firstIndex(where: { $0.user == me }) {
                paged.messages = Array(paged.messages[...mine])
            } else {
                foundMine = false
            }
        case .all:
            paged = try await history(oldest: nil, limit: 200)
        }
        // Slack gives the newest first.
        var messages = Array(paged.messages.reversed())

        // A reply also sent to the channel shows in its thread when the thread is read.
        let starts = Set(messages.filter { ($0.replyCount ?? 0) > 0 }.map(\.ts))
        messages.removeAll { message in
            guard let thread = message.threadTs, thread != message.ts else { return false }
            return starts.contains(thread)
        }

        let shown = messages
        var entries = shown.map(Self.entry)
        let threads = entries.indices.filter { (shown[$0].replyCount ?? 0) > 0 }
        let read = Array(threads.suffix(range.threadCap))
        let reading = Set(read)
        for index in threads where !reading.contains(index) {
            entries[index].repliesNotRead = shown[index].replyCount ?? 0
        }
        if !read.isEmpty {
            let total = read.count
            await progress(total == 1 ? "Reading 1 thread…" : "Reading \(total) threads…")
            let replies = try await Self.limited(read, width: 4, { index in
                try await self.replies(channel, ts: shown[index].ts)
            }, done: { done in
                // A long history's threads take a while: say how far it's got.
                if total > 20, done % 10 == 0, done < total { await progress("Reading threads: \(done) of \(total)…") }
            })
            for (index, thread) in zip(read, replies) {
                entries[index].replies = thread.map(Self.entry)
                entries[index].repliesNotRead = max(0, (shown[index].replyCount ?? 0) - thread.count)
            }
        }
        return SlackRead(entries: entries, foundMine: foundMine, reachedStart: paged.reachedStart)
    }

    /// Top-level messages, newest first, from `oldest` (nil: any age), page by page until
    /// `until` says enough or `cap` is reached. Join and leave notices are left out.
    /// `reachedStart`: no older messages are left in the range.
    private func page(_ channel: String, oldest: Date?, limit: Int, cap: Int, until: ([Message]) -> Bool,
                      progress: @MainActor @escaping (String) -> Void) async throws -> (messages: [Message], reachedStart: Bool) {
        var messages: [Message] = []
        var cursor = ""
        repeat {
            var parameters = ["channel": channel, "limit": String(limit)]
            if let oldest { parameters["oldest"] = String(format: "%.6f", oldest.timeIntervalSince1970) }
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            let page = try await api.get("conversations.history", parameters, as: History.self)
            messages += page.messages.filter { !Self.skipped.contains($0.subtype ?? "") }
            cursor = (page.hasMore ?? false) ? (page.responseMetadata?.nextCursor ?? "") : ""
            if !cursor.isEmpty, messages.count >= 400 {
                await progress("Read \(SlackRange.number(messages.count)) messages…")
            }
        } while !cursor.isEmpty && messages.count < cap && !until(messages)
        return (Array(messages.prefix(cap)), cursor.isEmpty && messages.count <= cap)
    }

    /// A thread's replies, oldest first, without the message that started it.
    private func replies(_ channel: String, ts: String) async throws -> [Message] {
        var replies: [Message] = []
        var cursor = ""
        repeat {
            var parameters = ["channel": channel, "ts": ts, "limit": "200"]
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            let page = try await api.get("conversations.replies", parameters, as: History.self)
            replies += page.messages.filter { $0.ts != ts && !Self.skipped.contains($0.subtype ?? "") }
            cursor = (page.hasMore ?? false) ? (page.responseMetadata?.nextCursor ?? "") : ""
        } while !cursor.isEmpty && replies.count < 1_000
        return replies
    }

    static func entry(_ message: Message) -> SlackEntry {
        let author: SlackEntry.Author
        if let user = message.user, message.botId == nil {
            author = .user(user)
        } else if let name = message.username ?? message.botProfile?.name {
            author = .bot(SlackText.unescape(name))
        } else if let user = message.user {
            author = .user(user)
        } else {
            author = .unknown
        }
        // Link previews repeat a link already in the text; other attachments carry an app's message.
        let attachments = (message.attachments ?? []).compactMap { attachment -> String? in
            guard attachment.fromUrl == nil, attachment.originalUrl == nil else { return nil }
            let parts = [attachment.pretext, attachment.title, attachment.text ?? attachment.fallback]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return SlackEntry(
            ts: message.ts,
            author: author,
            text: message.text ?? "",
            files: (message.files ?? []).map { SlackText.unescape($0.title ?? $0.name ?? "a file") },
            attachments: attachments,
            reactions: (message.reactions ?? []).map { SlackEntry.Reaction(name: $0.name, count: $0.count) }
        )
    }

    /// `work` on each item, at most `width` at a time, results in the items' order.
    static func limited<T: Sendable, R: Sendable>(_ items: [T], width: Int, _ work: @escaping @Sendable (T) async throws -> R,
                                                  done: ((Int) async -> Void)? = nil) async throws -> [R] {
        var results = [R?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var next = 0
            func add() {
                let index = next
                let item = items[index]
                group.addTask { (index, try await work(item)) }
                next += 1
            }
            while next < min(width, items.count) { add() }
            var finished = 0
            while let (index, result) = try await group.next() {
                results[index] = result
                finished += 1
                await done?(finished)
                if next < items.count { add() }
            }
        }
        return results.map { $0! }
    }
}

/// Who's who, kept while the app runs, for each token: its own account and people's names.
actor SlackDirectory {
    static let shared = SlackDirectory()

    private struct Known {
        var account: SlackAPI.AuthTest?
        var names: [String: String] = [:]
        var people: [SlackAPI.User] = []
        var peopleRead = Date.distantPast
    }

    private var known: [String: Known] = [:]

    func account(_ api: SlackAPI) async throws -> SlackAPI.AuthTest {
        if let account = known[api.token]?.account { return account }
        let fetched = try await api.auth()
        known[api.token, default: Known()].account = fetched
        return fetched
    }

    /// Everyone in the workspace, read again after six hours so new people turn up.
    func everyone(_ api: SlackAPI) async throws -> [SlackAPI.User] {
        if let cached = known[api.token], !cached.people.isEmpty,
           Date().timeIntervalSince(cached.peopleRead) < 6 * 3600 { return cached.people }
        let people = try await api.everyone()
        var entry = known[api.token] ?? Known()
        entry.people = people
        entry.peopleRead = Date()
        for person in people where entry.names[person.id] == nil {
            entry.names[person.id] = SlackAPI.shownName(person)
        }
        known[api.token] = entry
        return people
    }

    /// Names for these user IDs; anyone Slack can't name is left out.
    func names(_ ids: Set<String>, _ api: SlackAPI) async throws -> [String: String] {
        let missing = Array(ids.subtracting((known[api.token]?.names ?? [:]).keys))
        if !missing.isEmpty {
            let found = try await SlackReader.limited(missing, width: 6) { id in await api.name(of: id) }
            for (id, name) in zip(missing, found) {
                if let name { known[api.token, default: Known()].names[id] = name }
            }
        }
        return (known[api.token]?.names ?? [:]).filter { ids.contains($0.key) }
    }
}
