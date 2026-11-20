import Foundation
import CryptoKit
import Darwin
import RAWMasterCore

/// Preparation only. Durable replay remains the existing manual source-space RedEye operator.
enum DevelopmentRedEyeAutomaticV3 {
  static let version = "red-eye-auto-v1/proxy1536/component8/support32-annulus64/refine-native/cap256-eyes64"
  static let maximumCandidates = 256, maximumEyes = 64
  struct Candidate {
    var x,y,radius: Double
    var score: Double = 0
    var component: Int32
    var qualified = false, paired = false
  }
  final class Circles {
    let storage: DevelopmentLocalAllocationV3
    let count: Int
    let statistics: Statistics
    init(storage:DevelopmentLocalAllocationV3,count:Int,statistics:Statistics) { self.storage=storage;self.count=count;self.statistics=statistics }
    subscript(_ i:Int)->Candidate { storage.pointer.assumingMemoryBound(to:Candidate.self)[i] }
  }
  struct Statistics {
    var proxyWidth=0,proxyHeight=0,visible=0,redPixels=0,components=0,geometric=0,nativeQualified=0,accepted=0
    var peakAnalysisBytes=0,peakMetadataBytes=0
    mutating func observe(_ sampler:DevelopmentLocalAnalysisV3.Sampler) { let s=DevelopmentLocalChargeV3.snapshot();peakAnalysisBytes=max(peakAnalysisBytes,max(s.analysis,sampler.peakAnalysisBytes));peakMetadataBytes=max(peakMetadataBytes,max(s.metadata,sampler.peakMetadataBytes)) }
  }
  enum Detection { case circles(Circles), noResult(DevelopmentLocalNoResult) }
  private static func check(_ cancellation:DevelopmentAnalysisCancellation?)throws { try Task.checkCancellation();try cancellation?.check() }
  static func encoded(_ p:SIMD4<Float>)throws->SIMD3<Float>? {
    guard p.x.isFinite,p.y.isFinite,p.z.isFinite,p.w.isFinite,p.w>=0,p.w<=1 else { throw DevelopmentError.invalidEncoding }
    guard p.w>=DevelopmentLocalEngineV3.alphaMinimum else { return nil }
    func encode(_ x:Float)->Float { let c=min(1,max(0,x));return c<=0.0031308 ? 12.92*c:1.055*powf(c,1/2.4)-0.055 }
    return .init(encode(p.x/p.w),encode(p.y/p.w),encode(p.z/p.w))
  }
  static func red(_ c:SIMD3<Float>)->Bool {
    if (min(c.x,min(c.y,c.z))>0.6 && max(c.x,max(c.y,c.z))>0.9) || (c.z>0.8 && c.x-c.z<=0.15) { return false }
    return c.x>=0.35 && c.x-max(c.y,c.z)>=0.15 && c.x/(c.y+c.z+0.01)>=1.5
  }
  private static func smooth(_ a:Float,_ b:Float,_ x:Float)->Float { let t=min(1,max(0,(x-a)/(b-a)));return t*t*(3-2*t) }
  /// Strictly positive current manual correction at the actual native pixel, after final-center refinement.
  static func effectiveSupport(_ p:SIMD4<Float>,point:SIMD2<Double>,center:SIMD2<Double>,radius:Double)throws->Bool {
    guard let c=try encoded(p),red(c),point.x.isFinite,point.y.isFinite,center.x.isFinite,center.y.isFinite,radius.isFinite,radius>0 else { return false }
    let distance=Float(hypot(point.x-center.x,point.y-center.y)/radius)
    let coverage=1-smooth(0.7,1,distance)
    let factor=smooth(0.15,0.30,c.x-max(c.y,c.z))*smooth(0.25,0.45,c.x)*smooth(1.5,2,c.x/(c.y+c.z+0.01))
    let weight=coverage*factor
    guard coverage>0,factor>0,weight.isFinite,weight>0 else { return false }
    let redEncoded=min(c.x,(c.y+c.z)/2)
    let replacement=(redEncoded<=0.04045 ? redEncoded/12.92:powf((redEncoded+0.055)/1.055,2.4))*p.w
    return replacement<p.x && p.x+(replacement-p.x)*weight<p.x
  }
  static func sourceGeometry(cx:Double,cy:Double,area:Int,proxyWidth:Int,proxyHeight:Int,width:Int,height:Int)throws->(center:SIMD2<Double>,radius:Double) {
    guard cx.isFinite,cy.isFinite,area>0,proxyWidth>0,proxyHeight>0,width>0,height>0 else { throw DevelopmentLocalPreparationError.invalidInput }
    let sx=Double(proxyWidth)/Double(width),sy=Double(proxyHeight)/Double(height)
    return(.init(cx/sx,cy/sy),max(2,1.4*sqrt(Double(area)/(Double.pi*sx*sy))))
  }
  static func pair(_ a:Candidate,_ b:Candidate)->Bool {
    guard a.qualified,b.qualified,a.score>=0.60,b.score>=0.60,a.radius>0,b.radius>0 else { return false }
    let ratio=a.radius/b.radius,d=hypot(a.x-b.x,a.y-b.y),separation=d/max(a.radius,b.radius)
    return ratio>=0.5 && ratio<=2 && separation>=3 && separation<=25 && abs(a.y-b.y)<=0.5*d
  }
  static func operationID(_ base:UUID,component:Int32)->UUID {
    let d=SHA256.hash(data:Data((base.uuidString+"/red-eye-auto-v1/"+String(component)).utf8))
    let b=Array(d.prefix(16))
    return UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
  }
  static func detect(sampler:DevelopmentLocalAnalysisV3.Sampler,remainingOperations:Int,cancellation:DevelopmentAnalysisCancellation?)throws->Detection {
    let w=sampler.pw,h=sampler.ph,p=w.multipliedReportingOverflow(by:h)
    guard !p.overflow,p.partialValue>0,p.partialValue<=1536*1536,remainingOperations>=0,
      MemoryLayout<Candidate>.stride<=128 else { throw DevelopmentLocalPreparationError.localWorkBudgetExceeded }
    let n=p.partialValue
    let maskStorage=try DevelopmentLocalAllocationV3(bytes:n,kind:.analysis)
    let queueStorage=try DevelopmentLocalAllocationV3(bytes:n*MemoryLayout<Int32>.stride,kind:.analysis)
    let records=try DevelopmentLocalAllocationV3(bytes:maximumCandidates*128,kind:.analysis)
    let mask=maskStorage.pointer.bindMemory(to:UInt8.self,capacity:n),queue=queueStorage.pointer.bindMemory(to:Int32.self,capacity:n)
    let candidates=records.pointer.bindMemory(to:Candidate.self,capacity:maximumCandidates)
    let pixels=sampler.proxy.pointer.assumingMemoryBound(to:SIMD4<Float>.self)
    var stats=Statistics();stats.proxyWidth=w;stats.proxyHeight=h;stats.observe(sampler)
    for y in 0..<h {
      try check(cancellation)
      for x in 0..<w {
        let i=y*w+x
        if let c=try encoded(pixels[i]) { stats.visible += 1;if red(c) { mask[i]=1;stats.redPixels += 1 } }
      }
    }
    if stats.visible==0 { return .noResult(.noVisibleSamples) }
    if stats.redPixels==0 { return .noResult(.noRedPixels) }
    let sx=Double(w)/Double(sampler.width),sy=Double(h)/Double(sampler.height)
    for first in 0..<n where mask[first]==1 {
      try check(cancellation);stats.components += 1
      var head=0,tail=1,area=0,minX=w,maxX=0,minY=h,maxY=0
      var sumX=0.0,sumY=0.0,sumXX=0.0,sumXY=0.0,sumYY=0.0,weightedX=0.0,weightedY=0.0,totalWeight=0.0
      queue[0]=Int32(first);mask[first]=2
      while head<tail {
        if head%256==0 { try check(cancellation) }
        let i=Int(queue[head]);head += 1;let x=i%w,y=i/w,px=Double(x)+0.5,py=Double(y)+0.5
        area += 1;minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)
        sumX += px;sumY += py;sumXX += px*px;sumXY += px*py;sumYY += py*py
        if let c=try encoded(pixels[i]) { let weight=Double(c.x-max(c.y,c.z));weightedX += px*weight;weightedY += py*weight;totalWeight += weight }
        // Fixed top-left to bottom-right eight-neighbor order.
        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
          let nx=x+dx,ny=y+dy
          if nx>=0,ny>=0,nx<w,ny<h {
            let j=ny*w+nx
            if mask[j]==1 { guard tail<n else { throw DevelopmentLocalPreparationError.localWorkBudgetExceeded };mask[j]=2;queue[tail]=Int32(j);tail += 1 }
          }
        } }
      }
      guard area>=4,area<=Int(ceil(0.005*Double(n))),totalWeight>0 else { continue }
      let bw=Double(maxX-minX+1)/sx,bh=Double(maxY-minY+1)/sy,aspect=max(bw/bh,bh/bw)
      let fill=Double(area)/Double((maxX-minX+1)*(maxY-minY+1))
      let meanX=sumX/Double(area),meanY=sumY/Double(area)
      let xx=max(0,sumXX/Double(area)-meanX*meanX)/(sx*sx),yy=max(0,sumYY/Double(area)-meanY*meanY)/(sy*sy)
      let xy=(sumXY/Double(area)-meanX*meanY)/(sx*sy),delta=hypot(xx-yy,2*xy)
      let small=(xx+yy-delta)/2,large=(xx+yy+delta)/2
      guard aspect<=2.5,fill>=0.25,small>0,large/small<=6.25 else { continue }
      let geometry=try sourceGeometry(cx:weightedX/totalWeight,cy:weightedY/totalWeight,area:area,proxyWidth:w,proxyHeight:h,width:sampler.width,height:sampler.height)
      guard geometry.radius<=0.08*Double(min(sampler.width,sampler.height)) else { continue }
      guard stats.geometric<maximumCandidates else { throw DevelopmentLocalPreparationError.localWorkBudgetExceeded }
      candidates[stats.geometric] = .init(x:geometry.center.x,y:geometry.center.y,radius:geometry.radius,component:Int32(first));stats.geometric += 1
    }
    for i in 0..<stats.geometric {
      try check(cancellation)
      candidates[i]=try qualify(candidates[i],sampler:sampler,cancellation:cancellation)
      if candidates[i].qualified { stats.nativeQualified += 1 }
      stats.observe(sampler)
    }
    for i in 0..<stats.geometric {
      try check(cancellation)
      for j in 0..<stats.geometric where i != j {
        if pair(candidates[i],candidates[j]) { candidates[i].paired=true;break }
      }
    }
    var eligible=0
    for i in 0..<stats.geometric {
      let c=candidates[i]
      if c.qualified && (c.score>=0.70 || (c.score>=0.60 && c.paired)) { candidates[eligible]=c;eligible += 1 }
    }
    // Stable in-place insertion sort, at most256 records and no hidden sorting scratch.
    sort(candidates,count:eligible,byScore:true)
    var selected=0
    for i in 0..<eligible {
      try check(cancellation);let c=candidates[i];var duplicate=false
      for j in 0..<selected { if hypot(c.x-candidates[j].x,c.y-candidates[j].y)<=1.25*max(c.radius,candidates[j].radius) { duplicate=true;break } }
      if !duplicate {
        guard selected<maximumEyes,selected<remainingOperations else { throw DevelopmentLocalPreparationError.localWorkBudgetExceeded }
        candidates[selected]=c;selected += 1
      }
    }
    guard selected>0 else { return .noResult(.noConfidentEyes) }
    sort(candidates,count:selected,byScore:false);stats.accepted=selected;stats.observe(sampler)
    return .circles(.init(storage:records,count:selected,statistics:stats))
  }
  private static func sort(_ records:UnsafeMutablePointer<Candidate>,count:Int,byScore:Bool) {
    func earlier(_ a:Candidate,_ b:Candidate)->Bool {
      if byScore,a.score != b.score { return a.score>b.score }
      if !byScore,a.y != b.y { return a.y<b.y };if !byScore,a.x != b.x { return a.x<b.x };return a.component<b.component
    }
    if count<2 { return }
    for i in 1..<count { let value=records[i];var j=i;while j>0 && earlier(value,records[j-1]) { records[j]=records[j-1];j -= 1 };records[j]=value }
  }
  private static func snapped(_ x:Double,_ y:Double)->SIMD2<Double> { .init(floor(x)+0.5,floor(y)+0.5) }
  private static func qualify(_ initial:Candidate,sampler:DevelopmentLocalAnalysisV3.Sampler,cancellation:DevelopmentAnalysisCancellation?)throws->Candidate {
    var c=initial;let original=SIMD2(c.x,c.y);var weighted=SIMD2<Double>.zero,total=0.0
    for ring in 0..<2 { for i in 0..<16 {
      try check(cancellation);let a=2*Double.pi*Double(i)/16,r=c.radius*(ring==0 ? 0.35:0.7),p=snapped(original.x+cos(a)*r,original.y+sin(a)*r)
      guard let rgba=try sampler.nativeRGBA(p),let rgb=try encoded(rgba) else { return c }
      if red(rgb) { let weight=Double(rgb.x-max(rgb.y,rgb.z));weighted += p*weight;total += weight }
    } }
    guard total>0 else { return c };let refined=weighted/total
    guard hypot(refined.x-original.x,refined.y-original.y)<=0.25*c.radius else { return c }
    c.x=refined.x;c.y=refined.y;var support=0,innerDark=0,outerRed=0;var innerY=0.0,outerY=0.0
    for ring in 0..<2 { for i in 0..<16 {
      try check(cancellation);let a=2*Double.pi*Double(i)/16,r=c.radius*(ring==0 ? 0.35:0.7),p=snapped(original.x+cos(a)*r,original.y+sin(a)*r)
      guard let rgba=try sampler.nativeRGBA(p) else { return c }
      if try effectiveSupport(rgba,point:p,center:refined,radius:c.radius) { support += 1 }
    } }
    guard support>=16 else { return c }
    for ring in 0..<2 { for i in 0..<32 {
      try check(cancellation);let a=2*Double.pi*Double(i)/32,r=c.radius*(ring==0 ? 1.1:1.35),p=snapped(c.x+cos(a)*r,c.y+sin(a)*r)
      guard let rgba=try sampler.nativeRGBA(p),let rgb=try encoded(rgba) else { return c }
      let y=Double(rgb.x)*0.2126729+Double(rgb.y)*0.7151522+Double(rgb.z)*0.0721750
      if ring==0 { innerY += y;if y<0.45 { innerDark += 1 } } else { outerY += y;if red(rgb) { outerRed += 1 } }
    } }
    guard innerDark>=8,outerRed<=8 else { return c }
    let delta=outerY/32-innerY/32
    c.score=0.5*Double(support)/32+0.25*Double(innerDark)/32+0.25*min(1,max(0,delta/0.15));c.qualified=true
    return c
  }
}
