#!/usr/bin/env swift
import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
import Darwin

// Standalone offline builder. No application/diagnostic algorithms or metadata sidecar injection.
struct BuildError: Error, CustomStringConvertible { let description: String; init(_ message: String) { description = message } }
struct InputSpec: Decodable {
    struct Recipe: Codable {
        let maximumPixel: Int; let jpegQuality: Double; let colorSpace: String; let orientation: Int; let rawMode: String
        let exposureAbsoluteToleranceSeconds: Double; let exposureRelativeTolerance: Double
    }
    struct Case: Decodable {
        struct File: Decodable { let assetID: String; let ordinal: Int; let relativePath: String }
        let id: String; let sourceRelativeRoot: String; let files: [File]; let truthPath: String
        let completeGroupTruth: Bool; let unknownAssetIDs: [String]
    }
    let schemaVersion: Int; let datasetID: String; let recipe: Recipe; let cases: [Case]
}
struct Credential: Equatable {
    let device: Int32; let inode: UInt64; let size: Int64
    let modifiedSeconds: Int; let modifiedNanos: Int; let changedSeconds: Int; let changedNanos: Int
}
func credential(_ url: URL) throws -> Credential {
    var value = Darwin.stat()
    let result = url.path.withCString { Darwin.fstatat(AT_FDCWD, $0, &value, AT_SYMLINK_NOFOLLOW) }
    guard result == 0, (value.st_mode & S_IFMT) == S_IFREG else { throw BuildError("Source is not an accessible regular file: \(url.lastPathComponent)") }
    return Credential(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                      modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanos: value.st_mtimespec.tv_nsec,
                      changedSeconds: value.st_ctimespec.tv_sec, changedNanos: value.st_ctimespec.tv_nsec)
}
func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while try autoreleasepool(invoking: { () throws -> Bool in
        let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
        guard !data.isEmpty else { return false }
        hash.update(data: data); return true
    }) {}
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func relativeURL(_ path: String, under base: URL) throws -> URL {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\"), !parts.isEmpty,
          !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw BuildError("Unsafe relative path") }
    let root = base.standardizedFileURL.resolvingSymlinksInPath()
    let result = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
    guard result.path.hasPrefix(root.path + "/") else { throw BuildError("Relative path escapes its base") }
    return result
}
// Resolve the existing ancestor too: final/staging paths may not exist yet.
func canonicalDestination(_ url: URL) -> URL {
    var ancestor = url.standardizedFileURL, suffix: [String] = []
    while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
        suffix.insert(ancestor.lastPathComponent, at: 0)
        ancestor.deleteLastPathComponent()
    }
    return suffix.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL
}
func overlaps(_ first: URL, _ second: URL) -> Bool {
    func contained(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
    }
    return contained(first, second) || contained(second, first)
}
func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10]) }
func writeJSON(_ object: Any, to url: URL) throws { try jsonData(object).write(to: url, options: .withoutOverwriting) }
func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
struct Capture {
    let date: String?; let subsec: String?; let offset: String?; let exposure: Double?; let make: String?; let model: String?; let orientation: Int?
    var object: [String: Any] { ["dateTimeOriginalRaw": nullable(date), "subsecTimeOriginalRaw": nullable(subsec), "offsetTimeOriginalRaw": nullable(offset), "exposureSeconds": nullable(exposure), "cameraMake": nullable(make), "cameraModel": nullable(model), "orientation": nullable(orientation)] }
    func upright() -> Capture { Capture(date: date, subsec: subsec, offset: offset, exposure: exposure, make: make, model: model, orientation: 1) }
}
func capture(_ properties: [String: Any]) throws -> Capture {
    let exif = dictionary(properties[kCGImagePropertyExifDictionary as String])
    let tiff = dictionary(properties[kCGImagePropertyTIFFDictionary as String])
    func string(_ values: [String: Any], _ key: CFString) throws -> String? {
        guard let value = values[key as String] else { return nil }
        guard let result = value as? String else { throw BuildError("Whitelisted EXIF string has an unexpected type: \(key)") }
        return result
    }
    var exposure: Double?
    if let raw = exif[kCGImagePropertyExifExposureTime as String] {
        guard let number = raw as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else { throw BuildError("Invalid source exposure") }
        exposure = number.doubleValue
    }
    let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue
    guard orientation == nil || (1...8).contains(orientation!) else { throw BuildError("Invalid orientation") }
    return Capture(date: try string(exif, kCGImagePropertyExifDateTimeOriginal), subsec: try string(exif, kCGImagePropertyExifSubsecTimeOriginal), offset: try string(exif, kCGImagePropertyExifOffsetTimeOriginal), exposure: exposure, make: try string(tiff, kCGImagePropertyTIFFMake), model: try string(tiff, kCGImagePropertyTIFFModel), orientation: orientation)
}
let rawExtensions: Set<String> = ["arw", "dng", "cr2", "cr3", "nef", "nrw", "raf", "rw2", "orf", "pef", "srw"]
func convert(_ input: URL, to output: URL, recipe: InputSpec.Recipe) throws -> (Capture, Double?, Int, Int) {
    guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw BuildError("ImageIO cannot read source metadata: \(input.lastPathComponent)") }
    let metadata = try capture(props)
    let isRAW = rawExtensions.contains(input.pathExtension.lowercased())
    guard isRAW || ["jpg", "jpeg"].contains(input.pathExtension.lowercased()) else { throw BuildError("Unapproved input format") }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: !isRAW,
        kCGImageSourceCreateThumbnailFromImageAlways: !isRAW, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: recipe.maximumPixel, kCGImageSourceShouldCacheImmediately: true]
    guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw BuildError("No embedded preview (RAW fallback prohibited): \(input.lastPathComponent)") }
    guard preview.width > 0, preview.height > 0, max(preview.width, preview.height) <= recipe.maximumPixel,
          let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: preview.width, height: preview.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw BuildError("Cannot allocate bounded sRGB preview") }
    context.interpolationQuality = .high; context.draw(preview, in: CGRect(x: 0, y: 0, width: preview.width, height: preview.height))
    guard let rendered = context.makeImage(), let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.jpeg" as CFString, 1, nil) else { throw BuildError("Cannot create fixture JPEG") }
    var exif: [CFString: Any] = [:], tiff: [CFString: Any] = [kCGImagePropertyTIFFOrientation: 1]
    if let value = metadata.date { exif[kCGImagePropertyExifDateTimeOriginal] = value }
    if let value = metadata.subsec { exif[kCGImagePropertyExifSubsecTimeOriginal] = value }
    if let value = metadata.offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = value }
    if let value = metadata.exposure { exif[kCGImagePropertyExifExposureTime] = value }
    if let value = metadata.make { tiff[kCGImagePropertyTIFFMake] = value }
    if let value = metadata.model { tiff[kCGImagePropertyTIFFModel] = value }
    let outputProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: recipe.jpegQuality, kCGImagePropertyExifDictionary: exif,
                                     kCGImagePropertyTIFFDictionary: tiff, kCGImagePropertyOrientation: 1]
    CGImageDestinationAddImage(destination, rendered, outputProps as CFDictionary)
    guard CGImageDestinationFinalize(destination), let check = CGImageSourceCreateWithURL(output as CFURL, nil),
          CGImageSourceGetType(check) as String? == "public.jpeg",
          let checkProps = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [String: Any],
          let decoded = CGImageSourceCreateImageAtIndex(check, 0, nil), decoded.width == preview.width, decoded.height == preview.height else { throw BuildError("Fixture JPEG decode/type/dimension verification failed") }
    let actual = try capture(checkProps)
    guard actual.date == metadata.date, actual.subsec == metadata.subsec, actual.offset == metadata.offset,
          actual.make == metadata.make, actual.model == metadata.model, actual.orientation == 1 else { throw BuildError("Exact capture metadata failed roundtrip: \(input.lastPathComponent)") }
    let tolerance = max(recipe.exposureAbsoluteToleranceSeconds, abs(metadata.exposure ?? 0) * recipe.exposureRelativeTolerance)
    switch (metadata.exposure, actual.exposure) {
    case (nil, nil): break
    case let (expected?, measured?) where abs(expected - measured) <= tolerance: break
    default: throw BuildError("Exposure metadata failed bounded roundtrip: \(input.lastPathComponent)")
    }
    guard checkProps[kCGImagePropertyGPSDictionary as String] == nil else { throw BuildError("Unexpected GPS metadata") }
    let outputEXIF = dictionary(checkProps[kCGImagePropertyExifDictionary as String])
    guard outputEXIF[kCGImagePropertyExifMakerNote as String] == nil,
          outputEXIF[kCGImagePropertyExifBodySerialNumber as String] == nil,
          outputEXIF[kCGImagePropertyExifLensSerialNumber as String] == nil,
          checkProps[kCGImagePropertyExifAuxDictionary as String] == nil else { throw BuildError("Unexpected private camera metadata") }
    return (metadata, actual.exposure, preview.width, preview.height)
}
struct SourceRecord { let key: String; let url: URL; let credential: Credential; let hash: String }
func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 8 else { throw BuildError("Usage: make-sequence-fixtures --input-spec <cases.json> --source-base <original-root> --output <absent-fixture-root> --staging-base <output/staging>") }
    var args: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let key = arguments[index]
        guard ["--input-spec", "--source-base", "--output", "--staging-base"].contains(key), args[key] == nil else { throw BuildError("Unknown or duplicate argument") }
        args[key] = arguments[index + 1]
    }
    guard let specPath = args["--input-spec"], let sourcePath = args["--source-base"], let outputPath = args["--output"], let stagingPath = args["--staging-base"] else { throw BuildError("Missing argument") }
    let manager = FileManager.default, specURL = URL(fileURLWithPath: specPath).standardizedFileURL
    let sourceBase = canonicalDestination(URL(fileURLWithPath: sourcePath))
    let finalURL = canonicalDestination(URL(fileURLWithPath: outputPath))
    let stagingBase = canonicalDestination(URL(fileURLWithPath: stagingPath))
    // Before opening or hashing any media, reject equality and containment in either direction.
    // This includes symlinked existing ancestors of an otherwise absent destination.
    guard !manager.fileExists(atPath: finalURL.path), !overlaps(sourceBase, finalURL),
          !overlaps(sourceBase, stagingBase), !overlaps(stagingBase, finalURL) else {
        throw BuildError("Final destination exists or canonical source/staging/output paths overlap")
    }
    let spec = try JSONDecoder().decode(InputSpec.self, from: Data(contentsOf: specURL))
    let expectedCounts = ["burst123": 123, "burst14-context38": 38, "burst48-context72": 72, "interval427-context439": 439, "burst193-context217": 217, "dji187-context376": 376]
    guard spec.schemaVersion == 1, spec.datasetID == "sequence-grouping-jpeg-v1", spec.cases.count == 6,
          Set(spec.cases.map(\.id)) == Set(expectedCounts.keys), spec.recipe.maximumPixel == 1024, spec.recipe.jpegQuality == 0.8,
          spec.recipe.colorSpace == "sRGB", spec.recipe.orientation == 1, spec.recipe.rawMode == "embedded-preview-only",
          spec.recipe.exposureAbsoluteToleranceSeconds == 1e-8, spec.recipe.exposureRelativeTolerance == 1e-6 else { throw BuildError("Unsupported input specification/recipe") }
    var records: [SourceRecord] = []
    for item in spec.cases {
        guard item.files.count == expectedCounts[item.id], Set(item.files.map(\.assetID)).count == item.files.count,
              Set(item.files.map(\.relativePath)).count == item.files.count else { throw BuildError("Invalid case count or duplicate identity") }
        let root = try relativeURL(item.sourceRelativeRoot, under: sourceBase)
        for (ordinal, file) in item.files.enumerated() {
            guard file.ordinal == ordinal, file.assetID == String(format: "asset%04d", ordinal) else { throw BuildError("Noncanonical input order/identity") }
            let url = try relativeURL(file.relativePath, under: root), before = try credential(url), hash = try sha256(url)
            guard try credential(url) == before else { throw BuildError("Source changed during before hash: \(file.assetID)") }
            records.append(SourceRecord(key: item.id + "/" + file.assetID, url: url, credential: before, hash: hash))
        }
    }
    try manager.createDirectory(at: stagingBase, withIntermediateDirectories: true)
    try manager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stage = stagingBase.appendingPathComponent("sequence-fixtures-" + UUID().uuidString)
    try manager.createDirectory(at: stage, withIntermediateDirectories: false)
    // Failed stages stay outside formal resources, for explicit diagnosis. Never publish partially.
    try manager.createDirectory(at: stage.appendingPathComponent("truth"), withIntermediateDirectories: false)
    var indexCases: [[String: Any]] = [], sourceIndex = 0
    for item in spec.cases {
        let caseRoot = stage.appendingPathComponent("cases/" + item.id)
        try manager.createDirectory(at: caseRoot.appendingPathComponent("files"), withIntermediateDirectories: true)
        var files: [[String: Any]] = [], metadataRows: [[String: Any]] = []
        for file in item.files {
            let record = records[sourceIndex]; sourceIndex += 1
            let converted = try autoreleasepool { () throws -> ([String: Any], [String: Any]) in
                guard try credential(record.url) == record.credential else { throw BuildError("Source changed before conversion: \(record.key)") }
                let relative = "files/" + file.assetID + ".jpg", output = caseRoot.appendingPathComponent(relative)
                let (capture, actualExposure, width, height) = try convert(record.url, to: output, recipe: spec.recipe)
                guard try credential(record.url) == record.credential else { throw BuildError("Source changed during conversion: \(record.key)") }
                let fileRow: [String: Any] = ["assetID": file.assetID, "ordinal": file.ordinal, "relativePath": relative,
                    "jpegSHA256": try sha256(output), "width": width, "height": height,
                    "sourceCapture": ["relativePath": item.sourceRelativeRoot + "/" + file.relativePath, "originalExtension": record.url.pathExtension, "sha256": record.hash]]
                let allowed = max(spec.recipe.exposureAbsoluteToleranceSeconds, abs(capture.exposure ?? 0) * spec.recipe.exposureRelativeTolerance)
                let difference: Double? = capture.exposure.flatMap { expected in actualExposure.map { abs(expected - $0) } }
                let metadataRow: [String: Any] = ["assetID": file.assetID, "sourceCapture": capture.object, "expectedJPEG": capture.upright().object,
                    "exposureRoundtrip": ["actualSeconds": nullable(actualExposure), "absoluteDifferenceSeconds": nullable(difference), "allowedDifferenceSeconds": allowed],
                    "sourceIntegrity": ["sha256Before": record.hash, "sha256After": record.hash, "credentialUnchanged": true]]
                return (fileRow, metadataRow)
            }
            files.append(converted.0); metadataRows.append(converted.1)
        }
        let manifestURL = caseRoot.appendingPathComponent("manifest.json"), metadataURL = caseRoot.appendingPathComponent("metadata.json")
        try writeJSON(["schemaVersion": 1, "scopeID": "fixture-" + item.id, "sessionID": "fixture-" + item.id,
                       "orderVersion": "session-natural-path-v1", "files": files], to: manifestURL)
        try writeJSON(["schemaVersion": 1, "caseID": item.id, "assets": metadataRows], to: metadataURL)
        let truthInput = try relativeURL(item.truthPath, under: specURL.deletingLastPathComponent())
        let truthURL = stage.appendingPathComponent("truth/" + item.id + ".json")
        try manager.copyItem(at: truthInput, to: truthURL)
        indexCases.append(["id": item.id, "assetCount": item.files.count,
            "manifestPath": "cases/" + item.id + "/manifest.json", "metadataPath": "cases/" + item.id + "/metadata.json", "truthPath": "truth/" + item.id + ".json",
            "manifestSHA256": try sha256(manifestURL), "metadataSHA256": try sha256(metadataURL), "truthSHA256": try sha256(truthURL),
            "completeGroupTruth": item.completeGroupTruth, "unknownAssetIDs": item.unknownAssetIDs])
        print("Converted \(item.id): \(item.files.count) / \(records.count) total inputs")
    }
    for record in records {
        guard try credential(record.url) == record.credential else { throw BuildError("Source changed before final hash: \(record.key)") }
        let afterHash = try sha256(record.url)
        guard afterHash == record.hash, try credential(record.url) == record.credential else { throw BuildError("Source full hash/credential changed: \(record.key)") }
    }
    let recipeObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec.recipe))
    try writeJSON(["schemaVersion": 1, "datasetID": spec.datasetID, "converterVersion": "sequence-fixtures-imageio-v1", "assetCount": records.count, "recipe": recipeObject, "cases": indexCases], to: stage.appendingPathComponent("index.json"))
    try manager.copyItem(at: specURL.deletingLastPathComponent().appendingPathComponent("README.md"), to: stage.appendingPathComponent("README.md"))
    var sourceStat = Darwin.stat(), destinationStat = Darwin.stat()
    let sourceStatus = stage.path.withCString { Darwin.fstatat(AT_FDCWD, $0, &sourceStat, 0) }
    let destinationStatus = finalURL.deletingLastPathComponent().path.withCString { Darwin.fstatat(AT_FDCWD, $0, &destinationStat, 0) }
    guard sourceStatus == 0, destinationStatus == 0, sourceStat.st_dev == destinationStat.st_dev else { throw BuildError("Atomic publication requires same-filesystem staging") }
    // RENAME_EXCL protects against another process creating the destination after preflight.
    let renamed = stage.path.withCString { a in finalURL.path.withCString { b in Darwin.renameatx_np(AT_FDCWD, a, AT_FDCWD, b, UInt32(RENAME_EXCL)) } }
    guard renamed == 0 else { throw BuildError("Atomic publication refused/failed (errno \(errno)); verified stage retained") }
    print("Published \(records.count) verified JPEG fixtures; source hashes and credentials unchanged")
}
do { try run() } catch {
    FileHandle.standardError.write(Data("Fixture build FAILED: \(error)\n".utf8)); exit(1)
}
