import SwiftUI
import RAWMasterCore
import RAWMasterImaging

@MainActor
final class PhotosColorReadout: ObservableObject {
    @Published private(set) var pixel: DevelopmentDisplayPixel?
    private var location: DevelopmentSourcePoint?
    private var source: DevelopmentPreviewSessionID?
    private var nativeSize: CGSize?

    func update(_ event: ImageCanvasHoverEvent, frame: EditingPreviewBitmap?) {
        let rect = event.viewport.imageRect
        guard let frame, event.viewport.frameID == frame.id, let p = event.locationInView,
              rect.width > 0, rect.height > 0, rect.contains(p) else { clear(); return }
        location = DevelopmentSourcePoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
        source = frame.leaseID
        nativeSize = frame.nativeSize
        refresh(frame)
    }

    func refresh(_ frame: EditingPreviewBitmap?) {
        guard let frame, let location, frame.leaseID == source, frame.nativeSize == nativeSize else { clear(); return }
        let next = DevelopmentDisplayPixel.sample(frame.image, at: location)
        if next != pixel { pixel = next }
    }

    func clear() {
        location = nil; source = nil; nativeSize = nil
        if pixel != nil { pixel = nil }
    }

    func formatted(showLab: Bool) -> String? {
        guard let pixel else { return nil }
        if showLab { return String(format: "L* %.1f   a* %.1f   b* %.1f", pixel.lab.x, pixel.lab.y, pixel.lab.z) }
        let rgb = pixel.rgb * 255
        return String(format: "R %.0f   G %.0f   B %.0f", rgb.x, rgb.y, rgb.z)
    }
}

struct PhotosColorReadoutView: View {
    @ObservedObject var readout: PhotosColorReadout
    @AppStorage("editing.scope.showLab") private var showLab = false

    var body: some View {
        HStack(spacing: 7) {
            Menu(showLab ? "Lab D50" : "sRGB") {
                Button("sRGB · 0–255") { showLab = false }
                Button("Lab · D50") { showLab = true }
            }.menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("像素读数色彩空间")
            if let text = readout.formatted(showLab: showLab) {
                Text(text)
            } else {
                Text("将指针移到照片上").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.font(.caption2).monospacedDigit()
            .accessibilityIdentifier("photos.scopes.pixelReadout")
    }
}
