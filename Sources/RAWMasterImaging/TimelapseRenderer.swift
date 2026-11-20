import AVFoundation
import CoreImage
import Darwin
import Foundation
import ImageIO
import RAWMasterCore

public enum TimelapseRenderer {
    private struct Stamp: Equatable {
        let size: Int64, seconds: Int, nanoseconds: Int
        let inode: UInt64, device: Int32
        let resolvedPath: String
        static func read(_ url: URL) throws -> Stamp {
            var info = stat()
            guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG else { throw LibraryError.invalid("无法读取序列原片：\(url.lastPathComponent)") }
            return Stamp(size: info.st_size, seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec,
                         inode: info.st_ino, device: info.st_dev, resolvedPath: url.resolvingSymlinksInPath().path)
        }
    }
    private struct Analysis {
        var stamps: [Stamp], exposure: [Double], translations: [SIMD2<Double>]
        var crop: Double, warnings: [String], aspect: Double
    }

    private struct DirectoryStamp: Equatable {
        let device: Int32, inode: UInt64
        static func read(_ url: URL) throws -> DirectoryStamp {
            var info = stat()
            guard url.path.withCString({ fstatat(AT_FDCWD,$0,&info,0) }) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else { throw LibraryError.invalid("目标目录不可用。") }
            return DirectoryStamp(device:info.st_dev,inode:info.st_ino)
        }
    }
    private struct DestinationPin {
        let originalParent: URL, canonicalParent: URL, destination: URL
        let identity: DirectoryStamp
        init(_ url: URL) throws {
            originalParent = url.deletingLastPathComponent().standardizedFileURL
            canonicalParent = originalParent.resolvingSymlinksInPath().standardizedFileURL
            identity = try DirectoryStamp.read(canonicalParent)
            destination = canonicalParent.appendingPathComponent(url.lastPathComponent)
        }
        func validate() throws {
            guard originalParent.resolvingSymlinksInPath().standardizedFileURL.path == canonicalParent.path,
                  try DirectoryStamp.read(originalParent) == identity,
                  try DirectoryStamp.read(canonicalParent) == identity else { throw LibraryError.invalid("目标目录在合成期间发生变化，请重新选择保存位置。") }
        }
    }

    /// The ROI selector uses the same oriented RAW development geometry as the movie engine.
    public static func referenceImage(for asset: AssetRecord, maxPixel: Int = 1400) async throws -> CGImage {
        try Task.checkCancellation()
        let stamp = try Stamp.read(asset.resolvedURL)
        let context = CIContext(options:[.workingColorSpace:TimelapseAnalysis.linearSpace,.cacheIntermediates:false])
        defer { context.clearCaches() }
        let image = try load(asset:asset,maxEdge:max(64,min(2048,maxPixel)))
        guard let result = context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else { throw LibraryError.invalid("无法生成合成参考图。") }
        try check(asset,stamp:stamp);try Task.checkCancellation()
        return result
    }

