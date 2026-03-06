import SwiftUI

@main
struct RelayApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(appState)
        } label: {
            MenuBarIcon(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
