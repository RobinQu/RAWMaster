import Foundation
import CryptoKit
import Darwin
import RAWMasterCore

/// Optional bounded, source-free diagnostics; no paths, text metadata or opaque IDs.
public struct RuntimeAutomaticGroupingDiagnostics: Codable, Sendable {
    public let assetCount, eventCount, groupCount, nativeEvidenceCount, previewCount, metadataFailureCount: Int
    public let associationHypothesisAssumed: Bool
    public let fieldStateCounts: [String:[String:Int]]
    public let barrierCounts, nativeContradictionCounts, timePrecisionCounts, coverageStateFileCounts, coverageReasonFileCounts: [String:Int]
}

/// App-facing integration has no eager tool/RAW work and no Imaging-owned database writes.
public enum RuntimeAutomaticGroupingCoordinator {
    public static func callback(store: LibraryStore, libraryURL: URL, toolRoot: URL? = nil,
                                diagnostics: (@Sendable (RuntimeAutomaticGroupingDiagnostics)->Void)? = nil) -> ImportPostIngestCallback {
        let analyzer = RuntimeAutomaticGroupingAnalyzer(libraryURL: libraryURL, toolRoot: toolRoot, diagnostics:diagnostics)
        let service = AutomaticGroupingService(store:store, analyzer: { input, check, progress in
            try await analyzer.analyze(input,check:check,progress:progress)
        })
        return { session, check, progress in await service.run(sessionID:session.id,checkCancellation:check,progress:progress) }
    }
}
public struct RuntimeAutomaticGroupingAnalyzer: Sendable {
    public let libraryURL: URL
    public let toolRoot: URL?
    private let diagnostics: (@Sendable (RuntimeAutomaticGroupingDiagnostics)->Void)?
    public init(libraryURL:URL,toolRoot:URL? = nil,diagnostics:(@Sendable (RuntimeAutomaticGroupingDiagnostics)->Void)? = nil) {
        self.libraryURL = libraryURL; self.toolRoot = toolRoot; self.diagnostics = diagnostics
    }
    public func analyze(_ input:AutomaticGroupingInput, check:@escaping @Sendable () throws->Void,
                        progress:@escaping @Sendable (TaskProgress)->Void) async throws -> AutomaticGroupingAnalysis {
        try await Task.detached(priority:.utility) { try run(input,check:check,progress:progress) }.value
    }
    private func run(_ input:AutomaticGroupingInput, check:@escaping @Sendable () throws->Void,
                     progress:@escaping @Sendable (TaskProgress)->Void) throws -> AutomaticGroupingAnalysis {
        let started = ProcessInfo.processInfo.systemUptime
        let checkpoint: @Sendable () throws->Void = {
            try check()
            guard ProcessInfo.processInfo.systemUptime-started < 1800 else { throw RuntimeSequenceError.invalid("自动分组超过本轮时间预算") }
        }
        try checkpoint()
        guard input.assets.count <= 30_000, input.assets.count == input.assetRevisions.count else { throw RuntimeSequenceError.invalid("自动分组会话范围无效或超出预算") }
        let tool = try RuntimeSequenceTool(root:toolRoot)
        let key = try Self.key(libraryURL:libraryURL), keyID = key.withUnsafeBytes { SequenceMetadataEvidenceLoader.sha256(Data($0)) }
        struct Verified { let credential:SequenceFileCredential; let stamp:AutomaticGroupingFileStamp; let sha:String }
        var before:[Verified] = []
        for (i,asset) in input.assets.enumerated() {
            try checkpoint()
            guard let expected = asset.contentHash, SequenceMetadataEvidenceLoader.isSHA(expected) else { throw RuntimeSequenceError.invalid("完整导入素材缺少内容身份") }
            let credential = try SequenceFileCredential.capture(at:asset.resolvedURL)
            let stamp = try AutomaticGroupingFileStamp.read(at:asset.resolvedURL)
            let sha = try RuntimeSequenceTool.hash(asset.resolvedURL,check:checkpoint)
            guard sha == expected, try SequenceFileCredential.capture(at:asset.resolvedURL) == credential else { throw RuntimeSequenceError.invalid("自动分组前素材身份发生变化") }
            before.append(Verified(credential:credential,stamp:stamp,sha:sha))
            progress(TaskProgress(title:"自动分组：核验素材",completed:i+1,total:input.assets.count))
        }
        var normalized:[RuntimeNormalizedMetadata] = [], natives:[SequenceCaptureEvidence?] = [], primaries:[SequenceCaptureEvidence] = []
        var features:[SequenceFrameFeature?] = [], barriers:[SequenceReason?] = [], formats:[SequenceOriginalFormat] = []
        var metadataBytes = 0, featureBytes = 0, metadataFailureCount = 0
        var nativeContradictionCounts:[String:Int] = [:]
        for (i,asset) in input.assets.enumerated() {
            try checkpoint()
            var facts:RuntimeNormalizedMetadata, barrier:SequenceReason?
            do { facts = try RuntimeJSONQ.normalize(tool.read(asset.resolvedURL,check:checkpoint), expectedSource:asset.resolvedURL.path,key:key) }
            catch is CancellationError { throw CancellationError() }
            catch RuntimeSequenceError.providerUnavailable(let message) { throw RuntimeSequenceError.providerUnavailable(message) }
            catch {
                try checkpoint()
                metadataFailureCount += 1
                facts = RuntimeNormalizedMetadata()
                for field in RuntimeSequenceRegistry.fields { facts.states[field.id] = field.selector == nil ? .unsupportedSelector : .invalid }
                barrier = .unreadable
            }
            metadataBytes += try JSONEncoder().encode(facts).count
            guard metadataBytes <= 64*1024*1024 else { throw RuntimeSequenceError.invalid("自动分组元数据超出预算") }
            let format:SequenceOriginalFormat
            switch facts.strings["file.FileType"] { case "ARW":format = .arw;case "DNG":format = .dng;case "JPEG":format = .jpeg;default:format = .unknown }
            if format == .unknown { barrier = barrier ?? .unsupported }
            let exposure = facts.numbers["exif.ExposureTime"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let orientation = facts.numbers["exif.Orientation"].flatMap { SequenceCaptureEvents.decimal($0) }.map { NSDecimalNumber(decimal:$0).intValue } ?? 1
            let primary = SequenceCaptureEvidence(assetID:asset.id,contentHash:before[i].sha,
                extractorVersion:SequenceRuntimeMetadataProof.extractorVersion,evidenceRevision:input.assetRevisions[i],
                time:SequenceTimestampParser.parse(original:facts.strings["exif.DateTimeOriginal"],subseconds:facts.strings["exif.SubSecTimeOriginal"],offset:facts.strings["exif.OffsetTimeOriginal"]),
                cameraMake:facts.strings["exif.Make"],cameraModel:facts.strings["exif.Model"],imageNumberRaw:facts.numbers["exif.ImageNumber"],
                exposureSeconds:exposure,orientation:orientation,warnings:["Live JSONQ parser-decoded metadata; not raw stored tag bytes"]+facts.warningDigests.map { "Opaque parser warning: "+$0 })
            let native:SequenceCaptureReadResult?
            do { native = try SequenceCaptureReader.read(at:asset.resolvedURL,assetID:asset.id,contentHash:before[i].sha,
                    evidenceRevision:input.assetRevisions[i],verifiedCredential:before[i].credential,cancelled:{ (try? checkpoint()) == nil }) }
            catch is CancellationError { throw CancellationError() }
            catch { try checkpoint();native = nil;barrier = barrier ?? .unreadable }
            if let evidence = native?.evidence, let contradiction = SequenceRuntimeMetadataProof.nativeContradiction(evidence,primary) {
                nativeContradictionCounts[contradiction.rawValue,default:0] += 1
                barrier = barrier ?? contradiction
            }
            if native?.feature == nil { barrier = barrier ?? .missingEmbeddedPreview }
            featureBytes += native?.feature?.managedByteEstimate ?? 0
            guard featureBytes <= 256*1024*1024 else { throw RuntimeSequenceError.invalid("自动分组预览特征超出预算") }
            normalized.append(facts);natives.append(native?.evidence);primaries.append(primary);features.append(native?.feature);barriers.append(barrier);formats.append(format)
            progress(TaskProgress(title:"自动分组：读取拍摄信息",completed:i+1,total:input.assets.count))
        }
        try Self.validateMetadataAvailability(assetCount:input.assets.count,metadataFailureCount:metadataFailureCount)
        // Every current file is reverified after all metadata/preview reads, before publishing any result.
        var final:[AutomaticGroupingFileStamp] = []
        for (i,asset) in input.assets.enumerated() {
            try checkpoint()
            let sha = try RuntimeSequenceTool.hash(asset.resolvedURL,check:checkpoint), stamp = try AutomaticGroupingFileStamp.read(at:asset.resolvedURL)
            guard sha == before[i].sha, stamp == before[i].stamp,
                  try SequenceFileCredential.capture(at:asset.resolvedURL) == before[i].credential else { throw RuntimeSequenceError.invalid("自动分组期间素材发生变化") }
            final.append(stamp)
            progress(TaskProgress(title:"自动分组：复核素材",completed:i+1,total:input.assets.count))
        }
        guard try RuntimeSequenceTool(root:tool.root).closureSHA256 == tool.closureSHA256 else { throw RuntimeSequenceError.providerUnavailable("分组元数据组件在运行中发生变化") }
        // The session/model assertion is provisional; known body-candidate conflicts block the full partition.
        let cameraKeys = primaries.map { evidence -> String? in
            guard let make = SequenceCaptureEvents.canonicalCamera(evidence.cameraMake),let model = SequenceCaptureEvents.canonicalCamera(evidence.cameraModel) else { return nil }
            return make+"\n"+model
        }
        var candidates:[String:[String:Set<String>]] = [:]
        for (i,facts) in normalized.enumerated() {
            guard let camera = cameraKeys[i] else { continue }
            for field in SequenceCaptureEvents.deviceFields { if let value = facts.opaque[field] { candidates[camera,default:[:]][field,default:[]].insert(value) } }
        }
        let mismatched = Set(candidates.filter { $0.value.values.contains { $0.count > 1 } }.map(\.key))
        var entries = input.assets.enumerated().map { i,asset in
            SequenceManifestEntry(assetID:asset.id,ordinal:i,contentHash:asset.contentHash,evidenceRevision:input.assetRevisions[i])
        }
        let scope = "automatic-grouping/"+input.sessionID
        let initial = try SequenceInputManifest(scopeID:scope,sessionID:input.sessionID,orderVersion:SequenceBaseOrder.version,entries:entries)
        for i in entries.indices {
            var camera:SequenceCameraEvidence = .unknown
            if let key = cameraKeys[i] {
                if mismatched.contains(key) { barriers[i] = .assertionMismatch }
                else { camera = .manifestAssertion(id:"runtime-session-model:"+SequenceMetadataEvidenceLoader.sha256(Data(key.utf8)),revision:1,manifestFingerprint:initial.contentFingerprint) }
            }
            entries[i] = SequenceManifestEntry(assetID:entries[i].assetID,ordinal:i,contentHash:entries[i].contentHash,evidenceRevision:entries[i].evidenceRevision,camera:camera,barrier:barriers[i])
        }
        let manifest = try SequenceInputManifest(scopeID:scope,sessionID:input.sessionID,orderVersion:SequenceBaseOrder.version,entries:entries)
        let emptySeal = String(repeating:"0",count:64)
        var metadataFiles:[SequenceMetadataFileEvidence] = [], focusFiles:[SequenceFocusFileEvidence] = [], rows:[SequenceRuntimeMetadataProof.File] = []
        for (i,asset) in input.assets.enumerated() {
            let facts = normalized[i]
            let metadata = SequenceMetadataFileEvidence(assetID:asset.id,currentSHA256:before[i].sha,originalSHA256:before[i].sha,auditSeal:emptySeal,keyID:keyID,
                originalFormat:formats[i],originalCapture:primaries[i],fieldStates:facts.states.filter { SequenceMetadataEvidenceLoader.allFields.contains($0.key) },resolvedNumbers:facts.numbers,opaqueCandidates:facts.opaque)
            let focus = SequenceFocusFileEvidence(assetID:asset.id,currentSHA256:before[i].sha,originalSHA256:before[i].sha,ordinal:i,state:.runtimeExtracted,
                fieldStates:facts.states.filter { SequenceFocusSnapshot.allFields.contains($0.key) },resolvedCodes:facts.codes,resolvedTuples:facts.tuples)
            metadataFiles.append(metadata);focusFiles.append(focus)
            rows.append(.init(assetID:asset.id,contentSHA256:before[i].sha,locationFingerprint:SequenceMetadataEvidenceLoader.sha256(Data(asset.resolvedURL.standardizedFileURL.path.utf8)),
                ordinal:i,evidenceRevision:input.assetRevisions[i],before:before[i].stamp,after:final[i],beforeCredential:before[i].credential,afterCredential:before[i].credential,normalized:facts,nativeEvidence:natives[i],
                metadataDigest:try SequenceRuntimeMetadataProof.metadataDigest(metadata),focusDigest:try SequenceFingerprint.digest(focus),featureDigest:try features[i].map { try SequenceFingerprint.digest($0) },featureVersion:SequenceFrameFeature.version,barrier:barriers[i]))
        }
        let manifestDigest = try SequenceFingerprint.digest(manifest)
        let proof = SequenceRuntimeMetadataProof(version:SequenceRuntimeMetadataProof.providerVersion,toolCommit:RuntimeSequenceTool.commit,toolVersion:"13.59",toolClosureSHA256:tool.closureSHA256,
            registrySHA256:try RuntimeSequenceRegistry.fingerprint,keyID:keyID,manifestSHA256:manifestDigest,files:rows)
        let seal = try proof.digest()
        metadataFiles = metadataFiles.map { file in SequenceMetadataFileEvidence(assetID:file.assetID,currentSHA256:file.currentSHA256,originalSHA256:file.originalSHA256,auditSeal:seal,keyID:keyID,
            originalFormat:file.originalFormat,originalCapture:file.originalCapture,fieldStates:file.fieldStates,resolvedNumbers:file.resolvedNumbers,opaqueCandidates:file.opaqueCandidates) }
        let metadata = SequenceMetadataSnapshot(auditSeal:seal,fingerprint:try SequenceFingerprint.digest(metadataFiles),v1IndexSHA256:tool.closureSHA256,caseManifestSHA256:manifestDigest,files:metadataFiles,runtimeProof:proof)
        let focus = SequenceFocusSnapshot(focusAuditSeal:seal,fingerprint:try SequenceFingerprint.digest(focusFiles),metadataSnapshotFingerprint:metadata.fingerprint,files:focusFiles,runtimeProofDigest:seal)
        let files = entries.enumerated().map { i,entry in SequenceCaptureFileInput(entry:entry,currentEvidence:primaries[i],metadata:metadataFiles[i],contentVersion:input.assetRevisions[i],feature:features[i],readBarrier:barriers[i]) }
        progress(TaskProgress(title:"自动分组：分析序列",total:input.assets.count))
        let analysis = try SequenceMetadataEventPipeline.analyze(files:files,manifest:manifest,metadata:metadata,associationPolicy:.assumeCorroborated,rescuePolicy:.allowShortRestart,
            focusSnapshot:focus,pauseBridgePolicy:.focusRectAndCohortSeparation,cancelled:{ (try? checkpoint()) == nil })
        try checkpoint()
        if let diagnostics {
            var fieldStates:[String:[String:Int]] = [:], barrierCounts:[String:Int] = [:], precision:[String:Int] = [:]
            var coverageStates:[String:Int] = [:], coverageReasons:[String:Int] = [:]
            for facts in normalized { for (field,state) in facts.states { fieldStates[field,default:[:]][state.rawValue,default:0] += 1 } }
            for barrier in barriers.compactMap({ $0 }) { barrierCounts[barrier.rawValue,default:0] += 1 }
            for primary in primaries { precision[primary.time.precision.rawValue,default:0] += 1 }
            for part in analysis.result.coverage {
                let count = part.range.last-part.range.first+1
                coverageStates[part.state.rawValue,default:0] += count
                for reason in part.reasons { coverageReasons[reason.rawValue,default:0] += count }
            }
            diagnostics(RuntimeAutomaticGroupingDiagnostics(assetCount:input.assets.count,eventCount:analysis.map.events.count,groupCount:analysis.result.ranges.count,
                nativeEvidenceCount:natives.compactMap({$0}).count,previewCount:features.compactMap({$0}).count,metadataFailureCount:metadataFailureCount,
                associationHypothesisAssumed:analysis.associationHypothesisAssumed,fieldStateCounts:fieldStates,barrierCounts:barrierCounts,
                nativeContradictionCounts:nativeContradictionCounts,timePrecisionCounts:precision,coverageStateFileCounts:coverageStates,coverageReasonFileCounts:coverageReasons))
        }
        let resultDigest = try SequenceFingerprint.digest(analysis.result)
        let proofs = input.assets.enumerated().map { i,asset in AutomaticGroupingSourceProof(assetID:asset.id,verifiedSHA256:before[i].sha,finalStamp:final[i],issue:barriers[i]?.rawValue) }
        return AutomaticGroupingAnalysis(runID:input.runID,scopeFingerprint:input.scopeFingerprint,manifest:manifest,result:analysis.result,observations:analysis.observations,featuresAvailable:analysis.featuresAvailable,sourceProofs:proofs,
            provenance:AutomaticGroupingProvenance(providerVersion:SequenceRuntimeMetadataProof.providerVersion,analysisSHA256:resultDigest,associationHypothesisAssumed:analysis.associationHypothesisAssumed,
                reportPath:nil,warnings:["拍摄设备来源按本次会话及机型作临时假设；自动组待人工检查", "实时元数据回执："+seal,"RAW/JPEG关联为暂定假设，所有原文件均保留"] + (mismatched.isEmpty ? [] : ["部分设备候选信息矛盾，相应分区已阻断"])))
    }
    /// A wholly failed metadata pass is retryable work, never a successful empty classification.
    static func validateMetadataAvailability(assetCount:Int,metadataFailureCount:Int) throws {
        guard assetCount >= 0, metadataFailureCount >= 0, metadataFailureCount <= assetCount else {
            throw RuntimeSequenceError.invalid("自动分组元数据读取计数无效")
        }
        if assetCount > 0 && metadataFailureCount == assetCount {
            throw RuntimeSequenceError.providerUnavailable("本轮所有素材的拍摄信息读取均失败；保留导入结果，可稍后重试自动分组")
        }
    }
    static func key(libraryURL:URL) throws -> SymmetricKey {
        let url = libraryURL.appendingPathExtension("grouping-key")
        let fd = open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,S_IRUSR|S_IWUSR)
        if fd >= 0 {
            let data = SymmetricKey(size:.bits256).withUnsafeBytes { Data($0) }
            let written = data.withUnsafeBytes { Darwin.write(fd,$0.baseAddress,data.count) };close(fd)
            guard written == data.count else { try? FileManager.default.removeItem(at:url);throw RuntimeSequenceError.invalid("分组隐私密钥写入失败") }
        } else if errno != EEXIST { throw RuntimeSequenceError.invalid("分组隐私密钥不可用") }
        let readFD = open(url.path,O_RDONLY|O_NOFOLLOW)
        guard readFD >= 0 else { throw RuntimeSequenceError.invalid("分组隐私密钥不可读") }
        defer { close(readFD) }
        var info = stat();guard fstat(readFD,&info) == 0, (info.st_mode&S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode&0o777) == 0o600, info.st_size == 32 else { throw RuntimeSequenceError.invalid("分组隐私密钥权限无效") }
        var bytes = [UInt8](repeating:0,count:32)
        guard Darwin.read(readFD,&bytes,32) == 32 else { throw RuntimeSequenceError.invalid("分组隐私密钥长度无效") }
        return SymmetricKey(data:bytes)
    }
}
