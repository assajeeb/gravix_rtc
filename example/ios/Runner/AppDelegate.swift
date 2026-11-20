import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // A headless second engine (stands in for a background / push engine), for
  // integration_test/ios_events_test.dart. Started only on request.
  private var secondEngine: FlutterEngine?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GravixExampleSecondEngine") else { return }
    let channel = FlutterMethodChannel(name: "gravix_example/second_engine", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "spawn", let self else { return result(FlutterMethodNotImplemented) }
      if self.secondEngine == nil {
        let e = FlutterEngine(name: "second", project: nil, allowHeadlessExecution: true)
        let ok = e.run(withEntrypoint: "secondEngineMain", libraryURI: "package:gravix_cloud_example/second_engine.dart")
        GeneratedPluginRegistrant.register(with: e)
        self.secondEngine = e
        return result(ok)
      }
      result(true)
    }
  }
}
