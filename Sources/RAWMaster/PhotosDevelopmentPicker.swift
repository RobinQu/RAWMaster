import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct EditingDevelopmentPicker: Equatable {
    enum Kind: Equatable {
        case whiteBalance(PhotosWhiteBalanceMode)
        case selectiveColor(DevelopmentSelectiveColorSlotV3)
        case selectiveColorTargeted(DevelopmentSelectiveColorSlotV3, DevelopmentTargetedColorAttributeV3)
        case defringe(DevelopmentDefringeBandV3)
        case pointColor(UUID)
        case curve(channel: DevelopmentCurveChannelV3ID, point: DevelopmentCurvePickerPointV3)
        case curveTargeted(DevelopmentCurveChannelV3ID)
        case parametricCurveTargeted
        case colorSampler(replacing: Int?)
        case lensBlurFocus, lensBlurArea, lensBlurRefineFocus, lensBlurRefineBlur
        var group: DevelopmentAdjustmentID {
            switch self { case .whiteBalance: return .whiteBalance; case .colorSampler: return .color; case .selectiveColor,.selectiveColorTargeted: return .selectiveColor; case .defringe:return .optics; case .pointColor:return .selectiveColor; case .curve,.curveTargeted,.parametricCurveTargeted: return .curves; case .lensBlurFocus,.lensBlurArea,.lensBlurRefineFocus,.lensBlurRefineBlur:return .sharpen }
        }
        var isLensBlur: Bool {
            switch self { case .lensBlurFocus,.lensBlurArea,.lensBlurRefineFocus,.lensBlurRefineBlur:return true;default:return false }
        }
        var isTargetedColor: Bool { if case .selectiveColorTargeted = self {return true};return false }
        var isTargetedCurve: Bool {
            switch self { case .curveTargeted, .parametricCurveTargeted: return true; default: return false }
        }
        var instruction: String {
            switch self {
            case .whiteBalance(let mode): return mode == .skinTone ? "点选照片中的肤色" : "点选照片中的中性灰"
            case .selectiveColor: return "点选要调整的颜色"
            case .selectiveColorTargeted: return "先点选取样，再在照片上上下拖动调整"
            case .defringe(let band): return "点选照片中的" + (band == .purple ? "紫色边" : "绿色边")
            case .pointColor: return "点选照片以建立独立颜色样本"
            case .curve(_, let point):
                switch point { case .black: return "点选曲线黑点"; case .midtone: return "点选曲线中间调"; case .white: return "点选曲线白点"; case .addPoint: return "点选照片以添加曲线控制点" }
            case .curveTargeted:return "先点选曲线取样点，再左右／上下拖动输入与输出"
            case .parametricCurveTargeted: return "在照片上选定影调，向上或向右拖动提亮，向下或向左拖动压暗"
            case .colorSampler: return "点选照片上的采样位置"
            case .lensBlurFocus:return "点选照片以设置 Lens Blur 焦点"
            case .lensBlurArea:return "在照片上拖动以设置 Lens Blur 焦内区域"
            case .lensBlurRefineFocus:return "刷涂要恢复焦内的区域"
            case .lensBlurRefineBlur:return "刷涂要增强模糊的区域"
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
    var onAreaPick: ((DevelopmentSourcePoint, DevelopmentSourcePoint) -> Void)? = nil
    var onStrokePick: (([DevelopmentStrokePoint]) -> Void)? = nil
    var targetedReady: Bool = false
    var onTargetedDrag: ((Double, Bool) -> Void)? = nil
    var onCurveDrag: ((SIMD2<Double>, Bool) -> Void)? = nil
    let onCancel: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var dragOrigin: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var strokePoints: [CGPoint] = []
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
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { dragChanged($0, rectangle: rectangle) }
                            .onEnded { dragEnded($0, rectangle: rectangle) })
                        .accessibilityLabel(frame.picker.kind.instruction)
                    dragOverlay
                }
            }
            Text("取样时适合窗口 · 结束后恢复缩放").font(.caption2).foregroundStyle(.secondary).padding(6)
        }.id(frame.picker.kind.isTargetedCurve ? frame.picker.id : frame.frameID)
    }
    private func targetedDelta(_ value:DragGesture.Value,rectangle:CGRect)->Double {
        min(1,max(-1,(value.startLocation.y-value.location.y)/max(rectangle.height,1)*2))
    }
    private func curveDelta(_ value:DragGesture.Value,rectangle:CGRect)->SIMD2<Double> {
        .init(x:min(1,max(-1,(value.location.x-value.startLocation.x)/max(rectangle.width,1))),
              y:min(1,max(-1,(value.startLocation.y-value.location.y)/max(rectangle.height,1))))
    }
    private func dragChanged(_ value:DragGesture.Value,rectangle:CGRect) {
        if frame.picker.kind == .parametricCurveTargeted {
            if dragOrigin == nil {
                guard rectangle.contains(value.startLocation) else { return }
                onPick(normalized(value.startLocation, rectangle: rectangle))
            }
            dragOrigin = value.startLocation
            onCurveDrag?(curveDelta(value, rectangle: rectangle), false)
            return
        }
        dragOrigin = value.startLocation; dragCurrent = value.location
        if let onCurveDrag,targetedReady { onCurveDrag(curveDelta(value,rectangle:rectangle),false) }
        if let onTargetedDrag,targetedReady { onTargetedDrag(targetedDelta(value,rectangle:rectangle),false) }
        if onStrokePick != nil {
            if strokePoints.isEmpty { strokePoints = [value.startLocation] }
            if strokePoints.last != value.location { strokePoints.append(value.location) }
        }
    }
    private func dragEnded(_ value:DragGesture.Value,rectangle:CGRect) {
        defer { dragOrigin = nil; dragCurrent = nil; strokePoints = [] }
        if frame.picker.kind == .parametricCurveTargeted {
            if dragOrigin != nil { onCurveDrag?(curveDelta(value, rectangle: rectangle), true) }
            return
        }
        if let onCurveDrag,targetedReady { onCurveDrag(curveDelta(value,rectangle:rectangle),true);return }
        if let onTargetedDrag,targetedReady { onTargetedDrag(targetedDelta(value,rectangle:rectangle),true);return }
        guard rectangle.width > 0, rectangle.height > 0, rectangle.contains(value.location) else { return }
        if let onStrokePick {
            guard rectangle.contains(value.startLocation) else { return }
            var locations=strokePoints.isEmpty ? [value.startLocation]:strokePoints
            if locations.last != value.location { locations.append(value.location) }
            onStrokePick(locations.map{DevelopmentStrokePoint(position:normalized($0,rectangle:rectangle))})
        } else if let onAreaPick {
            guard rectangle.contains(value.startLocation), value.startLocation != value.location else { return }
            onAreaPick(normalized(value.startLocation,rectangle:rectangle),normalized(value.location,rectangle:rectangle))
        } else { onPick(normalized(value.location,rectangle:rectangle)) }
    }
    private func normalized(_ point:CGPoint,rectangle:CGRect)->DevelopmentSourcePoint {
        .init(x:(point.x-rectangle.minX)/rectangle.width,y:(point.y-rectangle.minY)/rectangle.height)
    }
    @ViewBuilder private var dragOverlay:some View {
        if onStrokePick != nil, !strokePoints.isEmpty {
            Path { path in
                path.move(to:strokePoints[0]);for point in strokePoints.dropFirst(){path.addLine(to:point)}
            }.stroke(AppPalette.accent,lineWidth:2).allowsHitTesting(false)
        } else if let dragOrigin, let dragCurrent, onAreaPick != nil {
            Path { path in
                path.addRect(.init(x:min(dragOrigin.x,dragCurrent.x),y:min(dragOrigin.y,dragCurrent.y),
                    width:abs(dragCurrent.x-dragOrigin.x),height:abs(dragCurrent.y-dragOrigin.y)))
            }.stroke(AppPalette.accent,lineWidth:1.5).allowsHitTesting(false)
        }
    }
}
