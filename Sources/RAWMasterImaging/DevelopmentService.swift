import AppKit
import CoreImage
import CryptoKit
import ImageIO
import RAWMasterCore
import Darwin
import UniformTypeIdentifiers

public typealias RenderPublicationPreparation = @Sendable (_ stagedURL: URL, _ targetURL: URL, _ artifact: RenderArtifact) throws -> Void

public enum PhotoRenderFormat: String, CaseIterable, Sendable { case png16, jpeg8, tiff16
  public var filenameExtension: String { self == .jpeg8 ? "jpg" : (self == .tiff16 ? "tiff" : "png") }
}
public struct DevelopmentPreview: @unchecked Sendable {
  public let image: NSImage
  public let pixelWidth: Int
  public let pixelHeight: Int
}
public struct RenderedPhoto: Sendable {
  public let fileURL: URL
  public let artifact: RenderArtifact
  public init(fileURL: URL, artifact: RenderArtifact) { self.fileURL = fileURL; self.artifact = artifact }
}
public enum DevelopmentError: LocalizedError {
  case unreadable, unsupportedEngine, invalidGeometry, outputExists, protectedDestination, invalidEncoding
  public var errorDescription: String? {
    switch self {
    case .unreadable: return "无法解码图像"
    case .unsupportedEngine: return "当前设备或版本不支持此显影配方的颜色引擎"
    case .invalidGeometry: return "裁切后没有可用像素"
    case .outputExists: return "目标文件已存在，请选择另一个名称"
    case .protectedDestination: return "成片不能写入原片或作品档案目录"
    case .invalidEncoding: return "输出位深、色彩或编码校验失败"
    }
  }
}

