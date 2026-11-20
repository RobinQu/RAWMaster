import CoreImage
import Foundation
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentBrillianceNativeRGV1Tests:XCTestCase {
  private func image(_ width:Int,_ height:Int,pairs:Bool=false)->CIImage {
    let pixels=(0..<width*height).map { i -> SIMD4<Float> in
      let x=Float(i%width)/Float(width),y=Float(i/width)/Float(height)
      if pairs{return .init(x,y,0,1)}
      let a:Float=i%7==0 ? 0:(i%5==0 ? 0.3:1)
      if a==0{return .init(-0.1,0.2,1.3,0)}
      return .init((1.5*x-0.2)*a,(0.9*y+0.1)*a,(1.1*(x+y)-0.1)*a,a)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:width*16,
      size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func pixels(_ image:CIImage,_ context:CIContext)throws->[SIMD4<Float>] {
    let e=image.extent,w=Int(e.width),h=Int(e.height)
    var values=Array(repeating:SIMD4<Float>.zero,count:w*h),seen=0
    for y in stride(from:0,to:h,by:512){for x in stride(from:0,to:w,by:512){
      let tw=min(512,w-x),th=min(512,h-y),top=h-y-th
      try DevelopmentLocalEngineV3.read(image,rect:.init(x:e.minX+CGFloat(x),y:e.minY+CGFloat(y),width:CGFloat(tw),height:CGFloat(th)),context:context){tile in
        for r in 0..<th {for c in 0..<tw {values[(top+r)*w+x+c]=tile[r*tw+c]}}
        seen+=tile.count
      }
    }}
    XCTAssertEqual(seen,w*h);return values
  }
  func testRGfBothChannelsBitExactOrientationImplicitBAAnd64Tail()throws {
    for (w,h) in [(257,193),(193,257),(2051,1027)] {
      let source=image(w,h,pairs:true),context=DevelopmentBrillianceAdaptiveV1.makeContext()
      let reference=try pixels(source,context);context.clearCaches()
      var path:URL?
      let actual=try DevelopmentDehazeNativeResources.run {
        let owner=try XCTUnwrap(DevelopmentDehazeNativeResources.current)
        let scratch=try DehazeRfScratchV1(nativeWidth:w,height:h,components:2);path=scratch.directory
        XCTAssertEqual(scratch.planeBytes,w*h*8)
        let lease=owner.add(scratch);owner.register(context)
        let scope=PreviewPresentationScope();defer{scope.closeAndRetire()}
        let request=DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:{})
        if w>1024 {
          try DevelopmentDehazeRfTransportV1.file(scratch:scratch,context:context,request:request,
            bandRows:1024,tileWidth:1024,makeGraph:{source})
        } else {
          try DevelopmentDehazeRfTransportV1.file(source,scratch:scratch,context:context,request:request,bandRows:64)
        }
        let provider=try DehazeRfProviderV1(scratch,state:lease.state,onRelease:{lease.providerReleased()})
        lease.provider=provider
        return try pixels(provider.image(),context)
      }
      XCTAssertEqual(actual,reference,"All native r/g and implicit b=0,a=1 must be identical")
      XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(path).path))
    }
  }
  func testFactoryRetiresEachJoinedBandPreservesFailureAndRejectsEscapingGraph()throws {
    enum Stop:Error{case secondFactory}
    let source=image(257,193,pairs:true)
    for scenario in 0...2 {
      var path:URL?,escaped:CIImage?
      weak var witness:CIImage?
      var calls=0,joined=0,retired=0
      let operation = {
        try DevelopmentDehazeNativeResources.run {
          let owner=try XCTUnwrap(DevelopmentDehazeNativeResources.current)
          let scratch=try DehazeRfScratchV1(nativeWidth:257,height:193,components:2);path=scratch.directory
          _=owner.add(scratch)
          let context=DevelopmentBrillianceAdaptiveV1.makeContext();defer{context.clearCaches()}
          let scope=PreviewPresentationScope();defer{scope.closeAndRetire()}
          var request=DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:{})
          request.observer={phase in if phase == .scalarJoined{joined+=1}}
          try DevelopmentDehazeRfTransportV1.file(scratch:scratch,context:context,request:request,bandRows:64,makeGraph:{
            XCTAssertNil(witness,"The previous factory graph must retire before the next band")
            calls+=1
            if scenario==1 && calls==2{throw Stop.secondFactory}
            let graph=source.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0.75])
            witness=graph
            if scenario==2{escaped=graph}
            return graph
          },requireBandRetired:{
            guard witness==nil else{throw PreviewPresentationError.allocationProtocol}
            retired+=1
          })
          try scratch.requirePlane()
        }
      }
      if scenario==0{try operation();XCTAssertEqual(calls,4);XCTAssertEqual(joined,4);XCTAssertEqual(retired,4)}
      else {
        XCTAssertThrowsError(try operation()){error in
          if scenario==1{XCTAssertTrue(error is Stop)}
          else{XCTAssertEqual(error as? PreviewPresentationError,.allocationProtocol)}
        }
        XCTAssertEqual(calls,scenario==1 ? 2:1);XCTAssertEqual(joined,1)
      }
      if scenario==2{XCTAssertNotNil(escaped)}
      escaped=nil
      XCTAssertNil(witness)
      XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(path).path))
    }
  }
  func testContextFactoryRetiresBeforeNextTileAndPreservesFactoryOrRenderFailure()throws {
    enum Stop:Error,Equatable{case factory,render}
    let source=image(257,513,pairs:true)
    for scenario in 0...2 {
      var path:URL?,calls=0,retirementChecks=0
      weak var previous:CIContext?
      let operation = {
        try DevelopmentDehazeNativeResources.run {
          let owner=try XCTUnwrap(DevelopmentDehazeNativeResources.current)
          let scratch=try DehazeRfScratchV1(nativeWidth:257,height:513,components:2);path=scratch.directory
          _=owner.add(scratch)
          let scope=PreviewPresentationScope();defer{scope.closeAndRetire()}
          var request=DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:{})
          request.observer={phase in if scenario==2 && phase == .scalarSubmitted{throw Stop.render}}
          try DevelopmentDehazeRfTransportV1.file(scratch:scratch,request:request,makeContext:{
            guard previous==nil else{XCTFail("Previous context survived until next tile");throw PreviewPresentationError.allocationProtocol}
            calls+=1;if scenario==1 && calls==2{throw Stop.factory}
            let context=DevelopmentBrillianceAdaptiveV1.makeContext();previous=context;return context
          },makeGraph:{source},requireBandRetired:{
            guard previous==nil else{XCTFail("Context survived joined tile pool");throw PreviewPresentationError.allocationProtocol}
            retirementChecks+=1
          })
          try scratch.requirePlane()
        }
      }
      if scenario==0{try operation();XCTAssertEqual(calls,3);XCTAssertEqual(retirementChecks,3)}
      else {
        XCTAssertThrowsError(try operation()){error in XCTAssertEqual(error as? Stop,scenario==1 ? .factory:.render)}
        XCTAssertEqual(calls,scenario==1 ? 2:1);XCTAssertEqual(retirementChecks,calls)
      }
      XCTAssertNil(previous)
      XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(path).path))
    }
  }
  func testFullAdaptivePolyAlphaHDRAndRemainingSHHLParityAllSignedStrengths()throws {
    for (w,h) in [(257,193),(193,257)] {
      let source=image(w,h)
      XCTAssertTrue(DevelopmentBrillianceAdaptiveV1.nativeGraphSupported(source.extent))
      for amount in [-2.0,-0.5,-0.01,0.01,0.5,2] {
        var light=DevelopmentLightV3();light.enabled=true;light.brilliance=amount;light.brillianceVersion = .adaptiveLocalV1
        light.shadows=0.2;light.highlights = -0.1;light.contrast=0.1
        func output(_ bounded:Bool,sourceIsRAW:Bool=false)throws->[SIMD4<Float>] {
          let body = { ()throws->[SIMD4<Float>] in
            let context=DevelopmentBrillianceAdaptiveV1.makeContext();defer{context.clearCaches()}
            var graph=try DevelopmentBrillianceAdaptiveV1.apply(light,to:source,sourceIsRAW:sourceIsRAW,context:context)
            var remaining=light;remaining.brilliance=0
            graph=try DevelopmentSpatialEngineV3.applyLight(remaining,to:graph)
            var parameters=DevelopmentAdjustmentsV3();parameters.light=light;parameters.color.enabled=true;parameters.color.saturation=0.1
            graph=try DevelopmentColorEngineV3.applyPointwise(parameters,to:graph,context:context)
            return try self.pixels(graph,context)
          }
          if !bounded {
            XCTAssertNil(DevelopmentDehazeNativeResources.current,"The reference must be the original unowned tiled graph")
            return try autoreleasepool(invoking:body)
          }
          var providerReady=0,path:URL?
          let result=try DevelopmentDehazeNativeResources.run(owner:.init(observer:{phase,url in
            path=url;if phase == .providerReady{providerReady+=1}
          }),body)
          XCTAssertEqual(providerReady,1,"Both RAW and rendered candidates must actually use the native RGf provider")
          XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(path).path))
          return result
        }
        let expected=try output(false)
        for isRAW in [false,true] {
          let actual=try output(true,sourceIsRAW:isRAW)
          XCTAssertEqual(expected.count,actual.count)
          var difference:Float=0;var alphaMismatch=false
          for i in expected.indices {
            guard (0..<4).allSatisfy({expected[i][$0].isFinite && actual[i][$0].isFinite}) else {
              XCTFail("Nonfinite full-graph parity pixel \(i)")
              throw DevelopmentError.invalidEncoding
            }
            alphaMismatch = alphaMismatch || expected[i].w.bitPattern != actual[i].w.bitPattern
            for c in 0..<3 {difference=max(difference,abs(expected[i][c]-actual[i][c]))}
          }
          XCTAssertFalse(alphaMismatch);XCTAssertLessThanOrEqual(difference,3e-5,"native RGf \(w)x\(h) strength \(amount) RAW \(isRAW)")
        }
      }
    }
  }
  func testNative1024TilesMatchOriginalAcrossBothAxesAndPartialTails()throws {
    let source=image(2051,1027)
    for amount in [-0.5,0.5] {
      var light=DevelopmentLightV3();light.enabled=true;light.brilliance=amount;light.brillianceVersion = .adaptiveLocalV1
      light.shadows=0.2;light.highlights = -0.1;light.contrast=0.1
      func output(_ ownedRAW:Bool?)throws->[SIMD4<Float>] {
        let body = { ()throws->[SIMD4<Float>] in
          let context=DevelopmentBrillianceAdaptiveV1.makeContext();defer{context.clearCaches()}
          var graph=try DevelopmentBrillianceAdaptiveV1.apply(light,to:source,sourceIsRAW:ownedRAW ?? false,context:context)
          var remaining=light;remaining.brilliance=0
          graph=try DevelopmentSpatialEngineV3.applyLight(remaining,to:graph)
          var parameters=DevelopmentAdjustmentsV3();parameters.light=light;parameters.color.enabled=true;parameters.color.saturation=0.1
          graph=try DevelopmentColorEngineV3.applyPointwise(parameters,to:graph,context:context)
          return try self.pixels(graph,context)
        }
        guard let _=ownedRAW else {
          XCTAssertNil(DevelopmentDehazeNativeResources.current)
          return try autoreleasepool(invoking:body)
        }
        var path:URL?,joined=0,providers=0
        let result=try DevelopmentDehazeNativeResources.run(owner:.init(observer:{phase,url in
          path=url;if phase == .scalarJoined{joined+=1};if phase == .providerReady{providers+=1}
        }),body)
        XCTAssertEqual(joined,6,"Three native columns by two rows, including x/y tails")
        XCTAssertEqual(providers,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(path).path))
        return result
      }
      let expected=try output(nil)
      for raw in [false,true] {
        let actual=try output(raw);XCTAssertEqual(actual.count,2051*1027)
        var maximum:Float=0;var alphaMismatch=false
        for i in expected.indices {
          guard (0..<4).allSatisfy({expected[i][$0].isFinite && actual[i][$0].isFinite}) else {
            XCTFail("Nonfinite native tile pixel \(i)");throw DevelopmentError.invalidEncoding
          }
          alphaMismatch = alphaMismatch || actual[i].w.bitPattern != expected[i].w.bitPattern
          for c in 0..<3{maximum=max(maximum,abs(actual[i][c]-expected[i][c]))}
        }
        XCTAssertFalse(alphaMismatch)
        XCTAssertLessThanOrEqual(maximum,3e-5,"Every2051x1027 pixel across global1024 edges and partial tails; RAW \(raw), strength \(amount)")
      }
    }
  }
  func testZeroOldVersionsUnownedAndOverBudgetKeepOldDomain()throws {
    let source=image(257,193);var light=DevelopmentLightV3();light.enabled=true;light.brillianceVersion = .adaptiveLocalV1
    var calls=0
    try DevelopmentDehazeNativeResources.run(owner:.init(observer:{_,_ in calls+=1})){
      for isRAW in [false,true] {
        XCTAssertTrue(try DevelopmentBrillianceAdaptiveV1.apply(light,to:source,sourceIsRAW:isRAW) === source)
        for version in [nil,DevelopmentBrillianceVersion.publicTiledJointFixed050V1] {
          var historical=light;historical.brilliance=0.5;historical.brillianceVersion=version
          XCTAssertTrue(try DevelopmentBrillianceAdaptiveV1.apply(historical,to:source,sourceIsRAW:isRAW) === source)
          XCTAssertEqual(DevelopmentBrillianceNativeRGV1.keySuffix(historical,sourceIsRAW:isRAW),"")
        }
      }
    }
    XCTAssertEqual(calls,0)
    XCTAssertTrue(DevelopmentBrillianceNativeRGV1.supports(.init(x:0,y:0,width:5760,height:8640)))
    XCTAssertTrue(DevelopmentBrillianceNativeRGV1.supports(.init(x:0,y:0,width:9504,height:6336)))
    XCTAssertFalse(DevelopmentBrillianceNativeRGV1.supports(.init(x:0,y:0,width:9504,height:9504)))
    XCTAssertFalse(DevelopmentBrillianceNativeRGV1.supports(.init(x:1,y:0,width:257,height:193)))
    XCTAssertFalse(DevelopmentBrillianceNativeRGV1.supports(.infinite))
    light.brilliance=0.5
    XCTAssertEqual(DevelopmentBrillianceNativeRGV1.keySuffix(light,sourceIsRAW:false),"/"+DevelopmentBrillianceNativeRGV1.version)
    XCTAssertEqual(DevelopmentBrillianceNativeRGV1.keySuffix(light,sourceIsRAW:true),"/"+DevelopmentBrillianceNativeRGV1.version)
    let context=DevelopmentBrillianceAdaptiveV1.makeContext()
    XCTAssertEqual(try pixels(DevelopmentBrillianceAdaptiveV1.apply(light,to:source,sourceIsRAW:true),context),
      try pixels(DevelopmentBrillianceAdaptiveV1.apply(light,to:source),context))
  }
  func testRGProducerCancellationAndProviderFailureRemoveBothChannelFile()throws {
    let source=image(257,193);var light=DevelopmentLightV3();light.enabled=true;light.brilliance=0.5;light.brillianceVersion = .adaptiveLocalV1
    enum Stop:Error{case afterProvider}
    for stop in [DevelopmentDehazeNativeResources.Phase.scalarSubmitted,.providerReady] {
      var path:URL?
      XCTAssertThrowsError(try DevelopmentDehazeNativeResources.run(owner:.init(observer:{phase,url in
        path=url
        if phase==stop {if phase == .scalarSubmitted{throw CancellationError()};throw Stop.afterProvider}
      })){
        let context=DevelopmentBrillianceAdaptiveV1.makeContext();defer{context.clearCaches()}
        let result=try DevelopmentBrillianceAdaptiveV1.apply(light,to:source,sourceIsRAW:true,context:context)
        _=try pixels(result,context)
      })
      XCTAssertNotNil(path)
      if let path{XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))}
    }
  }
}
