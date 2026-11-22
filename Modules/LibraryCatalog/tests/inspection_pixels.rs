//! Uses the production Swift readers and pixel geometry on macOS. The capture sink substitutes
//! only the transaction boundary; integration tests exercise those same command payloads in Rust.
#[cfg(target_os = "macos")]
#[test]
fn imageio_jpeg_histogram_geometry_and_sony_fallback() -> rawmaster_library::Result<()> {
    use std::{fs, path::Path, process::Command};
    let scratch = tempfile::tempdir()?;
    let main = scratch.path().join("Probe.swift");
    fs::write(
        &main,
        r##"
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
public struct LibraryEngineError:Error { let text:String; public init(_ value:String){text=value} }
actor Sink {
    var rows=[String:CatalogJSON]()
    func set(_ key:String,_ v:CatalogJSON){rows[key]=v}
    func get(_ key:String)->CatalogJSON?{rows[key]}
}
public struct CatalogActions:Sendable {
    let sink:Sink
    public func perform(_ key:String,_ body:[String:CatalogJSON],commandID:String=UUID().uuidString)async throws->CatalogJSON{
        await sink.set(key,.object(body));return .null
    }
}
extension CatalogJSON{
    subscript(_ key:String)->CatalogJSON? {if case .object(let o)=self{return o[key]};return nil}
    var stringValue:String? {if case .string(let s)=self{return s};return nil}
}
@main struct Probe {
    static func main()async throws{
        let directory=URL(fileURLWithPath:CommandLine.arguments[1])
        for exif in 1...8{
            let geo=LibraryInspectionGeometry(original:.init(width:6000,height:4000),orientation:exif,rotationDegrees:7,
                crop:.init(x:0.1,y:0.12,width:0.75,height:0.77),viewport:.init(width:900,height:570),zoom:1.3,pan:.init(x:6,y:-8))
            let original=CGPoint(x:0.39,y:0.54)
            guard let loc=geo.displayPoint(forRaw:original),let back=geo.rawPoint(forDisplay:loc)else{fatalError("ROI disappeared")}
            precondition(abs(back.x-original.x)<1e-9 && abs(back.y-original.y)<1e-9)
            precondition(geo.displayPoint(forRaw:.zero)==nil)
        }
        let known=LibraryInspectionGeometry.oriented(.init(x:0.25,y:0.60),exif:6)!
        precondition(abs(known.x-0.40)<1e-9 && abs(known.y-0.25)<1e-9)
        let dim=CGSize(width:6000,height:4000)
        precondition(LibraryInspectionReader.sonyLocation([8640,5760,4320,2880],model:"ILCE-1",orientation:1,image:.init(width:8640,height:5760))["state"] == .string("unavailable"))
        precondition(LibraryInspectionReader.sonyLocation([9504,6336,5197,3168],model:"ILCE-7RM5",orientation:1,image:.init(width:9504,height:6336))["state"] == .string("available"))
        precondition(LibraryInspectionReader.sonyLocation([6000,4000,3000,2000],model:"ILCE-1M2",orientation:6,image:dim)["state"] == .string("unavailable"))
        precondition(LibraryInspectionReader.sonyLocation([6000,4000,1200,2000],model:"ILCE-1M2",orientation:6,image:dim)["state"] == .string("available"))
        let url=directory.appendingPathComponent("fixture.jpg")
        let ctx=CGContext(data:nil,width:160,height:100,bitsPerComponent:8,bytesPerRow:640,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed:0.8,green:0.2,blue:0.1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:160,height:100))
        let dst=CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil)!
        let props:[CFString:Any]=[kCGImagePropertyOrientation:6,kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFModel:"Fixture camera"],
            kCGImagePropertyExifDictionary:[kCGImagePropertyExifFNumber:4,kCGImagePropertyExifDateTimeOriginal:"2025:02:01 12:00:00",
              kCGImagePropertyExifOffsetTimeOriginal:"+08:00"],kCGImagePropertyIPTCDictionary:[kCGImagePropertyIPTCObjectName:"共享标题"]]
        CGImageDestinationAddImage(dst,ctx.makeImage()!,props as CFDictionary);precondition(CGImageDestinationFinalize(dst))
        let bytes=try LibraryInspectionReader.digest(url)
        let c="sha256:\(bytes.0):\(bytes.1)", target=LibraryInspectionFile(fileID:"fixture",contentID:c,url:url)
        let sink=Sink(),actions=CatalogActions(sink:sink)
        try await LibraryInspectionReader.capture(target,using:actions)
        let captured=await sink.get("inspect.capture")
        precondition(captured?["fields"]?["width"] == .integer(160))
        precondition(captured?["fields"]?["title"] == .string("共享标题"))
        precondition(captured?["af"]?["state"] == .string("unavailable"))
        try await LibraryInspectionReader.histogram(.init(kind:.cameraJPEG,url:url,sha256:bytes.0,contentID:c),for:target,using:actions)
        let sample=await sink.get("inspect.histogram")?["sample"];precondition(sample?["kind"] == .string("cameraJPEG"))
        guard case .array(let red)?=sample?["red"],case .integer(let n)?=sample?["sampledPixels"] else{fatalError("Missing histogram")}
        precondition(red.count==256 && red.reduce(0){s,v in if case .integer(let n)=v{return s+n};return s}==n)
        let flat=LibraryInspectionReader.patchMeasurements(rgba:[UInt8](repeating:60,count:64*64*4),width:64,height:64)
        if case .number(let contrast)?=flat["contrast"]{precondition(contrast<0.001)}else{fatalError("Missing contrast")}
        if let filename=ProcessInfo.processInfo.environment["RAWMASTER_INSPECTION_SONY_ARW"] {
            let source=URL(fileURLWithPath:filename),hash=try LibraryInspectionReader.digest(source)
            let tool=ProcessInfo.processInfo.environment["RAWMASTER_INSPECTION_EXIFTOOL"].map{URL(fileURLWithPath:$0)}
            try await LibraryInspectionReader.capture(.init(fileID:"real",contentID:"sha256:\(hash.0):\(hash.1)",url:source),using:actions,exifTool:tool)
            let real=await sink.get("inspect.capture");precondition(real?["fields"]?["make"]?.stringValue?.uppercased()=="SONY")
            guard let af=real?["af"]?["state"]?.stringValue else{fatalError("Missing Sony AF provenance")}
            precondition(af=="available" || af=="unavailable")
        }
    }
}
"##,
    )?;
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("Swift");
    let binary = scratch.path().join("reader-check");
    let build = Command::new("/usr/bin/xcrun")
        .arg("swiftc")
        .args(["-swift-version", "6", "-parse-as-library"])
        .arg(src.join("CatalogJSON.swift"))
        .arg(src.join("LibraryInspectionGeometry.swift"))
        .arg(src.join("LibraryInspectionReader.swift"))
        .arg(src.join("LibraryInspectionPixels.swift"))
        .arg(&main)
        .arg("-o")
        .arg(&binary)
        .output()?;
    assert!(
        build.status.success(),
        "{}",
        String::from_utf8_lossy(&build.stderr)
    );
    let run = Command::new(binary).arg(scratch.path()).output()?;
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
    Ok(())
}
