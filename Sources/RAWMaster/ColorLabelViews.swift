import AppKit
import SwiftUI
import RAWMasterCore

extension PhotoColorLabel {
    var color: Color {
        switch self { case .red: .red; case .orange: .orange; case .yellow: .yellow; case .green: .green; case .blue: .blue; case .purple: .purple; case .gray: .gray }
    }

    // Native menus discard SwiftUI foreground styles. Draw the swatch into a
    // non-template image so AppKit preserves its color, including on hover.
    var menuImage: NSImage {
        let fill = NSColor(color)
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { bounds in
            let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            fill.setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.22).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct ColorLabelMenuLabel: View {
    let label: PhotoColorLabel
    var selected = false

    var body: some View {
        Label {
            Text(label.title + (selected ? " ✓" : ""))
        } icon: {
            Image(nsImage: label.menuImage).renderingMode(.original)
        }
    }
}
struct ColorLabelBadge: View {
    @EnvironmentObject var model: AppModel
    let assetID: String
    var body: some View {
        if let label = model.colorLabel(for: assetID) {
            Circle().fill(label.color).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(.primary.opacity(0.22), lineWidth: 0.5))
                .help("颜色标签：" + label.title).accessibilityLabel("颜色标签：" + label.title)
        }
    }
}
struct ColorLabelPicker: View {
    @EnvironmentObject var model: AppModel
    let assetIDs: [String]
    var compact = false
    private var common: PhotoColorLabel? {
        let labels = assetIDs.map { model.colorLabel(for: $0) }
        guard let first = labels.first, labels.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
    private var mixed: Bool {
        let labels = assetIDs.map { model.colorLabel(for: $0) }
        guard let first = labels.first else { return false }
        return labels.dropFirst().contains { $0 != first }
    }
    var body: some View {
        Menu {
            ForEach(PhotoColorLabel.allCases, id: \.rawValue) { label in
                Button { model.setColorLabel(label, assetIDs: assetIDs) } label: {
                    ColorLabelMenuLabel(label: label, selected: common == label)
                }
            }
            Divider()
            Button("移除颜色标签") { model.setColorLabel(nil, assetIDs: assetIDs) }
            Divider()
            Button("撤销上次颜色标签") { model.undoLastColorLabel() }
                .disabled(!model.colorLabelCommands.contains { !$0.restored })
        } label: {
            if compact {
                Image(systemName: "tag.fill").foregroundStyle(common?.color ?? .secondary)
                    .accessibilityLabel(mixed ? "颜色标签：混合" : (common.map { "颜色标签：" + $0.title } ?? "颜色标签"))
            } else {
                Label(mixed ? "颜色标签 · 混合" : (common.map { "颜色标签 · " + $0.title } ?? "颜色标签"), systemImage: "tag.fill")
                    .foregroundStyle(common?.color ?? .secondary)
            }
        }.disabled(assetIDs.isEmpty || model.isBusy || model.isHistoryScope)
            .help("为所选文件设置一种颜色；文字标签保持不变")
    }
}
