import AppKit
import RAWMasterCore
import RAWMasterImaging
import SwiftUI
@testable import RAWMaster

enum PhotoInspectionFixtures {
    static func writeCubes(in directory: URL) throws -> [URL] {
        try [false, true].map { monochrome in
            let name = monochrome ? "Mono" : "Warm"
            let url = directory.appendingPathComponent(name + ".cube")
            var text = "TITLE \"\(name)\"\nLUT_3D_SIZE 17\n"
            for b in 0...16 { for g in 0...16 { for r in 0...16 {
                let red = Double(r)/16, green = Double(g)/16, blue = Double(b)/16
                let gray = red*0.2126 + green*0.7152 + blue*0.0722
                let value = monochrome ? [gray,gray,gray] : [red*0.94+0.06,green,blue*0.9]
                text += value.map { String($0) }.joined(separator:" ") + "\n"
            }}}
            try text.write(to:url,atomically:true,encoding:.utf8)
            return url
        }
    }

    /// Render the normal detached scope in a window that never enters the screen's window list.
    @MainActor static func detachedScope(editing: EditingController, defaults: UserDefaults, size: CGSize) throws -> [Double] {
        guard let distribution = editing.developmentHistogram, distribution.visibleSamples > 0 else { throw EditingError.staleSource }
        let panel = NSPanel(contentRect:.init(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],
                            backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let view = NSHostingView(rootView:PhotosColorScopes(editing:editing,floating:true).padding()
            .defaultAppStorage(defaults).environment(\.colorScheme,.dark))
        panel.contentView = view
        defer { panel.contentView = nil; panel.close() }
        view.frame = .init(origin:.zero,size:size)
        view.layoutSubtreeIfNeeded()
        guard !panel.isVisible, !panel.isKeyWindow,
              let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw EditingError.invalidRecipe }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        var chromatic = 0
        for y in stride(from:bitmap.pixelsHigh/4,to:3*bitmap.pixelsHigh/4,by:4) {
            for x in stride(from:bitmap.pixelsWide/3,to:2*bitmap.pixelsWide/3,by:4) {
                guard let pixel = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) else { continue }
                let maxChannel = max(pixel.redComponent,pixel.greenComponent,pixel.blueComponent)
                let minChannel = min(pixel.redComponent,pixel.greenComponent,pixel.blueComponent)
                if maxChannel-minChannel > 0.12, pixel.alphaComponent > 0.95 { chromatic += 1 }
            }
        }
        guard chromatic >= 8 else { throw EditingError.invalidRecipe }
        return [Double(bitmap.pixelsWide),Double(bitmap.pixelsHigh),Double(chromatic),Double(distribution.visibleSamples)]
    }
}
