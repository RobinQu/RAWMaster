import XCTest
import AppKit
import Darwin
@testable import RAWMasterImaging

private final class IsolationDrawClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanos: UInt64 = 0
    func reset() { lock.lock(); nanos = 0; lock.unlock() }
    func add(_ value: UInt64) { lock.lock(); nanos += value; lock.unlock() }
    var milliseconds: Double { lock.lock(); defer { lock.unlock() }; return Double(nanos) / 1_000_000 }
}
private final class IsolationTimedImage: NSImage, @unchecked Sendable {
    let clock = IsolationDrawClock()
    override func draw(in rect: NSRect, from source: NSRect, operation: NSCompositingOperation,
                       fraction: CGFloat, respectFlipped: Bool, hints: [NSImageRep.HintKey: Any]?) {
        let start = DispatchTime.now().uptimeNanoseconds
        super.draw(in: rect, from: source, operation: operation, fraction: fraction,
                   respectFlipped: respectFlipped, hints: hints)
        clock.add(DispatchTime.now().uptimeNanoseconds - start)
    }
}
/// Test-only copy of the pre-theme drawing path. Never shipped by the application.
private final class LegacyStaticCanvas: NSView {
    var image: NSImage?
    var transform = ImageTransform()
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.clip()
        NSColor(calibratedWhite: 0.065, alpha: 1).setFill(); bounds.fill()
        guard let image else { return }
        let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        let pixels = CGSize(width: rep?.pixelsWide ?? 0, height: rep?.pixelsHigh ?? 0)
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let scale = ImageViewportGeometry.pointScale(pixelSize: pixels, viewport: bounds.size,
                                                      transform: transform, backingScale: backing)
        NSGraphicsContext.current?.imageInterpolation = abs(scale * backing - 1) < 0.001 ? .none : .high
        let rect = ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: bounds.size,
                                                    transform: transform, backingScale: backing)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

