import Foundation

private final class RenderStackBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

/// Debug cooperative tasks use a fixed, comparatively small stack. The native render
/// chain (recipe validation, renderer options and settled thumbnail hooks) can exceed
/// it. Debug builds run that synchronous work on a short-lived thread with a larger
/// stack; release keeps the direct call and its existing stack behavior.
enum DevelopmentRenderStack {
#if DEBUG
  static func run<T>(_ body: @escaping () throws -> T) throws -> T {
    let box = RenderStackBox<T>(), done = DispatchSemaphore(value: 0)
    let thread = Thread {
      box.result = Result { try body() }
      done.signal()
    }
    thread.name = "RAWMaster native render"
    thread.stackSize = 16 * 1024 * 1024
    thread.start()
    done.wait()
    guard let result = box.result else { throw DevelopmentPreviewError.capacityExceeded }
    return try result.get()
  }
#else
  static func run<T>(_ body: () throws -> T) throws -> T { try body() }
#endif
}
