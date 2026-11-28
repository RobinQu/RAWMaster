import XCTest

@testable import RAWMasterCore

final class SequenceEvidenceTests: XCTestCase {
  func testCivilTimeStrictlyRejectsCalendarNormalizationAndDecodeBypass() throws {
    let bad = [
      "2023:02:29 12:00:00", "1900:02:29 12:00:00", "2024:04:31 12:00:00",
      "2024:00:01 12:00:00", "2024:13:01 12:00:00", "0000:01:01 00:00:00",
      "2024:01:00 00:00:00", "2024:01:01 24:00:00", "2024:01:01 00:60:00",
      "2024:01:01 00:00:60", "2024-01-01 00:00:00", "２０２４:01:01 00:00:00",
    ]
    for text in bad {
      let parsed = SequenceTimestampParser.parse(original: text, subseconds: nil, offset: "+00:00")
      XCTAssertNil(parsed.local, text)
      XCTAssertNil(parsed.utcInstant, text)
      XCTAssertEqual(parsed.precision, .unknown)
    }
    XCTAssertNotNil(
      SequenceTimestampParser.parse(original: "2000:02:29 23:59:59", subseconds: nil, offset: nil)
        .local)
    let json = Data(
      #"{"year":2024,"month":2,"day":30,"hour":0,"minute":0,"second":0}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(SequenceCivilTime.self, from: json))
  }

  func testMissingAndInvalidSubsecondsRemainUnknownFraction() throws {
    for fraction in [nil, "", "bad", "1.2", "-1", "１２"] as [String?] {
      let value = SequenceTimestampParser.parse(
        original: "2026:10:24 12:34:56", subseconds: fraction, offset: nil)
      XCTAssertNotNil(value.local)
      XCTAssertNil(value.local?.nanosecond)
      XCTAssertEqual(value.precision, .seconds)
      XCTAssertNil(value.subsecondDigits)
      XCTAssertNil(value.utcInstant)
      XCTAssertTrue(value.isConsistent)
    }
    let explicitZero = SequenceTimestampParser.parse(
      original: "2026:10:24 12:34:56", subseconds: "000", offset: nil)
    XCTAssertEqual(explicitZero.local?.nanosecond, 0)
    XCTAssertEqual(explicitZero.precision, .subsecond)
    XCTAssertEqual(explicitZero.subsecondDigits, 3)
  }

  func testRawPaddingAndExcessPrecisionPreservedWithWarnings() throws {
    let raw = " 2026:10:24 12:34:56\0"
    let fraction = " 123456789876 "
    let offset = " +08:00 "
    let value = SequenceTimestampParser.parse(original: raw, subseconds: fraction, offset: offset)
    XCTAssertEqual(value.originalRaw, raw)
    XCTAssertEqual(value.subsecondsRaw, fraction)
    XCTAssertEqual(value.offsetRaw, offset)
    XCTAssertEqual(value.local?.nanosecond, 123_456_789)
    XCTAssertEqual(value.subsecondDigits, 12)
    XCTAssertTrue(value.subsecondTruncated)
    XCTAssertGreaterThanOrEqual(value.warnings.count, 2)
    XCTAssertEqual(value.offsetMinutes, 480)
    XCTAssertTrue(value.isConsistent)
    let decoded = try JSONDecoder().decode(
      SequenceTimeEvidence.self, from: JSONEncoder().encode(value))
    XCTAssertEqual(decoded, value)
  }

  func testUTCRequiresExplicitValidOffsetAndDoesNotChangeCivilClock() throws {
    let local = "1970:01:01 08:00:00"
    let explicit = SequenceTimestampParser.parse(original: local, subseconds: "25", offset: "+08:00")
    XCTAssertEqual(explicit.local?.civilSecond, 28_800)
    XCTAssertEqual(try XCTUnwrap(explicit.utcInstant).timeIntervalSince1970, 0.25, accuracy: 0.000001)
    let noOffset = SequenceTimestampParser.parse(original: local, subseconds: "25", offset: nil)
    XCTAssertEqual(noOffset.local, explicit.local)
    XCTAssertNil(noOffset.utcInstant)
    for offset in ["Z", "+0800", "+14:01", "-15:00", "+01:60", "+aa:00"] {
      let value = SequenceTimestampParser.parse(original: local, subseconds: "25", offset: offset)
      XCTAssertNil(value.offsetMinutes, offset)
      XCTAssertNil(value.utcInstant, offset)
      XCTAssertEqual(value.local, explicit.local)
    }
    for offset in ["+14:00", "-14:00", "+00:00", "-00:00"] {
      XCTAssertNotNil(
        SequenceTimestampParser.parse(original: local, subseconds: nil, offset: offset).utcInstant)
    }
  }

  func testPrimaryTIFFCaptureClockReadsBothByteOrdersAndRejectsAnOutOfBoundsTag() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    for littleEndian in [true, false] {
      var fixture = Data(littleEndian ? [0x49, 0x49] : [0x4d, 0x4d])
      func field(_ value: Int, bytes: Int) {
        let parts = (0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        fixture.append(contentsOf: littleEndian ? parts : Array(parts.reversed()))
      }
      func entry(_ tag: Int, type: Int, count: Int) {
        field(tag, bytes: 2); field(type, bytes: 2); field(count, bytes: 4)
      }
      field(42, bytes: 2); field(8, bytes: 4)
      field(1, bytes: 2)
      entry(0x8769, type: 4, count: 1); field(26, bytes: 4)
      field(0, bytes: 4)
      field(3, bytes: 2)
      entry(0x9003, type: 2, count: 20); field(68, bytes: 4)
      entry(0x9011, type: 2, count: 7); field(88, bytes: 4)
      entry(0x9291, type: 2, count: 4); fixture.append(contentsOf: [0x30, 0x30, 0x35, 0])
      field(0, bytes: 4)
      fixture.append(contentsOf: "2026:10:24 12:34:56\0-07:30\0".utf8)
      try fixture.write(to: url)

      let clock = try XCTUnwrap(TIFFCaptureTimeTags.read(from: url))
      XCTAssertEqual(clock.dateTimeOriginal, "2026:10:24 12:34:56")
      XCTAssertEqual(clock.subsecTimeOriginal, "005")
      XCTAssertEqual(clock.offsetTimeOriginal, "-07:30")
      let date = "2026-10-24T12:34:56"
      let missingOffset = try XCTUnwrap(clock.supplementing(imageIODate: date, imageIOSubseconds: "0050", imageIOOffset: nil))
      XCTAssertEqual(missingOffset.offsetTimeOriginal, "-07:30")
      XCTAssertNil(missingOffset.subsecTimeOriginal)
      XCTAssertEqual(clock.supplementing(imageIODate: date, imageIOSubseconds: nil, imageIOOffset: "-07:30")?.subsecTimeOriginal, "005")
      XCTAssertNil(clock.supplementing(imageIODate: date, imageIOSubseconds: "006", imageIOOffset: nil))
      XCTAssertNil(clock.supplementing(imageIODate: date, imageIOSubseconds: nil, imageIOOffset: "+08:00"))
      XCTAssertNil(clock.supplementing(imageIODate: "2026-10-24T12:34:55", imageIOSubseconds: nil, imageIOOffset: nil))

      fixture.removeLast(1)
      try fixture.write(to: url)
      let truncated = try XCTUnwrap(TIFFCaptureTimeTags.read(from: url))
      XCTAssertEqual(truncated.subsecTimeOriginal, "005")
      XCTAssertNil(truncated.offsetTimeOriginal)
    }
  }

  func testCivilArithmeticAcrossGregorianBoundariesAndNoTimezoneFallback() throws {
    func time(_ text: String) throws -> SequenceCivilTime {
      try XCTUnwrap(SequenceTimestampParser.parse(original: text, subseconds: nil, offset: nil).local)
    }
    XCTAssertEqual(try time("1970:01:01 00:00:00").civilSecond, 0)
    XCTAssertEqual(try time("1969:12:31 23:59:59").civilSecond, -1)
    XCTAssertEqual(
      try time("2000:03:01 00:00:00").civilSecond - time("2000:02:28 00:00:00").civilSecond,
      172_800)
    XCTAssertEqual(
      try time("1900:03:01 00:00:00").civilSecond - time("1900:02:28 00:00:00").civilSecond,
      86_400)
  }

  func testForgedDerivedTimeIsNotConsistentWithRetainedRawEvidence() throws {
    let value = SequenceTimeEvidence(
      originalRaw: "2026:10:24 10:00:00", subsecondsRaw: nil, offsetRaw: nil,
      local: try SequenceCivilTime(year: 2026, month: 10, day: 24, hour: 10, minute: 0, second: 0),
      precision: .seconds, utcInstant: Date(timeIntervalSince1970: 0))
    XCTAssertFalse(value.isConsistent)
  }
}
