import SwiftUI

extension ContentType {
    var chipColor: Color {
        switch self {
        case .code: Self.chipColors.code
        case .json: Self.chipColors.json
        case .terminal: Self.chipColors.terminal
        case .url: Self.chipColors.url
        case .error: Self.chipColors.error
        case .diff: Self.chipColors.diff
        case .agentation: Self.chipColors.agentation
        case .text: Self.chipColors.text
        case .image: Self.chipColors.image
        case .file: Self.chipColors.file
        case .folder: Self.chipColors.file
        case .voiceNote: Self.chipColors.voiceNote
        }
    }

    private struct ChipColors {
        let code: Color
        let json: Color
        let terminal: Color
        let url: Color
        let error: Color
        let diff: Color
        let agentation: Color
        let text: Color
        let image: Color
        let file: Color
        let voiceNote: Color
    }

    private static let chipColors = ChipColors(
        code: adaptive(light: (0, 0.55, 0.85), dark: (0, 0.694, 1)),
        json: adaptive(light: (0, 0.60, 0.58), dark: (0, 0.788, 0.761)),
        terminal: adaptive(light: (0.35, 0.35, 0.35), dark: (0.68, 0.68, 0.68)),
        url: adaptive(light: (0, 0.42, 0.82), dark: (0, 0.541, 0.996)),
        error: adaptive(light: (0.85, 0.15, 0.12), dark: (1, 0.267, 0.235)),
        diff: adaptive(light: (0, 0.60, 0.36), dark: (0, 0.788, 0.471)),
        agentation: adaptive(light: (0.22, 0.33, 0.85), dark: (0.298, 0.455, 1)),
        text: adaptive(light: (0.35, 0.35, 0.35), dark: (0.68, 0.68, 0.68)),
        image: adaptive(light: (0.52, 0.22, 0.82), dark: (0.659, 0.349, 0.996)),
        file: adaptive(light: (0.78, 0.52, 0), dark: (0.976, 0.667, 0)),
        voiceNote: adaptive(light: (0.85, 0.22, 0.52), dark: (1, 0.365, 0.682))
    )

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1)
            } else {
                NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
            }
        })
    }
}