/// Full RAW decoding and one canonical pixel transform for previews, provider inputs and exports.
public actor DevelopmentService {
  private let qaBrilliancePublicV1:Bool
  public init() {qaBrilliancePublicV1=DevelopmentBrilliancePublicV1.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)}
  init(qaBrilliancePublicV1:Bool){self.qaBrilliancePublicV1=qaBrilliancePublicV1}
  public func preview(source: EditingSourceSnapshot, recipe: DevelopmentRecipe, maxPixel: Int = 1600) async throws -> DevelopmentPreview {
    if let scene = recipe.adjustmentsV3?.effects?.lensBlur?.sceneDepth, scene.sourceSHA256 != source.contentSHA256 {
      throw EditingError.staleSource
    }
    guard !DevelopmentBrilliancePublicV1.active(recipe) else{throw PreviewPresentationError.unsupported}
    return try await renderingTask {
      try RenderFiles.verify(source)
      let captured = try RenderFiles.capture(source); defer { try? FileManager.default.removeItem(at: captured.deletingLastPathComponent()) }
      let adaptive=recipe.adjustmentsV3.map{DevelopmentBrillianceAdaptiveV1.isActive($0.light)} ?? false
      let ownedContext=adaptive ? DevelopmentBrillianceAdaptiveV1.makeContext():nil
      defer{ownedContext?.clearCaches()}
      let image:CIImage
      if recipe.adjustmentsV3?.superResolution != nil {
        let graph=try DevelopmentRendererV3.develop(captured,recipe:recipe,context:ownedContext ?? DevelopmentColorEngineV3.context)
        let edge=max(graph.canonicalSize.width,graph.canonicalSize.height)
        let limit=maxPixel <= 0 ? edge:CGFloat(max(64,min(4096,maxPixel)))
        image=graph.displayImage(scale:min(1,limit/edge))
      } else {
        let (developed, _) = try PhotoRenderer.develop(captured, recipe, context:ownedContext)
        let edge=max(developed.extent.width,developed.extent.height)
        let limit=maxPixel <= 0 ? edge:CGFloat(max(64,min(4096,maxPixel)))
        let factor=min(1,limit/edge)
        image=factor < 1 ? developed.transformed(by:.init(scaleX:factor,y:factor)):developed
      }
      guard let cg = (ownedContext ?? PhotoRenderer.renderingContext(recipe)).createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: PhotoRenderer.sRGB, deferred:false) else { throw DevelopmentError.unreadable }
      try RenderFiles.verify(source)
      let bitmap = NSBitmapImageRep(cgImage: cg)
      let preview = NSImage(size: NSSize(width: cg.width, height: cg.height)); preview.addRepresentation(bitmap)
      return DevelopmentPreview(image: preview, pixelWidth: cg.width, pixelHeight: cg.height)
    }
  }
  public func render(source: EditingSourceSnapshot, recipe: DevelopmentRecipe, format: PhotoRenderFormat, destination: URL, protectedURLs: [URL] = [], preparePublication: RenderPublicationPreparation? = nil) async throws -> RenderedPhoto {
    if let scene = recipe.adjustmentsV3?.effects?.lensBlur?.sceneDepth, scene.sourceSHA256 != source.contentSHA256 {
      throw EditingError.staleSource
    }
    let newBrilliance=DevelopmentBrilliancePublicV1.active(recipe)
    guard !newBrilliance || (qaBrilliancePublicV1 && format == .tiff16) else{throw PreviewPresentationError.unsupported}
    return try await renderingTask {
      try RenderFiles.verify(source)
      let captured = try RenderFiles.capture(source); defer { try? FileManager.default.removeItem(at: captured.deletingLastPathComponent()) }
      let dehazeBanded = format == .tiff16 && DevelopmentDehazeNativeRfV1.isActive(recipe.adjustmentsV3?.advancedDetail)
      let banded=dehazeBanded || newBrilliance
      // One owner across the actual native graph's finite checks and its joined TIFF tasks.
      let brillianceScope=newBrilliance ? PreviewPresentationScope():nil
      defer{brillianceScope?.closeAndRetire()}
      let adaptive=recipe.adjustmentsV3.map{DevelopmentBrillianceAdaptiveV1.isActive($0.light)} ?? false
      let ownedContext = newBrilliance ? DevelopmentBrilliancePublicV1.makeContext():
        (adaptive ? DevelopmentBrillianceAdaptiveV1.makeContext():(banded ? DevelopmentColorEngineV3.makeContext():nil))
      defer { ownedContext?.clearCaches() }
      let brillianceRequest=brillianceScope.map{DevelopmentBrilliancePublicV1.Request(scope:$0,check:{try Task.checkCancellation()})}
      let legacyCoverage = try DevelopmentLegacyMaskOutput.Coverage(recipe: recipe)
      let (image, depth) = try PhotoRenderer.develop(captured, recipe, context:ownedContext,brillianceQARequest:brillianceRequest,legacyCoverage:legacyCoverage)
      let legacyMask = try DevelopmentLegacyMaskOutput.make(capture: captured, collected: legacyCoverage, extent: image.extent, format: format)
      return try PhotoRenderer.write(image, format: format, destination: destination,
        protectedURLs: protectedURLs + [source.sourceLocation], sourceDepth: depth, preparePublication: preparePublication,
        renderContext: ownedContext ?? PhotoRenderer.renderingContext(recipe),
        tiffTransport:(newBrilliance || ((dehazeBanded || (adaptive && format == .tiff16)) && image.extent == image.extent.integral)) ? .nativeBands256:.whole,
        legacyMask: legacyMask, beforePublish: { try RenderFiles.verify(source) })
    }
  }
  public func inspect(fileURL: URL, sourceEffectiveBitDepth: Int? = nil) async throws -> RenderArtifact {
    try await renderingTask { try PhotoRenderer.inspect(fileURL, sourceDepth: sourceEffectiveBitDepth) }
  }
}

func renderingTask<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
  let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try DevelopmentDehazeNativeResources.run(operation) }
  return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
}

