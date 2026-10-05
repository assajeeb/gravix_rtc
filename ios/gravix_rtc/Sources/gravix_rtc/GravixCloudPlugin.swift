import Flutter
import UIKit

/// The package's registered iOS plugin class (pubspec `pluginClass`).
///
/// Registers every native channel the Dart side uses:
///  - `gravix_client`: RTC core (audio session, routing, CallKit engine gating,
///    audio processing, visualizer/renderer, screen-share broadcast), see
///    `GravixClientPlugin`.
///  - `com.gravitycompile.gravix_rtc/music`: room music mixed into the microphone, see
///    `GravixMusicMixer`.
///  - `gravix_cloud`: `getPlatformVersion` (kept for compatibility).
public class GravixCloudPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "gravix_cloud", binaryMessenger: registrar.messenger())
    let instance = GravixCloudPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    GravixClientPlugin.register(with: registrar)
    GravixMusicMixer.register(with: registrar)
  }

  /// Gate the WebRTC audio engine from native code before (or without) the
  /// Flutter engine, e.g. in a CallKit killed-state wake from the AppDelegate.
  /// Forwards to `GravixClientPlugin.setEngineAvailability`. Returns true when
  /// applied to a live audio device module, false when stored and applied at
  /// plugin registration.
  @objc @discardableResult
  public static func setEngineAvailability(isInputAvailable: Bool, isOutputAvailable: Bool) -> Bool {
    GravixClientPlugin.setEngineAvailability(isInputAvailable: isInputAvailable,
                                             isOutputAvailable: isOutputAvailable)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
