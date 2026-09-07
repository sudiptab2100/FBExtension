import BackgroundTasks
import Flutter
import UIKit

final class BackgroundUploadPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let pluginKey = "LocalDriveBackgroundUploadPlugin"
  private let listenerId = UUID()
  private var eventSink: FlutterEventSink?

  static func registerIfNeeded(with registry: FlutterPluginRegistry) {
    guard !registry.hasPlugin(pluginKey), let registrar = registry.registrar(forPlugin: pluginKey) else { return }
    register(with: registrar)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = BackgroundUploadPlugin()
    let methods = FlutterMethodChannel(name: "localdrive/bg_upload", binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(name: "localdrive/bg_upload/events", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: methods)
    registrar.publish(plugin)
    events.setStreamHandler(plugin)
    BackgroundUploadCoordinator.shared.restore()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "environment" {
      BGTaskScheduler.shared.getPendingTaskRequests { requests in
        DispatchQueue.main.async {
          let refresh: String
          switch UIApplication.shared.backgroundRefreshStatus {
          case .available: refresh = "available"
          case .denied: refresh = "denied"
          case .restricted: refresh = "restricted"
          @unknown default: refresh = "restricted"
          }
          result([
            "backgroundRefresh": refresh,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
            "pendingTaskIdentifiers": requests.map(\.identifier).sorted()
          ])
        }
      }
      return
    }
    guard ["enqueue", "pending", "cancel", "readCompletions", "ackCompletions", "setTokenBackgroundAccess"]
      .contains(call.method)
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    BackgroundUploadCoordinator.shared.perform(method: call.method, arguments: call.arguments) { response in
      switch response {
      case .success(let value): result(value)
      case .failure(let error):
        result(FlutterError(code: error.code, message: error.message, details: nil))
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    BackgroundUploadCoordinator.shared.addListener(id: listenerId) { [weak self] progress in
      self?.eventSink?(progress)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    BackgroundUploadCoordinator.shared.removeListener(id: listenerId)
    return nil
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    eventSink = nil
    BackgroundUploadCoordinator.shared.removeListener(id: listenerId)
  }

  deinit {
    BackgroundUploadCoordinator.shared.removeListener(id: listenerId)
  }
}
