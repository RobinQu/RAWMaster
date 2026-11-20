import Foundation
import CoreFoundation
import Darwin

/// Explicit persisted, machine-specific application opt-in. Public/isolated defaults remain zero.
enum DevelopmentPreviewApplicationCacheProfile {
  static let bytes=1_073_741_824
  static let profile="m4max128-macos27.0.1-whole-f32-v1"
  static let enabledKey="rawBaseCacheEnabled",profileKey="rawBaseCacheProfile"
  static let normalBundle="io.robinqu.RAWMaster",previewBundle="io.robinqu.RAWMaster.preview020final"
  static let preview021Bundle="io.robinqu.RAWMaster.preview021"
  struct Host {
    let model:String?,physicalBytes:UInt64?,os:OperatingSystemVersion?
  }
  static func allowedBundle(_ bundleID:String?)->Bool {
    bundleID==normalBundle || bundleID==previewBundle || bundleID==preview021Bundle
  }
  static func genuineTrue(_ object:Any?)->Bool {
    guard let number=object as? NSNumber else{return false}
    // NSNumber/Bool bridging is deliberate. NSNumber(1), NSNumber(1.0), NSString("true") and
    // UserDefaults.bool(forKey:) coercion are NOT acceptable evidence of a saved CFBoolean true.
    return CFGetTypeID(number)==CFBooleanGetTypeID() && number.boolValue
  }
  static func requested(enabled:Any?,profile:Any?)->Bool {
    genuineTrue(enabled) && (profile as? String)==Self.profile
  }
  static func selectedBytes(bundleID:String?,enabled:Any?,profile:Any?,host:Host)->Int {
    guard allowedBundle(bundleID),requested(enabled:enabled,profile:profile),
      host.model=="Mac16,5",host.physicalBytes==137_438_953_472,
      let os=host.os,os.majorVersion==27,os.minorVersion==0,os.patchVersion==1 else{return 0}
    return bytes
  }
  // Live read adapter is synchronous and is invoked ONLY by shared's existing private initializer.
  // Deliberately read the app's own persisted domain, not argument/global/registration fallback.
  // This implements "explicitly saved" opt-in; preview never borrows normal-domain preferences.
  // No registration default, env flag, migration, set/synchronize/write or automatic enable.
  static func currentSharedBytes()->Int {
    let bundleID=Bundle.main.bundleIdentifier
    guard let bundleID,allowedBundle(bundleID)else{return 0}
    let saved=UserDefaults.standard.persistentDomain(forName:bundleID) ?? [:]
    let enabled=saved[enabledKey],profile=saved[profileKey]
    guard requested(enabled:enabled,profile:profile)else{return 0} // Off path avoids host sysctls too.
    return selectedBytes(bundleID:bundleID,enabled:enabled,profile:profile,
      host:.init(model:readModel(),physicalBytes:readPhysicalBytes(),os:ProcessInfo.processInfo.operatingSystemVersion))
  }
  private static func readModel()->String? {
    var count=0
    guard sysctlbyname("hw.model",nil,&count,nil,0)==0,count>1,count<=256 else{return nil}
    var buffer=[CChar](repeating:0,count:count),returned=count
    let ok=buffer.withUnsafeMutableBufferPointer{sysctlbyname("hw.model",$0.baseAddress,&returned,nil,0)==0}
    guard ok,returned>1,returned<=buffer.count,buffer[returned-1]==0,
      !buffer.prefix(returned-1).contains(0) else{return nil}
    return buffer.withUnsafeBufferPointer{p in p.baseAddress.flatMap{String(validatingUTF8:$0)}}
  }
  private static func readPhysicalBytes()->UInt64? {
    var value:UInt64=0,count=MemoryLayout<UInt64>.size
    guard sysctlbyname("hw.memsize",&value,&count,nil,0)==0,count==MemoryLayout<UInt64>.size else{return nil}
    return value
  }
}

