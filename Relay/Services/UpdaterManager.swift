import Foundation
import SwiftUI

#if canImport(Sparkle)
import Sparkle
#endif

/// Wraps Sparkle's updater controller, exposing a simple `checkForUpdates()` action
/// and a `canCheckForUpdates` binding for SwiftUI buttons.
@MainActor
final class UpdaterManager: ObservableObject {
    @Published var canCheckForUpdates = false

    #if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController
    private var observation: Any?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Check for updates on every launch (prompts user before installing)
        updaterController.updater.automaticallyChecksForUpdates = true

        // Bridge KVO → @Published
        observation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
    #else
    init() {}
    func checkForUpdates() {}
    #endif
}
