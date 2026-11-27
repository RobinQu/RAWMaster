import CryptoKit
import Darwin
import Foundation
import RAWMasterCore

package enum DevelopmentSceneHDRDiagnostics {
  package struct Receipt: Encodable {
    let width, height, bitDepth, primaries, transfer, matrix, referenceWhiteNits, peakNits: Int
    let fullRange: Bool
    let inputSHA256, outputSHA256: String
    let exposureEV: Float
  }

  private enum Failure: LocalizedError {
    case invalidRequest, destinationExists, sourceChanged

    var errorDescription: String? {
      switch self {
      case .invalidRequest: return "Scene-HDR diagnostic requires an ARW, a new AVIF path, and exposure between −12 and +12 EV."
      case .destinationExists: return "The AVIF destination already exists; nothing was overwritten."
      case .sourceChanged: return "The source changed while rendering; no AVIF was published."
      }
    }
  }

  package static func exportARW(_ source: URL, to destination: URL, exposureEV: Float) throws -> Receipt {
    guard source.isFileURL, destination.isFileURL, source.pathExtension.lowercased() == "arw",
          destination.pathExtension.lowercased() == "avif", exposureEV.isFinite, (-12...12).contains(exposureEV)
    else { throw Failure.invalidRequest }
    if FileManager.default.fileExists(atPath:destination.path) { throw Failure.destinationExists }
    try Task.checkCancellation()
    let before=try digest(source)
    let output = DevelopmentSceneOutputStateV1.Version(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0))
    let workflow = try DevelopmentSceneWorkflowV1(correctors: [.init(exposureEV: exposureEV)], output: output)
    let encoded = try autoreleasepool { try DevelopmentSceneDeliveryServiceV1.encodeHDR(source, workflow: workflow) }
    guard try digest(source) == before else { throw Failure.sourceChanged }
    let result=Receipt(width:encoded.width,height:encoded.height,bitDepth:encoded.signal.bitDepth,
      primaries:encoded.signal.primaries,transfer:encoded.signal.transfer,matrix:encoded.signal.matrix,
      referenceWhiteNits:encoded.referenceWhiteNits,peakNits:encoded.peakNits,fullRange:encoded.signal.fullRange,
      inputSHA256:before,outputSHA256:hex(SHA256.hash(data:encoded.bytes)),exposureEV:exposureEV)
    let stage=destination.deletingLastPathComponent().appendingPathComponent(".rawmaster-scene-\(UUID().uuidString)")
    try encoded.bytes.write(to:stage,options:[.withoutOverwriting])
    defer { try? FileManager.default.removeItem(at:stage) }
    try Task.checkCancellation()
    guard renamex_np(stage.path,destination.path,UInt32(RENAME_EXCL)) == 0 else {
      let code=errno
      if code == EEXIST { throw Failure.destinationExists }
      throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
    }
    return result
  }

  private static func digest(_ url: URL) throws -> String {
    let file=try FileHandle(forReadingFrom:url)
    defer { try? file.close() }
    var sha=SHA256()
    while let block=try file.read(upToCount:1_048_576), !block.isEmpty {
      try Task.checkCancellation()
      sha.update(data:block)
    }
    return hex(sha.finalize())
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format:"%02x",$0) }.joined()
  }
}
