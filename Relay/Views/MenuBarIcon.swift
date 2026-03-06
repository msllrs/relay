import AppKit
import SwiftUI

enum MenuBarIconBuilder {
    // Closed arc — monitoring off
    private static let normalSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" fill="none" viewBox="0 0 36 36">
      <path fill="#fff" d="M18 4c7.732 0 14 6.268 14 14a13.99 13.99 0 0 1-.537 3.852c-.336 1.175-1.83 1.306-2.543.314-.307-.425-.382-.97-.254-1.48.217-.86.334-1.759.334-2.686 0-6.075-4.925-11-11-11S7 11.925 7 18c0 .927.116 1.827.333 2.686.128.51.053 1.055-.254 1.48-.714.992-2.207.86-2.542-.315A14.006 14.006 0 0 1 4 18c0-7.732 6.268-14 14-14Z"/>
      <path fill="#fff" d="m9.44 29.409 6.812-12.262c.762-1.372 2.734-1.372 3.496 0l6.812 12.262a1.744 1.744 0 1 1-3.056 1.682L18 21l-5.504 10.09a1.744 1.744 0 1 1-3.056-1.682Z"/>
    </svg>
    """

    // Open arc with notch — monitoring on
    private static let activeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" fill="none" viewBox="0 0 36 36">
      <path fill="#fff" d="M16.252 17.146c.762-1.37 2.734-1.37 3.496 0l6.813 12.262a1.745 1.745 0 1 1-3.057 1.683L18 21l-5.504 10.09a1.745 1.745 0 1 1-3.057-1.682l6.813-12.262ZM18 4c.997 0 1.969.104 2.906.302a7.946 7.946 0 0 0-.866 2.89A11.055 11.055 0 0 0 18 7C11.925 7 7 11.925 7 18c0 .927.116 1.827.333 2.686.128.51.052 1.054-.254 1.48-.714.992-2.207.86-2.543-.314A14.008 14.008 0 0 1 4 18c0-7.732 6.268-14 14-14Zm13.697 11.093a14.06 14.06 0 0 1-.234 6.759c-.336 1.175-1.83 1.306-2.543.314-.306-.426-.382-.97-.254-1.48a10.969 10.969 0 0 0 .142-4.727 7.944 7.944 0 0 0 2.89-.866Z"/>
    </svg>
    """

    // Open arc with notch + green dot — item just added
    private static let badgeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" fill="none" viewBox="0 0 36 36">
      <path fill="#fff" d="M16.252 17.146c.762-1.37 2.734-1.37 3.496 0l6.813 12.262a1.745 1.745 0 1 1-3.057 1.683L18 21l-5.504 10.09a1.745 1.745 0 1 1-3.057-1.682l6.813-12.262ZM18 4c.997 0 1.969.104 2.906.302a7.946 7.946 0 0 0-.866 2.89A11.055 11.055 0 0 0 18 7C11.925 7 7 11.925 7 18c0 .927.116 1.827.333 2.686.128.51.052 1.054-.254 1.48-.714.992-2.207.86-2.543-.314A14.008 14.008 0 0 1 4 18c0-7.732 6.268-14 14-14Zm13.697 11.093a14.06 14.06 0 0 1-.234 6.759c-.336 1.175-1.83 1.306-2.543.314-.306-.426-.382-.97-.254-1.48a10.969 10.969 0 0 0 .142-4.727 7.944 7.944 0 0 0 2.89-.866Z"/>
      <circle cx="28" cy="8" r="5.5" fill="#34c759"/>
    </svg>
    """

    static func buildIcon(state: IconState) -> NSImage {
        let svgString: String
        let template: Bool
        switch state {
        case .normal:
            svgString = normalSVG
            template = true
        case .active:
            svgString = activeSVG
            template = true
        case .badge:
            svgString = badgeSVG
            template = false
        }
        guard let data = svgString.data(using: .utf8),
              let img = NSImage(data: data) else {
            return NSImage()
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = template
        return img
    }

    enum IconState {
        case normal   // monitoring off
        case active   // monitoring on
        case badge    // item just added (green dot)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var appState: AppState

    private var icon: NSImage {
        if appState.isMonitoring {
            return MenuBarIconBuilder.buildIcon(state: .badge)
        }
        return MenuBarIconBuilder.buildIcon(state: .normal)
    }

    var body: some View {
        Image(nsImage: icon)
    }
}
