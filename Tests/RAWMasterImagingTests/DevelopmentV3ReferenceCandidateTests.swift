import XCTest
import Foundation
import CoreImage
import ImageIO
import Metal
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

/// Root-scheduled canonical quality generation only. Does not claim that a generated candidate passes.
final class DevelopmentV3ReferenceCandidateTests: XCTestCase {
  private enum Gate: Error { case mismatch(String) }
  private let protocolSHA = "fa0ba8429444befd42fd3baa99a33e2bc81721abd4bfac7052d451f70aa4bb15"
  private let commonSHA = "8390078b3d928b28a83908c7ebc833a10e38adc6080de2752551251c452e6231"
  private struct Case {
    let id, category: String
    let recipe: DevelopmentRecipe
    var summary = false
    var controlEvidence: [String:String] = [:]
    var referencePath: String? = nil
  }
  private func write(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
    let handle = try FileHandle(forWritingTo:url); try handle.synchronize(); try handle.close()
  }
  private func cases(repo: URL) throws -> [Case] {
    var result: [Case] = []
    func add(_ id: String,_ category: String,_ change:(inout DevelopmentAdjustmentsV3)->Void) {
      var p = DevelopmentAdjustmentsV3(); change(&p); result.append(.init(id:id,category:category,recipe:.init(adjustmentsV3:p)))
    }
    add("common-neutral","neutral") { _ in }
    add("exposure-050","pointwise") { $0.light = .init(enabled:true,exposure:0.5) }
    add("brilliance-050","spatial") { $0.light = .init(enabled:true,brilliance:0.5,brillianceVersion:.adaptiveLocalV1) }
    add("shadows-050","spatial") { $0.light = .init(enabled:true,shadows:0.5) }
    add("highlights-minus050","spatial") { $0.light = .init(enabled:true,highlights:-0.5) }
    add("brightness-025","pointwise") { $0.light = .init(enabled:true,brightness:0.25) }
    add("contrast-025","pointwise") { $0.light = .init(enabled:true,contrast:0.25) }
    add("blackpoint-025","pointwise") { $0.light = .init(enabled:true,blackPoint:0.25) }
    add("saturation-050","pointwise") { $0.color = .init(enabled:true,saturation:0.5) }
    add("vibrance-050","pointwise") { $0.color = .init(enabled:true,vibrance:0.5) }
    add("cast-050","pointwise") { $0.color = .init(enabled:true,cast:0.5) }
    add("blackwhite-intensity-050","pointwise") { $0.blackAndWhite = .init(enabled:true,intensity:0.5) }
    add("definition-050","spatial") { $0.definition = .init(enabled:true,amount:0.5) }
    add("noise-image-100","spatial") { $0.noiseReduction = .init(enabled:true,sourceCapability:.image,nonRawAmount:1) }
    let acr = "output/validation/021-photos-editor/acr-research/references"
    result.append(.init(id:"acr-texture-025",category:"spatial",recipe:.init(adjustmentsV3:.init(advancedDetail:.init(texture:.init(enabled:true,amount:25)))),referencePath:acr+"/acr-texture-025.tif"))
    result.append(.init(id:"acr-clarity-025",category:"spatial",recipe:.init(adjustmentsV3:.init(advancedDetail:.init(clarity:.init(enabled:true,amount:25)))),referencePath:acr+"/acr-clarity-025.tif"))
    let dehazeURL=repo.appendingPathComponent("output/validation/022-photos-speed-quality/dehaze-effects-package9-20261108/natural/v2/prepare/render/amount-25.recipe.json")
    let dehaze=try JSONDecoder().decode(DevelopmentRecipe.self,from:Data(contentsOf:dehazeURL))
    result.append(.init(id:"acr-dehaze-025",category:"spatial",recipe:dehaze,referencePath:acr+"/acr-dehaze-025.tif"))
    add("sharpen-050","spatial") { $0.sharpen = .init(enabled:true,intensity:0.5,edges:0.22,falloff:0.69) }
    add("vignette-050","spatial") { $0.vignette = .init(enabled:true,strength:0.5,radius:0.5,softness:0) }
    add("whitebalance-image-5000","pointwise") { $0.whiteBalance = .init(enabled:true,adjustment:.temperatureTint(temperature:5000,tint:0)) }
    add("whitebalance-image-7000","pointwise") { $0.whiteBalance = .init(enabled:true,adjustment:.temperatureTint(temperature:7000,tint:0)) }
    result.append(.init(id:"light-summary-050",category:"spatial",recipe:.init(adjustmentsV3:.init()),summary:true))
    let operation = repo.appendingPathComponent("output/validation/021-photos-editor/quality-reference/curve-rgb-mid-raise-operation.json")
    if FileManager.default.fileExists(atPath:operation.path) {
      let data = try JSONSerialization.jsonObject(with:Data(contentsOf:operation)) as! [String:Any]
      guard data["channel"] as? String == "RGB", let point = data["controlPointNormalized"] as? [Double], point.count == 2 else { throw Gate.mismatch("curve operation") }
      add("curve-rgb-mid-raise","pointwise") { p in p.curves.enabled = true; p.curves.rgb.curve.points.insert(.init(x:point[0],y:point[1]),at:1) }
    }
    let bindingURL = repo.appendingPathComponent("output/validation/021-photos-editor/quality-reference/curve-rgb-mid-raise-exact-replay-binding.json")
    if FileManager.default.fileExists(atPath:bindingURL.path) {
      let metadataURL = repo.appendingPathComponent("output/validation/021-photos-editor/rea/photos-parameter-replay/curve-rgb-mid-raise-exact-reference.json")
      let metadataSHA = "16ea3acd12948b7bd77b88e6c61279345759a5fe6b3e1f4f8c8acdc0b7dd58cb"
      let referenceSHA = "f4bf6fc79045405e2c86f8ca8552932b94aea365b77ed8a6a82ead5bc72a378b"
      let binding = try JSONSerialization.jsonObject(with:Data(contentsOf:bindingURL)) as! [String:Any]
      let metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:metadataURL)) as! [String:Any]
      guard try RenderFiles.hash(metadataURL) == metadataSHA, binding["metadataSHA256"] as? String == metadataSHA,
        binding["referenceSHA256"] as? String == referenceSHA,
        let points = binding["actualCurve"] as? [[String:Any]],
        let point = points.first(where: { $0["editable"] as? Bool == true }),
        let x = point["x"] as? Double, let y = point["y"] as? Double,
        x == 0.5533452765443708, y == 0.6538372097478679,
        let adjustments = metadata["adjustments"] as? [[String:Any]],
        let curve = adjustments.first(where: { $0["identifier"] as? String == "RKCurvesOperation" }),
        let settings = curve["settings"] as? [String:Any], let keys = settings["inputKeys"] as? [String:Any],
        let actualPoints = keys["RGBCurvePoints"] as? [[String:Any]],
        try JSONSerialization.data(withJSONObject:actualPoints,options:.sortedKeys) == JSONSerialization.data(withJSONObject:points,options:.sortedKeys)
      else { throw Gate.mismatch("exact curve control/reference binding") }
      var p = DevelopmentAdjustmentsV3(); p.curves = p.curves.forDirectUserEdit()
      p.curves.rgb.curve.points.insert(.init(x:x,y:y),at:1)
      result.append(.init(id:"curve-rgb-mid-raise-exact-replay",category:"pointwise",recipe:.init(adjustmentsV3:p),
        controlEvidence:["binding":bindingURL.path,"bindingSHA256":try RenderFiles.hash(bindingURL),
          "metadata":metadataURL.path,"metadataSHA256":metadataSHA,"expectedReferenceSHA256":referenceSHA,
          "interpolation":"current direct-edit natural cubic gamma512 luma; exact matched control; old uncertainty reference preserved"]))
    }
    return result
  }
  func testOptInGenerateCommonTIFFCandidates() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["RAWMASTER_021_V3_CANDIDATE"] == "1", let repository = env["RAWMASTER_021_V3_REPOSITORY"],
      let output = env["RAWMASTER_021_V3_OUTPUT"], let selection = env["RAWMASTER_021_V3_CASES"],
      env["RAWMASTER_021_V3_MAX_FOOTPRINT_MIB"] == "8192" else { throw XCTSkip("Explicit Root case/output/8192MiB candidate-generation grant required") }
    let repo = URL(fileURLWithPath:repository).standardizedFileURL.resolvingSymlinksInPath()
    let out = RenderFiles.canonical(URL(fileURLWithPath:output)), qa = repo.appendingPathComponent("output/validation/021-photos-editor/imaging-p3ba")
    let delivery = repo.appendingPathComponent("output/validation/023-effects-delivery")
    guard (out.path.hasPrefix(qa.path+"/") || out.path.hasPrefix(delivery.path+"/")), !FileManager.default.fileExists(atPath:out.path) else { throw Gate.mismatch("new QA output required") }
    let protocolURL = repo.appendingPathComponent("output/validation/021-photos-editor/reference-protocol.json")
    guard try RenderFiles.hash(protocolURL) == protocolSHA else { throw Gate.mismatch("frozen protocol") }
    let sourceURL = repo.appendingPathComponent("output/validation/021-photos-editor/photos-inputs/CommonBase-60MP-sRGB16.tiff")
    guard try RenderFiles.hash(sourceURL) == commonSHA else { throw Gate.mismatch("common source") }
    let count = (try FileManager.default.attributesOfItem(atPath:sourceURL.path)[.size] as! NSNumber).int64Value
    guard count == 361_334_448 else { throw Gate.mismatch("common bytes") }
    let ids = selection.split(separator:",").map(String.init), available = try cases(repo:repo)
    guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy({ id in available.contains { $0.id == id } }) else { throw Gate.mismatch("case selection") }
    let chosen = available.filter { ids.contains($0.id) }, referenceRoot = repo.appendingPathComponent("output/validation/021-photos-editor/quality-reference")
    // Freeze the chosen reference identities before constructing/rendering any candidate graph.
    var references: [String:[String:Any]] = [:]
    for entry in chosen {
      let url = entry.referencePath.map { repo.appendingPathComponent($0) } ?? referenceRoot.appendingPathComponent(entry.id).appendingPathComponent("CommonBase-60MP-sRGB16.tiff")
      let referenceSHA = try RenderFiles.hash(url)
      if let expected = entry.controlEvidence["expectedReferenceSHA256"], referenceSHA != expected { throw Gate.mismatch("exact frozen curve reference") }
      references[entry.id] = ["path":url.path,"sha256":referenceSHA,"category":entry.category,"controlEvidence":entry.controlEvidence]
    }
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false)
    let source = EditingSourceSnapshot(projectID:"021-canonical-QA",assetID:"common-sRGB16",contentSHA256:commonSHA,byteCount:count,
      admissionFingerprint:"021-reference-protocol-v2",sourceLocation:sourceURL)
    var producer = ["Package.swift"]
    for module in ["Sources/RAWMasterCore","Sources/RAWMasterImaging"] {
      let root=repo.appendingPathComponent(module)
      guard let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey]) else { continue }
      for case let url as URL in files {
        guard (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true else { continue }
        producer.append(String(url.path.dropFirst(repo.path.count+1)))
      }
    }
    producer.sort()
    var sourceHashes: [String:String] = [:]; for path in producer { sourceHashes[path] = try RenderFiles.hash(repo.appendingPathComponent(path)) }
    let executable = try XCTUnwrap(Bundle(for:DevelopmentV3ReferenceCandidateTests.self).executableURL)
    let start: [String:Any] = ["kind":"candidate generation, quality NOT measured", "protocolSHA256":protocolSHA,"commonSourceSHA256":commonSHA,
      "sourceBytes":count,"cases":chosen.map(\.id),"references":references,"producerSources":sourceHashes,
      "runnerSHA256":try RenderFiles.hash(URL(fileURLWithPath:#filePath)),"testExecutable":executable.path,"testExecutableSHA256":try RenderFiles.hash(executable),
      "buildConfiguration":_isDebugAssertConfiguration() ? "debug":"release","hostOS":ProcessInfo.processInfo.operatingSystemVersionString,
      "physicalMemory":ProcessInfo.processInfo.physicalMemory,"footprintHardGateMiB":8192,
      "pipeline":DevelopmentRendererV3.pipelineVersion,"pointwiseShaderSHA256":DevelopmentColorEngineV3.sourceSHA256,
      "scope":"common TIFF semantics only; no RAW end-to-end or draw/performance claim",
      "unqualifiedOrUnexecutedCases":["levels","BW neutrals","BW tone","BW grain statistics","RAW track","skin/noise/local tools"]]
    try write(start,to:out.appendingPathComponent("run-start.json"))
    let monitor = V3CandidateMemoryMonitor(output:out,limit:8192*1024*1024); monitor.start(); defer { monitor.stop() }
    let developer = DevelopmentService(); var rows: [[String:Any]] = [], failure: String?
    do {
      try monitor.check("tiny-kernel-preflight/begin")
      var tiny = DevelopmentAdjustmentsV3()
      tiny.light = .init(enabled:true,brilliance:0.2,highlights:-0.1,shadows:0.1,brightness:0.1)
      tiny.color = .init(enabled:true,saturation:0.2,vibrance:0.1,cast:0.1)
      tiny.blackAndWhite = .init(enabled:true,intensity:0.5,grain:0.1)
      tiny.curves.enabled = true; tiny.curves.rgb.curve.points.insert(.init(x:0.5,y:0.6),at:1)
      tiny.levels = .init(enabled:true,luminance:.manual(.init(black:0.01,shadows:0.2,midtones:0.5,highlights:0.8,white:0.99,outputBlack:0,outputWhite:1)))
      let tinySource = CIImage(color:CIColor(red:0.2,green:0.1,blue:0.05,alpha:1)).cropped(to:CGRect(x:0,y:0,width:8,height:8))
      let spatial = try DevelopmentSpatialEngineV3.applyLight(tiny.light,to:tinySource)
      let pointwise = try DevelopmentColorEngineV3.applyPointwise(tiny,to:spatial)
      let processed = try DevelopmentColorEngineV3.applyCurvesAndLevels(tiny,to:pointwise)
      try DevelopmentColorEngineV3.validateFinite(processed)
      DevelopmentColorEngineV3.context.clearCaches(); try monitor.check("tiny-kernel-preflight/joined")
      for entry in chosen {
        try monitor.check("\(entry.id)/begin"); let folder = out.appendingPathComponent(entry.id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        var recipe = entry.recipe, analysisRecord: [String:Any] = [:]
        if entry.summary {
          let preview = DevelopmentPreviewService()
          do {
            let lease = try await preview.open(source:.raw(source)), consumer = PreviewConsumerID()
            let request = DevelopmentPreviewRequest(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,
              revision:1,recipe:recipe,quality:.settled,clientCorrelation:Data("021-real-light-summary".utf8))
            let analysis = try await preview.analyze(.init(preview:request,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),
              stage:.workingImageBeforeGeometry,operation:.summary(.light,amount:0.5)))
            guard case .resolved(let command) = analysis.value else { throw Gate.mismatch("resolved summary") }
            recipe = try recipe.applying(.applyAnalysis(command),context:.init(source:analysis.sourceBinding,sourceGeneration:lease.sourceGeneration,analysisStage:analysis.binding.stage))
            analysisRecord = ["operationID":analysis.operationID.uuidString,"samplingRecipeFingerprint":analysis.samplingRecipeFingerprint,
              "samplingVersion":analysis.samplingVersion,"sourceGeneration":analysis.binding.sourceGeneration,"actualInputRecipeFingerprint":analysis.binding.expectedRecipeFingerprint]
            await preview.closeAll()
          } catch { await preview.closeAll(); throw error }
        } else if entry.id == "acr-dehaze-025" {
          let preview = DevelopmentPreviewService()
          do {
            let lease = try await preview.open(source:.raw(source)), consumer = PreviewConsumerID()
            let facts = try await preview.sourceFacts(sessionID:lease.id,sourceGeneration:lease.sourceGeneration)
            let current = try XCTUnwrap(facts.dehazeContextV1), original = DevelopmentRecipe(adjustmentsV3:.init())
            let projection = try original.prospectiveDehazeInputV1(context:current,algorithm:.positiveColorGuideV2)
            let previewRequest = DevelopmentPreviewRequest(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,
              role:.primary,revision:1,recipe:projection.analysisRecipe,quality:.settled)
            let request = DevelopmentAnalysisRequest(preview:previewRequest,expectedRecipeFingerprint:projection.expectedRecipeFingerprint,
              stage:.workingImageBeforeGeometry,operation:.prepareDehaze,presentedRecipeFingerprint:projection.presentedRecipeFingerprint,dehazeInputV1:projection.input)
            let analysis = try await preview.analyze(request)
            guard case .dehaze(let resolved)=analysis.value else { throw Gate.mismatch("resolved Dehaze preparation") }
            recipe = try original.applying(.applyPreparedDehaze(resolved,wantedAmount:25),context:.init(source:current.source,sourceGeneration:current.sourceGeneration,
              analysisStage:.workingImageBeforeGeometry,sourceCapability:.image,dehazeContextV1:current))
            analysisRecord = ["operationID":analysis.operationID.uuidString,"samplingRecipeFingerprint":analysis.samplingRecipeFingerprint,
              "samplingVersion":analysis.samplingVersion,"sourceGeneration":analysis.binding.sourceGeneration,"actualInputRecipeFingerprint":analysis.binding.expectedRecipeFingerprint]
            await preview.closeAll()
          } catch { await preview.closeAll(); throw error }
        }
        try recipe.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let recipeData = try encoder.encode(recipe); try recipeData.write(to:folder.appendingPathComponent("recipe.json"),options:.withoutOverwriting)
        try monitor.check("\(entry.id)/before-public-render"); let before = DispatchTime.now().uptimeNanoseconds
        let rendered = try await developer.render(source:source,recipe:recipe,format:.tiff16,destination:folder.appendingPathComponent("candidate.tiff"),protectedURLs:[sourceURL,referenceRoot,repo.appendingPathComponent("output/validation/021-photos-editor/acr-research/references")])
        let end = DispatchTime.now().uptimeNanoseconds; try monitor.check("\(entry.id)/render-returned")
        guard rendered.artifact.pixelWidth == 9504, rendered.artifact.pixelHeight == 6336, rendered.artifact.bitDepth == 16,
          rendered.artifact.iccProfileSHA256 != nil else { throw Gate.mismatch("actual candidate canvas/depth/ICC") }
        let candidateSHA = try RenderFiles.hash(rendered.fileURL)
        guard candidateSHA == rendered.artifact.sha256 else { throw Gate.mismatch("published candidate bytes") }
        PhotoRenderer.renderingContext(recipe).clearCaches(); try monitor.check("\(entry.id)/context-cleared")
        let row: [String:Any] = ["case":entry.id,"category":entry.category,"candidate":rendered.fileURL.path,"candidateSHA256":candidateSHA,
          "recipe":folder.appendingPathComponent("recipe.json").path,"recipeFingerprint":try EditingFingerprint.of(recipe),
          "reference":references[entry.id]!,"artifact":try JSONSerialization.jsonObject(with:JSONEncoder().encode(rendered.artifact)),
          "publicRenderIncludingVerifyCaptureEncodeIOMilliseconds":Double(end-before)/1e6,"drawTiming":NSNull(),
          "capturedSourceSHA256":NSNull(),"captureNote":"public API internal capture is not exposed; no invented capture hash or decode count",
          "analysis":analysisRecord,"qualityStatus":"NOT MEASURED; run separately reviewed comparator", "memoryAtReturn":monitor.current()]
        try write(row,to:folder.appendingPathComponent("candidate-receipt.json")); rows.append(row)
        try monitor.check("\(entry.id)/receipt-fsynced")
      }
      try RenderFiles.verify(source); try monitor.check("original-source-postverified")
    } catch { failure = String(describing:error) }
    PhotoRenderer.context.clearCaches(); DevelopmentColorEngineV3.context.clearCaches()
    try await Task.sleep(nanoseconds:500_000_000); try monitor.check("cleanup-plus0.5s")
    try await Task.sleep(nanoseconds:1_500_000_000); try monitor.check("cleanup-plus2s")
    let report: [String:Any] = ["generationComplete":failure == nil && rows.count == chosen.count,"failure":failure as Any? ?? NSNull(),
      "rows":rows,"memory":monitor.report(),"qualityQualified":false,"noAdvanceOnFailure":true,
      "actualRawCandidatesExecuted":false,"noProductMemoryPolicyChange":true]
    try write(report,to:out.appendingPathComponent("generation-receipt.json")); try monitor.check("generation-receipt-fsynced")
    monitor.stop()
    try write(monitor.report(),to:out.appendingPathComponent("memory-final.json"))
    XCTAssertNil(failure); XCTAssertEqual(rows.count,chosen.count)
  }
}

