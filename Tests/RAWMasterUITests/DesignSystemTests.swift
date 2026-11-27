import AppKit
import SwiftUI
import XCTest
@testable import RAWMaster

final class DesignSystemTests: XCTestCase {
    /// 规范里的数值是契约；改动令牌必须同步 specs/039-design-system/spec.md。
    func testPublishedTokens() {
        XCTAssertEqual(AppDesign.Metric.rowHeight, 26)
        XCTAssertEqual(AppDesign.Metric.scaleHeight, 6)
        XCTAssertEqual(AppDesign.Metric.compactRowHeight, 22)
        XCTAssertEqual(AppDesign.Metric.sectionHeaderHeight, 32)
        XCTAssertEqual(AppDesign.Metric.tabHeight, 24)
        XCTAssertEqual(AppDesign.Metric.segmentDividerHeight, 14)
        XCTAssertEqual(AppDesign.Metric.segmentDividerWidth, 1)
        XCTAssertEqual(AppDesign.Metric.iconButtonSize, 26)
        XCTAssertEqual(AppDesign.Metric.fieldHeight, 21)
        XCTAssertEqual(AppDesign.Spacing.row, 4)
        XCTAssertEqual(AppDesign.Spacing.inline, 7)
        XCTAssertEqual(AppDesign.Spacing.group, 12)
        XCTAssertEqual(AppDesign.Spacing.section, 16)
        XCTAssertEqual(AppDesign.Spacing.inspectorInset, 12)
        XCTAssertEqual(AppDesign.Spacing.panelInset, 14)
        XCTAssertEqual(AppDesign.Radius.glyph, 2)
        XCTAssertEqual(AppDesign.Radius.control, 5)
        XCTAssertEqual(AppDesign.Radius.container, 7)
        XCTAssertEqual(AppDesign.Radius.composer, 9)
    }

    /// 旧入口保留，但必须指向同一组令牌，避免两套数值漂移。
    func testLegacyLayoutEntryPointsDelegate() {
        XCTAssertEqual(PhotosControlLayout.height, AppDesign.Metric.rowHeight)
        XCTAssertEqual(PhotosControlLayout.scaleHeight, AppDesign.Metric.scaleHeight)
        XCTAssertEqual(PhotosControlLayout.spacing, AppDesign.Spacing.row)
        XCTAssertEqual(PhotosControlLayout.descriptionSpacing, AppDesign.Spacing.inline)
        XCTAssertEqual(PhotosControlLayout.groupSpacing, AppDesign.Spacing.group)
    }

    @MainActor func testSliderRowReservesScaleBand() {
        let row = PhotosSliderRow(title: "曝光", value: .constant(0.5), range: -5...5, onReset: { _ in }) { _ in }
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 64)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height,
                       AppDesign.Metric.rowHeight + AppDesign.Metric.scaleHeight, accuracy: 0.5)
    }

    @MainActor func testIconButtonKeepsHitArea() {
        let host = NSHostingView(rootView: AppIconButton(systemName: "plus", label: "新建") {})
        host.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, AppDesign.Metric.iconButtonSize, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize.height, AppDesign.Metric.iconButtonSize, accuracy: 0.5)
    }

    @MainActor func testGroupedTabsKeepPublishedHeightAtLibraryWidth() {
        let host = NSHostingView(rootView: AppTabs(title: "浏览方式", selection: .constant("单张"),
                                                   options: ["网格", "单张", "比较"], label: { $0 })
            .frame(width: 120))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 64)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, AppDesign.Metric.tabHeight, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize.width, 120, accuracy: 0.5)
    }

    /// 可选证据：设置 RAWMASTER_DESIGN_GALLERY_OUTPUT 后写出浅色与深色画廊截图。
    @MainActor func testOptionalGalleryCaptures() throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_DESIGN_GALLERY_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_DESIGN_GALLERY_OUTPUT to render the design gallery")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let host = NSHostingView(rootView: DesignGallery().preferredColorScheme(dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = NSSize(width: 760, height: 1_500)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("gallery-\(dark ? "dark" : "light").png"))
            XCTAssertGreaterThan(rep.pixelsHigh, 800)
            let luminance = averageLuminance(rep)
            if dark { XCTAssertLessThan(luminance, 0.5) } else { XCTAssertGreaterThan(luminance, 0.5) }
            window.contentView = nil
        }
    }

    private func averageLuminance(_ rep: NSBitmapImageRep) -> Double {
        var total = 0.0, samples = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 40) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 40) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                samples += 1
            }
        }
        return samples > 0 ? total / samples : 0
    }
}
