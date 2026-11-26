import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct PhotosMaskControls:View{
    @ObservedObject var editing:EditingController
    @ObservedObject var session:EditingDevelopmentSession
    @ObservedObject var input: EditingMaskInputSession
    let context:EditingInteractionContext
    @State private var errorText:String?
    @Environment(\.colorScheme) private var colorScheme

    init(editing: EditingController, session: EditingDevelopmentSession, context: EditingInteractionContext) {
        self.editing = editing
        self.session = session
        self.input = editing.developmentMaskInput
        self.context = context
    }

    private var layers:[DevelopmentMaskLayerV3]{session.parameters.masks}
    private var selected:DevelopmentMaskLayerV3?{layers.first{$0.id==editing.developmentScopeMaskID} ?? layers.last}
    var body: some View {
        VStack(alignment: .leading, spacing: PhotosControlLayout.groupSpacing) {
            PhotosAIMaskControls(input: input, session: session, context: context) {
                editing.addDevelopmentMask(.range, context: context)
            }
            Divider()
            layerList
            if let layer = selected, !input.isActive {
                Divider()
                layerDetails(layer).id(layer.id)
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(AppPalette.warning) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .foregroundStyle(photosAdjustmentTextColor(in: colorScheme))
        .toggleStyle(PhotosFlatCheckboxStyle())
        .accessibilityElement(children: .contain).accessibilityIdentifier("photos.mask.panel")
    }
    private var layerList: some View {
        VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
            HStack {
                Text("图层").font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(layers.count, format: .number).font(.caption2).monospacedDigit()
            }.foregroundStyle(.secondary)
            if layers.isEmpty {
                Text("还没有蒙版。新建选区后，只调整照片中该区域。")
                    .photosInspectorParagraph().foregroundStyle(.secondary)
                    .accessibilityIdentifier("photos.mask.empty")
            }
            VStack(spacing: PhotosControlLayout.spacing) {
                ForEach(layers) { layer in layerRow(layer) }
            }
        }
    }
    private func layerRow(_ layer: DevelopmentMaskLayerV3) -> some View {
        let active = selected?.id == layer.id
        return HStack(spacing: 4) {
            Button {
                editing.selectDevelopmentScopeMask(layer.id)
            } label: {
                HStack(spacing: 6) {
                    PhotosMaskToolIcon(kind: .init(layer: layer))
                    Text(layer.name).lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(active ? AppPalette.accent : photosAdjustmentTextColor(in: colorScheme))
                .accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityIdentifier("photos.mask.layer." + layer.id.uuidString)
            Button {
                update(layer.id) { $0.enabled.toggle() }
            } label: {
                Image(systemName: layer.enabled ? "eye" : "eye.slash").foregroundStyle(.secondary)
            }.buttonStyle(PhotosFlatButtonStyle())
                .accessibilityLabel((layer.enabled ? "停用" : "启用") + layer.name)
                .accessibilityValue(layer.enabled ? "已启用" : "已停用").accessibilityAddTraits(.isToggle)
                .help(layer.enabled ? "停用图层（保留调整）" : "启用图层")
                .accessibilityIdentifier("photos.mask.layer.enabled." + layer.id.uuidString)
        }
        .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
        .background(active ? AppPalette.accent.opacity(0.13) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
        .disabled(input.isActive)
    }
    private func layerDetails(_ layer: DevelopmentMaskLayerV3) -> some View {
        VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(layer.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(layer.semanticSnapshot?.target.title ?? layer.kind.title)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button { move(layer.id, offset: -1) } label: { Label("上移", systemImage: "arrow.up") }
                        .disabled(layers.first?.id == layer.id)
                    Button { move(layer.id, offset: 1) } label: { Label("下移", systemImage: "arrow.down") }
                        .disabled(layers.last?.id == layer.id)
                    Divider()
                    Button(role: .destructive) { remove(layer.id) } label: { Label("删除图层", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("管理选中蒙版").accessibilityIdentifier("photos.mask.manage")
            }
            if layer.semanticSnapshot != nil {
                Button { input.review(layer, context: context) } label: { Label("查看与修正选区", systemImage: "pencil.and.outline") }
                    .buttonStyle(PhotosFlatButtonStyle(stretches: true))
                    .disabled(!input.allowsInput(context)).accessibilityIdentifier("photos.mask.review")
            }
            PhotosMaskControlGroup(title: "选区") { selectionControls(layer) }
            PhotosMaskControlGroup(title: "光效", initiallyExpanded: true) { lightControls(layer) }
            PhotosMaskControlGroup(title: "颜色") { colorControls(layer) }
            PhotosMaskControlGroup(title: "效果") { effectControls(layer) }
            PhotosMaskControlGroup(title: "细节") { detailControls(layer) }
            PhotosMaskControlGroup(title: "高级") { advancedControls(layer) }
        }
    }
    @ViewBuilder private func selectionControls(_ layer: DevelopmentMaskLayerV3) -> some View {
        Toggle("反转蒙版",isOn:.init(get:{layer.inverted},set:{value in update(layer.id){$0.inverted=value}})).font(.caption)
        row("不透明度",layer.id,0...1,layer.opacity){$0.opacity=$1}
        if layer.kind != .subject{row("羽化",layer.id,0...1,layer.feather){$0.feather=$1}}
        if layer.kind == .range{
            row("范围下限",layer.id,0...0.99,layer.rangeLower){$0.rangeLower=min($1,$0.rangeUpper-0.01)}
            row("范围上限",layer.id,0.01...1,layer.rangeUpper){$0.rangeUpper=max($1,$0.rangeLower+0.01)}
        }
    }
    @ViewBuilder private func lightControls(_ layer: DevelopmentMaskLayerV3) -> some View {
        row("曝光",layer.id,-2...2,layer.adjustments.exposure){$0.adjustments.exposure=$1}
        row("高光",layer.id,-1...1,layer.adjustments.highlights){$0.adjustments.highlights=$1}
        row("阴影",layer.id,-1...1,layer.adjustments.shadows){$0.adjustments.shadows=$1}
        row("对比度",layer.id,-1...1,layer.adjustments.contrast ?? 0){$0.adjustments.contrast=$1}
        row("白色",layer.id,-1...1,layer.adjustments.whites ?? 0){$0.adjustments.whites=$1}
        row("黑色",layer.id,-1...1,layer.adjustments.blacks ?? 0){$0.adjustments.blacks=$1}
    }
    @ViewBuilder private func colorControls(_ layer: DevelopmentMaskLayerV3) -> some View {
        row("色温",layer.id,-1...1,layer.adjustments.temperature ?? 0){$0.adjustments.temperature=$1}
        row("色调",layer.id,-1...1,layer.adjustments.tint ?? 0){$0.adjustments.tint=$1}
        row("色相",layer.id,-1...1,layer.adjustments.hue ?? 0){$0.adjustments.hue=$1}
            .accessibilityIdentifier("photos.mask.hue")
        Toggle("精细调整",isOn:.init(get:{layer.adjustments.fineAdjustment == true},set:{value in update(layer.id){$0.adjustments.fineAdjustment=value}}))
            .font(.caption).accessibilityIdentifier("photos.mask.fineAdjustment")
        row("饱和度",layer.id,-1...1,layer.adjustments.saturation){$0.adjustments.saturation=$1}
    }
    @ViewBuilder private func effectControls(_ layer: DevelopmentMaskLayerV3) -> some View {
        VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
        VStack(spacing: PhotosControlLayout.spacing) {
        row("纹理",layer.id,-1...1,layer.adjustments.texture ?? 0){$0.adjustments.texture=$1}
        row("清晰度",layer.id,-1...1,layer.adjustments.clarity ?? 0){$0.adjustments.clarity=$1}
        row("去朦胧",layer.id,-1...1,layer.adjustments.dehaze ?? 0){$0.adjustments.dehaze=$1}
            .accessibilityIdentifier("photos.mask.dehaze")
        row("颗粒数量",layer.id,0...1,layer.adjustments.grain ?? 0){$0.adjustments.grain=$1}
        row("颗粒大小",layer.id,0...1,layer.adjustments.grainSize ?? 0.25){$0.adjustments.grainSize=$1}
        row("颗粒粗糙度",layer.id,0...1,layer.adjustments.grainRoughness ?? 0.5){$0.adjustments.grainRoughness=$1}
        row("光晕数量",layer.id,0...1,layer.adjustments.glowAmount ?? 0){$0.adjustments.glowAmount=$1}
        }
        Text("光晕风格、范围、扩散、色温、方向与柔和度使用“效果”面板的全局共享设置。")
            .photosInspectorParagraph().foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func detailControls(_ layer: DevelopmentMaskLayerV3) -> some View {
        row("锐化",layer.id,-1...1,layer.adjustments.sharpness ?? 0){$0.adjustments.sharpness=$1}
        row("降噪",layer.id,0...1,layer.adjustments.noiseReduction ?? 0){$0.adjustments.noiseReduction=$1}
        row("摩尔纹减少",layer.id,0...1,layer.adjustments.moireReduction ?? 0){$0.adjustments.moireReduction=$1}
        row("去边／保护",layer.id,-1...1,layer.adjustments.defringe ?? 0){$0.adjustments.defringe=$1}
    }
    @ViewBuilder private func advancedControls(_ layer: DevelopmentMaskLayerV3) -> some View {
        Toggle("局部 Colorize",isOn:.init(get:{layer.adjustments.colorize != nil},set:{enabled in
            update(layer.id){ layer in
                layer.adjustments.colorize=enabled ? (layer.adjustments.colorize ?? .init(red:0.5,green:0.1,blue:0.05)):nil
                if enabled { layer.adjustments.colorizeAmount=layer.adjustments.colorizeAmount ?? 1 }
            }
        })).accessibilityIdentifier("photos.mask.colorize")
        if let colorize=layer.adjustments.colorize {
            ColorPicker("着颜色样",selection:.init(get:{
                Color(red:pow(colorize.red,1/2.2),green:pow(colorize.green,1/2.2),blue:pow(colorize.blue,1/2.2))
            },set:{ color in
                guard let rgb=NSColor(color).usingColorSpace(.sRGB)else{return}
                update(layer.id){$0.adjustments.colorize = .init(red:pow(Double(rgb.redComponent),2.2),green:pow(Double(rgb.greenComponent),2.2),blue:pow(Double(rgb.blueComponent),2.2))}
            }),supportsOpacity:false).font(.caption)
            row("着色强度",layer.id,0...1,layer.adjustments.colorizeAmount ?? 1){$0.adjustments.colorizeAmount=$1}
        }
        Toggle("局部 Curves",isOn:.init(get:{layer.adjustments.curves != nil},set:{enabled in
            update(layer.id){$0.adjustments.curves=enabled ? ($0.adjustments.curves ?? .init(enabled:true)):nil}
        })).accessibilityIdentifier("photos.mask.curves")
        if let curves=layer.adjustments.curves {
            PhotosMaskCurveEditor(curves:curves,onChange:{next in update(layer.id){$0.adjustments.curves=next}})
        }
        Toggle("局部 Color Grading",isOn:.init(get:{layer.adjustments.grading != nil},set:{enabled in
            update(layer.id){$0.adjustments.grading=enabled ? ($0.adjustments.grading ?? .init()):nil}
        })).accessibilityIdentifier("photos.mask.grading")
        if let grading=layer.adjustments.grading {
            PhotosMaskGradingEditor(grading:grading,onChange:{next in update(layer.id){$0.adjustments.grading=next}})
        }
        PhotosGradingLUTControls(session: session, context: context, maskID: layer.id).id(layer.id)
        let samples=session.parameters.selectiveColor.pointColors ?? []
        Toggle("局部 Point Color",isOn:.init(get:{layer.adjustments.pointColor != nil},set:{enabled in
            update(layer.id){ layer in
                if enabled { if layer.adjustments.pointColor==nil {layer.adjustments.pointColor=samples.first ?? .init(sampledColor:.init(red:0.5,green:0,blue:0))} }
                else {layer.adjustments.pointColor=nil}
            }
        })).accessibilityIdentifier("photos.mask.pointColor")
        if let point=layer.adjustments.pointColor {
            Picker("局部色样",selection:.init(get:{point.id},set:{id in
                guard let sample=samples.first(where:{$0.id==id})else{return}
                update(layer.id){$0.adjustments.pointColor=sample}
            })) {
                if !samples.contains(where:{$0.id==point.id}) { Text("当前独立色样").tag(point.id) }
                ForEach(samples) { sample in Text("色样 " + sample.id.uuidString.prefix(4)).tag(sample.id) }
            }
            row("局部色相",layer.id,-60...60,point.hue){$0.adjustments.pointColor?.hue=$1}
            row("局部饱和度",layer.id,-100...100,point.saturation){$0.adjustments.pointColor?.saturation=$1}
            row("局部明度",layer.id,-70...70,point.luminance){$0.adjustments.pointColor?.luminance=$1}
            row("局部范围",layer.id,0...2,point.range){$0.adjustments.pointColor?.range=$1}
            row("局部差异",layer.id,-100...100,point.variance ?? 0){$0.adjustments.pointColor?.variance=$1}
        }
    }
    private func row(_ title:String,_ id:UUID,_ range:ClosedRange<Double>,_ value:Double,mutation:@escaping(inout DevelopmentMaskLayerV3,Double)->Void)->some View{
        PhotosRecipeValueRow(session:session,context:context,title:title,control:"mask."+id.uuidString+"."+title,value:value,range:range,apply:{value,token in
            try apply(id,gesture:token,title:title){mutation(&$0,value)}
        },onError:{_ in errorText="蒙版调整未应用，请检查当前状态。"})
    }
    private func update(_ id: UUID, mutation: (inout DevelopmentMaskLayerV3) -> Void) {
        do { try apply(id, gesture: nil, title: "蒙版", mutation: mutation) }
        catch { errorText = "蒙版调整未应用，请重试。" }
    }
    private func apply(_ id:UUID,gesture:EditingGestureToken?,title:String,mutation:(inout DevelopmentMaskLayerV3)->Void)throws{
        var next=layers;guard let index=next.firstIndex(where:{$0.id==id})else{return};mutation(&next[index]);try DevelopmentMaskLayerV3.validateLayers(next)
        try session.apply(.setMasks(next),event:.init(context:context,control:.init(group:nil,name:"蒙版 · "+title),nativeInput:.capture(control:"mask.layer",phase:gesture == nil ? "discrete":"change",nativeEvent:true,gestureID:gesture?.id)),gesture:gesture);errorText=nil
    }
    private func remove(_ id: UUID) {
        var next = layers
        next.removeAll { $0.id == id }
        if commit(next, title: "删除蒙版") && editing.developmentScopeMaskID == id {
            editing.selectDevelopmentScopeMask(next.last?.id)
        }
    }
    private func move(_ id: UUID, offset: Int) {
        guard let index = layers.firstIndex(where: { $0.id == id }), layers.indices.contains(index + offset) else { return }
        var next = layers
        next.swapAt(index, index + offset)
        _ = commit(next, title: "蒙版排序")
    }
    private func commit(_ layers: [DevelopmentMaskLayerV3], title: String) -> Bool {
        do {
            try session.apply(.setMasks(layers), event: .init(context: context, control: .init(group: nil, name: title)))
            errorText = nil
            return true
        } catch {
            errorText = "\(title)未完成，请重试。"
            return false
        }
    }
}

private struct PhotosMaskControlGroup<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(title: String, initiallyExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _expanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.65)
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: PhotosControlLayout.spacing, content: content)
                    .padding(.top, 4)
            } label: {
                Text(title).font(.caption.weight(.semibold)).frame(minHeight: 22)
            }.accessibilityIdentifier("photos.mask.group." + title)
        }
    }
}