final class CanvasIsolationTests: XCTestCase {
    struct Sample {
        var phase: String; var round: Int; var index: Int; var position: Int; var variant: String
        var milliseconds: Double; var updateMilliseconds: Double; var imageMilliseconds: Double
        var contextCreateMilliseconds: Double; var flushMilliseconds: Double
        var json: [String: Any] {
            ["phase": phase, "round": round, "index": index, "position": position, "variant": variant,
             "milliseconds": milliseconds, "updateMilliseconds": updateMilliseconds,
             "imageDrawMilliseconds": imageMilliseconds,
             "contextCreateMilliseconds": contextCreateMilliseconds, "flushMilliseconds": flushMilliseconds,
             "otherMilliseconds": milliseconds - imageMilliseconds,
             "remainingWrapperMilliseconds": milliseconds - imageMilliseconds - updateMilliseconds - contextCreateMilliseconds - flushMilliseconds]
        }
    }
    @MainActor
    func testOptInPairedCanvasBackgroundIsolation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RAWMASTER_RUN_CANVAS_AB"] == "1" else {
            throw XCTSkip("Opt-in paired background isolation; does not change performance gates")
        }
        #if DEBUG
        XCTFail("Canvas isolation requires a release build"); return
        #else
        _ = NSApplication.shared
        let environmentBefore = processEvidence()
        let source = URL(fileURLWithPath: try XCTUnwrap(env["RAWMASTER_CANVAS_AB_SOURCE"]))
        let output = URL(fileURLWithPath: try XCTUnwrap(env["RAWMASTER_CANVAS_AB_REPORT"]))
        let decoded = try await ImagePipeline().detail(at: source)
        let image = IsolationTimedImage(size: decoded.size)
        for representation in decoded.representations { image.addRepresentation(representation) }
        let size = NSSize(width: 600, height: 720)
        let legacy = (0..<4).map { _ in LegacyStaticCanvas(frame: NSRect(origin: .zero, size: size)) }
        let variants = ["legacy_static_dark", "cached_control_dynamic", "cached_same_dark", "cached_light"]
        let colors: [String: NSColor] = ["cached_control_dynamic": .controlBackgroundColor,
            "cached_same_dark": NSColor(calibratedWhite: 0.065, alpha: 1),
            "cached_light": NSColor(calibratedWhite: 0.94, alpha: 1)]
        let modern = Dictionary(uniqueKeysWithValues: variants.dropFirst().map { name in
            (name, (0..<4).map { _ in ImageCanvas(frame: NSRect(origin: .zero, size: size)) })
        })
        let bitmaps = Dictionary(uniqueKeysWithValues: variants.map { name in
            (name, (0..<4).map { _ in NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: 600, pixelsHigh: 720, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)! })
        })
        let appearance = NSApplication.shared.effectiveAppearance
        var colorEvidence: [String: Any] = [:]
        appearance.performAsCurrentDrawingAppearance {
            for (name, color) in colors.merging(["legacy_static_dark": NSColor(calibratedWhite: 0.065, alpha: 1)], uniquingKeysWith: { a, _ in a }) {
                let rgb = color.usingColorSpace(.deviceRGB)!
                colorEvidence[name] = ["r": rgb.redComponent, "g": rgb.greenComponent,
                    "b": rgb.blueComponent, "alpha": rgb.alphaComponent,
                    "space": String(describing: rgb.colorSpace)]
            }
        }
        var samples: [Sample] = []
        func run(phase: String, round: Int, count: Int) {
            for index in 0..<count {
                let transform = ImageTransform(centerX: 0.4 + CGFloat(index % 5) * 0.03,
                    centerY: 0.5, physicalMagnification: 1 + CGFloat(index % 4) * 0.1)
                let rotation = (round + index + 8) % variants.count
                let order = Array(variants[rotation...]) + Array(variants[..<rotation])
                for (position, name) in order.enumerated() {
                    image.clock.reset()
                    let start = DispatchTime.now().uptimeNanoseconds
                    var updateNanos: UInt64 = 0, contextCreateNanos: UInt64 = 0, flushNanos: UInt64 = 0
                    for pane in 0..<4 {
                        let updateStart = DispatchTime.now().uptimeNanoseconds
                        let canvas: NSView
                        if name == "legacy_static_dark" {
                            legacy[pane].image = image; legacy[pane].transform = transform; canvas = legacy[pane]
                        } else {
                            let view = modern[name]![pane]
                            view.update(image: image, actualPixels: false, transform: transform, backgroundColor: colors[name]!)
                            canvas = view
                        }
                        updateNanos += DispatchTime.now().uptimeNanoseconds - updateStart
                        NSGraphicsContext.saveGraphicsState()
                        let createStart = DispatchTime.now().uptimeNanoseconds
                        let context = NSGraphicsContext(bitmapImageRep: bitmaps[name]![pane])
                        contextCreateNanos += DispatchTime.now().uptimeNanoseconds - createStart
                        NSGraphicsContext.current = context
                        canvas.draw(canvas.bounds)
                        let flushStart = DispatchTime.now().uptimeNanoseconds
                        NSGraphicsContext.current?.flushGraphics()
                        flushNanos += DispatchTime.now().uptimeNanoseconds - flushStart
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    samples.append(Sample(phase: phase, round: round, index: index, position: position, variant: name,
                        milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                        updateMilliseconds: Double(updateNanos) / 1_000_000,
                        imageMilliseconds: image.clock.milliseconds,
                        contextCreateMilliseconds: Double(contextCreateNanos) / 1_000_000,
                        flushMilliseconds: Double(flushNanos) / 1_000_000))
                }
            }
        }
        run(phase: "initial", round: -1, count: 10)
        run(phase: "warmup", round: 0, count: 20)
        for round in 1...6 { run(phase: "paired-measured", round: round, count: 30) }
        var summary: [String: Any] = [:]
        for name in variants {
            let measured = samples.filter { $0.phase == "paired-measured" && $0.variant == name }
            let legacyPairs = samples.filter { $0.phase == "paired-measured" && $0.variant == "legacy_static_dark" }
            var deltas: [Double] = []
            for sample in measured {
                if let baseline = legacyPairs.first(where: { $0.round == sample.round && $0.index == sample.index }) {
                    deltas.append(sample.milliseconds - baseline.milliseconds)
                }
            }
            var rounds: [[String: Any]] = []
            for round in 1...6 {
                rounds.append(["round": round, "statistics": stats(measured.filter { $0.round == round }.map(\.milliseconds))])
            }
            summary[name] = ["total": stats(measured.map(\.milliseconds)),
                "imageDraw": stats(measured.map(\.imageMilliseconds)),
                "update": stats(measured.map(\.updateMilliseconds)),
                "contextCreate": stats(measured.map(\.contextCreateMilliseconds)),
                "flush": stats(measured.map(\.flushMilliseconds)),
                "remainingWrapper": stats(measured.map { $0.milliseconds - $0.updateMilliseconds - $0.imageMilliseconds - $0.contextCreateMilliseconds - $0.flushMilliseconds }),
                "other": stats(measured.map { $0.milliseconds - $0.imageMilliseconds }),
                "pairedDifferenceFromLegacy": stats(deltas), "rounds": rounds,
                "initial": stats(samples.filter { $0.phase == "initial" && $0.variant == name }.map(\.milliseconds))]
        }
        let report: [String: Any] = ["schemaVersion": 1, "status": "diagnostic-complete",
            "date": ISO8601DateFormatter().string(from: Date()),
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "processors": ProcessInfo.processInfo.processorCount,
            "physicalMemory": ProcessInfo.processInfo.physicalMemory,
            "appearance": appearance.name.rawValue,
            "environmentBefore": environmentBefore, "environmentAfter": processEvidence(),
            "fixture": source.lastPathComponent,
            "imageDimensions": [image.representations.first?.pixelsWide ?? 0, image.representations.first?.pixelsHigh ?? 0],
            "viewportPoints": [600, 720], "paneCount": 4,
            "colors": colorEvidence,
            "boundary": "Same process, image instance, 4-pane geometry and 30 transforms; variant order rotates per pair. Update+offscreen draw+flush. Timed NSImage subclass shares original bitmap representation; image.draw component is diagnostic only. Initial and warmup excluded from measured statistics; existing gates unchanged.",
            "samples": samples.map(\.json), "summary": summary]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        for name in variants { print("CANVAS_AB \(name) \(summary[name]!)") }
        XCTAssertEqual(samples.filter { $0.phase == "paired-measured" }.count, 720)
        XCTAssertTrue(samples.allSatisfy { $0.milliseconds.isFinite && $0.milliseconds > 0 })
        print("CANVAS_AB_REPORT \(output.path)")
        #endif
    }
    @MainActor
    private func processEvidence() -> [String: Any] {
        let info = ProcessInfo.processInfo
        var usage = rusage()
        let usageStatus = getrusage(RUSAGE_SELF, &usage)
        var result: [String: Any] = ["thermalState": info.thermalState.rawValue,
            "lowPowerMode": info.isLowPowerModeEnabled,
            "threadQualityOfService": Thread.current.qualityOfService.rawValue,
            "taskPriority": Task.currentPriority.rawValue,
            "isMainThread": Thread.isMainThread,
            "nice": getpriority(PRIO_PROCESS, 0), "systemUptime": info.systemUptime]
        if usageStatus == 0 {
            result["userCPUSeconds"] = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            result["systemCPUSeconds"] = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            result["minorPageFaults"] = usage.ru_minflt; result["majorPageFaults"] = usage.ru_majflt
            result["maxResidentSize"] = usage.ru_maxrss
            result["voluntaryContextSwitches"] = usage.ru_nvcsw; result["involuntaryContextSwitches"] = usage.ru_nivcsw
        }
        return result
    }
    private func stats(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return ["count": 0] }
        func percentile(_ fraction: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        return ["count": values.count, "p50Milliseconds": percentile(0.5),
                "p95Milliseconds": percentile(0.95), "maxMilliseconds": sorted.last!, "minMilliseconds": sorted.first!]
    }
}
