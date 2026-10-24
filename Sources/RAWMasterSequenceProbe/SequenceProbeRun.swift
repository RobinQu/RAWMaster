import Foundation
import CryptoKit
import Darwin
import RAWMasterCore
import RAWMasterImaging

struct ProbeStamp: Codable, Equatable {
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let device: Int64
    let inode: UInt64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    init(_ value: SequenceFileCredential) {
        size = value.size; modifiedSeconds = value.modifiedSeconds; modifiedNanoseconds = value.modifiedNanoseconds
        device = value.device; inode = value.inode; changedSeconds = value.changedSeconds; changedNanoseconds = value.changedNanoseconds
    }
}
struct ProbeSourceRecord: Codable {
    let assetID: String
    let relativePath: String
    var beforeSHA256: String?
    var afterSHA256: String?
    var before: ProbeStamp?
    var after: ProbeStamp?
    var errors: [String] = []
    var unchanged: Bool { beforeSHA256 != nil && beforeSHA256 == afterSHA256 && before != nil && before == after }
}
struct ProbeAnalysis: Codable {
    let manifest: SequenceInputManifest
    let result: SequenceAnalysisResult
    let observations: [SequenceAssetInput]
    let featuresAvailable: [Bool]
    let sources: [ProbeSourceRecord]
    let hashBeforeSeconds: Double
    let readerAndEngineSeconds: Double
    let hashAfterSeconds: Double
    let analysisSeconds: Double
    let engineManagedPeakEstimateBytes: Int
    let processPeakResidentBytes: Int64?
    let spatialStatistics: SequenceSpatialStatistics?
    init(manifest: SequenceInputManifest, result: SequenceAnalysisResult, observations: [SequenceAssetInput],
         featuresAvailable: [Bool], sources: [ProbeSourceRecord], hashBeforeSeconds: Double,
         readerAndEngineSeconds: Double, hashAfterSeconds: Double, analysisSeconds: Double,
         engineManagedPeakEstimateBytes: Int, processPeakResidentBytes: Int64?,
         spatialStatistics: SequenceSpatialStatistics? = nil) {
        self.manifest = manifest; self.result = result; self.observations = observations
        self.featuresAvailable = featuresAvailable; self.sources = sources; self.hashBeforeSeconds = hashBeforeSeconds
        self.readerAndEngineSeconds = readerAndEngineSeconds; self.hashAfterSeconds = hashAfterSeconds
        self.analysisSeconds = analysisSeconds; self.engineManagedPeakEstimateBytes = engineManagedPeakEstimateBytes
        self.processPeakResidentBytes = processPeakResidentBytes; self.spatialStatistics = spatialStatistics
    }
    var sourcesUnchanged: Bool { sources.allSatisfy(\.unchanged) }
}
struct ProbeReadValue {
    let evidence: SequenceCaptureEvidence
    let feature: SequenceFrameFeature?
    let failure: String?
    let spatialFeature: SequenceSpatialFeature?
    let spatialExtractionSeconds: Double?
    init(evidence: SequenceCaptureEvidence, feature: SequenceFrameFeature?, failure: String?,
         spatialFeature: SequenceSpatialFeature? = nil, spatialExtractionSeconds: Double? = nil) {
        self.evidence = evidence; self.feature = feature; self.failure = failure
        self.spatialFeature = spatialFeature; self.spatialExtractionSeconds = spatialExtractionSeconds
    }
}
enum SequenceProbeRun {
    typealias Reader = (URL, SequenceManifestEntry, SequenceFileCredential) throws -> ProbeReadValue
    static let nativeReader: Reader = { url, entry, credential in
        let value = try SequenceCaptureReader.read(at: url, assetID: entry.assetID, contentHash: entry.contentHash!, evidenceRevision: entry.evidenceRevision, verifiedCredential: credential)
        return ProbeReadValue(evidence: value.evidence, feature: value.feature, failure: value.previewFailure)
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func verifiedHash(_ url: URL, deadline: Double, cancelled: () -> Bool = { false }, onChunk: (Int) -> Void = { _ in }) throws -> (String, SequenceFileCredential) {
        guard (try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular else { throw SequenceProbeError.invalid("Manifest entry is not a regular file") }
        let before = try SequenceFileCredential.capture(at: url)
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var digest = SHA256()
        while true {
            // FileHandle bridges NSData on macOS. Drain each chunk, not just each file,
            // so repeated full-source verification cannot retain total RAW bytes.
            let hadBytes: Bool = try autoreleasepool {
                if Task.isCancelled || cancelled() { throw CancellationError() }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SequenceProbeError.invalid("Frozen run duration limit exceeded") }
                let bytes = try input.read(upToCount: 1024 * 1024) ?? Data()
                guard !bytes.isEmpty else { return false }
                digest.update(data: bytes)
                onChunk(bytes.count) // Only the count escapes; no Data/NSData leaves this pool.
                return true
            }
            if !hadBytes { break }
        }
        if Task.isCancelled || cancelled() { throw CancellationError() }
        guard try SequenceFileCredential.capture(at: url) == before else { throw SequenceProbeError.invalid("Source changed while hashing") }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), before)
    }
    static func resultSHA256(_ result: SequenceAnalysisResult) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(result))
    }
    static func analyze(manifest description: ProbeManifest, root: URL, policy: ProbePolicy,
                        trace: ProbeTraceSink? = nil, onTraceSummary: (SequenceTraceSummary) -> Void = { _ in },
                        cancelled: () -> Bool = { false },
                        onMeasurement: (@Sendable (ProbeMeasurement) -> Void)? = nil, reader: Reader? = nil) throws -> ProbeAnalysis {
        try description.validate(); try policy.validate()
        guard reader == nil || policy.detector.spatialExperiment == nil else {
            throw SequenceProbeError.invalid("Legacy injected reader cannot supply experimental spatial features")
        }
        if Task.isCancelled || cancelled() { throw CancellationError() }
        guard (trace != nil) == (policy.boundedTrace != nil) else { throw SequenceProbeError.invalid("Trace sink must match the frozen policy") }
        let start = ProcessInfo.processInfo.systemUptime, deadline = start + policy.maximumDurationSeconds
        let urls = try description.urls(root: root)
        var sources = description.files.map { ProbeSourceRecord(assetID: $0.assetID, relativePath: $0.relativePath) }
        var credentials: [SequenceFileCredential?] = Array(repeating: nil, count: sources.count)
        for index in sources.indices {
            do {
                let (hash, credential) = try verifiedHash(urls[index], deadline: deadline, cancelled: cancelled)
                sources[index].beforeSHA256 = hash; sources[index].before = ProbeStamp(credential); credentials[index] = credential
            } catch is CancellationError { throw CancellationError() }
            catch { sources[index].errors.append("before-hash: \(error)") }
        }
        let hashBefore = ProcessInfo.processInfo.systemUptime - start
        let entries = description.files.enumerated().map { index, file in
            SequenceManifestEntry(assetID: file.assetID, ordinal: index, contentHash: sources[index].beforeSHA256, barrier: credentials[index] == nil ? .unreadable : nil)
        }
        let initial = try SequenceInputManifest(scopeID: description.scopeID, sessionID: description.sessionID, orderVersion: description.orderVersion, entries: entries)
        let boundEntries = entries.map { entry in
            SequenceManifestEntry(assetID: entry.assetID, ordinal: entry.ordinal, contentHash: entry.contentHash,
                camera: policy.sourceAssertion.map { .manifestAssertion(id: $0.id, revision: $0.revision, manifestFingerprint: initial.contentFingerprint) } ?? .unknown, barrier: entry.barrier)
        }
        let manifest = try SequenceInputManifest(scopeID: description.scopeID, sessionID: description.sessionID, orderVersion: description.orderVersion, entries: boundEntries)
        let configuration = policy.detector
        let token = try SequenceAnalysisToken.make(manifest: manifest, versions: configuration.versions(order: manifest.orderVersion), policyFingerprint: configuration.fingerprint)
        let observer: (@Sendable (SequenceTraceEvent) -> Void)? = trace.map { sink in { event in sink.record(event) } }
        var detector = try SequenceDetector(manifest: manifest, token: token, configuration: configuration,
            trace: observer, traceLimits: policy.boundedTrace?.limits ?? .init(),
            spatialMetrics: onMeasurement.map { sink in { @Sendable event in
                sink(ProbeMeasurement(stage: .spatialPair, ordinal: event.ordinal,
                    referenceOrdinal: event.referenceOrdinal, durationSeconds: event.durationSeconds,
                    spatial: ProbeSpatialMeasurement(event)))
            } })
        var preprocessor = SequenceObservationPreprocessor(manifest: manifest)
        var observations: [SequenceAssetInput] = [], featuresAvailable: [Bool] = []
        let engineStart = ProcessInfo.processInfo.systemUptime
        for (index, entry) in manifest.entries.enumerated() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SequenceProbeError.invalid("Frozen run duration limit exceeded") }
            if Task.isCancelled || cancelled() { detector.cancel(); throw CancellationError() }
            let observation: SequenceObservation
            if let credential = credentials[index] {
                var read: ProbeReadValue?
                let readStart = ProcessInfo.processInfo.systemUptime
                do {
                    read = try autoreleasepool {
                        if let reader { return try reader(urls[index], entry, credential) }
                        let value = try SequenceCaptureReader.read(at: urls[index], assetID: entry.assetID,
                            contentHash: entry.contentHash!, evidenceRevision: entry.evidenceRevision,
                            verifiedCredential: credential, spatial: configuration.spatialExperiment, cancelled: cancelled)
                        return ProbeReadValue(evidence: value.evidence, feature: value.feature, failure: value.previewFailure,
                            spatialFeature: value.spatialFeature, spatialExtractionSeconds: value.spatialExtractionSeconds)
                    }
                } catch is CancellationError { detector.cancel(); throw CancellationError() }
                catch SequenceReadError.spatialExtractionFailed { throw SequenceReadError.spatialExtractionFailed }
                catch {
                    sources[index].errors.append("reader: \(error)")
                }
                onMeasurement?(ProbeMeasurement(stage: .nativeRead, ordinal: index,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - readStart))
                // Outside the legacy unreadable catch: experimental failures must never become barriers.
                if let value = read {
                    if configuration.spatialExperiment != nil, value.feature != nil,
                       (value.spatialFeature == nil || value.spatialExtractionSeconds == nil) {
                        throw SequenceProbeError.invalid("Valid legacy preview lacks experimental spatial extraction")
                    }
                    if let duration = value.spatialExtractionSeconds {
                        guard duration.isFinite, duration >= 0 else { throw SequenceProbeError.invalid("Invalid spatial extraction duration") }
                        onMeasurement?(ProbeMeasurement(stage: .spatialExtraction, ordinal: index, durationSeconds: duration))
                    }
                    observation = preprocessor.make(entry: entry, evidence: value.evidence, feature: value.feature,
                        barrier: value.feature == nil ? .missingEmbeddedPreview : nil, spatialFeature: value.spatialFeature)
                } else { observation = preprocessor.make(entry: entry, evidence: nil, feature: nil, barrier: .unreadable) }
            } else { observation = preprocessor.make(entry: entry, evidence: nil, feature: nil, barrier: .unreadable) }
            observations.append(observation.input); featuresAvailable.append(observation.feature != nil)
            let consumeStart = ProcessInfo.processInfo.systemUptime
            try detector.consume(observation, cancelled: cancelled)
            onMeasurement?(ProbeMeasurement(stage: .engineConsume, ordinal: index,
                durationSeconds: ProcessInfo.processInfo.systemUptime - consumeStart))
        }
        if Task.isCancelled || cancelled() { detector.cancel(); throw CancellationError() }
        let finishStart = ProcessInfo.processInfo.systemUptime
        let result = try detector.finish(cancelled: cancelled)
        onMeasurement?(ProbeMeasurement(stage: .engineFinish, durationSeconds: ProcessInfo.processInfo.systemUptime - finishStart))
        try result.validate(manifest: manifest, expectedToken: token, observations: observations)
        if let summary = detector.traceSummary { onTraceSummary(summary) }
        let engineSeconds = ProcessInfo.processInfo.systemUptime - engineStart
        let afterStart = ProcessInfo.processInfo.systemUptime
        for index in sources.indices {
            do {
                let (hash, credential) = try verifiedHash(urls[index], deadline: deadline, cancelled: cancelled)
                sources[index].afterSHA256 = hash; sources[index].after = ProbeStamp(credential)
            } catch is CancellationError { throw CancellationError() }
            catch { sources[index].errors.append("after-hash: \(error)") }
        }
        var usage = rusage()
        let resident = getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : nil
        return ProbeAnalysis(manifest: manifest, result: result, observations: observations, featuresAvailable: featuresAvailable, sources: sources,
            hashBeforeSeconds: hashBefore, readerAndEngineSeconds: engineSeconds,
            hashAfterSeconds: ProcessInfo.processInfo.systemUptime - afterStart, analysisSeconds: ProcessInfo.processInfo.systemUptime - start,
            engineManagedPeakEstimateBytes: detector.managedPeakEstimateBytes, processPeakResidentBytes: resident,
            spatialStatistics: detector.spatialStatistics)
    }
    /// The label loader is deliberately invoked only after an immutable, encoded analysis seal exists.
    static func sealThenEvaluate(_ analysis: ProbeAnalysis, policy: ProbePolicy, onSealed: (String) throws -> Void = { _ in }, labels: () throws -> ProbeLabels) throws -> (String, ProbeEvaluation) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let seal = sha256(try encoder.encode(analysis))
        try onSealed(seal)
        let truth = try labels()
        return (seal, try ProbeEvaluator.evaluate(analysis, labels: truth, policy: policy))
    }
}
