import XCTest
import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

// Opt-in isolated transport experiment. No production override or output-policy change.
final class ReadbackContextProbeTests: XCTestCase {
  private enum Stop: Error { case memory(String), quality(String), layout(String), protocolMismatch }
  private let limit: UInt64 = 3 * 1024 * 1024 * 1024
  private func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
  private func json(_ value: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting) }
  private func rgba(_ cg: CGImage) throws -> Data {
    let bitmap = NSBitmapImageRep(cgImage:cg)
    guard bitmap.bitsPerPixel == 32, bitmap.bytesPerRow == cg.width*4, let pointer = bitmap.bitmapData else { throw Stop.layout("original NSBitmap packed RGBA unavailable") }
    return Data(bytes:pointer,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
  }
  private func metrics(_ a: Data, _ b: Data) throws -> [String:Any] {
    guard a.count == b.count, a.count % 4 == 0 else { throw Stop.layout("pixel byte counts") }
    var hist = [[Int]](repeating:[Int](repeating:0,count:256),count:4), zeroAlpha = 0, positiveAlpha = 0
    var straightMax = [Double](repeating:0,count:3), compositeMax = [Int](repeating:0,count:3)
    a.withUnsafeBytes { (aa: UnsafeRawBufferPointer) in b.withUnsafeBytes { (bb: UnsafeRawBufferPointer) in
      for p in stride(from:0,to:a.count,by:4) {
        for c in 0..<4 { hist[c][abs(Int(aa[p+c])-Int(bb[p+c]))] += 1 }
        if aa[p+3] > 0 && bb[p+3] > 0 {
          positiveAlpha += 1
          for c in 0..<3 { straightMax[c] = max(straightMax[c],abs(Double(aa[p+c])*255/Double(aa[p+3])-Double(bb[p+c])*255/Double(bb[p+3]))) }
        } else { zeroAlpha += 1 }
        for c in 0..<3 { for background in [0,255] {
          let av = min(255,Int(aa[p+c])+background*(255-Int(aa[p+3]))/255)
          let bv = min(255,Int(bb[p+c])+background*(255-Int(bb[p+3]))/255)
          compositeMax[c] = max(compositeMax[c],abs(av-bv))
        } }
      }
    } }
    var p99:[Int] = [], maximum:[Int] = []
    for h in hist { let target = Int(ceil(Double(h.reduce(0,+))*0.99)); var sum = 0, q = 0; for (v,n) in h.enumerated() { sum += n; if sum >= target { q = v; break } }; p99.append(q); maximum.append(h.lastIndex(where:{$0>0}) ?? 0) }
    return ["p99":p99,"maximum":maximum,"passed":p99.allSatisfy{$0<=1} && maximum.allSatisfy{$0<=2} && compositeMax.allSatisfy{$0<=2} && straightMax.allSatisfy{$0<=2},"positiveRepresentableOutputAlphaPixels":positiveAlpha,"zeroQuantizedOrNonpositiveOutputAlphaPixels":zeroAlpha,"straightRGBMaximumByteUnits":straightMax,"straightRGBScope":"only both output alphas positive; zero quantized alpha unmeasurable, premul/alpha/composites still compared","blackWhiteCompositeMaximum":compositeMax]
  }
  private func original(_ image: CIImage, _ context: CIContext) throws -> CGImage {
    guard let cg = context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false) else { throw DevelopmentError.unreadable }; return cg
  }
  private func owned(_ image: CIImage, _ context: CIContext, strips: Bool, stage: (String) throws -> Void) throws -> ReadbackOwnedRGBA8 {
    let canvas = image.extent.integral
    guard canvas.width > 0, canvas.height > 0, canvas.width < 50000, canvas.height < 50000 else { throw Stop.layout("invalid canvas") }
    let owner = try ReadbackOwnedRGBA8(width:Int(canvas.width),height:Int(canvas.height))
    try stage("allocation-complete")
    if strips {
      for row in stride(from:0,to:owner.height,by:256) {
        let height = min(256,owner.height-row)
        let bounds = CGRect(x:canvas.minX,y:canvas.maxY-CGFloat(row+height),width:canvas.width,height:CGFloat(height))
        try stage("before-strip-\(row)-\(height)")
        context.render(image,toBitmap:owner.pointer.advanced(by:row*owner.rowBytes),rowBytes:owner.rowBytes,bounds:bounds,format:.RGBA8,colorSpace:PhotoRenderer.sRGB)
        try stage("after-strip-\(row)-\(height)")
      }
    } else {
      try stage("before-whole-render")
      context.render(image,toBitmap:owner.pointer,rowBytes:owner.rowBytes,bounds:canvas,format:.RGBA8,colorSpace:PhotoRenderer.sRGB)
      try stage("after-whole-render")
    }
    return owner
  }
  func testOptInMicroParity() throws {
    let env = ProcessInfo.processInfo.environment
    guard let mode = env["RAWMASTER_READBACK_MODE"], ["F4-micro","F5-micro"].contains(mode), let root = env["RAWMASTER_READBACK_OUTPUT"] else { throw XCTSkip("Explicit readback micro arm required") }
    let directory = URL(fileURLWithPath:root).appendingPathComponent(mode); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    guard !FileManager.default.fileExists(atPath:directory.appendingPathComponent("receipt.json").path) else { throw XCTSkip("No evidence overwrite") }
    var rows:[[String:Any]] = [], failure:String?
    do {
      let context = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512])
      defer { context.clearCaches() }
      let width=513, height=1025
      var pixels = [Float](repeating:0,count:width*height*4)
      let alpha:[Float] = [0,1e-8,1.0/65535,0.5,1]
      for y in 0..<height { for x in 0..<width {
        let offset=(y*width+x)*4, a=alpha[min(4,x*5/width)]
        pixels[offset] = (Float(x)/Float(width-1)*1.2-0.1)*a
        pixels[offset+1] = Float(y%257)/256*a
        pixels[offset+2] = (x%2 == 0 ? 0.05:2)*a; pixels[offset+3]=a
      } }
      let data=pixels.withUnsafeBytes { Data($0) }
      let base=CIImage(bitmapData:data,bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB)
      var colors=DevelopmentColorAdjustments(); colors.curves.rgb = .init(points:[.init(x:0,y:0),.init(x:0.4999,y:0),.init(x:0.5,y:1),.init(x:1,y:1)])
      let steep=try DevelopmentColorEngineV2.apply(colors,to:base); try DevelopmentColorEngineV2.validateFinite(steep,context:context)
      var fixtures:[(String,CIImage)] = [("gradient-HDR-alpha-rows",base),("steep-minGap",steep),("fractional-negative-origin",base.transformed(by:.init(translationX:-7.25,y:3.75)))]
      var recipe = DevelopmentRecipe(); recipe.straightenDegrees = 3.25; recipe.crop = .init(x:0.07,y:0.04,width:0.86,height:0.9)
      fixtures.append(("geometry-crop-straighten",try PhotoRenderer.applyV2Geometry(base,recipe)))
      for orientation in [6,8] {
        let url=directory.appendingPathComponent("orientation\(orientation).png"), cg=try original(base,context)
        guard let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw DevelopmentError.invalidEncoding }
        CGImageDestinationAddImage(dest,cg,[kCGImagePropertyOrientation:orientation] as CFDictionary);guard CGImageDestinationFinalize(dest),let oriented=CIImage(contentsOf:url,options:[.applyOrientationProperty:true]) else { throw DevelopmentError.unreadable }
        guard Int(oriented.extent.width)==height,Int(oriented.extent.height)==width else { throw Stop.layout("ImageIO orientation not applied") }
        fixtures.append(("ImageIO-orientation\(orientation)",oriented))
      }
      // The row-ID fixture is opaque and transport-sensitive, independent of the effect kernel.
      var ids = [UInt8](repeating:255,count:width*height*4)
      for y in 0..<height { for x in 0..<width { let p=(y*width+x)*4;ids[p]=UInt8(y&255);ids[p+1]=UInt8(y>>8);ids[p+2]=UInt8(x&255) } }
      fixtures.append(("opaque-row-ID-corners",CIImage(bitmapData:Data(ids),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:PhotoRenderer.sRGB)))
      for (name,image) in fixtures {
        try autoreleasepool {
          let reference=try original(image,context), expected=try rgba(reference)
          let owner=try owned(image,context,strips:mode == "F5-micro",stage:{_ in})
          guard owner.width==reference.width,owner.height==reference.height else { throw Stop.layout(name+" canvas") }
          let actual=owner.packedDataForMicroOnly(), result=try metrics(actual,expected)
          var row:[String:Any] = ["name":name,"width":owner.width,"height":owner.height,"canvas":[image.extent.integral.minX,image.extent.integral.minY,image.extent.integral.width,image.extent.integral.height],"cgVsCandidate":result,"expectedSHA256":sha(expected),"actualSHA256":sha(actual)]
          if name == "opaque-row-ID-corners" && actual != expected { throw Stop.layout("row-ID/corners differ") }
          if mode == "F5-micro" {
            let whole=try owned(image,context,strips:false,stage:{_ in}).packedDataForMicroOnly()
            row["wholeVsStripsExact"] = whole == actual
            guard whole == actual else { rows.append(row);throw Stop.layout(name+" strip seams/phase") }
          }
          rows.append(row)
          guard result["passed"] as? Bool == true else { throw Stop.quality(name) }
        }
      }
    } catch { failure=String(describing:error) }
    try json(["mode":mode,"pass":failure==nil,"failure":failure ?? "none","rows":rows,"helperSHA256":try RenderFiles.hash(URL(fileURLWithPath:#filePath)),"scope":"isolated transport; tiny input alpha quantizes to0, straightRGB unmeasurable there; original RGBAf semantic gate independent"],directory.appendingPathComponent("receipt.json"))
    XCTAssertNil(failure)
  }
  func testOptInReadbackResource() async throws {
    let env=ProcessInfo.processInfo.environment
    guard let mode=env["RAWMASTER_READBACK_MODE"],["F3","F4","F5"].contains(mode),let repository=env["RAWMASTER_READBACK_REPOSITORY"],let root=env["RAWMASTER_READBACK_OUTPUT"] else { throw XCTSkip("Explicit bounded readback resource arm required") }
    let repo=URL(fileURLWithPath:repository), parent=URL(fileURLWithPath:root), output=parent.appendingPathComponent(mode)
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    guard !FileManager.default.fileExists(atPath:output.appendingPathComponent("receipt.json").path) else { throw XCTSkip("No arm overwrite") }
    if mode != "F3" {
      let micro=try JSONSerialization.jsonObject(with:Data(contentsOf:parent.appendingPathComponent(mode+"-micro/receipt.json"))) as! [String:Any]
      guard micro["pass"] as? Bool == true else { throw XCTSkip("Micro gate required") }
      if mode == "F5" {
        let prior=try JSONSerialization.jsonObject(with:Data(contentsOf:parent.appendingPathComponent("F4/receipt.json"))) as! [String:Any]
        guard prior["memoryPass"] as? Bool == false,(prior["failure"] as? String)?.hasPrefix("memory(") == true else { throw XCTSkip("F5 only actual F4 resource memory failure") }
      }
    }
    let specData=try Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/reference-protocol.json"))
    guard sha(specData)=="e1caf2c7fb3aa215f4a0862fa6e39591b39a5a0634c3f6910d845c14e6a57246" else { throw Stop.protocolMismatch }
    let spec=try JSONSerialization.jsonObject(with:specData) as! [String:Any],cases=spec["cases"] as! [[String:Any]]
    let combined=try XCTUnwrap(cases.first{$0["id"] as? String=="combined-photographic"}),alternate=try XCTUnwrap(cases.first{$0["id"] as? String=="highlights--100"})
    let primary=EditingSourceSnapshot(projectID:"020-context-probe",assetID:"DSC05994",contentSHA256:"8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c",byteCount:69_488_640,admissionFingerprint:"pinned-probe",sourceLocation:repo.appendingPathComponent("output/validation/019-preview-ux/adobe/DSC05994-ACR-benchmark.ARW"))
    let secondary=EditingSourceSnapshot(projectID:"020-context-probe",assetID:"DSC05995",contentSHA256:"7798bebb0b45d68e44d5794385eeb361498858e4f477d9f658a066c41786dc89",byteCount:70_914_048,admissionFingerprint:"pinned-probe",sourceLocation:repo.appendingPathComponent("output/validation/010-timelapse/raw-input-interval5994-5999/DSC05995.ARW"))
    let sampler=ReadbackMemorySampler();sampler.start();defer{sampler.stop()}
    var phases:[[String:Any]]=[],rows:[[String:Any]]=[],failure:String?,contexts:[String:CIContext]=[:],held=[CGImage?](repeating:nil,count:2)
    func mark(_ label:String) { sampler.label(label);phases.append(["label":label,"at":DispatchTime.now().uptimeNanoseconds,"footprint":ReadbackMemorySampler.footprint(),"periodicHighWater":sampler.highWater]) }
    func check(_ label:String) throws { if max(sampler.highWater,ReadbackMemorySampler.footprint())>limit { throw Stop.memory(label) } }
    func stage<T>(_ label:String,_ body:() throws -> T) throws -> T { mark(label+"/begin");let value=try body();mark(label+"/end");try check(label);return value }
    func context(_ family:String)->CIContext {
      autoreleasepool{contexts[family]?.clearCaches();contexts[family]=nil}
      let options:[CIContextOption:Any] = family=="active" ? [.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512]:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.memoryTarget:512]
      let c=CIContext(options:options);contexts[family]=c;return c
    }
    func render(_ label:String,_ source:EditingSourceSnapshot,_ recipe:DevelopmentRecipe,_ maxPixel:Int,_ family:String,_ floats:Bool,_ slot:Int) throws {
      held[slot]=nil;let c=context(family),folder=output.appendingPathComponent(label);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      let start=DispatchTime.now().uptimeNanoseconds
      let result=try autoreleasepool { () throws -> ([String:Any],CGImage) in
        let capture=try stage(label+"/capture"){try RenderFiles.capture(source)};defer{try? FileManager.default.removeItem(at:capture.deletingLastPathComponent())}
        let image=try stage(label+"/develop-finite"){try (family=="active" ? ContextProbeV2Clone.develop(capture,recipe,context:c):PhotoRenderer.develop(capture,recipe)).0}
        let scale=maxPixel==0 ? 1:min(1,CGFloat(maxPixel)/max(image.extent.width,image.extent.height)),scaled=image.transformed(by:.init(scaleX:scale,y:scale))
        let cg:CGImage,hash:String,rowBytes:Int
        if mode=="F3" {
          cg=try stage(label+"/createCGImage"){try original(scaled,c)}
          let bitmap=try stage(label+"/NSBitmapImageRep"){NSBitmapImageRep(cgImage:cg)}
          let pointer=try stage(label+"/bitmapData"){try XCTUnwrap(bitmap.bitmapData)}
          let data=try stage(label+"/Data-copy"){Data(bytes:pointer,count:bitmap.bytesPerRow*bitmap.pixelsHigh)}
          try stage(label+"/raw-file-write"){try data.write(to:folder.appendingPathComponent("output.rgba8"),options:.withoutOverwriting)}
          hash=sha(data);rowBytes=bitmap.bytesPerRow
          try stage(label+"/PNG"){try writePNG(cg,folder.appendingPathComponent("output.png"))}
          // Same F2 owned output bridge after complete readback. Its provider owns the Data.
          guard let provider=CGDataProvider(data:data as CFData),let result=CGImage(width:cg.width,height:cg.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:rowBytes,space:cg.colorSpace!,bitmapInfo:cg.bitmapInfo,provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw DevelopmentError.unreadable}
          if floats { try floatReadback(scaled,c,cg.width,cg.height,folder,label,stage) }
          return (["label":label,"sourceSHA256":source.contentSHA256,"recipeFingerprint":try EditingFingerprint.of(recipe),"width":cg.width,"height":cg.height,"rowBytes":rowBytes,"rgba8SHA256":hash,"scale":scale,"elapsedMillisecondsIncludingAllPasses":Double(DispatchTime.now().uptimeNanoseconds-start)/1e6],result)
        } else {
          let owner=try owned(scaled,c,strips:mode=="F5",stage:{s in mark(label+"/"+s);try check(label+"/"+s)})
          cg=try stage(label+"/same-allocation-provider"){try owner.cgImage()};hash=owner.packedSHA256();rowBytes=owner.rowBytes
          try stage(label+"/raw-file-write"){try owner.writePacked(folder.appendingPathComponent("output.rgba8"))}
          try stage(label+"/PNG"){try writePNG(cg,folder.appendingPathComponent("output.png"))}
          if floats { try floatReadback(scaled,c,cg.width,cg.height,folder,label,stage) }
          try stage(label+"/source-postverify"){try RenderFiles.verify(source)}
          return (["label":label,"sourceSHA256":source.contentSHA256,"recipeFingerprint":try EditingFingerprint.of(recipe),"width":cg.width,"height":cg.height,"rowBytes":rowBytes,"rgba8SHA256":hash,"scale":scale,"canvas":[scaled.extent.integral.minX,scaled.extent.integral.minY,scaled.extent.integral.width,scaled.extent.integral.height],"allocationBytes":owner.rowBytes*owner.height,"elapsedMillisecondsIncludingAllPasses":Double(DispatchTime.now().uptimeNanoseconds-start)/1e6],cg)
        }
      }
      held[slot]=result.1;rows.append(result.0);try json(result.0,folder.appendingPathComponent("artifact.json"));mark(label+"/after-pool");try check(label+"/after-pool")
      print("READBACK \(mode) \(label) completed sampledMiB=\(Double(sampler.highWater)/1048576)")
    }
    mark("before-contexts")
    do {
      let active=try apply(combined["overrides"] as! [String:Any]),alt=try apply(alternate["overrides"] as! [String:Any])
      try render("active-combined",primary,active,2400,"active",true,0)
      try render("legacy-comparison",primary,.init(),2400,"legacy",false,1)
      try render("active-repeat",primary,active,2400,"active",true,0)
      try render("active-alternate-second-source",secondary,alt,2400,"active",true,0)
      try render("second-source-neutral-comparison",secondary,.init(),2400,"legacy",false,1)
      try render("active-native-detail",primary,active,0,"active",false,0)
      if mode != "F3" { try render("comparison-native-detail",secondary,.init(),0,"legacy",false,1) }
    } catch { failure=String(describing:error) }
    held=[nil,nil];mark("all-native-joined-drop-outputs");for c in contexts.values{c.clearCaches()};contexts.removeAll();mark("clear-and-drop-contexts")
    try? await Task.sleep(nanoseconds:500_000_000);mark("close-plus0.5s");try? await Task.sleep(nanoseconds:1_500_000_000);mark("close-plus2s");sampler.stop()
    let memoryPass=sampler.highWater<=limit
    try json(["mode":mode,"pass":failure==nil && rows.count==(mode=="F3" ? 6:7),"failure":failure ?? "none","memoryPass":memoryPass,"limitBytes":limit,"rows":rows,"phases":phases,"periodic":sampler.report(),"helperSHA256":try RenderFiles.hash(URL(fileURLWithPath:#filePath)),"cloneSHA256":try RenderFiles.hash(repo.appendingPathComponent("Tests/RAWMasterImagingTests/ContextProbeV2Clone.swift")),"protocolSHA256":sha(specData),"caveats":["Isolated readback transport; production/default/cache unchanged","Sample labels mark before/after synchronous calls; actual timestamps classify sampled peak, no causal inference from label alone","No original-v2 control quality automatically qualified; resource and QC separate","Atmost two held output slots; no GUI handoff proof"]],output.appendingPathComponent("receipt.json"))
    XCTAssertNil(failure);XCTAssertTrue(memoryPass)
  }
  private func writePNG(_ cg:CGImage,_ url:URL)throws { guard let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else{throw DevelopmentError.invalidEncoding};CGImageDestinationAddImage(dest,cg,nil);guard CGImageDestinationFinalize(dest) else{throw DevelopmentError.invalidEncoding} }
  private func floatReadback(_ image:CIImage,_ c:CIContext,_ width:Int,_ height:Int,_ folder:URL,_ label:String,_ stage:(String,() throws -> Void)throws -> Void)throws {
    try stage(label+"/float32") {
      var values=[Float](repeating:0,count:width*height*4);c.render(image,toBitmap:&values,rowBytes:width*16,bounds:image.extent.integral,format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB)
      guard values.allSatisfy(\.isFinite) else{throw DevelopmentError.invalidEncoding}
      try values.withUnsafeMutableBytes{buffer in try Data(bytesNoCopy:buffer.baseAddress!,count:buffer.count,deallocator:.none).write(to:folder.appendingPathComponent("output.rgba32f"),options:.withoutOverwriting)}
    }
  }
  private func apply(_ overrides:[String:Any])throws->DevelopmentRecipe {
    var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(DevelopmentRecipe().promotingToV2())) as! [String:Any]
    func set(_ o:[String:Any],_ path:ArraySlice<String>,_ v:Any)throws->[String:Any]{guard let key=path.first else{throw Stop.protocolMismatch};var r=o;if path.count==1{r[key]=v}else{guard let child=o[key] as? [String:Any]else{throw Stop.protocolMismatch};r[key]=try set(child,path.dropFirst(),v)};return r}
    for k in overrides.keys.sorted(){object=try set(object,k.components(separatedBy:".")[...],overrides[k]!)}
    return try JSONDecoder().decode(DevelopmentRecipe.self,from:JSONSerialization.data(withJSONObject:object))
  }
}

private final class ReadbackOwnedRGBA8 {
  let width:Int,height:Int,rowBytes:Int,pointer:UnsafeMutableRawPointer
  init(width:Int,height:Int)throws {self.width=width;self.height=height;let (n,o)=width.multipliedReportingOverflow(by:4);guard !o,n<Int.max-63 else{throw CocoaError(.fileWriteOutOfSpace)};rowBytes=((n+63)/64)*64;let (bytes,overflow)=rowBytes.multipliedReportingOverflow(by:height);guard !overflow,let p=calloc(1,bytes)else{throw CocoaError(.fileWriteOutOfSpace)};pointer=p}
  deinit{free(pointer)}
  func cgImage()throws->CGImage {
    let info=Unmanaged.passRetained(self).toOpaque()
    guard let provider=CGDataProvider(dataInfo:info,data:pointer,size:rowBytes*height,releaseData:{info,_,_ in if let info{Unmanaged<ReadbackOwnedRGBA8>.fromOpaque(info).release()}}) else{Unmanaged<ReadbackOwnedRGBA8>.fromOpaque(info).release();throw DevelopmentError.unreadable}
    guard let cg=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:rowBytes,space:PhotoRenderer.sRGB,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)else{throw DevelopmentError.unreadable};return cg
  }
  func packedSHA256()->String {var digest=SHA256();for row in 0..<height{digest.update(bufferPointer:UnsafeRawBufferPointer(start:pointer.advanced(by:row*rowBytes),count:width*4))};return digest.finalize().map{String(format:"%02x",$0)}.joined()}
  func writePacked(_ url:URL)throws {guard FileManager.default.createFile(atPath:url.path,contents:nil)else{throw CocoaError(.fileWriteUnknown)};let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()};for row in 0..<height{try handle.write(contentsOf:Data(bytesNoCopy:pointer.advanced(by:row*rowBytes),count:width*4,deallocator:.none))};try handle.synchronize()}
  func packedDataForMicroOnly()->Data {var result=Data(capacity:width*height*4);for row in 0..<height{result.append(pointer.advanced(by:row*rowBytes).assumingMemoryBound(to:UInt8.self),count:width*4)};return result}
}
private final class ReadbackMemorySampler:@unchecked Sendable {
  private let lock=NSLock(),queue=DispatchQueue(label:"020.readback-memory");private var timer:DispatchSourceTimer?,name="before",peak:UInt64=0,samples:[[String:Any]]=[]
  var highWater:UInt64{lock.lock();defer{lock.unlock()};return peak}
  func label(_ s:String){lock.lock();name=s;lock.unlock()}
  func start(){let t=DispatchSource.makeTimerSource(queue:queue);t.schedule(deadline:.now(),repeating:.milliseconds(20));t.setEventHandler{[weak self]in self?.sample()};timer=t;t.resume()}
  func stop(){timer?.cancel();timer=nil;queue.sync{}}
  private func sample(){let memory=Self.footprint(),at=DispatchTime.now().uptimeNanoseconds;lock.lock();peak=max(peak,memory);samples.append(["at":at,"footprint":memory,"phase":name]);lock.unlock()}
  func report()->[String:Any]{lock.lock();defer{lock.unlock()};let times=samples.compactMap{$0["at"] as? UInt64};let d=zip(times.dropFirst(),times).map{Double($0-$1)/1e6}.sorted();return["samples":samples,"sampleCount":samples.count,"sampledHighWaterBytes":peak,"requestedIntervalMilliseconds":20,"achievedIntervalP95Milliseconds":d.isEmpty ? 0:d[Int(ceil(Double(d.count)*0.95))-1],"achievedIntervalMaximumMilliseconds":d.max() ?? 0]}
  static func footprint()->UInt64{var info=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);let s=withUnsafeMutablePointer(to:&info){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return s==KERN_SUCCESS ? info.phys_footprint:0}
}
