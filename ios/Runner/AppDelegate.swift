import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register a BGTaskScheduler launch handler for every permitted identifier
    // *before* didFinishLaunching returns. Flutter's UIScene lifecycle registers
    // plugins after this method returns, which is too late for workmanager_apple
    // to register the handlers itself. Without this, BGTaskScheduler.submit()
    // aborts the app the first time a periodic task is scheduled from Dart.
    if let identifiers = Bundle.main.object(
      forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
    ) as? [String] {
      for identifier in identifiers {
        WorkmanagerPlugin.registerPeriodicTask(withIdentifier: identifier)
      }
    }
    // Re-register handlers for any tasks persisted from a previous session.
    WorkmanagerPlugin.registerLaunchHandlers()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
