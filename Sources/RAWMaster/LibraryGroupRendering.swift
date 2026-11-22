import AVFoundation
import Darwin
import Foundation
import RAWMasterCore
import RAWMasterImaging
import RAWMasterLibrary

@MainActor
enum LibraryGroupRendering {
    static func render(_ request: GroupRenderRequest) async throws -> GroupRenderReceipt {
        if request.operation == "timelapse" { return try await video(request) }
        return try await GroupPixelRenderer.render(request)
    }

    private static func video(_ request: GroupRenderRequest, expected: TimelapseInput? = nil,
                              progress: @escaping @Sendable (TimelapseProgress) -> Void = { _ in }) async throws -> GroupRenderReceipt {
        let frames = try request.frames.map { frame -> AssetRecord in
            var a = try frame.asset.decoded(AssetRecord.self)
            guard a.id == frame.assetID, a.contentHash == frame.sha256, a.fileSize == frame.byteCount else {
                throw LibraryEngineError("冻结输入与原件版本不符")
            }
            a.currentPath = frame.path
            a.effectiveManagedPath = frame.path
            return a
        }
        guard let project = frames.first?.projectID else { throw LibraryEngineError("分组没有可制作的帧") }
        if let expected, expected.groupID != request.groupID ||
            expected.assets.map(\.id) != frames.map(\.id) || expected.assets.map(\.contentHash) != frames.map(\.contentHash) {
            throw LibraryEngineError("分组输入已变化，请重新打开分组制作")
        }
        let group = CaptureGroup(id: request.groupID, projectID: project, name: expected?.groupName ?? "分组延时",
                                 kind: "延时", assetIDs: frames.map(\.id), includedAssetIDs: frames.map(\.id),
                                 groupRevision: request.revision)
        let input = try TimelapseInput.make(group: group, eligibleAssets: frames)
        var settings = TimelapseSettings()
        if let full = request.recipe["settings"] { settings = try full.decoded(TimelapseSettings.self) }
        else if let fps = request.recipe["frameRate"] { settings.frameRate = try fps.decoded(Int.self) }
        let movie = try await TimelapseRenderer.render(input:input, settings:settings, destination:request.outputURL, progress:progress)
        let url = request.outputURL
        let measurement = try await Task.detached(priority:.utility) { try await readMovie(url) }.value
        guard measurement.0 == movie.frameCount, measurement.1 == movie.width, measurement.2 == movie.height else {
            throw LibraryEngineError("成片读回的帧数或尺寸与编码结果不符")
        }
        let inputs: [CatalogJSON] = request.frames.map {
            .object(["fileID":.string($0.fileID),"contentID":.string($0.contentID),"sha256":.string($0.sha256)])
        }
        return GroupRenderReceipt(mediaKind:"derivedVideo",format:"mp4",width:movie.width,height:movie.height,frameCount:movie.frameCount,
            engineVersion:"rawmaster-timelapse-v1",facts:.object(["inputs":.array(inputs),
                "usedFrameIndices":.array(settings.outputFrameIndices(inputCount:frames.count).map { .integer(Int64($0)) }),
                "durationSeconds":.number(movie.duration),"cropFraction":.number(movie.cropFraction),
                "warnings":.array(movie.warnings.map(CatalogJSON.string))]))
    }

    nonisolated private static func readMovie(_ url: URL) async throws -> (Int,Int,Int) {
        let asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw LibraryEngineError("母版缺少视频轨道") }
        let size = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LibraryEngineError("不能读取母版帧") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? LibraryEngineError("不能读取母版") }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            frames += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed else { throw reader.error ?? LibraryEngineError("母版读回中断") }
        return (frames,Int(size.width.rounded()),Int(size.height.rounded()))
    }

    static func export(actions: CatalogActions, input: TimelapseInput, settings: TimelapseSettings, destination: URL,
                       progress: @escaping @Sendable (TimelapseProgress) -> Void) async throws -> TimelapseRenderResult {
        guard destination.pathExtension.lowercased() == "mp4", !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryEngineError("请选择尚不存在的 MP4 文件")
        }
        let recipe = try JSONDecoder().decode(CatalogJSON.self,from:JSONEncoder().encode(settings))
        var receipt: GroupRenderReceipt?
        let result = try await GroupProcessingRunner.render(actions:actions,groupID:input.groupID,operation:"timelapse",
            recipe:.object(["settings":recipe])) { request in
                let media = try await video(request,expected:input,progress:progress)
                receipt = media
                return media
        }
        guard let receipt else { throw LibraryEngineError("缺少成片校验结果") }
        do {
            try await Task.detached(priority:.utility) {
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".rawmaster-export-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:temporary) }
                try FileManager.default.copyItem(at:result.outputURL,to:temporary)
                guard renamex_np(temporary.path,destination.path,UInt32(RENAME_EXCL)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
                }
            }.value
        } catch { throw LibraryEngineError("成片已入库。外部副本写入失败：" + error.localizedDescription) }
        return TimelapseRenderResult(outputURL:destination,frameCount:receipt.frameCount,width:receipt.width,height:receipt.height,
            duration:Double(receipt.frameCount)/Double(settings.frameRate),
            warnings:(try? receipt.facts["warnings"]?.decoded([String].self)) ?? [],
            cropFraction:(try? receipt.facts["cropFraction"]?.decoded(Double.self)) ?? 0)
    }
}
