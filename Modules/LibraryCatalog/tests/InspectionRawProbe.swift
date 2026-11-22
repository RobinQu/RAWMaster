import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SQLite3

struct ProbeInput: Decodable {
  let id, path, digest: String
  let size: Int64
}
struct ProbeFrame: Decodable {
  let id: String
  let point: [Double]?
}
struct ProbeReview: Decodable { let id, value: String }
struct ProbeGroup: Decodable {
  let manualReview: ProbeReview?
  let id, basis: String
  let frames: [ProbeFrame]
}
struct ProbeManifest: Decodable {
  let inputs: [ProbeInput]
  let groups: [ProbeGroup]
}
func number(_ v: CatalogJSON?) -> Double? {
  if case .integer(let n)? = v { return Double(n) }
  if case .number(let n)? = v { return n }
  return nil
}
@main struct Probe {
  static func main() async throws {
    let args = CommandLine.arguments
    let url = URL(fileURLWithPath: args[1])
    let manifest = try JSONDecoder().decode(
      ProbeManifest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let exif = URL(fileURLWithPath: args[3])
    let dest = URL(fileURLWithPath: args[4])
    let db = try ProbeWriter(url)
    let actions = CatalogActions(database: url) { try db.transaction("command", $0) }
    _ = try db.transaction("install")
    _ = try db.transaction("flushLegacy")
    _ = try await actions.perform(
      "session.seal",
      [
        "sessionID": .string("s"),
        "items": .array(
          manifest.inputs.map {
            .object(["occurrenceID": .string($0.id), "disposition": .string("admitted")])
          }),
      ])
    var files = [String: LibraryInspectionFile]()
    var metadata = [String: CatalogJSON]()
    var report = [String: CatalogJSON]()
    for entry in manifest.inputs {
      let id = entry.id
      let file = LibraryInspectionFile(
        fileID: id, contentID: "sha256:\(entry.digest):\(entry.size)",
        url: URL(fileURLWithPath: entry.path))
      files[id] = file
      try await LibraryInspectionReader.capture(file, using: actions, exifTool: exif)
      try await LibraryInspectionReader.histogram(
        .init(kind: .cameraJPEG, url: file.url, sha256: entry.digest, contentID: file.contentID),
        for: file, using: actions)
      let details = try await actions.read(
        "inspection",
        ["op": .string("file"), "fileID": .string(id), "contentID": .string(file.contentID)])
      guard let sample = details["samples"]?.arrayValue?.first,
        let count = number(sample["sampledPixels"]), count > 0
      else { throw ProbeError("missing measured RGB") }
      for channel in ["red", "green", "blue"] {
        guard let bins = sample[channel]?.arrayValue, bins.count == 256,
          bins.reduce(0.0, { $0 + (number($1) ?? -1) }) == count
        else { throw ProbeError("RGB bin count differs") }
      }
      metadata[id] = details
      var entryReport: [String: CatalogJSON] = [
        "af": details["af"] ?? .null, "sampledPixels": sample["sampledPixels"] ?? .null,
        "histogramSource": sample["kind"] ?? .null,
        "sourceDigestMatched": .boolean(sample["sourceSHA256"] == .string(entry.digest)),
      ]
      for k in [
        "camera", "lens", "iso", "aperture", "shutterSeconds", "width", "height", "orientation",
        "focalLength",
      ] {
        entryReport[k] = details["fields"]?[k]
      }
      report[id] = .object(entryReport)
    }
    var groupResults = [String: CatalogJSON]()
    var reviews = [String: CatalogJSON]()
    for group in manifest.groups {
      guard let basis = LibraryFocusFrame.Basis(rawValue: group.basis) else {
        throw ProbeError("unknown ROI basis")
      }
      var focus = [LibraryFocusFrame]()
      for row in group.frames {
        guard let file = files[row.id] else { throw ProbeError("unknown sample") }
        var center: CGPoint?
        if let p = row.point, p.count == 2 { center = CGPoint(x: p[0], y: p[1]) }
        if basis == .cameraAF, let a = metadata[row.id]?["af"]?["tuple"]?.arrayValue, a.count == 4,
          let w = number(a[0]), let h = number(a[1]), let x = number(a[2]), let y = number(a[3])
        {
          center = CGPoint(x: x / w, y: y / h)
        }
        if let point = center,
          let review = ProcessInfo.processInfo.environment["RAWMASTER_FOCUS_REVIEW_PATCH_DIR"]
        {
          try saveReview(
            file.url, point: point,
            to: URL(fileURLWithPath: review).appendingPathComponent(
              group.id + "-" + row.id + ".png"))
        }
        focus.append(.init(file: file, center: center, basis: basis, comparisonKey: group.id))
      }
      let analyzed = try await LibraryInspectionReader.analyze(
        groupID: group.id, frames: focus, using: actions)
      var rows = [String: CatalogJSON]()
      for r in group.frames {
        let file = files[r.id]!
        let details = try await actions.read(
          "inspection",
          ["op": .string("file"), "fileID": .string(r.id), "contentID": .string(file.contentID)])
        let evidence = details["focusEvidence"]
        rows[r.id] = .object([
          "decision": analyzed["frames"]?[r.id] ?? .null,
          "relativeScore": evidence?["relativeScore"] ?? .null,
          "measurement": evidence?["frame"]?["measurements"] ?? .null,
          "pixelScale": evidence?["frame"]?["pixelScale"] ?? .null,
          "admitted": details["archiveEligible"] ?? .null,
        ])
      }
      groupResults[group.id] = .object(rows)
      if let row = group.manualReview, let target = files[row.id] {
        _ = try await actions.perform(
          "inspect.focusManual",
          [
            "fileID": .string(row.id), "contentID": .string(target.contentID),
            "value": .string(row.value),
          ])
        _ = try await LibraryInspectionReader.analyze(
          groupID: group.id, frames: focus, using: actions)
        let view = try await actions.read(
          "inspection", ["op": .string("work"), "workID": .string("file:" + row.id)])
        reviews[group.id] = .object([
          "machine": view["fields"]?["focusMachine"]?["value"] ?? .null,
          "human": view["fields"]?["focusEffective"]?["value"] ?? .null,
          "eligible": view["file"]?["archiveEligible"] ?? .null,
        ])
        guard view["fields"]?["focusEffective"]?["value"] == .string(row.value),
          view["fields"]?["focusEffective"]?["origin"] == .string("manual"),
          view["file"]?["archiveEligible"] == .boolean(true)
        else { throw ProbeError("human focus/admission changed on refresh") }
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(
      CatalogJSON.object([
        "sources": .object(report), "groups": .object(groupResults),
        "manualReviews": .object(reviews),
      ])
    ).write(to: dest, options: .withoutOverwriting)
  }

  static func saveReview(_ source: URL, point: CGPoint, to dst: URL) throws {
    guard let raw = CIRAWFilter(imageURL: source) else { return }
    raw.orientation = .up
    guard let im = raw.outputImage else { return }
    let size = 192
    let rect = CGRect(
      x: floor(point.x * im.extent.width) - 96,
      y: im.extent.maxY - floor(point.y * im.extent.height) - 96, width: Double(size),
      height: Double(size))
    guard im.extent.contains(rect) else { return }
    try CIContext().writePNGRepresentation(
      of: im.cropped(to: rect), to: dst, format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
  }
}
