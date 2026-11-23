import AppKit
import RAWMasterCore
import RAWMasterImaging
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class PhotosLUTLibraryModel: ObservableObject {
    static let shared = PhotosLUTLibraryModel()
    @Published private(set) var entries: [DevelopmentLUTLibrary.Entry] = []
    func refresh() async throws { entries = try await DevelopmentLUTLibrary.shared.entries() }
}

/// The same picker and amount editor operate on a global stack or a single, source-bound mask.
struct PhotosGradingLUTControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    var maskID: UUID?
    @ObservedObject private var library = PhotosLUTLibraryModel.shared
    @State private var errorText: String?
    @State private var importing = false

    private var stack: DevelopmentLUTStack {
        if let maskID {
            let value = session.parameters.masks.first { $0.id == maskID }?.adjustments.gradingLUT
            return .init(layers: value.map { [$0] } ?? [])
        }
        return session.parameters.gradingLUTs ?? .init()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if maskID != nil {
                Text("应用 LUT").font(.system(size: 12, weight: .semibold))
            }
            ForEach(stack.layers) { layer in
                VStack(spacing: 5) {
                    HStack {
                        if maskID == nil, stack.layers.count > 1 {
                            Image(systemName: "line.3.horizontal").draggable(layer.id.uuidString)
                                .accessibilityLabel("拖动以调整 LUT 顺序")
                        }
                        choices(label: layer.cube.name) { cube in
                            change("替换") { value in
                                guard let index = value.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                                value.layers[index].cube = cube
                            }
                        }
                        Spacer()
                        if maskID == nil, stack.layers.count > 1 {
                            Button { move(layer.id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(stack.layers.first?.id == layer.id).accessibilityLabel("上移 LUT")
                            Button { move(layer.id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(stack.layers.last?.id == layer.id).accessibilityLabel("下移 LUT")
                        }
                        Button { change("移除") { $0.layers.removeAll { $0.id == layer.id } } } label: {
                            Image(systemName: "xmark")
                        }.accessibilityLabel("移除 LUT")
                    }.buttonStyle(.borderless)
                    PhotosRecipeValueRow(session: session, context: context, title: "LUT 强度",
                        control: "grading.lut." + layer.id.uuidString + ".amount", value: layer.amount, range: 0...100,
                        step: 1, digits: 1, apply: { amount, token in
                            try apply("强度", token: token) { value in
                                guard let i = value.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                                value.layers[i].amount = amount
                            }
                        }, onError: { errorText = $0.localizedDescription })
                }
                .dropDestination(for: String.self) { items, _ in
                    guard maskID == nil, let raw = items.first, let id = UUID(uuidString: raw),
                          let source = stack.layers.firstIndex(where: { $0.id == id }),
                          let target = stack.layers.firstIndex(where: { $0.id == layer.id }), source != target else { return false }
                    move(id, by: target - source)
                    return true
                }
            }
            if stack.layers.count < (maskID == nil ? DevelopmentLUTStack.maximumLayers : 1) {
                choices(label: stack.layers.isEmpty ? "选择 LUT…" : "添加另一个 LUT…") { cube in
                    change("添加") { $0.layers.append(.init(cube: cube)) }
                }.accessibilityIdentifier(maskID == nil ? "photos.grading.lut.add" : "photos.mask.lut.add")
            }
            if importing { ProgressView("正在导入 LUT…").controlSize(.small) }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(AppPalette.warning) }
        }
        .task {
            do { try await library.refresh() }
            catch { errorText = error.localizedDescription }
        }
    }

    private func choices(label: String, select: @escaping (DevelopmentColorLUT) -> Void) -> some View {
        Menu(label) {
            Section("颜色 LUT") { Button(DevelopmentColorLUT.warm.name) { select(.warm) } }
            Section("黑白 LUT") { Button(DevelopmentColorLUT.monochrome.name) { select(.monochrome) } }
            if !library.entries.isEmpty {
                Section("已导入") {
                    ForEach(library.entries) { entry in
                        Button(entry.name) {
                            Task { @MainActor in
                                do { select(try await DevelopmentLUTLibrary.shared.load(entry)) }
                                catch { errorText = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("导入 CUBE 或 ZIP…") { importFile() }.disabled(importing)
        }
        .menuStyle(.borderlessButton)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText, .zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            importing = true
            Task { @MainActor in
                defer { importing = false }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let telemetry = ImagePerformanceTelemetry.shared
                let ticket = telemetry.begin(operation: "DevelopmentLUTLibrary.importFile", stage: url.pathExtension.uppercased(),
                                             queue: "LUT 素材入库", boundary: .apiReturn)
                var outcome = ImagePerformanceOutcome.failed
                defer { telemetry.end(ticket, outcome: outcome) }
                do {
                    _ = try await DevelopmentLUTLibrary.shared.importFile(url)
                    outcome = .succeeded
                    try await library.refresh()
                    errorText = nil
                } catch { errorText = error.localizedDescription }
            }
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        change("排序") { value in
            guard let i = value.layers.firstIndex(where: { $0.id == id }), value.layers.indices.contains(i + offset) else { return }
            let layer = value.layers.remove(at: i)
            value.layers.insert(layer, at: i + offset)
        }
    }
    private func change(_ title: String, mutation: (inout DevelopmentLUTStack) -> Void) {
        do { try apply(title, token: nil, mutation: mutation) }
        catch { errorText = error.localizedDescription }
    }
    private func apply(_ title: String, token: EditingGestureToken?, mutation: (inout DevelopmentLUTStack) -> Void) throws {
        var next = stack
        mutation(&next)
        try next.validate()
        let command: DevelopmentAdjustmentCommand
        if let maskID {
            var masks = session.parameters.masks
            guard next.layers.count <= 1, let index = masks.firstIndex(where: { $0.id == maskID }) else { throw EditingError.invalidRecipe }
            masks[index].adjustments.gradingLUT = next.layers.first
            command = .setMasks(masks)
        } else {
            command = .setGradingLUTs(next.layers.isEmpty ? nil : next)
        }
        let control = maskID == nil ? "grading.lut" : "mask.grading.lut"
        try session.apply(command, event: .init(context: context, control: .init(group: nil, name: "LUT · " + title),
            nativeInput: .capture(control: control, phase: token == nil ? "discrete" : "change",
                                  nativeEvent: true, gestureID: token?.id)), gesture: token)
        errorText = nil
    }
}