enum RenderFiles {
  static func hash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while true {
      try Task.checkCancellation()
      let count = try autoreleasepool { let data = try handle.read(upToCount: 1024 * 1024) ?? Data(); hash.update(data: data); return data.count }
      if count == 0 { break }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func verify(_ source: EditingSourceSnapshot) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: source.sourceLocation.resolvingSymlinksInPath().path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? NSNumber)?.int64Value == source.byteCount,
      try hash(source.sourceLocation) == source.contentSHA256 else { throw EditingError.staleSource }
  }
  static func capture(_ source: EditingSourceSnapshot) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-render-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("source").appendingPathExtension(source.sourceLocation.pathExtension)
    do {
      let input = try FileHandle(forReadingFrom: source.sourceLocation); defer { try? input.close() }
      FileManager.default.createFile(atPath: destination.path, contents: nil)
      let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
      var digest = SHA256(), count: Int64 = 0
      while true {
        try Task.checkCancellation()
        let length = try autoreleasepool {
          let bytes = try input.read(upToCount: 1024 * 1024) ?? Data()
          digest.update(data: bytes); try output.write(contentsOf: bytes); return bytes.count
        }
        if length == 0 { break }; count += Int64(length)
      }
      try output.synchronize(); try output.close()
      let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
      guard count == source.byteCount, hash == source.contentSHA256 else { throw EditingError.staleSource }
      return destination
    } catch { try? FileManager.default.removeItem(at: directory); throw error }
  }
  static func canonical(_ url: URL) -> URL {
    let u = url.standardizedFileURL
    if FileManager.default.fileExists(atPath: u.path) { return u.resolvingSymlinksInPath() }
    let parent = u.deletingLastPathComponent()
    return parent.path == u.path ? u : canonical(parent).appendingPathComponent(u.lastPathComponent)
  }
  static func check(_ destination: URL, protected: [URL]) throws {
    guard destination.isFileURL else { throw DevelopmentError.protectedDestination }
    let path = canonical(destination).path
    for root in protected {
      let r = canonical(root).path
      if path == r || path.hasPrefix(r + "/") { throw DevelopmentError.protectedDestination }
    }
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw DevelopmentError.outputExists }
  }
}

