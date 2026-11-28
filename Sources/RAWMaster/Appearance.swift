import AppKit
import SwiftUI

enum AppAppearance {
    static let native = NSAppearance(named: .darkAqua)
    static let colorScheme: ColorScheme = .dark
}

/// The application palette applies to its interface. Photo pixels keep their own color management.
enum AppPalette {
    static let canvasNSColor = NSColor(calibratedWhite: 0.075, alpha: 1)
    static let panelNSColor = NSColor(calibratedWhite: 0.105, alpha: 1)
    static let canvas = Color(nsColor: canvasNSColor)
    static let panel = Color(nsColor: panelNSColor)
    static let thumbnailWell = Color(nsColor: NSColor(calibratedWhite: 0.055, alpha: 1))
    static let overlay = Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 0.94))
    static let boundary = Color(nsColor: .separatorColor)
    static let accent = Color(nsColor: NSColor(calibratedRed: 0.26, green: 0.80, blue: 0.94, alpha: 1))
    static let keep = Color(nsColor: NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.42, alpha: 1))
    static let warning = Color(nsColor: NSColor(calibratedRed: 0.98, green: 0.64, blue: 0.22, alpha: 1))
    static let rating = Color(nsColor: NSColor(calibratedRed: 0.98, green: 0.81, blue: 0.15, alpha: 1))
}
