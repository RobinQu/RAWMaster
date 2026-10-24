import Foundation
import CryptoKit
import Darwin
import RAWMasterCore

public enum RuntimeSequenceError: Error, LocalizedError {
    case invalid(String), providerUnavailable(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message), .providerUnavailable(let message): return message }
    }
}
struct RuntimeFieldDefinition: Codable, Sendable {
    let id, kind: String
    let selector: String?
    let tupleCount: Int?
}
enum RuntimeSequenceRegistry {
    static let fields: [RuntimeFieldDefinition] = [
        .init(id: "exif.Make", kind: "string", selector: "EXIF:Make", tupleCount: nil),
        .init(id: "exif.Model", kind: "string", selector: "EXIF:Model", tupleCount: nil),
        .init(id: "exif.DateTimeOriginal", kind: "string", selector: "EXIF:DateTimeOriginal", tupleCount: nil),
        .init(id: "exif.SubSecTimeOriginal", kind: "string", selector: "EXIF:SubSecTimeOriginal", tupleCount: nil),
        .init(id: "exif.OffsetTimeOriginal", kind: "string", selector: "EXIF:OffsetTimeOriginal", tupleCount: nil),
        .init(id: "exif.ExposureTime", kind: "number", selector: "EXIF:ExposureTime", tupleCount: nil),
        .init(id: "exif.Orientation", kind: "number", selector: "EXIF:Orientation", tupleCount: nil),
        .init(id: "exif.ImageNumber", kind: "number", selector: "EXIF:ImageNumber", tupleCount: nil),
        .init(id: "exif.ImageUniqueID", kind: "identity", selector: "EXIF:ImageUniqueID", tupleCount: nil),
        .init(id: "exif.RawDataUniqueID", kind: "identity", selector: "EXIF:RawDataUniqueID", tupleCount: nil),
        .init(id: "exif.SerialNumber", kind: "identity", selector: "EXIF:SerialNumber", tupleCount: nil),
        .init(id: "exif.CameraSerialNumber", kind: "identity", selector: "EXIF:CameraSerialNumber", tupleCount: nil),
        .init(id: "sony.SequenceNumber", kind: "number", selector: "Sony:SequenceNumber", tupleCount: nil),
        .init(id: "sony.SequenceImageNumber", kind: "number", selector: "Sony:SequenceImageNumber", tupleCount: nil),
        .init(id: "sony.SequenceFileNumber", kind: "number", selector: "Sony:SequenceFileNumber", tupleCount: nil),
        .init(id: "sony.SequenceLength", kind: "number", selector: "Sony:SequenceLength", tupleCount: nil),
        .init(id: "sony.ReleaseMode", kind: "number", selector: "Sony:ReleaseMode", tupleCount: nil),
        .init(id: "sony.ReleaseMode2", kind: "number", selector: "Sony:ReleaseMode2", tupleCount: nil),
        .init(id: "sony.ReleaseMode3", kind: "number", selector: "Sony:ReleaseMode3", tupleCount: nil),
        .init(id: "sony.DriveMode", kind: "number", selector: "Sony:DriveMode", tupleCount: nil),
        .init(id: "sony.DriveMode2", kind: "number", selector: "Sony:DriveMode2", tupleCount: nil),
        .init(id: "sony.DriveModeSetting", kind: "number", selector: "Sony:DriveModeSetting", tupleCount: nil),
        .init(id: "sony.ShutterType", kind: "number", selector: "Sony:ShutterType", tupleCount: nil),
        .init(id: "sony.SerialNumber", kind: "identity", selector: "Sony:SerialNumber", tupleCount: nil),
        .init(id: "sony.InternalSerialNumber", kind: "identity", selector: "Sony:InternalSerialNumber", tupleCount: nil),
        .init(id: "dji.SensorID", kind: "identity", selector: "DJI:SensorID", tupleCount: nil),
        .init(id: "xmp.ImageUniqueID", kind: "identity", selector: "XMP-exif:ImageUniqueID", tupleCount: nil),
        .init(id: "dji.unresolved.CaptureMode", kind: "number", selector: nil, tupleCount: nil),
        .init(id: "dji.unresolved.PhotoCaptureMode", kind: "number", selector: nil, tupleCount: nil),
        .init(id: "dji.unresolved.SequenceNumber", kind: "number", selector: nil, tupleCount: nil),
        .init(id: "dji.unresolved.CaptureUUID", kind: "number", selector: nil, tupleCount: nil),
        .init(id: "exif.UniqueCameraModel", kind: "string", selector: "EXIF:UniqueCameraModel", tupleCount: nil),
        .init(id: "xmpEX.ImageUniqueID", kind: "identity", selector: "XMP-exifEX:ImageUniqueID", tupleCount: nil),
        .init(id: "exif.ISO", kind: "number", selector: "EXIF:ISO", tupleCount: nil),
        .init(id: "exif.FNumber", kind: "number", selector: "EXIF:FNumber", tupleCount: nil),
        .init(id: "exif.FocalLength", kind: "number", selector: "EXIF:FocalLength", tupleCount: nil),
        .init(id: "exif.ExposureProgram", kind: "number", selector: "EXIF:ExposureProgram", tupleCount: nil),
        .init(id: "exif.ExifImageWidth", kind: "number", selector: "EXIF:ExifImageWidth", tupleCount: nil),
        .init(id: "exif.ExifImageHeight", kind: "number", selector: "EXIF:ExifImageHeight", tupleCount: nil),
        .init(id: "exif.ImageWidth", kind: "number", selector: "EXIF:ImageWidth", tupleCount: nil),
        .init(id: "exif.ImageHeight", kind: "number", selector: "EXIF:ImageHeight", tupleCount: nil),
        .init(id: "file.FileType", kind: "string", selector: "File:FileType", tupleCount: nil),
        .init(id: "file.MIMEType", kind: "string", selector: "File:MIMEType", tupleCount: nil),
        .init(id: "sony.FocusLocation", kind: "tuple", selector: "Sony:FocusLocation", tupleCount: 4),
        .init(id: "sony.FocusLocation2", kind: "tuple", selector: "Sony:FocusLocation2", tupleCount: 4),
        .init(id: "sony.FocusFrameSize", kind: "tuple", selector: "Sony:FocusFrameSize", tupleCount: 3),
        .init(id: "sony.FocusMode", kind: "code", selector: "Sony:FocusMode", tupleCount: nil),
        .init(id: "sony.AFAreaModeSetting", kind: "code", selector: "Sony:AFAreaModeSetting", tupleCount: nil),
        .init(id: "sony.AFAreaMode", kind: "code", selector: "Sony:AFAreaMode", tupleCount: nil),
        .init(id: "sony.FlexibleSpotPosition", kind: "tuple", selector: "Sony:FlexibleSpotPosition", tupleCount: 2),
        .init(id: "sony.AFPointSelected", kind: "code", selector: "Sony:AFPointSelected", tupleCount: nil),
        .init(id: "sony.AFTracking", kind: "code", selector: "Sony:AFTracking", tupleCount: nil),
        .init(id: "sony.FocusPosition2", kind: "code", selector: "Sony:FocusPosition2", tupleCount: nil),
        .init(id: "sony.CameraOrientation", kind: "code", selector: "Sony:CameraOrientation", tupleCount: nil),
        .init(id: "exif.SubjectDistance", kind: "distance", selector: "EXIF:SubjectDistance", tupleCount: nil)
    ]
    static var fingerprint: String { get throws { try SequenceFingerprint.digest(fields) } }
}

