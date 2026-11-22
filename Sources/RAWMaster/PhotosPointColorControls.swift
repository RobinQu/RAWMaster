import SwiftUI
import RAWMasterCore

struct PhotosPointColorControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onAdd: () -> Void
    let onError: (Error) -> Void
    @State private var selectedID: UUID?
    private var samples: [DevelopmentPointColorSampleV3] { session.parameters.selectiveColor.pointColors ?? [] }
    private var selected: DevelopmentPointColorSampleV3? { samples.first(where:{$0.id==selectedID}) ?? samples.last }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("独立 Point Color").font(.caption.weight(.semibold))
                Spacer()
                Button("添加色样", action: onAdd).disabled(samples.count>=8)
                    .accessibilityIdentifier("photos.pointColor.add")
            }
            if samples.isEmpty { Text("从照片建立独立颜色样本，不占用固定 HSL 色域。").font(.caption2).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                ForEach(samples) { sample in
                    Button { selectedID=sample.id } label: {
                        Circle().fill(color(sample.sampledColor)).frame(width: 20,height: 20)
                            .overlay(Circle().stroke(selected?.id==sample.id ? Color.white:Color.clear,lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityLabel("独立颜色样本")
                }
            }
            if let sample=selected {
                row("色相", value: sample.hue, range: -60...60, path: \.hue)
                row("饱和度", value: sample.saturation, range: -100...100, path: \.saturation)
                row("明度", value: sample.luminance, range: -70...70, path: \.luminance)
                row("范围", value: sample.range, range: 0...2, path: \.range)
                PhotosTypedValueRow(session: session, context: context, group: .selectiveColor,
                    name: "差异", value: sample.variance ?? 0, range: -100...100, command: { value in
                        try update(sample.id){$0.variance=value}
                    }, onError: onError)
                Button("删除当前色样") { remove(sample.id) }.buttonStyle(.borderless).font(.caption)
                    .accessibilityIdentifier("photos.pointColor.remove")
            }
        }.id(context)
    }
    private func row(_ title: String, value: Double, range: ClosedRange<Double>,
                     path: WritableKeyPath<DevelopmentPointColorSampleV3,Double>) -> some View {
        PhotosTypedValueRow(session: session, context: context, group: .selectiveColor,
            name: title, value: value, range: range, command: { value in
                try update(selected?.id){$0[keyPath:path]=value}
            }, onError: onError)
    }
    private func update(_ id: UUID?, mutation: (inout DevelopmentPointColorSampleV3)->Void)throws->DevelopmentAdjustmentCommand {
        guard let id else{throw EditingError.invalidRecipe}
        var next=session.parameters.selectiveColor;var samples=next.pointColors ?? []
        guard let index=samples.firstIndex(where:{$0.id==id})else{throw EditingError.invalidRecipe}
        mutation(&samples[index]);next.pointColors=samples;next.enabled=true;try next.validate()
        return .setParameters(.selectiveColor(next))
    }
    private func remove(_ id: UUID) {
        var next=session.parameters.selectiveColor;next.pointColors=(next.pointColors ?? []).filter{$0.id != id}
        do{try session.apply(.setParameters(.selectiveColor(next)),event:.init(context:context,control:.init(group:.selectiveColor,name:"删除独立颜色样本")));selectedID=nil}catch{onError(error)}
    }
    private func color(_ sample: DevelopmentSampledColorV3) -> Color {
        func channel(_ value: Double)->Double{pow(max(0,min(1,value)),1/2.2)}
        return Color(red:channel(sample.red),green:channel(sample.green),blue:channel(sample.blue))
    }
}
