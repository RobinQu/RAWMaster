import XCTest
import AppKit
import ImageIO
import Darwin
@testable import RAWMasterImaging

/// Opt in with RAWMASTER_RUN_IMAGE_PERF=1 in a release build. This measures the
/// shipped decode pipeline and offscreen raster drawing, never display presentation.
final class ImagePerformanceTests: XCTestCase {
    struct Observation: Encodable {
        var milliseconds: Double
        var fixture: String?
        var result: String
        var width: Int?
        var height: Int?
    }
    struct Metric: Encodable {
        var name: String
        var boundary: String
        var cache: String
        var samples: [Observation]
        var count: Int { samples.count }
        var p50Milliseconds: Double { percentile(0.5) }
        var p95Milliseconds: Double { percentile(0.95) }
        var maxMilliseconds: Double { samples.map(\.milliseconds).max() ?? 0 }
        private func percentile(_ value: Double) -> Double {
            let ordered = samples.map(\.milliseconds).sorted()
            guard !ordered.isEmpty else { return 0 }
            return ordered[min(ordered.count - 1, max(0, Int(ceil(Double(ordered.count) * value)) - 1))]
        }
        enum CodingKeys: String, CodingKey { case name, boundary, cache, samples, count, p50Milliseconds, p95Milliseconds, maxMilliseconds }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(name, forKey: .name); try values.encode(boundary, forKey: .boundary)
            try values.encode(cache, forKey: .cache); try values.encode(samples, forKey: .samples)
            try values.encode(count, forKey: .count); try values.encode(p50Milliseconds, forKey: .p50Milliseconds)
            try values.encode(p95Milliseconds, forKey: .p95Milliseconds); try values.encode(maxMilliseconds, forKey: .maxMilliseconds)
        }
    }
    struct Gate: Encodable {
        var metric: String
        var p95LimitMilliseconds: Double
        var maxLimitMilliseconds: Double
        var baselineP95Milliseconds: Double?
        var relativeP95LimitMilliseconds: Double?
        var passed: Bool
    }
    struct Fixture: Encodable { var filename: String; var bytes: Int; var metadataWidth: Int; var metadataHeight: Int; var orientation: Int }
    struct Report: Encodable {
        var schemaVersion = 1
        var phase: String
        var timestamp: Date
        var status = "failed"
        var failure: String?
        var build = "release"
        var hardwareModel: String
        var cpu: String
        var physicalMemory: UInt64
        var processors: Int
        var operatingSystem: String
        var boundaries: [String]
        var fixtures: [Fixture]
        var metrics: [Metric] = []
        var cancellation: [String: Int] = [:]
        var timingGatesEnabled = false
        var gates: [Gate] = []
    }
    private static func machineValue(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unavailable" }
        return String(cString: buffer)
    }
    private func dimensions(_ image: NSImage) -> (Int, Int) {
        (image.representations.first?.pixelsWide ?? 0, image.representations.first?.pixelsHigh ?? 0)
    }
    private func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    private func samples(at root: URL, count: Int) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw NSError(domain: "ImagePerformance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Required real RAW source is missing"])
        }
        if !isDirectory.boolValue { return [root] }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { ["arw", "dng", "nef", "cr3", "cr2", "raf"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Array(files.prefix(count))
    }
    func testOptInReleasePipelineAndCanvasPerformance() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RAWMASTER_RUN_IMAGE_PERF"] == "1" else {
            throw XCTSkip("Opt-in real RAW release suite; run the documented performance launcher to require it")
        }
        #if DEBUG
        XCTFail("Real RAW performance suite requires swift test -c release")
        return
        #else
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(env["RAWMASTER_IMAGE_PERF_REPORT"], "Explicit output report path is required"))
        let root = URL(fileURLWithPath: try XCTUnwrap(env["RAWMASTER_IMAGE_PERF_SOURCE"], "Real RAW source is required; requested runs must not silently skip"))
        let urls = try samples(at: root, count: max(4, Int(env["RAWMASTER_IMAGE_PERF_COUNT"] ?? "15") ?? 15))
        XCTAssertGreaterThanOrEqual(urls.count, 4, "At least four distinct real RAW files are required for compare regression")
        guard urls.count >= 4 else { return }
        let fixtures = try urls.map { url -> Fixture in
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            return Fixture(filename: url.lastPathComponent, bytes: try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                metadataWidth: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                metadataHeight: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
                orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1)
        }
        var report = Report(phase: env["RAWMASTER_PERF_PHASE"] ?? "after", timestamp: Date(),
            hardwareModel: Self.machineValue("hw.model"), cpu: Self.machineValue("machdep.cpu.brand_string"),
            physicalMemory: ProcessInfo.processInfo.physicalMemory, processors: ProcessInfo.processInfo.processorCount,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            boundaries: [
                "Monotonic in-process request start to decoded NSImage return; includes actor queue, stat, image decoding and materialization.",
                "Cold means cleared application image caches and Core Image context caches. Filesystem cache and OS RAW resources are uncontrolled; not disk-cold.",
                "Warm means a populated application cache. No UI frame presentation or pointer-to-visible latency is measured here.",
                "Canvas metrics are synchronous offscreen bitmap raster draws after state update, not window-server presentation.",
                "Real RAW samples are read-only. Reports contain basenames and metadata, not source directory paths. Setup/fixture enumeration excluded."
            ], fixtures: fixtures)
        defer {
            do {
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(report).write(to: reportURL, options: .atomic)
                print("IMAGE_PERFORMANCE_REPORT \(reportURL.path)")
            } catch { XCTFail("Could not write required performance evidence: \(error)") }
        }
        do {
            let pipeline = ImagePipeline()
            var coldPreview = Metric(name: "embedded_preview_app_cache_cold", boundary: "request→decoded preview bitmap", cache: "application-cold; filesystem-uncontrolled", samples: [])
            var coldDetail = Metric(name: "true_raw_app_cache_cold", boundary: "request→materialized native RAW bitmap", cache: "application-cold; filesystem-uncontrolled", samples: [])
            for _ in 0..<2 {
                for (index, url) in urls.enumerated() {
                    await pipeline.clearCaches()
                    var start = DispatchTime.now().uptimeNanoseconds
                    let preview = try await pipeline.preview(at: url, maxPixel: 600)
                    let previewMs = elapsed(start), previewSize = dimensions(preview)
                    XCTAssertLessThanOrEqual(max(previewSize.0, previewSize.1), 600)
                    coldPreview.samples.append(.init(milliseconds: previewMs, fixture: url.lastPathComponent, result: "decoded", width: previewSize.0, height: previewSize.1))
                    await pipeline.clearCaches()
                    start = DispatchTime.now().uptimeNanoseconds
                    let detail = try await pipeline.detail(at: url)
                    let detailMs = elapsed(start), detailSize = dimensions(detail)
                    let expected = [fixtures[index].metadataWidth, fixtures[index].metadataHeight].sorted()
                    XCTAssertEqual([detailSize.0, detailSize.1].sorted(), expected, "Detail must retain native RAW pixel dimensions")
                    coldDetail.samples.append(.init(milliseconds: detailMs, fixture: url.lastPathComponent, result: "decoded-native-raw", width: detailSize.0, height: detailSize.1))
                }
            }
            XCTAssertGreaterThanOrEqual(coldPreview.count, 30, "Required performance run must contain at least 30 application-cold preview samples")
            XCTAssertGreaterThanOrEqual(coldDetail.count, 30, "Required performance run must contain at least 30 native RAW samples")
            report.metrics += [coldPreview, coldDetail]
            var warmPreview = Metric(name: "embedded_preview_warm_cache", boundary: "request→same cached preview bitmap", cache: "application-warm", samples: [])
            let warm = try await pipeline.preview(at: urls[0], maxPixel: 600)
            for _ in 0..<100 {
                let start = DispatchTime.now().uptimeNanoseconds
                let image = try await pipeline.preview(at: urls[0], maxPixel: 600)
                let milliseconds = elapsed(start)
                XCTAssertTrue(image === warm)
                warmPreview.samples.append(.init(milliseconds: milliseconds, fixture: urls[0].lastPathComponent, result: "cache-hit"))
            }
            var warmDetail = Metric(name: "true_raw_warm_cache", boundary: "request→same cached native RAW bitmap", cache: "application-warm", samples: [])
            let warmRAW = try await pipeline.detail(at: urls[0])
            for _ in 0..<50 {
                let start = DispatchTime.now().uptimeNanoseconds
                let image = try await pipeline.detail(at: urls[0])
                let milliseconds = elapsed(start)
                XCTAssertTrue(image === warmRAW)
                warmDetail.samples.append(.init(milliseconds: milliseconds, fixture: urls[0].lastPathComponent, result: "cache-hit"))
            }
            report.metrics += [warmPreview, warmDetail]
            for paneCount in 2...4 {
                var compare = Metric(name: "compare_\(paneCount)_native_raw", boundary: "parallel requests→all native RAW results (detail decoder serialized)", cache: "application-cold; filesystem-uncontrolled", samples: [])
                for _ in 0..<3 {
                    await pipeline.clearCaches()
                    let start = DispatchTime.now().uptimeNanoseconds
                    let count = try await withThrowingTaskGroup(of: Int.self) { group in
                        for url in urls.prefix(paneCount) { group.addTask { _ = try await pipeline.detail(at: url); return 1 } }
                        var count = 0
                        for try await value in group { count += value }
                        return count
                    }
                    XCTAssertEqual(count, paneCount)
                    compare.samples.append(.init(milliseconds: elapsed(start), result: "\(count)-panes-decoded"))
                }
                report.metrics.append(compare)
            }
            var navigation = Metric(name: "sequential_preview_navigation", boundary: "request→decoded preview per next distinct asset", cache: "application-cold at start of sequence", samples: [])
            await pipeline.clearCaches()
            for url in urls {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try await pipeline.preview(at: url, maxPixel: 600)
                navigation.samples.append(.init(milliseconds: elapsed(start), fixture: url.lastPathComponent, result: "decoded"))
            }
            report.metrics.append(navigation)
            await pipeline.clearCaches()
            let burstStart = DispatchTime.now().uptimeNanoseconds
            let burst = (0..<24).map { index in Task { try await pipeline.preview(at: urls[index % urls.count], maxPixel: 600) } }
            try await Task.sleep(for: .milliseconds(5))
            for task in burst.dropLast() { task.cancel() }
            var completed = 0, cancelled = 0
            for (index, task) in burst.enumerated() {
                do {
                    _ = try await task.value; completed += 1
                } catch is CancellationError {
                    cancelled += 1
                    XCTAssertNotEqual(index, burst.count - 1, "Final focused image was cancelled")
                }
            }
            XCTAssertEqual(completed + cancelled, burst.count)
            XCTAssertGreaterThan(completed, 0)
            XCTAssertGreaterThan(cancelled, 0)
            report.cancellation = ["requested": burst.count, "completed": completed, "cancelled": cancelled]
            report.metrics.append(Metric(name: "rapid_navigation_cancel_burst", boundary: "24 request enqueue→all returns, cancel first23 after5ms", cache: "application-cold; filesystem-uncontrolled", samples: [.init(milliseconds: elapsed(burstStart), result: "latest-completed")]))
            report.metrics += try await canvasMetrics(image: warmRAW)
            XCTAssertTrue(report.metrics.allSatisfy { !$0.samples.isEmpty && $0.samples.allSatisfy { $0.milliseconds.isFinite && $0.milliseconds >= 0 } })
            try enforceGates(report: &report, baselinePath: env["RAWMASTER_IMAGE_PERF_BASELINE"])
            guard (testRun?.failureCount ?? 0) == 0 else {
                throw NSError(domain: "ImagePerformance", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Functional assertions failed; timing observations cannot count as a passing run"])
            }
            report.status = "passed"
            for metric in report.metrics {
                print("IMAGE_PERF \(metric.name) count=\(metric.count) p50_ms=\(metric.p50Milliseconds) p95_ms=\(metric.p95Milliseconds) max_ms=\(metric.maxMilliseconds)")
            }
        } catch {
            report.failure = String(describing: error)
            throw error
        }
        #endif
    }
    private func syntheticReport(milliseconds: Double) -> Report {
        var report = Report(phase: "after", timestamp: Date(), hardwareModel: "test-machine", cpu: "test-cpu",
            physicalMemory: 1024, processors: 1, operatingSystem: "test-os", boundaries: [], fixtures: [])
        report.metrics = [Metric(name: "embedded_preview_warm_cache", boundary: "synthetic gate verification",
            cache: "synthetic", samples: [.init(milliseconds: milliseconds, result: "test")])]
        return report
    }
    func testDeclaredAbsoluteGateRejectsWarmCacheRegression() throws {
        var report = syntheticReport(milliseconds: 20)
        XCTAssertThrowsError(try enforceGates(report: &report, baselinePath: nil))
        XCTAssertEqual(report.status, "failed")
        XCTAssertEqual(report.gates.first?.passed, false)
        XCTAssertEqual(report.gates.first?.p95LimitMilliseconds, 5)
    }
    func testBlankRelativeBaselineMeansAbsoluteGatesOnly() throws {
        var report = syntheticReport(milliseconds: 0.1)
        XCTAssertNoThrow(try enforceGates(report: &report, baselinePath: ""))
        XCTAssertTrue(report.timingGatesEnabled)
        XCTAssertEqual(report.gates.first?.passed, true)
        XCTAssertNil(report.gates.first?.relativeP95LimitMilliseconds)
    }
    func testRelativeGateRejectsRegressionWithinAbsoluteBudget() throws {
        var baseline = syntheticReport(milliseconds: 0.1)
        baseline.status = "passed"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterPerfBaseline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(baseline).write(to: url)
        var report = syntheticReport(milliseconds: 2)
        XCTAssertThrowsError(try enforceGates(report: &report, baselinePath: url.path))
        XCTAssertEqual(report.gates.first?.relativeP95LimitMilliseconds, 1)
        XCTAssertEqual(report.gates.first?.passed, false)
        XCTAssertEqual(report.status, "failed")
    }
    private func enforceGates(report: inout Report, baselinePath: String?) throws {
        guard report.phase != "baseline" else { return }
        report.timingGatesEnabled = true
        var baselineMetrics: [String: Double] = [:]
        if let path = baselinePath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let names = (baseline["fixtures"] as? [[String: Any]] ?? []).compactMap { $0["filename"] as? String }
            guard ["completed", "passed"].contains(baseline["status"] as? String ?? ""),
                  baseline["hardwareModel"] as? String == report.hardwareModel,
                  baseline["cpu"] as? String == report.cpu,
                  baseline["physicalMemory"] as? UInt64 == report.physicalMemory,
                  baseline["operatingSystem"] as? String == report.operatingSystem,
                  baseline["build"] as? String == report.build,
                  names == report.fixtures.map(\.filename) else {
                throw NSError(domain: "ImagePerformance", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Relative baseline is incomplete or differs in machine, OS, release configuration or RAW sample selection"])
            }
            for value in baseline["metrics"] as? [[String: Any]] ?? [] {
                if let name = value["name"] as? String, let p95 = value["p95Milliseconds"] as? Double {
                    baselineMetrics[name] = p95
                }
            }
        }
        var failures: [String] = []
        for metric in report.metrics {
            let p95Limit: Double, relativeFloor: Double
            switch metric.name {
            case "embedded_preview_app_cache_cold", "sequential_preview_navigation": p95Limit = 100; relativeFloor = 50
            case "true_raw_app_cache_cold": p95Limit = 1500; relativeFloor = 1000
            case "embedded_preview_warm_cache", "true_raw_warm_cache": p95Limit = 5; relativeFloor = 1
            case "rapid_navigation_cancel_burst": p95Limit = 1000; relativeFloor = 100
            default:
                if metric.name.hasPrefix("compare_"), let count = Int(metric.name.split(separator: "_")[1]) {
                    p95Limit = Double(count) * 1500; relativeFloor = Double(count) * 750
                } else if metric.name.hasPrefix("canvas_") {
                    p95Limit = 33.333; relativeFloor = 8
                } else { throw NSError(domain: "ImagePerformance", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing timing rule for \(metric.name)"]) }
            }
            let maxLimit = metric.name.hasPrefix("canvas_") ? 100 : p95Limit * 2.5
            let baseline = baselineMetrics[metric.name]
            let relativeLimit = baseline.map { max($0 * 1.5, relativeFloor) }
            let passed = metric.p95Milliseconds <= p95Limit && metric.maxMilliseconds <= maxLimit
                && (relativeLimit.map { metric.p95Milliseconds <= $0 } ?? true)
            if !baselineMetrics.isEmpty && baseline == nil { failures.append("Baseline lacks \(metric.name)") }
            if !passed { failures.append("\(metric.name): p95=\(metric.p95Milliseconds)ms, max=\(metric.maxMilliseconds)ms exceeded declared limits") }
            report.gates.append(Gate(metric: metric.name, p95LimitMilliseconds: p95Limit,
                maxLimitMilliseconds: maxLimit, baselineP95Milliseconds: baseline,
                relativeP95LimitMilliseconds: relativeLimit, passed: passed))
        }
        if !failures.isEmpty {
            throw NSError(domain: "ImagePerformance", code: 4,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
    }
    @MainActor
    private func canvasMetrics(image: NSImage) throws -> [Metric] {
        _ = NSApplication.shared
        var results: [Metric] = []
        for paneCount in 1...4 where paneCount != 3 {
            let size = NSSize(width: paneCount == 1 ? 1200 : 600, height: 720)
            let canvases = (0..<paneCount).map { _ in ImageCanvas(frame: NSRect(origin: .zero, size: size)) }
            let bitmaps = canvases.map { _ in NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)! }
            for mode in ["fit", "zoom-pan"] {
                var metric = Metric(name: "canvas_\(paneCount)_\(mode)", boundary: "state update→completed offscreen bitmap raster drawing (not onscreen presentation)", cache: "decoded native RAW supplied; no decoding", samples: [])
                for index in 0..<30 {
                    let transform = mode == "fit" ? ImageTransform() : ImageTransform(centerX: 0.4 + CGFloat(index % 5) * 0.03, centerY: 0.5, physicalMagnification: 1 + CGFloat(index % 4) * 0.1)
                    let start = DispatchTime.now().uptimeNanoseconds
                    for (canvas, bitmap) in zip(canvases, bitmaps) {
                        canvas.update(image: image, actualPixels: false, transform: transform)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                        canvas.draw(canvas.bounds)
                        NSGraphicsContext.current?.flushGraphics()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    metric.samples.append(.init(milliseconds: elapsed(start), result: "\(paneCount)-panes-rasterized"))
                }
                results.append(metric)
            }
        }
        return results
    }
}
