import Foundation
import CryptoKit
import Darwin
import RAWMasterCore
import RAWMasterImaging

struct ProbeTraceReport: Encodable {
    let version: String
    let path: String
    let sha256: String
    let resultSHA256: String
    let fileBytes: Int
    let eventBytes: Int
    let eventCount: Int
    let engineSummary: SequenceTraceSummary
    let incomplete: Bool
    let resourceBoundary = "Instrumented diagnostic run; timings are not an uninstrumented performance baseline. Missing/truncated events do not prove a decision path was not exercised."
}

/// A streaming file sink, never a retained array. Its lock also makes the engine's Sendable callback safe.
final class ProbeTraceSink: @unchecked Sendable {
    typealias Writer = (Data) throws -> Void
    private let lock = NSLock()
    private let configuration: ProbeBoundedTrace
    private let handle: FileHandle
    private let writer: Writer
    let url: URL
    private var digest = SHA256()
    private var bytes = 0
    private var events = 0
    private var eventBytes = 0
    private var failure: String?
    private var headerWritten = false
    private var finalized = false
    private static let maximumFramingLineBytes = ProbeBoundedTrace.framingReserveBytes / 2

    private struct Header: Encodable {
        let recordType = "header"
        let version = ProbeBoundedTrace.supportedVersion
        let eventVersion = SequenceTraceEvent.version
        let configuration: ProbeBoundedTrace
        let manifestControlSHA256: String
        let policyControlSHA256: String
        let boundary = "Ordinal-only diagnostic evidence; no labels loaded. Incomplete logs never establish absence of a decision."
    }
    private struct Footer: Encodable {
        let recordType = "footer"
        let analysisSHA256: String
        let resultSHA256: String
        let inputFingerprint: String
        let eventCount: Int
        let eventBytes: Int
        let engineSummary: SequenceTraceSummary
        let incomplete: Bool
    }
    static func derivedURL(reportURL: URL) -> URL { URL(fileURLWithPath: reportURL.path + ".trace.jsonl") }
    static func canonicalOutput(_ url: URL) -> URL {
        url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }
    static func reserve(reportURL: URL, sourceRoot: URL, controls: [URL], configuration: ProbeBoundedTrace,
                        writerOverride: Writer? = nil) throws -> ProbeTraceSink {
        try configuration.validate()
        let output = derivedURL(reportURL: reportURL)
        let root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        func check() throws {
            let resolved = canonicalOutput(output)
            let forbidden = controls + [reportURL]
            guard root.path != "/", resolved.path != root.path, !resolved.path.hasPrefix(root.path + "/"),
                  !forbidden.contains(where: { canonicalOutput($0).path == resolved.path })
            else { throw SequenceProbeError.invalid("Trace output must be outside the source root and distinct from controls/report") }
        }
        try check()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try check()
        let descriptor = output.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw SequenceProbeError.invalid("Cannot exclusively reserve trace output: \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return ProbeTraceSink(url: output, configuration: configuration, handle: handle, writerOverride: writerOverride)
    }
    private init(url: URL, configuration: ProbeBoundedTrace, handle: FileHandle, writerOverride: Writer?) {
        self.url = url; self.configuration = configuration; self.handle = handle
        writer = writerOverride ?? { try handle.write(contentsOf: $0) }
    }
    deinit { try? handle.close() }
    private func write(_ data: Data) throws {
        guard data.count <= configuration.maximumFileBytes - bytes else { throw SequenceProbeError.invalid("Trace file byte budget exceeded") }
        try writer(data); digest.update(data: data); bytes += data.count
    }
    private func framingLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value); data.append(10)
        guard data.count <= Self.maximumFramingLineBytes else { throw SequenceProbeError.invalid("Trace framing byte budget exceeded") }
        return data
    }
    func begin(manifestControlSHA256: String, policyControlSHA256: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !headerWritten, !finalized else { throw SequenceProbeError.invalid("Trace header may only be written once") }
        try write(framingLine(Header(configuration: configuration, manifestControlSHA256: manifestControlSHA256, policyControlSHA256: policyControlSHA256)))
        headerWritten = true
    }
    func record(_ event: SequenceTraceEvent) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        do {
            guard headerWritten, !finalized else { throw SequenceProbeError.invalid("Trace event outside the open stream") }
            let data = try event.encodedJSONLine()
            guard data.count <= SequenceTraceLimits.maximumEventBytes,
                  events < configuration.limits.maximumEvents,
                  data.count <= configuration.limits.maximumBytes - eventBytes
            else { throw SequenceProbeError.invalid("Engine emitted an event outside frozen trace limits") }
            try write(data); events += 1; eventBytes += data.count
        } catch { failure = "Trace sink failed: \(error)" }
    }
    func finish(analysis: ProbeAnalysis, analysisSHA256: String, summary: SequenceTraceSummary) throws -> ProbeTraceReport {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw SequenceProbeError.invalid(failure) }
        guard headerWritten, !finalized, summary.emittedEvents == events, summary.encodedBytes == eventBytes
        else { throw SequenceProbeError.invalid("Trace stream counters or finalization mismatch") }
        let resultSHA = try SequenceProbeRun.resultSHA256(analysis.result)
        try write(framingLine(Footer(analysisSHA256: analysisSHA256, resultSHA256: resultSHA, inputFingerprint: analysis.result.token.inputFingerprint,
            eventCount: events, eventBytes: eventBytes, engineSummary: summary, incomplete: summary.incomplete)))
        try handle.synchronize(); try handle.close(); finalized = true
        return ProbeTraceReport(version: ProbeBoundedTrace.supportedVersion, path: url.path,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), resultSHA256: resultSHA,
            fileBytes: bytes, eventBytes: eventBytes, eventCount: events, engineSummary: summary, incomplete: summary.incomplete)
    }
}
