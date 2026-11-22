import Foundation
import MaskAI

struct ProbeRecord: Codable {
    let capability: String
    let status: String
    let coverage: Double?
    let selectedPixels: Int?
    let elapsedMilliseconds: Double?
    let modelIDs: [String]
    let notes: [String]
    let output: String?
}

func write(_ result: MaskResult, to output: URL, capability: String, notes: [String] = []) throws {
    try result.mask.writePNG(to: output)
    let record = ProbeRecord(capability: capability, status: "passed", coverage: result.mask.coverage,
                             selectedPixels: result.mask.selectedPixelCount,
                             elapsedMilliseconds: result.metrics.elapsedMilliseconds,
                             modelIDs: result.metrics.modelIDs, notes: result.metrics.notes + notes,
                             output: output.lastPathComponent)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: output.deletingPathExtension().appendingPathExtension("json"))
}

func model(_ identifier: String) -> MaskAIModel? {
    MaskAIModel.allCases.first { $0.rawValue == identifier || $0.relativePath == identifier }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("Usage: mask-ai-probe capabilities | inspect <model> | subject <image> <out.png> | background <image> <out.png>")
    print("       landscape <sky|snow|architecture|vegetation|water|naturalGround|artificialGround|mountains> <image> <out.png>")
    print("       object <image> <out.png> [x,y] | people <target|detect> <image> <out.png> [personIndex]")
    exit(2)
}
let modelRoot = ProcessInfo.processInfo.environment["MASK_AI_MODELS"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appending(path: "Vendor/Models")
let client = MaskAIClient(modelRoot: modelRoot)

do {
    switch command {
    case "capabilities":
        print("subject background")
        print("landscape:", LandscapeMaskTarget.allCases.map(\.rawValue).joined(separator: " "))
        print("people:", PersonMaskTarget.allCases.map(\.rawValue).joined(separator: " "))
        print("objects: point, box, negative points; SlimSAM encoder cache")
    case "inspect":
        guard arguments.count == 2, let selected = model(arguments[1]) else { throw MaskAIError.invalidInput("Unknown model.") }
        let session = try ONNXSession(modelAt: modelRoot.appending(path: selected.relativePath))
        print(selected.rawValue)
        print("inputs:", session.inputNames.joined(separator: ", "))
        print("outputs:", session.outputNames.joined(separator: ", "))
    case "raw-info":
        guard arguments.count == 3 else { throw MaskAIError.invalidInput("Expected RAW input and preview output paths.") }
        let loaded = try RAWImageAdapter.load(URL(fileURLWithPath: arguments[1]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(loaded.info), encoding: .utf8)!)
        try loaded.image.writePNG(to: URL(fileURLWithPath: arguments[2]))
    case "subject", "background":
        guard arguments.count == 3 else { throw MaskAIError.invalidInput("Expected image and output paths.") }
        let image = try NativeImage(contentsOf: URL(fileURLWithPath: arguments[1]))
        let result = command == "subject" ? try client.subject(in: image) : try client.background(in: image)
        try write(result, to: URL(fileURLWithPath: arguments[2]), capability: command)
    case "landscape":
        guard arguments.count == 4, let target = LandscapeMaskTarget(rawValue: arguments[1]) else { throw MaskAIError.invalidInput("Unknown landscape target.") }
        let image = try NativeImage(contentsOf: URL(fileURLWithPath: arguments[2]))
        try write(client.landscape(in: image, target: target), to: URL(fileURLWithPath: arguments[3]), capability: "landscape.\(target.rawValue)")
    case "object":
        guard arguments.count >= 3 else { throw MaskAIError.invalidInput("Expected image and output paths.") }
        let image = try NativeImage(contentsOf: URL(fileURLWithPath: arguments[1]))
        let prompt: ObjectPrompt
        if arguments.count >= 4 {
            let values = arguments[3].split(separator: ",").compactMap { Double($0) }
            if values.count == 2 { prompt = ObjectPrompt(positivePoints: [NormalizedPoint(x: values[0], y: values[1])]) }
            else if values.count == 4 { prompt = ObjectPrompt(box: NormalizedRect(x: values[0], y: values[1], width: values[2], height: values[3])) }
            else { throw MaskAIError.invalidInput("Prompt must be x,y or x,y,width,height.") }
        } else { prompt = ObjectPrompt(positivePoints: [NormalizedPoint(x: 0.5, y: 0.5)]) }
        try write(client.object(in: image, prompt: prompt), to: URL(fileURLWithPath: arguments[2]), capability: "object")
    case "people":
        guard arguments.count >= 4 else { throw MaskAIError.invalidInput("Expected target, image and output paths.") }
        let image = try NativeImage(contentsOf: URL(fileURLWithPath: arguments[2]))
        if arguments[1] == "detect" {
            let people = try client.people.detectPeople(in: image)
            print(people)
            if people.isEmpty { throw MaskAIError.noPeople }
        } else {
            guard let target = PersonMaskTarget(rawValue: arguments[1]) else { throw MaskAIError.invalidInput("Unknown person target.") }
            let index = arguments.count >= 5 ? Int(arguments[4]) : nil
            try write(client.person(in: image, target: target, personIndex: index), to: URL(fileURLWithPath: arguments[3]), capability: "people.\(arguments[1])")
        }
    default:
        throw MaskAIError.invalidInput("Unknown command \(command).")
    }
} catch {
    FileHandle.standardError.write(Data("MaskAI probe failed: \(error)\n".utf8))
    exit(1)
}
