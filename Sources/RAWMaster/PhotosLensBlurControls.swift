import SwiftUI
import RAWMasterCore

struct PhotosLensBlurControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    private enum Field: String, CaseIterable, Identifiable {
        case amount, focusX, focusY, focusRange, catEye, bokehBoost
        var id: String { rawValue }
        var title: String {
            switch self { case .amount: "模糊量"; case .focusX: "焦点 X"; case .focusY: "焦点 Y"; case .focusRange: "焦内范围";
                case .catEye: "Cat Eye 边缘形变"; case .bokehBoost: "失焦高亮增益" }
        }
    }
    private enum BrushField: String, CaseIterable, Identifiable {
        case amount, size, feather, flow
        var id: String { rawValue }
        var title: String { switch self { case .amount:"精修 Amount";case .size:"笔刷 Size";case .feather:"羽化 Feather";case .flow:"流量 Flow" } }
    }
    private var blur: DevelopmentLensBlurV3 { session.parameters.effects?.lensBlur ?? .init() }
    private var brush: DevelopmentLensBlurRefinementBrushV3 { blur.refinementBrush ?? .init() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Lens Blur", systemImage: "camera.aperture").font(.caption.weight(.semibold))
            Toggle("启用 Lens Blur", isOn: .init(get: { blur.enabled || editing.enablingSceneDepth == context }, set: { enabled in
                if !enabled && editing.enablingSceneDepth == context { editing.cancelEnablingSceneDepth(context: context) }
                else if enabled && !blur.enabled && blur.renderDepth == nil && editing.supportsSceneDepth {
                    editing.useDevelopmentSceneDepth(context: context, enabling: true)
                } else { apply(nil, enabled: enabled) }
            }))
                .accessibilityIdentifier("photos.effects.lensBlur.enabled")
            Picker("焦外光斑", selection: .init(get: { blur.bokehStyle ?? .circle }, set: { applyStyle($0) })) {
                ForEach(DevelopmentLensBokehStyleV3.allCases, id: \.self) { style in Text(styleTitle(style)).tag(style) }
            }.disabled(!blur.enabled).accessibilityIdentifier("photos.effects.lensBlur.bokehStyle")
            HStack(spacing: 12) {
                Button("点选焦点") { editing.beginDevelopmentPicker(.lensBlurFocus, context: context) }
                    .accessibilityIdentifier("photos.effects.lensBlur.pointFocus")
                Button("区域对焦") { editing.beginDevelopmentPicker(.lensBlurArea, context: context) }
                    .accessibilityIdentifier("photos.effects.lensBlur.areaFocus")
                Button("主体对焦") { editing.focusDevelopmentLensBlurSubject(context: context) }
                    .disabled(editing.developmentLensBlurSubjectFocusInProgress)
                    .accessibilityIdentifier("photos.effects.lensBlur.subjectFocus")
                if editing.developmentLensBlurSubjectFocusInProgress { ProgressView().controlSize(.mini) }
                Button(editing.developmentLensBlurDepthPreviewActive ? "退出深度可视化" : "可视化深度") {
                    editing.setDevelopmentLensBlurDepthPreview(!editing.developmentLensBlurDepthPreviewActive, context: context)
                }.accessibilityIdentifier("photos.effects.lensBlur.visualiseDepth")
            }.buttonStyle(.borderless).font(.caption)
            if editing.supportsSceneDepth && blur.deviceDepth == nil && blur.sceneDepth == nil {
                Button(editing.developmentDeviceDepthInProgress ? "正在估算场景深度…" : "估算场景深度") {
                    editing.useDevelopmentSceneDepth(context:context)
                }.disabled(!blur.enabled || editing.developmentDeviceDepthInProgress)
                 .accessibilityIdentifier("photos.effects.lensBlur.estimateSceneDepth")
            }
            if editing.developmentSourceFacts?.deviceDepthAvailable == true || blur.deviceDepth != nil {
                HStack(spacing: 8) {
                    Button(blur.deviceDepth == nil ? "使用设备深度" : "移除设备深度") {
                        if blur.deviceDepth == nil { editing.useDevelopmentDeviceDepth(context: context) }
                        else { editing.clearDevelopmentDeviceDepth(context: context) }
                    }.disabled(editing.developmentDeviceDepthInProgress)
                    .accessibilityIdentifier("photos.effects.lensBlur.useDeviceDepth")
                    if editing.developmentDeviceDepthInProgress { ProgressView().controlSize(.mini) }
                }.buttonStyle(.borderless).font(.caption)
            }
            ForEach(Field.allCases) { field in
                PhotosRecipeValueRow(session: session, context: context, title: field.title,
                    control: "effects.lensBlur." + field.rawValue, value: value(field) * 100, range: 0...100, step: 1, digits: 0,
                    apply: { number, token in apply(field, value: number / 100, gesture: token) }, onError: onError)
                    .disabled(!blur.enabled).accessibilityIdentifier("photos.effects.lensBlur." + field.rawValue)
            }
            Text("深度精修").font(.caption.weight(.semibold))
            HStack(spacing: 10) {
                Button("Focus 笔刷") { editing.beginDevelopmentPicker(.lensBlurRefineFocus, context: context) }
                    .accessibilityIdentifier("photos.effects.lensBlur.refineFocus")
                Button("Blur 笔刷") { editing.beginDevelopmentPicker(.lensBlurRefineBlur, context: context) }
                    .accessibilityIdentifier("photos.effects.lensBlur.refineBlur")
                Button("重置精修") { editing.resetDevelopmentLensBlurRefinements(context: context) }
                    .disabled((blur.refinementStrokes ?? []).isEmpty)
                    .accessibilityIdentifier("photos.effects.lensBlur.resetRefinements")
            }.buttonStyle(.borderless).font(.caption)
            Toggle("Auto Mask · 按刷涂点颜色约束边缘", isOn: .init(get: { brush.autoMask == true }, set: { applyAutoMask($0) }))
                .accessibilityIdentifier("photos.effects.lensBlur.brush.autoMask")
            ForEach(BrushField.allCases) { field in
                PhotosRecipeValueRow(session: session, context: context, title: field.title,
                    control: "effects.lensBlur.brush." + field.rawValue, value: brushValue(field) * 100, range: 0...100, step: 1, digits: 0,
                    apply: { number, token in applyBrush(field, value: number / 100, gesture: token) }, onError: onError)
                    .accessibilityIdentifier("photos.effects.lensBlur.brush." + field.rawValue)
            }
            Text("已记录 \((blur.refinementStrokes ?? []).count) 笔；Focus 减少失焦，Blur 增强失焦。Auto Mask 使用当前图像颜色，不执行 AI 推断。")
                .font(.caption2).foregroundStyle(.secondary)
            Text(blur.deviceDepth != nil ? "正在使用设备深度图。" :
                 (blur.sceneDepth != nil ? "正在使用 Depth Anything V2 估算的相对场景深度。" : "当前使用按位置计算的焦平面。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if editing.developmentSourceFacts?.deviceDepthAvailable == true {
                Text(blur.deviceDepth == nil ? "检测到设备深度图；可点击“使用设备深度”接入渲染。" : "设备深度图已读取并用于当前 Lens Blur。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("photos.effects.lensBlur.deviceDepthAvailable")
            }
        }.onDisappear { editing.cancelDevelopmentLensBlurDepthPreview() }
    }
    private func value(_ field: Field) -> Double {
        switch field { case .amount: blur.amount; case .focusX: blur.focusX; case .focusY: blur.focusY; case .focusRange: blur.focusRange;
            case .catEye: blur.catEyeAmount ?? 0; case .bokehBoost: blur.bokehBoost ?? 0 }
    }
    private func styleTitle(_ style:DevelopmentLensBokehStyleV3)->String {
        switch style {case .circle:"Circle 圆形";case .bubble:"Bubble 气泡";case .fiveBlade:"5-blade 五叶片";case .ring:"Ring 环形";case .anamorphic:"Anamorphic 变形宽银幕"}
    }
    private func applyStyle(_ style:DevelopmentLensBokehStyleV3) {
        do {
            var effects=session.parameters.effects ?? .init(),next=blur
            next.enabled=true;next.bokehStyle=style;try next.validate();effects.lensBlur=next
            try session.apply(.setEffects(effects),event:.init(context:context,control:.init(group:nil,name:"Lens Blur · 焦外光斑")))
        }catch{onError(error)}
    }
    private func brushValue(_ field: BrushField) -> Double {
        switch field { case .amount:brush.amount;case .size:brush.size;case .feather:brush.feather;case .flow:brush.flow }
    }
    private func applyAutoMask(_ enabled: Bool) {
        do {
            var effects=session.parameters.effects ?? .init(),next=blur,current=brush
            current.autoMask=enabled;next.enabled=true;next.refinementBrush=current;try next.validate();effects.lensBlur=next;try effects.validate()
            try session.apply(.setEffects(effects),event:.init(context:context,control:.init(group:nil,name:"Lens Blur · Auto Mask"),
                nativeInput:.capture(control:"effects.lensBlur.brush.autoMask",phase:"discrete",nativeEvent:true)))
        } catch { onError(error) }
    }
    private func applyBrush(_ field: BrushField, value: Double, gesture: EditingGestureToken?) {
        do {
            var effects=session.parameters.effects ?? .init(),next=blur,current=brush
            switch field { case .amount:current.amount=value;case .size:current.size=value;case .feather:current.feather=value;case .flow:current.flow=value }
            next.enabled=true;next.refinementBrush=current;try next.validate();effects.lensBlur=next;try effects.validate()
            try session.apply(.setEffects(effects),event:.init(context:context,
                control:.init(group:nil,name:"Lens Blur · 精修笔刷参数"),
                nativeInput:.capture(control:"effects.lensBlur.brush",phase:gesture == nil ? "discrete":"change",nativeEvent:true,gestureID:gesture?.id)),gesture:gesture)
        } catch { onError(error) }
    }
    private func apply(_ field: Field?, value: Double = 0, enabled: Bool = true, gesture: EditingGestureToken? = nil) {
        do {
            var effects = session.parameters.effects ?? .init(), next = blur
            if let field {
                switch field { case .amount: next.amount = value; case .focusX: next.focusX = value; case .focusY: next.focusY = value; case .focusRange: next.focusRange = value;
                    case .catEye: next.catEyeAmount = value; case .bokehBoost: next.bokehBoost = value }
            }
            next.enabled = enabled; try next.validate(); effects.lensBlur = next; try effects.validate()
            try session.apply(.setEffects(effects), event: .init(context: context,
                control: .init(group: nil, name: "效果 · Lens Blur"),
                nativeInput: .capture(control: "effects.lensBlur", phase: gesture == nil ? "discrete" : "change", nativeEvent: true, gestureID: gesture?.id)), gesture: gesture)
        } catch { onError(error) }
    }
}
