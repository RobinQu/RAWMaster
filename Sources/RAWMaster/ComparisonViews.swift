import AppKit
import ImageIO
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

enum ComparisonMode: String, CaseIterable, Identifiable {
    case rgb, metadata, histogram
    var id: String { rawValue }
    var title: String { switch self { case .rgb: return "RGB 视图"; case .metadata: return "EXIF 与文件信息"; case .histogram: return "直方图" } }
    var symbol: String { switch self { case .rgb: return "photo"; case .metadata: return "list.bullet.rectangle"; case .histogram: return "chart.bar.xaxis" } }
}

/// The actions belong to this file, irrespective of the filmstrip multi-selection.
private struct ComparisonPhotoActions: View {
    @EnvironmentObject var model: AppModel
    let asset: AssetRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { model.decideAsset(id: asset.id, decision: .keep) } label: {
                    Image(systemName: asset.decision == .keep ? "flag.fill" : "flag")
                        .foregroundStyle(asset.decision == .keep ? AppPalette.keep : .secondary)
                }.help("保留 " + asset.filename).accessibilityLabel("保留：" + asset.filename)
                Button { model.decideAsset(id: asset.id, decision: .reject) } label: {
                    Image(systemName: asset.decision == .reject ? "xmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(asset.decision == .reject ? AppPalette.warning : .secondary)
                }.help("排除 " + asset.filename).accessibilityLabel("排除：" + asset.filename)
                Button { model.decideAsset(id: asset.id, decision: .undecided) } label: { Image(systemName: "circle.dotted") }
                    .help("清除决定：" + asset.filename).accessibilityLabel("清除决定：" + asset.filename)
                Spacer(minLength: 0)
                ColorLabelPicker(assetIDs: [asset.id], compact: true)
            }
            RatingButtons(rating: asset.rating) { model.decideAsset(id: asset.id, rating: $0) }
                .accessibilityLabel("星级：" + asset.filename)
        }.font(.caption).buttonStyle(.borderless)
            .disabled(!model.canDecideAsset(id: asset.id))
            .accessibilityElement(children: .contain).accessibilityLabel("照片操作：" + asset.filename)
    }
}

