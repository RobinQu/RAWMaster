import Foundation
import Metal
import RAWMasterCore
import RAWMasterImage

/// Thin Swift owner for the Rust scene-linear graph executor. The Swift Metal graph remains the
/// reference implementation; this backend is only selected after the shadow comparison passes.
final class RustSceneGraphRenderer {
    private let device: any MTLDevice
    private let surfaceBudget: Int
    private var programs: [String: RAWMasterImageKernel.SceneProgram] = [:]

    init(device: any MTLDevice, surfaceBudget: Int) {
        self.device = device
        self.surfaceBudget = surfaceBudget
    }

    enum Mode { case auto, rust, swift }

    static var mode: Mode {
        switch ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BACKEND"]?.lowercased() {
        case "rust": return .rust
        case "swift", "off", "0": return .swift
        default: return .auto
        }
    }

    func render(input: any MTLTexture,
                graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View,
                origin: SIMD2<Int>, geometry: SIMD2<Int>,
                tileEdge: Int?, sourceRevision: UInt64,
                coverages: [UUID: any MTLTexture] = [:]) throws
      -> (texture: any MTLTexture, receipt: RAWMasterImageKernel.SceneProgram.SceneReceipt) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try SceneDeliveryTrace.measure(.dagBridgeEncode) { try encoder.encode(Document(graph: graph.graph)) }
        let key = Self.topology(graph.graph)
        let program: RAWMasterImageKernel.SceneProgram
        if let cached = programs[key] {
            // Same node identity and scope nesting: swap parameters in place so the Rust prefix
            // cache can keep unchanged nodes across an edit.
            try SceneDeliveryTrace.measure(.dagUpdate) { try cached.update(graph: data) }
            program = cached
        } else {
            if programs.count >= 8 { programs.removeAll(keepingCapacity: true) }
            let created = try SceneDeliveryTrace.measure(.dagOpen) {
                try RAWMasterImageKernel.SceneProgram(graph: data, device: device)
            }
            programs[key] = created
            program = created
        }
        let sceneView: RAWMasterImageKernel.SceneView = switch view.target {
        case .final: .final
        case .bypass: .bypass
        case .node(let id): .node(id.uuidString)
        }
        do {
            let texture = try SceneDeliveryTrace.measure(.dagDispatch) {
                try program.renderSurface(input: input, view: sceneView, groupPath: view.groupPath,
                    origin: origin, geometry: geometry, surfaceBudget: surfaceBudget,
                    tileEdge: tileEdge, sourceRevision: sourceRevision, coverages: coverages)
            }
            SceneDeliveryTrace.sampleMemory(device: device)
            guard let receipt = program.receipt() else { throw RAWMasterImageKernel.Failure.renderFailed }
            return (texture, receipt)
        } catch RAWMasterImageKernel.Failure.surfaceBudget {
            throw DevelopmentSceneGraphRendererV1.Failure.surfaceBudget
        }
    }

    /// Programs are reusable while node identities and group nesting stay fixed. Node parameter
    /// changes are applied with `update`, and Rust invalidates cache entries by content.
    private static func topology(_ scope: DevelopmentSceneGraphV1.Scope) -> String {
        scope.nodes.map { node in
            switch node.operation {
            case .group(_, let child, _, _):
                return "\(node.id.uuidString){\(topology(child))}"
            default:
                return node.id.uuidString
            }
        }.joined(separator: ",") + ">\(scope.output)"
    }

    private struct Document: Encodable {
        let schemaVersion = 1
        let graph: DevelopmentSceneGraphV1.Scope
    }
}
