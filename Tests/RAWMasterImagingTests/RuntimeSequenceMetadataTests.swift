import XCTest
import Foundation
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class RuntimeSequenceMetadataTests: XCTestCase {
    private final class DiagnosticBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: RuntimeAutomaticGroupingDiagnostics?
        func put(_ value:RuntimeAutomaticGroupingDiagnostics) { lock.lock();defer { lock.unlock() };stored = value }
        func get() -> RuntimeAutomaticGroupingDiagnostics? { lock.lock();defer { lock.unlock() };return stored }
    }
    private let key = SymmetricKey(data:Data(repeating:17,count:32))
    private func normalize(_ fields:String) throws -> RuntimeNormalizedMetadata {
        try RuntimeJSONQ.normalize(Data(("[{\"SourceFile\":\"/authorized.ARW\","+fields+"}]").utf8),expectedSource:"/authorized.ARW",key:key)
    }
    func testJSONQRetainsLeadingZeroSubsecondsAndAll55States() throws {
        let facts = try normalize(#""EXIF:ExifIFD:SubSecTimeOriginal":"001","EXIF:ExifIFD:DateTimeOriginal":"2026:10:01 01:02:03""#)
        XCTAssertEqual(facts.strings["exif.SubSecTimeOriginal"],"001")
        XCTAssertEqual(facts.states.count,55)
        XCTAssertEqual(facts.states["dji.unresolved.CaptureMode"],.unsupportedSelector)
        XCTAssertEqual(facts.states["sony.SequenceNumber"],.absent)
    }
    func testActualQualifiedCollapsedFileAndAdditionalEXIFInstances() throws {
        let facts = try normalize(#""File:FileType":"ARW","File:MIMEType":"image/x-sony-arw","EXIF:IFD2:Copy2:Orientation":"1","EXIF:SubIFD1:ImageWidth":"8640""#)
        XCTAssertEqual(facts.strings["file.FileType"],"ARW")
        XCTAssertEqual(facts.strings["file.MIMEType"],"image/x-sony-arw")
        XCTAssertEqual(facts.numbers["exif.Orientation"],"1")
        XCTAssertEqual(facts.numbers["exif.ImageWidth"],"8640")
        for wrong in [#""File:OtherType":"ARW""#,#""Other:FileType":"ARW""#,#""EXIF:IFD9:Orientation":"1""#,#""EXIF:IFD2:SubjectDistance":"1""#] {
            XCTAssertThrowsError(try normalize(wrong))
        }
    }
    func testRealisticQualifiedMetadataAndCollapsedDiagnosticsTogether() throws {
        let facts = try normalize(#""File:FileType":"ARW","File:MIMEType":"image/x-sony-arw","EXIF:ExifIFD:DateTimeOriginal":"2026:10:01 01:02:03","EXIF:ExifIFD:SubSecTimeOriginal":"001","EXIF:IFD0:Make":"SONY","EXIF:IFD0:Model":"ILCE-1M2","EXIF:ExifIFD:Copy1:ExposureTime":"0.0008","EXIF:IFD2:Copy1:ImageWidth":"8640","MakerNotes:Sony:ReleaseMode":"2","MakerNotes:Sony:FocusLocation":"8640 5760 6318 2700","ExifTool:Warning":"private-warning-content","ExifTool:Copy1:Warning":"another-private-warning""#)
        XCTAssertEqual(facts.strings["file.FileType"],"ARW")
        XCTAssertEqual(facts.strings["exif.Make"],"SONY")
        XCTAssertEqual(facts.strings["exif.Model"],"ILCE-1M2")
        XCTAssertEqual(facts.numbers["exif.ExposureTime"],"0.0008")
        XCTAssertEqual(facts.numbers["exif.ImageWidth"],"8640")
        XCTAssertEqual(facts.numbers["sony.ReleaseMode"],"2")
        XCTAssertEqual(facts.tuples["sony.FocusLocation"],[8640,5760,6318,2700])
        XCTAssertEqual(facts.warningDigests.count,2)
        XCTAssertTrue(facts.warningDigests.allSatisfy(SequenceMetadataEvidenceLoader.isSHA))
        let time = SequenceTimestampParser.parse(original:facts.strings["exif.DateTimeOriginal"],subseconds:facts.strings["exif.SubSecTimeOriginal"],offset:nil)
        XCTAssertEqual(time.local?.nanosecond,1_000_000)
        XCTAssertEqual(time.precision,.subsecond)
        let retained = String(decoding:try JSONEncoder().encode(facts),as:UTF8.self)
        XCTAssertFalse(retained.contains("private-warning"))
        for name in ["ExifTool:Error","ExifTool:Copy1:Error","ExifTool:ExifTool:Error","ExifTool:ExifTool:Copy2:Error"] {
            XCTAssertThrowsError(try normalize("\""+name+"\":\"unusable\""))
        }
        for name in ["Other:Warning","ExifTool:Other:Warning","ExifTool:CopyN:Warning"] {
            XCTAssertThrowsError(try normalize("\""+name+"\":\"private-warning\""))
        }
    }
    func testDuplicateJSONKeysWrongNamespaceAndNonStringScalarReject() {
        for text in [#""EXIF:ExifIFD:SubSecTimeOriginal":"001","EXIF:ExifIFD:SubSecTimeOriginal":"123""#,
                     #""EXIF:GPS:SubjectDistance":"1""#,
                     #""MakerNotes:Sony:Unexpected:FocusMode":"3""#,
                     #""EXIF:ExifIFD:SubSecTimeOriginal":123"#,
                     #""EXIF:ExifIFD:SubSecTimeOriginal":true"#] {
            XCTAssertThrowsError(try normalize(text))
        }
    }
    func testNilRuntimePropertiesAreOmittedFromLegacyEncoding() throws {
        let zero = String(repeating:"0",count:64)
        let metadata = SequenceMetadataSnapshot(auditSeal:zero,fingerprint:zero,v1IndexSHA256:zero,caseManifestSHA256:zero,files:[])
        let focus = SequenceFocusSnapshot(focusAuditSeal:zero,fingerprint:zero,metadataSnapshotFingerprint:zero,files:[])
        let metadataObject = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(metadata)) as? [String:Any])
        let focusObject = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(focus)) as? [String:Any])
        XCTAssertNil(metadataObject["runtimeProof"])
        XCTAssertNil(focusObject["runtimeProofDigest"])
        let object = try normalize(#""EXIF:ExifIFD:SubSecTimeOriginal":{"x":"1"}"#)
        XCTAssertEqual(object.states["exif.SubSecTimeOriginal"],.invalid)
    }
    func testAllInstancesMustAgreeAndInvalidDominates() throws {
        let equivalent = try normalize(#""MakerNotes:Sony:FocusMode":"3.0","MakerNotes:Sony:Copy1:FocusMode":"3e0""#)
        XCTAssertEqual(equivalent.codes["sony.FocusMode"],3)
        let conflict = try normalize(#""MakerNotes:Sony:FocusMode":"3","MakerNotes:Sony:Copy1:FocusMode":"4""#)
        XCTAssertEqual(conflict.states["sony.FocusMode"],.conflicting)
        XCTAssertNil(conflict.codes["sony.FocusMode"])
        let invalid = try normalize(#""MakerNotes:Sony:FocusMode":"3","MakerNotes:Sony:Copy1:FocusMode":"-1""#)
        XCTAssertEqual(invalid.states["sony.FocusMode"],.invalid)
    }
    func testTupleUIntBoundsPrivacyAndExactDistance() throws {
        let facts = try normalize(#""MakerNotes:Sony:FocusLocation":["100","200","0","65535"],"EXIF:ExifIFD:SerialNumber":"secret-body","EXIF:ExifIFD:SubjectDistance":"1.123456789012345678901234567890123456789e1000""#)
        XCTAssertEqual(facts.tuples["sony.FocusLocation"],[100,200,0,65535])
        XCTAssertEqual(facts.strings["exif.SubjectDistance"],"1.123456789012345678901234567890123456789e1000")
        let bytes = try JSONEncoder().encode(facts)
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("secret-body"))
        XCTAssertEqual(facts.opaque["exif.SerialNumber"]?.count,64)
        let invalid = try normalize(#""MakerNotes:Sony:FocusLocation":["100","200","0","65536"],"MakerNotes:Sony:FocusMode":"4294967296""#)
        XCTAssertEqual(invalid.states["sony.FocusLocation"],.invalid)
        XCTAssertEqual(invalid.states["sony.FocusMode"],.invalid)
        XCTAssertThrowsError(try normalize("\"EXIF:ExifIFD:SubSecTimeOriginal\":\""+String(repeating:"1",count:257)+"\""))
    }
    func testChildOutputBudgetTimeoutAndCancellationAreBounded() {
        XCTAssertThrowsError(try RuntimeMetadataChild.run(arguments:["-e","print 'x' x 1100000"],check:{}))
        XCTAssertThrowsError(try RuntimeMetadataChild.run(arguments:["-e","sleep 3"],timeout:0.02,check:{}))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try RuntimeMetadataChild.run(arguments:["-e","sleep 3"],check:{
            if ProcessInfo.processInfo.systemUptime-start > 0.03 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
    }
    func testWhollyFailedMetadataPassIsRetryableButEmptyPartialAndValidUngroupedScopesRemainAllowed() {
        XCTAssertThrowsError(try RuntimeAutomaticGroupingAnalyzer.validateMetadataAvailability(assetCount:50,metadataFailureCount:50)) { error in
            guard let runtime = error as? RuntimeSequenceError, case .providerUnavailable = runtime else { return XCTFail("A wholly failed metadata read must fail the provider") }
        }
        XCTAssertNoThrow(try RuntimeAutomaticGroupingAnalyzer.validateMetadataAvailability(assetCount:0,metadataFailureCount:0))
        XCTAssertNoThrow(try RuntimeAutomaticGroupingAnalyzer.validateMetadataAvailability(assetCount:50,metadataFailureCount:1))
        XCTAssertNoThrow(try RuntimeAutomaticGroupingAnalyzer.validateMetadataAvailability(assetCount:50,metadataFailureCount:0))
        XCTAssertThrowsError(try RuntimeAutomaticGroupingAnalyzer.validateMetadataAvailability(assetCount:1,metadataFailureCount:2))
    }
    func testMissingHelperIsFatalProviderFailure() {
        XCTAssertThrowsError(try RuntimeMetadataChild.run(arguments:["/nonexistent/RAWMaster-metadata-helper"],check:{})) { error in
            guard let runtime = error as? RuntimeSequenceError, case .providerUnavailable = runtime else { return XCTFail("Missing helper must fail the provider, not return an empty valid classification") }
        }
    }
    func testRuntimeReceiptRejectsSelfConsistentWrongRegistry() throws {
        let zero = String(repeating:"0",count:64)
        let manifest = try SequenceInputManifest(scopeID:"runtime-test",sessionID:"runtime-test",orderVersion:SequenceBaseOrder.version,entries:[])
        func snapshot(registry:String) throws -> SequenceMetadataSnapshot {
            let proof = SequenceRuntimeMetadataProof(version:SequenceRuntimeMetadataProof.providerVersion,toolCommit:RuntimeSequenceTool.commit,toolVersion:"13.59",toolClosureSHA256:zero,
                registrySHA256:registry,keyID:zero,manifestSHA256:try SequenceFingerprint.digest(manifest),files:[])
            return SequenceMetadataSnapshot(auditSeal:try proof.digest(),fingerprint:try SequenceFingerprint.digest([SequenceMetadataFileEvidence]()),v1IndexSHA256:zero,
                caseManifestSHA256:try SequenceFingerprint.digest(manifest),files:[],runtimeProof:proof)
        }
        XCTAssertNoThrow(try snapshot(registry:RuntimeSequenceRegistry.fingerprint).validateBindings(manifest:manifest))
        XCTAssertThrowsError(try snapshot(registry:zero).validateBindings(manifest:manifest))
    }
    func testSourceAndToolErrorsAreNeverUsableFacts() {
        XCTAssertThrowsError(try RuntimeJSONQ.normalize(Data(#"[{"SourceFile":"/other.ARW"}]"#.utf8),expectedSource:"/authorized.ARW",key:key))
        XCTAssertThrowsError(try normalize(#""ExifTool:ExifTool:Error":"broken""#))
    }
    func testLibraryKeyRejectsSymlinkAndKeeps0600() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-key-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = root.appendingPathComponent("library.sqlite")
        let a = try RuntimeAutomaticGroupingAnalyzer.key(libraryURL:library)
        let b = try RuntimeAutomaticGroupingAnalyzer.key(libraryURL:library)
        XCTAssertEqual(a.withUnsafeBytes { Data($0) },b.withUnsafeBytes { Data($0) })
        let other = root.appendingPathComponent("other.sqlite")
        try FileManager.default.createSymbolicLink(at:other.appendingPathExtension("grouping-key"),withDestinationURL:library.appendingPathExtension("grouping-key"))
        XCTAssertThrowsError(try RuntimeAutomaticGroupingAnalyzer.key(libraryURL:other))
    }
    /// Explicit local-only opt-in: Root supplies a bounded original directory and packaged tool root.
    func testOptInActualRAWImportCallbackKeepsEveryFileAndSourcesUnchanged() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["RAWMASTER_RUNTIME_RAW_DIRECTORY"],let tool = env["RAWMASTER_RUNTIME_TOOL_ROOT"] else {
            throw XCTSkip("Set RAWMASTER_RUNTIME_RAW_DIRECTORY and RAWMASTER_RUNTIME_TOOL_ROOT for a bounded original-RAW trial")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-import-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let started = ProcessInfo.processInfo.systemUptime
        let library = root.appendingPathComponent("library.sqlite"), store = try LibraryStore(databaseURL:library)
        let observed = DiagnosticBox()
        let importer = ImportService(store:store,postIngest:RuntimeAutomaticGroupingCoordinator.callback(store:store,libraryURL:library,toolRoot:URL(fileURLWithPath:tool),diagnostics:{ observed.put($0) }))
        let mode:ImportMode = env["RAWMASTER_RUNTIME_IMPORT_MODE"] == "copy" ? .copy : .reference
        let destination = mode == .copy ? root.appendingPathComponent("managed") : nil
        let session = try await importer.importDirectory(source:URL(fileURLWithPath:source),destination:destination,projectName:"Runtime RAW trial",mode:mode,progress:{ _ in })
        XCTAssertEqual(session.status,"completed")
        let assets = try store.loadAssets(sessionID:session.id)
        XCTAssertFalse(assets.isEmpty)
        let run = try XCTUnwrap(store.automaticGroupingRun(sessionID:session.id))
        XCTAssertTrue([AutomaticGroupingRunState.applied,.completedNoGroups].contains(run.state),run.message ?? "")
        XCTAssertEqual(run.provenance?.providerVersion,SequenceRuntimeMetadataProof.providerVersion)
        XCTAssertEqual(try store.loadAssets(sessionID:session.id).count,assets.count)
        var unchanged = true
        for asset in assets {
            let current = try RuntimeSequenceTool.hash(asset.resolvedURL), original = try RuntimeSequenceTool.hash(asset.resolvedSourceURL)
            unchanged = unchanged && current == asset.contentHash && original == asset.contentHash
            XCTAssertEqual(current,asset.contentHash);XCTAssertEqual(original,asset.contentHash)
        }
        let ordered = SequenceBaseOrder.sorted(assets,sessions:[session]), groups = try store.loadGroups(projectID:session.projectID)
        if let minimum = env["RAWMASTER_RUNTIME_MIN_GROUPS"].flatMap(Int.init) { XCTAssertGreaterThanOrEqual(groups.count,minimum) }
        if let first = env["RAWMASTER_RUNTIME_EXPECTED_FIRST"],let last = env["RAWMASTER_RUNTIME_EXPECTED_LAST"] {
            let expected = ordered.filter { $0.filename >= first && $0.filename <= last }.map(\.id)
            XCTAssertFalse(expected.isEmpty)
            XCTAssertTrue(groups.contains { $0.assetIDs == expected },"Expected complete bounded sequence was not emitted as an exact group")
        }
        var undone = false
        if run.state == .applied,let command = run.commandID {
            _ = try store.undoGroupCommand(id:command)
            undone = try store.loadGroups(projectID:session.projectID).isEmpty
            XCTAssertTrue(undone)
            XCTAssertEqual(try store.loadAssets(sessionID:session.id).count,assets.count)
        }
        // Ordinary resume after undo must not reapply the successful one-shot command.
        _ = try await importer.resume(sessionID:session.id,progress:{ _ in })
        XCTAssertEqual(try store.automaticGroupingRun(sessionID:session.id)?.runID,run.runID)
        if undone { XCTAssertTrue(try store.loadGroups(projectID:session.projectID).isEmpty) }
        if let path = env["RAWMASTER_RUNTIME_SUMMARY_PATH"] {
            let target = URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
            let sourceRoot = URL(fileURLWithPath:source).standardizedFileURL.resolvingSymlinksInPath().path
            guard target.path != sourceRoot && !target.path.hasPrefix(sourceRoot+"/") else { throw RuntimeSequenceError.invalid("Test summary must remain outside original source") }
            let ranges = groups.map { group -> [String:Int] in
                let indexes = group.assetIDs.compactMap { id in ordered.firstIndex { $0.id == id } }
                return ["firstOrdinal":indexes.min() ?? -1,"lastOrdinal":indexes.max() ?? -1,"count":group.assetIDs.count]
            }
            var summary:[String:Any] = ["assetCount":assets.count,"groupCount":groups.count,"ranges":ranges,"runState":run.state.rawValue,
                "providerVersion":run.provenance?.providerVersion ?? "","sourceSHAUnchanged":unchanged,"undone":undone,"mode":mode.rawValue,
                "elapsedSeconds":ProcessInfo.processInfo.systemUptime-started]
            if let diagnostics = observed.get() { summary["diagnostics"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(diagnostics)) }
            try JSONSerialization.data(withJSONObject:summary,options:[.sortedKeys,.prettyPrinted]).write(to:target,options:.withoutOverwriting)
        }
    }
}
