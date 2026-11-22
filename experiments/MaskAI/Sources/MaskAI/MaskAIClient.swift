import Foundation

/// Independent native facade. No RAWMaster types or render state are imported.
public final class MaskAIClient: @unchecked Sendable {
    public let modelPaths: MaskAIModelPaths
    public let subjects: SubjectMasker
    public let scenes: SceneMasker
    public let objects: ObjectMasker
    public let people: PeopleMasker

    public init(modelRoot: URL) {
        modelPaths = MaskAIModelPaths(root: modelRoot)
        subjects = SubjectMasker(paths: modelPaths)
        scenes = SceneMasker(paths: modelPaths)
        objects = ObjectMasker(paths: modelPaths)
        people = PeopleMasker(paths: modelPaths, objectMasker: objects)
    }

    public var hasLoadedModels: Bool {
        subjects.hasLoadedSession || scenes.hasLoadedSession || objects.hasLoadedSessions || people.hasLoadedSessions
    }

    public func releaseResources() {
        subjects.releaseResources()
        scenes.releaseResources()
        objects.releaseResources()
        people.releaseResources()
    }

    public func subject(in image: NativeImage, cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        try subjects.generate(from: image, cancellation: cancellation)
    }
    public func background(in image: NativeImage, cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        try subjects.generate(from: image, background: true, cancellation: cancellation)
    }
    public func landscape(in image: NativeImage, target: LandscapeMaskTarget, cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        try scenes.generate(from: image, target: target, cancellation: cancellation)
    }
    public func object(in image: NativeImage, prompt: ObjectPrompt, cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        try objects.generate(from: image, prompt: prompt, cancellation: cancellation)
    }
    public func person(in image: NativeImage, target: PersonMaskTarget, personIndex: Int? = nil,
                       cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        try people.generate(from: image, target: target, personIndex: personIndex, cancellation: cancellation)
    }
}
