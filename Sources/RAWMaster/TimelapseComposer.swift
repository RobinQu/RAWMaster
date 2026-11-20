import AppKit
import AVFoundation
import Combine
import Foundation
import RAWMasterCore
import RAWMasterImaging

/// One immutable group snapshot and one independently cancellable render at a time.
@MainActor
final class TimelapseComposer: ObservableObject {
    typealias Render = @Sendable (TimelapseInput, TimelapseSettings, URL, Bool,
        @escaping @Sendable (TimelapseProgress) -> Void) async throws -> TimelapseRenderResult

    let input: TimelapseInput
    @Published var settings = TimelapseSettings() {
        didSet {
            guard settings != oldValue else { return }
            invalidatePreview()
        }
    }
    @Published var advanced = false
    @Published var advancedTab: AdvancedTab = .light
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progress: TimelapseProgress?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var firstImage: NSImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var exportedURL: URL?
    @Published private(set) var previewURL: URL?
    @Published private(set) var previewNeedsUpdate = true
    @Published private(set) var isSelectingRegion = false

    enum AdvancedTab: String, CaseIterable {
        case light, alignment, keyframes, export
        var title: String {
            switch self { case .light: return "光照"; case .alignment: return "对齐"; case .keyframes: return "关键帧"; case .export: return "导出" }
        }
    }

    private let render: Render
    private let temporaryDirectory: URL
    private let runningChanged: @MainActor (Bool) -> Void
    private var task: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var generation = UUID()
    private var isClosed = false

    init(input: TimelapseInput, temporaryDirectory: URL? = nil,
         render: @escaping Render = { input, settings, destination, preview, progress in
             try await TimelapseRenderer.render(input: input, settings: settings,
                destination: destination, preview: preview, progress: progress)
         }, runningChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.input = input; self.render = render; self.runningChanged = runningChanged
        self.temporaryDirectory = temporaryDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RAWMaster-Timelapse-" + UUID().uuidString, isDirectory: true)
    }

    var duration: Double { settings.duration(inputCount: input.assets.count) }
    var outputCount: Int { settings.outputFrameIndices(inputCount: input.assets.count).count }
    var validationMessage: String? {
        do { try settings.validate(inputCount: input.assets.count); return nil }
        catch { return error.localizedDescription }
    }
    var canRender: Bool { !isRunning && !isClosed && validationMessage == nil }

    func loadFirstImage() {
        guard imageTask == nil, firstImage == nil, let asset = input.assets.first, !isClosed else { return }
        imageTask = Task { [weak self] in
            do {
                // Use the renderer's developed, oriented source geometry. A camera's
                // embedded RAW JPEG can have a different crop and cannot define this ROI.
                let bitmap = try await TimelapseRenderer.referenceImage(for: asset, maxPixel: 1400)
                let image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
                try Task.checkCancellation()
                guard let self, !self.isClosed else { return }
                self.firstImage = image
            } catch {
                guard let self, !self.isClosed, !Task.isCancelled else { return }
                self.errorMessage = "首帧预览不可用：" + error.localizedDescription
                self.imageTask = nil
            }
        }
    }

