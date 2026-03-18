import Foundation
import SwiftUI

#if canImport(Sparkle)
import Sparkle
#endif

/// Wraps Sparkle's updater controller, exposing a simple `checkForUpdates()` action
/// and a `canCheckForUpdates` binding for SwiftUI buttons.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    @Published var canCheckForUpdates = false

    #if canImport(Sparkle)
    // IUO so super.init() can run before we pass `self` as delegate
    private var updaterController: SPUStandardUpdaterController!
    private var observation: Any?

    override init() {
        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
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
    override init() {}
    func checkForUpdates() {}
    #endif
}

#if canImport(Sparkle)
// MARK: - SPUStandardUserDriverDelegate
extension UpdaterManager: SPUStandardUserDriverDelegate {
    /// Normalize all font sizes in the release notes to system font size so they
    /// match the rest of the Sparkle update dialog. Sparkle scales headers to
    /// 1.2–1.5× by default, which makes the notes feel much heavier than the
    /// surrounding UI text. Bold weight is preserved so headers remain distinct.
    nonisolated func standardUserDriverWillShowReleaseNotesText(
        _ releaseNotesAttributedString: NSAttributedString,
        for update: SUAppcastItem,
        withBundleDisplayVersion bundleDisplayVersion: String,
        bundleVersion: String
    ) -> NSAttributedString? {
        let targetSize = NSFont.systemFontSize
        let mutable = NSMutableAttributedString(attributedString: releaseNotesAttributedString)
        let fullRange = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard let font = value as? NSFont else { return }
            guard font.pointSize != targetSize else { return }

            let resized = NSFontManager.shared.convert(font, toSize: targetSize)
            mutable.addAttribute(.font, value: resized, range: range)
        }

        return mutable
    }
}
#endif
