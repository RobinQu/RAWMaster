import AppKit
import RAWMasterCore
import RAWMasterImaging

/// The live image panel delegates to the bounded shared pipeline. Keeping the async
/// boundary explicit lets regression tests deliver an old, cancellation-ignoring result.
struct PanelImageLoader {
    var preview: (AssetRecord, Int) async throws -> NSImage
    var detail: (AssetRecord) async throws -> NSImage
    static let live = PanelImageLoader(
        preview: { try await ImageEngines.browsing.preview(for: $0, maxPixel: $1) },
        detail: { try await ImageEngines.browsing.detail(for: $0) })
}
