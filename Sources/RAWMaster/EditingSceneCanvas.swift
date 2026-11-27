import AppKit
import Metal
import QuartzCore
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct SceneDisplayEnvironment {
    let id: CGDirectDisplayID
    let colorProfile: Data?
    let headroom: CGFloat
    let potentialHeadroom: CGFloat
}

/// Uses the existing photo transform and safe viewport. Only the image surface is EDR; all UI chrome stays SDR.
struct EditingSceneCanvas: NSViewRepresentable {
    let frame: DevelopmentScenePreviewFrameV1?
    let target: DevelopmentSceneOutputStateV1.Target
    let requestHDR: Bool
    let fitInsets: NSEdgeInsets
    @Binding var transform: ImageTransform
    let onDisplay: (SceneDisplayEnvironment?) -> Void
    let onSampling: (DevelopmentScenePreviewV1.Sampling) -> Void
    let onPresentationError: () -> Void
    var onPick: ((CGPoint) -> Void)? = nil
    var onCancelPick: (() -> Bool)? = nil

    func makeNSView(context: Context) -> SceneMetalView { SceneMetalView() }
    func updateNSView(_ view: SceneMetalView, context: Context) {
        view.changedTransform = { transform = $0 }
        view.changedDisplay = onDisplay
        view.changedSampling = onSampling
        view.failed = onPresentationError
        view.pickedPoint = onPick
        view.cancelPick = onCancelPick
        view.submit(frame, target: target, requestHDR: requestHDR, transform: transform, insets: fitInsets)
    }
}

@MainActor final class SceneMetalView: NSView {
    private struct DisplayKey: Equatable {
        let id: UUID?, target: DevelopmentSceneOutputStateV1.Target, hdr: Bool
        let size: CGSize, backing: CGFloat, rect: CGRect, viewport: CGRect
        let displayGeneration: UInt64
    }
    private struct Parameters {
        var pixels: SIMD4<Float> // target(presentation) pixel bounds, top-left
    }

    private(set) var photoLayer: CAMetalLayer?
    private(set) var presentedFrameID: UUID?
    var changedTransform: ((ImageTransform) -> Void)?
    var changedDisplay: ((SceneDisplayEnvironment?) -> Void)?
    var pickedPoint: ((CGPoint) -> Void)?
    var cancelPick: (() -> Bool)?
    var changedSampling: ((DevelopmentScenePreviewV1.Sampling) -> Void)?
    var failed: (() -> Void)?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLComputePipelineState?
    private var sceneFrame: DevelopmentScenePreviewFrameV1?
    private var target: DevelopmentSceneOutputStateV1.Target = .sdr709
    private var requestHDR = false
    private var transform = ImageTransform()
    private var insets = NSEdgeInsets.zero
    private var lastPaint: DisplayKey?
    private var lastReported: DevelopmentScenePreviewV1.Sampling?
    private var timer: Timer?
    private var inFlight = false
    private var display: SceneDisplayEnvironment?
    private var displayGeneration: UInt64 = 0
    private var screenUpdateQueued = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var backing: CGFloat { max(1, window?.backingScaleFactor ?? 1) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("场景照片预览")
    }
    required init?(coder: NSCoder) { nil }

    func submit(_ frame: DevelopmentScenePreviewFrameV1?, target: DevelopmentSceneOutputStateV1.Target,
                requestHDR: Bool, transform: ImageTransform, insets: NSEdgeInsets) {
        self.sceneFrame = frame; self.transform = transform; self.insets = insets
        self.requestHDR = requestHDR
        if self.target != target {
            self.target = target
            // Never interpret the old drawable with a new color space or leave HDR on screen as fallback.
            photoLayer?.removeFromSuperlayer(); photoLayer = nil; lastPaint = nil; presentedFrameID = nil
        }
        if frame == nil { photoLayer?.isHidden = true; lastPaint = nil; presentedFrameID = nil }
        scheduleDraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        let notifications = NotificationCenter.default
        notifications.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        notifications.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if let window {
            notifications.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
            notifications.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleScreenUpdate() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        scheduleScreenUpdate()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); scheduleScreenUpdate(); scheduleDraw() }
    override func layout() { super.layout(); scheduleDraw() }

    @objc private func screenChanged(_ notification: Notification) { scheduleScreenUpdate() }

