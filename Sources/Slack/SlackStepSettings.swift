import SwiftUI

/// The Send Slack to Claude step in the editor: whether Slack is connected, and a place to
/// add or change the token.
struct SlackStepSettings: View {
    @State private var status = "Checking Slack…"
    @State private var connected: Bool?
    @State private var editing = false
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: connected == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(connected == true ? Color.green : Color.orange)
                    .opacity(connected == nil ? 0 : 1)
                Text(status)
                    .font(.subheadline)
                Spacer()
                Button(editing ? "Cancel" : (connected == true ? "Change Token…" : "Add Token…")) {
                    editing.toggle()
                    token = ""
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
            Text("With a channel or chat open in Slack, press this workflow's shortcut, choose how far back and what you'd like, and it opens in Claude. It only reads from Slack. Requires Accessibility access.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .task { await check() }
    }

    private func check() async {
        guard let token = SlackKeychain.token() else {
            connected = false
            status = "Not connected to Slack"
            return
        }
        do {
            let account = try await SlackAPI(token: token).auth()
            connected = true
            status = "Connected to \(account.team) as \(account.user)"
        } catch SlackError.unreachable {
            connected = false
            status = "Couldn't reach Slack to check the token"
        } catch {
            connected = false
            status = "Slack didn't accept the token"
        }
    }

    private func save() {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard SlackKeychain.save(token) else {
            status = "Couldn't save the token in the Keychain"
            return
        }
        token = ""
        editing = false
        connected = nil
        status = "Checking Slack…"
        Task { await check() }
    }
}
