import Foundation
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

enum OwnedFixtureError:Error { case unsafe(String) }
private func fixtureRequire(_ value:Bool,_ message:String)throws{if !value{throw OwnedFixtureError.unsafe(message)}}
private struct FixtureState:Equatable {
  let device:Int32,inode:UInt64,nlink:UInt16,mode:UInt16,size:Int64
  let modifiedSeconds:Int,modifiedNanoseconds:Int,changedSeconds:Int,changedNanoseconds:Int
  init(_ s:stat){device=s.st_dev;inode=s.st_ino;nlink=s.st_nlink;mode=s.st_mode;size=s.st_size;modifiedSeconds=s.st_mtimespec.tv_sec;modifiedNanoseconds=s.st_mtimespec.tv_nsec;changedSeconds=s.st_ctimespec.tv_sec;changedNanoseconds=s.st_ctimespec.tv_nsec}
  var regular:Bool{mode & UInt16(S_IFMT)==UInt16(S_IFREG)}
  var dictionary:[String:Any]{["device":device,"inode":inode,"nlink":nlink,"mode":mode,"bytes":size,"mtimeSeconds":modifiedSeconds,"mtimeNanoseconds":modifiedNanoseconds,"ctimeSeconds":changedSeconds,"ctimeNanoseconds":changedNanoseconds]}
}
private func fixtureStat(_ fd:Int32)throws->FixtureState{var s=stat();guard Darwin.fstat(fd,&s)==0 else{throw OwnedFixtureError.unsafe("fstat errno \(errno)")};return FixtureState(s)}
private func fixturePathStat(_ url:URL)throws->FixtureState{var s=stat();guard Darwin.lstat(url.path,&s)==0 else{throw OwnedFixtureError.unsafe("lstat errno \(errno)")};return FixtureState(s)}
private func fixtureRead(_ fd:Int32,_ buffer:UnsafeMutableRawPointer,_ size:Int)throws->Int{
  while true{let n=Darwin.read(fd,buffer,size);if n<0 && errno==EINTR{continue};guard n>=0 else{throw OwnedFixtureError.unsafe("read errno \(errno)")};return n}
}
private func fixtureWrite(_ fd:Int32,_ buffer:UnsafeRawPointer,_ size:Int)throws{
  var offset=0
  while offset<size{let n=Darwin.write(fd,buffer.advanced(by:offset),size-offset);if n<0 && errno==EINTR{continue};guard n>0 else{throw OwnedFixtureError.unsafe("write errno \(errno)")};offset+=n}
}
private func fixtureHash(_ fd:Int32)throws->String{
  guard Darwin.lseek(fd,0,SEEK_SET)>=0 else{throw OwnedFixtureError.unsafe("seek")}
  var hash=SHA256(),buffer=[UInt8](repeating:0,count:1_048_576)
  while true{let n=try buffer.withUnsafeMutableBytes{try fixtureRead(fd,$0.baseAddress!,$0.count)};if n==0{break};autoreleasepool{hash.update(data:Data(buffer.prefix(n)))}}
  return hash.finalize().map{String(format:"%02x",$0)}.joined()
}
private struct FixtureProtectedInput {
  let snapshot:EditingSourceSnapshot,resolved:URL,state:FixtureState
  func verify()throws{
    try fixtureRequire(snapshot.sourceLocation.resolvingSymlinksInPath()==resolved,"protected input alias redirected")
    let fd=Darwin.open(resolved.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw OwnedFixtureError.unsafe("protected readonly open")};defer{Darwin.close(fd)}
    try fixtureRequire(try fixtureStat(fd)==state,"protected source identity changed")
    try fixtureRequire(try fixtureHash(fd)==snapshot.contentSHA256,"protected source bytes changed")
    try fixtureRequire(try fixtureStat(fd)==state && fixturePathStat(resolved)==state,"protected source changed during hash/path check")
  }
}
/// TEST ONLY: the owned file is an exclusive regular byte copy, never a copied symlink.
/// Every mutation reopens no-follow and verifies the creation identity, size, stamp, digest and
/// protected input separation. The source descriptors are always readonly; atime is not identity.
final class OwnedFixtureFile {
  let original:EditingSourceSnapshot,url:URL
  private var state:FixtureState,digest:String
  private let protected:[FixtureProtectedInput]
  private(set) var history:[[String:Any]]
  var snapshot:EditingSourceSnapshot{var value=original;value.sourceLocation=url;return value}
  var report:[String:Any]{["ownedURL":url.path,"currentIdentity":state.dictionary,"actualCurrentSHA256":digest,"originalURL":original.sourceLocation.path,"originalExpectedSHA256":original.contentSHA256,"protectedInputs":protected.map{["path":$0.snapshot.sourceLocation.path,"resolved":$0.resolved.path,"verifiedIdentity":$0.state.dictionary,"expectedSHA256":$0.snapshot.contentSHA256]},"operations":history,"atimeScope":"access time excluded from unchanged source identity; no source fchmod/write performed"]}
  private init(original:EditingSourceSnapshot,url:URL,state:FixtureState,digest:String,protected:[FixtureProtectedInput],history:[[String:Any]]){self.original=original;self.url=url;self.state=state;self.digest=digest;self.protected=protected;self.history=history}
  static func create(from original:EditingSourceSnapshot,to destination:URL,protecting inputs:[EditingSourceSnapshot])throws->OwnedFixtureFile{
    var protected:[FixtureProtectedInput]=[]
    for snapshot in inputs+[original]{
      let resolved=snapshot.sourceLocation.resolvingSymlinksInPath();let fd=Darwin.open(resolved.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw OwnedFixtureError.unsafe("input readonly nofollow open")};defer{Darwin.close(fd)}
      let before=try fixtureStat(fd);try fixtureRequire(before.regular && before.size==snapshot.byteCount,"input regular/size")
      try fixtureRequire(try fixtureHash(fd)==snapshot.contentSHA256 && fixtureStat(fd)==before,"input before hash/stamp")
      if !protected.contains(where:{$0.snapshot.sourceLocation==snapshot.sourceLocation && $0.snapshot.contentSHA256==snapshot.contentSHA256}){protected.append(.init(snapshot:snapshot,resolved:resolved,state:before))}
    }
    let inputURL=original.sourceLocation.resolvingSymlinksInPath(),input=Darwin.open(inputURL.path,O_RDONLY|O_NOFOLLOW);guard input>=0 else{throw OwnedFixtureError.unsafe("input open")};defer{Darwin.close(input)}
    let inputState=try fixtureStat(input);try fixtureRequire(protected.contains(where:{$0.resolved==inputURL && $0.state==inputState}),"input changed before copy")
    let parentURL=destination.deletingLastPathComponent().standardizedFileURL
    try fixtureRequire(parentURL==parentURL.resolvingSymlinksInPath(),"output parent redirected")
    let parent=Darwin.open(parentURL.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);guard parent>=0 else{throw OwnedFixtureError.unsafe("output parent open")};defer{Darwin.close(parent)}
    let fd=Darwin.openat(parent,destination.lastPathComponent,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,mode_t(0o600));guard fd>=0 else{throw OwnedFixtureError.unsafe("exclusive output open errno \(errno)")};defer{Darwin.close(fd)}
    let initial=try fixtureStat(fd);try fixtureRequire(initial.regular && initial.nlink==1 && initial.size==0,"new regular nlink1")
    try fixtureRequire(protected.allSatisfy{ $0.state.device != initial.device || $0.state.inode != initial.inode },"output aliases protected input")
    guard Darwin.fchmod(fd,mode_t(0o600))==0 else{throw OwnedFixtureError.unsafe("new owned fchmod")}
    var hash=SHA256(),count:Int64=0,buffer=[UInt8](repeating:0,count:1_048_576)
    while true{
      let n=try buffer.withUnsafeMutableBytes{try fixtureRead(input,$0.baseAddress!,$0.count)};if n==0{break}
      try buffer.withUnsafeBytes{try fixtureWrite(fd,$0.baseAddress!,n)};autoreleasepool{hash.update(data:Data(buffer.prefix(n)))};count+=Int64(n)
    }
    guard Darwin.fsync(fd)==0 else{throw OwnedFixtureError.unsafe("output fsync")}
    let actual=hash.finalize().map{String(format:"%02x",$0)}.joined(),after=try fixtureStat(fd)
    try fixtureRequire(count==original.byteCount && actual==original.contentSHA256 && after.size==count,"copy actual bytes/SHA")
    try fixtureRequire(after.regular && after.nlink==1 && after.device==initial.device && after.inode==initial.inode && fixturePathStat(destination)==after,"output path/FD identity")
    try fixtureRequire(try fixtureHash(fd)==actual,"output readback SHA")
    for source in protected{try source.verify()}
    guard Darwin.fsync(parent)==0 else{throw OwnedFixtureError.unsafe("parent fsync")}
    return .init(original:original,url:destination,state:after,digest:actual,protected:protected,history:[["operation":"exclusive-stream-create","inputResolved":inputURL.path,"inputIdentity":inputState.dictionary,"ownedIdentity":after.dictionary,"actualBytes":count,"actualSHA256":actual,"noSourceMetadataWrite":true]])
  }
  private func openOwned(access:Int32=O_RDWR)throws->Int32{
    for input in protected{try input.verify()}
    let parent=url.deletingLastPathComponent().standardizedFileURL
    try fixtureRequire(parent==parent.resolvingSymlinksInPath(),"owned parent redirected")
    let fd=Darwin.open(url.path,access|O_NOFOLLOW);guard fd>=0 else{throw OwnedFixtureError.unsafe("owned nofollow open errno \(errno)")}
    do{
      let current=try fixtureStat(fd)
      try fixtureRequire(current.regular && current.nlink==1 && current==state && fixturePathStat(url)==current,"owned path/identity/nlink/expected-size-stamp")
      try fixtureRequire(protected.allSatisfy{$0.state.device != current.device || $0.state.inode != current.inode},"owned/protected inode collision")
      try fixtureRequire(try fixtureHash(fd)==digest && fixtureStat(fd)==current,"owned expected bytes/SHA")
      return fd
    }catch{Darwin.close(fd);throw error}
  }
  private func commit(_ fd:Int32,operation:String,before:FixtureState,expectedSize:Int64)throws{
    guard Darwin.fsync(fd)==0 else{throw OwnedFixtureError.unsafe("mutation fsync")}
    let after=try fixtureStat(fd);try fixtureRequire(after.regular && after.nlink==1 && after.size==expectedSize && after.device==before.device && after.inode==before.inode && fixturePathStat(url)==after,"mutation owner changed")
    let hash=try fixtureHash(fd);for source in protected{try source.verify()}
    state=after;digest=hash;history.append(["operation":operation,"beforeIdentity":before.dictionary,"afterIdentity":after.dictionary,"actualSHA256":hash])
  }
  func setPermissions(_ mode:mode_t)throws{let fd=try openOwned(access:O_RDONLY);defer{Darwin.close(fd)};let before=state;guard Darwin.fchmod(fd,mode)==0 else{throw OwnedFixtureError.unsafe("owned fchmod")};try commit(fd,operation:"verified-FD-fchmod",before:before,expectedSize:before.size)}
  func append(_ bytes:Data)throws{let fd=try openOwned();defer{Darwin.close(fd)};let before=state;guard Darwin.lseek(fd,0,SEEK_END)==before.size else{throw OwnedFixtureError.unsafe("append expected size")};try bytes.withUnsafeBytes{if !$0.isEmpty{try fixtureWrite(fd,$0.baseAddress!,$0.count)}};try commit(fd,operation:"verified-FD-append-\(bytes.count)",before:before,expectedSize:before.size+Int64(bytes.count))}
  func truncate(to length:Int64)throws{let fd=try openOwned();defer{Darwin.close(fd)};let before=state;guard length>=0 && Darwin.ftruncate(fd,off_t(length))==0 else{throw OwnedFixtureError.unsafe("owned truncate")};try commit(fd,operation:"verified-FD-truncate",before:before,expectedSize:length)}
  func restore()throws{
    let fd=try openOwned(access:O_RDONLY);defer{Darwin.close(fd)};let old=state
    let parentURL=url.deletingLastPathComponent().standardizedFileURL;try fixtureRequire(parentURL==parentURL.resolvingSymlinksInPath(),"restore parent redirected")
    let parent=Darwin.open(parentURL.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);guard parent>=0 else{throw OwnedFixtureError.unsafe("restore parent")};defer{Darwin.close(parent)}
    try fixtureRequire(try fixturePathStat(url)==old && fixtureStat(fd)==old,"restore owner changed before unlink")
    guard Darwin.unlinkat(parent,url.lastPathComponent,0)==0 && Darwin.fsync(parent)==0 else{throw OwnedFixtureError.unsafe("unlink verified owned path")}
    let replacement=try Self.create(from:original,to:url,protecting:protected.map(\.snapshot))
    try fixtureRequire(replacement.state.device != old.device || replacement.state.inode != old.inode,"restore reused live old inode")
    let previous=history;state=replacement.state;digest=replacement.digest;history=previous+[["operation":"verified-owned-unlink-and-exclusive-restore","removedIdentity":old.dictionary,"newIdentity":state.dictionary,"actualSHA256":digest]]
  }
}
