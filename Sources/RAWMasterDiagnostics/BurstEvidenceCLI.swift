import Foundation
import Darwin

final class EvidenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
enum BurstEvidenceCLI {
    static func run(_ arguments: [String]) async throws -> Int32 {
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let sourcePath = option("--source-root"), let manifestPath = option("--inputs"), let outputPath = option("--output") else {
            throw NSError(domain: "BurstEvidenceCLI", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Usage: --burst-evidence --source-root directory --inputs manifest.txt --output report.json [--labels fixture.json] [--budget-mib 1...64] [--cancel-after N]"])
        }
        let root = URL(fileURLWithPath: sourcePath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let output = URL(fileURLWithPath: outputPath).resolvingSymlinksInPath().standardizedFileURL
        guard !isWithin(output, root: root) else { throw setupError("Report output must be outside the read-only source root") }
        let inputs = try loadInputs(manifestURL: URL(fileURLWithPath: manifestPath), root: root)
        var options = EvidenceOptions()
        if let rawBudget = option("--budget-mib") {
            guard let mib = Int(rawBudget), (1...64).contains(mib) else { throw setupError("Budget must be 1...64 MiB") }
            options.memoryBudgetBytes = mib * 1024 * 1024
        }
        var cancelAfter: Int?
        if let rawLimit = option("--cancel-after") {
            guard let count = Int(rawLimit), count >= 0 else { throw setupError("Cancel-after must be a nonnegative integer") }
            cancelAfter = count
        }
        let token = EvidenceCancellation()
        if cancelAfter == 0 { token.cancel() }
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .utility))
        signalSource.setEventHandler { token.cancel() }; signalSource.resume()
        defer { signalSource.cancel() }
        let limit = cancelAfter
        var report = await BurstEvidenceExperiment.run(inputs: inputs, options: options, cancelled: { token.isCancelled }, progress: { count, total in
            if count % 20 == 0 || count == total { fputs("Evidence: \(count)/\(total) serial frames recorded\n", stderr) }
            if let limit, count >= limit { token.cancel() }
        })
        // Labels cannot affect source selection, order, extraction, distances, or threshold calculations.
        if let labelsPath = option("--labels") {
            let labels = try JSONDecoder().decode(PositiveLabels.self, from: Data(contentsOf: URL(fileURLWithPath: labelsPath)))
            report.evaluation = BurstEvidenceExperiment.evaluate(report, labels: labels)
        }
        if token.isCancelled { report.status = "cancelled"; report.stopReason = "Cancellation observed before report serialization" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        print("Burst evidence \(report.status): \(report.coverage.recorded)/\(report.coverage.requested) frames; \(report.coverage.previewFailures) preview failures; production quality remains unaccepted")
        return report.status == "complete" ? 0 : 2
    }
    static func isWithin(_ url: URL, root: URL) -> Bool { url.path == root.path || url.path.hasPrefix(root.path + "/") }
    static func setupError(_ message: String) -> NSError { NSError(domain: "BurstEvidenceCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func loadInputs(manifestURL: URL, root: URL) throws -> [EvidenceInput] {
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= 256 * 1024, let manifest = String(data: data, encoding: .utf8) else { throw setupError("Manifest too large or not UTF-8") }
        let paths = manifest.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !paths.isEmpty, paths.count <= EvidenceOptions.maximumInputs else { throw setupError("Manifest requires 1...512 explicit relative paths") }
        var seen = Set<String>()
        return try paths.enumerated().map { index, path in
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw setupError("Manifest paths must remain under selected source root") }
            var componentURL = root
            for component in path.split(separator: "/") {
                componentURL.appendPathComponent(String(component))
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: componentURL.path)) != nil {
                    throw setupError("Manifest source symlinks are not supported; select an explicit physical source scope")
                }
            }
            let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard isWithin(url, root: root), seen.insert(url.path).inserted else { throw setupError("Manifest contains an escaped or duplicate source") }
            return EvidenceInput(id: String(format: "frame%06d", index + 1), sourceOrder: index, url: url)
        }
    }
}