enum PhotoRenderer {
  static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
  static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
  static let rawExtensions: Set<String> = ["arw", "dng", "raw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq"]
  static func develop(_ url: URL, _ recipe: DevelopmentRecipe, context:CIContext?=nil,brillianceQARequest:DevelopmentBrilliancePublicV1.Request?=nil,analysisResidentInput:DevelopmentBWSummaryResidentV3.Input?=nil,legacyCoverage:DevelopmentLegacyMaskOutput.Coverage?=nil) throws -> (CIImage, Int?) {
    try recipe.validate()
    if let analysisResidentInput {
      guard recipe == DevelopmentRecipe(),rawExtensions.contains(url.pathExtension.lowercased()),
        context == nil,brillianceQARequest == nil else { throw DevelopmentV3Error.unsupportedAnalysis }
      try analysisResidentInput.requireCurrent()
    }
    if recipe.schemaVersion == 3 {
      let graph = try DevelopmentRendererV3.develop(url,recipe:recipe,context:context ?? DevelopmentColorEngineV3.context,
        brillianceQARequest:brillianceQARequest,legacyCoverage:legacyCoverage,checkCancellation:context == nil ? nil:{try Task.checkCancellation()})
      return (graph.image,graph.sourceDepth)
    }
    if recipe.schemaVersion == 2 { return try developV2(url, recipe) }
    guard recipe.engineVersion == "core-image-v1" else { throw DevelopmentError.unsupportedEngine }
    var image: CIImage
    var sourceDepth: Int?
    if let analysisResidentInput {
      image = try analysisResidentInput.image()
    } else if rawExtensions.contains(url.pathExtension.lowercased()) {
      guard let raw = CIRAWFilter(imageURL: url) else { throw DevelopmentError.unreadable }
      raw.scaleFactor = 1; raw.isDraftModeEnabled = false; raw.exposure = Float(recipe.exposureEV)
      if case let .temperatureTint(temperature, tint) = recipe.whiteBalance { raw.neutralTemperature = Float(temperature); raw.neutralTint = Float(tint) }
      guard let output = raw.outputImage else { throw DevelopmentError.unreadable }
      // CIRAWFilter applies EXIF orientation. Do not apply it a second time.
      image = output
    } else {
      guard let output = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
        let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DevelopmentError.unreadable }
      image = output; sourceDepth = cg.bitsPerComponent
      if case let .temperatureTint(temperature, tint) = recipe.whiteBalance {
        image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: temperature, y: tint), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
      }
      if recipe.exposureEV != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: recipe.exposureEV]) }
    }
    guard !image.extent.isEmpty, !image.extent.isInfinite else { throw DevelopmentError.unreadable }
    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    if recipe.straightenDegrees != 0 {
      let w = image.extent.width, h = image.extent.height
      let angle = recipe.straightenDegrees * .pi / 180
      image = image.transformed(by: CGAffineTransform(translationX: -w/2, y: -h/2))
        .transformed(by: CGAffineTransform(rotationAngle: angle))
      let size = inscribedSize(width: w, height: h, angle: abs(angle))
      image = image.cropped(to: CGRect(x: -size.width/2, y: -size.height/2, width: size.width, height: size.height))
      image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    let bounds = image.extent, crop = recipe.crop
    let rect = CGRect(x: bounds.width * crop.x, y: bounds.height * (1 - crop.y - crop.height), width: bounds.width * crop.width, height: bounds.height * crop.height)
    // Round inward so fractional crop/rotation bounds cannot add a transparent border.
    let pixels = CGRect(x: ceil(rect.minX), y: ceil(rect.minY), width: floor(rect.maxX) - ceil(rect.minX), height: floor(rect.maxY) - ceil(rect.minY))
    guard pixels.width >= 1, pixels.height >= 1 else { throw DevelopmentError.invalidGeometry }
    image = image.cropped(to: pixels).transformed(by: CGAffineTransform(translationX: -pixels.minX, y: -pixels.minY))
    return (image, sourceDepth)
  }
  static func inscribedSize(width: Double, height: Double, angle: Double) -> CGSize {
    let s = sin(angle), c = cos(angle), long = max(width, height), short = min(width, height)
    if short <= 2 * s * c * long || abs(c - s) < 1e-10 {
      let x = short / 2
      return width >= height ? CGSize(width: x / max(s, 1e-10), height: x / c) : CGSize(width: x / c, height: x / max(s, 1e-10))
    }
    let cos2 = c*c - s*s
    return CGSize(width: (width*c-height*s)/cos2, height: (height*c-width*s)/cos2)
  }
  static func write(_ original: CIImage, format: PhotoRenderFormat, destination: URL, protectedURLs: [URL], sourceDepth: Int?, preparePublication: RenderPublicationPreparation? = nil, renderContext: CIContext? = nil, tiffTransport:TIFF16Output.Transport = .whole, legacyMask: DevelopmentLegacyMaskOutput? = nil, beforePublish: () throws -> Void = {}) throws -> RenderedPhoto {
    let telemetry = ImagePerformanceTelemetry.shared
    let token = telemetry.begin(operation: "导出图像", stage: format.filenameExtension, queue: "导出")
    var outcome = ImagePerformanceOutcome.failed
    defer { telemetry.end(token, outcome: outcome,
      pixelCount: outcome == .succeeded ? Int(original.extent.width * original.extent.height) : 0) }
    let context = renderContext ?? self.context
    try RenderFiles.check(destination, protected: protectedURLs)
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try RenderFiles.check(destination, protected: protectedURLs)
    let stage = directory.appendingPathComponent(".rawmaster-render-\(UUID().uuidString).\(format.filenameExtension)")
    var preservePreparedStage = false
    defer { if !preservePreparedStage { try? FileManager.default.removeItem(at: stage) } }
    var image = original
    if format == .jpeg8 { image = image.composited(over: CIImage(color: .white).cropped(to: image.extent)) }
    if TIFF16Output.requiresTiles(image.extent) {
      try TIFF16Output.write(image, context:context, colorSpace:sRGB, to:stage, transport:.nativeTiles, format:format, legacyMask:legacyMask)
    } else if let legacyMask {
      try TIFF16Output.write(image, context:context, colorSpace:sRGB, to:stage, transport:tiffTransport, format:format, legacyMask:legacyMask)
    } else {
      switch format {
      case .jpeg8: try context.writeJPEGRepresentation(of: image, to: stage, colorSpace: sRGB, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])
      case .tiff16: try TIFF16Output.write(image, context: context, colorSpace: sRGB, to: stage, transport:tiffTransport)
      case .png16: try context.writePNGRepresentation(of: image, to: stage, format: .RGBA16, colorSpace: sRGB)
      }
    }
    var artifact = try inspect(stage, sourceDepth: sourceDepth)
    guard artifact.bitDepth == (format == .jpeg8 ? 8 : 16), artifact.iccProfileSHA256 != nil else { throw DevelopmentError.invalidEncoding }
    if format == .jpeg8 { artifact.alphaPolicy = .compositedWhite }
    try Task.checkCancellation(); try beforePublish(); try RenderFiles.check(destination, protected: protectedURLs)
    if let preparePublication {
      preservePreparedStage = true
      try preparePublication(stage, destination, artifact)
    }
    // After the durable intent, publication survives late cancellation and is reconciled by Core.
    // moveItem never replaces an existing file, including a concurrent writer.
    try FileManager.default.moveItem(at: stage, to: destination)
    outcome = .succeeded
    return RenderedPhoto(fileURL: destination, artifact: artifact)
  }
  static func inspect(_ url: URL, sourceDepth: Int? = nil) throws -> RenderArtifact {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DevelopmentError.unreadable }
    let icc = cg.colorSpace?.copyICCData() as Data?
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let profileName = properties?[kCGImagePropertyProfileName] as? String
    let decodedAlpha: ArtifactAlphaPolicy
    switch cg.alphaInfo { case .first, .last: decodedAlpha = .straight; case .premultipliedFirst, .premultipliedLast: decodedAlpha = .premultiplied; default: decodedAlpha = .opaque }
    // A decoder may expose premultiplied pixels for an unassociated TIFF file.
    let alpha: ArtifactAlphaPolicy
    if (CGImageSourceGetType(source) as String?) == UTType.tiff.identifier {
      guard let stored = try TIFF16Output.storedAlpha(url:url) else {throw DevelopmentError.invalidEncoding}
      alpha = stored
    } else {alpha=decodedAlpha}
    let byteCount = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    return RenderArtifact(sha256: try RenderFiles.hash(url), byteCount: byteCount, pixelWidth: cg.width, pixelHeight: cg.height,
      encoding: (CGImageSourceGetType(source) as String?) ?? "unknown", bitDepth: cg.bitsPerComponent,
      colorSpace: profileName ?? cg.colorSpace?.name as String? ?? "unprofiled", iccProfileSHA256: icc.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
      sourceEffectiveBitDepth: sourceDepth, alphaPolicy: alpha)
  }
}

