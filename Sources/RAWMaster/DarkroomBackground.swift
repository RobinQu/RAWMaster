import AppKit
import SwiftUI

/// Fixed neutral darkroom surrounds. These are presentation-only and never enter the recipe.
enum DarkroomBackground: String, CaseIterable, Identifiable {
    case darkGray, mediumGray, lightGray, black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .darkGray: return "深灰"
        case .mediumGray: return "中灰"
        case .lightGray: return "浅灰"
        case .black: return "纯黑"
        }
    }
    var symbol: String {
        switch self {
        case .darkGray: return "circle.lefthalf.filled"
        case .mediumGray: return "circle.dotted"
        case .lightGray: return "circle"
        case .black: return "circle.fill"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .darkGray: return NSColor(calibratedWhite: 0.075, alpha: 1)
        case .mediumGray: return NSColor(calibratedWhite: 0.20, alpha: 1)
        case .lightGray: return NSColor(calibratedWhite: 0.42, alpha: 1)
        case .black: return .black
        }
    }
    var color: Color { Color(nsColor: nsColor) }
}
