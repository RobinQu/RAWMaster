import CoreGraphics

public enum ImageComparisonMode: Equatable, Sendable {
    case wipeHorizontal, wipeVertical, mix, difference, checkerboard
}

public struct ImageComparisonPresentation: Equatable, Sendable {
    public var mode: ImageComparisonMode
    /// Wipe position or current-image opacity for Mix.
    public var amount: CGFloat
    public var inverted: Bool
    public init(mode: ImageComparisonMode = .wipeHorizontal, amount: CGFloat = 0.5, inverted: Bool = false) {
        self.mode = mode; self.amount = amount; self.inverted = inverted
    }
}
