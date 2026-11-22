import Foundation
import RAWMasterCore

/// Pixel-content identity for the fixed filter candidate set. Delivery revisions stay separate.
public enum DevelopmentThumbnailContentKeyV1 {
  public static let version = "filter-candidate-set-content-v1"
  private struct Key: Encodable {
    let version: String
    let source: DevelopmentLocalEditSourceBinding
    let sourceGeneration: UInt64
    let candidates: [String]
    let target: String
    let filterOrder: [String]
    let pipeline: String
    let filterOperator: String
    let resourceVersion: String
  }
  public static func filters(_ request: DevelopmentThumbnailRequest,
                             source: DevelopmentLocalEditSourceBinding,
                             sourceIsRAW: Bool) throws -> String {
    guard request.kind == .filters else { throw DevelopmentThumbnailError.invalidRequest }
    let candidates = try DevelopmentThumbnailEngine.filterOrder.indices.map { index in
      let recipe = try DevelopmentThumbnailEngine.resolveCandidate(request, index: index, scalars: nil,
        source: source, sourceIsRAW: sourceIsRAW)
      return try EditingFingerprint.of(recipe)
    }
    return try EditingFingerprint.of(Key(version: version, source: source,
      sourceGeneration: request.preview.sourceGeneration, candidates: candidates,
      target: request.target.rawValue, filterOrder: DevelopmentThumbnailEngine.filterOrder.map(\.rawValue),
      pipeline: DevelopmentThumbnailEngine.version + "/" + DevelopmentRendererV3.pipelineVersion,
      filterOperator: DevelopmentPhotoFilterEngineV3.operatorVersion,
      resourceVersion: request.expectedPhotoFilterResourceVersion ?? "none"))
  }
}
