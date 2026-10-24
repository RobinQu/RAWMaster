import Foundation
import Darwin
import RAWMasterImaging

struct ProbeReport: Encodable {
    let schemaVersion: Int
    let tool = "RAWMasterSequenceProbe"
    let analysisSealedBeforeLabels = true
    let resourceBoundary = "Serial reader/streaming detector; retained Core observations for strict verification; max RSS is whole macOS process peak bytes, not engine-only memory"
    let nativeDeviceIdentityVerified = false
    let boundary = "Quality applies only to this explicit manifest and its declared source scope. A user batch declaration is not native physical-device verification and implies no broader generalization; a research assumption alone cannot close the A gate."
    let analysisSHA256: String
    let resultSHA256: String?
    let trace: ProbeTraceReport?
    let manifestControlSHA256: String
    let policyControlSHA256: String
    let labelsControlSHA256: String
    let sourceAssertion: ProbeSourceAssertion?
    let analysis: ProbeAnalysis
    let evaluation: ProbeEvaluation
    let evaluationSeconds: Double
    let totalSeconds: Double
}
enum SequenceProbeCLI {
    static func options(_ arguments: [String]) throws -> [String: String] {
        let allowed: Set<String> = ["--source-root", "--manifest", "--policy", "--labels", "--report"]
        guard arguments.count == allowed.count * 2 else { throw SequenceProbeError.invalid("Five complete explicit options required") }
        var result: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard allowed.contains(key), result[key] == nil, value.hasPrefix("/") else { throw SequenceProbeError.invalid("Unknown, duplicate or empty option") }
            result[key] = value
        }
        return result
    }
    static func writeDefaultPolicy(to path: String) throws {
        guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else { throw SequenceProbeError.invalid("Default policy output must be a new absolute file") }
        let policy = ProbePolicy(schemaVersion: 2, detector: .init(), sourceAssertion: ProbeSourceAssertion(id: "whole-manifest-research-assumption", revision: 0, declaredByUser: false, provenance: "Research assumption only for the complete manifest including negative boundaries; before declaring user provenance, record the verbatim batch declaration and the limits of EXIF device evidence"),
            acceptance: ProbeAcceptance(minimumPositivePairs: 1, minimumRecall: 0.95, minimumTypedCoverage: 0.80, minimumExactGroupFraction: 1, minimumPrecision: 0.95, minimumNegativePairs: 2), maximumDurationSeconds: 600, deterministicSeed: 0)
        try policy.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(policy).write(to: output, options: .withoutOverwriting)
    }
    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments.count == 2 && arguments[0] == "--write-default-policy" { try writeDefaultPolicy(to: arguments[1]); return 0 }
        guard ProcessInfo.processInfo.environment["RAWMASTER_SEQUENCE_GUARDED"] == "1" else { throw SequenceProbeError.invalid("Use the reviewed run-sequence-validation.py freeze guard; direct media runs disabled") }
        let start = ProcessInfo.processInfo.systemUptime, values = try options(arguments)
        let root = URL(fileURLWithPath: values["--source-root"]!).standardizedFileURL.resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: values["--report"]!).standardizedFileURL
        let resolvedOutput = output.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(output.lastPathComponent)
        guard root.path != "/", !resolvedOutput.path.hasPrefix(root.path + "/"), resolvedOutput.path != root.path,
              !FileManager.default.fileExists(atPath: output.path) else { throw SequenceProbeError.invalid("Report must be a new file outside the source root") }
        let manifestBytes = try Data(contentsOf: URL(fileURLWithPath: values["--manifest"]!))
        let policyBytes = try Data(contentsOf: URL(fileURLWithPath: values["--policy"]!))
        let description = try JSONDecoder().decode(ProbeManifest.self, from: manifestBytes)
        let policy = try JSONDecoder().decode(ProbePolicy.self, from: policyBytes)
        try description.validate(); try policy.validate()
        let traceSink = try policy.boundedTrace.map { configuration in
            try ProbeTraceSink.reserve(reportURL: output, sourceRoot: root,
                controls: ["--manifest", "--policy", "--labels"].map { URL(fileURLWithPath: values[$0]!) }, configuration: configuration)
        }
        try traceSink?.begin(manifestControlSHA256: SequenceProbeRun.sha256(manifestBytes), policyControlSHA256: SequenceProbeRun.sha256(policyBytes))
        var traceSummary: SequenceTraceSummary?
        let analysis = try SequenceProbeRun.analyze(manifest: description, root: root, policy: policy, trace: traceSink, onTraceSummary: { traceSummary = $0 })
        var traceReport: ProbeTraceReport?
        var labelsBytes = Data()
        let evaluationStart = ProcessInfo.processInfo.systemUptime
        let (seal, evaluation) = try SequenceProbeRun.sealThenEvaluate(analysis, policy: policy, onSealed: { seal in
            if let traceSink {
                guard let traceSummary else { throw SequenceProbeError.invalid("Enabled trace is missing its engine summary") }
                traceReport = try traceSink.finish(analysis: analysis, analysisSHA256: seal, summary: traceSummary)
            }
        }) {
            labelsBytes = try Data(contentsOf: URL(fileURLWithPath: values["--labels"]!))
            return try JSONDecoder().decode(ProbeLabels.self, from: labelsBytes)
        }
        let report = ProbeReport(schemaVersion: policy.schemaVersion, analysisSHA256: seal,
            resultSHA256: policy.schemaVersion == 3 ? try SequenceProbeRun.resultSHA256(analysis.result) : nil,
            trace: traceReport, manifestControlSHA256: SequenceProbeRun.sha256(manifestBytes), policyControlSHA256: SequenceProbeRun.sha256(policyBytes), labelsControlSHA256: SequenceProbeRun.sha256(labelsBytes), sourceAssertion: policy.sourceAssertion,
            analysis: analysis, evaluation: evaluation, evaluationSeconds: ProcessInfo.processInfo.systemUptime - evaluationStart, totalSeconds: ProcessInfo.processInfo.systemUptime - start)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output, options: .withoutOverwriting)
        if !analysis.sourcesUnchanged { return 1 }
        if traceReport?.incomplete == true { return 4 } // Diagnostic truncation is explicit, never a complete-trace success.
        if !evaluation.qualityUnderAssumption { return 2 }
        return evaluation.acceptedWithinDeclaredSourceScope ? 0 : 3
    }
}
@main enum RAWMasterSequenceProbe {
    static func main() {
        do { exit(try SequenceProbeCLI.run(Array(CommandLine.arguments.dropFirst()))) }
        catch { FileHandle.standardError.write(Data("SequenceProbe failed: \(error)\n".utf8)); exit(1) }
    }
}
