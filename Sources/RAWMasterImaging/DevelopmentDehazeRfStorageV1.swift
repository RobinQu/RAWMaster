import CoreImage
import Darwin
import Foundation

/// One invocation's scalar file. CI callback destination storage remains CI-owned.
final class DehazeRfStateV1: @unchecked Sendable {
  private let lock=NSLock()
  private var active=0, failure:String?, closed=false, removed=false
  func enter(){lock.lock();active+=1;lock.unlock()}
  func leave(){lock.lock();active-=1;lock.unlock()}
  func fail(_ reason:String){lock.lock();failure=failure ?? reason;lock.unlock()}
  func didClose(_ c:Bool,_ r:Bool){lock.lock();closed=c;removed=r;if active != 0{failure=failure ?? "close while callback active"};lock.unlock()}
  func check()throws{lock.lock();let bad=failure;lock.unlock();if bad != nil{throw DevelopmentError.invalidEncoding}}
  var storageReleased:Bool{lock.lock();defer{lock.unlock()};return active==0 && closed && removed}
}

final class DehazeRfScratchV1 {
  static let cap=512*1024*1024
  let directory:URL,plane:URL,width:Int,height:Int,components:Int,planeBytes:Int,sourceBytes:Int64
  private(set) var providerOpened=false
  init(capture:URL,width:Int,height:Int)throws{
    guard width>0,height>0,width<=9504,height<=6336 else{throw PreviewPresentationError.unsupported}
    let (pixels,a)=width.multipliedReportingOverflow(by:height)
    let (bytes,b)=pixels.multipliedReportingOverflow(by:4)
    guard !a,!b,bytes>0,bytes<=Self.cap else{throw PreviewPresentationError.displayCapacity}
    self.width=width;self.height=height;components=1;planeBytes=bytes
    sourceBytes=try PreviewFileStamp.read(capture).size
    guard sourceBytes>0,sourceBytes<=Self.cap else{throw PreviewPresentationError.displayCapacity}
    directory=capture.deletingLastPathComponent().appendingPathComponent("dehaze-rf-"+UUID().uuidString,isDirectory:true)
    plane=directory.appendingPathComponent("plane.r32f")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
  }
  /// General canonical transport owns a directory independent of source-capture cleanup.
  /// Admission is bounded by the scalar plane, not by a landscape-only canvas.
  static func supportsNative(width:Int,height:Int,components:Int)->Bool {
    guard components==1 || components==2,DevelopmentDehazeNativeRfV1.supports(width:width,height:height) else{return false}
    return width*height*4 <= cap/components
  }
  init(nativeWidth width:Int,height:Int,components:Int=1)throws{
    guard Self.supportsNative(width:width,height:height,components:components) else{throw PreviewPresentationError.displayCapacity}
    self.width=width;self.height=height;self.components=components;planeBytes=width*height*components*4;sourceBytes=0
    directory=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-native-dehaze-rf-"+UUID().uuidString,isDirectory:true)
    plane=directory.appendingPathComponent(components==1 ? "plane.r32f":"plane.rg32f")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
  }
  func markProviderOpened(){providerOpened=true}
  func requirePlane()throws{
    var s=stat()
    guard lstat(plane.path,&s)==0,s.st_mode&S_IFMT==S_IFREG,s.st_nlink==1,
      s.st_mode&0o222==0,s.st_size==planeBytes else{throw DevelopmentError.invalidEncoding}
  }
  /// Called only after all actual tasks and graph pools have ended.
  func finish()throws{
    if providerOpened {
      guard !FileManager.default.fileExists(atPath:plane.path) else{throw PreviewPresentationError.allocationProtocol}
    }else if FileManager.default.fileExists(atPath:plane.path){try FileManager.default.removeItem(at:plane)}
    guard try FileManager.default.contentsOfDirectory(atPath:directory.path).isEmpty else{throw PreviewPresentationError.allocationProtocol}
    try FileManager.default.removeItem(at:directory)
  }
}