    public static func render(input: TimelapseInput, settings: TimelapseSettings, destination: URL,
                              preview: Bool = false,
                              progress: @escaping @Sendable (TimelapseProgress) -> Void = { _ in }) async throws -> TimelapseRenderResult {
        try settings.validate(inputCount: input.assets.count)
        try Task.checkCancellation()
        try validateDestination(destination, assets: input.assets)
        let pin = try DestinationPin(destination)
        let outputSpace = CGColorSpace(name: CGColorSpace.itur_709)!
        let context = CIContext(options: [.workingColorSpace: TimelapseAnalysis.linearSpace,
                                          .outputColorSpace: outputSpace, .cacheIntermediates: false])
        defer { context.clearCaches() }
        let analysis = try analyze(input: input, settings: settings, context: context, progress: progress)
        try pin.validate()
        let indices = settings.outputFrameIndices(inputCount: input.assets.count)
        let dimensions = settings.dimensions(preview: preview)
        let temporaryDirectory = pin.canonicalParent.appendingPathComponent(".rawmaster-timelapse-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let temporaryIdentity = try DirectoryStamp.read(temporaryDirectory)
        defer {
            if (try? DirectoryStamp.read(temporaryDirectory)) == temporaryIdentity { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
        let temporary = temporaryDirectory.appendingPathComponent("video.mp4")
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        var finished = false
        defer { if !finished, writer.status == .writing { writer.cancelWriting() } }
        let codec: AVVideoCodecType = settings.codec == .h264 ? .h264 : .hevc
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec, AVVideoWidthKey: dimensions.width, AVVideoHeightKey: dimensions.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, dimensions.width*dimensions.height*6),
                AVVideoExpectedSourceFrameRateKey: settings.frameRate, AVVideoMaxKeyFrameIntervalKey: settings.frameRate*2]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw LibraryError.invalid("当前系统无法使用所选视频编码，请改用 H.264 / 1080p。") }
        let track = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        track.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: dimensions.width, kCVPixelBufferHeightKey as String: dimensions.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(track) else { throw LibraryError.invalid("无法创建视频编码轨道。") }
        writer.add(track)
        guard writer.startWriting() else { throw writer.error ?? LibraryError.invalid("无法开始视频编码。") }
        writer.startSession(atSourceTime: .zero)
        let desiredAspect = Double(dimensions.width) / Double(dimensions.height)
        let aspectPenalty = max(analysis.aspect / desiredAspect, desiredAspect / analysis.aspect)
        let decodeEdge = Int(ceil(Double(max(dimensions.width, dimensions.height)) * aspectPenalty / max(0.5, 1 - 2*analysis.crop)))
        for (ordinal, index) in indices.enumerated() {
            try Task.checkCancellation()
            try check(input.assets[index], stamp: analysis.stamps[index])
            while !track.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? LibraryError.invalid("视频编码中断。") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try autoreleasepool {
                let asset = input.assets[index]
                var image = try load(asset: asset, maxEdge: decodeEdge)
                let extent = image.extent
                let translation = analysis.translations[index]
                image = image.transformed(by: CGAffineTransform(translationX: translation.x * extent.width, y: translation.y * extent.height))
                let safe = extent.insetBy(dx: analysis.crop * extent.width, dy: analysis.crop * extent.height)
                var crop = safe
                if safe.width/safe.height > desiredAspect { crop.size.width = safe.height*desiredAspect; crop.origin.x += (safe.width-crop.width)/2 }
                else { crop.size.height = safe.width/desiredAspect; crop.origin.y += (safe.height-crop.height)/2 }
                image = TimelapseAnalysis.normalized(image.cropped(to: crop))
                image = image.transformed(by: CGAffineTransform(scaleX: Double(dimensions.width)/crop.width, y: Double(dimensions.height)/crop.height))
                let position = Double(index) / Double(max(1,input.assets.count-1))
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: analysis.exposure[index] + settings.exposure(at: position)])
                guard let pool = adaptor.pixelBufferPool else { throw LibraryError.invalid("无法分配视频帧缓存。") }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw LibraryError.invalid("视频帧缓存不足。") }
                context.render(image, to: buffer, bounds: CGRect(x:0,y:0,width:dimensions.width,height:dimensions.height), colorSpace: outputSpace)
                try Task.checkCancellation()
                try check(asset, stamp: analysis.stamps[index])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(ordinal), timescale: CMTimeScale(settings.frameRate))) else { throw writer.error ?? LibraryError.invalid("写入视频帧失败。") }
            }
            progress(TimelapseProgress(phase: .rendering, completed: ordinal+1, total: indices.count))
        }
        try Task.checkCancellation()
        track.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(indices.count), timescale: CMTimeScale(settings.frameRate)))
        progress(TimelapseProgress(phase: .finishing, completed: 0, total: 1))
        try await finish(writer)
        finished = true
        // Recheck even stride-skipped inputs; a complete immutable input must remain valid through both passes.
        for index in input.assets.indices { try Task.checkCancellation(); try check(input.assets[index], stamp: analysis.stamps[index]) }
        try Task.checkCancellation()
        try pin.validate()
        try validateDestination(pin.destination, assets: input.assets)
        // Atomic no-clobber commit. Cancellation after this point must not remove a completed user output.
        try publish(temporary, destination:pin.destination)
        progress(TimelapseProgress(phase: .finishing, completed: 1, total: 1))
        return TimelapseRenderResult(outputURL: pin.destination, frameCount: indices.count,
            width: dimensions.width, height: dimensions.height, duration: Double(indices.count)/Double(settings.frameRate),
            warnings: analysis.warnings, cropFraction: analysis.crop)
    }

    private static func analyze(input: TimelapseInput, settings: TimelapseSettings, context: CIContext,
                                progress: @escaping @Sendable (TimelapseProgress) -> Void) throws -> Analysis {
        var stamps: [Stamp] = []
        for asset in input.assets { try Task.checkCancellation(); stamps.append(try Stamp.read(asset.resolvedURL)) }
        var reference: CGImage?, logLuminances: [Double] = [], offsets: [SIMD2<Double>] = []
        var aspect = 0.0, alignmentFailed = false
        let referenceRegion = settings.alignment == .subject ? settings.subjectRegion : nil
        for (index,asset) in input.assets.enumerated() {
            try Task.checkCancellation(); try check(asset, stamp: stamps[index])
            try autoreleasepool {
                let image = try load(asset: asset, maxEdge: 640)
                let currentAspect = image.extent.width/image.extent.height
                if index == 0 { aspect = currentAspect }
                guard abs(currentAspect/aspect-1) < 0.005 else { throw LibraryError.invalid("序列画幅不一致：\(asset.filename)。请先拆分不同方向或画幅的照片。") }
                guard let cg = context.createCGImage(image, from: image.extent) else { throw LibraryError.invalid("序列图像解码失败：\(asset.filename)") }
                var offset: SIMD2<Double> = .zero
                if settings.alignment != .off, let reference {
                    if let result = try TimelapseAnalysis.translation(reference: reference, current: cg, region: referenceRegion, context: context) { offset = result }
                    else { alignmentFailed = true }
                }
                if index == 0 { reference = cg }
                offsets.append(offset)
                let meteringImage = image.transformed(by: CGAffineTransform(translationX: offset.x * image.extent.width, y: offset.y * image.extent.height))
                let meteringRegion = referenceRegion ?? TimelapseRegion(x:0.15,y:0.15,width:0.7,height:0.7)
                let area = TimelapseAnalysis.rectangle(meteringRegion, in:image.extent).intersection(meteringImage.extent)
                guard !area.isEmpty else { throw LibraryError.invalid("光照参考区域已移出画面：\(asset.filename)") }
                logLuminances.append(TimelapseAnalysis.logLuminance(meteringImage, context:context, region:area))
                try check(asset, stamp: stamps[index])
            }
            progress(TimelapseProgress(phase:.analyzing,completed:index+1,total:input.assets.count))
        }
        var warnings: [String] = []
        var correction = TimelapseAnalysis.corrections(offsets:offsets,settings:settings)
        if alignmentFailed || correction.fallback {
            correction = (Array(repeating:.zero,count:offsets.count),0,false)
            warnings.append(alignmentFailed ? "部分画面缺乏可靠纹理或无法平移配准，本片已整体关闭画面稳定，保留原始运动。" : "所需裁切超出设定上限，本片已整体关闭画面稳定；可提高最大裁切后重新预览。")
        }
        return Analysis(stamps:stamps,exposure:TimelapseAnalysis.exposureCorrections(logLuminances:logLuminances,strength:settings.deflickerStrength,radius:settings.smoothingRadius),
                        translations:correction.values,crop:correction.crop,warnings:warnings,aspect:aspect)
    }

    static func load(asset: AssetRecord, maxEdge: Int) throws -> CIImage {
        let url = asset.resolvedURL
        let image: CIImage
        if CaptureFileFormat.isRAW(asset.filename) {
            guard let raw = CIRAWFilter(imageURL:url) else { throw LibraryError.invalid("无法解码 RAW：\(asset.filename)") }
            raw.scaleFactor = Float(min(1,Double(maxEdge)/max(raw.nativeSize.width,raw.nativeSize.height)))
            raw.isDraftModeEnabled = false
            guard let output = raw.outputImage else { throw LibraryError.invalid("RAW 渲染失败：\(asset.filename)") }
            image = output
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                    kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maxEdge,
                    kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw LibraryError.invalid("图像解码失败：\(asset.filename)") }
            image = CIImage(cgImage:cg)
        }
        guard !image.extent.isEmpty, !image.extent.isInfinite, image.extent.width.isFinite, image.extent.height.isFinite else { throw LibraryError.invalid("图像尺寸无效：\(asset.filename)") }
        return TimelapseAnalysis.normalized(image)
    }

    private static func check(_ asset: AssetRecord, stamp: Stamp) throws {
        guard try Stamp.read(asset.resolvedURL) == stamp else { throw LibraryError.sourceChanged(asset.filename) }
    }
    private static func validateDestination(_ destination: URL, assets: [AssetRecord]) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "mp4" else { throw LibraryError.invalid("请选择本地 MP4 文件位置。") }
        var info = stat()
        if destination.path.withCString({ lstat($0,&info) }) == 0 { throw LibraryError.invalid("目标文件已存在，请选择新的文件名。") }
        guard errno == ENOENT else { throw LibraryError.invalid("无法访问目标位置。") }
        let canonical = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).standardizedFileURL.path
        for asset in assets {
            if [asset.resolvedURL,asset.resolvedSourceURL].contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == canonical }) { throw LibraryError.invalid("目标不能指向原片。") }
        }
    }

    private static func publish(_ temporary: URL, destination: URL) throws {
        let outcome = temporary.path.withCString { from in
            destination.path.withCString { to in renamex_np(from,to,UInt32(RENAME_EXCL)) }
        }
        if outcome == 0 { return }
        var failure = errno
        // Some filesystems do not implement exclusive rename. Atomic hardlink is a safe fallback;
        // a plain rename would overwrite a destination created concurrently and is never used.
        if failure == ENOTSUP {
            let linked = temporary.path.withCString { from in destination.path.withCString { to in Darwin.link(from,to) } }
            if linked == 0 { return }
            failure = errno
        }
        throw LibraryError.invalid(failure == EEXIST ? "目标文件已存在，请选择新的文件名。" : "无法安全保存成片：\(String(cString:strerror(failure)))。请尝试其他保存位置。")
    }

    /// Once native finalization starts, join its callback before observing cancellation.
    /// Calling cancelWriting during finishWriting can suppress the native callback on some systems.
    /// The internal hook lets the regression test cancel precisely after native finalization starts.
    static func finish(_ writer: AVAssetWriter, started: () -> Void = {}) async throws {
        try Task.checkCancellation()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            writer.finishWriting { continuation.resume() }
            started()
        }
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? LibraryError.invalid("视频编码未完成。") }
    }
}
