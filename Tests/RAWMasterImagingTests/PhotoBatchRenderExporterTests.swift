import XCTest
import CoreImage
import ImageIO
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class PhotoBatchRenderExporterTests:XCTestCase{
    func testRealRecipeResizeQualityNamingAndNoOverwrite()async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("batch-export-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try?FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.png"),output=root.appendingPathComponent("output",isDirectory:true),archiveRoot=root.appendingPathComponent("archive",isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let image=CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2,alpha:1)).cropped(to:.init(x:0,y:0,width:128,height:64))
        let context=CIContext();try context.writePNGRepresentation(of:image,to:source,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        let bytes=try Data(contentsOf:source),hash=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        let snapshot=EditingSourceSnapshot(projectID:"p",assetID:"a",contentSHA256:hash,byteCount:Int64(bytes.count),admissionFingerprint:"test",sourceLocation:source)
        let work=PhotoWork(source:snapshot),version=EditingVersion(id:work.originalVersionID,workID:work.id,parentVersionID:nil,kind:.original,source:snapshot)
        let archive=try EditingArchive(root:archiveRoot,protectedRoots:[source])
        let exporter=PhotoBatchRenderExporter(),configuration=PhotoBatchExportConfiguration(format:.jpeg8,maximumLongEdge:64,jpegQuality:0.5)
        let url=try await exporter.export(work:work,version:version,archive:archive,directory:output,filename:"{name}-0001",configuration:configuration)
        XCTAssertEqual(url.lastPathComponent,"{name}-0001.jpg")
        let cgSource=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil)),cg=try XCTUnwrap(CGImageSourceCreateImageAtIndex(cgSource,0,nil))
        XCTAssertEqual(cg.width,64);XCTAssertEqual(cg.height,32);XCTAssertEqual(cg.bitsPerComponent,8)
        XCTAssertEqual(try Data(contentsOf:source),bytes)
        await XCTAssertThrowsErrorAsync(try await exporter.export(work:work,version:version,archive:archive,directory:output,filename:"{name}-0001",configuration:configuration))
        XCTAssertThrowsError(try PhotoBatchExportConfiguration(format:.jpeg8,maximumLongEdge:32).validate())
        XCTAssertThrowsError(try PhotoBatchExportConfiguration(format:.jpeg8,jpegQuality:0).validate())
    }
}

// XCTest's synchronous assertion cannot directly wrap an async expression on all supported SDKs.
private func XCTAssertThrowsErrorAsync<T>(_ expression:@autoclosure()async throws->T,file:StaticString=#filePath,line:UInt=#line)async{
    do{_=try await expression();XCTFail("Expected an error",file:file,line:line)}catch{}
}
