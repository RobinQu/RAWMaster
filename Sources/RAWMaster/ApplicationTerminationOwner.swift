import AppKit

/// One termination owner waits through actual shutdown joins and optional scalar trace emission.
@MainActor
final class ApplicationTerminationOwner {
  private var claimed=false
  private var shutdownTask:Task<Void,Never>?
  func request(shutdown:(@MainActor () async -> Void)?,
               reply:@escaping @MainActor () -> Void)->NSApplication.TerminateReply {
    if claimed {return .terminateLater}
    guard let shutdown else{return .terminateNow} // Original idle/no-editing branch, no new task.
    claimed=true // Synchronous claim precedes creation/suspension of the only owner task.
    shutdownTask=Task { @MainActor in
      await shutdown()
      self.shutdownTask=nil // Drop only the Void task; retain claimed so no second owner/reply.
      reply() // Only this original owner can reply, after ALL supplied shutdown/stat/emit work.
    }
    return .terminateLater
  }
}
