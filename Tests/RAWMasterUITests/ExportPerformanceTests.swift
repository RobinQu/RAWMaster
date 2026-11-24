import Darwin
import Foundation
import ImageIO
import XCTest
@testable import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

/// Runs against the same files used by the comparator clients. The fixture imports are untimed.
final class ExportPerformanceTests: XCTestCase {
    private final class Milestones: @unchecked Sendable {
        private let start = DispatchTime.now().uptimeNanoseconds
        private let lock = NSLock()
        private var first: Double?

        var seconds: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000 }
        var firstPhoto: Double? { lock.withLock { first } }

        func receive(_ count: Int) {
            guard count > 0 else { return }
            lock.withLock { if first == nil { first = seconds } }
        }
    }

    @MainActor func testRealWorkbenchBenchmarks() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let location = environment["RAWMASTER_EXPORT_BENCH_ROOT"] else {
            throw XCTSkip("Set RAWMASTER_EXPORT_BENCH_ROOT to run the shared performance dataset.")
        }
        let directory = URL(fileURLWithPath: location, isDirectory: true)
        let repeatCount = Int(environment["RAWMASTER_EXPORT_BENCH_REPEATS"] ?? "") ?? 3
        let fixture = try AppModelTests.Fixture()
        defer { fixture.clean() }

        for kind in ["jpeg-source", "raw-source"] {
            let folder = directory.appendingPathComponent(kind, isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            if files.isEmpty { continue }
            _ = try await ImportService(store: fixture.store).importDirectory(source: folder, destination: nil,
                projectName: kind, mode: .reference, progress: { _ in })
        }
        #if canImport(RAWMasterLibrary)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
            editingPreviewBackend: PhotosDevelopmentBackend(), usesPagedLibrary: true)
        let deadline = Date().addingTimeInterval(30)
        while model.scopedAssets.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #else
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: PhotosDevelopmentBackend())
        #endif
        model.openProjectExport()
        let openedBy = Date().addingTimeInterval(30)
        while !model.exportWorkspacePresented && Date() < openedBy {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.exportWorkspacePresented, model.errorMessage ?? "Export workbench did not open")
        let candidates = model.workbenchExportCandidates
        #if canImport(RAWMasterLibrary)
        XCTAssertTrue(model.isPagedGrid)
        let mounted = Set(model.scopedAssets.map(\.id))
        XCTAssertGreaterThan(candidates.count, mounted.count)
        let offPage = try XCTUnwrap(candidates.first { !mounted.contains($0.id) })
        let offPagePreview = try await model.workbenchExportPreview(for: offPage, maxPixel: 320)
        XCTAssertGreaterThan(offPagePreview.image.width, 0)
        #endif
        var result: [String: [[String: Any]]] = [:]
        let file = directory.appendingPathComponent("rawmaster/results.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let configuration = PhotoBatchExportConfiguration(format: .jpeg8, maximumLongEdge: 2048, jpegQuality: 0.9)
        for (kind, count) in [("jpeg-source", 1), ("jpeg-source", 20), ("jpeg-source", 200), ("raw-source", 1), ("raw-source", 20)] {
            let key = "\(kind)/\(count)"
            let ext = kind == "raw-source" ? ".dng" : ".jpg"
            let photos = Array(candidates.filter { $0.filename.lowercased().hasSuffix(ext) }
                .sorted { $0.filename < $1.filename }.prefix(count))
            guard photos.count == count else {
                XCTFail("Only \(photos.count) of \(count) inputs admitted for \(key)")
                result[key] = [["error": "Only \(photos.count) of \(count) inputs admitted"]]
                continue
            }
            let ids = photos.map(\.id)
            var trials: [[String: Any]] = []
            for index in -1 ..< repeatCount {
                let target = file.deletingLastPathComponent().appendingPathComponent("\(kind)-\(count)-\(UUID().uuidString)")
                let timer = Milestones()
                do {
                    let output = try await model.exportWorkbenchPhotos(directory: target, namingTemplate: "{name}",
                        configuration: configuration, includedIDs: Set(ids)) { completed, _, _ in timer.receive(completed) }
                    let time = timer.seconds
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    var bytes = 0
                    var width = 0
                    var height = 0
                    var tagged = true
                    for url in output {
                        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                        width = image.width
                        height = image.height
                        tagged = tagged && image.colorSpace?.copyICCData() != nil
                        bytes += (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    }
                    XCTAssertEqual(output.count, count)
                    XCTAssertEqual(width, 2048)
                    XCTAssertTrue(tagged)
                    let row: [String: Any] = ["seconds": time, "firstPhotoSeconds": timer.firstPhoto ?? time,
                        "bytes": bytes, "count": output.count, "dimensionsAndICC": [[width, height, tagged]],
                        "processMaxRSSKiB": usage.ru_maxrss / 1024, "container": "files"]
                    print("rawmaster \(key) \(index) \(row)")
                    if index >= 0 { trials.append(row) }
                } catch {
                    XCTFail("\(key) export failed: \(error.localizedDescription)")
                    trials.append(["error": error.localizedDescription])
                    break
                }
            }
            result[key] = trials
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
        }
        await model.editing?.shutdown()
        if environment["RAWMASTER_EXPORT_BENCH_RECEIPTS"] == "1" {
            // Preserve the finished run for independent receipt-to-file comparison after all clocks stop.
            let snapshot = directory.appending(path: "rawmaster/receipts.sqlite")
            try fixture.store.locked { try fixture.store.statement("VACUUM INTO ?", [snapshot.path]) }
        }
    }
}
