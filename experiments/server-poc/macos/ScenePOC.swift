import Foundation
import RAWMasterImaging

/// CLI shim for the isolated 040/041 PoC. The implementation lives in RAWMasterImaging so it can
/// reuse the package-internal scene executor without exposing new production API.
enum ScenePOC {
  static let usage = "RAWMasterDiagnostics --scene-poc <ARW> <scene-v1.json> <scene-v2.json> <new-output-dir> [tile-edge] [surface-budget-bytes]"

  static func run(_ arguments: [String]) throws -> Int32 {
    guard arguments.count == 5 || arguments.count == 6 || arguments.count == 7 else {
      throw NSError(domain: "ScenePOC", code: 2,
        userInfo: [NSLocalizedDescriptionKey: usage])
    }
    let tileEdge = arguments.count >= 6 ? Int(arguments[5]) ?? 2048 : 2048
    let budget = arguments.count >= 7 ? Int(arguments[6]) ?? 6 * 1024 * 1024 * 1024 : 6 * 1024 * 1024 * 1024
    let result = try DevelopmentScenePOCDiagnostics.export(
      source: URL(fileURLWithPath: arguments[1]),
      graphV1URL: URL(fileURLWithPath: arguments[2]),
      graphV2URL: URL(fileURLWithPath: arguments[3]),
      destination: URL(fileURLWithPath: arguments[4]),
      tileEdge: tileEdge, surfaceBudget: budget, sourceRevision: 1)
    let data = try JSONSerialization.data(withJSONObject: result,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
    return 0
  }
}
