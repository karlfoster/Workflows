import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct MenuView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 9)

            if store.workflows.isEmpty {
                Text("No workflows yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(store.workflows) { workflow in
                        workflowRow(workflow)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider()
                .padding(.horizontal, 14)

            VStack(spacing: 10) {
                HStack {
                    Text("Launch at login")
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { _, enable in
                            do {
                                if enable {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
                Button {
                    openWindow(id: "editor")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Edit Workflows…")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .padding(.horizontal, 14)

            Button("Quit Workflows") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 300)
        .onAppear {
            // Refresh only when the menu is opened — never in the background.
            store.refresh()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Workflows")
                .font(.headline)
            Spacer()
            Image(systemName: "command")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.tertiary)
        }
    }

    private func workflowRow(_ workflow: Workflow) -> some View {
        Button {
            store.run(workflow)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(workflow.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                if let shortcut = KeyboardShortcuts.getShortcut(for: Store.shortcutName(workflow.id)) {
                    Text(shortcut.description)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

/// Plain row that highlights on hover, like native menu items.
private struct MenuRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08) : .clear)
            )
            .onHover { hovering = $0 }
    }
}
