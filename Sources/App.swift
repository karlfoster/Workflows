import SwiftUI

@main
struct WorkflowsApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
        } label: {
            Image(systemName: "command")
        }
        .menuBarExtraStyle(.window)

        Window("Workflows", id: "editor") {
            EditorView()
                .environmentObject(store)
                .frame(minWidth: 660, minHeight: 440)
        }
        .defaultSize(width: 760, height: 500)
    }
}
