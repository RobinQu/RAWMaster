import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import RAWMasterImaging

struct ExportLayoutControls: View {
    @Binding var draft: PhotoExportLayout
    @State private var canvasExpanded = false
    @State private var typeExpanded = false
    @State private var issue: String?

    static let fields = [("camera", "机型"), ("lens", "镜头"), ("focal", "焦距"), ("aperture", "光圈"),
                         ("shutter", "快门"), ("iso", "ISO"), ("date", "拍摄日期")]
    static let anchors = [("tl", "左上"), ("tc", "上中"), ("tr", "右上"), ("cl", "左中"), ("cc", "居中"),
                          ("cr", "右中"), ("bl", "左下"), ("bc", "下中"), ("br", "右下")]

    static func choosing(_ style: BuiltinPhotoStyle, for draft: PhotoExportLayout) -> PhotoExportLayout {
        guard style != draft.style else { return draft }
        var next = PhotoExportAppearance(style: style, signature: draft.signature)
        next.logo = draft.appearance?.logo
        return PhotoExportLayout(appearance: next)
    }

    static func issue(for draft: PhotoExportLayout) -> String? {
        let current = draft.resolvedAppearance
        if ["signature", "both"].contains(current.mark), current.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写署名文字，或选择其他水印内容。"
        }
        if current.mark == "logo" && current.logo == nil { return "请添加要印在照片上的 Logo。" }
        if ["exif", "both"].contains(current.mark) && current.fields.isEmpty { return "请至少选择一项拍摄信息。" }
        if current.signature.utf16.count > 100 { return "署名最多 100 个字符。" }
        return nil
    }

    private var current: PhotoExportAppearance { draft.resolvedAppearance }

    private func change(_ update: (inout PhotoExportAppearance) -> Void) {
        var next = current
        update(&next)
        if next.frame == "none" { next.place = "photo" }
        if next.place == "footer", next.anchor.first != "b" { next.anchor = "b" + String(next.anchor.last ?? "c") }
        draft = PhotoExportLayout(appearance: next)
    }

    private func setting<T>(_ key: WritableKeyPath<PhotoExportAppearance, T>) -> Binding<T> {
        Binding(get: { current[keyPath: key] }, set: { value in change { $0[keyPath: key] = value } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("版式设置").font(.headline)
                choices("水印内容", \.mark, options: [("off", "关闭"), ("signature", "署名"), ("exif", "拍摄信息"), ("both", "署名和拍摄信息"), ("logo", "仅 Logo")])
                if ["signature", "both"].contains(current.mark) || !draft.signature.isEmpty {
                    TextField("署名", text: setting(\.signature)).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("export.style.signature")
                }
                if ["exif", "both"].contains(current.mark) {
                    DisclosureGroup("拍摄字段（\(current.fields.count)）") {
                        ForEach(Self.fields, id: \.0) { field in
                            Toggle(field.1, isOn: Binding(get: { current.fields.contains(field.0) }, set: { added in
                                change { value in
                                    value.fields.removeAll { $0 == field.0 }
                                    if added { value.fields.append(field.0) }
                                }
                            }))
                        }
                    }
                }
                HStack {
                    if let logo = current.logo, let bytes = Data(base64Encoded: logo.base64), let image = NSImage(data: bytes) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 24)
                            .accessibilityLabel("当前 Logo")
                    }
                    Button(current.logo == nil ? "添加 Logo…" : "替换 Logo…", action: selectLogo)
                    if current.logo != nil {
                        Button("移除") { change { $0.logo = nil } }.buttonStyle(.link)
                    }
                }
                if current.mark != "off" {
                    choices("位置", \.place, options: current.frame == "none" ? [("photo", "照片内")] : [("photo", "照片内"), ("footer", "底部留白")])
                    choices("对齐", \.anchor, options: Self.anchors.filter { current.place != "footer" || $0.0.first == "b" })
                }
                DisclosureGroup("画布与相框", isExpanded: $canvasExpanded) {
                    VStack(alignment: .leading, spacing: 9) {
                        choices("底板", \.frame, options: [("none", "无边框"), ("solid", "纯色"), ("blur", "同图模糊")])
                        if current.frame != "none" {
                            choices("比例", \.ratio, options: [("source", "跟随照片"), ("1:1", "1∶1"), ("4:5", "4∶5"), ("3:2", "3∶2"), ("16:9", "16∶9")])
                            choices("照片", \.fit, options: [("contain", "完整保留"), ("cover", "居中填满")])
                            if current.fit == "cover" { Text("填满会裁掉超出画框的部分。").font(.caption).foregroundStyle(.secondary) }
                            if current.frame == "solid" { ColorPicker("底色", selection: color(\.paper), supportsOpacity: false) }
                            number("边距", \.margin, range: 0...16, suffix: "%")
                            number("细线", \.stroke, range: 0...5, suffix: "")
                            if current.stroke != 0 { ColorPicker("线色", selection: color(\.strokeColor), supportsOpacity: false) }
                            Toggle("照片投影", isOn: setting(\.shadow))
                        }
                    }.padding(.top, 5)
                }
                if current.mark != "off" {
                    DisclosureGroup(current.mark == "logo" ? "Logo 大小与透明度" : "字体与颜色", isExpanded: $typeExpanded) {
                        VStack(alignment: .leading, spacing: 9) {
                            if current.mark != "logo" {
                                choices("字体", \.font, options: [("sans", "无衬线"), ("serif", "衬线"), ("mono", "等宽")])
                                ColorPicker("文字颜色", selection: color(\.ink), supportsOpacity: false)
                            }
                            number(current.mark == "logo" ? "大小" : "字号", \.scale, range: 60...160, suffix: "%")
                            number("不透明度", \.opacity, range: 0...100, suffix: "%")
                        }.padding(.top, 5)
                    }
                }
                if let issue = issue ?? Self.issue(for: draft) {
                    Text(issue).foregroundStyle(AppPalette.warning).font(.caption)
                }
            }.padding(13)
        }.font(.callout)
    }

    private func choices(_ title: String, _ path: WritableKeyPath<PhotoExportAppearance, String>,
                         options: [(String, String)]) -> some View {
        Picker(title, selection: setting(path)) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func number(_ title: String, _ path: WritableKeyPath<PhotoExportAppearance, Int>,
                        range: ClosedRange<Int>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text("\(current[keyPath: path])" + suffix).monospacedDigit() }
            Slider(value: Binding(get: { Double(current[keyPath: path]) }, set: { value in change { $0[keyPath: path] = Int(value.rounded()) } }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1).accessibilityLabel(title)
        }.font(.caption)
    }

    private func color(_ path: WritableKeyPath<PhotoExportAppearance, String>) -> Binding<Color> {
        Binding {
            let rgb = UInt32(current[keyPath: path].trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        } set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            change { $0[keyPath: path] = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())) }
        }
    }

    private func selectLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Self.logoBytes(at: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            change {
                $0.logo = .init(mime: "image/png", sha256: digest, base64: data.base64EncodedString())
                if $0.mark == "off" { $0.mark = "logo" }
            }
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    static func logoBytes(at url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let identifier = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier].contains(identifier as String),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { throw DevelopmentError.unreadable }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { throw DevelopmentError.invalidEncoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DevelopmentError.invalidEncoding }
        return result as Data
    }
}
