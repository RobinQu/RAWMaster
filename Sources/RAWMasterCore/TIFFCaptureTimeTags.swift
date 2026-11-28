import Foundation

/// Standard EXIF capture time fields read from the primary IFD of a classic TIFF container.
/// ImageIO remains the reader for the rest of the metadata, including non-TIFF formats.
package struct TIFFCaptureTimeTags {
    package let dateTimeOriginal: String
    package let subsecTimeOriginal: String?
    package let offsetTimeOriginal: String?

    package func supplementing(imageIODate: String, imageIOSubseconds: String?, imageIOOffset: String?) -> Self? {
        let physical = SequenceTimestampParser.parse(original: dateTimeOriginal,
            subseconds: subsecTimeOriginal, offset: offsetTimeOriginal)
        guard let local = physical.local else { return nil }
        let day = dateTimeOriginal.prefix(10).replacingOccurrences(of: ":", with: "-")
        let isoClock = day + "T" + dateTimeOriginal.suffix(8)
        // A copied XMP timestamp may override the physical EXIF clock. Keep its companion tags together.
        guard imageIODate == isoClock || imageIODate == dateTimeOriginal else { return nil }
        let imageIO = SequenceTimestampParser.parse(original: dateTimeOriginal,
            subseconds: imageIOSubseconds, offset: imageIOOffset)
        if imageIOSubseconds != nil {
            guard let fraction = imageIO.local?.nanosecond,
                  subsecTimeOriginal == nil || fraction == local.nanosecond else { return nil }
        }
        if imageIOOffset != nil {
            guard let offset = imageIO.offsetMinutes,
                  offsetTimeOriginal == nil || offset == physical.offsetMinutes else { return nil }
        }
        return .init(dateTimeOriginal: dateTimeOriginal,
                     subsecTimeOriginal: imageIOSubseconds == nil && local.nanosecond != nil ? subsecTimeOriginal : nil,
                     offsetTimeOriginal: imageIOOffset == nil && physical.offsetMinutes != nil ? offsetTimeOriginal : nil)
    }

    package static func read(from url: URL) throws -> Self? {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        return try read(from: source)
    }

    static func read(from source: FileHandle) throws -> Self? {
        func read(_ count: Int, at offset: Int) throws -> Data? {
            try source.seek(toOffset: UInt64(offset))
            guard let bytes = try source.read(upToCount: count), bytes.count == count else { return nil }
            return bytes
        }

        guard let header = try read(8, at: 0) else { return nil }
        let littleEndian: Bool
        switch (header[0], header[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4d, 0x4d): littleEndian = false
        default: return nil
        }

        func number(_ bytes: Data, at index: Int, count: Int) -> Int {
            let field = bytes[index..<(index + count)]
            return if littleEndian {
                field.reversed().reduce(0) { ($0 << 8) | Int($1) }
            } else {
                field.reduce(0) { ($0 << 8) | Int($1) }
            }
        }

        func directory(at offset: Int) throws -> (entries: Data, range: Range<Int>)? {
            guard offset >= 8, let header = try read(2, at: offset) else { return nil }
            let count = number(header, at: 0, count: 2)
            guard (1...1024).contains(count), let body = try read(count * 12 + 4, at: offset + 2) else { return nil }
            return (body.dropLast(4), offset..<(offset + 2 + body.count))
        }

        func entry(_ tag: Int, in directory: Data) -> Int? {
            var found: Int?
            for index in stride(from: 0, to: directory.count, by: 12)
                where number(directory, at: index, count: 2) == tag {
                guard found == nil else { return nil }
                found = index
            }
            return found
        }

        guard number(header, at: 2, count: 2) == 42,
              let primary = try directory(at: number(header, at: 4, count: 4)),
              let pointer = entry(0x8769, in: primary.entries),
              number(primary.entries, at: pointer + 2, count: 2) == 4,
              number(primary.entries, at: pointer + 4, count: 4) == 1,
              let exif = try directory(at: number(primary.entries, at: pointer + 8, count: 4)),
              !primary.range.overlaps(exif.range) else { return nil }

        func ascii(_ tag: Int, length: ClosedRange<Int>) throws -> String? {
            let entries = exif.entries
            guard let index = entry(tag, in: entries), number(entries, at: index + 2, count: 2) == 2 else { return nil }
            let count = number(entries, at: index + 4, count: 4)
            guard length.contains(count) else { return nil }
            let field = index + 8
            let bytes: Data?
            if count <= 4 {
                bytes = entries.subdata(in: field..<(field + count))
            } else {
                let offset = number(entries, at: field, count: 4)
                let valueRange = offset..<(offset + count)
                guard offset >= 8, !valueRange.overlaps(primary.range), !valueRange.overlaps(exif.range) else { return nil }
                bytes = try read(count, at: offset)
            }
            guard let bytes, bytes.last == 0, bytes.dropLast().allSatisfy({ (32...126).contains($0) }) else { return nil }
            return String(decoding: bytes.dropLast(), as: UTF8.self)
        }

        guard let date = try ascii(0x9003, length: 20...20) else { return nil }
        return .init(dateTimeOriginal: date,
                     subsecTimeOriginal: try ascii(0x9291, length: 2...64),
                     offsetTimeOriginal: try ascii(0x9011, length: 7...7))
    }
}
