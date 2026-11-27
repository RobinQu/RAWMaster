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

    static var enabled: Bool { mode != .swift }

    func render(input: any MTLTexture, output: any MTLTexture,
                graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View,
                origin: SIMD2<Int>, geometry: SIMD2<Int>,
                coverages: [UUID: any MTLTexture] = [:]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let document = Document(graph: graph.graph)
        let data = try encoder.encode(document)
        let key = String(decoding: data, as: UTF8.self)
        let program: RAWMasterImageKernel.SceneProgram
        if let cached = programs[key] {
            program = cached
        } else {
            // Keep only the current topology/parameter document; graph edits are infrequent
            // compared with the repeated previews of a settled graph.
            if programs.count >= 8 { programs.removeAll(keepingCapacity: true) }
            let created = try RAWMasterImageKernel.SceneProgram(graph: data, device: device)
            programs[key] = created
            program = created
        }
        let sceneView: RAWMasterImageKernel.SceneView = switch view.target {
        case .final: .final
        case .bypass: .bypass
        case .node(let id): .node(id.uuidString)
        }
        do {
            try program.render(input: input, output: output, view: sceneView,
                               origin: origin, geometry: geometry, surfaceBudget: surfaceBudget,
                               coverages: coverages)
        } catch RAWMasterImageKernel.Failure.surfaceBudget {
            throw DevelopmentSceneGraphRendererV1.Failure.surfaceBudget
        }
    }

    private struct Document: Encodable {
        let schemaVersion = 1
        let graph: DevelopmentSceneGraphV1.Scope
    }
}
