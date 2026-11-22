import SwiftUI
import RAWMasterCore
import RAWMasterImaging

/// Curve editor bound to one mask, never to the global Development session curves.
struct PhotosMaskCurveEditor: View {
  let curves:DevelopmentCurvesV3
  let onChange:(DevelopmentCurvesV3)->Void
  @State private var channel:DevelopmentCurveChannel = .rgb
  @State private var selected=0
  private var path:WritableKeyPath<DevelopmentCurvesV3,DevelopmentCurveChannelV3>{
    switch channel{case .rgb:\.rgb;case .red:\.red;case .green:\.green;case .blue:\.blue}
  }
  private var current:DevelopmentCurveChannelV3{curves[keyPath:path]}
  var body:some View{
    VStack(alignment:.leading,spacing:8){
      Picker("局部曲线通道",selection:$channel){ForEach(DevelopmentCurveChannel.allCases){Text($0.rawValue).tag($0)}}
        .pickerStyle(.segmented).onChange(of:channel){_,_ in selected=0}
      PhotosMaskCurveCanvas(curves:curves,channel:channel,selected:$selected,onChange:update)
        .frame(height:160).accessibilityIdentifier("photos.mask.curves.canvas")
      HStack{
        Button("添加点"){if let(next,index)=DevelopmentCurveInteraction.midpoint(current.curve,displayModel:displayModel){update(next);selected=index}}
          .disabled(current.curve.points.count>=16)
        Button("删除点"){if let next=DevelopmentCurveInteraction.deleting(current.curve,index:selected){update(next);selected=max(0,selected-1)}}
          .disabled(selected<=0 || selected>=current.curve.points.count-1)
        Button("复位当前通道"){if let next=try? PhotosCurveParameterControls.resetting(curves,channel:channel){write(next);selected=0}}
      }.buttonStyle(.borderless).font(.caption)
      if current.curve.points.indices.contains(selected){
        let point=current.curve.points[selected]
        Text("点 \(selected+1) · 输入 \(point.x.formatted(.number.precision(.fractionLength(3)))) · 输出 \(point.y.formatted(.number.precision(.fractionLength(3))))")
          .font(.caption2).foregroundStyle(.secondary)
      }
      endpoint("输入黑点",value:current.inputBlack,upper:max(0,current.inputWhite.nextDown),black:true)
      endpoint("输入白点",value:current.inputWhite,lower:min(1,current.inputBlack.nextUp),black:false)
    }
  }
  private var displayModel:DevelopmentCurveDisplayModel?{
    guard curves.algorithm == .naturalCubicGamma512LumaV1 else{return nil}
    return try? .init(curve:current.curve,algorithm:.naturalCubicGamma512LumaV1)
  }
  private func update(_ curve:DevelopmentCurve){var next=curves;next[keyPath:path].curve=curve;write(next)}
  private func write(_ value:DevelopmentCurvesV3){
    var next=value.forDirectUserEdit();next.enabled=true
    guard (try? next.validate()) != nil else{return};onChange(next)
  }
  private func endpoint(_ title:String,value:Double,upper:Double=1,lower:Double=0,black:Bool)->some View{
    HStack{Text(title).font(.caption2);Slider(value:.init(get:{value},set:{number in
      var next=curves
      if black{next[keyPath:path].inputBlack=min(number,next[keyPath:path].inputWhite.nextDown)}
      else{next[keyPath:path].inputWhite=max(number,next[keyPath:path].inputBlack.nextUp)}
      write(next)
    }),in:lower...upper)}
  }
}

private struct PhotosMaskCurveCanvas:View{
  let curves:DevelopmentCurvesV3
  let channel:DevelopmentCurveChannel
  @Binding var selected:Int
  let onChange:(DevelopmentCurve)->Void
  @State private var dragging=false
  private var path:WritableKeyPath<DevelopmentCurvesV3,DevelopmentCurveChannelV3>{
    switch channel{case .rgb:\.rgb;case .red:\.red;case .green:\.green;case .blue:\.blue}
  }
  private var curve:DevelopmentCurve{curves[keyPath:path].curve}
  var body:some View{
    GeometryReader{proxy in
      Canvas{context,size in
        let rect=CGRect(origin:.zero,size:size).insetBy(dx:10,dy:10)
        context.stroke(Path(rect),with:.color(.secondary.opacity(0.35)))
        var diagonal=Path();diagonal.move(to:CGPoint(x:rect.minX,y:rect.maxY));diagonal.addLine(to:CGPoint(x:rect.maxX,y:rect.minY))
        context.stroke(diagonal,with:.color(.secondary.opacity(0.25)),style:.init(dash:[3,3]))
        var line=Path();var started=false
        let model=curves.algorithm == .naturalCubicGamma512LumaV1 ? try? DevelopmentCurveDisplayModel(curve:curve,algorithm:.naturalCubicGamma512LumaV1):nil
        for index in 0...128{
          let x=Double(index)/128
          let value=(try? model?.value(at:x)) ?? (try? curve.value(at:x))
          guard let value else{continue}
          let point=CGPoint(x:rect.minX+x*rect.width,y:rect.maxY-value*rect.height)
          if started{line.addLine(to:point)}else{line.move(to:point);started=true}
        }
        context.stroke(line,with:.color(color),lineWidth:2)
        for(index,point)in curve.points.enumerated(){
          let center=CGPoint(x:rect.minX+point.x*rect.width,y:rect.maxY-point.y*rect.height),radius=index==selected ? 5.0:3.5
          let dot=Path(ellipseIn:CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
          context.fill(dot,with:.color(index==selected ? .accentColor:color))
        }
      }.background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:6))
        .gesture(DragGesture(minimumDistance:0).onChanged{event in
          let location=event.location,rect=CGRect(origin:.zero,size:proxy.size).insetBy(dx:10,dy:10)
          func point(_ index:Int)->CGPoint{let p=curve.points[index];return .init(x:rect.minX+p.x*rect.width,y:rect.maxY-p.y*rect.height)}
          if !dragging{
            dragging=true
            if let nearest=curve.points.indices.min(by:{hypot(point($0).x-location.x,point($0).y-location.y)<hypot(point($1).x-location.x,point($1).y-location.y)}),
               hypot(point(nearest).x-location.x,point(nearest).y-location.y)<=20{selected=nearest}
            else{
              let candidate=DevelopmentCurvePoint(x:(location.x-rect.minX)/rect.width,y:(rect.maxY-location.y)/rect.height)
              if let(_,index)=DevelopmentCurveInteraction.adding(curve,x:candidate.x,y:candidate.y){selected=index}
            }
          }
          guard curve.points.indices.contains(selected)else{return}
          let moved=DevelopmentCurveInteraction.moving(curve,index:selected,x:(location.x-rect.minX)/rect.width,y:(rect.maxY-location.y)/rect.height)
          if let moved{onChange(moved)}
        }.onEnded{_ in dragging=false})
    }
  }
  private var color:Color{switch channel{case .rgb:.primary;case .red:.red;case .green:.green;case .blue:.blue}}
}
