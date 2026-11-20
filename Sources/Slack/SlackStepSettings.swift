import SwiftUI

/// The Send Slack to Claude step in the editor: which Slack workspaces are connected, a place to
/// add one, and a way to remove one.
struct SlackStepSettings: View {
    private struct Row: Identifiable {
        /// The Keychain account.
        var id: String
        var status: String
        var connected: Bool
    }

    @State private var rows: [Row] = []
    @State private var checking = true
    @State private var message: String?
    @State private var editing = false
    @State private var token = ""
    @State private var hasClaudeKey = ClaudeKeychain.key() != nil
    @State private var editingClaude = false
    @State private var claudeKey = ""
    @State private var claudeMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if checking {
                Text("Checking Slack…")
                    .font(.subheadline)
            } else if rows.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Color.orange)
                    Text("Not connected to Slack")
                        .font(.subheadline)
                }
            }
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(row.connected ? Color.green : Color.orange)
                    Text(row.status)
                        .font(.subheadline)
                    Spacer()
                    Button("Remove") {
                        SlackKeychain.delete(row.id)
                        Task { await check() }
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(editing ? "Cancel" : (rows.isEmpty ? "Add Token…" : "Add Workspace…")) {
                    editing.toggle()
                    token = ""
                    message = nil
                }
                .controlSize(.small)
            }
            if editing {
                HStack(spacing: 8) {
                    SecureField("Slack user token (xoxp-…)", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Divider()
                .padding(.vertical, 2)
            HStack(spacing: 6) {
                Image(systemName: hasClaudeKey ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(hasClaudeKey ? Color.green : Color.secondary)
                Text(claudeMessage ?? (hasClaudeKey ? "Claude finds where the conversation on screen starts"
                                                    : "No Claude API key: it sends the messages on screen and the ones around them"))
                    .font(.subheadline)
                Spacer()
                if hasClaudeKey {
                    Button("Remove") {
                        ClaudeKeychain.delete()
                        hasClaudeKey = false
                        claudeMessage = nil
                    }
                    .controlSize(.small)
                } else {
                    Button(editingClaude ? "Cancel" : "Add Key…") {
                        editingClaude.toggle()
                        claudeKey = ""
                        claudeMessage = nil
                    }
                    .controlSize(.small)
                }
            }
            if editingClaude {
                HStack(spacing: 8) {
                    SecureField("Claude API key (sk-ant-…)", text: $claudeKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveClaude)
                    Button("Save", action: saveClaude)
                        .disabled(claudeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("With a channel, chat or thread open in Slack, press this workflow's shortcut and say what you'd like. It works out how much of the conversation belongs with what's on your screen and opens that in Claude. Add a token for each workspace you use; it reads with the one Slack is showing. It only reads from Slack. Requires Accessibility access.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .task { await check() }
    }

    private func saveClaude() {
        let entered = claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return }
        claudeMessage = "Checking the key…"
        Task {
            do {
                try await ClaudeAPI(key: entered).check()
                guard ClaudeKeychain.save(entered) else {
                    claudeMessage = "Couldn't save the key in the Keychain"
                    return
                }
                claudeKey = ""
                editingClaude = false
                hasClaudeKey = true
                claudeMessage = nil
            } catch ClaudeError.rejectedKey {
                claudeMessage = "Claude didn't accept the key"
            } catch ClaudeError.unreachable {
                claudeMessage = "Couldn't reach Claude to check the key"
            } catch let ClaudeError.failed(message) {
                claudeMessage = "Claude said “\(message)”"
            } catch {
                claudeMessage = error.localizedDescription
            }
        }
    }

    private func check() async {
        checking = true
        var found: [Row] = []
        for stored in SlackKeychain.all() {
            do {
                let account = try await SlackAPI(token: stored.token).auth()
                found.append(Row(id: stored.account, status: "\(account.team), as \(account.user)", connected: true))
            } catch SlackError.unreachable {
                found.append(Row(id: stored.account, status: "Couldn't reach Slack to check this token", connected: false))
            } catch {
                found.append(Row(id: stored.account, status: "Slack didn't accept this token", connected: false))
            }
        }
        rows = found
        checking = false
    }

    private func save() {
        let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return }
        message = "Checking the token…"
        Task {
            do {
                let account = try await SlackAPI(token: entered).auth()
                guard SlackKeychain.save(entered, for: account) else {
                    message = "Couldn't save the token in the Keychain"
                    return
                }
                await SlackKeychain.dropLegacy(ifFor: account)
                token = ""
                editing = false
                message = nil
                await check()
            } catch let error as SlackError {
                message = error == .unreachable ? "Couldn't reach Slack to check the token" : "Slack didn't accept the token"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
