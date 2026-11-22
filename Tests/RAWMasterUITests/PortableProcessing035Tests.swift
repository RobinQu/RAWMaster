// Spec 035 opt-in fixture. The runner supplies the two experimental C modules.
#if canImport(RMImageProbe) && canImport(RMQueueProbe)
import AppKit
import CoreImage
import CryptoKit
import ImageIO
import RAWMasterImaging
import RMImageProbe
import RMQueueProbe
import SwiftUI
import UniformTypeIdentifiers
import XCTest

private enum ProbeError: Error { case invalid(String) }
private func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw ProbeError.invalid(reason) }
}
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct MaskBinding: Decodable {
    let sourceSHA256, maskSHA256, modelSHA256: String
    let width, height: Int
}

private func request(_ db: URL, _ value: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let reply = try XCTUnwrap(rmq_request_v1(db.path, String(decoding: data, as: UTF8.self)))
    defer { rmq_release_v1(reply) }
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: reply).utf8)) as? [String: Any])
    try require(json["ok"] as? Bool == true, json["error"] as? String ?? "queue error")
    return try XCTUnwrap(json["value"] as? [String: Any])
}

private struct Samples {
    let width, height, nativeWidth, nativeHeight: Int
    let rgba, mask: [Float]
    let decoder: String

    init(photo: URL, coverage: URL, binding: MaskBinding) throws {
        let driver = try XCTUnwrap(CGImageSourceCreateWithURL(coverage as CFURL, nil))
        let map = try XCTUnwrap(CGImageSourceCreateImageAtIndex(driver, 0, nil))
        let w = map.width, h = map.height
        try require(w == binding.width && h == binding.height && map.bitsPerPixel == 8 &&
                    map.bitsPerComponent == 8 && map.colorSpace?.model == .monochrome, "coverage layout")
        let data = try XCTUnwrap(map.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        try require(CFDataGetLength(data) >= map.bytesPerRow * h, "truncated coverage")
        // Decode numeric coverage bytes without ICC conversion.
        mask = (0..<h).flatMap { y in (0..<w).map { x in Float(bytes[y * map.bytesPerRow + x]) / 255 } }
        let image: CIImage
        if photo.pathExtension.lowercased() == "arw" {
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: photo))
            raw.scaleFactor = 1
            raw.isDraftModeEnabled = false
            image = try XCTUnwrap(raw.outputImage)
            decoder = "CIRAWFilter/" + raw.decoderVersion.rawValue
        } else {
            image = try XCTUnwrap(CIImage(contentsOf: photo, options: [.applyOrientationProperty: true]))
            decoder = "Core Image raster"
        }
        width = w; height = h
        nativeWidth = Int(image.extent.width); nativeHeight = Int(image.extent.height)
        try require(abs(Double(nativeWidth) / Double(nativeHeight) - Double(w) / Double(h)) < 0.001, "mask aspect")
        let aligned = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width, y: CGFloat(h) / image.extent.height))
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf.rawValue])
        var pixels = [Float](repeating: 0, count: w*h*4)
        try pixels.withUnsafeMutableBytes { buffer in
            let dest = CIRenderDestination(bitmapData: buffer.baseAddress!, width: w, height: h, bytesPerRow: w*16, format: .RGBAf)
            dest.colorSpace = space; dest.alphaMode = .premultiplied; dest.isFlipped = true; dest.isDithered = false
            try context.startTask(toRender: aligned, from: CGRect(x: 0, y: 0, width: w, height: h),
                                  to: dest, at: .zero).waitUntilCompleted()
        }
        rgba = pixels
    }
    func render(_ graph: String, backend: UInt32) throws -> [Float] {
        var handle: OpaquePointer?
        let opened = graph.withCString { rmi_open_v1($0, graph.utf8.count, backend, &handle) }
        try require(opened == 0 && handle != nil, "open backend \(backend), status \(opened)")
        defer { rmi_close_v1(handle) }
        let count = rgba.count
        var output = [Float](repeating: 0, count: count)
        let status = rmi_render_v1(handle, UInt32(width), UInt32(height), rgba, count, mask, mask.count, &output, count)
        try require(status == 0, "render status \(status)")
        return output
    }

    func displayImage(_ output: [Float]) throws -> CGImage {
        let data = output.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union([.floatComponents, .byteOrder32Little])
        let linear = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: width*16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(linear, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }
}

