import SwiftUI
import RAWMasterCore
import RAWMasterImaging

/// Inspection annotations stay with the source photo across recipe branches and crops.
@MainActor final class PhotosColorSamplers: ObservableObject {
    static let limit = 9
    @Published private(set) var points: [DevelopmentSourcePoint] = []
    private var key: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func bind(workID: String, sourceID: String) {
        let next = "editing.colorSamplers.v1." + workID + "." + sourceID
        guard next != key else { return }
        key = next
        points = defaults.data(forKey: next)
            .flatMap { try? JSONDecoder().decode([DevelopmentSourcePoint].self, from: $0) }
            .flatMap { $0.count <= Self.limit ? $0 : nil } ?? []
    }

    @discardableResult func place(_ point: DevelopmentSourcePoint, replacing index: Int? = nil) -> Bool {
        guard key != nil, (try? point.validate()) != nil else { return false }
        var next = points
        if let index {
            guard next.indices.contains(index) else { return false }
            next[index] = point
        } else {
            guard next.count < Self.limit else { return false }
            next.append(point)
        }
        return save(next)
    }

    func remove(_ index: Int) {
        guard points.indices.contains(index) else { return }
        var next = points
        next.remove(at: index)
        _ = save(next)
    }

    func colors(frame: EditingPreviewBitmap?, mapping: DevelopmentGeometryMappingV3?) -> [DevelopmentDisplayPixel?] {
        guard !points.isEmpty, let mapping,
              let cg = frame?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return points.map { point in
            guard let output = try? mapping.outputPoint(fromSource: point) else { return nil }
            return DevelopmentDisplayPixel.sample(cg, at: output)
        }
    }

    private func save(_ next: [DevelopmentSourcePoint]) -> Bool {
        guard let key, let data = try? JSONEncoder().encode(next) else { return false }
        if next.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(data, forKey: key) }
        points = next
        return true
    }
}

struct PhotosColorSamplerRows: View {
    @ObservedObject var samplers: PhotosColorSamplers
    let frame: EditingPreviewBitmap?
    let mapping: DevelopmentGeometryMappingV3?
    var showsScene = false
    var sceneFrame: DevelopmentScenePreviewFrameV1?
    var visualizingHDR = false
    let onPick: (Int?) -> Void
    @State private var colors: [DevelopmentDisplayPixel?] = []
    @State private var linearColors: [DevelopmentDisplayPixel.LinearSample?] = []
    @State private var sampledInput: Input?
    private struct Input: Equatable {
        let frameID: UUID?
        let points: [DevelopmentSourcePoint]
        let mapping: DevelopmentGeometryMappingV3?
        let showsScene: Bool
    }
    private var input: Input {
        .init(frameID: showsScene ? sceneFrame?.id : frame?.id, points: samplers.points, mapping: mapping, showsScene: showsScene)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
            Button { onPick(nil) } label: { Label("添加颜色采样点", systemImage: "eyedropper") }
                .buttonStyle(PhotosFlatButtonStyle(stretches: true))
                .disabled(samplers.points.count >= PhotosColorSamplers.limit)
                .accessibilityIdentifier("photos.scopes.sampler.add")
            VStack(spacing: PhotosControlLayout.spacing) {
                ForEach(samplers.points.indices, id: \.self) { i in
                    samplerRow(i)
                }
            }
        }.font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
            .task(id: input) {
                let request = input
                if showsScene, let sceneFrame, let mapping {
                    let points = request.points.map { try? mapping.outputPoint(fromSource: $0) }
                    let result = await Task.detached(priority: .userInitiated) {
                        DevelopmentDisplayPixel.linearSamples(sceneFrame, at: points)
                    }.value
                    guard !Task.isCancelled else { return }
                    linearColors = result
                } else {
                    linearColors = []
                    colors = samplers.colors(frame: frame, mapping: mapping)
                }
                sampledInput = request
            }
    }
    private func samplerRow(_ index: Int) -> some View {
        let current = sampledInput == input
        let sample = current && colors.indices.contains(index) ? colors[index] : nil
        let scene = current && linearColors.indices.contains(index) ? linearColors[index] : nil
        let swatchColor: Color?
        let readout: String?
        if showsScene, let scene {
            let rgb = scene.rgb
            let scale = max(1, rgb.max())
            let components = [CGFloat(rgb.x / scale), CGFloat(rgb.y / scale), CGFloat(rgb.z / scale), 1]
            swatchColor = scene.colorSpace.flatMap { CGColor(colorSpace: $0, components: components) }.map { Color(cgColor: $0) }
            let space = scene.target == .hdr2020 ? "Rec.2020" : "Rec.709"
            readout = String(format: "R %.2f  G %.2f  B %.2f · %.0f nits · %@", rgb.x, rgb.y, rgb.z, scene.luminanceNits, space)
        } else if !showsScene, let sample {
            let rgb = sample.rgb
            swatchColor = Color(.sRGB, red: Double(min(1, max(0, rgb.x))), green: Double(min(1, max(0, rgb.y))), blue: Double(min(1, max(0, rgb.z))))
            readout = String(format: "R %.0f   G %.0f   B %.0f", rgb.x * 255, rgb.y * 255, rgb.z * 255)
        } else {
            swatchColor = nil; readout = nil
        }
        return HStack(spacing: 8) {
            swatch(swatchColor).accessibilityHidden(true)
            Text("\(index + 1)").fontWeight(.semibold)
            if let readout {
                Text(readout)
                    .monospacedDigit().fixedSize(horizontal: false, vertical: true)
            } else if visualizingHDR {
                Text("退出亮度诊断后可读数").foregroundStyle(.secondary)
            } else {
                Text(!current || showsScene && sceneFrame == nil ? "等待读数" : "当前画面外").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button { onPick(index) } label: { Label("重新取样", systemImage: "eyedropper") }
                Button(role: .destructive) { samplers.remove(index) } label: { Label("移除采样点", systemImage: "trash") }
            } label: { PhotosFlatControlLabel(label: Image(systemName: "ellipsis")) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("编辑采样点 \(index + 1)")
                .accessibilityIdentifier("photos.scopes.sampler.manage.\(index + 1)")
        }
        .frame(minHeight: 28).padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photos.scopes.sampler.row.\(index + 1)")
    }
    private func swatch(_ color: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return shape.fill(color ?? .clear)
        .overlay(shape.strokeBorder(.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: color == nil ? [3, 2] : [])))
        .frame(width: 18, height: 18)
    }
}

struct PhotosColorSamplerMarkers: View {
    @ObservedObject var samplers: PhotosColorSamplers
    let mapping: DevelopmentGeometryMappingV3
    let rect: CGRect

    var body: some View {
        ForEach(samplers.points.indices, id: \.self) { i in
            if let p = try? mapping.outputPoint(fromSource: samplers.points[i]) {
                Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .padding(3).background(Circle().fill(.black.opacity(0.7)))
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
                    .position(x: rect.minX + rect.width * p.x, y: rect.minY + rect.height * p.y)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
