import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct PhotosMaskControls:View{
    @ObservedObject var editing:EditingController
    @ObservedObject var session:EditingDevelopmentSession
    let context:EditingInteractionContext
    @State private var errorText:String?
    private var layers:[DevelopmentMaskLayerV3]{session.parameters.masks}
    private var selected:DevelopmentMaskLayerV3?{layers.first{$0.id==editing.developmentScopeMaskID} ?? layers.last}
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Label("蒙版",systemImage:"circle.lefthalf.filled").font(.system(size:13,weight:.semibold))
            PhotosAIMaskControls(input:editing.developmentMaskInput,session:session,context:context,selected:selected)
            HStack(spacing:6){
                Button{editing.developmentMaskInput.select(.linear,context:context)}label:{Label("线性",systemImage:"line.diagonal")}
                    .background(editing.developmentMaskInput.activeKind == .linear ? AppPalette.accent.opacity(0.2):Color.clear,in:RoundedRectangle(cornerRadius:5))
                Button{editing.developmentMaskInput.select(.radial,context:context)}label:{Label("径向",systemImage:"circle.dashed")}
                    .background(editing.developmentMaskInput.activeKind == .radial ? AppPalette.accent.opacity(0.2):Color.clear,in:RoundedRectangle(cornerRadius:5))
                Button{editing.addDevelopmentMask(.range,context:context)}label:{Label("范围",systemImage:"slider.horizontal.3")}
            }.buttonStyle(.borderless).font(.caption)
            if editing.developmentMaskInput.activeKind != nil{Text("在照片上拖动以确定选取范围，按 Escape 取消。").font(.caption).foregroundStyle(.secondary)}
            Divider()
            if layers.isEmpty{Text("新建一个蒙版后，可独立调整曝光、高光、阴影、饱和度和光晕数量。").font(.caption).foregroundStyle(.secondary)}
            ForEach(layers){layer in
                HStack(spacing:6){
                    Toggle("",isOn:.init(get:{layer.enabled},set:{value in update(layer.id){$0.enabled=value}})).labelsHidden().toggleStyle(.checkbox)
                    Button{editing.selectDevelopmentScopeMask(layer.id)}label:{Text(layer.name).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)}
                        .buttonStyle(.plain).foregroundStyle(selected?.id == layer.id ? AppPalette.accent:.primary)
                    Button{move(layer.id,offset:-1)}label:{Image(systemName:"chevron.up")}.disabled(layers.first?.id==layer.id)
                    Button{move(layer.id,offset:1)}label:{Image(systemName:"chevron.down")}.disabled(layers.last?.id==layer.id)
                    Button{remove(layer.id)}label:{Image(systemName:"trash")}.accessibilityLabel("删除"+layer.name)
                }.buttonStyle(.borderless).font(.caption)
            }
            if let layer=selected{
                Divider()
                Text(layer.semanticSnapshot?.target.title ?? layer.kind.title).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                Toggle("反转蒙版",isOn:.init(get:{layer.inverted},set:{value in update(layer.id){$0.inverted=value}})).font(.caption)
                row("不透明度",layer.id,0...1,layer.opacity){$0.opacity=$1}
                if layer.kind != .subject{row("羽化",layer.id,0...1,layer.feather){$0.feather=$1}}
                if layer.kind == .range{
                    row("范围下限",layer.id,0...0.99,layer.rangeLower){$0.rangeLower=min($1,$0.rangeUpper-0.01)}
                    row("范围上限",layer.id,0.01...1,layer.rangeUpper){$0.rangeUpper=max($1,$0.rangeLower+0.01)}
                }
                row("曝光",layer.id,-2...2,layer.adjustments.exposure){$0.adjustments.exposure=$1}
                row("高光",layer.id,-1...1,layer.adjustments.highlights){$0.adjustments.highlights=$1}
                row("阴影",layer.id,-1...1,layer.adjustments.shadows){$0.adjustments.shadows=$1}
                row("对比度",layer.id,-1...1,layer.adjustments.contrast ?? 0){$0.adjustments.contrast=$1}
                row("白色",layer.id,-1...1,layer.adjustments.whites ?? 0){$0.adjustments.whites=$1}
                row("黑色",layer.id,-1...1,layer.adjustments.blacks ?? 0){$0.adjustments.blacks=$1}
                row("色温",layer.id,-1...1,layer.adjustments.temperature ?? 0){$0.adjustments.temperature=$1}
                row("色调",layer.id,-1...1,layer.adjustments.tint ?? 0){$0.adjustments.tint=$1}
                row("色相",layer.id,-1...1,layer.adjustments.hue ?? 0){$0.adjustments.hue=$1}
                    .accessibilityIdentifier("photos.mask.hue")
                Toggle("精细调整",isOn:.init(get:{layer.adjustments.fineAdjustment == true},set:{value in update(layer.id){$0.adjustments.fineAdjustment=value}}))
                    .font(.caption).accessibilityIdentifier("photos.mask.fineAdjustment")
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
                row("饱和度",layer.id,-1...1,layer.adjustments.saturation){$0.adjustments.saturation=$1}
                row("纹理",layer.id,-1...1,layer.adjustments.texture ?? 0){$0.adjustments.texture=$1}
                row("清晰度",layer.id,-1...1,layer.adjustments.clarity ?? 0){$0.adjustments.clarity=$1}
                row("去朦胧",layer.id,-1...1,layer.adjustments.dehaze ?? 0){$0.adjustments.dehaze=$1}
                    .accessibilityIdentifier("photos.mask.dehaze")
                row("颗粒数量",layer.id,0...1,layer.adjustments.grain ?? 0){$0.adjustments.grain=$1}
                row("颗粒大小",layer.id,0...1,layer.adjustments.grainSize ?? 0.25){$0.adjustments.grainSize=$1}
                row("颗粒粗糙度",layer.id,0...1,layer.adjustments.grainRoughness ?? 0.5){$0.adjustments.grainRoughness=$1}
                row("锐化",layer.id,-1...1,layer.adjustments.sharpness ?? 0){$0.adjustments.sharpness=$1}
                row("降噪",layer.id,0...1,layer.adjustments.noiseReduction ?? 0){$0.adjustments.noiseReduction=$1}
                row("摩尔纹减少",layer.id,0...1,layer.adjustments.moireReduction ?? 0){$0.adjustments.moireReduction=$1}
                row("去边／保护",layer.id,-1...1,layer.adjustments.defringe ?? 0){$0.adjustments.defringe=$1}
                row("光晕数量",layer.id,0...1,layer.adjustments.glowAmount ?? 0){$0.adjustments.glowAmount=$1}
                Text("光晕风格、范围、扩散、色温、方向与柔和度使用“效果”面板的全局共享设置。")
                    .font(.caption).foregroundStyle(.secondary)
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
            if let errorText{Text(errorText).font(.caption).foregroundStyle(AppPalette.warning)}
        }.padding(16)
    }
    private func row(_ title:String,_ id:UUID,_ range:ClosedRange<Double>,_ value:Double,mutation:@escaping(inout DevelopmentMaskLayerV3,Double)->Void)->some View{
        PhotosRecipeValueRow(session:session,context:context,title:title,control:"mask."+id.uuidString+"."+title,value:value,range:range,apply:{value,token in
            try apply(id,gesture:token,title:title){mutation(&$0,value)}
        },onError:{_ in errorText="蒙版调整未应用，请检查当前状态。"})
    }
    private func update(_ id:UUID,mutation:(inout DevelopmentMaskLayerV3)->Void){try?apply(id,gesture:nil,title:"蒙版",mutation:mutation)}
    private func apply(_ id:UUID,gesture:EditingGestureToken?,title:String,mutation:(inout DevelopmentMaskLayerV3)->Void)throws{
        var next=layers;guard let index=next.firstIndex(where:{$0.id==id})else{return};mutation(&next[index]);try DevelopmentMaskLayerV3.validateLayers(next)
        try session.apply(.setMasks(next),event:.init(context:context,control:.init(group:nil,name:"蒙版 · "+title),nativeInput:.capture(control:"mask.layer",phase:gesture == nil ? "discrete":"change",nativeEvent:true,gestureID:gesture?.id)),gesture:gesture);errorText=nil
    }
    private func remove(_ id:UUID){var next=layers;next.removeAll{$0.id==id};try?session.apply(.setMasks(next),event:.init(context:context,control:.init(group:nil,name:"删除蒙版")));if editing.developmentScopeMaskID==id{editing.selectDevelopmentScopeMask(nil)}}
    private func move(_ id:UUID,offset:Int){guard let index=layers.firstIndex(where:{$0.id==id})else{return};var next=layers;let target=index+offset;guard next.indices.contains(target)else{return};next.swapAt(index,target);try?session.apply(.setMasks(next),event:.init(context:context,control:.init(group:nil,name:"蒙版排序")))}
}
