import AppKit
import CoreMedia
import ScreenCaptureKit
import Vision

// Stream records use big-endian host nanoseconds followed by a 96 × 64 RGB sample grid.
// Sampling is restricted to the caller's photo ROI. No other window is captured.
private enum CaptureError: Error { case arguments, missingWindow, missingField, invalidValue, windowChanged }

func hostNanoseconds() -> UInt64 {
    let clock = CMClockGetTime(CMClockGetHostTimeClock())
    return UInt64(CMTimeConvertScale(clock, timescale: 1_000_000_000, method: .default).value)
}

func ax(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func descendants(_ element: AXUIElement, role: String) -> [AXUIElement] {
    let children = ax(element, "AXChildren") as? [AXUIElement] ?? []
    return children.flatMap { child in
        (ax(child, "AXRole") as? String == role ? [child] : []) + descendants(child, role: role)
    }
}

func coordinate(_ object: CFTypeRef?, size: Bool = false) -> [CGFloat] {
    guard let object, CFGetTypeID(object) == AXValueGetTypeID() else { return [] }
    let value = object as! AXValue
    if size {
        var s = CGSize.zero
        return AXValueGetValue(value, .cgSize, &s) ? [s.width, s.height] : []
    }
    var p = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &p) ? [p.x, p.y] : []
}

final class Sampler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let roi: CGRect
    let handle: FileHandle
    var previous = Data()
    var first = true
    let queue = DispatchQueue(label: "benchmark.canvas.frames")
    init(roi: CGRect, handle: FileHandle) { self.roi = roi; self.handle = handle }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("Capture stopped: \(error)\n".utf8))
        exit(2)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let image = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image), stride = CVPixelBufferGetBytesPerRow(image)
        var pixels = Data(capacity: 96 * 64 * 3)
        for y in 0..<64 {
            let row = min(height - 1, Int((roi.minY + roi.height * (CGFloat(y) + 0.5) / 64) * CGFloat(height))) * stride
            for x in 0..<96 {
                let col = min(width - 1, Int((roi.minX + roi.width * (CGFloat(x) + 0.5) / 96) * CGFloat(width)))
                let offset = row + col * 4
                pixels.append(base[offset + 2]); pixels.append(base[offset + 1]); pixels.append(base[offset])
            }
        }
        guard first || pixels != previous else { return }
        previous = pixels
        var pts = UInt64(CMTimeConvertScale(sample.presentationTimeStamp, timescale: 1_000_000_000, method: .default).value).bigEndian
        withUnsafeBytes(of: &pts) { handle.write(Data($0)) }
        handle.write(pixels)
        if first { first = false; print("READY"); fflush(stdout) }
    }
}

