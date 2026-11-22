import SwiftUI
import RAWMasterCore

/// Explicit Detail-panel controls. Their stored optionals keep old sharpening recipes bit-exact.
enum PhotosSharpeningControl: String, CaseIterable, Identifiable {
    case radius, detail, masking
    var id: String { rawValue }
    var title: String {
        switch self { case .radius: "半径"; case .detail: "细节"; case .masking: "蒙版" }
    }
    var range: ClosedRange<Double> {
        switch self { case .radius: 0.5...3; case .detail, .masking: 0...100 }
    }
    var step: Double { self == .radius ? 0.1 : 1 }
    var digits: Int { self == .radius ? 1 : 0 }
    static func value(_ control: Self, in parameters: DevelopmentSharpenV3) -> Double {
        switch control {
        case .radius: parameters.radius ?? 1
        case .detail: (parameters.detail ?? 0.25) * 100
        case .masking: (parameters.masking ?? 0) * 100
        }
    }
    static func command(_ control: Self, value: Double, parameters: DevelopmentSharpenV3) throws -> DevelopmentAdjustmentCommand {
        guard value.isFinite, control.range.contains(value) else { throw EditingError.invalidRecipe }
        var next = parameters
        switch control {
        case .radius: next.radius = value
        case .detail: next.detail = value / 100
        case .masking: next.masking = value / 100
        }
        next.enabled = true
        try next.validate()
        return .setParameters(.sharpen(next))
    }
}

struct PhotosSharpeningControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    var onMaskingInteraction: ((Bool) -> Void)? = nil
    var body: some View {
        VStack(spacing: 9) {
            PhotosScalarAdjustmentControls(session: session, context: context, group: .sharpen, onError: onError)
            ForEach(PhotosSharpeningControl.allCases) { control in
                PhotosTypedValueRow(session: session, context: context, group: .sharpen,
                    name: control.title, value: PhotosSharpeningControl.value(control, in: session.parameters.sharpen),
                    readValue: { PhotosSharpeningControl.value(control, in: session.parameters.sharpen) },
                    range: control.range, step: control.step, digits: control.digits,
                    command: { try PhotosSharpeningControl.command(control, value: $0, parameters: session.parameters.sharpen) },
                    onError: onError,
                    onInteraction: control == .masking ? { active in onMaskingInteraction?(active) } : nil)
                    .accessibilityIdentifier("photos.sharpen." + control.rawValue)
            }
            Text("按住 Option 拖动“蒙版”可查看黑白锐化区域；松开后恢复原照片。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