/// Parser-decoded JSONQ strings. Never reconstructs subsecond text through NSNumber.
public struct RuntimeMetadataInstance: Codable, Sendable, Equatable {
    let qualifiedSource, transport: String
    let components: [String]
}
public struct RuntimeNormalizedMetadata: Codable, Sendable, Equatable {
    var instances: [String:[RuntimeMetadataInstance]] = [:]
    var states: [String: SequenceMetadataFieldState] = [:]
    var strings: [String: String] = [:]
    var numbers: [String: String] = [:]
    var opaque: [String: String] = [:]
    var codes: [String: Int] = [:]
    var tuples: [String: [Int]] = [:]
    var warningDigests: [String] = []
}
enum RuntimeJSONQ {
    indirect enum Value { case string(String), array([Value]), object([String:Value]) }
    struct Parser {
        let bytes: [UInt8]; var index = 0
        mutating func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == 34 else { throw RuntimeSequenceError.invalid("JSONQ string expected") }
            let start = index; index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    index += 1
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
                index += 1
            }
            throw RuntimeSequenceError.invalid("Unterminated JSONQ string")
        }
        mutating func value(depth: Int = 0) throws -> Value {
            whitespace()
            guard depth < 5, index < bytes.count else { throw RuntimeSequenceError.invalid("JSONQ depth/end") }
            if bytes[index] == 34 { return .string(try string()) }
            if bytes[index] == 91 {
                index += 1; whitespace(); var values:[Value] = []
                if index < bytes.count && bytes[index] == 93 { index += 1; return .array(values) }
                while true {
                    guard values.count < (depth == 0 ? 1 : 16) else { throw RuntimeSequenceError.invalid("JSONQ array budget") }
                    values.append(try value(depth: depth+1)); whitespace()
                    guard index < bytes.count else { throw RuntimeSequenceError.invalid("JSONQ array end") }
                    let next = bytes[index]; index += 1
                    if next == 93 { return .array(values) }
                    guard next == 44 else { throw RuntimeSequenceError.invalid("JSONQ array delimiter") }
                }
            }
            if bytes[index] == 123 {
                index += 1; whitespace(); var fields:[String:Value] = [:]
                if index < bytes.count && bytes[index] == 125 { index += 1; return .object(fields) }
                while true {
                    whitespace(); let key = try string(); whitespace()
                    guard fields.count < 512, key.utf8.count <= 256, fields[key] == nil,
                          index < bytes.count, bytes[index] == 58 else { throw RuntimeSequenceError.invalid("JSONQ duplicate/key budget") }
                    index += 1; fields[key] = try value(depth: depth+1); whitespace()
                    guard index < bytes.count else { throw RuntimeSequenceError.invalid("JSONQ object end") }
                    let next = bytes[index]; index += 1
                    if next == 125 { return .object(fields) }
                    guard next == 44 else { throw RuntimeSequenceError.invalid("JSONQ object delimiter") }
                }
            }
            throw RuntimeSequenceError.invalid("JSONQ non-string scalar")
        }
    }
    static func parse(_ data: Data) throws -> [String:Value] {
        guard data.count <= 1024*1024 else { throw RuntimeSequenceError.invalid("JSONQ stdout budget") }
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(); parser.whitespace()
        guard parser.index == parser.bytes.count, case .array(let array) = value, array.count == 1,
              case .object(let fields) = array[0] else { throw RuntimeSequenceError.invalid("JSONQ document shape") }
        return fields
    }
    static func matches(_ key: String, field: RuntimeFieldDefinition) -> Bool {
        guard let selector = field.selector else { return false }
        let wanted = selector.split(separator: ":").map(String.init)
        var parts = key.split(separator: ":").map(String.init)
        // Family 0/1 equal names are collapsed by ExifTool (File:FileType).
        if wanted[0] == "File", parts.count == 2 {
            return parts[0] == "File" && ["FileType","MIMEType"].contains(parts[1]) && parts[1] == wanted[1]
        }
        guard parts.count == 3 || parts.count == 4 else { return false }
        if parts.count == 4 {
            guard parts[2].range(of: "^Copy[0-9]+$", options: .regularExpression) != nil else { return false }
            parts.remove(at: 2)
        }
        guard parts[2] == wanted[1] else { return false }
        switch wanted[0] {
        case "Sony": return parts[0] == "MakerNotes" && parts[1] == "Sony"
        case "DJI": return ["MakerNotes", "APP7"].contains(parts[0]) && parts[1] == "DJI"
        case "EXIF": return parts[0] == "EXIF" && (field.id == "exif.SubjectDistance" ? parts[1] == "ExifIFD" : ["ExifIFD","IFD0","IFD1","IFD2","SubIFD","SubIFD1","InteropIFD"].contains(parts[1]))
        case "XMP-exif", "XMP-exifEX": return parts[0] == "XMP" && parts[1] == wanted[0]
        case "File": return parts[0] == "File" && parts[1] == "File"
        default: return false
        }
    }
    /// Exact coefficient/exponent form, with bounded integer arithmetic and no floating rounding.
    static func canonicalNumber(_ text: String) -> String? {
        guard text.utf8.count <= 256, text.range(of: #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil else { return nil }
        var t = text.lowercased(); let negative = t.first == "-"
        if t.first == "-" || t.first == "+" { t.removeFirst() }
        let parts = t.split(separator: "e", omittingEmptySubsequences: false)
        guard let power = parts.count == 2 ? Int(parts[1]) : 0 else { return nil }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = mantissa.joined(); var zeros = 0
        while digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty { return "0" }
        while digits.last == "0" { digits.removeLast(); zeros += 1 }
        let (a, overflow1) = power.subtractingReportingOverflow(mantissa.count == 2 ? mantissa[1].count : 0)
        let (b, overflow2) = a.addingReportingOverflow(zeros)
        guard !overflow1, !overflow2 else { return nil }
        return (negative ? "-" : "") + digits + "e" + String(b)
    }
    static func normalize(_ data: Data, expectedSource: String, key: SymmetricKey) throws -> RuntimeNormalizedMetadata {
        let object = try parse(data)
        guard case .string(let source)? = object["SourceFile"], source == expectedSource else { throw RuntimeSequenceError.invalid("JSONQ source mismatch") }
        var instances: [String:[(String,Value)]] = [:]; var result = RuntimeNormalizedMetadata()
        func opaque(_ text: String, domain: String) -> String {
            HMAC<SHA256>.authenticationCode(for: Data(("RAWMaster.runtime.\(domain)\n"+text).utf8), using: key).map { String(format:"%02x",$0) }.joined()
        }
        for (name, value) in object where name != "SourceFile" {
            if name.range(of: #"\AExifTool:(?:ExifTool:)?(?:Copy[0-9]+:)?(?:Warning|Error)\z"#, options: .regularExpression) != nil {
                guard case .string(let text) = value, text.utf8.count <= 4096 else { throw RuntimeSequenceError.invalid("Metadata diagnostic shape/budget") }
                if name.hasSuffix(":Error") && !text.isEmpty { throw RuntimeSequenceError.invalid("Metadata tool reported an error") }
                if !text.isEmpty { result.warningDigests.append(opaque(text, domain: "warning")) }; continue
            }
            guard let field = RuntimeSequenceRegistry.fields.first(where: { matches(name, field:$0) }) else { throw RuntimeSequenceError.invalid("Unexpected qualified metadata field") }
            instances[field.id, default: []].append((name,value))
        }
        for field in RuntimeSequenceRegistry.fields {
            guard field.selector != nil else { result.states[field.id] = .unsupportedSelector; continue }
            guard let values = instances[field.id], !values.isEmpty else { result.states[field.id] = .absent; continue }
            var normalized:[String] = [], originals:[String] = [], tupleValues:[[Int]] = []; var invalid = false
            for (qualified,value) in values {
                var components:[String]
                let transport: String
                switch value {
                case .string(let text):
                    transport = "jsonq-string"
                    guard text.utf8.count <= 256 else { throw RuntimeSequenceError.invalid("Metadata scalar budget") }
                    components = field.kind == "tuple" ? text.split(maxSplits:16,whereSeparator: { $0.isWhitespace }).map(String.init) : [text]
                case .array(let array):
                    transport = "jsonq-string-array"
                    guard array.count <= 16 else { throw RuntimeSequenceError.invalid("Metadata component budget") }
                    components = try array.map { value in guard case .string(let text) = value, text.utf8.count <= 256 else { throw RuntimeSequenceError.invalid("Metadata vector shape/budget") }; return text }
                    if field.kind != "tuple" { invalid = true }
                default: transport = "invalid-object"; invalid = true; components = []
                }
                guard components.count <= 16 else { throw RuntimeSequenceError.invalid("Metadata component budget") }
                let retained = field.kind == "identity" ? components.map { opaque($0,domain:field.id) } : components
                result.instances[field.id, default:[]].append(RuntimeMetadataInstance(qualifiedSource:qualified,transport:transport,components:retained))
                if field.kind == "tuple" {
                    guard components.count == field.tupleCount else { invalid = true; continue }
                    let integers = components.compactMap { text -> Int? in
                        guard let number = canonicalNumber(text), let value = Decimal(string:text), value >= 0, value <= 65535,
                              let exact = canonicalNumber(NSDecimalNumber(decimal:value).stringValue), exact == number else { return nil }
                        let integer = NSDecimalNumber(decimal:value).intValue
                        return Decimal(integer) == value ? integer : nil
                    }
                    guard integers.count == components.count else { invalid = true; continue }
                    tupleValues.append(integers); normalized.append(integers.map(String.init).joined(separator:" ")); continue
                }
                guard components.count == 1 else { invalid = true; continue }
                let text = components[0]; originals.append(text)
                switch field.kind {
                case "number", "code":
                    guard let exact = canonicalNumber(text) else { invalid = true; continue }
                    if field.kind == "code" {
                        guard let d = Decimal(string:text), d >= 0, d <= Decimal(UInt32.max), canonicalNumber(NSDecimalNumber(decimal:d).stringValue) == exact,
                              Decimal(NSDecimalNumber(decimal:d).int64Value) == d else { invalid = true; continue }
                    } else if SequenceCaptureEvents.decimal(text) == nil { invalid = true; continue }
                    normalized.append(exact)
                case "distance":
                    if ["inf","undef"].contains(text.lowercased()) { normalized.append(text.lowercased()) }
                    else if let exact = canonicalNumber(text), !exact.hasPrefix("-") { normalized.append(exact) }
                    else { invalid = true }
                case "identity": normalized.append(opaque(text, domain:field.id))
                default: normalized.append(text)
                }
            }
            if invalid || normalized.count != values.count { result.states[field.id] = .invalid; continue }
            guard Set(normalized).count == 1 else { result.states[field.id] = .conflicting; continue }
            result.states[field.id] = .present
            switch field.kind {
            case "number": result.numbers[field.id] = originals[0]
            case "code": result.codes[field.id] = NSDecimalNumber(string: originals[0]).intValue
            case "tuple": result.tuples[field.id] = tupleValues[0]
            case "identity": result.opaque[field.id] = normalized[0]
            default: result.strings[field.id] = originals.first
            }
        }
        for field in result.instances.keys { result.instances[field]?.sort { $0.qualifiedSource < $1.qualifiedSource } }
        result.warningDigests.sort()
        return result
    }
}

