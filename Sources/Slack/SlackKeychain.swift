import Foundation
import Security

/// The Slack token, kept in the login Keychain and nowhere else. Workflows creates the item
/// itself, so with its Developer ID signature it reads it back after every update without asking.
enum SlackKeychain {
    static let service = "com.karlfoster.Workflows.slack"
    static let account = "token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func token() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Workflows: Slack token"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    /// `Workflows --store-slack-token < file`: saves the token read from standard input, then
    /// quits before any window or hotkey, so a token can be set up without it ever appearing
    /// in a command line or on screen.
    static func storeFromCommandLineIfAsked() {
        guard CommandLine.arguments.contains("--store-slack-token") else { return }
        let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let saved = save(input)
        FileHandle.standardError.write(Data((saved ? "Slack token saved in the Keychain.\n" : "No token saved: standard input was empty.\n").utf8))
        exit(saved ? 0 : 1)
    }
}
