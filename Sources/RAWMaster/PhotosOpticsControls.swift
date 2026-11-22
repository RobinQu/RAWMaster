import SwiftUI
import RAWMasterCore

struct PhotosOpticsControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    @ObservedObject var profileDefaults: DevelopmentLensProfileDefaultsStore
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    let onPicker: (DevelopmentDefringeBandV3) -> Void
    let lensMetadata: DevelopmentLensMetadata?
    private var value: DevelopmentDefringeV3 { session.parameters.optics?.defringe ?? .init() }
    private var profile:DevelopmentLensProfileV3?{session.parameters.optics?.lensProfile}
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("镜头配置").font(.caption.weight(.semibold))
            Toggle("启用镜头配置校正",isOn:.init(get:{session.parameters.optics?.lensProfileEnabled == true},set:{enabled in
                update{$0.lensProfileEnabled=enabled}
            })).accessibilityIdentifier("photos.optics.profileEnabled")
            Button("按 EXIF 自动匹配", action: matchMetadata)
              .disabled(DevelopmentLensProfileCatalogV3.match(lensMetadata)==nil).font(.caption)
              .accessibilityIdentifier("photos.optics.profileMatch")
            profilePickers()
            if profile != nil {
                profileAmount("配置畸变强度",value:session.parameters.optics?.profileDistortionAmount ?? 1,vignetting:false)
                profileAmount("配置晕影强度",value:session.parameters.optics?.profileVignettingAmount ?? 1,vignetting:true)
                HStack(spacing: 12) {
                    Button("保存为新默认值") { saveProfileDefaults() }
                    Button("恢复内置默认值") { resetProfileDefaults() }
                }.buttonStyle(.borderless).font(.caption)
                .accessibilityIdentifier("photos.optics.profileDefaults")
            }
            if session.parameters.optics?.lensProfileEnabled == true && profile == nil {
                Text("没有已匹配配置；请手动选择。内置系数为 RawMaster 近似值。").font(.caption2).foregroundStyle(.secondary)
            }
            Text("镜头晕影校正（非创作型）").font(.caption2).foregroundStyle(.secondary)
            PhotosTypedValueRow(session:session,context:context,group:.optics,name:"镜头晕影校正量",
              value:(session.parameters.optics?.lensVignettingAmount ?? 0)*100,range:0...200,step:1,digits:1,command:{number in
                var next=session.parameters.optics ?? .init();next.lensVignettingAmount=number/100
                try next.validate();return .setParameters(.optics(next))
              },onError:onError).accessibilityIdentifier("photos.optics.lensVignettingAmount")
            PhotosTypedValueRow(session:session,context:context,group:.optics,name:"镜头晕影中点",
              value:(session.parameters.optics?.lensVignettingMidpoint ?? 0.5)*100,range:0...100,step:1,digits:1,command:{number in
                var next=session.parameters.optics ?? .init();next.lensVignettingMidpoint=number/100
                try next.validate();return .setParameters(.optics(next))
              },onError:onError).accessibilityIdentifier("photos.optics.lensVignettingMidpoint")
            Toggle("移除色差",isOn:.init(get:{session.parameters.optics?.removeChromaticAberration == true},set:{enabled in
                update{$0.removeChromaticAberration=enabled}
            })).accessibilityIdentifier("photos.optics.removeCA")
            PhotosTypedValueRow(session:session,context:context,group:.optics,name:"畸变校正",
              value:(session.parameters.optics?.distortion ?? 0)*100,range:-100...100,step:1,digits:1,command:{number in
                var next=session.parameters.optics ?? .init();next.distortion=number/100
                try next.validate();return .setParameters(.optics(next))
              },onError:onError).accessibilityIdentifier("photos.optics.distortion")
            Text("去除色边").font(.caption.weight(.semibold))
            row("紫色强度", value: value.purpleAmount, range: 0...100) { $0.purpleAmount=$1 }
            row("绿色强度", value: value.greenAmount, range: 0...100) { $0.greenAmount=$1 }
            rangeRows("紫色", lower: value.purpleHueLower, upper: value.purpleHueUpper,
              lowerPath: \.purpleHueLower, upperPath: \.purpleHueUpper)
            rangeRows("绿色", lower: value.greenHueLower, upper: value.greenHueUpper,
              lowerPath: \.greenHueLower, upperPath: \.greenHueUpper)
            HStack(spacing: 12) {
                Button("选取紫色边") { onPicker(.purple) }.accessibilityIdentifier("photos.optics.defringe.purplePicker")
                Button("选取绿色边") { onPicker(.green) }.accessibilityIdentifier("photos.optics.defringe.greenPicker")
            }.buttonStyle(.borderless).font(.caption)
            Text("Defringe 使用 RawMaster 的色带与局部边缘近似模型。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func profilePickers()->some View{
        let profiles=DevelopmentLensProfileCatalogV3.profiles
        let make=profile?.make ?? profiles[0].make
        let models=profiles.filter{$0.make==make}
        let model=profile?.model ?? models[0].model
        let visible=profiles.filter{$0.make==make && $0.model==model}
        Picker("制造商",selection:.init(get:{make},set:{value in
            if let first=profiles.first(where:{$0.make==value}){select(first)}
        })){ForEach(Set(profiles.map(\.make)).sorted(),id:\.self){Text($0).tag($0)}}
        Picker("型号",selection:.init(get:{model},set:{value in
            if let first=profiles.first(where:{$0.make==make && $0.model==value}){select(first)}
        })){ForEach(models.map(\.model),id:\.self){Text($0).tag($0)}}
        Picker("配置文件",selection:.init(get:{profile?.id ?? visible[0].id},set:{value in
            if let selected=DevelopmentLensProfileCatalogV3.profile(id:value){select(selected)}
        })){ForEach(visible){Text($0.name).tag($0.id)}}.accessibilityIdentifier("photos.optics.profile")
    }
    func matchMetadata() {
        if let match = DevelopmentLensProfileCatalogV3.match(lensMetadata) { select(match) }
    }
    func select(_ value:DevelopmentLensProfileV3){
        update{$0=PhotosOpticsProfileSelection.applying(value,to:$0,defaults:profileDefaults)}
    }
    func saveProfileDefaults(){
        guard let profile else{return}
        let optics=session.parameters.optics ?? .init()
        let value=DevelopmentLensProfileDefaultsV1(enabled:optics.lensProfileEnabled == true,
            distortion:optics.profileDistortionAmount ?? 1,vignetting:optics.profileVignettingAmount ?? 1)
        do{try profileDefaults.save(value,for:profile)}catch{onError(error)}
    }
    func resetProfileDefaults(){
        guard let profile else{return}
        do{try profileDefaults.reset(for:profile);select(profile)}catch{onError(error)}
    }
    private func profileAmount(_ title:String,value:Double,vignetting:Bool)->some View{
        PhotosTypedValueRow(session:session,context:context,group:.optics,name:title,value:value*100,range:0...200,step:1,digits:1,command:{number in
            var next=session.parameters.optics ?? .init()
            if vignetting{next.profileVignettingAmount=number/100}else{next.profileDistortionAmount=number/100}
            try next.validate();return .setParameters(.optics(next))
        },onError:onError)
    }
    private func rangeRows(_ title: String, lower: Double, upper: Double,
                           lowerPath: WritableKeyPath<DevelopmentDefringeV3,Double>,
                           upperPath: WritableKeyPath<DevelopmentDefringeV3,Double>) -> some View {
        let width=upper-lower, center=(lower+upper)/2
        return Group {
            row(title+"起点", value: lower, range: 0...359) { $0[keyPath: lowerPath]=min($1,$0[keyPath: upperPath]-1) }
            row(title+"终点", value: upper, range: 1...360) { $0[keyPath: upperPath]=max($1,$0[keyPath: lowerPath]+1) }
            row(title+"整体位置", value: center, range: width/2...(360-width/2)) { model, number in
                model[keyPath: lowerPath]=number-width/2;model[keyPath: upperPath]=number+width/2
            }
        }
    }
    private func update(_ mutation:(inout DevelopmentOpticsV3)->Void){
        var next=session.parameters.optics ?? .init();mutation(&next)
        do{try next.validate();try session.apply(.setParameters(.optics(next)),event:.init(context:context,control:.init(group:.optics,name:"光学校正")))}catch{onError(error)}
    }
    private func row(_ title: String, value: Double, range: ClosedRange<Double>,
                     mutation: @escaping (inout DevelopmentDefringeV3,Double)->Void) -> some View {
        PhotosTypedValueRow(session: session, context: context, group: .optics, name: title,
            value: value, range: range, step: 1, digits: 1, command: { number in
                var next=session.parameters.optics ?? .init()
                mutation(&next.defringe,number);next.defringe.enabled=true
                try next.validate();return .setParameters(.optics(next))
            }, onError: onError)
    }
}