private func runWorker(directory: URL, photo: URL, coverage: URL, graphURL: URL, bindingURL: URL) throws -> Data {
    let sourceHash = digest(try Data(contentsOf: photo))
    let maskHash = digest(try Data(contentsOf: coverage))
    let bindings = try JSONDecoder().decode([MaskBinding].self, from: Data(contentsOf: bindingURL))
    let binding = try XCTUnwrap(bindings.first { $0.sourceSHA256 == sourceHash && $0.maskSHA256 == maskHash })
    let graph = try String(contentsOf: graphURL, encoding: .utf8)
    let graphHash = digest(Data(graph.utf8))
    let db = directory.appendingPathComponent("queue.sqlite")
    let job = "preview-\(sourceHash)-\(graphHash)-\(maskHash)"
    _ = try request(db, ["op":"submit", "key":job, "lane":"editing", "resource":"gpu",
                         "payload":["source":sourceHash, "graph":graphHash, "mask":maskHash, "model":binding.modelSHA256]])
    let claim = try request(db, ["op":"claim", "leaseMs":120000])
    try require(claim["key"] as? String == job, "claimed wrong snapshot")
    let samples = try Samples(photo: photo, coverage: coverage, binding: binding)
    let cpu = try samples.render(graph, backend: 0), gpu = try samples.render(graph, backend: 1)
    // These LE interchange fixtures feed the Linux worker without installing an Apple decoder.
    let inputs = samples.rgba.withUnsafeBytes { Data($0) }
    let coverages = samples.mask.withUnsafeBytes { Data($0) }
    try inputs.write(to: directory.appendingPathComponent("input.rgba32fle"))
    try coverages.write(to: directory.appendingPathComponent("mask.r32fle"))
    let cpuHash = cpu.withUnsafeBytes { digest(Data($0)) }
    var maxError: Float = 0, maxOutsideError: Float = 0, insideChanged = 0, outside = 0
    let baseGain = Float(pow(2.0, 0.25)) // The independent analytic base branch in local-look.json.
    for i in samples.mask.indices {
        let a = i*4
        var delta: Float = 0
        for c in 0..<4 { maxError = max(maxError, abs(cpu[a+c]-gpu[a+c])) }
        for c in 0..<3 { delta = max(delta, abs(gpu[a+c]-samples.rgba[a+c]*baseGain)) }
        if samples.mask[i] == 0 { outside += 1; maxOutsideError = max(maxOutsideError, delta) }
        if samples.mask[i] > 0.5 && delta > 1.0/65535 { insideChanged += 1 }
    }
    try require(maxError < 2e-6 && maxOutsideError < 2e-6 && outside > 0 && insideChanged > 0, "parity or mask boundary")
    let output = directory.appendingPathComponent("render.png")
    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, try samples.displayImage(gpu), nil)
    try require(CGImageDestinationFinalize(dest), "encode")
    let fileData = try Data(contentsOf: output)
    let sha = digest(fileData)
    let token = try XCTUnwrap(claim["token"] as? String)
    let receipt = try request(db, ["op":"complete", "key":job, "token":token, "result":sha, "file":output.path])
    let status = try request(db, ["op":"status", "key":job])
    try require(status["state"] as? String == "done" && status["result"] as? String == sha &&
                receipt["resourceID"] is String, "stale or missing catalog resource")
    let report: [String: Any] = ["sourceSHA256":sourceHash, "maskSHA256":maskHash, "modelSHA256":binding.modelSHA256,
        "graphSHA256":graphHash, "outputSHA256":sha, "sourceExtent":[samples.nativeWidth,samples.nativeHeight],
        "renderExtent":[samples.width,samples.height],"decoder":samples.decoder, "maxAbsCPUvsGPU":maxError,
        "zeroCoveragePixels":outside, "maxOutsideBaseError":maxOutsideError, "changedInsidePixels":insideChanged,
        "inputRGBASHA256":digest(inputs),"inputCoverageSHA256":digest(coverages),"cpuRGBA32FLESHA256":cpuHash,
        "jobState":"done","catalogResource":try XCTUnwrap(receipt["resourceID"] as? String)]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        .write(to: directory.appendingPathComponent("worker.json"))
    return fileData
}

final class PortableProcessing035Tests: XCTestCase {
    @MainActor func testTwoCoresPresentOnEditingCanvas() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["RM035_ROOT"], let out = env["RM035_RESULT"] else { throw XCTSkip("Run the spec 035 Swift host script") }
        let base = URL(fileURLWithPath: root), directory = URL(fileURLWithPath: out)
        let spec = base.appendingPathComponent("specs/035-portable-processing-cores/evidence")
        let photo = URL(fileURLWithPath: try XCTUnwrap(env["RM035_PHOTO"]))
        let mask = URL(fileURLWithPath: try XCTUnwrap(env["RM035_MASK"]))
        let png = try await Task.detached {
            try runWorker(directory: directory, photo: photo, coverage: mask,
                graphURL: base.appendingPathComponent("experiments/portable-processing/image/examples/local-look.json"),
                bindingURL: spec.appendingPathComponent("sky-bindings.json"))
        }.value
        let image = try XCTUnwrap(NSImage(data: png))
        let frame = UUID()
        let drawn = expectation(description: "editing canvas drew this frame")
        drawn.assertForOverFulfill = false
        let canvas = ZoomableImageView(image: image, actualPixels: false, transform: .constant(ImageTransform()),
            frameID: frame, onFrameDrawn: { event in if event.frameID == frame { drawn.fulfill() } })
        let rect = CGRect(x: 0, y: 0, width: 480, height: 320)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: canvas)
        panel.contentView = host
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        panel.orderBack(nil); host.layoutSubtreeIfNeeded(); host.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        await fulfillment(of: [drawn], timeout: 5)
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide/2, y: bitmap.pixelsHigh/2)?.usingColorSpace(.sRGB))
        let upper = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide/2, y: bitmap.pixelsHigh*3/4)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(abs(center.redComponent-upper.redComponent)+abs(center.blueComponent-upper.blueComponent), 0.01)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("canvas.png"))
    }
}
#endif
