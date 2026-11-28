import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

package struct CaptureClock: Codable, Sendable, Equatable {
  package let localSecond: Int64?
  package let nanosecond: Int?
  package let offsetMinutes: Int?
  package let hasInvalidTags: Bool
  package let subsecondTruncated: Bool
  package let displayText: String?
  package let cameraDay: String?

  init(evidence: SequenceTimeEvidence, invalidTagType: Bool) {
    func present(_ raw: String?) -> Bool {
      raw?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty == false
    }
    let local = evidence.local
    localSecond = local?.civilSecond
    nanosecond = local?.nanosecond
    offsetMinutes = evidence.offsetMinutes
    hasInvalidTags = invalidTagType
      || (present(evidence.originalRaw) && local == nil)
      || (present(evidence.subsecondsRaw) && evidence.subsecondDigits == nil)
      || (present(evidence.offsetRaw) && offsetMinutes == nil)
    subsecondTruncated = evidence.subsecondTruncated
    if let local {
      cameraDay = String(format: "%04d%02d%02d", local.year, local.month, local.day)
      var clock = String(format: "%04d-%02d-%02d %02d:%02d:%02d", local.year, local.month, local.day,
        local.hour, local.minute, local.second)
      if let nanos = local.nanosecond, let digits = evidence.subsecondDigits {
        clock += "." + String(format: "%09d", nanos).prefix(min(9, digits))
      }
      if offsetMinutes != nil, let raw = evidence.offsetRaw {
        clock += " " + raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
      }
      displayText = clock
    } else {
      displayText = nil
      cameraDay = nil
    }
  }

  static func describesSameInstant(_ first: Self, _ second: Self) -> Bool {
    let validSeconds: ClosedRange<Int64> = -62_135_596_800...253_402_300_799
    guard !first.hasInvalidTags, !second.hasInvalidTags,
          let firstSecond = first.localSecond, validSeconds.contains(firstSecond),
          let secondSecond = second.localSecond, validSeconds.contains(secondSecond),
          [first.offsetMinutes, second.offsetMinutes].compactMap({ $0 }).allSatisfy({ (-840...840).contains($0) }),
          [first.nanosecond, second.nanosecond].compactMap({ $0 }).allSatisfy({ (0...999_999_999).contains($0) })
    else { return false }

    let secondsDifference: Int64
    if let firstOffset = first.offsetMinutes, let secondOffset = second.offsetMinutes {
      secondsDifference = firstSecond - secondSecond - Int64(firstOffset - secondOffset) * 60
    } else {
      secondsDifference = firstSecond - secondSecond
    }
    guard let firstFraction = first.nanosecond, let secondFraction = second.nanosecond else {
      return secondsDifference == 0
    }
    guard (-1...1).contains(secondsDifference) else { return false }
    let nanoseconds = secondsDifference * 1_000_000_000 + Int64(firstFraction - secondFraction)
    return abs(nanoseconds) < 1_000_000
  }
}

struct ImportedCaptureMetadata {
  let width, height: Int?
  let camera, cameraSerialDigest: String?
  let clock: CaptureClock
  let capturedAt: Date?

  static func read(from file: FileHandle, size: Int64, extension suffix: String, localDate: DateFormatter) throws -> Self {
    let input = ImageFile(file: file, size: size)
    var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
      getBytesAtPosition: { info, buffer, offset, count in
        guard let info else { return 0 }
        return Unmanaged<ImageFile>.fromOpaque(info).takeUnretainedValue().read(at: offset, to: buffer, count: count)
      }, releaseInfo: nil)

    return try withExtendedLifetime(input) {
      try autoreleasepool {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let type = UTType(filenameExtension: suffix) { options[kCGImageSourceTypeIdentifierHint] = type.identifier }
        let source = CGDataProvider(directInfo: Unmanaged.passUnretained(input).toOpaque(), size: size, callbacks: &callbacks)
          .flatMap { CGImageSourceCreateWithDataProvider($0, options as CFDictionary) }
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        try input.checkRead()
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let dateValue = exif[kCGImagePropertyExifDateTimeOriginal]
        let subsecondValue = exif[kCGImagePropertyExifSubsecTimeOriginal]
        let offsetValue = exif[kCGImagePropertyExifOffsetTimeOriginal]
        let invalidTagType = [dateValue, subsecondValue, offsetValue].compactMap { $0 }.contains { !($0 is String) }
        var date = dateValue as? String
        var subseconds = subsecondValue as? String
        var offset = offsetValue as? String
        if !invalidTagType, (subseconds == nil || offset == nil), let originalDate = date,
           source.flatMap(CGImageSourceGetType) == "com.sony.arw-raw-image" as CFString,
           let physical = try TIFFCaptureTimeTags.read(from: file),
           let available = physical.supplementing(imageIODate: originalDate, imageIOSubseconds: subseconds, imageIOOffset: offset) {
          date = available.dateTimeOriginal
          subseconds = subseconds ?? available.subsecTimeOriginal
          offset = offset ?? available.offsetTimeOriginal
        }
        let evidence = SequenceTimestampParser.parse(original: date, subseconds: subseconds, offset: offset)
        let clock = CaptureClock(evidence: evidence, invalidTagType: invalidTagType)
        let capturedAt = evidence.utcInstant ?? evidence.local.flatMap { local in
          date.flatMap { localDate.date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))) }
            .map { $0.addingTimeInterval(Double(local.nanosecond ?? 0) / 1_000_000_000) }
        }
        let serials = Set([exif[kCGImagePropertyExifBodySerialNumber], aux[kCGImagePropertyExifAuxSerialNumber]]
          .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) }
          .filter { !$0.isEmpty })
        let serialDigest = serials.count == 1 ? serials.first.map {
          SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        } : nil
        return .init(width: (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          height: (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
          camera: tiff[kCGImagePropertyTIFFModel] as? String, cameraSerialDigest: serialDigest,
          clock: clock, capturedAt: capturedAt)
      }
    }
  }

  private final class ImageFile {
    let file: FileHandle
    let size: Int64
    private let lock = NSLock()
    private var readError: POSIXErrorCode?

    init(file: FileHandle, size: Int64) {
      self.file = file
      self.size = size
    }

    func read(at offset: off_t, to buffer: UnsafeMutableRawPointer, count: Int) -> Int {
      guard offset >= 0, offset < size, count > 0 else { return 0 }
      let length = min(count, Int(size - offset))
      var total = 0
      while total < length {
        var received: Int
        repeat {
          received = pread(file.fileDescriptor, buffer.advanced(by: total), length - total, offset + Int64(total))
        } while received < 0 && errno == EINTR
        if received <= 0 {
          let error = received == 0 ? POSIXErrorCode.EIO : POSIXErrorCode(rawValue: errno) ?? .EIO
          lock.withLock { readError = readError ?? error }
          return total
        }
        total += received
      }
      return total
    }

    func checkRead() throws {
      if let error = lock.withLock({ readError }) { throw POSIXError(error) }
    }
  }
}
