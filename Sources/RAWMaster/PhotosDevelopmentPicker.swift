import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct EditingDevelopmentPicker: Equatable {
    enum Kind: Equatable {
        case whiteBalance(PhotosWhiteBalanceMode)
        case selectiveColor(DevelopmentSelectiveColorSlotV3)
        case curve(channel: DevelopmentCurveChannelV3ID, point: DevelopmentCurvePickerPointV3)
        var group: DevelopmentAdjustmentID {
            switch self { case .whiteBalance: return .whiteBalance; case .selectiveColor: return .selectiveColor; case .curve: return .curves }
        }
        var instruction: String {
            switch self {
            case .whiteBalance(let mode): return mode == .skinTone ? "点选照片中的肤色" : "点选照片中的中性灰"
            case .selectiveColor: return "点选要调整的颜色"
            case .curve(_, let point):
                switch point { case .black: return "点选曲线黑点"; case .midtone: return "点选曲线中间调"; case .white: return "点选曲线白点"; case .addPoint: return "点选照片以添加曲线控制点" }
            }
        }
    }
    let id: UUID
    let context: EditingInteractionContext
    let recipeFingerprint: String
    let kind: Kind
}
struct EditingDevelopmentPickerFrame {
    let picker: EditingDevelopmentPicker
    let frameID: UUID
    let sourceGeneration: UInt64
    let mapping: DevelopmentGeometryMappingV3
    let outputPixelSize: CGSize
}

/// A temporary fit presentation of the exact accepted frame. The regular canvas keeps its existing
/// transform/actual-pixel state while this view is present, and restores them when sampling ends.
/// Points outside the image are rejected rather than clamped to an image edge.
struct PhotosDevelopmentPickerCanvas: View {
    let image: NSImage
    let frame: EditingDevelopmentPickerFrame
    let onFrameDrawn: @MainActor @Sendable (ImageFrameDrawEvent) -> Void
    let onPick: (DevelopmentSourcePoint) -> Void
    let onCancel: () -> Void
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(frame.picker.kind.instruction).font(.caption)
                Spacer()
                Button("取消", action: onCancel)
            }.padding(10).background(AppPalette.overlay)
            GeometryReader { geometry in
                let rectangle = ImageViewportGeometry.imageRect(pixelSize: frame.outputPixelSize, viewport: geometry.size,
                    transform: .init(), backingScale: displayScale)
                ZStack {
                ZoomableImageView(image: image, actualPixels: false, transform: .constant(.init()), backgroundColor: AppPalette.canvasNSColor,
                    frameID: frame.frameID, onFrameDrawn: onFrameDrawn)
                    .allowsHitTesting(false).accessibilityHidden(true)
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        guard rectangle.width > 0, rectangle.height > 0,
                              rectangle.contains(value.location) else { return }
                        onPick(.init(x: (value.location.x - rectangle.minX) / rectangle.width,
                                     y: (value.location.y - rectangle.minY) / rectangle.height))
                    })
                    .accessibilityLabel(frame.picker.kind.instruction)
                }
            }
            Text("取样时适合窗口 · 结束后恢复缩放").font(.caption2).foregroundStyle(.secondary).padding(6)
        }.id(frame.picker.id.uuidString + ":" + frame.frameID.uuidString)
    }
}
