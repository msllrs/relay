import SwiftUI

extension ContentType {
    var chipColor: Color {
        switch self {
        case .code: Color(red: 0, green: 0.694, blue: 1) // #00B1FF
        case .json: Color(red: 0, green: 0.788, blue: 0.761) // #00C9C2
        case .terminal: Color(white: 0.49) // #7D7D7D
        case .url: Color(red: 0, green: 0.541, blue: 0.996) // #008AFE
        case .error: Color(red: 1, green: 0.267, blue: 0.235) // #FF443C
        case .diff: Color(red: 0, green: 0.788, blue: 0.471) // #00C978
        case .agentation: Color(red: 0.298, green: 0.455, blue: 1) // #4C74FF
        case .text: Color(white: 0.49) // #7D7D7D
        case .image: Color(red: 0.659, green: 0.349, blue: 0.996) // #A859FE
        case .file: Color(red: 0.976, green: 0.667, blue: 0) // #F9AA00
        case .voiceNote: Color(red: 1, green: 0.365, blue: 0.682) // #FF5DAE
        }
    }
}
