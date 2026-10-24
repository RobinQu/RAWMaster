import Foundation
import Darwin
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

struct MetadataExperimentUnit: Codable {
    let schemaVersion: Int
    let runID, unitID, phase, caseID: String
    let variant: String?
    let expectedPolicyFingerprint: String?
    let fixtureIndexSHA256, metadataIndexSHA256, sourceSnapshotSHA256, executableSHA256: String
}
private final class MetadataTraceCollector: @unchecked Sendable {
    private let lock=NSLock()
    private var records:[SequenceTraceEvent]=[]
    private var overflow=false
    func record(_ value:SequenceTraceEvent) {
        guard value.metadataRescue != nil else { return }
        lock.lock();defer { lock.unlock() }
        guard records.count<4096 else { overflow=true;return };records.append(value)
    }
    func snapshot() throws -> [SequenceTraceEvent] {
        lock.lock();defer { lock.unlock() }
        guard !overflow else { throw SequenceFixtureError.invalid("Metadata hook diagnostics truncated") };return records
    }
}
enum MetadataExperimentHarness {
    static let variants=["dev4","strict-continuation","strict-shortRestart","assumed-continuation","assumed-shortRestart"]
    struct Prepared {
        let item:SequenceFixtureIndex.Case
        let native:ProbeAnalysis
        let files:[SequenceCaptureFileInput]
        let snapshot:SequenceMetadataSnapshot
    }
    static func processPeakResidentBytes() -> Int64? {
        var usage = rusage()
        return getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : nil
    }
    static func policies(_ variant:String) throws -> (SequenceAssociationPolicy,SequenceMetadataRescuePolicy) {
        switch variant {
        case "strict-continuation":return (.strict,.continuationOnly)
        case "strict-shortRestart":return (.strict,.allowShortRestart)
        case "assumed-continuation":return (.assumeCorroborated,.continuationOnly)
        case "assumed-shortRestart":return (.assumeCorroborated,.allowShortRestart)
        default:throw SequenceFixtureError.invalid("Unknown metadata variant")
        }
    }
    static func prepare(_ request:MetadataExperimentUnit,v1:URL,v2:URL) throws -> Prepared {
        let (index,bytes)=try SequenceFixtureHarness.loadIndex(root:v1)
        guard request.schemaVersion==1,request.fixtureIndexSHA256==SequenceProbeRun.sha256(bytes),
              [request.sourceSnapshotSHA256,request.executableSHA256].allSatisfy(SequenceFixtureFiles.isDigest),
              let item=index.cases.first(where:{$0.id==request.caseID}) else { throw SequenceFixtureError.invalid("Metadata execution identity") }
        let metadataIndex=try SequenceMetadataEvidenceLoader.loadIndex(at:v2.appendingPathComponent("index.json"),expectedSHA256:request.metadataIndexSHA256)
        guard let metadataCase=metadataIndex.cases.first(where:{$0.id==request.caseID}) else { throw SequenceFixtureError.invalid("Missing metadata case") }
        let (manifestBytes,manifestURL)=try SequenceFixtureHarness.verifiedSidecar(item.manifestPath,expectedHash:item.manifestSHA256,root:v1)
        let fixture=try SequenceFixtureHarness.decode(SequenceFixtureManifest.self,data:manifestBytes)
        try fixture.validate(expectedCount:item.assetCount)
        let description=try SequenceFixtureHarness.decode(ProbeManifest.self,data:manifestBytes)
        let snapshot=try SequenceMetadataEvidenceLoader.loadCase(metadataCase,index:metadataIndex,metadataRoot:v2,v1Root:v1,v1ManifestURL:manifestURL)
        var reads:[String:ProbeReadValue]=[:]
        let policy=SpatialExperimentHarness.policy(caseID:item.id,configuration:.init(),trace:false)
        // Reuse the reviewed native hash/reader pipeline. Its default classifier result is only
        // preparation/control here; no labels are loaded and no metadata repairs native evidence.
        let native=try SequenceProbeRun.analyze(manifest:description,root:manifestURL.deletingLastPathComponent(),policy:policy,reader:{ url,entry,credential in
            let read=try SequenceCaptureReader.read(at:url,assetID:entry.assetID,contentHash:entry.contentHash!,evidenceRevision:entry.evidenceRevision,verifiedCredential:credential)
            let value=ProbeReadValue(evidence:read.evidence,feature:read.feature,failure:read.previewFailure)
            reads[entry.assetID]=value;return value
        })
        guard native.sourcesUnchanged,native.manifest.entries.count==item.assetCount else { throw SequenceFixtureError.invalid("Current JPEG source proof failed") }
        try snapshot.validateBindings(manifest:native.manifest)
        let (expectationData,_)=try SequenceFixtureHarness.verifiedSidecar(item.metadataPath,expectedHash:item.metadataSHA256,root:v1)
        let expectation=try SequenceFixtureHarness.decode(SequenceFixtureMetadata.self,data:expectationData)
        var files:[SequenceCaptureFileInput]=[]
        for ordinal in fixture.files.indices {
            let declared=fixture.files[ordinal],entry=native.manifest.entries[ordinal],source=native.sources[ordinal]
            guard declared.jpegSHA256==source.beforeSHA256,source.beforeSHA256==source.afterSHA256,
                  declared.sourceCapture.sha256==snapshot.files[ordinal].originalSHA256,
                  let read=reads[entry.assetID] else { throw SequenceFixtureError.invalid("Native read/content supplement coverage") }
            try SequenceFixtureHarness.validateMetadata(expectation.assets[ordinal],evidence:read.evidence,sourceHash:declared.sourceCapture.sha256,recipe:index.recipe)
            files.append(SequenceCaptureFileInput(entry:entry,currentEvidence:read.evidence,metadata:snapshot.files[ordinal],contentVersion:0,
                feature:read.feature,readBarrier:read.feature==nil ? .missingEmbeddedPreview : nil))
        }
        return Prepared(item:item,native:native,files:files,snapshot:snapshot)
    }
    static func configuration(_ variant:String,prepared:Prepared) throws -> SequenceDetectorConfiguration {
        if variant=="dev4" { return .init() }
        let (association,rescue)=try policies(variant)
        let map=try SequenceCaptureEvents.make(files:prepared.files,manifest:prepared.native.manifest,metadata:prepared.snapshot,
            confirmedPairs:[],policy:association)
        var configuration=SequenceDetectorConfiguration()
        configuration.metadataExperiment=SequenceMetadataExperimentConfiguration(associationPolicy:association,rescuePolicy:rescue,
            auditSeal:prepared.snapshot.auditSeal,snapshotFingerprint:prepared.snapshot.fingerprint,eventMapFingerprint:map.fingerprint)
        try configuration.validate();return configuration
    }
    static func bootstrap(_ request:MetadataExperimentUnit,v1:URL,v2:URL) throws -> [String:Any] {
        let prepared=try prepare(request,v1:v1,v2:v2)
        let records:[[String:Any]]=try variants.map { name in
            let config=try configuration(name,prepared:prepared)
            return ["variant":name,"policyFingerprint":try config.fingerprint,"configuration":try SpatialExperimentHarness.object(config)]
        }
        return ["schemaVersion":1,"kind":"metadata-descriptor","identity":try SpatialExperimentHarness.object(request),
            "variants":records,"metadataSnapshotSHA256":prepared.snapshot.fingerprint,"metadataAuditSeal":prepared.snapshot.auditSeal,
            "platform":try SpatialExperimentHarness.object(SequenceFixturePlatform()),"labelsRead":false]
    }
    static func run(_ request:MetadataExperimentUnit,v1:URL,v2:URL,output:URL) throws -> [String:Any] {
        guard request.phase=="quality",let variant=request.variant,variants.contains(variant) else { throw SequenceFixtureError.invalid("Metadata quality unit shape") }
        let started=ProcessInfo.processInfo.systemUptime
        let prepared=try prepare(request,v1:v1,v2:v2),collector=MetadataTraceCollector()
        var projected:SequenceMetadataEventAnalysis?
        let analysis:ProbeAnalysis
        if variant=="dev4" { analysis=prepared.native }
        else {
            let (association,rescue)=try policies(variant)
            let result=try SequenceMetadataEventPipeline.analyze(files:prepared.files,manifest:prepared.native.manifest,metadata:prepared.snapshot,
                associationPolicy:association,rescuePolicy:rescue,trace:{collector.record($0)})
            projected=result
            analysis=ProbeAnalysis(manifest:result.manifest,result:result.result,observations:result.observations,featuresAvailable:result.featuresAvailable,
                sources:prepared.native.sources,hashBeforeSeconds:prepared.native.hashBeforeSeconds,
                readerAndEngineSeconds:prepared.native.readerAndEngineSeconds+result.analysisSeconds,hashAfterSeconds:prepared.native.hashAfterSeconds,
                analysisSeconds:prepared.native.analysisSeconds+result.analysisSeconds,engineManagedPeakEstimateBytes:result.managedPeakEstimateBytes,
                processPeakResidentBytes:processPeakResidentBytes())
        }
        let config=projected?.configuration ?? SequenceDetectorConfiguration()
        guard request.expectedPolicyFingerprint == (try config.fingerprint) else { throw SequenceFixtureError.invalid("Frozen effective metadata policy changed") }
        let hooks=try collector.snapshot()
        let analysisBytes=try SequenceFixtureHarness.encoded(analysis),analysisSHA=SequenceProbeRun.sha256(analysisBytes)
        let mapObject:Any=try projected.map { try SpatialExperimentHarness.object($0.map) } ?? NSNull()
        let sealObject:[String:Any]=["analysis":try JSONSerialization.jsonObject(with:analysisBytes),"eventMap":mapObject,
            "configuration":try SpatialExperimentHarness.object(config),"metadataSnapshotSHA256":prepared.snapshot.fingerprint,
            "metadataHookEvents":try SpatialExperimentHarness.object(hooks)]
        let sealBytes=try JSONSerialization.data(withJSONObject:sealObject,options:[.sortedKeys,.withoutEscapingSlashes])
        let seal=SequenceProbeRun.sha256(sealBytes),sealURL=output.appendingPathExtension("analysis.json")
        try FileManager.default.createDirectory(at:sealURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try sealBytes.write(to:sealURL,options:.withoutOverwriting) // Before human labels are opened.
        let policy=SpatialExperimentHarness.policy(caseID:request.caseID,configuration:config,trace:false)
        let (truthData,_)=try SequenceFixtureHarness.verifiedSidecar(prepared.item.truthPath,expectedHash:prepared.item.truthSHA256,root:v1)
        let labels=try SequenceFixtureHarness.decode(ProbeLabels.self,data:truthData)
        let evaluation:ProbeEvaluation
        if let projected,let metadataConfig=config.metadataExperiment {
            evaluation=try ProbeEvaluator.evaluateMetadata(analysis:analysis,labels:labels,policy:policy,configuration:metadataConfig,
                files:prepared.files,map:projected.map,metadata:prepared.snapshot,confirmedPairs:[])
        } else { evaluation=try ProbeEvaluator.evaluate(analysis,labels:labels,policy:policy) }
        let assumed=projected?.associationHypothesisAssumed ?? false
        let limitations=evaluation.failures.filter { $0.contains("support") || $0.contains("acceptanceIncomplete") || $0=="acceptanceNotConfigured" || $0=="source-declaration-contradicted" }
            + (prepared.item.completeGroupTruth ? []:["full-group-extent-not-labeled; DJI0188 remains unknown"])
        let topAccepted=evaluation.acceptedWithinDeclaredSourceScope && !assumed && prepared.item.completeGroupTruth
        let behavior=SequenceFixtureCaseBehavior(id:prepared.item.id,assetCount:prepared.item.assetCount,manifestSHA256:prepared.item.manifestSHA256,
            metadataSHA256:prepared.item.metadataSHA256,truthSHA256:prepared.item.truthSHA256,policyFingerprint:try config.fingerprint,
            result:analysis.result,evaluation:evaluation,completeGroupTruth:prepared.item.completeGroupTruth,unknownAssetIDs:prepared.item.unknownAssetIDs,
            integrityValidated:true,qualityAccepted:topAccepted,evidenceLimitations:limitations,classificationFailures:evaluation.failures.filter{!limitations.contains($0)})
        if variant=="dev4" { try SpatialExperimentHarness.validateDefaultGolden(behavior,root:v1) }
        return ["schemaVersion":1,"kind":"metadata-quality-unit","identity":try SpatialExperimentHarness.object(request),
            "integrityValidated":true,"strictValidated":true,"analysisSealedBeforeLabels":true,"analysisSHA256":analysisSHA,
            "supplementAnalysisSealSHA256":seal,"analysisPath":sealURL.path,"resultSHA256":try SequenceProbeRun.resultSHA256(analysis.result),
            "behavior":try SpatialExperimentHarness.object(behavior),"configuration":try SpatialExperimentHarness.object(config),
            "metadataSnapshotSHA256":prepared.snapshot.fingerprint,"auditSeal":prepared.snapshot.auditSeal,"eventMap":mapObject,
            "eventResult":try projected.map{try SpatialExperimentHarness.object($0.eventResult)} ?? NSNull(),
            "metadataStatistics":try projected?.metadataStatistics.map{try SpatialExperimentHarness.object($0)} ?? NSNull(),
            "associationHypothesisAssumed":assumed,"topQualityAccepted":topAccepted,
            "metricsMeaning":assumed ? "conditionalGroupingMetrics" : "strictGroupingMetricsUnderDeclaredSource",
            "pairPrecision":NSNull(),"metadataHookEvents":try SpatialExperimentHarness.object(hooks),
            "metadataHookTraceBoundary":"Filtered hook summaries only; generic trace cap unchanged; absence is not causal evidence",
            "wholeUnitSeconds":ProcessInfo.processInfo.systemUptime-started,"platform":try SpatialExperimentHarness.object(SequenceFixturePlatform()),
            "engineManagedPeakEstimateBytes":analysis.engineManagedPeakEstimateBytes,
            "processPeakResidentBytes":processPeakResidentBytes().map { NSNumber(value:$0) as Any } ?? NSNull(),
            "processPeakBoundary":"Process high-water RSS at report construction includes fixture/control loading, native preparation, optional candidate, sealing and label evaluation; engine managed estimate excludes caller-owned input/frameworks",
            "timingBoundary":"Native before/read/default-preparation/after proof plus optional event pipeline; no GUI claim, no264benchmark. Labels/report writes excluded from analysis timings."]
    }
}
