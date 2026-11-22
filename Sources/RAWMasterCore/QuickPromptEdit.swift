import Foundation

/// Coordinates use the frozen, already-oriented composition, with the origin at its top left.
public enum QuickPromptSelection: Equatable, Sendable {
    case whole
    case rectangle(NormalizedCrop)
    case mask(String)
}

public struct QuickPromptPixelRegion: Codable, Equatable, Sendable {
    public let x, y, width, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func validate(width fullWidth: Int, height fullHeight: Int) throws {
        guard x >= 0, y >= 0, width > 0, height > 0, width <= fullWidth, height <= fullHeight,
              x <= fullWidth - width, y <= fullHeight - height else { throw EditingError.invalidArtifact }
    }

    public func contains(_ item: Self) -> Bool {
        item.x >= x && item.y >= y && item.x - x <= width - item.width && item.y - y <= height - item.height
    }
}

public struct QuickPromptInputFile: Codable, Equatable, Sendable {
    public var artifact: RenderArtifact
    public var url: URL

    public init(artifact: RenderArtifact, url: URL) { self.artifact = artifact; self.url = url }
}

/// The model file and these local-only inputs are frozen separately. No auxiliary file is a provider input.
public struct QuickPromptEditSnapshot: Codable, Equatable, Sendable {
    public static let currentMapping = "quick-prompt-srgb-fit-v1"
    public let mappingVersion: String?
    public var basis: QuickPromptInputFile
    public var matte: QuickPromptInputFile?
    public let selection, context: QuickPromptPixelRegion?
    public let maskID: String?
    public let adoptedVersionID: String
    public let adoptionRevision: Int
    public let liveRevision: Int?
    public let usesLiveDraft: Bool

    public init(basis: QuickPromptInputFile, matte: QuickPromptInputFile? = nil,
                selection: QuickPromptPixelRegion? = nil, context: QuickPromptPixelRegion? = nil,
                maskID: String? = nil, work: PhotoWork, usesLiveDraft: Bool) {
        self.mappingVersion = Self.currentMapping
        self.basis = basis; self.matte = matte; self.selection = selection; self.context = context; self.maskID = maskID
        self.adoptedVersionID = work.adoptedVersionID; self.adoptionRevision = work.adoptionRevision
        self.liveRevision = work.liveRevision; self.usesLiveDraft = usesLiveDraft
    }

    func validate(input: RenderArtifact) throws {
        try basis.artifact.validate()
        guard (mappingVersion ?? Self.currentMapping) == Self.currentMapping,
              basis.url.isFileURL, basis.artifact.encoding == "public.tiff", basis.artifact.bitDepth == 16,
              input.encoding == "public.png", input.bitDepth == 8, (selection == nil) == (context == nil),
              (matte == nil) == (maskID == nil), adoptionRevision >= 0 else { throw EditingError.invalidArtifact }
        if let selection, let context {
            let width = basis.artifact.pixelWidth, height = basis.artifact.pixelHeight
            try selection.validate(width: width, height: height); try context.validate(width: width, height: height)
            guard context.contains(selection) else { throw EditingError.invalidArtifact }
            if let matte {
                try matte.artifact.validate()
                guard matte.url.isFileURL, matte.artifact.encoding == "public.png", matte.artifact.bitDepth == 8,
                      matte.artifact.pixelWidth == width, matte.artifact.pixelHeight == height else { throw EditingError.invalidArtifact }
            }
        } else if matte != nil { throw EditingError.invalidArtifact }
    }

    func matches(_ work: PhotoWork, parent: EditingVersion, recipe: DevelopmentRecipe) -> Bool {
        guard work.strictDocumentary != true, work.adoptedVersionID == adoptedVersionID,
              work.adoptionRevision == adoptionRevision, work.liveRevision == liveRevision else { return false }
        if usesLiveDraft, let live = work.liveRecipe {
            return work.liveParentVersionID == parent.id && live == recipe
        }
        return parent.recipe == recipe
    }
}
