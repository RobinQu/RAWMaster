import Foundation
import Dispatch

/// Reports kernel memory-pressure events; never inspects or terminates another application's processes.
final class RuntimePressureMonitor: @unchecked Sendable {
  private let source: DispatchSourceMemoryPressure
  init(handler: @escaping @Sendable (Bool) -> Void) {
    source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    source.setEventHandler { [weak self] in guard let self else { return }; handler(self.source.data.contains(.critical)) }
    source.resume()
  }
  deinit { source.cancel() }
}
