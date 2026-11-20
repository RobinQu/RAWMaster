import XCTest
import Foundation
import AppKit
import CoreImage
import ImageIO
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

final class WholeHost4ColorQualificationTests:XCTestCase {
  private enum Stop:Error{case provenance(String),quality(String),layout(String)}
  private func sha(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private func json(_ value:Any,_ url:URL)throws{try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting);let h=try FileHandle(forWritingTo:url);try h.synchronize();try h.close()}
  func testOptInOneFixedOriginalCaseAgainstWholeHost4()throws{
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_HOST4_QC63"]=="1",let root=env["RAWMASTER_HOST4_QC63_OUTPUT"],let repository=env["RAWMASTER_HOST4_QC63_REPOSITORY"],let value=env["RAWMASTER_HOST4_QC63_INDEX"],let index=Int(value),(0..<63).contains(index)else{throw XCTSkip("Explicit RELEASE onecase host4 QC63 grant required")}
    #if DEBUG
    throw Stop.provenance("RELEASE -O required, DEBUG rejected")
    #endif
    let repo=URL(fileURLWithPath:repository),out=URL(fileURLWithPath:root).appendingPathComponent(String(format:"case-%02d",index));try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    guard !FileManager.default.fileExists(atPath:out.appendingPathComponent("receipt.json").path)else{throw Stop.provenance("nooverwrite")}
    let helperSHA=try RenderFiles.hash(URL(fileURLWithPath:#filePath)),safety=NativeTransportSafety();safety.start();defer{safety.stop()}
    var phases:[[String:Any]]=[],failure:String?,result:[String:Any]?,capture:URL?,native:PreviewNativeSource?
    func check(_ name:String)throws{safety.label(name);let current=safety.observe();phases.append(["label":name,"at":DispatchTime.now().uptimeNanoseconds,"footprint":current as Any? ?? NSNull()]);try Host4TrialContract.check(safety)}
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,nativeFillMode:.whole,observation:check)
    do{
      try check("before-admit")
      var physical:UInt64=0,size=MemoryLayout<UInt64>.size,pressure:Int32=0,pressureSize=MemoryLayout<Int32>.size
      guard sysctlbyname("hw.memsize",&physical,&size,nil,0)==0,physical==137_438_953_472,sysctlbyname("kern.memorystatus_vm_pressure_level",&pressure,&pressureSize,nil,0)==0,pressure==1 else{throw Stop.provenance("host128GiB/normalpressure")}
      let controlData=try Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/original-canonical-qc63-continuation/controls-manifest.json"));guard sha(controlData)=="33aecdb3fc1773856eaead055317854d59a4514dfa6b817564e19604e4ef1ace"else{throw Stop.provenance("controlmanifest")}
      let manifest=try JSONSerialization.jsonObject(with:controlData)as![String:Any],entries=manifest["selectedEntries"]as![[String:Any]],ledger=manifest["artifactSHA256"]as![String:String]
      guard entries.count==63,entries[index]["index"]as?Int==index else{throw Stop.provenance("fixedorder")};let entry=entries[index]
      func verified(_ url:URL)throws->Data{
        guard url.path.hasPrefix(repo.path+"/"),let expected=ledger[String(url.path.dropFirst(repo.path.count+1))]else{throw Stop.provenance("artifactnotinfrozenledger")}
        let data=try Data(contentsOf:url);guard sha(data)==expected else{throw Stop.provenance("actualartifactSHA "+url.lastPathComponent)};return data
      }
      let refMetaURL=URL(fileURLWithPath:entry["metadata"]as!String),refMeta=try JSONSerialization.jsonObject(with:verified(refMetaURL))as![String:Any]
      let recipeData=try verified(URL(fileURLWithPath:entry["recipeJSON"]as!String)),recipe=try JSONDecoder().decode(DevelopmentRecipe.self,from:recipeData);try recipe.validate()
      let fingerprint=try EditingFingerprint.of(recipe);guard fingerprint==entry["recipeFingerprint"]as?String else{throw Stop.provenance("actualrecipefingerprint")}
      let reference=try verified(URL(fileURLWithPath:entry["RGBA8"]as!String)),sourceID=entry["sourceID"]as!String,caseID=entry["caseID"]as!String,expectedSHA=entry["sourceSHA256"]as!String
      let snapshot=EditingSourceSnapshot(projectID:"020-QC63",assetID:sourceID,contentSHA256:expectedSHA,byteCount:(refMeta["sourceByteCount"]as!NSNumber).int64Value,admissionFingerprint:"frozen-020-reference",sourceLocation:URL(fileURLWithPath:refMeta["sourceLocation"]as!String))
      try check("before-actual-capture");let captured=try RenderFiles.capture(snapshot);capture=captured;let captureSHA=try RenderFiles.hash(captured);guard captureSHA==expectedSHA else{throw Stop.provenance("actualcaptureSHA")}
      native=try PreviewNativeSource(capture:captured,byteCount:snapshot.byteCount,artifact:false,memoryLimit:512)
      guard native!.hasRAWFilter,native!.decoder==refMeta["decoderVersion"]as?String else{throw Stop.provenance("actualdecoder/RAW")}
      let sourceNativeSize=native!.nativeSize
      let orientation:UInt32=try autoreleasepool{guard let f=CIRAWFilter(imageURL:captured)else{throw Stop.provenance("raworientation")};return f.orientation.rawValue}
      let naturalOrientation:Int?=autoreleasepool{guard let s=CGImageSourceCreateWithURL(captured as CFURL,nil),let p=CGImageSourceCopyPropertiesAtIndex(s,0,nil)as?[CFString:Any]else{return nil};return(p[kCGImagePropertyOrientation]as?NSNumber)?.intValue}
      let record=try pool.withWorker{try autoreleasepool{()throws->[String:Any]in
        try pool.checkpoint("before-actual-native-render");let start=DispatchTime.now().uptimeNanoseconds
        let pixels=try native!.render(recipe:recipe,maxPixel:2400,rawBasePool:pool,sourceKey:"verified:"+expectedSHA+":"+snapshot.admissionFingerprint)
        let APIElapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6;try pool.checkpoint("actual-render-joined")
        let stats=pool.statistics,neutral=recipe.color?.isNeutral != false
        guard stats.fills==(neutral ? 0:1),stats.hits==0 else{throw Stop.provenance("actualWHOLEfillcounts/no fallback/no neutralF32")}
        guard let cg=pixels.image.cgImage(forProposedRect:nil,context:nil,hints:nil)else{throw DevelopmentError.unreadable}
        let b=NSBitmapImageRep(cgImage:cg),w=b.pixelsWide,h=b.pixelsHigh
        guard w==entry["width"]as?Int,h==entry["height"]as?Int,pixels.outputSize==CGSize(width:w,height:h),!b.isPlanar,b.bitsPerSample==8,b.bitsPerPixel==32,b.samplesPerPixel==4,!b.bitmapFormat.contains(.alphaFirst),b.bytesPerRow>=w*4,let pointer=b.bitmapData else{throw Stop.layout("actualRGBA8shape/channel")}
        let refStride=(refMeta["rowBytesRGBA8"]as!NSNumber).intValue
        guard refStride>=w*4,reference.count==refStride*h,(refMeta["cgAlphaInfo"]as!NSNumber).intValue==1 else{throw Stop.layout("referenceRGBA8layout")}
        let canonical=refMeta["canonicalBounds"]as![Double],sourceBounds=refMeta["nativeBounds"]as![Double]
        guard pixels.nativeSize==CGSize(width:canonical[2],height:canonical[3]),sourceNativeSize==CGSize(width:sourceBounds[2],height:sourceBounds[3]),orientation==(refMeta["rawFilterOrientation"]as!NSNumber).uint32Value else{throw Stop.layout("actualcanonical/source-native/EXIF")}
        let icc=cg.colorSpace?.copyICCData()as Data?
        guard let icc,sha(icc)==refMeta["cgICCSHA256"]as?String,cg.colorSpace?.model == .rgb else{throw Stop.layout("actualICC/profile")}
        let actual=Data(bytes:pointer,count:b.bytesPerRow*h);try pool.checkpoint("actualbitmap-readback-complete")
        var gates:[[String:Any]]=[]
        for maskEntry in entry["masks"]as![[String:Any]]{
          let id=maskEntry["id"]as!String,maskURL=refMetaURL.deletingLastPathComponent().appendingPathComponent(maskEntry["file"]as!String),mask=try verified(maskURL)
          guard mask.count==w*h,sha(mask)==maskEntry["sha256"]as?String else{throw Stop.provenance("frozenmask")}
          let gate=try metrics(actual,reference,width:w,height:h,actualStride:b.bytesPerRow,referenceStride:refStride,mask:mask)
          guard gate["pixels"]as?Int==(maskEntry["pixels"]as!NSNumber).intValue else{throw Stop.layout("maskcoverage")}
          gates.append(["id":id,"actualMaskSHA256":sha(mask),"source":"frozenoriginalmask, not regenerated", "gate":gate])
          guard gate["pass"]as?Bool==true else{throw Stop.quality(id+" "+String(describing:gate))}
          try pool.checkpoint("mask-"+id+"-verified")
        }
        try pool.checkpoint("before-candidate-artifact-IO")
        let rawURL=out.appendingPathComponent("candidate.rgba8");try actual.write(to:rawURL,options:.withoutOverwriting);let raw=try FileHandle(forWritingTo:rawURL);try raw.synchronize();try raw.close()
        return["index":index,"sourceID":sourceID,"caseID":caseID,"sourceSHA256":expectedSHA,"capturedSHA256":captureSHA,"sourceBytes":snapshot.byteCount,"sourceLocation":snapshot.sourceLocation.path,"actualSourceNativeSize":[sourceNativeSize.width,sourceNativeSize.height],"canonicalPixelSize":[pixels.nativeSize.width,pixels.nativeSize.height],"outputPixelSize":[pixels.outputSize.width,pixels.outputSize.height],"encodedRasterCanvas":[0,0,w,h],"internalCITransformExtents":"notexposed by renderer; unknown, not copiedfromcontrol","actualDecoderVersion":native!.decoder,"actualRawFilterOrientation":orientation,"actualNaturalEXIFOrientation":naturalOrientation as Any? ?? NSNull(),"recipeFingerprint":fingerprint,"recipeSHA256":sha(recipeData),"nativeRenderAPIMilliseconds":APIElapsed,"neutralLegacyBypass":neutral,"actualRawBaseFills":stats.fills,"actualRawBaseHits":stats.hits,"rawBaseResidentBytes":stats.residentBytes,"rawBasePinnedBytes":stats.pinnedBytes,"width":w,"height":h,"bytesPerRow":b.bytesPerRow,"bitsPerPixel":b.bitsPerPixel,"bitsPerSample":b.bitsPerSample,"samplesPerPixel":b.samplesPerPixel,"bitmapFormat":b.bitmapFormat.rawValue,"isPlanar":b.isPlanar,"cgBitmapInfo":cg.bitmapInfo.rawValue,"cgAlphaInfo":cg.alphaInfo.rawValue,"cgColorSpaceName":cg.colorSpace?.name as String? ?? "missing","actualICCBytes":icc.count,"actualICCSHA256":sha(icc),"dataBytes":actual.count,"actualRGBA8SHA256":sha(actual),"masks":gates,"maskCount":gates.count,"highPrecisionEvidence":"originaltiny9/sharedF32/wholetransportkept; NO fakeRGBAf derivedfrom8bit"]
      }}
      try check("before-source-postverify");try RenderFiles.verify(snapshot);let postSHA=try RenderFiles.hash(snapshot.sourceLocation);guard postSHA==expectedSHA else{throw Stop.provenance("actualpostsource")}
      var complete=record;complete["reverifiedOriginalSHA256"]=postSHA;complete["sourceRecipeJSON"]=String(decoding:recipeData,as:UTF8.self)
      try check("before-provenance-IO");try recipeData.write(to:out.appendingPathComponent("recipe.json"),options:.withoutOverwriting);let rh=try FileHandle(forWritingTo:out.appendingPathComponent("recipe.json"));try rh.synchronize();try rh.close();try json(complete,out.appendingPathComponent("metadata.json"));result=complete
      try check("candidate-pixels-provenance-durable")
    }catch{failure=String(describing:error)}
    native?.context.clearCaches();native=nil;if let capture{try? FileManager.default.removeItem(at:capture.deletingLastPathComponent())}
    var drained = -1;do{let s=try pool.withWorker{try pool.drain()};drained=s.residentBytes+s.reservedBytes+s.buildingBytes+s.retiredBytes}catch{failure=failure ?? "drain:\(error)"}
    safety.label("joined-clear");_=safety.observe();Thread.sleep(forTimeInterval:0.5);safety.label("close-plus0.5s");_=safety.observe();Thread.sleep(forTimeInterval:1.5);safety.label("close-plus2s");_=safety.observe();safety.stop()
    let verdict=Host4TrialContract.verdict(safety,completePayload:result != nil && drained==0,failure:failure)
    try json(["index":index,"complete":verdict.complete,"failure":verdict.failure ?? "none","target3GiBPass":verdict.target3,"host4GiBPass":verdict.host4,"operationalAbort":safety.abortReason as Any? ?? NSNull(),"drainedOwnedBytes":drained,"metadata":result ?? [:],"phases":phases,"periodic":safety.report(),"helperSHA256":helperSHA,"controlsSHA256":"33aecdb3fc1773856eaead055317854d59a4514dfa6b817564e19604e4ef1ace","mode":"WHOLE","configuration":"RELEASE -O nofastmath","defaultCacheBytes":0],out.appendingPathComponent("receipt.json"))
    let fd=Darwin.open(out.path,O_RDONLY);guard fd>=0 else{throw CocoaError(.fileWriteUnknown)};let status=Darwin.fsync(fd);Darwin.close(fd);guard status==0 else{throw CocoaError(.fileWriteUnknown)}
    print("HOST4QC63 \(index) complete=\(verdict.complete) target3=\(verdict.target3) host4=\(verdict.host4) peakMiB=\(Double(safety.highWater)/1048576)");XCTAssertTrue(verdict.complete)
  }
  func testFrozenMaskMetricsKeepRGBASeparateAndMaximumGate()throws{
    var a=Data(repeating:0,count:400),b=Data(repeating:0,count:400),mask=Data(repeating:255,count:100)
    for p in 0..<100{a[p*4+3]=255;b[p*4+3]=255};a[0]=3
    let bad=try metrics(a,b,width:100,height:1,actualStride:400,referenceStride:400,mask:mask)
    XCTAssertFalse(bad["pass"]as!Bool);let rgba=bad["RGBA"]as![[String:Any]];XCTAssertEqual(rgba[0]["p99"]as?Double,0);XCTAssertEqual(rgba[0]["maximum"]as?Double,3);XCTAssertEqual(rgba[3]["maximum"]as?Double,0)
    mask[0]=0;let good=try metrics(a,b,width:100,height:1,actualStride:400,referenceStride:400,mask:mask);XCTAssertTrue(good["pass"]as!Bool);XCTAssertEqual(good["pixels"]as?Int,99)
    for p in 0..<100{a[p*4]=0;a[p*4+3]=128;b[p*4+3]=128};let alpha=try metrics(a,b,width:100,height:1,actualStride:400,referenceStride:400,mask:mask);XCTAssertTrue(alpha["pass"]as!Bool);XCTAssertFalse(alpha["bothFullyOpaque"]as!Bool)
  }
  private func metrics(_ actual:Data,_ reference:Data,width:Int,height:Int,actualStride:Int,referenceStride:Int,mask:Data)throws->[String:Any]{
    var hist=[[Int]](repeating:[Int](repeating:0,count:256),count:4),opaqueHist=[[Int]](repeating:[Int](repeating:0,count:256),count:3)
    var extra=[[[Double]]](repeating:[[Double]](repeating:[],count:3),count:3),n=0,opaque=0,positiveStraight=0
    actual.withUnsafeBytes{(a:UnsafeRawBufferPointer)in reference.withUnsafeBytes{(b:UnsafeRawBufferPointer)in mask.withUnsafeBytes{(m:UnsafeRawBufferPointer)in
      for y in 0..<height{for x in 0..<width where m[y*width+x] != 0{
        let p=y*actualStride+x*4,q=y*referenceStride+x*4;n+=1
        for c in 0..<4{hist[c][abs(Int(a[p+c])-Int(b[q+c]))]+=1}
        let aa=Double(a[p+3])/255,ba=Double(b[q+3])/255
        if a[p+3]==255 && b[q+3]==255{opaque+=1;positiveStraight+=1;for c in 0..<3{opaqueHist[c][abs(Int(a[p+c])-Int(b[q+c]))]+=1}}
        else{
          if aa>0 && ba>0{positiveStraight+=1}
          for c in 0..<3{
            let ar=aa>0 ? Double(a[p+c])/255/aa:0,br=ba>0 ? Double(b[q+c])/255/ba:0
            if aa>0 && ba>0{extra[0][c].append(abs(ar-br)*255)}
            let al=DevelopmentColorEngineV2.decode(ar)*aa,bl=DevelopmentColorEngineV2.decode(br)*ba
            for background in 0...1{let av=min(1,max(0,DevelopmentColorEngineV2.encode(al+Double(background)*(1-aa)))),bv=min(1,max(0,DevelopmentColorEngineV2.encode(bl+Double(background)*(1-ba))));extra[background+1][c].append(abs(av-bv)*255)}
          }
        }
      }}
    }}}
    guard n>0 else{throw Stop.layout("emptymask")}
    func distribution(_ h:[Int],_ other:[Double]=[])->[String:Any]{let s=other.sorted(),count=h.reduce(0,+)+s.count,rank=Int(ceil(Double(count)*0.99));var cumulative=0,j=0,p99=0.0,found=false
      for e in 0..<256{while j<s.count && s[j]<Double(e){cumulative+=1;if cumulative>=rank && !found{p99=s[j];found=true};j+=1};cumulative+=h[e];if cumulative>=rank && !found{p99=Double(e);found=true}}
      if !found && count>0{p99=s[max(0,rank-h.reduce(0,+)-1)]};let maximum=max(Double(h.lastIndex(where:{$0>0}) ?? 0),s.last ?? 0)
      return["n":count,"p99":p99,"maximum":maximum,"pass":count==0 || (p99<=1 && maximum<=2)]}
    let rgba=hist.map{distribution($0)},derived=extra.map{channels in (0..<3).map{distribution(opaqueHist[$0],channels[$0])}}
    let passed=rgba.allSatisfy{$0["pass"]as?Bool==true} && derived.flatMap{$0}.allSatisfy{$0["pass"]as?Bool==true}
    return["pixels":n,"RGBA":rgba,"pass":passed,"bothOpaquePixels":opaque,"bothFullyOpaque":opaque==n,"straightRGBPositiveOutputAlphaPixels":positiveStraight,"straightRGB":derived[0],"blackCompositeRGB":derived[1],"whiteCompositeRGB":derived[2],"derivedScope":opaque==n ? "actualbothopaque: straight/composites exactlyRGBA_RGB gate":"quantizedpremul-sRGBdisplaybytes; positivealphaonlystraight, zeroalphaunmeasurable; E(D(straight)*alpha+background*(1-alpha)); NOT fabricatedF32/HDRbuffer"]
  }
}
