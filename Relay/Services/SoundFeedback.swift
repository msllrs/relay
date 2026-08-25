import AppKit

/// Selectable start/stop sound pairs, bundled as <theme>-start/stop.wav in
/// Resources/Sounds. Regenerate with Scripts/generate-sounds.py.
enum RecordingSoundTheme: String, CaseIterable, Identifiable {
    // Blip family
    case circuit
    case relay
    case breaker
    // Somber glide family
    case pulse
    case abyss
    case umbra
    // Airy family
    case drift
    case haze
    // Ambient family — soft reverberant taps
    case felt
    case ripple
    case halo

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Start/stop recording chirps — short synthesized wavs bundled in
/// Resources/Sounds.
@MainActor
final class SoundFeedback {
    private var startSound: NSSound?
    private var stopSound: NSSound?

    init(theme: RecordingSoundTheme = .circuit) {
        setTheme(theme)
    }

    func setTheme(_ theme: RecordingSoundTheme) {
        startSound = Self.load("\(theme.rawValue)-start")
        stopSound = Self.load("\(theme.rawValue)-stop")
    }

    private static func load(_ name: String) -> NSSound? {
        guard let url = Bundle.relayResources.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") else {
            NSLog("SoundFeedback: missing %@.wav", name)
            return nil
        }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = 0.5
        return sound
    }

    func playStart() {
        startSound?.stop()
        startSound?.play()
    }

    func playStop() {
        stopSound?.stop()
        stopSound?.play()
    }
}
