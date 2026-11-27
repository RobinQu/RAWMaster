import XCTest
import CoreImage
import ImageIO
import CryptoKit
import Metal
import RAWMasterCore
import RAWMasterImage
@testable import RAWMasterImaging

final class DevelopmentPhotoFilterEngineV3Tests:XCTestCase {
  private let width=16,height=12
  private func sha(_ path:URL)throws->String {
    let f=try FileHandle(forReadingFrom:path);defer{try? f.close()};var digest=SHA256()
    while let data=try f.read(upToCount:65536),!data.isEmpty{digest.update(data:data)}
    return digest.finalize().map{String(format:"%02x",$0)}.joined()
  }
  private func value(_ percent:Int,_ r:Int,_ g:Int,_ b:Int)->SIMD4<Float> {
    let scale=Float(percent)/100*0.04
    let x=Float(DevelopmentPhotoFilterEngineV3.axis(r)),y=Float(DevelopmentPhotoFilterEngineV3.axis(g)),z=Float(DevelopmentPhotoFilterEngineV3.axis(b))
    return .init((x-0.5)*scale,(0.5-y)*scale,(z-x)*scale,1)
  }
  private func fixture(look:DevelopmentPhotoFilterV3 = .vivid)throws->URL {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-filter-tests-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    var planes=[DevelopmentPhotoFilterPayload]()
    for percent in DevelopmentPhotoFilterCatalog.intensities {
      let filename=DevelopmentPhotoFilterCatalog.filename(look,percent),url=root.appendingPathComponent(filename)
      FileManager.default.createFile(atPath:url.path,contents:nil)
      let f=try FileHandle(forWritingTo:url)
      var row=[SIMD4<Float>](repeating:.zero,count:4096)
      for start in stride(from:0,to:64*64*64,by:4096) {
        for i in 0..<4096{let n=start+i;row[i]=value(percent,n%64,(n/64)%64,n/4096)}
        try f.write(contentsOf:row.withUnsafeBytes{Data($0)})
      }
      try f.synchronize();try f.close()
      planes.append(.init(intensityPercent:percent,file:filename,byteCount:4194304,sha256:try sha(url)))
    }
    let catalog=DevelopmentPhotoFilterCatalog(schemaVersion:1,operatorVersion:DevelopmentPhotoFilterEngineV3.operatorVersion,
      representation:"linear-delta64-rgba32f-v1",cubeDimension:64,atlasWidth:512,atlasHeight:512,
      axisCodes:(0..<64).map{UInt16((65535*$0+31)/63)},inputICCsha256:DevelopmentPhotoFilterCatalog.icc,
      alphaPolicy:"source-alpha-preserved/lowalpha-1over65535-bypass",hdrPolicy:"boundary-residual-mono-noir-endpoint-v2",
      sourceBindingsSHA256:String(repeating:"a",count:64),builderSHA256:String(repeating:"b",count:64),looks:[.init(id:look,planes:planes)])
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    try encoder.encode(catalog).write(to:root.appendingPathComponent("catalog-v1.json"))
    return root
  }
  private func image(_ pixels:[SIMD4<Float>],width:Int,height:Int)->CIImage {
    .init(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func context()->CIContext{CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])}
  private func read(_ graph:CIImage,context:CIContext)throws->[SIMD4<Float>] {
    var result=[SIMD4<Float>]()
    try DevelopmentLocalEngineV3.read(graph,rect:graph.extent,context:context){result=Array($0)};return result
  }
  private func pixels()->[SIMD4<Float>] {
    let row:[SIMD4<Float>]=[.init(0.2,0.3,0.4,1),.init(0.1,0.15,0.05,0.5),.init(2,-0.2,0.4,1),.init(0,0,0,0),
      .init(0.0000004,-0.0000002,0.0000001,0.000001),.init(0.97,0.1,0.7,1),.init(0,1,0.5,1),.init(-0.1,1.4,0,1)]
    return (0..<(width*height)).map{row[$0%row.count]}
  }
  func testDefaultClosedFactsAndOffOriginalZeroAreObjectIdentityWithStrictValueValidation()throws {
    let store=DevelopmentPhotoFilterResourceStore(resourceRoot:nil)
    XCTAssertEqual(store.capabilities().filters,[.original]);XCTAssertNil(store.capabilities().resourceVersion)
    let source=image(pixels(),width:width,height:height)
    for f in [DevelopmentFilterV3(),.init(enabled:true,selection:.original,intensity:73),.init(enabled:false,selection:.noir,intensity:100),.init(enabled:true,selection:.vivid,intensity:0)] {
      XCTAssertTrue(try DevelopmentPhotoFilterEngineV3.apply(f,to:source,resources:store) === source)
    }
    XCTAssertThrowsError(try DevelopmentPhotoFilterEngineV3.apply(.init(enabled:true,selection:.vivid),to:source,resources:store))
    XCTAssertThrowsError(try DevelopmentPhotoFilterEngineV3.apply(.init(enabled:false,selection:.original,intensity:.nan),to:source,resources:store))
    let binding=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:16,orientedHeight:12)
    let facts=DevelopmentSourceFacts(sourceBinding:binding,sourceGeneration:1,sourceKind:.image,decoderVersion:"test",noiseReduction:.init(sourceCapability:.image,raw:nil),asShotWhiteBalance:nil,implementedAdjustments:[])
    XCTAssertEqual(facts.supportedPhotoFilters,[.original]);XCTAssertNil(facts.photoFilterResourceVersion)
  }
  func testResourceCapabilitiesRequireAllFourValidPayloadsAndClosedCatalog()throws {
    let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root)
    XCTAssertEqual(store.capabilities().filters,[.original,.vivid]);XCTAssertNotNil(store.capabilities().resourceVersion)
    try FileManager.default.removeItem(at:root.appendingPathComponent(DevelopmentPhotoFilterCatalog.filename(.vivid,25)))
    XCTAssertEqual(store.capabilities().filters,[.original]);XCTAssertNil(store.capabilities().resourceVersion)
    let url=root.appendingPathComponent("catalog-v1.json")
    var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]);json["unknown"]=1
    try JSONSerialization.data(withJSONObject:json).write(to:url)
    XCTAssertEqual(DevelopmentPhotoFilterResourceStore(resourceRoot:root).capabilities().filters,[.original])
    XCTAssertThrowsError(try DevelopmentPhotoFilterCatalog.decode(JSONSerialization.data(withJSONObject:json)))
  }
  func testFreshChecksumConsistentButInvalidFloatOrAlphaPayloadIsNotAdvertised()throws {
    for (offset,bits) in [(0,UInt32(0x7fc00000)),(12,UInt32(0))] {
      let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
      let file=root.appendingPathComponent(DevelopmentPhotoFilterCatalog.filename(.vivid,1))
      let f=try FileHandle(forWritingTo:file);try f.seek(toOffset:UInt64(offset))
      var little=bits.littleEndian;try f.write(contentsOf:withUnsafeBytes(of:&little){Data($0)});try f.close()
      let catalogURL=root.appendingPathComponent("catalog-v1.json")
      var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:catalogURL)) as? [String:Any])
      var looks=try XCTUnwrap(object["looks"] as? [[String:Any]])
      var planes=try XCTUnwrap(looks[0]["planes"] as? [[String:Any]])
      planes[0]["sha256"]=try sha(file);looks[0]["planes"]=planes;object["looks"]=looks
      try JSONSerialization.data(withJSONObject:object).write(to:catalogURL)
      let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root)
      XCTAssertEqual(store.capabilities().filters,[.original]);XCTAssertNil(store.capabilities().resourceVersion)
    }
  }
  func testActualGPUManualCubeAndAllStrengthBracketsMatchActualFloatNodesAlphaAndHDR()throws {
    let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root),context=context();defer{store.trimReady();context.clearCaches()}
    let input=pixels(),source=image(input,width:width,height:height)
    for intensity in [0.5,1,13,25,37,50,61,88,100] as [Double] {
      let graph=try DevelopmentPhotoFilterEngineV3.apply(.init(enabled:true,selection:.vivid,intensity:intensity),to:source,resources:store)
      let actual=try read(graph,context:context)
      for i in input.indices {
        let p=input[i],d=SIMD4<Double>(Double(p.x),Double(p.y),Double(p.z),Double(p.w))
        let expected=try DevelopmentPhotoFilterEngineV3.reference(d,intensity:intensity){percent,r,g,b in
          let n=self.value(percent,r,g,b);return .init(Double(n.x),Double(n.y),Double(n.z))
        }
        XCTAssertEqual(actual[i].w.bitPattern,p.w.bitPattern)
        if p.w<DevelopmentPhotoFilterEngineV3.alphaMinimum{XCTAssertEqual(actual[i],p)}
        for c in 0..<3{XCTAssertEqual(Double(actual[i][c]),expected[c],accuracy:2e-4)}
      }
      XCTAssertGreaterThan(actual[2].x,1);XCTAssertLessThan(actual[2].y,0)
    }
  }
  func testRAWTransportRepairAcceptsOnlyMeasuredOneToThreeULPWhenExplicitlyEnabled()throws {
    let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root),context=context();defer{store.trimReady();context.clearCaches()}
    let filter=DevelopmentFilterV3(enabled:true,selection:.vivid,intensity:37)
    let expected=try DevelopmentPhotoFilterEngineV3.reference(.init(0.2,0.3,0.4,1),intensity:37){percent,r,g,b in
      let n=self.value(percent,r,g,b);return .init(Double(n.x),Double(n.y),Double(n.z))
    }
    for bits in UInt32(0x3f800001)...0x3f800003 {
      let source=image([.init(0.2,0.3,0.4,Float(bitPattern:bits))],width:1,height:1)
      let repaired=try DevelopmentPhotoFilterEngineV3.apply(filter,to:source,resources:store,repairRAWTransportAlpha:true)
      let actual=try read(repaired,context:context)[0]
      XCTAssertEqual(actual.w,1)
      for c in 0..<3{XCTAssertEqual(Double(actual[c]),expected[c],accuracy:2e-4)}
      let ordinary=try DevelopmentPhotoFilterEngineV3.apply(filter,to:source,resources:store)
      XCTAssertThrowsError(try read(ordinary,context:context))
    }
    for alpha in [Float(bitPattern:0x3f800004),-0.01,.infinity,.nan] {
      let invalid=image([.init(0.2,0.3,0.4,alpha)],width:1,height:1)
      let graph=try DevelopmentPhotoFilterEngineV3.apply(filter,to:invalid,resources:store,repairRAWTransportAlpha:true)
      XCTAssertThrowsError(try read(graph,context:context))
    }
  }
  func testActualAtlasNodeAddressesPinCrossRowAndCubeBoundaries()throws {
    let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root),context=context();defer{store.trimReady();context.clearCaches()}
    let pair=try store.pair(.init(enabled:true,selection:.vivid,intensity:100))
    let shader=try RAWMasterImageKernel.source(.photoFilter) + #"""
    extern "C" { namespace coreimage {
    [[stitchable]] float4 rmFilterNodeProbe(sampler table,float4 node,destination dest){return float4(rmFilterNodeV1(table,int3(node.xyz)),1);}
    } }
    """#
    let kernel=try XCTUnwrap(CIKernel.kernels(withMetalString:shader).first(where:{$0.name=="rmFilterNodeProbe"}))
    for n in [0,1,63,64,4095,4096,262143] {
      let r=n%64,g=(n/64)%64,b=n/4096,one=CGRect(x:0,y:0,width:1,height:1)
      let graph=try XCTUnwrap(kernel.apply(extent:one,roiCallback:{_,_ in pair.lower.image.extent},arguments:[pair.lower.image.samplingNearest(),CIVector(x:CGFloat(r),y:CGFloat(g),z:CGFloat(b),w:0)]))
      XCTAssertEqual(try read(graph,context:context)[0],value(100,r,g,b))
    }
  }
  func testFilterAloneWholeTilesAndEXIFKeepGlobalCoordinates()throws {
    let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root),context=context();defer{store.trimReady();context.clearCaches()}
    let source=image(pixels(),width:width,height:height),parameters=DevelopmentFilterV3(enabled:true,selection:.vivid,intensity:37)
    let output=try DevelopmentPhotoFilterEngineV3.apply(parameters,to:source,resources:store),whole=try read(output,context:context)
    for y in stride(from:0,to:height,by:5){for x in stride(from:0,to:width,by:7){
      let w=min(7,width-x),h=min(5,height-y)
      try DevelopmentLocalEngineV3.read(output,rect:.init(x:x,y:height-y-h,width:w,height:h),context:context){p in
        for row in 0..<h{for column in 0..<w{for c in 0..<4{XCTAssertEqual(p[row*w+column][c],whole[(y+row)*width+x+column][c],accuracy:2e-6)}}}
      }
    }}
    for orientation in [CGImagePropertyOrientation.right,.left]{
      let a=try read(DevelopmentPhotoFilterEngineV3.apply(parameters,to:source.oriented(orientation),resources:store),context:context)
      let b=try read(output.oriented(orientation),context:context)
      for i in a.indices{for c in 0..<4{XCTAssertEqual(a[i][c],b[i][c],accuracy:2e-4)}}
    }
  }
  func testRetiringRealCIImageAliasKeepsActualBackingChargeUntilJoinedAndReleased()throws {
    let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let baseline=DevelopmentPhotoFilterCharge.snapshot().union
    try autoreleasepool {
      let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root),context=context()
      var graph:CIImage?=try DevelopmentPhotoFilterEngineV3.apply(.init(enabled:true,selection:.vivid,intensity:37),to:image(pixels(),width:width,height:height),resources:store)
      store.trimReady()
      XCTAssertGreaterThan(DevelopmentPhotoFilterCharge.snapshot().retiring,0)
      _=try read(try XCTUnwrap(graph),context:context) // public checked task actually joins.
      XCTAssertGreaterThan(DevelopmentPhotoFilterCharge.snapshot().union,baseline)
      graph=nil;context.clearCaches()
    }
    XCTAssertEqual(DevelopmentPhotoFilterCharge.snapshot().union,baseline)
  }
  func testPendingActualMetalCommandKeepsRetiringBackingUntilNativeCompletion()throws {
    let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let baseline=DevelopmentPhotoFilterCharge.snapshot().union
    try autoreleasepool {
      let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
      let queue=try XCTUnwrap(device.makeCommandQueue()),event=try XCTUnwrap(device.makeSharedEvent())
      let command=try XCTUnwrap(queue.makeCommandBuffer())
      let destination=try XCTUnwrap(device.makeBuffer(length:16,options:.storageModeShared))
      defer{event.signaledValue=1;command.waitUntilCompleted()}
      let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root,device:device)
      var pair:DevelopmentPhotoFilterResourceStore.Pair?=try store.pair(.init(enabled:true,selection:.vivid,intensity:100))
      XCTAssertEqual(pair?.lower.bytes, DevelopmentPhotoFilterCatalog.payloadBytes)
      XCTAssertEqual(pair?.lower.buffer.length, DevelopmentPhotoFilterCatalog.payloadBytes)
      command.encodeWaitForEvent(event,value:1)
      let blit=try XCTUnwrap(command.makeBlitCommandEncoder())
      blit.copy(from:pair!.lower.buffer,sourceOffset:0,to:destination,destinationOffset:0,size:16)
      blit.endEncoding();command.commit()
      store.trimReady();pair=nil
      XCTAssertNotEqual(command.status,.completed)
      XCTAssertGreaterThan(DevelopmentPhotoFilterCharge.snapshot().retiring,0)
      event.signaledValue=1;command.waitUntilCompleted()
      XCTAssertEqual(command.status,.completed)
    }
    XCTAssertEqual(DevelopmentPhotoFilterCharge.snapshot().union,baseline)
  }
  func testBudgetUnavailableIsTypedAndDoesNotWaitForCallersOwnOutstandingGraph()throws {
    let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let baseline=DevelopmentPhotoFilterCharge.snapshot().union
    // Other filter tests can already hold verified LUTs in the process-wide cache.
    let reserveBytes = max(0, DevelopmentPhotoFilterCharge.maximumBytes - baseline - 1024 * 1024)
    try autoreleasepool {
      let reservation = reserveBytes > 0 ? try DevelopmentPhotoFilterCharge(bytes: reserveBytes, state: .active) : nil
      let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root)
      try withExtendedLifetime(reservation) {
        XCTAssertEqual(store.capabilities().filters,[.original,.vivid])
        XCTAssertThrowsError(try store.pair(.init(enabled:true,selection:.vivid,intensity:37))){XCTAssertEqual($0 as? DevelopmentPhotoFilterError,.budgetUnavailable)}
        XCTAssertEqual(DevelopmentPhotoFilterCharge.snapshot().union,baseline+reserveBytes)
      }
      store.trimReady()
    }
    XCTAssertEqual(DevelopmentPhotoFilterCharge.snapshot().union,baseline)
  }
  func testOutsideCubeMonochromeContractPureAndCubeIsBitwiseUnchanged()throws {
    let samples:[SIMD4<Double>]=[.init(2,0.5,0.5,1),.init(-0.2,0.4,1.4,1),.init(0.1,0.25,0.2,0.5)]
    for look in [DevelopmentPhotoFilterV3.mono,.noir,.vivid,.silvertone] {
      for amount in [0.0,37,100] {
        for p in samples {
          let result=try DevelopmentPhotoFilterEngineV3.reference(p,intensity:amount,selection:look){percent,r,g,b in
            let v=self.value(percent,r,g,b);return .init(Double(v.x),Double(v.y),Double(v.z))
          }
          let baseline=try DevelopmentPhotoFilterEngineV3.reference(p,intensity:amount,selection:.vivid){percent,r,g,b in
            let v=self.value(percent,r,g,b);return .init(Double(v.x),Double(v.y),Double(v.z))
          }
          let u=SIMD3(p.x,p.y,p.z)/p.w,outside=u.x<0 || u.y<0 || u.z<0 || u.x>1 || u.y>1 || u.z>1
          if amount==0 || !outside || look == .vivid || look == .silvertone {XCTAssertEqual(result,baseline)}
          if outside && amount==100 && (look == .mono || look == .noir) {XCTAssertEqual(result.x,result.y);XCTAssertEqual(result.y,result.z)}
          XCTAssertEqual(result.w,p.w)
        }
      }
    }
  }
  func testActualGPUOutsideCubeMonoNoirEndpointGrayAndOtherLooksAndCubeUnchanged()throws {
    let input:[SIMD4<Float>]=[.init(2,0.5,0.5,1),.init(-0.2,0.4,1.4,1),.init(0.1,0.25,0.2,0.5),.init(0,0,0,0),.init(0.0000004,-0.0000002,0.0000001,0.000001)]
    for look in [DevelopmentPhotoFilterV3.mono,.noir,.vivid,.silvertone] {
      let root=try fixture(look:look);defer{try? FileManager.default.removeItem(at:root)}
      try autoreleasepool {
        let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root),context=context();defer{store.trimReady();context.clearCaches()}
        let source=image(input,width:input.count,height:1)
        for amount: Double in [0,37,100] {
          let graph=try DevelopmentPhotoFilterEngineV3.apply(.init(enabled:true,selection:look,intensity:amount),to:source,resources:store)
          if amount==0{XCTAssertTrue(graph === source)}
          let actual=try read(graph,context:context)
          for i in input.indices {
            let p=input[i],d=SIMD4(Double(p.x),Double(p.y),Double(p.z),Double(p.w))
            let expected=try DevelopmentPhotoFilterEngineV3.reference(d,intensity:amount,selection:look){percent,r,g,b in
              let v=self.value(percent,r,g,b);return .init(Double(v.x),Double(v.y),Double(v.z))
            }
            for c in 0..<4{XCTAssertEqual(Double(actual[i][c]),expected[c],accuracy:2e-4)}
            XCTAssertEqual(actual[i].w.bitPattern,p.w.bitPattern)
            if i>=3{XCTAssertEqual(actual[i],p)}
            if i<2 && amount==100 && (look == .mono || look == .noir) {
              XCTAssertEqual(actual[i].x.bitPattern,actual[i].y.bitPattern);XCTAssertEqual(actual[i].y.bitPattern,actual[i].z.bitPattern)
            }
          }
          // Identical cube data withcolorflagoff must preserve this inside-cube pixel bit-for-bit.
          if amount != 0 {
            let pair=try store.pair(.init(enabled:true,selection:look,intensity:amount))
            let kernel=try XCTUnwrap(CIKernel.kernels(withMetalString:RAWMasterImageKernel.source(.photoFilter)).first(where:{$0.name=="rmPhotoFilterV1"}))
            let params=CIVector(x:CGFloat(pair.weight),y:pair.zeroLower ? 1:0,z:0,w:CGFloat(amount/100))
            let baseline=try XCTUnwrap(kernel.apply(extent:source.extent,roiCallback:{index,rect in index==0 ? rect:CGRect(x:0,y:0,width:512,height:512)},arguments:[source.samplingNearest(),pair.lower.image.samplingNearest(),pair.upper.image.samplingNearest(),params,CIVector(x:0,y:0,z:0,w:0)]))
            let color=try read(baseline,context:context)
            XCTAssertEqual(actual[2],color[2])
            if look == .vivid || look == .silvertone{XCTAssertEqual(actual,color)}
          }
        }
      }
    }
  }
  func testCorruptWarmPayloadRevokesLookCapabilityAndCannotReuseCachedTable()throws {
    let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let store=DevelopmentPhotoFilterResourceStore(resourceRoot:root)
    XCTAssertEqual(store.capabilities().filters,[.original,.vivid])
    var pair:DevelopmentPhotoFilterResourceStore.Pair?=try store.pair(.init(enabled:true,selection:.vivid,intensity:37))
    let file=root.appendingPathComponent(DevelopmentPhotoFilterCatalog.filename(.vivid,50))
    let handle=try FileHandle(forWritingTo:file);try handle.seek(toOffset:12)
    var wrong:UInt32=0;try handle.write(contentsOf:withUnsafeBytes(of:&wrong){Data($0)});try handle.close()
    XCTAssertEqual(store.capabilities().filters,[.original]);XCTAssertNil(store.capabilities().resourceVersion)
    XCTAssertThrowsError(try store.validate(.init(enabled:true,selection:.vivid,intensity:37)))
    withExtendedLifetime(pair){};pair=nil;store.trimReady()
  }
}
