import Foundation
import Security

/// The Slack tokens, one per workspace, kept in the login Keychain and nowhere else. Each item's
/// account is the workspace's team ID; the first token, saved before there could be several, is
/// under the account "token". Workflows creates the items itself, so with its Developer ID
/// signature it reads them back after every update without asking.
enum SlackKeychain {
    static let service = "com.karlfoster.Workflows.slack"
    /// The account of the token saved before workspaces had their own items.
    static let legacyAccount = "token"

    struct Stored: Equatable {
        /// The workspace's team ID, or `legacyAccount`.
        var account: String
        var token: String
    }

    private static func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Every saved token, the old single one first, then by account.
    static func all() -> [Stored] {
        var search = query()
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        search[kSecReturnAttributes as String] = true
        var items: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &items) == errSecSuccess,
              let found = items as? [[String: Any]] else { return [] }
        let accounts = found.compactMap { $0[kSecAttrAccount as String] as? String }
        return accounts
            .sorted { ($0 == legacyAccount ? "" : $0) < ($1 == legacyAccount ? "" : $1) }
            .compactMap { account in token(account).map { Stored(account: account, token: $0) } }
    }

    static func token(_ account: String) -> String? {
        var item: CFTypeRef?
        var search = query(account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    /// Saves the token for its workspace, replacing that workspace's old one (including the old
    /// single token if it was for the same workspace).
    @discardableResult
    static func save(_ token: String, for account: SlackAPI.AuthTest) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(query(account.teamId) as CFDictionary)
        var item = query(account.teamId)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Workflows: Slack token for \(account.team)"
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        return true
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    /// `Workflows --store-slack-token < file`: checks the token read from standard input with
    /// Slack, saves it for its workspace, then quits before any window or hotkey, so a token can
    /// be set up without it ever appearing in a command line or on screen.
    static func storeFromCommandLineIfAsked() {
        guard CommandLine.arguments.contains("--store-slack-token") else { return }
        let input = (String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func finish(_ line: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data((line + "\n").utf8))
            exit(code)
        }
        guard !input.isEmpty else { finish("No token saved: standard input was empty.", 1) }
        final class Box: @unchecked Sendable { var line = "No token saved."; var code: Int32 = 1 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let account = try await SlackAPI(token: input).auth()
                if save(input, for: account) {
                    await dropLegacy(ifFor: account)
                    box.line = "Slack token for \(account.team) saved in the Keychain."
                    box.code = 0
                } else {
                    box.line = "Couldn't save the token in the Keychain."
                }
            } catch {
                box.line = "No token saved: \((error as? SlackError)?.explanation ?? error.localizedDescription)"
            }
            done.signal()
        }
        done.wait()
        finish(box.line, box.code)
    }

    /// Removes the old single token when it belongs to this workspace, now that the workspace
    /// has its own item.
    static func dropLegacy(ifFor account: SlackAPI.AuthTest) async {
        guard let legacy = token(legacyAccount),
              (try? await SlackAPI(token: legacy).auth())?.teamId == account.teamId else { return }
        delete(legacyAccount)
    }
}
