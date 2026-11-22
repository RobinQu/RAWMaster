import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct Renderer {
  static func main() {
    do {
      guard CommandLine.arguments.count == 3 else {
        throw RenderIssue("usage: rawmaster-group-render REQUEST.json RECEIPT.json")
      }
      let request = URL(fileURLWithPath: CommandLine.arguments[1])
      let receipt = URL(fileURLWithPath: CommandLine.arguments[2])
      try run(requestFile: request, receipt: receipt)
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      FileHandle.standardError.write(Data((message + "\n").utf8))
      exit(1)
    }
  }

  static func run(requestFile: URL, receipt: URL) throws {
    let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestFile))
    guard
      request.recipe.sourceRenderingPolicy == nil
        || request.recipe.sourceRenderingPolicy == "originalLinearRAW"
    else {
      throw RenderIssue("unsupported source rendering policy for a linear RAW group master")
    }
    let output = request.outputURL
    guard output.isFileURL, receipt != output, !FileManager.default.fileExists(atPath: output.path),
      !FileManager.default.fileExists(atPath: receipt.path)
    else { throw RenderIssue("output or receipt already exists") }
    let parent =
      ProcessInfo.processInfo.environment["RAWMASTER_GROUP_SCRATCH"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      }
      ?? output.deletingLastPathComponent()
    let scratch = parent.appendingPathComponent(
      ".render-worker-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: scratch, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let xs = try loadInputs(request, scratch)
    try commonInputs(xs)
    var canvas: Canvas
    switch request.operation {
    case "starTrail": canvas = try star(xs, request.recipe)
    case "hdr": canvas = try hdr(xs, request.recipe)
    case "panorama": canvas = try panorama(xs, request.recipe, scratch)
    default: throw RenderIssue("unsupported group recipe")
    }
    let stage = scratch.appendingPathComponent("master.tiff")
    // Use a finite, bounded ICC v2/v4 linear sRGB profile. Extended values stay in the TIFF's float samples.
    guard let icc = CGColorSpace(name: CGColorSpace.linearSRGB)?.copyICCData() as Data?,
      icc.count > 128
    else { throw RenderIssue("linear RGB ICC profile unavailable") }
    var stats = [Double](repeating: 0, count: 5)
    let result = icc.withUnsafeBytes { data in
      gr_tiff(
        stage.path, canvas.rgb.p, Int32(canvas.w), Int32(canvas.h),
        data.bindMemory(to: UInt8.self).baseAddress, Int32(icc.count), &stats)
    }
    guard result == 0 else { throw RenderIssue("linear float TIFF write failed (\(result))") }
    guard let src = CGImageSourceCreateWithURL(stage as CFURL, nil),
      CGImageSourceGetCount(src) == 1,
      let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?,
      (meta[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == canvas.w,
      (meta[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == canvas.h,
      let decoded = CGImageSourceCreateImageAtIndex(
        src, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary),
      decoded.bitsPerComponent == 32, decoded.colorSpace?.model == .rgb,
      decoded.bitmapInfo.contains(.floatComponents)
    else { throw RenderIssue("independent ImageIO TIFF readback failed") }
    let (hash, length) = try digest(stage)
    let facts = xs.enumerated().map { i, x -> Facts in
      var v = canvas.frames[i]
      v["fileID"] = x.frame.fileID
      v["assetID"] = x.frame.assetID
      v["captureID"] = x.frame.captureID
      v["contentID"] = x.frame.contentID
      v["sha256"] = x.frame.sha256
      v["byteCount"] = x.frame.byteCount
      if let ver = x.frame.workVersionID { v["workVersionID"] = ver }
      if let s = x.shutter { v["measuredExposureSeconds"] = s }
      v["sourceOrientation"] = x.orientation
      return v
    }
    canvas.facts["inputs"] = facts
    canvas.facts["inputCount"] = xs.count
    canvas.facts["source"] = "verified full camera RAW"
    canvas.facts["sourceRenderingPolicy"] = "originalLinearRAW"
    canvas.facts["workVersionUsage"] =
      "frozen work-version IDs retained for provenance; pixels decoded from frozen camera bytes"
    canvas.facts["workingSpace"] = "scene-linear extended sRGB"
    canvas.facts["sampleFormat"] = "IEEE 754 float32 RGB contiguous"
    canvas.facts["decoder"] =
      "Apple CIRAWFilter, zero boost and baseline exposure, fixed reference chromaticity"
    canvas.facts["outputSHA256"] = hash
    canvas.facts["outputByteCount"] = length
    canvas.facts["minimumSample"] = stats[0]
    canvas.facts["maximumSample"] = stats[1]
    canvas.facts["overOnePixels"] = Int64(stats[2])
    canvas.facts["negativeChannelPixels"] = Int64(stats[3])
    canvas.facts["meanLinearLuminance"] = stats[4]
    let resultJSON: Facts = [
      "mediaKind": "derivedPhoto", "format": "tiff32f", "width": canvas.w, "height": canvas.h,
      "frameCount": 1, "engineVersion": "rawmaster-group-render/1 opencv/4.12.0",
      "facts": canvas.facts,
    ]
    let encoded = try JSONSerialization.data(withJSONObject: resultJSON, options: [.sortedKeys])
    let tmpReceipt = scratch.appendingPathComponent("receipt.json")
    try encoded.write(to: tmpReceipt, options: .withoutOverwriting)
    guard link(stage.path, output.path) == 0 else {
      throw RenderIssue("exclusive publication of private group output failed")
    }
    guard link(tmpReceipt.path, receipt.path) == 0 else {
      unlink(output.path)
      throw RenderIssue("exclusive publication of group receipt failed")
    }
  }
}
