import SwiftUI

extension ContentType {
    var chipColor: Color {
        switch self {
        case .code: Self.adaptive(light: (0, 0.55, 0.85), dark: (0, 0.694, 1))
        case .json: Self.adaptive(light: (0, 0.60, 0.58), dark: (0, 0.788, 0.761))
        case .terminal: Self.adaptive(light: (0.35, 0.35, 0.35), dark: (0.49, 0.49, 0.49))
        case .url: Self.adaptive(light: (0, 0.42, 0.82), dark: (0, 0.541, 0.996))
        case .error: Self.adaptive(light: (0.85, 0.15, 0.12), dark: (1, 0.267, 0.235))
        case .diff: Self.adaptive(light: (0, 0.60, 0.36), dark: (0, 0.788, 0.471))
        case .agentation: Self.adaptive(light: (0.22, 0.33, 0.85), dark: (0.298, 0.455, 1))
        case .text: Self.adaptive(light: (0.35, 0.35, 0.35), dark: (0.49, 0.49, 0.49))
        case .image: Self.adaptive(light: (0.52, 0.22, 0.82), dark: (0.659, 0.349, 0.996))
        case .file: Self.adaptive(light: (0.78, 0.52, 0), dark: (0.976, 0.667, 0))
        case .voiceNote: Self.adaptive(light: (0.85, 0.22, 0.52), dark: (1, 0.365, 0.682))
        }
    }

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
