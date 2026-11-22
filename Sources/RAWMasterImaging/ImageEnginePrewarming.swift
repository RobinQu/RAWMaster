import Foundation

/// Serial, idempotent shader-library warming. This is explicitly a graph-build/startup boundary;
/// it never relabels a cold render measurement as warm.
public enum ImageEnginePrewarming {
  private static let lock=NSLock()
  private static var scheduled=false

  public static func start() {
    lock.lock();guard !scheduled else{lock.unlock();return};scheduled=true;lock.unlock()
    let telemetry=ImagePerformanceTelemetry.shared
    telemetry.updateQueue("Shader 预热",pendingCount:1)
    let token=telemetry.begin(operation:"ImageEnginePrewarming",stage:"shader-libraries",queue:"Shader 预热",boundary:.graphBuild)
    Task.detached(priority:.utility) {
      run()
      telemetry.end(token,outcome:.succeeded)
      telemetry.updateQueue("Shader 预热",pendingCount:0)
    }
  }

  static func run() {
    PreviewMetalFrameValidator.prewarm()
    PreviewNativeSharpMaskScalar.prewarm()
    FlashRawNoiseReduction.prewarm()
    DevelopmentColorEngineV3.prewarm()
    DevelopmentWhiteBalanceEngineV3.prewarm()
    DevelopmentGlobalEngineV3.prewarm()
    DevelopmentGlowEngineV3.prewarm()
    DevelopmentPostCropVignetteEngineV3.prewarm()
    DevelopmentLensBlurEngineV3.prewarm()
    DevelopmentLensBlurRefinementEngineV3.prewarm()
    DevelopmentMaskEngineV3.prewarm()
    DevelopmentBlackAndWhiteMixerEngineV3.prewarm()
    DevelopmentRefineSaturationEngineV3.prewarm()
    DevelopmentDefringeEngineV3.prewarm()
    DevelopmentOpticsEngineV3.prewarm()
  }
}
