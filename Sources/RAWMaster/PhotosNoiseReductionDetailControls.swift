import SwiftUI
import RAWMasterCore

enum PhotosNoiseReductionDetailControl: String, CaseIterable, Identifiable {
    case luminanceContrast, colorDetail
    var id: String { rawValue }
    var title: String { self == .luminanceContrast ? "亮度对比度" : "颜色细节" }
    static func value(_ control: Self, in parameters: DevelopmentNoiseReductionV3) -> Double {
        switch control {
        case .luminanceContrast: (parameters.luminanceContrast ?? 0) * 100
        case .colorDetail: (parameters.colorDetail ?? 0.5) * 100
        }
    }
    static func command(_ control: Self, value: Double, parameters: DevelopmentNoiseReductionV3,
                        capability: DevelopmentNoiseReductionSourceCapability?) throws -> DevelopmentAdjustmentCommand {
        guard value.isFinite, (0...100).contains(value), let capability else { throw EditingError.invalidRecipe }
        var next = parameters
        switch control {
        case .luminanceContrast: next.luminanceContrast = value / 100
        case .colorDetail: next.colorDetail = value / 100
        }
        next.sourceCapability = capability; next.enabled = true
        try next.validate(for: capability)
        return .setParameters(.noiseReduction(next))
    }
}

struct PhotosNoiseReductionDetailControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let supportedFieldIDs: Set<String>
    let onError: (Error) -> Void
    var body: some View {
        VStack(spacing: 9) {
            PhotosScalarAdjustmentControls(session: session, context: context, group: .noiseReduction,
                onError: onError, supportedFieldIDs: supportedFieldIDs)
            ForEach(PhotosNoiseReductionDetailControl.allCases) { control in
                PhotosTypedValueRow(session: session, context: context, group: .noiseReduction,
                    name: control.title, value: PhotosNoiseReductionDetailControl.value(control, in: session.parameters.noiseReduction),
                    readValue: { PhotosNoiseReductionDetailControl.value(control, in: session.parameters.noiseReduction) },
                    range: 0...100, step: 1, digits: 0,
                    command: { try PhotosNoiseReductionDetailControl.command(control, value: $0,
                        parameters: session.parameters.noiseReduction, capability: session.noiseReductionCapability) },
                    onError: onError)
                    .accessibilityIdentifier("photos.noiseReduction." + control.rawValue)
            }
        }
    }
}