/// TIFF's integer representation is independent of the canonical F32 adjustment graph.
enum TIFF16Output {
  enum Transport { case whole,nativeBands256,nativeTiles }
  static func requiresTiles(_ extent: CGRect) -> Bool { max(extent.width,extent.height) > 16384 }
  struct Layout {
    let width, height, rowBytes, payload, mappedBytes: Int
    static func checked(_ extent: CGRect, pageSize: Int = Int(getpagesize())) throws -> Layout {
      let w=extent.width,h=extent.height
      guard extent.minX.isFinite,extent.minY.isFinite,w.isFinite,h.isFinite,w>0,h>0,
        w.rounded(.down)==w,h.rounded(.down)==h,w<Double(Int.max),h<Double(Int.max),pageSize>0 else { throw DevelopmentError.invalidEncoding }
      let width=Int(w),height=Int(h)
      let (row,a)=width.multipliedReportingOverflow(by:8)
      let (payload,b)=row.multipliedReportingOverflow(by:height)
      let (padded,c)=payload.addingReportingOverflow(pageSize-1)
      guard !a,!b,!c,row>0,payload>0 else { throw DevelopmentError.invalidEncoding }
      let (mapped,d)=(padded/pageSize).multipliedReportingOverflow(by:pageSize)
      guard !d,mapped>=payload else { throw DevelopmentError.invalidEncoding }
      return .init(width:width,height:height,rowBytes:row,payload:payload,mappedBytes:mapped)
    }
  }
  /// No implicit deinit unmap: callers must observe close failure before publication.
  final class Pages {
    let pointer: UnsafeMutableRawPointer, count: Int
    private let unmap: (UnsafeMutableRawPointer,Int)->Int32
    private let lock=NSLock()
    private var readers=0,closed=false
    init(_ count: Int, unmap: @escaping (UnsafeMutableRawPointer,Int)->Int32 = { munmap($0,$1) }) throws {
      guard count>0,let p=mmap(nil,count,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0),p != MAP_FAILED else {
        throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:[NSLocalizedDescriptionKey:"TIFF16 page allocation failed"])
      }
      pointer=p;self.count=count;self.unmap=unmap
    }
    func borrow() { lock.lock();defer{lock.unlock()};precondition(!closed);readers += 1 }
    func finish() { lock.lock();defer{lock.unlock()};precondition(readers>0);readers -= 1 }
    var activeReaders: Int {lock.lock();defer{lock.unlock()};return readers}
    var isClosed: Bool {lock.lock();defer{lock.unlock()};return closed}
    func close() throws {
      lock.lock();defer{lock.unlock()}
      if closed{return}
      guard readers==0 else {throw DevelopmentError.invalidEncoding}
      guard unmap(pointer,count)==0 else {
        throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:[NSLocalizedDescriptionKey:"TIFF16 page release failed"])
      }
      closed=true
    }
  }
  /// The body must join every native reader, including its failure paths.
  static func withPages(_ pages: Pages, body: (Pages)throws->Void) throws {
    var primary: Error?
    do {try autoreleasepool {try body(pages)}} catch {primary=error}
    do {try pages.close()} catch {
      if let primary {
        throw NSError(domain:"RAWMaster.TIFF16Cleanup",code:1,userInfo:[NSUnderlyingErrorKey:primary,
          NSLocalizedDescriptionKey:"TIFF16 failed and its pages could not be released","releaseError":error as NSError])
      }
      throw error
    }
    if let primary {throw primary}
  }
  static func renderBand(_ image:CIImage, context:CIContext, colorSpace:CGColorSpace, layout:Layout,
                         format:PhotoRenderFormat, top:Int, height:Int, buffer:UnsafeMutableRawPointer) throws {
    let stridePerPixel=format == .jpeg8 ? 4:8
    for x in stride(from:0,to:layout.width,by:1536) {
      try Task.checkCancellation()
      try autoreleasepool {
        let w=min(1536,layout.width-x)
        let rect=CGRect(x:image.extent.minX+CGFloat(x),y:image.extent.maxY-CGFloat(top+height),width:CGFloat(w),height:CGFloat(height))
        let destination=CIRenderDestination(bitmapData:buffer.advanced(by:x*stridePerPixel),width:w,height:height,
          bytesPerRow:layout.rowBytes,format:format == .jpeg8 ? .RGBA8:.RGBA16)
        destination.colorSpace=colorSpace;destination.alphaMode = .unpremultiplied
        destination.isFlipped=true;destination.isClamped=true;destination.isDithered=false
        let task=try context.startTask(toRender:image,from:rect,to:destination,at:.zero)
        do {_ = try task.waitUntilCompleted()}
        catch {let failure=error;_ = try? task.waitUntilCompleted();throw failure}
      }
    }
  }
  static func write(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace, to url: URL,
                    transport:Transport = .whole, format:PhotoRenderFormat = .tiff16, jpegQuality:Double = 0.95, legacyMask:DevelopmentLegacyMaskOutput? = nil) throws {
    let extent=image.extent,layout=try Layout.checked(extent)
    if transport != .whole {
      guard extent == extent.integral else { throw DevelopmentError.invalidEncoding }
    }
    if format == .tiff16, transport == .nativeTiles, try LargeTIFF16Writer.writeIfRepresentable(
      image:image,layout:layout,context:context,colorSpace:colorSpace,url:url,legacyMask:legacyMask) { return }
    // Same opt-in scalar diagnostic as native finite validation. This records only
    // synchronous stage boundaries, not the continuously sampled process peak.
    let qaScalars=ProcessInfo.processInfo.environment["RAWMASTER_MAXIMUM_QA_SCALARS"] == "1"
    let outputID=qaScalars ? UUID().uuidString:""
    var phase="allocation",completed=false
    func trace(_ boundary:String) {
      guard qaScalars else{return}
      var info=task_vm_info_data_t()
      var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
      let status=withUnsafeMutablePointer(to:&info){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)){
        task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
      }}
      let row:[String:Any]=["tag":"rawmaster-maximum-qa-scalars","kind":"tiff-output","outputID":outputID,
        "boundary":boundary,"phase":phase,"completed":completed,"atNS":DispatchTime.now().uptimeNanoseconds,
        "physFootprintBytes":status==KERN_SUCCESS ? UInt64(info.phys_footprint) as Any:NSNull(),
        "transport":String(describing:transport),
        "width":layout.width,"height":layout.height,"mappedBytes":layout.mappedBytes,
        "measurementScope":"joined-output-stage-boundaries-not-continuous-task-peak"]
      guard var data=try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) else{return}
      data.append(0x0a);try? FileHandle.standardError.write(contentsOf:data)
    }
    defer{trace("exit")}
    try Task.checkCancellation()
    let pages=try Pages(layout.mappedBytes)
    try withPages(pages) { pages in
      try Task.checkCancellation()
      phase="native-render";trace("begin")
      try renderJoined(pages) {
        func join(_ from:CGRect,at point:CGPoint,pointer:UnsafeMutableRawPointer,width:Int,height:Int)throws {
          let destination=CIRenderDestination(bitmapData:pointer,width:width,height:height,bytesPerRow:layout.rowBytes,format:format == .jpeg8 ? .RGBA8 : .RGBA16)
          destination.colorSpace=colorSpace;destination.alphaMode = .unpremultiplied
          destination.isFlipped=true;destination.isClamped=true;destination.isDithered=false
          let task=try context.startTask(toRender:image,from:from,to:destination,at:point)
          do {_ = try task.waitUntilCompleted()}
          catch {let original=error;_ = try? task.waitUntilCompleted();throw original}
        }
        switch transport {
        case .whole: try join(extent,at:.zero,pointer:pages.pointer,width:layout.width,height:layout.height)
        case .nativeTiles:
          // Keep each render and its full graph footprint inside a native texture, even when
          // the 2× photo exceeds the device limit along either axis. Image I/O receives global top-first rows.
          for top in stride(from:0,to:layout.height,by:LargeTIFF16Writer.rowsPerStrip) {
            let h=min(LargeTIFF16Writer.rowsPerStrip,layout.height-top)
            try renderBand(image,context:context,colorSpace:colorSpace,layout:layout,format:format,
                           top:top,height:h,buffer:pages.pointer.advanced(by:top*layout.rowBytes))
          }
        case .nativeBands256:
          for y in stride(from:0,to:layout.height,by:256) {
            let count=min(256,layout.height-y)
            let from=CGRect(x:extent.minX,y:extent.minY+CGFloat(y),width:extent.width,height:CGFloat(count))
            try Task.checkCancellation()
            do {
              defer { context.clearCaches() }
              try autoreleasepool {
                // The complete output backing remains top-first. Only this destination's
                // height is local; the input graph and requested source coordinates stay global.
                let physicalTop=layout.height-y-count
                try join(from,at:.zero,pointer:pages.pointer.advanced(by:physicalTop*layout.rowBytes),width:layout.width,height:count)
              }
            }
            try Task.checkCancellation()
          }
        }
        try legacyMask?.restore(buffer:pages.pointer, rowBytes:layout.rowBytes, top:0, rows:layout.height, format:format, colorSpace:colorSpace)
      }
      trace("end")
      try Task.checkCancellation()
      phase="imageio-encode";trace("begin")
      // Provider's retain and reader lease outlive every encoder access to this pointer.
      var provider: CGDataProvider? = try self.provider(pages,size:layout.payload)
      guard let actualProvider=provider else {throw DevelopmentError.invalidEncoding}
      #if _endian(little)
      let order=CGBitmapInfo.byteOrder16Little
      #else
      let order=CGBitmapInfo.byteOrder16Big
      #endif
      let bits=format == .jpeg8 ? 8:16
      let info=CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue)
      var cg=CGImage(width:layout.width,height:layout.height,bitsPerComponent:bits,bitsPerPixel:bits*4,bytesPerRow:layout.rowBytes,
        space:colorSpace,bitmapInfo:bits == 16 ? info.union(order):info,
        provider:actualProvider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
      let type:UTType, properties:[CFString:Any]
      switch format {
      case .tiff16: type = .tiff; properties=[kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFCompression:1]]
      case .png16: type = .png; properties=[kCGImagePropertyDepth:16]
      case .jpeg8: type = .jpeg; properties=[kCGImageDestinationLossyCompressionQuality:jpegQuality]
      }
      var target=CGImageDestinationCreateWithURL(url as CFURL,type.identifier as CFString,1,nil)
      defer {target=nil;cg=nil;provider=nil}
      guard let cg,let target else {throw DevelopmentError.invalidEncoding}
      CGImageDestinationAddImage(target,cg,properties.merging([kCGImagePropertyOrientation:1]){first,_ in first} as CFDictionary)
      guard CGImageDestinationFinalize(target) else {throw DevelopmentError.invalidEncoding}
      trace("end")
      // CGImage/provider/target retire at the autoreleasepool boundary, before explicit close.
    }
    phase="pages-closed";trace("end")
    try Task.checkCancellation()
    if format == .tiff16, try storedAlpha(url:url) != .straight {throw DevelopmentError.invalidEncoding}
    completed=true
  }
  static func renderJoined(_ pages: Pages, _ native: ()throws->Void) throws {
    pages.borrow();defer{pages.finish()};try native()
  }
  static func provider(_ pages: Pages,size: Int) throws -> CGDataProvider {
    guard size>0,size<=pages.count else{throw DevelopmentError.invalidEncoding}
    pages.borrow();let info=Unmanaged.passRetained(pages).toOpaque()
    guard let provider=CGDataProvider(dataInfo:info,data:pages.pointer,size:size,releaseData:{info,_,_ in
      guard let info else{return};let owner=Unmanaged<Pages>.fromOpaque(info)
      owner.takeUnretainedValue().finish();owner.release()
    }) else {pages.finish();Unmanaged<Pages>.fromOpaque(info).release();throw DevelopmentError.invalidEncoding}
    return provider
  }
  /// Read bounded classic-TIFF metadata, never decoder pixel bytes. BigTIFF is not reinterpreted.
  static func storedAlpha(url: URL) throws -> ArtifactAlphaPolicy? {
    let f=try FileHandle(forReadingFrom:url);defer{try? f.close()}
    func read(_ n:Int)throws->[UInt8] {let d=try f.read(upToCount:n) ?? Data();guard d.count==n else{throw DevelopmentError.invalidEncoding};return Array(d)}
    let header=try read(8);let little=header[0]==73 && header[1]==73
    guard little || (header[0]==77 && header[1]==77) else{return nil}
    func u16(_ a:[UInt8],_ o:Int)->Int {little ? Int(a[o])|Int(a[o+1])<<8 : Int(a[o])<<8|Int(a[o+1])}
    func u32(_ a:[UInt8],_ o:Int)->UInt64 {little ? (0..<4).reduce(0){$0|UInt64(a[o+$1])<<($1*8)} : (0..<4).reduce(0){$0<<8|UInt64(a[o+$1])}}
    guard u16(header,2)==42 else{return nil}
    try f.seek(toOffset:u32(header,4));let count=u16(try read(2),0)
    guard count<=256 else{return nil}
    var samples:Int?,extra:Int?
    for _ in 0..<count {
      let e=try read(12);let tag=u16(e,0)
      if tag==277 || tag==338 {
        guard u16(e,2)==3,u32(e,4)==1 else{return nil}
        if tag==277{samples=u16(e,8)}else{extra=u16(e,8)}
      }
    }
    if samples==3 && extra==nil{return .opaque}
    if samples==4,extra==1{return .premultiplied}
    if samples==4,extra==2{return .straight}
    return nil
  }
}
