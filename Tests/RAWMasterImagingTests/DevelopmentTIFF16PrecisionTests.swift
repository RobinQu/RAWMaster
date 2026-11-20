import XCTest
import CoreImage
import ImageIO
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentTIFF16PrecisionTests: XCTestCase {
  private func directory() throws -> URL {
    let u=FileManager.default.temporaryDirectory.appendingPathComponent("TIFF16-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:u,withIntermediateDirectories:false)
    addTeardownBlock{try? FileManager.default.removeItem(at:u)};return u
  }
  private func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  /// Direct TIFF42 serialization: fixture creation cannot share the tested encoder.
  private func source(_ root:URL,_ pixels:[[UInt16]],width:Int,height:Int,orientation:Int=1)throws->EditingSourceSnapshot {
    let c=pixels[0].count;XCTAssertEqual(pixels.count,width*height)
    func u16(_ a:[UInt16])->Data {a.map{$0.littleEndian}.withUnsafeBytes{Data($0)}}
    func u32(_ x:UInt32)->Data {var x=x.littleEndian;return withUnsafeBytes(of:&x){Data($0)}}
    let icc=try XCTUnwrap(PhotoRenderer.sRGB.copyICCData()) as Data
    var tags:[(UInt16,UInt16,UInt32,Data)] = [
      (256,4,1,u32(UInt32(width))),(257,4,1,u32(UInt32(height))),(258,3,UInt32(c),u16(Array(repeating:16,count:c))),
      (259,3,1,u16([1])),(262,3,1,u16([2])),(273,4,1,u32(0)),(274,3,1,u16([UInt16(orientation)])),
      (277,3,1,u16([UInt16(c)])),(278,4,1,u32(UInt32(height))),(279,4,1,u32(UInt32(width*height*c*2))),
      (284,3,1,u16([1])),(34675,7,UInt32(icc.count),icc)]
    if c==4 {tags.append((338,3,1,u16([2])))}
    tags.sort{$0.0<$1.0};var cursor=8+2+12*tags.count+4;var extra:[UInt16:(Int,Data)]=[:]
    for t in tags where t.3.count>4 {cursor=(cursor+3)/4*4;extra[t.0]=(cursor,t.3);cursor += t.3.count}
    let offset=(cursor+15)/16*16;var data=Data(repeating:0,count:offset)
    data.replaceSubrange(0..<8,with:Data([73,73,42,0])+u32(8));data.replaceSubrange(8..<10,with:u16([UInt16(tags.count)]))
    for (i,t) in tags.enumerated() {
      var value=t.0==273 ? u32(UInt32(offset)) : t.3
      if value.count>4 {value=u32(UInt32(extra[t.0]!.0))} else {value.append(Data(repeating:0,count:4-value.count))}
      data.replaceSubrange(10+i*12..<22+i*12,with:u16([t.0,t.1])+u32(t.2)+value)
    }
    for (_,v) in extra {data.replaceSubrange(v.0..<v.0+v.1.count,with:v.1)}
    data.append(u16(pixels.flatMap{$0}));let url=root.appendingPathComponent("source.tiff");try data.write(to:url)
    return .init(projectID:"precision",assetID:"literal",contentSHA256:hash(data),byteCount:Int64(data.count),admissionFingerprint:"literal",sourceLocation:url)
  }
  private func raw(_ url:URL)throws->([[UInt16]],[Int:[Int]]) {
    let d=[UInt8](try Data(contentsOf:url));let le=d[0]==73
    func n(_ p:Int,_ size:Int)->Int {(0..<size).reduce(0){le ? $0|Int(d[p+$1])<<($1*8):$0<<8|Int(d[p+$1])}}
    XCTAssertEqual(n(2,2),42);let ifd=n(4,4),count=n(ifd,2);var t:[Int:[Int]]=[:]
    for i in 0..<count {let p=ifd+2+i*12,k=n(p,2),kind=n(p+2,2),c=n(p+4,4)
      guard [256,257,258,259,273,274,277,278,338].contains(k) else{continue}
      let size=kind==3 ? 2:4;let start=c*size<=4 ? p+8:n(p+8,4);t[k]=(0..<c).map{n(start+$0*size,size)}
    }
    XCTAssertEqual(t[259],[1]);XCTAssertTrue(t[258]!.allSatisfy{$0==16})
    let w=t[256]![0],h=t[257]![0],c=t[277]![0],rows=t[278]![0];var p:[[UInt16]]=[]
    for y in 0..<h {let start=t[273]![y/rows]+y%rows*w*c*2
      for x in 0..<w {p.append((0..<c).map{UInt16(n(start+(x*c+$0)*2,2))})}
    };return(p,t)
  }
  private func precise(_ actual:[[UInt16]],_ expected:[[UInt16]],file:StaticString=#filePath,line:UInt=#line) {
    XCTAssertEqual(actual.count,expected.count,file:file,line:line);guard actual.count==expected.count else{return}
    for c in 0..<expected[0].count {
      let errors=zip(actual,expected).map{pair in abs(Int(pair.0[c])-Int(pair.1[c]))}.sorted()
      XCTAssertLessThanOrEqual(errors.last ?? 0,2,file:file,line:line)
      let pos=Double(errors.count-1)*0.99,i=Int(pos)
      let p99=Double(errors[i])+Double(errors[min(i+1,errors.count-1)]-errors[i])*(pos-Double(i))
      XCTAssertLessThanOrEqual(p99,1,file:file,line:line)
    }
  }
  // Core Image rounds public crop and affine extents outward on this SDK.
  private final class FractionalOriginImage: CIImage, @unchecked Sendable {
    override var extent: CGRect { CGRect(x:0.25,y:0,width:19,height:513) }
  }
  func testPublicPositiveV2TIFFMatchesWholeWriterAcrossBoundariesAndTail() async throws {
    let root=try directory(),width=19,height=513
    let values=(0..<width*height).map { i -> [UInt16] in
      let x=i%width,y=i/width
      return [UInt16(10_000+y*70),UInt16(18_000+x*900),UInt16(34_000+(x+y)%31*800),
              x==0 ? 0:(x<5 ? 32768:65535)]
    }
    let input=try source(root,values,width:width,height:height)
    let before=DevelopmentRecipe(adjustmentsV3:.init())
    let actual=try DevelopmentDehazeContextFactoryV1.fromCapture(input.sourceLocation)
    let projection=try before.prospectiveDehazeInputV1(context:actual,algorithm:.positiveColorGuideV2)
    let prepared=DevelopmentPreparedDehazeV1(sourceBinding:actual.source,inputFingerprint:projection.input.inputFingerprint,
      airlight:.init(red:1,green:1,blue:1),algorithmVersion:2)
    let resolved=DevelopmentResolvedDehazeV1(binding:.init(sourceContentID:actual.source.sourceContentID,
      sourceGeneration:actual.sourceGeneration,expectedRecipeFingerprint:projection.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry),
      presentedRecipeFingerprint:projection.presentedRecipeFingerprint,input:projection.input,resolution:.prepared(prepared))
    let recipe=try before.applying(.applyPreparedDehaze(resolved,wantedAmount:25),context:.init(source:actual.source,
      sourceGeneration:actual.sourceGeneration,analysisStage:.workingImageBeforeGeometry,sourceCapability:.image,dehazeContextV1:actual))
    let banded=try await DevelopmentService().render(source:input,recipe:recipe,format:.tiff16,destination:root.appendingPathComponent("banded.tiff"))
    let c=DevelopmentColorEngineV3.makeContext()
    defer{c.clearCaches()}
    let graph=try DevelopmentRendererV3.develop(input.sourceLocation,recipe:recipe,context:c)
    XCTAssertTrue(graph.graphDescriptor.contains(DevelopmentDehazeColorGuideV2.version))
    let whole=root.appendingPathComponent("whole.tiff")
    try TIFF16Output.write(graph.image,context:c,colorSpace:PhotoRenderer.sRGB,to:whole)
    let (candidate,tags)=try raw(banded.fileURL),(reference,_)=try raw(whole)
    XCTAssertEqual(candidate,reference)
    XCTAssertEqual(tags[338],[2])
    XCTAssertEqual(banded.artifact.alphaPolicy,.straight)
    XCTAssertEqual(banded.artifact.iccProfileSHA256,try PhotoRenderer.inspect(whole,sourceDepth:nil).iccProfileSHA256)
    XCTAssertEqual(hash(try Data(contentsOf:input.sourceLocation)),input.contentSHA256)
    for geometry in [
      DevelopmentGeometryV3(crop:.init(x:0.25,y:0,width:0.75,height:1)),
      DevelopmentGeometryV3(clockwiseQuarterTurns:1)
    ] {
      let changed=try recipe.applying(.setGeometry(geometry),context:.init(source:actual.source,
        sourceGeneration:actual.sourceGeneration,analysisStage:.workingImageBeforeGeometry,sourceCapability:.image,dehazeContextV1:actual))
      let id=UUID().uuidString
      let actualURL=root.appendingPathComponent(id+"-geometry.tiff")
      let rendered=try await DevelopmentService().render(source:input,recipe:changed,format:.tiff16,destination:actualURL)
      let canonical=try DevelopmentRendererV3.develop(input.sourceLocation,recipe:changed,context:c)
      let referenceURL=root.appendingPathComponent(id+"-whole.tiff")
      try TIFF16Output.write(canonical.image,context:c,colorSpace:PhotoRenderer.sRGB,to:referenceURL)
      XCTAssertEqual(try raw(rendered.fileURL).0,try raw(referenceURL).0)
      let png=try await DevelopmentService().render(source:input,recipe:changed,format:.png16,destination:root.appendingPathComponent(id+".png"))
      let pngReference=try PhotoRenderer.write(canonical.image,format:.png16,destination:root.appendingPathComponent(id+"-whole.png"),protectedURLs:[],sourceDepth:16,renderContext:c)
      let actualPNG=try XCTUnwrap(CIImage(contentsOf:png.fileURL)),expectedPNG=try XCTUnwrap(CIImage(contentsOf:pngReference.fileURL))
      XCTAssertEqual(actualPNG.extent,expectedPNG.extent)
      let e=actualPNG.extent,w=Int(e.width),h=Int(e.height);var compared=0
      // Read every native PNG pixel within the analysis helper's existing 512 limit.
      for y in stride(from:0,to:h,by:512){for x in stride(from:0,to:w,by:512){
        let tile=CGRect(x:e.minX+CGFloat(x),y:e.minY+CGFloat(y),width:CGFloat(min(512,w-x)),height:CGFloat(min(512,h-y)))
        var actualPixels=[SIMD4<Float>](),expectedPixels=[SIMD4<Float>]()
        try DevelopmentLocalEngineV3.read(actualPNG,rect:tile,context:c){actualPixels=Array($0)}
        try DevelopmentLocalEngineV3.read(expectedPNG,rect:tile,context:c){expectedPixels=Array($0)}
        XCTAssertEqual(actualPixels,expectedPixels);compared+=actualPixels.count
      }}
      XCTAssertEqual(compared,w*h)
      let preview=try await DevelopmentService().preview(source:input,recipe:changed,maxPixel:0)
      XCTAssertEqual(preview.pixelWidth,Int(canonical.image.extent.width))
      XCTAssertEqual(preview.pixelHeight,Int(canonical.image.extent.height))
    }
    let fractional=FractionalOriginImage(color:.white)
    XCTAssertNotEqual(fractional.extent,fractional.extent.integral)
    XCTAssertNoThrow(try TIFF16Output.Layout.checked(fractional.extent))
    let rejected=root.appendingPathComponent("fractional.tiff")
    XCTAssertThrowsError(try TIFF16Output.write(fractional,context:c,colorSpace:PhotoRenderer.sRGB,to:rejected,transport:.nativeBands256)) { error in
      guard case DevelopmentError.invalidEncoding = error else { return XCTFail("Unexpected fractional-origin error: \(error)") }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath:rejected.path))
  }
  /// Independent original transport: one full-height destination, original global at.y,
  /// native256 task rects, and the same joined-task/clear ordering. No new writer helper.
  private func oldFullDestinationPixels(_ image:CIImage,context:CIContext)throws->[[UInt16]] {
    let e=image.extent,layout=try TIFF16Output.Layout.checked(e),pages=try TIFF16Output.Pages(try TIFF16Output.Layout.checked(e).mappedBytes)
    var answer=[[UInt16]]()
    try TIFF16Output.withPages(pages){pages in
      try TIFF16Output.renderJoined(pages){
        let destination=CIRenderDestination(bitmapData:pages.pointer,width:layout.width,height:layout.height,bytesPerRow:layout.rowBytes,format:.RGBA16)
        destination.colorSpace=PhotoRenderer.sRGB;destination.alphaMode = .unpremultiplied
        destination.isFlipped=true;destination.isClamped=true;destination.isDithered=false
        for y in stride(from:0,to:layout.height,by:256) {
          let count=min(256,layout.height-y)
          let from=CGRect(x:e.minX,y:e.minY+CGFloat(y),width:e.width,height:CGFloat(count))
          try Task.checkCancellation()
          do {
            defer{context.clearCaches()}
            try autoreleasepool {
              let task=try context.startTask(toRender:image,from:from,to:destination,at:CGPoint(x:0,y:CGFloat(y)))
              do{_ = try task.waitUntilCompleted()}
              catch{let primary=error;_ = try? task.waitUntilCompleted();throw primary}
            }
          }
          try Task.checkCancellation()
        }
      }
      let values=pages.pointer.assumingMemoryBound(to:UInt16.self)
      answer=(0..<layout.width*layout.height).map{i in (0..<4).map{values[i*4+$0]}}
    }
    XCTAssertTrue(pages.isClosed);XCTAssertEqual(pages.activeReaders,0)
    return answer
  }
  private func bandFixture(width:Int,height:Int)->CIImage {
    let values=(0..<width*height).map{i -> SIMD4<Float> in
      let x=i%width,y=i/width
      let alpha:Float=x==0 ? 0:(x<3 ? 0.5:1)
      let rgb=SIMD3<Float>(Float(y)/Float(height-1)*1.2-0.1,Float(x)/Float(width-1),Float((x*13+y*17)%127)/126)
      return .init(rgb.x*alpha,rgb.y*alpha,rgb.z*alpha,alpha)
    }
    return CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:width*16,
      size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  func testLocalBandDestinationPreservesFullHeightPixelsPortraitTailAndTranslatedOrigin()throws {
    let root=try directory(),context=DevelopmentColorEngineV3.makeContext()
    defer{context.clearCaches()}
    for (w,h) in [(19,513),(513,257),(193,769)] {
      for offset in [CGPoint.zero,CGPoint(x:11,y:-7)] {
        let image=bandFixture(width:w,height:h).transformed(by:.init(translationX:offset.x,y:offset.y))
        let reference=try oldFullDestinationPixels(image,context:context)
        let out=root.appendingPathComponent(UUID().uuidString+"-band.tiff")
        try TIFF16Output.write(image,context:context,colorSpace:PhotoRenderer.sRGB,to:out,transport:.nativeBands256)
        let (actual,tags)=try raw(out)
        XCTAssertEqual(actual,reference,"Every RGBA16 code and physical row must match the original full-height destination")
        XCTAssertEqual(actual.count,w*h);XCTAssertEqual(tags[338],[2]);XCTAssertEqual(tags[274] ?? [1],[1])
        let artifact=try PhotoRenderer.inspect(out)
        XCTAssertEqual(artifact.bitDepth,16);XCTAssertEqual(artifact.alphaPolicy,.straight)
        XCTAssertEqual(artifact.iccProfileSHA256,"2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e")
      }
    }
  }
  func testLocalBandDestinationPreservesActualAdaptiveGraphAllRGBA16Codes()throws {
    let root=try directory(),context=DevelopmentBrillianceAdaptiveV1.makeContext()
    defer{context.clearCaches()}
    let source=bandFixture(width:257,height:513)
    XCTAssertTrue(DevelopmentBrillianceAdaptiveV1.nativeGraphSupported(source.extent))
    var light=DevelopmentLightV3();light.enabled=true;light.brillianceVersion = .adaptiveLocalV1;light.brilliance=0.5
    let graph=try DevelopmentBrillianceAdaptiveV1.apply(light,to:source)
    let reference=try oldFullDestinationPixels(graph,context:context)
    let out=root.appendingPathComponent("adaptive-band.tiff")
    try TIFF16Output.write(graph,context:context,colorSpace:PhotoRenderer.sRGB,to:out,transport:.nativeBands256)
    let (actual,tags)=try raw(out)
    XCTAssertEqual(actual,reference,"The same actual spatial graph must retain every original RGBA16 code")
    XCTAssertEqual(tags[338],[2]);XCTAssertEqual(actual.count,257*513)
  }
  // Root first actual gate: run these two methods only, stop on failure.
  func testPublicFullUInt16CodePrecision() async throws {
    let root=try directory()
    var p: [[UInt16]] = []
    for i in 0..<65536 {
      let red: UInt16 = UInt16(i)
      let greenCode: Int = (257*i+17)%65536
      let green: UInt16 = UInt16(greenCode)
      let blue: UInt16 = UInt16(65535-i)
      p.append([red,green,blue])
    }
    let input=try source(root,p,width:1024,height:64),recipe=DevelopmentRecipe(adjustmentsV3:.init())
    let result=try await DevelopmentService().render(source:input,recipe:recipe,format:.tiff16,destination:root.appendingPathComponent("out.tiff"))
    let (actual,t)=try raw(result.fileURL);precise(actual,p.map{$0+[65535]})
    XCTAssertEqual(t[338],[2])
    let actualAlpha: ArtifactAlphaPolicy = result.artifact.alphaPolicy
    XCTAssertEqual(actualAlpha,ArtifactAlphaPolicy.straight)
    XCTAssertEqual(result.artifact.iccProfileSHA256,"2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e")
    XCTAssertEqual(hash(try Data(contentsOf:input.sourceLocation)),input.contentSHA256)
  }
  func testPublicLowAlphaStraightPrecisionAndStoredAssociation() async throws {
    let root=try directory();let p:[[UInt16]] = [[0,0,0,0],[60000,23456,12345,1],[12345,54321,34567,32768],[32767,1,60001,65534],[123,45678,65535,65535],[65535,0,32768,32768]]
    let input=try source(root,p,width:3,height:2)
    let result=try await DevelopmentService().render(source:input,recipe:.init(adjustmentsV3:.init()),format:.tiff16,destination:root.appendingPathComponent("alpha.tiff"))
    let (actual,t)=try raw(result.fileURL);precise(actual,p);XCTAssertEqual(t[338],[2])
    XCTAssertEqual(result.artifact.alphaPolicy,.straight)
    let inspected=try await DevelopmentService().inspect(fileURL:result.fileURL)
    XCTAssertEqual(inspected.alphaPolicy,.straight)
    // This alpha0 literal is all zero; it does not qualify hidden RGB preservation.
    for background in [0.0,1.0] { for c in 0..<3 {
      let errors=zip(actual,p).map { a,b -> Double in
        func decode(_ x:Double)->Double {x<=0.04045 ? x/12.92:pow((x+0.055)/1.055,2.4)}
        let ac=decode(Double(a[c])/65535)*Double(a[3])/65535+background*(1-Double(a[3])/65535)
        let ex=decode(Double(b[c])/65535)*Double(b[3])/65535+background*(1-Double(b[3])/65535)
        return abs(ac-ex)*65535
      }.sorted()
      XCTAssertLessThanOrEqual(errors.last ?? 0,2)
      let pos=Double(errors.count-1)*0.99,i=Int(pos)
      let p99=errors[i]+(errors[min(i+1,errors.count-1)]-errors[i])*(pos-Double(i))
      XCTAssertLessThanOrEqual(p99,1)
    } }
  }
  func testPublicNegativeHDRClipsOnlyAtIntegerExport() async throws {
    let root=try directory();let input=try source(root,[[0,0,0],[32768,32768,32768],[65535,65535,65535]],width:3,height:1)
    var p=DevelopmentAdjustmentsV3();p.light.enabled=true;p.light.exposure=0.5;p.light.blackPoint=1
    let recipe=DevelopmentRecipe(adjustmentsV3:p),graph=try DevelopmentRendererV3.develop(input.sourceLocation,recipe:recipe)
    var f=[Float](repeating:.nan,count:12)
    DevelopmentColorEngineV3.context.render(graph.image,toBitmap:&f,rowBytes:48,bounds:graph.image.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    XCTAssertLessThan(f[0],0);XCTAssertGreaterThan(f[8],1)
    let result=try await DevelopmentService().render(source:input,recipe:recipe,format:.tiff16,destination:root.appendingPathComponent("clip.tiff"))
    let (a,_)=try raw(result.fileURL);XCTAssertEqual(a[0],[0,0,0,65535]);XCTAssertEqual(a[2],[65535,65535,65535,65535])
  }
  func testPublicOrientationSixPreservesLiteralPermutation() async throws {
    let root=try directory()
    var p: [[UInt16]] = []
    for value in 1...6 {
      let red: UInt16 = UInt16(value*7000)
      let green: UInt16 = UInt16(value*5000)
      let blue: UInt16 = UInt16(value*3000)
      p.append([red,green,blue])
    }
    let input=try source(root,p,width:3,height:2,orientation:6)
    let result=try await DevelopmentService().render(source:input,recipe:.init(adjustmentsV3:.init()),format:.tiff16,destination:root.appendingPathComponent("rotate.tiff"))
    let (a,t)=try raw(result.fileURL);XCTAssertEqual(t[256],[2]);XCTAssertEqual(t[257],[3]);precise(a,[3,0,4,1,5,2].map{p[$0]+[65535]})
    XCTAssertEqual(t[274] ?? [1],[1])
  }
  func testCheckedLayoutHasNoNewByteCapAndRejectsOverflow() throws {
    let a=try TIFF16Output.Layout.checked(.init(x:0,y:0,width:9504,height:6336))
    XCTAssertEqual(a.rowBytes,76032);XCTAssertEqual(a.payload,481738752);XCTAssertGreaterThanOrEqual(a.mappedBytes,a.payload)
    XCTAssertNoThrow(try TIFF16Output.Layout.checked(.init(x:0,y:0,width:12000,height:12000)))
    for r in [CGRect.zero,CGRect(x:0,y:0,width:1.5,height:2),CGRect(x:0,y:0,width:CGFloat.infinity,height:2),CGRect(x:0,y:0,width:Double(Int.max),height:2)] {XCTAssertThrowsError(try TIFF16Output.Layout.checked(r))}
    XCTAssertThrowsError(try TIFF16Output.Layout.checked(.init(x:0,y:0,width:1,height:1),pageSize:Int.max))
  }
  func testOwnedPagesWaitReadersAndSurfaceReleaseFailure() throws {
    let p=try TIFF16Output.Pages(Int(getpagesize()));p.borrow();XCTAssertThrowsError(try p.close());XCTAssertFalse(p.isClosed)
    p.finish();try p.close();XCTAssertTrue(p.isClosed)
    var calls=0;let q=try TIFF16Output.Pages(Int(getpagesize()),unmap:{ptr,n in calls += 1;if calls==1{errno=EIO;return -1};return munmap(ptr,n)})
    XCTAssertThrowsError(try TIFF16Output.withPages(q){_ in});XCTAssertFalse(q.isClosed);try q.close();XCTAssertTrue(q.isClosed)
  }
  func testActualProviderLeaseRetiresBeforeExplicitUnmap() throws {
    let p=try TIFF16Output.Pages(Int(getpagesize()))
    try autoreleasepool {
      var provider: CGDataProvider? = try TIFF16Output.provider(p,size:8)
      XCTAssertNotNil(provider);XCTAssertEqual(p.activeReaders,1)
      XCTAssertThrowsError(try p.close());XCTAssertFalse(p.isClosed)
      provider=nil
    }
    XCTAssertEqual(p.activeReaders,0);try p.close();XCTAssertTrue(p.isClosed)
  }
  func testCancellationWhileJoinedReaderCannotReleaseEarly() async throws {
    let pages=try TIFF16Output.Pages(Int(getpagesize())),entered=expectation(description:"entered")
    let finish=DispatchSemaphore(value:0)
    let task=Task.detached {
      try TIFF16Output.withPages(pages){p in
        try TIFF16Output.renderJoined(p){entered.fulfill();finish.wait()}
        try Task.checkCancellation()
      }
    }
    await fulfillment(of:[entered],timeout:5);task.cancel()
    XCTAssertEqual(pages.activeReaders,1);XCTAssertThrowsError(try pages.close());XCTAssertFalse(pages.isClosed)
    finish.signal()
    do {try await task.value;XCTFail("cancel must propagate")}catch is CancellationError{}catch{XCTFail("\(error)")}
    XCTAssertTrue(pages.isClosed)
  }
  func testPublicTIFFProtectionAndDurableStageRemain() async throws {
    let root=try directory(),input=try source(root,[[1000,2000,3000]],width:1,height:1)
    let target=root.appendingPathComponent("sentinel.tiff"),sentinel=Data([1,2,3]);try sentinel.write(to:target)
    do {_ = try await DevelopmentService().render(source:input,recipe:.init(adjustmentsV3:.init()),format:.tiff16,destination:target);XCTFail()}catch DevelopmentError.outputExists{}
    XCTAssertEqual(try Data(contentsOf:target),sentinel)
    do {_ = try await DevelopmentService().render(source:input,recipe:.init(adjustmentsV3:.init()),format:.tiff16,destination:root.appendingPathComponent("protected.tiff"),protectedURLs:[root]);XCTFail()}catch DevelopmentError.protectedDestination{}
    enum Expected:Error{case stop}
    let publication=root.appendingPathComponent("unpublished.tiff")
    do {_ = try await DevelopmentService().render(source:input,recipe:.init(adjustmentsV3:.init()),format:.tiff16,destination:publication,preparePublication:{stage,_,artifact in
      XCTAssertTrue(FileManager.default.fileExists(atPath:stage.path));XCTAssertEqual(artifact.bitDepth,16);throw Expected.stop
    });XCTFail()}catch Expected.stop{}
    XCTAssertFalse(FileManager.default.fileExists(atPath:publication.path))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".rawmaster-render-")})
  }
  func testPublicAlreadyCancelledTIFFDoesNotPublish() async throws {
    let root=try directory(),input=try source(root,[[111,222,333]],width:1,height:1)
    let gate=DispatchSemaphore(value:0),target=root.appendingPathComponent("cancelled.tiff")
    let task=Task.detached {
      gate.wait()
      return try await DevelopmentService().render(source:input,recipe:.init(adjustmentsV3:.init()),format:.tiff16,destination:target)
    }
    task.cancel();gate.signal()
    do {_ = try await task.value;XCTFail("cancelled render published")}catch is CancellationError{}catch{XCTFail("\(error)")}
    XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".rawmaster-render-")})
  }
}
