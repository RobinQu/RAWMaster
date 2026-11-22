import AppKit
import ImageIO
import RAWMasterAI
import RAWMasterCore

enum QuickPromptModel: String, CaseIterable, Identifiable {
    case flux, seedream
    var id: Self { self }
    var title: String { self == .flux ? "FLUX.3 Image Klein · 本机" : "Seedream 5.5 · 云端" }

    func matches(_ profile: AIProviderProfile) -> Bool {
        self == .flux ? LocalFluxProvider.matches(profile) : Seedream55Adapter.matches(profile)
    }

    var defaultProfile: AIProviderProfile {
        switch self {
        case .flux:
            return .init(id: "quick-prompt-flux3-klein", kind: .localComfy, displayName: title,
                model: LocalFluxProvider.modelID, endpoint: URL(string: "http://127.0.0.1")!,
                capabilities: .init(capabilityID: LocalFluxProvider.capabilityID, supportsCancellation: true,
                                    supportsReconciliation: true, maxInputPixels: 1_048_576))
        case .seedream:
            return .init(id: "quick-prompt-seedream-55-beijing", kind: .seedream, displayName: title,
                model: Seedream55Adapter.modelID, endpoint: Seedream55Adapter.endpoint, region: "cn-beijing",
                capabilities: .init(capabilityID: Seedream55Adapter.capabilityID, supportsReconciliation: true,
                                    maxInputPixels: 1_048_576))
        }
    }
}

struct QuickPromptDraft: Equatable {
    var prompt = ""
    var model = QuickPromptModel.flux
    var selection = QuickPromptSelection.whole
    var selectionBinding: QuickPromptScopeBinding?
    var templateIDs: [String] = []
    var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    var textIssue: String? {
        if trimmed.isEmpty { return "请输入想修改的内容。" }
        if trimmed.contains("［") || trimmed.contains("］") { return "请填写提示词中方括号里的内容。" }
        if trimmed.count > 4000 { return "提示词最多 4,000 个字符。" }
        return nil
    }
}

struct QuickPromptScopeBinding: Equatable {
    let workID: String
    let parentVersionID: String?
    let geometry: DevelopmentGeometryV3?
    let legacyCrop: NormalizedCrop
    let legacyStraighten: Double
    let mask: DevelopmentMaskLayerV3?

    init(workID: String, parentVersionID: String?, recipe: DevelopmentRecipe, selection: QuickPromptSelection) {
        self.workID = workID; self.parentVersionID = parentVersionID
        geometry = recipe.adjustmentsV3?.geometry; legacyCrop = recipe.crop; legacyStraighten = recipe.straightenDegrees
        if case .mask(let id) = selection { mask = recipe.adjustmentsV3?.masks.first { $0.id.uuidString == id } }
        else { mask = nil }
    }
}

struct QuickPromptPrepared: Identifiable {
    let id = UUID()
    let request: AIEditRequest
    let directory: URL
    let photoName: String
    let draft: QuickPromptDraft
    let focusID: UUID
    let thumbnail: CGImage

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

struct QuickPromptReview {
    let job: ProcessingJob
    let version: EditingVersion
    let before, after: CGImage

    nonisolated static func thumbnail(_ url: URL, maxPixel: Int = 2048) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { throw EditingError.invalidArtifact }
        return image
    }

    nonisolated static func crop(_ url: URL, to rect: CGRect) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let crop = image.cropping(to: rect) else { throw EditingError.invalidArtifact }
        return crop
    }
}
