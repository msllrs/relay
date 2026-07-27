import AppKit

/// Start/stop recording chirps — short synthesized wavs bundled in
/// Resources/Sounds (see the repo history for the generation script).
@MainActor
final class SoundFeedback {
    private let startSound: NSSound?
    private let stopSound: NSSound?

    init() {
        func load(_ name: String) -> NSSound? {
            guard let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") else {
                NSLog("SoundFeedback: missing %@.wav", name)
                return nil
            }
            let sound = NSSound(contentsOf: url, byReference: true)
            sound?.volume = 0.5
            return sound
        }
        startSound = load("record-start")
        stopSound = load("record-stop")
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