    private static func displayID(_ screen: NSScreen?) -> CGDirectDisplayID? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func scheduleScreenUpdate() {
        guard !screenUpdateQueued else { return }
        screenUpdateQueued = true
        // Moving an NSView into its window may be part of a SwiftUI update. Read the final
        // window state and publish display properties together after that update returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.screenUpdateQueued = false
            self.updateDisplay()
        }
    }

    private func updateDisplay() {
        let next: SceneDisplayEnvironment?
        if let screen = window?.screen, let id = Self.displayID(screen) {
            func finiteHeadroom(_ value: CGFloat) -> CGFloat { value.isFinite ? max(1, value) : 1 }
            next = .init(id: id, colorProfile: screen.colorSpace?.iccProfileData,
                headroom: finiteHeadroom(screen.maximumExtendedDynamicRangeColorComponentValue),
                potentialHeadroom: finiteHeadroom(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
        } else { next = nil }
        let changed = next?.id != display?.id || next?.colorProfile != display?.colorProfile
            || next?.potentialHeadroom != display?.potentialHeadroom
        display = next
        if changed {
            displayGeneration &+= 1
            photoLayer?.isHidden = true
            lastPaint = nil
            presentedFrameID = nil
        }
        changedDisplay?(next)
        if changed { scheduleDraw() }
    }

    private func imageRect(nativeSize: CGSize) -> CGRect {
        ImageViewportGeometry.imageRect(pixelSize: nativeSize, viewport: bounds.size, transform: transform,
            backingScale: backing, fitInsets: insets)
    }

    // Callbacks always occur after SwiftUI's updateNSView and never mutate state during a body pass.
    private func scheduleDraw() {
        DispatchQueue.main.async { [weak self] in self?.drawLatest() }
    }

    private func drawLatest() {
        guard let window, window.isVisible, bounds.width > 0, bounds.height > 0,
              let display, Self.displayID(window.screen) == display.id,
              let frame = sceneFrame, frame.target == target else { return }
        // Keep requesting EDR on a capable panel during its SDR fallback. Current headroom can
        // stay at 1 until onscreen content requests EDR.
        let enableEDR = requestHDR && display.potentialHeadroom > 1
        guard frame.target != .hdr2020 || enableEDR else { return }
        let rect = imageRect(nativeSize: frame.nativeSize)
        if transform.physicalMagnification != nil || transform.scale > 1,
           let visible = ImageViewportGeometry.visibleWindow(destination: rect, bounds: bounds),
           frame.nativeSize.width * frame.nativeSize.height * visible.width * visible.height <= 3_000_000 {
            let region = ImageViewportGeometry.quantized(ImageViewportGeometry.servedWindow(visible: visible, margin: 0.13), steps: 64)
            report(.pixels(window: region))
        } else { report(.fit(maximumEdge: 1440)) }
        guard !inFlight else { return }
        let drawn = ImageViewportGeometry.windowRect(frame.window, in: rect)
        let clipped = drawn.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { photoLayer?.isHidden = true; lastPaint = nil; presentedFrameID = nil; return }
        let pixels = clipped.applying(.init(scaleX: backing, y: backing)).integral
        let viewport = pixels.applying(.init(scaleX: 1 / backing, y: 1 / backing))
        let size = pixels.size
        guard size.width <= 8192, size.height <= 8192 else { failed?(); return }
        let key = DisplayKey(id: frame.id, target: frame.target, hdr: enableEDR, size: size, backing: backing,
            rect: drawn, viewport: viewport, displayGeneration: displayGeneration)
        guard key != lastPaint else { return }
        do {
            let gpu = frame.texture.device
            if queue?.device !== gpu || pipeline == nil {
                let library = try gpu.makeLibrary(source: Self.shader, options: nil)
                guard let kernel = library.makeFunction(name: "rmPresentSceneV1") else { throw Failure.device }
                pipeline = try gpu.makeComputePipelineState(function: kernel); queue = gpu.makeCommandQueue()
            }
            let layer = try configuredLayer(device: gpu, key: key)
            guard let pipeline, let queue, let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder() else { throw Failure.device }
            var params = Parameters(pixels: .init(Float((drawn.minX - viewport.minX) * backing), Float((drawn.minY - viewport.minY) * backing),
                                                  Float(drawn.width * backing), Float(drawn.height * backing)))
            encoder.setComputePipelineState(pipeline); encoder.setTexture(frame.texture, index: 0); encoder.setTexture(drawable.texture, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<Parameters>.stride, index: 0)
            let lanes = pipeline.threadExecutionWidth
            encoder.dispatchThreads(.init(width: drawable.texture.width, height: drawable.texture.height, depth: 1),
                threadsPerThreadgroup: .init(width: lanes, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / lanes), depth: 1))
            encoder.endEncoding()
            lastPaint = key; inFlight = true
            command.present(drawable)
            let layerID = ObjectIdentifier(layer)
            command.addCompletedHandler { [weak self] complete in
                let succeeded = complete.status == .completed
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight = false
                    if let currentWindow = self.window, let active = self.photoLayer, ObjectIdentifier(active) == layerID,
                       self.lastPaint == key, self.sceneFrame?.id == key.id,
                       let currentDisplay = self.display, Self.displayID(currentWindow.screen) == currentDisplay.id {
                        if succeeded {
                            self.presentedFrameID = frame.id; active.isHidden = false
                            InteractionTrace.shared.sceneDrawableCompleted(frame: frame.id, target: frame.target,
                                display: currentDisplay, windowNumber: currentWindow.windowNumber,
                                pixelSize: key.size, edrEnabled: key.hdr, nativeWindow: frame.window != nil)
                        } else { active.isHidden = true; self.presentedFrameID = nil; self.failed?(); return }
                    }
                    self.drawLatest()
                }
            }
            command.commit()
        } catch { photoLayer?.isHidden = true; presentedFrameID = nil; failed?() }
    }

    private func configuredLayer(device: MTLDevice, key: DisplayKey) throws -> CAMetalLayer {
        let layer: CAMetalLayer
        if let current = photoLayer { layer = current }
        else {
            layer = CAMetalLayer()
            layer.device = device; layer.pixelFormat = .rgba16Float; layer.framebufferOnly = false
            layer.isOpaque = false; layer.isHidden = true
            let profile = key.target == .hdr2020 ? CGColorSpace.extendedLinearITUR_2020 : CGColorSpace.extendedLinearSRGB
            guard let space = CGColorSpace(name: profile) else { throw Failure.device }
            layer.colorspace = space
            self.layer?.addSublayer(layer); photoLayer = layer
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let area = key.viewport
        // View coordinates are top-left; AppKit chooses the parent layer's coordinate orientation.
        layer.frame = self.layer?.isGeometryFlipped == true ? area :
            CGRect(x: area.minX, y: bounds.maxY - area.maxY, width: area.width, height: area.height)
        layer.contentsScale = key.backing
        layer.drawableSize = key.size
        layer.wantsExtendedDynamicRangeContent = key.hdr
        CATransaction.commit()
        return layer
    }

    private func report(_ sampling: DevelopmentScenePreviewV1.Sampling) {
        guard sampling != lastReported else { return }
        lastReported = sampling; changedSampling?(sampling)
    }

    override func mouseDown(with event: NSEvent) {
        guard let pickedPoint, let frame = sceneFrame else { super.mouseDown(with:event); return }
        let hit = convert(event.locationInWindow, from:nil)
        let rect = imageRect(nativeSize: frame.nativeSize)
        guard rect.contains(hit), rect.width > 0, rect.height > 0 else { return }
        pickedPoint(.init(x:(hit.x-rect.minX)/rect.width, y:(hit.y-rect.minY)/rect.height))
    }
    override func cancelOperation(_ sender: Any?) {
        if cancelPick?() == true { return }
        super.cancelOperation(sender)
    }
    override func scrollWheel(with event: NSEvent) {
        guard let frame = sceneFrame else { return super.scrollWheel(with: event) }
        let rect = imageRect(nativeSize: frame.nativeSize)
        guard rect.width > 0, rect.height > 0, transform.physicalMagnification != nil || transform.scale > 1 else { return }
        var next = transform
        next.centerX = min(1, max(0, next.centerX - event.scrollingDeltaX / rect.width))
        next.centerY = min(1, max(0, next.centerY + event.scrollingDeltaY / rect.height))
        changedTransform?(next)
    }

    override func magnify(with event: NSEvent) {
        var next = transform
        let zoom = max(0.1, 1 + event.magnification)
        if let physical = next.physicalMagnification { next.physicalMagnification = min(16, max(0.025, physical * zoom)) }
        else { next.scale = min(64, max(1, transform.scale * zoom)) }
        changedTransform?(next)
    }

    private enum Failure: Error { case device }
    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    kernel void rmPresentSceneV1(texture2d<float,access::read> image [[texture(0)]],
        texture2d<float,access::write> drawable [[texture(1)]], constant float4& rect [[buffer(0)]],
        uint2 xy [[thread_position_in_grid]]) {
      float2 uv=(float2(xy)+0.5f-rect.xy)/rect.zw;
      if (any(uv<0.0f)||any(uv>=1.0f)) { drawable.write(float4(0),xy); return; }
      int2 size=int2(image.get_width(),image.get_height());
      float2 p=uv*float2(size)-0.5f; int2 a=int2(floor(p)); float2 f=fract(p);
      float4 top=mix(image.read(uint2(clamp(a,int2(0),size-1))),
                     image.read(uint2(clamp(a+int2(1,0),int2(0),size-1))),f.x);
      float4 bottom=mix(image.read(uint2(clamp(a+int2(0,1),int2(0),size-1))),
                        image.read(uint2(clamp(a+1,int2(0),size-1))),f.x);
      // The compositor performs the monitor ICC conversion. No PQ encoding or clamps here.
      drawable.write(mix(top,bottom,f.y),xy);
    }
    """#
}
