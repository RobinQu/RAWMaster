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
    let onPick: (Int?) -> Void
    @State private var colors: [DevelopmentDisplayPixel?] = []
    private struct Input: Equatable {
        let frameID: UUID?
        let points: [DevelopmentSourcePoint]
        let mapping: DevelopmentGeometryMappingV3?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { onPick(nil) } label: { Label("添加颜色采样点", systemImage: "eyedropper") }
                .buttonStyle(.borderless).disabled(samplers.points.count >= PhotosColorSamplers.limit)
                .accessibilityIdentifier("photos.scopes.sampler.add")
            ForEach(samplers.points.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text("\(i + 1)").fontWeight(.semibold)
                    if colors.indices.contains(i), let sample = colors[i] {
                        let rgb = sample.rgb * 255
                        Text(String(format: "R %.0f   G %.0f   B %.0f", rgb.x, rgb.y, rgb.z)).monospacedDigit()
                    } else { Text("当前画面外").foregroundStyle(.secondary) }
                    Spacer()
                    Menu {
                        Button("重新取样") { onPick(i) }
                        Button("移除采样点") { samplers.remove(i) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("编辑采样点 \(i + 1)")
                }
            }
        }.font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
            .task(id: Input(frameID: frame?.id, points: samplers.points, mapping: mapping)) {
                colors = samplers.colors(frame: frame, mapping: mapping)
            }
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