struct ComparisonToolbar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { modePicker; Spacer(minLength: 8); imageTools; undoButton }
            VStack(alignment: .leading, spacing: 9) {
                HStack { modePicker; Spacer(minLength: 0); undoButton }
                if model.comparisonMode == .rgb { HStack(spacing: 16) { imageTools; Spacer(minLength: 0) } }
            }
        }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 11)
            .background(AppPalette.panel)
    }
    private var modePicker: some View {
        Picker("对比模式", selection: $model.comparisonMode) {
            ForEach(ComparisonMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityLabel("对比模式")
    }
    @ViewBuilder private var imageTools: some View {
        if model.comparisonMode == .rgb {
            Button { model.actualPixels.toggle() } label: {
                Label(model.actualPixels ? "适合窗口" : "原始像素 1:1", systemImage: model.actualPixels ? "arrow.down.right.and.arrow.up.left" : "1.magnifyingglass")
            }.help("Z · 适合窗口 / 原始像素")
            Toggle("同步缩放与平移", isOn: $model.syncCompare).toggleStyle(.checkbox).fixedSize()
        }
    }
    private var undoButton: some View {
        Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            .disabled(model.undoCount == 0).help("撤销上一步操作 ⌘Z").accessibilityLabel("撤销上一步操作")
    }
}

struct ComparisonEmptyState: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("选择 2–4 张照片进行比较", systemImage: "rectangle.split.2x1").font(.title3.weight(.semibold))
            Text(model.compareAssets.isEmpty ? "在下方照片列表中按住 ⌘ 点击，选择需要比较的照片。" : "当前只有一张可用照片，请从下方列表再选择一张。")
                .font(.caption).foregroundStyle(.secondary)
            Text("对比方式可在底部工具栏切换。").font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ComparisonContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var transform = ImageTransform()
    @State private var snapshots: [String: ComparisonSnapshot] = [:]
    @State private var loading = false
    private var taskKey: String {
        model.comparisonMode.rawValue + model.comparisonPanels.map { $0.id + $0.selectionAsset.resolvedURL.path + $0.selectionAsset.availability.rawValue + $0.selectionAsset.importState.rawValue + $0.imageAsset.resolvedURL.path + $0.imageAsset.availability.rawValue + $0.imageAsset.importState.rawValue }.joined(separator: "|")
    }
    var body: some View {
        Group {
            switch model.comparisonMode {
            case .rgb: rgb
            case .metadata: metadataTable
            case .histogram: histogramComparison
            }
        }.task(id: taskKey) {
            guard model.comparisonMode != .rgb else { snapshots = [:]; return }
            let histogram = model.comparisonMode == .histogram
            let assets = model.comparisonPanels.map { ($0.id, histogram ? $0.imageAsset : $0.selectionAsset) }
            snapshots = [:]; loading = true
            let work = Task.detached(priority: .userInitiated) {
                var output: [String: ComparisonSnapshot] = [:]
                for (id, asset) in assets {
                    if Task.isCancelled { break }
                    output[id] = ComparisonSnapshot.read(asset: asset, histogram: histogram)
                }
                return output
            }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled else { return }
            snapshots = result; loading = false
        }
    }
    private var rgb: some View {
        GeometryReader { geometry in
            let rowCount = model.comparisonPanels.count > 2 ? 2 : 1
            let height = max(120, (geometry.size.height - CGFloat(rowCount - 1)) / CGFloat(rowCount))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                ForEach(model.comparisonPanels) { panel in
                    VStack(spacing: 0) {
                        ImagePanel(asset: panel.imageAsset, actualPixels: model.actualPixels, sharedTransform: model.syncCompare ? $transform : nil)
                        VStack(alignment: .leading, spacing: 6) {
                            if panel.imageAsset.id != panel.id {
                                Text("操作：" + panel.selectionAsset.filename).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            ComparisonPhotoActions(asset: panel.selectionAsset)
                        }.padding(.horizontal, 14).padding(.vertical, 10).background(AppPalette.panel)
                    }.frame(height: height)
                }
            }
        }.background(AppPalette.canvas)
    }
    private func photoHeader(_ panel: AppModel.ComparisonPanel) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ThumbnailView(asset: panel.imageAsset).frame(width: 46, height: 36).background(AppPalette.thumbnailWell).clipped()
                Text(panel.selectionAsset.filename).font(.caption.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 36)
            ComparisonPhotoActions(asset: panel.selectionAsset)
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }
    private var metadataTable: some View {
        GeometryReader { geometry in
            let labelWidth: CGFloat = 84
            let count = max(1, model.comparisonPanels.count)
            let columnWidth = max(168, (geometry.size.width - labelWidth - 24) / CGFloat(count))
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    // Outside the vertical scroller: names, previews and file actions stay pinned.
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("拍摄与文件").font(.caption.weight(.semibold))
                            Text("逐项对比").font(.caption2).foregroundStyle(.secondary)
                        }.padding(.leading, 12).frame(width: labelWidth, alignment: .leading)
                        ForEach(model.comparisonPanels) { panel in
                            photoHeader(panel).frame(width: columnWidth)
                        }
                    }.frame(height: 118).background(AppPalette.panel)
                    Divider()
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            statusRow(labelWidth: labelWidth, columnWidth: columnWidth)
                            ForEach(Array(ComparisonSnapshot.fields.enumerated()), id: \.element) { index, field in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(field).font(.caption).foregroundStyle(.secondary)
                                        .padding(.horizontal, 12).frame(width: labelWidth, alignment: .leading)
                                    ForEach(model.comparisonPanels) { panel in
                                        Text(snapshots[panel.id]?.values[field] ?? (loading ? "读取中…" : "—"))
                                            .font(field == "文件位置" ? .system(size: 11, design: .monospaced) : .system(size: 12))
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                            .padding(.horizontal, 12).frame(width: columnWidth, alignment: .leading)
                                    }
                                }.padding(.vertical, 9).frame(minHeight: 34)
                                    .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                                Divider().opacity(0.55)
                            }
                        }
                    }.defaultScrollAnchor(.topLeading)
                }.frame(height: geometry.size.height, alignment: .top)
                    .padding(.horizontal, 12)
            }.defaultScrollAnchor(.topLeading).id(ComparisonMode.metadata)
        }.background(AppPalette.canvas)
    }
    private func statusRow(labelWidth: CGFloat, columnWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("读取状态").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).frame(width: labelWidth, alignment: .leading)
            ForEach(model.comparisonPanels) { panel in
                Text(snapshots[panel.id]?.error ?? (loading ? "正在读取文件信息…" : "当前所选文件"))
                    .font(.caption2).foregroundStyle(snapshots[panel.id]?.error == nil ? Color.secondary : AppPalette.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).frame(width: columnWidth, alignment: .leading)
            }
        }.padding(.vertical, 9)
    }
    private var histogramComparison: some View {
        GeometryReader { geometry in
            let count = max(1, model.comparisonPanels.count)
            let columnWidth = max(190, (geometry.size.width - 32 - CGFloat(count - 1) * 8) / CGFloat(count))
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("RGB 直方图 · sRGB 预览采样").font(.caption.weight(.semibold))
                        Text("最长边 512 像素；横轴 0–255 色阶，纵轴为像素占比，所有照片使用共同尺度。预览不代表 RAW 传感器数据。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(width: max(0, geometry.size.width - 32), alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(model.comparisonPanels) { panel in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Text(panel.selectionAsset.filename).font(.caption.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    ColorLabelBadge(assetID: panel.id)
                                }.frame(height: 32, alignment: .top)
                                if let histogram = snapshots[panel.id]?.histogram {
                                    RGBHistogramView(histogram: histogram, maximum: histogramMaximum).frame(height: 190)
                                } else {
                                    ZStack {
                                        AppPalette.thumbnailWell
                                        if loading { ProgressView().controlSize(.small) }
                                        else { Text(snapshots[panel.id]?.error ?? "无可用预览").font(.caption).foregroundStyle(AppPalette.warning).padding(12) }
                                    }.frame(height: 190)
                                }
                                HStack { Text("0"); Spacer(); Text("255") }.font(.caption2).foregroundStyle(.secondary)
                                ComparisonPhotoActions(asset: panel.selectionAsset)
                                Text("采样：" + panel.imageAsset.filename).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                HStack { channel("R", .red); channel("G", .green); channel("B", .blue) }
                            }.padding(12).frame(width: columnWidth, alignment: .topLeading)
                                .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    Text("共同峰值：\((histogramMaximum * 100).formatted(.number.precision(.fractionLength(1))))%")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
            }.defaultScrollAnchor(.topLeading).id(ComparisonMode.histogram)
        }.background(AppPalette.canvas)
    }
    private var histogramMaximum: Double { max(0.001, snapshots.values.compactMap(\.histogram).flatMap { $0.red + $0.green + $0.blue }.max() ?? 0) }
    private func channel(_ text: String, _ color: Color) -> some View { Label { Text(text) } icon: { Circle().fill(color).frame(width: 7, height: 7) }.font(.caption2) }
}

