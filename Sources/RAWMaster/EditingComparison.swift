import Foundation
import RAWMasterCore

/// Presentation and reference are independent: changing the wipe style must never change the photo.
enum EditingComparisonMode: String, CaseIterable, Identifiable, Sendable {
    case off, referenceOnly, wipeHorizontal, wipeVertical, mix, difference, checkerboard, sideLeftRight, sideTopBottom
    var id: String { rawValue }
    var isActive: Bool { self != .off }
    var isSideBySide: Bool { self == .sideLeftRight || self == .sideTopBottom }
    var usesWipeHandle: Bool { self == .wipeHorizontal || self == .wipeVertical }
    var supportsInversion: Bool { isActive && self != .referenceOnly && self != .difference }
    var title: String {
        switch self {
        case .off: "关闭对比"
        case .referenceOnly: "仅显示参考"
        case .wipeHorizontal: "水平擦除"
        case .wipeVertical: "垂直擦除"
        case .mix: "混合"
        case .difference: "差异"
        case .checkerboard: "棋盘格"
        case .sideLeftRight: "左右并排"
        case .sideTopBottom: "上下并排"
        }
    }
    var symbol: String {
        switch self {
        case .off: "rectangle"
        case .referenceOnly: "photo"
        case .wipeHorizontal: "rectangle.lefthalf.inset.filled"
        case .wipeVertical: "rectangle.tophalf.inset.filled"
        case .mix: "circle.lefthalf.filled"
        case .difference: "plus.forwardslash.minus"
        case .checkerboard: "checkerboard.rectangle"
        case .sideLeftRight: "rectangle.split.2x1"
        case .sideTopBottom: "rectangle.split.1x2"
        }
    }
}

enum EditingComparisonReference: Equatable, Sendable {
    case original
    case version(String)

    /// Resolve and revalidate the same-Work invariant at the point of use, not only in menu admission.
    func resolve(work: PhotoWork?, versions: [EditingVersion]) -> EditingVersion? {
        guard let work else { return nil }
        let id: String
        switch self {
        case .original: id = work.originalVersionID
        case .version(let value): id = value
        }
        guard let version = versions.first(where: { $0.id == id }), version.workID == work.id,
              version.source.hasSameIdentity(as: work.source) else { return nil }
        return version
    }
}

struct EditingComparisonState: Equatable, Sendable {
    var mode: EditingComparisonMode = .off
    var reference: EditingComparisonReference = .original
    var inverted = false
    var isActive: Bool { mode.isActive }
}

/// A reference bitmap is displayable only for the exact focus, Work, reference and source submitted above.
/// The pane may retain old pixels for its own lifecycle, but the canvas must not present them under a new reference.
struct EditingComparisonAdmission: Equatable, Sendable {
    let focusID: UUID
    let workID: String
    let referenceID: String
    let sourceKey: String
    let presentationID: String

    func matches(focusID: UUID, workID: String?, frame: EditingPreviewBitmap?,
                 frameSourceKey: String?, framePresentationID: String?) -> Bool {
        guard frame != nil, self.focusID == focusID, self.workID == workID,
              frameSourceKey == sourceKey, framePresentationID == presentationID else { return false }
        return true
    }
}

enum EditingComparisonGeometry {
    /// Before/After is a tonal and local-edit comparison. Both sides share the current geometry,
    /// including crop, rotation, perspective and late orientation, so corresponding pixels stay aligned.
    static func align(reference: DevelopmentRecipe, current: DevelopmentRecipe) throws -> DevelopmentRecipe {
        var aligned = try reference.promotingToV3()
        let currentV3 = try current.promotingToV3()
        aligned.adjustmentsV3?.geometry = currentV3.adjustmentsV3?.geometry ?? .init()
        try aligned.validate()
        return aligned
    }
}
