import Foundation

/// User-selectable rendering speed profile for the editing canvas.
///
/// `balanced` keeps every frame at the quality the operator graph defines. `turbo` additionally
/// allows the canvas to trade transient sharpness for latency: gestures at 1:1 fall back to the
/// canvas-sized proxy, the first settled 1:1 frame covers only the visible window, and the proxy
/// base may decode at half resolution. Only the canvas is affected; export, save, thumbnails,
/// histogram and analysis always use the native graph.
public enum PreviewPerformanceMode: String, CaseIterable, Identifiable, Sendable {
  case balanced, turbo
  public var id: String { rawValue }
  public var title: String { self == .turbo ? "极速" : "均衡" }
  public static let storageKey = "editing.preview.performanceMode"
}

/// Process-wide holder read by the preview service and the editing controller.
///
/// The app persists the user's choice; the engine only reads it. Kept lock-protected so a
/// settings change on the main actor is visible to the native worker without a data race.
public enum PreviewPerformancePreferences {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var stored: PreviewPerformanceMode = .balanced

  public static var mode: PreviewPerformanceMode {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); stored = newValue; lock.unlock() }
  }
  public static var isTurbo: Bool { mode == .turbo }

  /// UserDefaults key shared by the settings UI and the launch path.
  /// Reads back to `balanced` for anything unrecognised so a stale value cannot change quality.
  public static func apply(stored raw: String) {
    mode = PreviewPerformanceMode(rawValue: raw) ?? .balanced
  }

  /// Extra canvas around the visible rect for a settled 1:1 window. A larger margin keeps panning
  /// free; zero renders exactly what is on screen.
  public static let settledWindowMargin = 0.5
}

/// Pure decision table for the canvas frame quality, so the speed profile can be reviewed and
/// tested without a live controller.
public enum PreviewQualityPolicy {
  /// - `actualPixels`: the canvas is at 1:1.
  /// - `interacting`: a control gesture is in flight.
  /// - `overlayOnly`: only the crop overlay changed, so the pixels did not.
  public static func quality(actualPixels: Bool, interacting: Bool, overlayOnly: Bool,
                             turbo: Bool) -> PreviewQuality {
    if actualPixels { return turbo && interacting && !overlayOnly ? .interactive : .detail }
    if interacting && !overlayOnly { return .interactive }
    return .settled
  }

  /// Margin for a 1:1 window. Turbo settles exactly what is on screen first and fills the pan
  /// margin afterwards, so the visible frame lands sooner.
  public static func windowMargin(interacting: Bool, turbo: Bool) -> Double {
    turbo && interacting ? 0 : PreviewPerformancePreferences.settledWindowMargin
  }
}
