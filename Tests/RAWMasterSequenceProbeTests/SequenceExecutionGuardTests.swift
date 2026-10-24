import XCTest
import Foundation
import CryptoKit

final class SequenceExecutionGuardTests: XCTestCase {
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    struct Fixture { let root: URL; let script: URL; let binary: URL; let freeze: URL; let receipt: URL; let marker: URL; let arguments: [String] }
    func prepare(replaceOriginals: Bool = false, exitCode: Int = 0, watchdog: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sequence-guard-" + UUID().uuidString)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let names = ["Package.swift", "Sources/CSQLite/module.modulemap", "Sources/CSQLite/shim.h", "Sources/RAWMasterCore/Stub.swift", "Sources/RAWMasterImaging/Stub.swift", "Sources/RAWMasterSequenceProbe/Stub.swift", "scripts/run-sequence-validation.py"]
        var hashes: [String: String] = [:], aggregate = Data()
        for name in names.sorted() {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = name.hasSuffix(".py") ? try Data(contentsOf: repository.appendingPathComponent(name)) : Data("// synthetic source\n".utf8)
            try bytes.write(to: url); hashes[name] = digest(bytes)
            aggregate.append(Data((name + "\0").utf8)); aggregate.append(bytes)
        }
        var controls: [String: [String: String]] = [:]
        for key in ["manifest", "policy", "labels"] {
            let path = root.appendingPathComponent(key + ".json")
            let text = key == "policy" ? "{\"synthetic\":\"policy\",\"maximumDurationSeconds\":\(watchdog ? 0.01 : 30)}\n" : "{\"synthetic\":\"\(key)\"}\n"
            let bytes = Data(text.utf8)
            try bytes.write(to: path); controls[key] = ["path": path.path, "sha256": digest(bytes)]
        }
        let binary = root.appendingPathComponent("original-binary"), marker = root.appendingPathComponent("report-marker"), receipt = root.appendingPathComponent("receipt.json")
        let mutation = replaceOriginals ? "printf '# replaced original binary\\n' > '\(binary.path)'\nprintf '{\"changed\":true}\\n' > '\(root.appendingPathComponent("manifest.json").path)'\n" : ""
        let normalStub = "#!/bin/sh\n" + mutation + "printf '%s\\n' \"$0\" \"$4\" >> \"${10}\"\ncat \"$4\" >> \"${10}\"\nexit \(exitCode)\n"
        let stub = Data((watchdog ? "#!/bin/sh\nexec /bin/sleep 5\n" : normalStub).utf8)
        try stub.write(to: binary); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let arguments = ["--source-root", root.appendingPathComponent("never-read-raw").path, "--manifest", controls["manifest"]!["path"]!, "--policy", controls["policy"]!["path"]!, "--labels", controls["labels"]!["path"]!, "--report", marker.path]
        let freeze: [String: Any] = ["schemaVersion": 1, "experimentID": UUID().uuidString, "receiptPath": receipt.path, "sourceSHA256": hashes, "aggregateSourceSHA256": digest(aggregate), "binarySHA256": digest(stub), "controls": controls, "arguments": arguments]
        let frozen = root.appendingPathComponent("freeze.json")
        try JSONSerialization.data(withJSONObject: freeze, options: .sortedKeys).write(to: frozen)
        return Fixture(root: root, script: root.appendingPathComponent("scripts/run-sequence-validation.py"), binary: binary, freeze: frozen, receipt: receipt, marker: marker, arguments: arguments)
    }
    func invoke(_ f: Fixture, arguments: [String]? = nil) throws -> (Int32, [String: Any]) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [f.script.path, "--repo", f.root.path, "--freeze", f.freeze.path, "--binary", f.binary.path, "--receipt", f.receipt.path, "--"] + (arguments ?? f.arguments)
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: f.receipt)) as! [String: Any]
        return (process.terminationStatus, receipt)
    }
    func testEveryFrozenInputMismatchRefusesBeforeLaunching() throws {
        for changed in ["source", "binary", "policy", "manifest", "labels", "parameters", "relative-path", "added-source"] {
            let f = try prepare(); defer { try? FileManager.default.removeItem(at: f.root) }
            var arguments = f.arguments
            switch changed {
            case "source": try Data("// changed\n".utf8).write(to: f.root.appendingPathComponent("Sources/RAWMasterCore/Stub.swift"))
            case "binary": try Data("#!/bin/sh\nexit 0\n".utf8).write(to: f.binary)
            case "policy", "manifest", "labels": try Data("{\"changed\":true}".utf8).write(to: f.root.appendingPathComponent(changed + ".json"))
            case "parameters": arguments[1] += "-changed"
            case "relative-path": arguments[1] = "relative-source"
            default: try Data("// newly compiled source\n".utf8).write(to: f.root.appendingPathComponent("Sources/RAWMasterSequenceProbe/Added.swift"))
            }
            let (status, receipt) = try invoke(f, arguments: arguments)
            XCTAssertEqual(status, 78, changed); XCTAssertEqual(receipt["launched"] as? Bool, false, changed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.marker.path), changed)
        }
    }
    func testFrozenRelativePathStillRefusesBeforeLaunch() throws {
        let f = try prepare(); defer { try? FileManager.default.removeItem(at: f.root) }
        var frozen = try JSONSerialization.jsonObject(with: Data(contentsOf: f.freeze)) as! [String: Any]
        var arguments = f.arguments; arguments[1] = "relative-source"
        frozen["arguments"] = arguments
        try JSONSerialization.data(withJSONObject: frozen, options: .sortedKeys).write(to: f.freeze)
        let (status, receipt) = try invoke(f, arguments: arguments)
        XCTAssertEqual(status, 78); XCTAssertEqual(receipt["launched"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.marker.path))
    }
    func testMatchingFreezeRunsPrivateBinaryAndPrivateControlsOnlyOnce() throws {
        let f = try prepare(replaceOriginals: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let (status, receipt) = try invoke(f)
        XCTAssertEqual(status, 0); XCTAssertEqual(receipt["executedPrivateVerifiedSnapshot"] as? Bool, true)
        let marker = try String(contentsOf: f.marker, encoding: .utf8)
        let lines = marker.split(separator: "\n").map(String.init)
        XCTAssertNotEqual(lines[0], f.binary.path); XCTAssertNotEqual(lines[1], f.arguments[3])
        XCTAssertTrue(lines[2].contains("manifest")); XCTAssertFalse(lines[2].contains("changed"))
        let originalReceipt = try Data(contentsOf: f.receipt)
        XCTAssertEqual(try invoke(f).0, 78)
        XCTAssertEqual(try Data(contentsOf: f.receipt), originalReceipt)
        XCTAssertEqual(try String(contentsOf: f.marker, encoding: .utf8), marker)
    }
    func testFrozenWatchdogKillsAndJoinsWithoutRetry() throws {
        let f = try prepare(watchdog: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let start = ProcessInfo.processInfo.systemUptime
        let (status, receipt) = try invoke(f)
        XCTAssertEqual(status, 124); XCTAssertEqual(receipt["status"] as? String, "launched-timeout")
        XCTAssertEqual(receipt["launched"] as? Bool, true); XCTAssertEqual(receipt["childTimeoutEnforced"] as? Bool, true)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.marker.path))
        XCTAssertEqual(try invoke(f).0, 78)
    }
    func testExecFailureIsNotReportedAsPreflightRefusal() throws {
        let f = try prepare(); defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = Data("not an executable format".utf8)
        try bytes.write(to: f.binary)
        var frozen = try JSONSerialization.jsonObject(with: Data(contentsOf: f.freeze)) as! [String: Any]
        frozen["binarySHA256"] = digest(bytes)
        try JSONSerialization.data(withJSONObject: frozen, options: .sortedKeys).write(to: f.freeze)
        let (status, receipt) = try invoke(f)
        XCTAssertEqual(status, 126); XCTAssertEqual(receipt["status"] as? String, "launch-failed")
        XCTAssertEqual(receipt["launchAttempted"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.marker.path))
    }
    func testFreezeDigestBindsExactlyTheParsedBytesDuringPathReplacement() throws {
        let f = try prepare(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try Data(contentsOf: f.freeze)
        let expected = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        let program = """
        import json, pathlib, runpy, sys
        guard = runpy.run_path(sys.argv[1])
        path = pathlib.Path(sys.argv[2])
        class ReplacedAfterRead:
            count = 0
            def read_bytes(self):
                self.count += 1
                data = path.read_bytes()
                path.write_bytes(b'{"experimentID":"replacement"}')
                return data
        value = ReplacedAfterRead()
        document, checksum = guard['read_frozen'](value)
        print(json.dumps({'experimentID': document['experimentID'], 'sha256': checksum, 'reads': value.count}))
        """
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", program, f.script.path, f.freeze.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let actual = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        XCTAssertEqual(actual["experimentID"] as? String, expected["experimentID"] as? String)
        XCTAssertEqual(actual["sha256"] as? String, digest(original)); XCTAssertEqual(actual["reads"] as? Int, 1)
        XCTAssertNotEqual(digest(try Data(contentsOf: f.freeze)), actual["sha256"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.marker.path))
    }
    func testNonzeroChildIsRecordedWithoutRetry() throws {
        let f = try prepare(exitCode: 9); defer { try? FileManager.default.removeItem(at: f.root) }
        let (status, receipt) = try invoke(f)
        XCTAssertEqual(status, 9); XCTAssertEqual(receipt["childExitCode"] as? Int, 9)
        XCTAssertEqual(receipt["status"] as? String, "launched-nonzero")
        XCTAssertEqual(try String(contentsOf: f.marker, encoding: .utf8).split(separator: "\n").count, 3)
    }
}