@main
enum CaptureCanvas {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Canvas benchmark: \(error)\n".utf8)); exit(1)
        }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { throw CaptureError.arguments }
        let app = args[1]
        if args[0] == "activate" {
            guard args.count == 3,
                  let application = NSRunningApplication.runningApplications(withBundleIdentifier: app).first(where: { app in
                    (ax(AXUIElementCreateApplication(app.processIdentifier), "AXWindows") as? [AXUIElement])?.contains(where: {
                        ax($0, "AXTitle") as? String == args[2] }) == true
                  }), application.activate(options: []) else { throw CaptureError.missingWindow }
            for _ in 0..<20 where !application.isActive { try await Task.sleep(for: .milliseconds(50)) }
            guard application.isActive else { throw CaptureError.windowChanged }
            print("true"); return
        }
        if args[0] == "fields" {
            guard args.count == 5, let appPID = NSRunningApplication.runningApplications(withBundleIdentifier: app).first(where: { $0.isActive })?.processIdentifier,
                  let window = (ax(AXUIElementCreateApplication(appPID), "AXWindows") as? [AXUIElement])?.first(where: { ax($0, "AXTitle") as? String == args[2] })
                else { throw CaptureError.missingWindow }
            let origin = coordinate(ax(window, "AXPosition")), size = coordinate(ax(window, "AXSize"), size: true)
            guard size.count == 2, origin.count == 2 else { throw CaptureError.windowChanged }
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.usesLanguageCorrection = false
            try VNImageRequestHandler(url: URL(fileURLWithPath: args[4])).perform([recognition])
            let words: [[String: Any]] = (recognition.results ?? []).compactMap { obs in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                return ["text": text, "x": obs.boundingBox.midX * size[0], "y": (1 - obs.boundingBox.midY) * size[1]]
            }
            let fields: [[String: Any]] = descendants(window, role: args[3]).enumerated().compactMap { index, field in
                let pos = coordinate(ax(field, "AXPosition")), wh = coordinate(ax(field, "AXSize"), size: true)
                guard pos.count == 2, wh.count == 2 else { return nil }
                let x = pos[0] - origin[0], y = pos[1] - origin[1] + wh[1] / 2
                let left = words.filter { word in
                    guard let wordX = word["x"] as? CGFloat, let wordY = word["y"] as? CGFloat else { return false }
                    return abs(wordY - y) < 9 && (24...245).contains(x - wordX)
                }
                return ["index": index, "labelCandidates": left.compactMap { $0["text"] as? String },
                    "identifier": ax(field, "AXIdentifier") as? String ?? "", "position": pos,
                    "value": ax(field, "AXValue").map { String(describing: $0) } ?? ""]
            }
            let result: [String: Any] = ["fields": fields, "words": words]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result)); return
        }
        if ["set", "type", "click-value"].contains(args[0]) {
            let operation = args[0]
            guard args.count == (operation == "click-value" ? 7 : 6),
                  let appPID = NSRunningApplication.runningApplications(withBundleIdentifier: app).first(where: { $0.isActive })?.processIdentifier,
                  let windows = ax(AXUIElementCreateApplication(appPID), "AXWindows") as? [AXUIElement],
                  let window = windows.first(where: { ax($0, "AXTitle") as? String == args[2] }),
                  let index = Int(args[4]) else { throw CaptureError.missingWindow }
            // Camera Raw still exposes all of its parent's fields beneath a modal alert.
            // Physical typing in that state would go to the alert instead of the recorded control.
            if let front = windows.first, !CFEqual(front, window),
               (ax(front, "AXModal") as? Bool == true || ax(front, "AXTitle") as? String == "Camera Raw") {
                throw CaptureError.windowChanged
            }
            let fields = descendants(window, role: args[3])
            guard fields.indices.contains(index) else { throw CaptureError.missingField }
            let field = fields[index]
            let initial = ax(field, "AXValue").map { String(describing: $0) } ?? ""
            let sent: UInt64
            if operation == "click-value" {
                let origin = coordinate(ax(window, "AXPosition")), size = coordinate(ax(window, "AXSize"), size: true)
                let fieldPosition = coordinate(ax(field, "AXPosition"))
                guard args[3] == "AXTextField", origin.count == 2, size.count == 2, fieldPosition.count == 2,
                      let x = Double(args[5]), let y = Double(args[6]), x.isFinite, y.isFinite,
                      x >= 0, y >= 0, x < size[0], y < size[1] else { throw CaptureError.invalidValue }
                let point = CGPoint(x: origin[0] + x, y: origin[1] + y)
                guard (0...250).contains(fieldPosition[0] - point.x), (0...45).contains(point.y - fieldPosition[1]),
                      let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                else { throw CaptureError.invalidValue }
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(20_000)
                sent = hostNanoseconds()
                down.post(tap: .cghidEventTap)
                usleep(20_000)
                up.post(tap: .cghidEventTap)
                usleep(35_000)
            } else if operation == "type" {
                let digits: [Character:CGKeyCode] = ["0":29,"1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"-":27,".":47,"+":24]
                let keys = args[5].compactMap { digits[$0] }
                let position = coordinate(ax(field,"AXPosition")), size = coordinate(ax(field,"AXSize"),size:true)
                guard args[3] == "AXTextField", Double(args[5]) != nil, keys.count == args[5].count,
                      position.count == 2, size.count == 2 else { throw CaptureError.invalidValue }
                let center = CGPoint(x:position[0]+size[0]/2,y:position[1]+size[1]/2)
                func key(_ code:CGKeyCode, flags:CGEventFlags = []) {
                    for down in [true,false] {
                        let event = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)
                        event?.flags = flags
                        event?.post(tap:.cghidEventTap)
                    }
                }
                for kind in [CGEventType.leftMouseDown,.leftMouseUp] {
                    CGEvent(mouseEventSource:nil,mouseType:kind,mouseCursorPosition:center,mouseButton:.left)?.post(tap:.cghidEventTap)
                }
                usleep(15_000)
                key(0,flags:.maskCommand)
                usleep(8_000)
                sent = hostNanoseconds()
                for (character,code) in zip(args[5],keys) {
                    if character == "." {
                        var decimal: UniChar = 46
                        for down in [true,false] {
                            let event = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)
                            event?.keyboardSetUnicodeString(stringLength:1,unicodeString:&decimal)
                            event?.post(tap:.cghidEventTap)
                        }
                    } else { key(code) }
                    usleep(9_000)
                }
                key(48)
                usleep(35_000)
            } else {
                let value: CFTypeRef
                if args[3] == "AXSlider", let number = Double(args[5]) { value = NSNumber(value: number) }
                else { value = args[5] as CFString }
                sent = hostNanoseconds()
                guard AXUIElementSetAttributeValue(field, "AXValue" as CFString, value) == .success else { throw CaptureError.invalidValue }
            }
            let actual = ax(field, "AXValue").map { String(describing: $0) } ?? ""
            let output: [String: Any] = ["sentNs": sent, "old": initial, "actual": actual,
                "position": coordinate(ax(field, "AXPosition")), "size": coordinate(ax(field, "AXSize"), size: true)]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output)); return
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows: [SCWindow]
        if app.hasPrefix("pid:") {
            guard let pid = pid_t(app.dropFirst(4)), pid > 0 else { throw CaptureError.arguments }
            windows = content.windows.filter { $0.owningApplication?.processID == pid }
        } else {
            windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == app }
        }
        if args[0] == "list" {
            let rows: [[String: Any]] = windows.map { w in ["id": w.windowID, "title": w.title ?? "", "frame": [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height], "scale": SCContentFilter(desktopIndependentWindow: w).pointPixelScale] }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: rows)); return
        }
        guard args[0] == "capture", args.count == 8, let id = UInt32(args[2]),
              let window = windows.first(where: { $0.windowID == id }) else { throw CaptureError.missingWindow }
        let coords = args[3...6].compactMap(Double.init)
        guard coords.count == 4, coords.allSatisfy({ $0.isFinite && $0 >= 0 }), coords[2] > 0, coords[3] > 0,
              coords[0] + coords[2] <= 1, coords[1] + coords[3] <= 1 else { throw CaptureError.arguments }
        let output = URL(fileURLWithPath: args[7])
        try Data().write(to: output, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let sampler = Sampler(roi: CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3]), handle: handle)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        config.width = Int(round(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
        config.height = Int(round(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: filter, configuration: config, delegate: sampler)
        try stream.addStreamOutput(sampler, type: .screen, sampleHandlerQueue: sampler.queue)
        try await stream.startCapture()
        // The driver closes stdin after the last settled observation.
        _ = await Task.detached { FileHandle.standardInput.readDataToEndOfFile() }.value
        try await stream.stopCapture()
        sampler.queue.sync {}
    }
}