final class DehazeRfProviderV1:NSObject {
  let width:Int,height:Int,components:Int,state:DehazeRfStateV1
  private let fd:Int32,url:URL
  private let onRelease:(()->Void)?
  init(_ scratch:DehazeRfScratchV1,state:DehazeRfStateV1,onRelease:(()->Void)?=nil)throws{
    try scratch.requirePlane()
    var stamp=stat();guard lstat(scratch.plane.path,&stamp)==0 else{throw DevelopmentError.invalidEncoding}
    let file=open(scratch.plane.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
    guard file>=0 else{throw DevelopmentError.invalidEncoding}
    var actual=stat()
    guard fstat(file,&actual)==0,actual.st_ino==stamp.st_ino,actual.st_dev==stamp.st_dev,
      actual.st_size==stamp.st_size else{Darwin.close(file);throw DevelopmentError.invalidEncoding}
    fd=file;url=scratch.plane;width=scratch.width;height=scratch.height;components=scratch.components;self.state=state;self.onRelease=onRelease
    super.init();scratch.markProviderOpened()
  }
  deinit{let c=Darwin.close(fd)==0;let r=unlink(url.path)==0;state.didClose(c,r);onRelease?()}
  override func provideImageData(_ destination:UnsafeMutableRawPointer,bytesPerRow rowBytes:Int,
    origin x:Int,_ y:Int,size columns:Int,_ rows:Int,userInfo info:Any?){
    state.enter();defer{state.leave()}
    let (span,overflow)=rowBytes.multipliedReportingOverflow(by:rows)
    guard rowBytes>=0,rows>=0,!overflow,span>=0 else{state.fail("invalid callback span");return}
    func poison(){
      let n=max(0,min(max(0,min(columns,256))*components,rowBytes/4))
      guard rows<=256,n<=256*components else{state.fail("oversized callback");return}
      for row in 0..<rows{let p=destination.advanced(by:row*rowBytes).assumingMemoryBound(to:UInt32.self);for i in 0..<n{p[i]=0x7fc00000}}
    }
    guard columns>0,rows>0,columns<=256,rows<=256,x>=0,y>=0,x<=width,y<=height,
      columns<=width-x,rows<=height-y,rowBytes>=columns*components*4 else{state.fail("callback outside fixed256 layout");poison();return}
    do{try state.check()}catch{poison();return}
    for row in 0..<rows{
      let offset=((y+row)*width+x)*components*4,dst=destination.advanced(by:row*rowBytes)
      var n:Int
      repeat{n=pread(fd,dst,columns*components*4,off_t(offset))}while n<0 && errno==EINTR
      if n != columns*components*4{state.fail("short scalar read");poison();return}
    }
  }
  func image()->CIImage{CIImage(imageProvider:self,size:width,height,format:components==1 ? .Rf:.RGf,colorSpace:nil,options:[.providerTileSize:[256,256]])}
}

final class DehazeRfBufferV1 {
  let pointer:UnsafeMutableRawPointer,bytes:Int,rowBytes:Int
  private let ticket:PreviewPresentationReservation
  init(width:Int,height:Int,components:Int,scope:PreviewPresentationScope)throws{
    guard width>0,width<=9504,height>0,[1,2,4].contains(components),
      height<=256 || (components==2 && width<=1024 && height<=1024) else{throw PreviewPresentationError.invalidLayout}
    rowBytes=(width*components*4+255)/256*256
    let page=Int(getpagesize());bytes=(rowBytes*height+page-1)/page*page
    guard scope.ledger.statistics.chargedCPUBytes<=256*1024*1024-bytes else{throw PreviewPresentationError.displayCapacity}
    ticket=try scope.reserveCPUFallback(bytes:bytes)
    guard let p=calloc(1,bytes) else{ticket.releaseAfterStorageReleased();throw PreviewPresentationError.displayCapacity}
    pointer=p
  }
  deinit{free(pointer);ticket.releaseAfterStorageReleased()}
}