struct RGBHistogram: Sendable {
    let red: [Double]
    let green: [Double]
    let blue: [Double]
    static func sample(rgba: [UInt8]) -> RGBHistogram {
        var channels = Array(repeating: Array(repeating: 0.0, count: 256), count: 3)
        let count = rgba.count / 4
        for index in 0..<count { for channel in 0..<3 { channels[channel][Int(rgba[index * 4 + channel])] += 1 } }
        let divisor = Double(max(1, count))
        return RGBHistogram(red: channels[0].map { $0 / divisor }, green: channels[1].map { $0 / divisor }, blue: channels[2].map { $0 / divisor })
    }
}

private struct RGBHistogramView: View {
    let histogram: RGBHistogram
    let maximum: Double
    var body: some View {
        Canvas { context, size in
            for (values, color) in [(histogram.red, Color.red), (histogram.green, Color.green), (histogram.blue, Color.blue)] {
                var line = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) / 255 * size.width, y: size.height * (1 - CGFloat(value / maximum)))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .color(color.opacity(0.85)), lineWidth: 1.5)
            }
        }.background(AppPalette.thumbnailWell).overlay(Rectangle().stroke(AppPalette.boundary))
    }
}

struct ComparisonSnapshot: Sendable {
    static let fields = ["文件名", "格式", "大小", "分辨率", "相机", "镜头", "拍摄时间", "快门", "光圈", "ISO", "焦距", "曝光补偿", "色彩空间", "文件状态", "文件位置"]
    var values: [String: String]
    var histogram: RGBHistogram?
    var error: String?
    static func exposureDescription(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let denominator = (1 / seconds).rounded()
        if seconds < 1, denominator.isFinite, denominator >= 1, denominator < Double(Int.max) {
            return "1/\(Int(denominator)) s"
        }
        return "\(seconds) s"
    }
    static func read(asset: AssetRecord, histogram: Bool) -> ComparisonSnapshot {
        var result = ComparisonSnapshot(values: ["文件名": asset.filename, "格式": asset.resolvedURL.pathExtension.uppercased(), "大小": ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file), "相机": asset.camera ?? "—", "文件状态": asset.availability.title, "文件位置": asset.resolvedURL.path])
        if let date = asset.capturedAt { result.values["拍摄时间"] = date.formatted(date: .numeric, time: .standard) }
        if let w = asset.width, let h = asset.height { result.values["分辨率"] = "\(w) × \(h)" }
        guard asset.availability == .available else { result.error = "文件离线或内容已变化，无法读取当前图像。"; return result }
        guard let source = CGImageSourceCreateWithURL(asset.resolvedURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            result.error = "无法读取图像或 EXIF 信息。"; return result
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        func value(_ dictionary: [String: Any], _ key: CFString) -> String? { dictionary[key as String].map { String(describing: $0) } }
        if let w = properties[kCGImagePropertyPixelWidth as String], let h = properties[kCGImagePropertyPixelHeight as String] { result.values["分辨率"] = "\(w) × \(h)" }
        result.values["相机"] = value(tiff, kCGImagePropertyTIFFModel) ?? result.values["相机"]
        result.values["镜头"] = value(exif, kCGImagePropertyExifLensModel)
        result.values["拍摄时间"] = value(exif, kCGImagePropertyExifDateTimeOriginal) ?? result.values["拍摄时间"]
        if let exposure = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber {
            result.values["快门"] = exposureDescription(seconds: exposure.doubleValue)
        }
        result.values["光圈"] = value(exif, kCGImagePropertyExifFNumber).map { "f/" + $0 }
        if let values = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber] { result.values["ISO"] = values.map(\.stringValue).joined(separator: ", ") }
        result.values["焦距"] = value(exif, kCGImagePropertyExifFocalLength).map { $0 + " mm" }
        result.values["曝光补偿"] = value(exif, kCGImagePropertyExifExposureBiasValue).map { $0 + " EV" }
        result.values["色彩空间"] = properties[kCGImagePropertyProfileName as String].map { String(describing: $0) } ?? value(properties, kCGImagePropertyColorModel)
        guard histogram else { return result }
        if Task.isCancelled { return result }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { result.error = "此文件无法生成预览直方图。"; return result }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        if drawn { result.histogram = RGBHistogram.sample(rgba: bytes) } else { result.error = "无法分析预览颜色。" }
        return result
    }
}
