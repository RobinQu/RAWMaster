import AppKit
import SwiftUI
import RAWMasterCore

/// Color grading editor owned by one mask; no global recipe references.
struct PhotosMaskGradingEditor:View{
  let grading:DevelopmentColorGrading
  let onChange:(DevelopmentColorGrading)->Void
  @State private var region:DevelopmentGradingRegion = .shadows
  private var wheel:DevelopmentGradingWheel{grading[keyPath:region.path]}
  var body:some View{
    VStack(alignment:.leading,spacing:8){
      Picker("局部分级区域",selection:$region){ForEach(DevelopmentGradingRegion.allCases){Text($0.rawValue).tag($0)}}
        .pickerStyle(.segmented).accessibilityIdentifier("photos.mask.grading.region")
      PhotosMaskGradingWheel(wheel:wheel,region:region,onChange:updateWheel)
        .frame(height:160).accessibilityIdentifier("photos.mask.grading.wheel")
      HStack{
        RoundedRectangle(cornerRadius:4).fill(Color(nsColor:DevelopmentGradingFeedback.color(hue:wheel.hueDegrees,saturation:wheel.saturation,luminance:wheel.luminance)))
          .frame(width:34,height:22).overlay(RoundedRectangle(cornerRadius:4).stroke(Color.secondary.opacity(0.3)))
        Button("复位此区域"){updateWheel(.init())}.buttonStyle(.borderless).font(.caption)
      }
      component("色相 °",path:\.hueDegrees,range:0...360)
      component("饱和度",path:\.saturation,range:0...100)
      component("亮度",path:\.luminance,range:-100...100)
      mix("混合",value:grading.blending,range:0...100,balance:false)
      mix("平衡",value:grading.balance,range:-100...100,balance:true)
    }
  }
  private func updateWheel(_ value:DevelopmentGradingWheel){var next=grading;next[keyPath:region.path]=value;write(next)}
  private func component(_ title:String,path:WritableKeyPath<DevelopmentGradingWheel,Double>,range:ClosedRange<Double>)->some View{
    HStack{Text(title).font(.caption2);Slider(value:.init(get:{wheel[keyPath:path]},set:{value in var next=wheel;next[keyPath:path]=value;updateWheel(next)}),in:range)}
  }
  private func mix(_ title:String,value:Double,range:ClosedRange<Double>,balance:Bool)->some View{
    HStack{Text(title).font(.caption2);Slider(value:.init(get:{value},set:{number in var next=grading;if balance{next.balance=number}else{next.blending=number};write(next)}),in:range)}
  }
  private func write(_ value:DevelopmentColorGrading){guard (try? value.validate()) != nil else{return};onChange(value)}
}

private struct PhotosMaskGradingWheel:NSViewRepresentable{
  let wheel:DevelopmentGradingWheel
  let region:DevelopmentGradingRegion
  let onChange:(DevelopmentGradingWheel)->Void
  func makeNSView(context:Context)->DevelopmentGradingControl{DevelopmentGradingControl(frame:.zero)}
  func updateNSView(_ view:DevelopmentGradingControl,context:Context){
    view.wheel=wheel;view.onChange=onChange
    view.setAccessibilityLabel("蒙版"+region.rawValue+"色轮")
    view.setAccessibilityValue("色相 \(wheel.hueDegrees.formatted()) 度，饱和度 \(wheel.saturation.formatted())，亮度 \(wheel.luminance.formatted())")
    view.needsDisplay=true
  }
  static func dismantleNSView(_ view:DevelopmentGradingControl,coordinator:()){view.cancelTracking()}
}
