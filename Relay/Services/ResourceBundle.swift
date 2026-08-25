import Foundation

extension Bundle {
    /// SwiftPM's generated `Bundle.module` accessor for executable targets only
    /// checks <app root>/Relay_Relay.bundle and the absolute .build path of the
    /// machine that compiled it — neither exists in an installed .app, so it
    /// fatalErrors on user machines (GitHub issue #3). build-app.sh packages the
    /// bundle in Contents/Resources; look there first and fall back to
    /// Bundle.module only for bare `swift build` development runs.
    static let relayResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Relay_Relay.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
