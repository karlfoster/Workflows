import Foundation
import Security

enum ClaudeError: Error, Equatable {
    /// Claude didn't accept the key.
    case rejectedKey
    case unreachable
    /// Claude declined to answer.
    case declined
    /// Claude answered with this error, or with something that isn't an answer.
    case failed(String)
}

/// One question to Claude over its Messages API, answered in a JSON shape. The Slack step uses
/// it to work out how much of a conversation to send; it never sends anything anywhere else.
struct ClaudeAPI {
    let key: String
    var session: URLSession = .shared

    /// A small, fast model: the panel waits on its answer.
    static let model = "claude-haiku-5-5"
    static let version = "2026-10-21"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The JSON text of the answer to `user`, in the shape `schema` gives.
    func json(system: String, user: String, schema: [String: Any], timeout: TimeInterval = 12) async throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(system: system, user: user, schema: schema))
        let (data, response) = try await send(request)
        return try Self.answer(status: response.statusCode, data: data)
    }

    /// Whether Claude accepts the key for the model the step uses. Costs nothing.
    func check() async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models/" + Self.model)!)
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await send(request)
        guard response.statusCode != 200 else { return }
        throw Self.error(status: response.statusCode, data: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClaudeError.unreachable }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClaudeError {
            throw error
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ClaudeError.unreachable
        }
    }

    // MARK: - The request and the answer (no network needed)

    /// Low effort: the question is short and the panel is waiting. No sampling settings: this
    /// model refuses them.
    static func body(system: String, user: String, schema: [String: Any]) -> [String: Any] {
        ["model": model,
         "max_tokens": 2000,
         "system": system,
         "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
         "messages": [["role": "user", "content": user]]]
    }

    /// The answer's text: its first text block, which may come after thinking blocks.
    static func answer(status: Int, data: Data) throws -> String {
        guard status == 200 else { throw error(status: status, data: data) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.failed("unreadable answer")
        }
        let stop = object["stop_reason"] as? String
        if stop == "refusal" { throw ClaudeError.declined }
        let blocks = (object["content"] as? [[String: Any]]) ?? []
        guard stop != "max_tokens",
              let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              !text.isEmpty else {
            throw ClaudeError.failed(stop == "max_tokens" ? "answer cut short" : "no answer")
        }
        return text
    }

    static func error(status: Int, data: Data) -> ClaudeError {
        if status == 401 || status == 403 { return .rejectedKey }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (object?["error"] as? [String: Any])?["message"] as? String
        return .failed(message ?? "status \(status)")
    }
}

/// Claude's API key, kept in the login Keychain and nowhere else, beside the Slack tokens.
enum ClaudeKeychain {
    static let service = "com.karlfoster.Workflows.claude"
    static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func key() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Workflows: Claude API key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    /// `Workflows --store-claude-key < file`: checks the key read from standard input with
    /// Claude, saves it, then quits before any window or hotkey, so a key can be set up without
    /// it ever appearing in a command line or on screen.
    static func storeFromCommandLineIfAsked() {
        guard CommandLine.arguments.contains("--store-claude-key") else { return }
        let input = (String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func finish(_ line: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data((line + "\n").utf8))
            exit(code)
        }
        guard !input.isEmpty else { finish("No key saved: standard input was empty.", 1) }
        final class Box: @unchecked Sendable { var line = "No key saved."; var code: Int32 = 1 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await ClaudeAPI(key: input).check()
                if save(input) {
                    box.line = "Claude API key saved in the Keychain."
                    box.code = 0
                } else {
                    box.line = "Couldn't save the key in the Keychain."
                }
            } catch ClaudeError.rejectedKey {
                box.line = "No key saved: Claude didn't accept it."
            } catch ClaudeError.unreachable {
                box.line = "No key saved: couldn't reach Claude to check it."
            } catch let ClaudeError.failed(message) {
                box.line = "No key saved: Claude said “\(message)”."
            } catch {
                box.line = "No key saved: \(error.localizedDescription)"
            }
            done.signal()
        }
        done.wait()
        finish(box.line, box.code)
    }
}
