import XCTest
import AVFoundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentDeviceDepthV1Tests:XCTestCase {
  private func colorImage(width:Int=64,height:Int=32)throws->CGImage {
    let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red:0.3,green:0.5,blue:0.7,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
    return try XCTUnwrap(context.makeImage())
  }
  func testPlainImageHasNoDepthAndRejectsRead()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-depth-plain-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try?FileManager.default.removeItem(at:root)}
    let url=root.appendingPathComponent("plain.png"),destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil))
    CGImageDestinationAddImage(destination,try colorImage(),nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    XCTAssertFalse(DevelopmentDeviceDepthV1.probe(url));XCTAssertThrowsError(try DevelopmentDeviceDepthV1.read(url))
  }
  func testRealHEICDepthRoundTripThroughAVDepthData()throws {
    let width=8,height=4,values=(0..<(width*height)).map{Float($0+1)}
    let data=values.withUnsafeBytes{Data($0)}
    let description:[String:Any]=["Width":width,"Height":height,"BytesPerRow":width*4,"PixelFormat":kCVPixelFormatType_DepthFloat32]
    let info:[String:Any]=[kCGImageAuxiliaryDataInfoData as String:data,kCGImageAuxiliaryDataInfoDataDescription as String:description]
    let depth=try AVDepthData(fromDictionaryRepresentation:info)
    var auxiliaryType:NSString?
    let auxiliary=try XCTUnwrap(depth.dictionaryRepresentation(forAuxiliaryDataType:&auxiliaryType))
    XCTAssertEqual(auxiliaryType,kCGImageAuxiliaryDataTypeDepth)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-depth-heic-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try?FileManager.default.removeItem(at:root)}
    let url=root.appendingPathComponent("depth.heic"),destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.heic.identifier as CFString,1,nil))
    CGImageDestinationAddImage(destination,try colorImage(),nil)
    CGImageDestinationAddAuxiliaryDataInfo(destination,try XCTUnwrap(auxiliaryType),auxiliary as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination),"The actual HEIC writer must accept the depth auxiliary payload")
    XCTAssertTrue(DevelopmentDeviceDepthV1.probe(url))
    let actual=try DevelopmentDeviceDepthV1.read(url)
    XCTAssertEqual(actual.kind,.depth);XCTAssertEqual(actual.width,width);XCTAssertEqual(actual.height,height);XCTAssertEqual(actual.values.count,width*height)
    XCTAssertEqual(actual.values.first,0);XCTAssertEqual(actual.values.last,1)
    for i in 1..<actual.values.count { XCTAssertGreaterThanOrEqual(actual.values[i],actual.values[i-1]) }
    let payload=try DevelopmentDeviceDepthV1.payload(from:actual)
    XCTAssertEqual(payload.width,width);XCTAssertEqual(payload.height,height)
    XCTAssertEqual(try payload.values(),actual.values)
  }
  func testPayloadDownsamplesLargeDeviceMapWithinLimit()throws {
    let width=1024,height=512,values=(0..<(width*height)).map{Float($0%width)/Float(width-1)}
    let map=DevelopmentDeviceDepthMapV1(kind:.disparity,width:width,height:height,values:values)
    let payload=try DevelopmentDeviceDepthV1.payload(from:map)
    XCTAssertEqual(payload.width,512);XCTAssertEqual(payload.height,256);XCTAssertEqual(try payload.values().count,512*256)
    let scaledValues=try payload.values()
    XCTAssertEqual(try XCTUnwrap(scaledValues.first),0,accuracy:0.01)
    XCTAssertEqual(try XCTUnwrap(scaledValues.last),1,accuracy:0.01)
  }
}
