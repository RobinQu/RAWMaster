import CoreImage
import CryptoKit
import Darwin
import Foundation
import RAWMasterCore

/// Range and lineage for the fixed native R32 restore. The producer and the
/// consumer each check the same source and backing. No result graph is accepted as input.
enum DevelopmentDehazeRestoreProof {
  static let contract = "restore-finite/opaque1024-r32-bounded2-lines-v1"
  static let enabled = (ProcessInfo.processInfo.environment["RAWMASTER_QA_NATIVE_DEHAZE_RESTORE_PROOF"] ?? "1") == "1" && programIsKnown
  static let programIsKnown: Bool = {
    guard let restore = try? DevelopmentDehazeRfTransportV1.restoreSource() else { return false }
    return matches(restore: restore, coverage: PreviewFITCoverageV1.metalSource)
  }()

  static func matches(restore: String, coverage: String) -> Bool {
    func digest(_ source: String) -> String {
      SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    return digest(restore) == "e6447f5c465162e34b219e88adff7bb3408f539c40bc1517e857fc7f9bca4e5a"
      && digest(coverage) == "465bd5eced2c923a5c2c45e31e38640e7d41938a866aa08eb108470e8059e441"
  }

  struct NativeInput {
    let raw, normalized: CIImage

    init(normalizing raw: CIImage) throws {
      self.raw = raw
      normalized = try PreviewFITCoverageV1.normalize(raw, extent: raw.extent)
    }
  }

  /// A joined CI band has top-origin rows inside a bottom-origin native rectangle.
  /// Validate and copy the actual values, so the certificate and the stored data
  /// cannot describe different rows. The producer seeds unwritten R32 samples with NaN.
  final class Rows {
    private let width, height: Int
    private var copied = 0, withinRange = true

    init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }

    func copy(_ values: UnsafeBufferPointer<Float>, bandY: Int, bandHeight: Int, row: Int,
              to storage: UnsafeMutableRawBufferPointer, rowBytes: Int) throws {
      guard (1...9504).contains(width), (1...6336).contains(height), copied < height,
            bandY == (copied/256)*256, bandHeight == min(256, height-bandY),
            row == copied-bandY, row < bandHeight, values.count == width,
            rowBytes >= width*4, height <= storage.count/rowBytes,
            let src = values.baseAddress, let dst = storage.baseAddress else {
        throw PreviewPresentationError.allocationProtocol
      }
      var maxBits: UInt32 = 0
      for sample in values { maxBits = max(maxBits, sample.bitPattern & 0x7fff_ffff) }
      guard maxBits < 0x7f80_0000 else { throw DevelopmentError.invalidEncoding }
      if maxBits > Float(2).bitPattern { withinRange = false }
      let top = height-bandY-bandHeight
      let destination = dst.advanced(by: (top+row)*rowBytes)
      if UnsafeRawPointer(destination) != UnsafeRawPointer(src) {
        memcpy(destination, src, width*4)
      }
      copied += 1
    }

    func finished() throws -> Bool {
      guard copied == height, copied > 0 else { throw PreviewPresentationError.allocationProtocol }
      return withinRange
    }
  }
}