    func generatePreview() {
        guard canRender else { return }
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let output = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            start(destination: output, preview: true)
        } catch { errorMessage = "无法准备预览：" + error.localizedDescription }
    }

    func export(to destination: URL) {
        guard canRender else { return }
        start(destination: destination, preview: false)
    }

    private func start(destination: URL, preview: Bool) {
        let request = UUID(), recipe = settings
        generation = request
        errorMessage = nil; warnings = []; progress = nil; isCancelling = false
        isRunning = true; runningChanged(true)
        player?.pause()
        let render = self.render, input = self.input
        task = Task { [weak self] in
            do {
                let result = try await render(input, recipe, destination, preview, { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.generation == request, self.isRunning, !self.isClosed else { return }
                        self.progress = value
                    }
                })
                guard let self else { return }
                // Publication is the engine's commit boundary. A cancellation
                // arriving after it cannot undo a completed user export.
                if !preview, !self.isClosed { self.exportedURL = result.outputURL }
                guard !Task.isCancelled, !self.isClosed, self.generation == request else {
                    // Only a preview is controller-owned. A completed user export is never deleted.
                    if preview { try? FileManager.default.removeItem(at: result.outputURL) }
                    self.finish(request)
                    return
                }
                self.warnings = result.warnings
                if preview {
                    self.removePreview()
                    self.previewURL = result.outputURL
                    self.player = AVPlayer(url: result.outputURL)
                    self.previewNeedsUpdate = false
                }
                self.finish(request)
            } catch {
                guard let self else { return }
                if self.generation == request, !Task.isCancelled, !self.isClosed {
                    self.errorMessage = "合成未完成：" + error.localizedDescription
                }
                self.finish(request)
            }
        }
    }

    private func finish(_ request: UUID) {
        // Invalidated work still owns the busy flag until its engine has joined.
        guard task != nil else { return }
        task = nil; isRunning = false; isCancelling = false; progress = nil
        runningChanged(false)
    }

    func cancel() {
        guard isRunning else { return }
        generation = UUID(); isCancelling = true; task?.cancel()
    }

    private func invalidatePreview() {
        generation = UUID()
        if isRunning { isCancelling = true; task?.cancel() }
        errorMessage = nil; warnings = []; exportedURL = nil
        previewNeedsUpdate = true
        removePreview()
    }

    private func removePreview() {
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        previewURL = nil
    }

    func chooseSubjectRegion() {
        guard !isRunning else { return }
        player?.pause(); isSelectingRegion = true; loadFirstImage()
    }
    func setSubjectRegion(_ region: TimelapseRegion) {
        guard region.isValid, !isRunning else { return }
        settings.subjectRegion = region
        isSelectingRegion = false
    }
    func stopChoosingRegion() { isSelectingRegion = false }

    func addKeyframe(at position: Double) {
        guard !isRunning, settings.keyframes.count < 32 else { return }
        let clamped = max(0, min(1, position))
        let frame = Int((clamped * Double(max(1, input.assets.count - 1))).rounded())
        let normalized = Double(frame) / Double(max(1, input.assets.count - 1))
        guard !settings.keyframes.contains(where: { abs($0.position - normalized) < 0.000001 }) else { return }
        let ev = settings.exposure(at: normalized)
        settings.keyframes.append(TimelapseKeyframe(position: normalized, exposureEV: ev))
        settings.keyframes.sort { $0.position < $1.position }
    }

    func shutdown() async {
        isClosed = true; generation = UUID()
        imageTask?.cancel(); imageTask = nil
        if let pending = task { isCancelling = true; pending.cancel(); await pending.value }
        removePreview()
        // Folder has a unique operation UUID and contains only our preview files.
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

extension AppModel {
    func isTimelapseGroup(_ group: CaptureGroup) -> Bool {
        SequenceCatalogType.classify(group.kind) == .timelapse
    }

    func canComposeTimelapse(groupID: String? = nil) -> Bool {
        guard !isBusy, !externalEditorPreparing, !hasBusinessSheet, !isTriageScope, !isHistoryScope,
              let group = groupID.flatMap({ id in groups.first { $0.id == id } }) ?? activeGroup,
              isTimelapseGroup(group), group.includedAssetIDs.count >= 2 else { return false }
        let admitted = Set(admissions.filter { $0.projectID == group.projectID }.map(\.assetID))
        return group.assetIDs.contains { admitted.contains($0) }
    }

    func makeTimelapseInput(groupID: String) throws -> TimelapseInput {
        guard let group = groups.first(where: { $0.id == groupID }), isTimelapseGroup(group) else {
            throw LibraryError.invalid("请先选择项目中的延时或间隔拍摄组。")
        }
        let admitted = Set(admissions.filter { $0.projectID == group.projectID }.map(\.assetID))
        return try TimelapseInput.make(group: group, eligibleAssets: assets.filter { admitted.contains($0.id) }, pairs: capturePairs)
    }

    func openTimelapse(groupID: String? = nil) {
        guard canComposeTimelapse(groupID: groupID), let id = groupID ?? activeGroup?.id else { return }
        do {
            let input = try makeTimelapseInput(groupID: id)
            closeSearchControls()
            timelapseComposer = TimelapseComposer(input: input, runningChanged: { [weak self] running in
                self?.timelapseIsRunning = running
            })
            errorMessage = nil; showTimelapse = true
        } catch { errorMessage = error.localizedDescription }
    }

    func closeTimelapse() async {
        await timelapseComposer?.shutdown()
        showTimelapse = false; timelapseComposer = nil
    }
}
