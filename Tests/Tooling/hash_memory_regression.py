#!/usr/bin/env python3
"""Fresh-process autorelease lifetime regression for the actual Swift streaming loops.

Compile the complete production FileSafety.swift and verbatim runtime hash/credential
declarations with small standalone error shims. An explicit outer autoreleasepool
models a long-lived import worker. Each mode reads 2 GiB from a bounded sparse file;
no user library or original is accessed. Output records exact source SHA-256.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def declaration(text, marker):
    start = text.index(marker)
    opening = text.index("{", text.index("throws -> String", start) if "func hash" in marker else start)
    depth = 1
    index = opening + 1
    while depth:
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
        index += 1
    return text[start:index]


PROBE = r'''
import Foundation
import CryptoKit
import Darwin

enum LibraryError: Error {
    case invalid(String), sourceChanged(String), busy, cancelled
}
enum RuntimeSequenceError: Error { case invalid(String) }
enum SequenceReadError: Error { case unreadable }

struct Memory: Codable {
    let footprint: UInt64
    let rss: UInt64
    let maximumRSS: UInt64
    static func current() -> Memory {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Memory(footprint: info.phys_footprint, rss: info.resident_size, maximumRSS: UInt64(usage.ru_maxrss))
    }
}

@main struct HashMemoryProbe {
    static func main() throws {
        let mode = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2])
        let size = 64 * 1024 * 1024
        let passes = mode == "copy" ? 16 : 32
        let source = root.appendingPathComponent("source.bin")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(size)); try file.close()
        var samples: [Memory] = [], checks = 0, digest = ""
        let started = ProcessInfo.processInfo.systemUptime
        let before = Memory.current()
        let inside: Memory = try autoreleasepool {
            let check = {
                checks += 1
                if checks % 16 == 0 { samples.append(Memory.current()) }
            }
            for index in 0..<passes {
                let value: String
                switch mode {
                case "core": value = try FileSafety.hash(source, cancel: check)
                case "runtime": value = try RuntimeSequenceTool.hash(source, check: check)
                case "copy":
                    let target = root.appendingPathComponent("copy-\(index).bin")
                    let result = try FileSafety.verifiedCopy(source: source, target: target,
                        expectedHash: digest.isEmpty ? nil : digest, protectedRoots: [source], cancel: check)
                    value = result.1
                    try FileManager.default.removeItem(at: result.0)
                default: fatalError("unknown mode")
                }
                precondition(digest.isEmpty || digest == value)
                digest = value
                samples.append(Memory.current())
            }
            // This sample is BEFORE the outer pool drains: an ambient pool must not
            // hide retained autoreleased FileHandle read buffers from the regression.
            return Memory.current()
        }
        let after = Memory.current()
        var copyCancellationCleanupVerified: Bool?
        if mode == "copy" {
            let target = root.appendingPathComponent("existing-target.bin")
            let sentinel = Data("existing target must survive".utf8)
            try sentinel.write(to: target)
            var cancellationChecks = 0, cancelled = false
            do {
                _ = try FileSafety.verifiedCopy(source: source, target: target, expectedHash: digest,
                    protectedRoots: [source], cancel: {
                        cancellationChecks += 1
                        if cancellationChecks == 3 { throw LibraryError.cancelled }
                    })
            } catch LibraryError.cancelled { cancelled = true }
            precondition(cancelled)
            let survivingTarget = try Data(contentsOf: target), survivingSourceHash = try FileSafety.hash(source)
            precondition(survivingTarget == sentinel)
            precondition(survivingSourceHash == digest)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            precondition(Set(files) == Set([source.lastPathComponent, target.lastPathComponent]))
            copyCancellationCleanupVerified = true
        }
        struct Report: Codable {
            let mode: String
            let fileBytes, passes, logicalReadBytes: Int
            let elapsedSeconds: Double
            let before, insideOuterPool, afterOuterPool: Memory
            let observedPeakFootprint, observedPeakRSS: UInt64
            let sha256: String
            let copyCancellationCleanupVerified: Bool?
        }
        let report = Report(mode: mode, fileBytes: size, passes: passes,
            logicalReadBytes: size * passes * (mode == "copy" ? 2 : 1),
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
            before: before, insideOuterPool: inside, afterOuterPool: after,
            observedPeakFootprint: samples.map(\.footprint).max() ?? 0,
            observedPeakRSS: samples.map(\.rss).max() ?? 0, sha256: digest,
            copyCancellationCleanupVerified: copyCancellationCleanupVerified)
        print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--assert-bounded", action="store_true", help="Require <128 MiB growth despite 2 GiB reads")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    core = root / "Sources/RAWMasterCore/FileSafety.swift"
    runtime = root / "Sources/RAWMasterImaging/RuntimeSequenceMetadata.swift"
    reader = root / "Sources/RAWMasterImaging/SequenceCaptureReader.swift"
    credential = declaration(reader.read_text(), "public struct SequenceFileCredential:")
    runtime_hash = declaration(runtime.read_text(), "    static func hash(_ url: URL, check:")
    reports = []
    with tempfile.TemporaryDirectory(prefix="rawmaster-hash-memory-") as temporary:
        work = Path(temporary)
        swift = work / "Probe.swift"
        swift.write_text(PROBE + "\n" + credential + "\nenum RuntimeSequenceTool {\n" + runtime_hash + "\n}\n")
        binary = work / "probe"
        subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", str(core), str(swift), "-o", str(binary)], check=True)
        for mode in ("core", "runtime", "copy"):
            mode_root = work / mode
            mode_root.mkdir()
            process = subprocess.run([str(binary), mode, str(mode_root)], check=True, capture_output=True, text=True, timeout=90)
            report = json.loads(process.stdout)
            reports.append(report)
            print(json.dumps(report, sort_keys=True), flush=True)
    result = {
        "description": "Fresh subprocess per mode; 64MiB sparse file; explicit outer autoreleasepool; 2GiB logical reads",
        "sourceSHA256": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in (core, runtime, reader)},
        "reports": reports,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    expected = hashlib.sha256()
    for _ in range(64):
        expected.update(bytes(1024 * 1024))
    assert {r["sha256"] for r in reports} == {expected.hexdigest()}, "Streaming paths produced incorrect SHA-256"
    assert next(r for r in reports if r["mode"] == "copy")["copyCancellationCleanupVerified"]
    if args.assert_bounded:
        for report in reports:
            growth = report["observedPeakFootprint"] - report["before"]["footprint"]
            assert growth < 128 * 1024 * 1024, f"{report['mode']} retained {growth} bytes"


if __name__ == "__main__":
    main()
