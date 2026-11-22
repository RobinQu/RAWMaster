import CryptoKit
import Foundation
import XCTest
import RAWMasterCore

final class DevelopmentLUTImportPerformanceTests: XCTestCase {
  /// Each trial starts with a new empty chooser. The import ends after every parsed table
  /// and its index have been published. Generate/archive fixtures and verify witnesses outside the timer.
  func testFreshCUBEAndZIPLibraryImport() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["RAWMASTER_LUT_IMPORT_REPORT"] else { throw XCTSkip("Set RAWMASTER_LUT_IMPORT_REPORT to record import timings") }
    let output = URL(fileURLWithPath: path)
    guard !FileManager.default.fileExists(atPath: output.path) else { return XCTFail("Output exists") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func writeCube(_ dimension: Int, monochrome: Bool) throws -> URL {
      let name = monochrome ? "mono" : "warm"
      let url = root.appendingPathComponent("\(name)-\(dimension).cube")
      var content = "TITLE \"\(name)\"\nLUT_3D_SIZE \(dimension)\n"
      content.reserveCapacity(dimension * dimension * dimension * 30)
      let scale = Float(dimension - 1)
      for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
        let red = Float(r)/scale, green = Float(g)/scale, blue = Float(b)/scale
        if monochrome {
          let gray = red * 0.2126 + green * 0.7152 + blue * 0.0722
          content += "\(gray) \(gray) \(gray)\n"
        } else { content += "\(red*0.94+0.06) \(green) \(blue*0.9)\n" }
      } } }
      try Data(content.utf8).write(to: url)
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: url.path)
      return url
    }
    let large = try writeCube(64, monochrome: false), small = try writeCube(33, monochrome: true)
    let pack = root.appendingPathComponent("both.zip")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-X", "-q", pack.path, large.lastPathComponent, small.lastPathComponent]
    zip.currentDirectoryURL = root
    try zip.run(); zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { return XCTFail("Failed to make fixture") }
    var rows: [[String: Any]] = []
    let iterations = max(2, Int(env["RAWMASTER_LUT_IMPORT_REPEATS"] ?? "10") ?? 10)
    for file in [small, large, pack] {
      let input = try Data(contentsOf: file)
      let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
      var times: [Double] = []
      var ids: [String] = [], dimensions: [Int] = []
      for index in 0...iterations {
        let dir = root.appendingPathComponent(UUID().uuidString)
        let library = DevelopmentLUTLibrary(directory: dir)
        let start = DispatchTime.now().uptimeNanoseconds
        let imported = try await library.importFile(file)
        let end = DispatchTime.now().uptimeNanoseconds
        var witnessed: [DevelopmentColorLUT] = []
        for entry in imported { witnessed.append(try await library.load(entry)) }
        let got = witnessed.map(\.id)
        if index == 0 { ids = got; dimensions = witnessed.map(\.dimension) }
        XCTAssertEqual(got, ids)
        XCTAssertEqual(got.count, file == pack ? 2 : 1)
        times.append(Double(end - start) / 1_000_000)
        try FileManager.default.removeItem(at: dir)
      }
      let measured = Array(times.dropFirst()), sorted = measured.sorted()
      let nodes = dimensions.reduce(0) { $0 + $1 * $1 * $1 }
      let p50 = sorted.count % 2 == 1 ? sorted[sorted.count/2] : (sorted[sorted.count/2-1] + sorted[sorted.count/2])/2
      let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
      rows.append(["featureId": "grading-lut-import", "file": file.lastPathComponent, "bytes": input.count, "sha256": digest,
                   "cubeSHA256": ids, "dimensions": dimensions, "nodes": nodes, "firstMs": times[0], "samplesMs": measured,
                   "p50Ms": p50, "p95Ms": p95, "nodesPerSecondP50": Double(nodes)*1000/p50])
    }
    let report: [String: Any] = ["schemaVersion": 1, "application": "RAWMaster", "metric": "file-to-persisted-chooser-ms",
      "boundary": "Release DevelopmentLUTLibrary.importFile from empty chooser on local disk, table parse and publish; verification outside timer",
      "fixture": "Deterministic 33³ and 64³ text CUBE files and their ZIP. Import is independent of an open photograph.",
      "timestamp": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "hardware": env["RAWMASTER_LUT_HARDWARE"] ?? "unreported", "rows": rows]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
  }
}
