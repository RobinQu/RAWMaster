import CoreImage
import Foundation

/// Large unsigned TIFF uses uncompressed top-first strips with a bounded working buffer.
/// Image I/O still reads the staged result and verifies its size, depth and ICC before publication.
enum LargeTIFF16Writer {
    static let rowsPerStrip=384
    private struct Tag {
        let number:UInt16, type:UInt16, count:UInt32, bytes:Data
        static func shorts(_ number:UInt16,_ values:[UInt16]) -> Self {
            .init(number:number,type:3,count:UInt32(values.count),bytes:encoded(values))
        }
        static func longs(_ number:UInt16,_ values:[UInt32]) -> Self {
            .init(number:number,type:4,count:UInt32(values.count),bytes:encoded(values))
        }
    }
    private static func encoded<T:FixedWidthInteger>(_ values:[T]) -> Data {
        values.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }
    private static func directory(_ tags:[Tag]) -> Data {
        var table=Data([73,73,42,0,8,0,0,0]), extensions=Data()
        table.append(encoded([UInt16(tags.count)]))
        let firstOffset=8+2+tags.count*12+4
        for tag in tags.sorted(by:{$0.number<$1.number}) {
            table.append(encoded([tag.number,tag.type]));table.append(encoded([tag.count]))
            if tag.bytes.count <= 4 {
                table.append(tag.bytes);table.append(Data(repeating:0,count:4-tag.bytes.count))
            } else {
                if (firstOffset+extensions.count)%2 != 0 { extensions.append(0) }
                table.append(encoded([UInt32(firstOffset+extensions.count)]));extensions.append(tag.bytes)
            }
        }
        table.append(encoded([UInt32(0)]));table.append(extensions)
        if table.count%2 != 0 { table.append(0) }
        return table
    }

    /// Let Image I/O choose its container if this photograph exceeds classic TIFF's UInt32 offsets.
    static func writeIfRepresentable(image:CIImage, layout:TIFF16Output.Layout, context:CIContext,
                                     colorSpace:CGColorSpace, url:URL, legacyMask:DevelopmentLegacyMaskOutput? = nil) throws -> Bool {
        guard let profile=colorSpace.copyICCData() as Data?, !profile.isEmpty else { throw DevelopmentError.invalidEncoding }
        guard layout.payload < Int(UInt32.max), layout.width<=Int(UInt32.max), layout.height<=Int(UInt32.max) else { return false }
        let counts = stride(from:0,to:layout.height,by:rowsPerStrip).map {
            UInt32(min(rowsPerStrip,layout.height-$0)*layout.rowBytes)
        }
        func header(_ offsets:[UInt32]) -> Data {
            let values:[Tag]=[.longs(256,[UInt32(layout.width)]),.longs(257,[UInt32(layout.height)]),
                .shorts(258,[16,16,16,16]),.shorts(259,[1]),.shorts(262,[2]),.longs(273,offsets),
                .shorts(274,[1]),.shorts(277,[4]),.longs(278,[UInt32(rowsPerStrip)]),.longs(279,counts),
                .shorts(284,[1]),.shorts(338,[2]),.shorts(339,[1,1,1,1]),
                .init(number:34675,type:7,count:UInt32(profile.count),bytes:profile)]
            return directory(values)
        }
        let headerSize=header(Array(repeating:0,count:counts.count)).count
        guard layout.payload <= Int(UInt32.max)-headerSize else {return false}
        var offset=UInt32(headerSize)
        let offsets=counts.map { bytes in defer { offset += bytes };return offset }
        let bytes=header(offsets)
        guard bytes.count==headerSize else {throw DevelopmentError.invalidEncoding}
        let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
        guard fd>=0 else {throw POSIXError(.init(rawValue:errno) ?? .EIO)}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        let capacity=min(rowsPerStrip,layout.height)*layout.rowBytes
        let band=UnsafeMutableRawPointer.allocate(byteCount:capacity,alignment:4096)
        defer {band.deallocate()}
        do {
            try file.write(contentsOf:bytes)
            for top in stride(from:0,to:layout.height,by:rowsPerStrip) {
                try Task.checkCancellation()
                let h=min(rowsPerStrip,layout.height-top)
                try TIFF16Output.renderBand(image,context:context,colorSpace:colorSpace,layout:layout,
                                            format:.tiff16,top:top,height:h,buffer:band)
                try legacyMask?.restore(buffer:band, rowBytes:layout.rowBytes, top:top, rows:h, format:.tiff16, colorSpace:colorSpace)
                try file.write(contentsOf:Data(bytesNoCopy:band,count:h*layout.rowBytes,deallocator:.none))
            }
            try file.close()
            guard try TIFF16Output.storedAlpha(url:url) == .straight else { throw DevelopmentError.invalidEncoding }
            return true
        } catch {
            try? file.close();try? FileManager.default.removeItem(at:url);throw error
        }
    }
}
