import Foundation
import Metal
import RAWMasterCore
import RAWMasterImage

/// The portable form of the existing V3 point pass. The caller supplies the same
/// working-space pixels the Core Image pass would receive.
enum PreviewPortableBasic {
    static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_PORTABLE_BASIC_PREVIEW"] == "1"

    static func qualifies(_ p: DevelopmentAdjustmentsV3) -> Bool {
        let light = p.light, mono = p.blackAndWhite
        guard light == .init(enabled: light.enabled, brightness: light.brightness, contrast: light.contrast,
                             blackPoint: light.blackPoint, whites: light.whites),
              mono.grain == 0, mono.grainSamplingVersion == nil, mono.mixer?.isActive != true,
              DevelopmentColorEngineV3.pointwiseActive(p) else { return false }
        var remaining = p
        remaining.light = .init()
        remaining.color = .init()
        remaining.blackAndWhite = .init()
        if remaining.legacyBasis?.isPixelNeutral == true { remaining.legacyBasis = nil }
        var neutral = p.neutralForSameSource
        neutral.rawDetails = p.rawDetails
        return remaining == neutral
    }

    static func plan(_ p: DevelopmentAdjustmentsV3, backend: RAWMasterImageKernel.Backend = .cpu) throws -> RAWMasterImageKernel.RasterPlan {
        try p.validate()
        guard qualifies(p) else { throw DevelopmentV3Error.invalidGraph }
        let recipe: [String: Any] = ["version": 2, "working": "extended-linear-srgb-premul-f32", "output": "basic",
                                      "nodes": [["id": "source", "op": "source"], node(p)]]
        return try RAWMasterImageKernel.RasterPlan(recipe: JSONSerialization.data(withJSONObject: recipe), backend: backend)
    }

    static func node(_ p: DevelopmentAdjustmentsV3) -> [String: Any] {
        let light = p.light, color = p.color, mono = p.blackAndWhite
        var basic: [String: Any] = ["id": "basic", "op": "basic_v3", "image": "source"]
        if light.enabled {
            basic["light"] = ["brightness": light.brightness, "contrast": light.contrast,
                              "blackPoint": light.blackPoint, "whites": light.whites]
        }
        if color.enabled {
            basic["color"] = ["saturation": color.saturation, "vibrance": color.vibrance, "cast": color.cast]
        }
        if mono.enabled {
            basic["blackAndWhite"] = ["intensity": mono.intensity, "neutrals": mono.neutrals, "tone": mono.tone]
        }
        return basic
    }
}

enum PreviewPortablePointEdit {
    enum Program: String {
        case exposure = "portable-metal-exposure"
        case basic = "portable-metal-basic"
        case curvesLevels = "portable-metal-curves-levels"
    }

    case exposure(Double)
    case basic(DevelopmentAdjustmentsV3)
    case curvesLevels(DevelopmentAdjustmentsV3)

    init?(_ p: DevelopmentAdjustmentsV3, input: PreviewInteractiveInputDescriptor) {
        if let ev = PreviewPortableExposure.eligibility(p, input: input) {
            self = .exposure(ev)
        } else if PreviewPortableBasic.enabled, (!input.sourceIsRAW || input.usesFlashRaw),
                  input.contentRect == CGRect(origin: .zero, size: input.proxySize), PreviewPortableBasic.qualifies(p) {
            self = .basic(p)
        } else if PreviewPortableCurvesLevels.enabled, (!input.sourceIsRAW || input.usesFlashRaw),
                  input.contentRect == CGRect(origin: .zero, size: input.proxySize), PreviewPortableCurvesLevels.qualifies(p) {
            self = .curvesLevels(p)
        } else {
            return nil
        }
    }

    var program: Program {
        switch self {
        case .exposure: return .exposure
        case .basic: return .basic
        case .curvesLevels: return .curvesLevels
        }
    }

    func plan() throws -> RAWMasterImageKernel.RasterPlan {
        switch self {
        case .exposure(let ev): return try PreviewPortableExposure.plan(ev: ev)
        case .basic(let p): return try PreviewPortableBasic.plan(p)
        case .curvesLevels(let p): return try PreviewPortableCurvesLevels.plan(p)
        }
    }
}

/// One preview worker retains at most three immutable programs on its current device.
/// Each render still binds its own parameters, surfaces and revision callback.
final class PreviewPortableMetalPrograms: @unchecked Sendable {
    enum NativeHalfKind: Equatable {
        case curves, grading, frozenMask(UUID), frozenMaskRegion(UUID)

        var usesFrozenMask: Bool {
            switch self {
            case .frozenMask, .frozenMaskRegion: return true
            default: return false
            }
        }

        var usesCompactRegion: Bool {
            if case .frozenMaskRegion = self { return true }
            return false
        }
    }

    private let lock = NSLock()
    private var device: (any MTLDevice)?
    private var programs: [PreviewPortablePointEdit.Program: RAWMasterImageKernel.MetalProgram] = [:]
    private var nativeHalf: RAWMasterImageKernel.NativeHalfProgram?
    private var nativeHalfKind: NativeHalfKind?

    private func selectDevice(_ device: any MTLDevice) {
        if self.device !== device {
            programs.removeAll()
            nativeHalf = nil
            nativeHalfKind = nil
            self.device = device
        }
    }

    func acquire(_ kind: PreviewPortablePointEdit.Program, parameters: RAWMasterImageKernel.RasterPlan,
                 device: any MTLDevice) throws -> (value: RAWMasterImageKernel.MetalProgram, compiled: Bool) {
        try lock.withLock {
            selectDevice(device)
            if let existing = programs[kind] { return (existing, false) }
            let program = try RAWMasterImageKernel.MetalProgram(recipe: parameters, device: device)
            programs[kind] = program
            return (program, true)
        }
    }

    func discard(_ program: RAWMasterImageKernel.MetalProgram, kind: PreviewPortablePointEdit.Program) {
        lock.withLock {
            if programs[kind] === program { programs.removeValue(forKey: kind) }
        }
    }

    func acquireNativeHalf(parameters: RAWMasterImageKernel.RasterPlan,
                           device: any MTLDevice, kind: NativeHalfKind) throws -> RAWMasterImageKernel.NativeHalfProgram {
        try lock.withLock {
            selectDevice(device)
            if let nativeHalf, nativeHalfKind == kind { return nativeHalf }
            let telemetry = ImagePerformanceTelemetry.shared.begin(operation: "PreviewPortableHalfCompile",
                stage: "编译便携图", queue: "图像引擎", boundary: .apiReturn)
            var outcome = ImagePerformanceOutcome.failed
            defer { ImagePerformanceTelemetry.shared.end(telemetry, outcome: outcome) }
            let compiled = try RAWMasterImageKernel.NativeHalfProgram(recipe: parameters, device: device, frozenMask: kind.usesFrozenMask,
                                                                     compactRegion: kind.usesCompactRegion)
            nativeHalf = compiled
            nativeHalfKind = kind
            outcome = .succeeded
            return compiled
        }
    }

    func discardNativeHalf(_ program: RAWMasterImageKernel.NativeHalfProgram) {
        lock.withLock {
            if nativeHalf === program { nativeHalf = nil }
        }
    }

    func removeAll() {
        lock.withLock {
            programs.removeAll()
            nativeHalf = nil
            nativeHalfKind = nil
            device = nil
        }
    }
}