/// Process phys_footprint samples and Metal's API allocation counter are separate observations.
/// An observed8GiB breach writes/fsyncs an abort marker then stops this QA process, never user apps.
private final class V3CandidateMemoryMonitor: @unchecked Sendable {
  private let output: URL, limit: UInt64, queue = DispatchQueue(label:"021.v3-candidate-memory"), lock = NSLock()
  private let device = MTLCreateSystemDefaultDevice()
  private var timer: DispatchSourceTimer?, pressure: DispatchSourceMemoryPressure?
  private var phase = "before", peak: UInt64 = 0, metalPeak: UInt64 = 0, count: UInt64 = 0
  private var recent: [[String:Any]] = [], cursor = 0, stopped = false
  init(output: URL, limit: UInt64) { self.output = output; self.limit = limit }
  func start() {
    let timer = DispatchSource.makeTimerSource(queue:queue); timer.schedule(deadline:.now(),repeating:.milliseconds(20))
    timer.setEventHandler { [weak self] in self?.observe() }; self.timer = timer; timer.resume()
    let pressure = DispatchSource.makeMemoryPressureSource(eventMask:.critical,queue:queue)
    pressure.setEventHandler { [weak self] in self?.abort("system-critical-memory-pressure") }; self.pressure = pressure; pressure.resume()
    observe()
  }
  func stop() { lock.lock(); if stopped { lock.unlock(); return }; stopped = true; lock.unlock(); timer?.cancel(); pressure?.cancel(); queue.sync {} }
  func check(_ value: String) throws { lock.lock(); phase = value; lock.unlock(); observe() }
  func current() -> [String:Any] { ["physFootprintBytes":Self.footprint() as Any? ?? NSNull(),"metalCurrentAllocatedBytes":device.map { UInt64($0.currentAllocatedSize) } as Any? ?? NSNull()] }
  private func observe() {
    guard let bytes = Self.footprint() else { abort("phys-footprint-unavailable") }
    let metal = device.map { UInt64($0.currentAllocatedSize) }
    lock.lock(); peak = max(peak,bytes); metalPeak = max(metalPeak,metal ?? 0); count += 1
    let row: [String:Any] = ["at":DispatchTime.now().uptimeNanoseconds,"phase":phase,"physFootprintBytes":bytes,"metalCurrentAllocatedBytes":metal as Any? ?? NSNull()]
    if recent.count < 512 { recent.append(row) } else { recent[cursor] = row; cursor = (cursor+1)%512 }; lock.unlock()
    if bytes >= limit { abort("observed-phys-footprint-at-or-above-hard-gate") }
  }
  func report() -> [String:Any] {
    lock.lock(); defer { lock.unlock() }
    return ["limitBytes":limit,"physFootprintSampledPeakBytes":peak,"metalCurrentAllocatedSampledPeakBytes":metalPeak,
      "requestedIntervalMilliseconds":20,"sampleCount":count,"recentSamples":recent,"retainedSampleLimit":512,
      "overwrittenScalarSamples":count > UInt64(recent.count) ? count-UInt64(recent.count):0,
      "metalScope":"MTLDevice.currentAllocatedSize API counter; not a claim that phys_footprint covers all GPU/WindowServer memory",
      "guardScope":"observed threshold gate, not an OS-enforced cap between samples"]
  }
  private func abort(_ reason: String) -> Never {
    let marker = output.appendingPathComponent("memory-abort.json")
    let value: [String:Any] = ["aborted":true,"reason":reason,"observations":report()]
    if let data = try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys) {
      let fd = Darwin.open(marker.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
      if fd >= 0 { data.withUnsafeBytes { buffer in var n = 0; while n < buffer.count { let w = Darwin.write(fd,buffer.baseAddress!.advanced(by:n),buffer.count-n); if w < 0 && errno == EINTR { continue }; if w <= 0 { break }; n += w } }; _ = Darwin.fsync(fd); Darwin.close(fd) }
    }
    Darwin._exit(86)
  }
  private static func footprint() -> UInt64? {
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
    return status == KERN_SUCCESS ? info.phys_footprint:nil
  }
}