/// Only a bundled or explicitly injected development root is considered; never PATH/HOME/network.
struct RuntimeSequenceTool: Sendable {
    static let commit = "2200871d9cef988051d2a99d67df3bda6cbb30a8"
    struct Manifest: Codable { let version, commit, closureSHA256: String; let files:[String:String] }
    let root: URL
    let closureSHA256: String
    init(root explicit: URL? = nil) throws {
        guard let root = explicit ?? Bundle.main.resourceURL?.appendingPathComponent("MetadataTool") else { throw RuntimeSequenceError.invalid("分组元数据组件不可用") }
        let bytes = try Self.boundedData(root.appendingPathComponent("manifest.json"), maximum: 2*1024*1024)
        let manifest = try JSONDecoder().decode(Manifest.self, from:bytes)
        guard manifest.version == "13.59", manifest.commit == Self.commit, manifest.files.count > 100,
              manifest.files.count < 10000, manifest.files["exiftool"] != nil, manifest.files["lib/Image/ExifTool.pm"] != nil,
              manifest.files["README"] != nil, manifest.files["LICENSE"] != nil else { throw RuntimeSequenceError.invalid("分组元数据组件清单无效") }
        let encoded = manifest.files.keys.sorted().map { $0+"\0"+manifest.files[$0]!+"\n" }.joined()
        guard SequenceMetadataEvidenceLoader.sha256(Data(encoded.utf8)) == manifest.closureSHA256 else { throw RuntimeSequenceError.invalid("分组元数据组件闭包无效") }
        for (path, expected) in manifest.files {
            let file = try SequenceMetadataEvidenceLoader.resolve(path,root:root)
            guard SequenceMetadataEvidenceLoader.isSHA(expected), try Self.hash(file) == expected else { throw RuntimeSequenceError.invalid("分组元数据组件已改变") }
        }
        self.root = root; self.closureSHA256 = manifest.closureSHA256
    }
    static func boundedData(_ url:URL, maximum:Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount:maximum+1) ?? Data()
        guard bytes.count <= maximum else { throw RuntimeSequenceError.invalid("组件文件超出预算") }; return bytes
    }
    static func hash(_ url: URL, check: () throws -> Void = {}) throws -> String {
        let before = try SequenceFileCredential.capture(at:url)
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var digest = SHA256()
        while true { try check(); let bytes = try handle.read(upToCount:1024*1024) ?? Data(); if bytes.isEmpty { break }; digest.update(data:bytes) }
        guard try SequenceFileCredential.capture(at:url) == before else { throw RuntimeSequenceError.invalid("分组时素材发生变化") }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    func read(_ url: URL, check: () throws -> Void) throws -> Data {
        let selectors = RuntimeSequenceRegistry.fields.compactMap(\.selector).map { "-"+$0 }
        return try RuntimeMetadataChild.run(arguments:[root.appendingPathComponent("exiftool").path,"-config","","-api","StructFormat=JSONQ","-j","-n","-a","-G0:1:4"]+selectors+["-ExifTool:Warning","-ExifTool:Error",url.path],check:check)
    }
}
/// Isolated process group, concurrent bounded pipe draining, cancellation and reap.
enum RuntimeMetadataChild {
    static func run(arguments:[String], timeout:Double = 15, check:() throws->Void) throws -> Data {
        try check()
        var stdoutPipe:[Int32] = [0,0], stderrPipe:[Int32] = [0,0]
        guard pipe(&stdoutPipe) == 0 else { throw RuntimeSequenceError.providerUnavailable("Metadata stdout pipe") }
        guard pipe(&stderrPipe) == 0 else { close(stdoutPipe[0]);close(stdoutPipe[1]);throw RuntimeSequenceError.providerUnavailable("Metadata stderr pipe") }
        var actions:posix_spawn_file_actions_t?, attributes:posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO,"/dev/null",O_RDONLY,0)
        for fd in stdoutPipe+stderrPipe { posix_spawn_file_actions_addclose(&actions,fd) }
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes,0)
        let argv = (["/usr/bin/perl"]+arguments).map { strdup($0) }+[nil]
        let envStrings: [String] = ["PATH=/usr/bin:/bin","LANG=C","LC_ALL=C"]
        let env: [UnsafeMutablePointer<CChar>?] = envStrings.map { text in text.withCString { strdup($0) } }+[nil]
        defer { for value in argv+env { if let value { free(value) } } }
        var pid:pid_t = 0
        let status = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            posix_spawn(&pid,"/usr/bin/perl",&actions,&attributes,UnsafeMutablePointer(mutating:a.baseAddress!),UnsafeMutablePointer(mutating:e.baseAddress!))
        } }
        close(stdoutPipe[1]);close(stderrPipe[1])
        defer { close(stdoutPipe[0]);close(stderrPipe[0]) }
        guard status == 0 else { throw RuntimeSequenceError.providerUnavailable("无法启动分组元数据组件") }
        for fd in [stdoutPipe[0],stderrPipe[0]] { _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK) }
        var reaped = false, childStatus:Int32 = 0
        defer {
            kill(-pid,SIGTERM)
            if !reaped {
                // Always reap even on cancellation, and terminate inherited pipe holders.
                for _ in 0..<10 { if waitpid(pid,&childStatus,WNOHANG) == pid { reaped = true;break }; usleep(10000) }
                kill(-pid,SIGKILL)
                if !reaped { while waitpid(pid,&childStatus,0) == -1 && errno == EINTR {} }
            }
            kill(-pid,SIGKILL)
        }
        var output = Data(), errorBytes = 0, stdoutEnd = false, stderrEnd = false
        let started = ProcessInfo.processInfo.systemUptime
        while !reaped || !stdoutEnd || !stderrEnd {
            try check()
            guard ProcessInfo.processInfo.systemUptime-started < timeout else { throw RuntimeSequenceError.invalid("分组元数据读取超时") }
            for (fd,isOutput) in [(stdoutPipe[0],true),(stderrPipe[0],false)] {
                var buffer = [UInt8](repeating:0,count:8192)
                while true {
                    let count = Darwin.read(fd,&buffer,buffer.count)
                    if count > 0 {
                        if isOutput { guard output.count+count <= 1024*1024 else { throw RuntimeSequenceError.invalid("Metadata stdout budget") }; output.append(contentsOf:buffer.prefix(count)) }
                        else { errorBytes += count; guard errorBytes <= 64*1024 else { throw RuntimeSequenceError.invalid("Metadata stderr budget") } }
                    } else if count == 0 { if isOutput { stdoutEnd = true } else { stderrEnd = true };break }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else if errno != EINTR { throw RuntimeSequenceError.invalid("Metadata pipe read") }
                }
            }
            if !reaped { let status = waitpid(pid,&childStatus,WNOHANG); if status == pid { reaped = true }; if status == -1 && errno != EINTR { throw RuntimeSequenceError.invalid("Metadata wait failed") } }
            if !reaped || !stdoutEnd || !stderrEnd { usleep(5000) }
        }
        guard childStatus == 0 || !output.isEmpty else { throw RuntimeSequenceError.providerUnavailable("分组元数据组件启动或运行失败") }
        return output
    }
}
