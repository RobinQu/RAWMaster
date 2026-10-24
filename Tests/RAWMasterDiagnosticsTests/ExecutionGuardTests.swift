import XCTest
import Foundation
import CryptoKit

final class ExecutionGuardTests: XCTestCase {
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func runGuard(mutateSource: Bool, mutateBinary: Bool) throws -> (Int32, Bool, [String: Any]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.swift"), binary = root.appendingPathComponent("stub"), marker = root.appendingPathComponent("launched")
        let sourceData = Data("// frozen synthetic algorithm\n".utf8)
        try sourceData.write(to: source)
        let stub = Data("#!/usr/bin/python3\nimport pathlib,sys\npathlib.Path(sys.argv[1]).write_text('launched')\n".utf8)
        try stub.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        var aggregate = Data("Source.swift\0".utf8); aggregate.append(sourceData)
        let freeze: [String: Any] = ["sourceSHA256": ["Source.swift": hash(sourceData)],
            "aggregateSourceSHA256": hash(aggregate), "binarySHA256": hash(stub)]
        let freezeURL = root.appendingPathComponent("freeze.json"), receiptURL = root.appendingPathComponent("receipt.json")
        try JSONSerialization.data(withJSONObject: freeze).write(to: freezeURL)
        if mutateSource { try Data("// changed algorithm\n".utf8).write(to: source) }
        if mutateBinary { try Data((String(decoding: stub, as: UTF8.self) + "# relinked\n").utf8).write(to: binary) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [repository.appendingPathComponent("scripts/run-burst-evidence.py").path,
            "--repo", root.path, "--freeze", freezeURL.path, "--binary", binary.path, "--receipt", receiptURL.path, "--", marker.path]
        process.standardError = Pipe(); process.standardOutput = Pipe()
        try process.run(); process.waitUntilExit()
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
        return (process.terminationStatus, FileManager.default.fileExists(atPath: marker.path), receipt)
    }
    func testExecutableMismatchFailsBeforeLaunch() throws {
        let (status, launched, receipt) = try runGuard(mutateSource: false, mutateBinary: true)
        XCTAssertEqual(status, 78); XCTAssertFalse(launched)
        XCTAssertEqual(receipt["status"] as? String, "refused-before-launch")
        XCTAssertEqual(receipt["launched"] as? Bool, false)
    }
    func testSourceMismatchFailsBeforeLaunch() throws {
        let (status, launched, receipt) = try runGuard(mutateSource: true, mutateBinary: false)
        XCTAssertEqual(status, 78); XCTAssertFalse(launched)
        XCTAssertFalse((receipt["failures"] as! [String]).isEmpty)
    }
    func testMatchingFreezeLaunchesExactlyOnce() throws {
        let (status, launched, receipt) = try runGuard(mutateSource: false, mutateBinary: false)
        XCTAssertEqual(status, 0); XCTAssertTrue(launched)
        XCTAssertEqual(receipt["status"] as? String, "launched-completed")
        XCTAssertEqual(receipt["childExitCode"] as? Int, 0)
        XCTAssertEqual(receipt["executedPrivateVerifiedSnapshot"] as? Bool, true)
    }
}
