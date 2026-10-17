import ActivityKit
import Flutter
import UIKit
import UserNotifications
import WidgetKit

// MARK: - Live Activity host bridge
//
// Dart calls into ActivityKit through the `skotiq/live_activity`
// MethodChannel. ActivityKit landed in iOS 16.1, but
// `SkotiqLiveActivityAttributes` (and therefore every ActivityContent we
// build here) is gated to iOS 16.2 because the `ActivityContent` API itself
// is 16.2+. On devices that fall outside that gate we fail loudly via a
// FlutterError: a silent fallback would let an operator believe Live
// Activities are running when they are not.
//
// Channel name (`skotiq/live_activity`) and method/argument names MUST
// match `apps/mobile/lib/services/live_activity_service.dart`. Argument names
// here also mirror the field names on
// `SkotiqLiveActivityAttributes.ContentState` 1:1 so the host and the
// widget speak the same vocabulary end to end.

@main
@objc class AppDelegate: FlutterAppDelegate {

  /// Tracks running activities so update/end calls can find the right
  /// `Activity` instance. ActivityKit only exposes its own `Activity.activities`
  /// async lookup, but maintaining our own map lets us answer synchronously
  /// from the channel handler. Cleared in `liveActivityEnd(_:)`.
  private var liveActivities: [String: Any] = [:]

  // MARK: - APNs push (Phase E)

  /// Channel for forwarding the APNs device token to Dart, where
  /// `apps/mobile/lib/services/push_registration_service.dart` POSTs it to the
  /// Phase D server endpoint `POST /api/push/register-token` (platform=apns).
  /// Channel + method names MUST match that Dart service.
  private var pushChannel: FlutterMethodChannel?

  /// The most recently received APNs device token, as a lowercase hex string.
  /// Cached so Dart can pull it on demand (`getApnsToken`) even if it called
  /// after `didRegisterForRemoteNotificationsWithDeviceToken` already fired —
  /// the registration callback and the Dart channel listener race at launch.
  private var apnsDeviceTokenHex: String?

  /// The `UNUserNotificationCenter` delegate that `flutter_local_notifications`
  /// installs during Dart `initialize()`. We re-claim ownership of the center
  /// delegate (see `reclaimNotificationCenterDelegate`) so this host's
  /// `willPresent` governs REMOTE (APNs) notifications — the plugin only owns
  /// the LOCAL notifications it scheduled and otherwise leaves remote pushes
  /// silent in the foreground. For local notifications we forward both
  /// `willPresent` and `didReceive` back to this captured delegate so the
  /// plugin's per-notification `DarwinNotificationDetails` flags and tap
  /// handling keep working unchanged.
  private weak var flutterNotificationDelegate: UNUserNotificationCenterDelegate?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "skotiq/live_activity",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(
            FlutterError(
              code: "host_deallocated",
              message: "AppDelegate was released before \(call.method) completed",
              details: nil
            )
          )
          return
        }
        self.handleLiveActivityCall(call, result: result)
      }

      // Apple Watch complication snapshot publisher.
      //
      // The Dart host writes a pre-encoded JSON snapshot of the current
      // sequence + weather state to the App Group `UserDefaults` suite
      // and asks WidgetKit to reload the complication timeline. The
      // watchOS extension in
      // `apps/mobile/ios/SkotiqWatchComplication/` reads the same
      // key when its `TimelineProvider.getTimeline(...)` fires.
      //
      // Channel name + method/argument names MUST stay in lockstep with
      // `apps/mobile/lib/services/watch_complication_service.dart`.
      let watchChannel = FlutterMethodChannel(
        name: "skotiq/watch_complication",
        binaryMessenger: controller.binaryMessenger
      )
      watchChannel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(
            FlutterError(
              code: "host_deallocated",
              message:
                "AppDelegate was released before watch_complication.\(call.method) completed",
              details: nil
            )
          )
          return
        }
        self.handleWatchComplicationCall(call, result: result)
      }

      // Phase E — APNs push channel.
      //
      // The Dart side (push_registration_service.dart) calls
      // `registerForRemoteNotifications` once the device is paired, then either
      // receives the token via the `onApnsToken` invokeMethod push from the
      // didRegister callback below, or pulls the cached token synchronously via
      // `getApnsToken`. It POSTs the hex token to the desktop's
      // `/api/push/register-token` so cellular/APNs critical alerts can reach a
      // backgrounded phone.
      let pushChannel = FlutterMethodChannel(
        name: "skotiq/push",
        binaryMessenger: controller.binaryMessenger
      )
      pushChannel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(
            FlutterError(
              code: "host_deallocated",
              message: "AppDelegate was released before push.\(call.method) completed",
              details: nil
            )
          )
          return
        }
        self.handlePushCall(call, result: result)
      }
      self.pushChannel = pushChannel
    }

    let didFinish = super.application(
      application, didFinishLaunchingWithOptions: launchOptions)
    // The plugin installs its center delegate during Dart `initialize()`, which
    // runs after this method returns, so a single claim here is too early.
    // `applicationDidBecomeActive` re-claims after the engine is up (and on
    // every foreground), which is idempotent — see `reclaimNotificationCenterDelegate`.
    reclaimNotificationCenterDelegate()
    return didFinish
  }

  /// Re-assert this `AppDelegate` as the `UNUserNotificationCenter` delegate so
  /// the host `willPresent` (which forces `.sound` for remote critical alerts)
  /// is not shadowed by the delegate `flutter_local_notifications` installs.
  ///
  /// Idempotent: if the current delegate is already us, do nothing. If it is the
  /// plugin's delegate, capture it (for local-notification forwarding) and take
  /// over. Called after launch and on every `applicationDidBecomeActive`, so it
  /// re-wins after the plugin's deferred Dart `initialize()` sets its own
  /// delegate.
  private func reclaimNotificationCenterDelegate() {
    let center = UNUserNotificationCenter.current()
    let current = center.delegate
    if current === self {
      return
    }
    if let current = current {
      flutterNotificationDelegate = current
    }
    center.delegate = self
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    reclaimNotificationCenterDelegate()
  }

  // MARK: - APNs registration (Phase E)

  /// Handles `skotiq/push` MethodChannel calls from Dart.
  ///
  /// Methods:
  ///   * `registerForRemoteNotifications` — ask iOS to (re)issue an APNs token.
  ///     Returns immediately; the token arrives asynchronously on
  ///     `didRegisterForRemoteNotificationsWithDeviceToken` and is pushed back
  ///     to Dart via `onApnsToken`. Returns `false` only when the OS API is
  ///     unavailable (it isn't, on any supported iOS), else `true`.
  ///   * `getApnsToken` — returns the cached hex token (or nil if registration
  ///     has not completed yet). Lets Dart recover the token if it attached its
  ///     handler after the OS callback already fired.
  private func handlePushCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "registerForRemoteNotifications":
      // Must run on the main thread per UIApplication contract.
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
      result(true)
    case "getApnsToken":
      result(apnsDeviceTokenHex)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// APNs issued (or refreshed) the device token. Encode it as lowercase hex —
  /// the exact wire form the server stores and APNs expects — cache it, and
  /// forward it to Dart so it can be registered with the desktop server.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    apnsDeviceTokenHex = hex
    pushChannel?.invokeMethod("onApnsToken", arguments: hex)
    // Preserve any plugin-side handling (e.g. flutter_local_notifications).
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }

  /// APNs registration failed (no network, no entitlement on the profile, an
  /// APNs outage, or the Simulator which has no APNs). Surface the cause to
  /// Dart so the UI can show that cellular alerts are unavailable rather than
  /// leaving the operator believing they work.
  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    apnsDeviceTokenHex = nil
    pushChannel?.invokeMethod(
      "onApnsRegistrationError",
      arguments: error.localizedDescription
    )
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
  }

  // MARK: - Foreground critical-alert presentation (Phase E)

  /// Present notifications while the app is foregrounded.
  ///
  /// Without this, iOS suppresses banners/sound for a notification that
  /// arrives while the app is open — exactly when an operator is staring at the
  /// live view and a safety alert fires. Critical alerts (weather unsafe, mount
  /// runaway, guiding lost, equipment disconnect — see CRITICAL_ALERTS_SETUP.md)
  /// must surface with sound even in the foreground.
  ///
  /// Delegate ownership: `flutter_local_notifications` (v18) installs its OWN
  /// `UNUserNotificationCenter` delegate during Dart `initialize()`, which would
  /// shadow this override entirely — including for REMOTE (APNs) pushes the
  /// plugin does not own, leaving foreground critical alerts silent. We re-claim
  /// the center delegate (`reclaimNotificationCenterDelegate`) so this method
  /// governs presentation, then split by source:
  ///   * REMOTE (APNs / `UNPushNotificationTrigger`): the plugin has no record
  ///     of these, so WE force `.sound` for the foreground critical-alert path.
  ///   * LOCAL: forward to the captured plugin delegate so its per-notification
  ///     `DarwinNotificationDetails(presentAlert/presentSound/...)` flags (which
  ///     already request foreground sound on the safety paths) stay authoritative.
  /// If no plugin delegate was captured yet (launch window, before Dart
  /// `initialize()`), we fall back to forcing sound — the safe default.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let isRemote = notification.request.trigger is UNPushNotificationTrigger
    if !isRemote,
      let plugin = flutterNotificationDelegate,
      plugin.responds(
        to: #selector(
          UNUserNotificationCenterDelegate.userNotificationCenter(
            _:willPresent:withCompletionHandler:)))
    {
      // Local notification owned by the plugin — let it decide presentation so
      // its per-notification flags govern. (Forwarding keeps the plugin's
      // contract intact even though we own the delegate slot.)
      plugin.userNotificationCenter!(
        center, willPresent: notification, withCompletionHandler: completionHandler)
      return
    }
    // Remote push (or pre-initialize launch window): force sound so a
    // foreground critical alert is never silently swallowed.
    let options: UNNotificationPresentationOptions
    if #available(iOS 14.0, *) {
      options = [.banner, .list, .sound]
    } else {
      options = [.alert, .sound]
    }
    completionHandler(options)
  }

  /// Forward notification-tap responses to the plugin delegate so taps on LOCAL
  /// notifications still reach Dart (`onDidReceiveNotificationResponse`). We own
  /// the delegate slot for the `willPresent` safety net above, so without this
  /// the plugin would never see taps. Remote-only responses with no plugin
  /// delegate simply complete.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let plugin = flutterNotificationDelegate,
      plugin.responds(
        to: #selector(
          UNUserNotificationCenterDelegate.userNotificationCenter(
            _:didReceive:withCompletionHandler:)))
    {
      plugin.userNotificationCenter!(
        center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }
    completionHandler()
  }

  // MARK: - Watch complication
  //
  // Shared App Group + UserDefaults pattern between the iOS host and the
  // watchOS WidgetKit extension. The suite name MUST also be set as an
  // App Group entitlement on both the Runner target and the
  // SkotiqWatchComplication extension target in Xcode (see
  // `apps/mobile/ios/SkotiqWatchComplication/SETUP.md`).

  static let watchComplicationAppGroupSuite = "group.com.skotiq.app"
  static let watchComplicationSnapshotKey = "watch_complication_snapshot"

  private func handleWatchComplicationCall(
    _ call: FlutterMethodCall, result: @escaping FlutterResult
  ) {
    switch call.method {
    case "isSupported":
      // `WidgetCenter` is available from iOS 14 onwards; the host can
      // always *attempt* to write a snapshot regardless. The complication
      // extension itself runs on the paired watch and may not be
      // installed even when the host returns true here — we deliberately
      // don't try to detect that, since failing to publish only costs us
      // a UserDefaults write (no user-visible side-effect).
      if #available(iOS 14.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "publishSnapshot":
      publishWatchComplicationSnapshot(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func publishWatchComplicationSnapshot(
    _ rawArgs: Any?, result: @escaping FlutterResult
  ) {
    guard let args = rawArgs as? [String: Any] else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message:
            "publishSnapshot() expected a Map argument, got \(type(of: rawArgs))",
          details: nil
        )
      )
      return
    }
    guard let snapshotJson = args["snapshotJson"] as? String,
      !snapshotJson.isEmpty
    else {
      result(
        FlutterError(
          code: "missing_snapshot_json",
          message:
            "publishSnapshot() requires a non-empty snapshotJson string",
          details: nil
        )
      )
      return
    }
    guard
      let defaults = UserDefaults(
        suiteName: AppDelegate.watchComplicationAppGroupSuite
      )
    else {
      // Loud failure: the App Group entitlement is missing on the Runner
      // target, so the complication would never see snapshots. Surface the
      // cause now rather than letting the watch face silently render the
      // empty placeholder.
      result(
        FlutterError(
          code: "app_group_unavailable",
          message:
            "Cannot open UserDefaults(suiteName: \(AppDelegate.watchComplicationAppGroupSuite)). " +
            "See apps/mobile/ios/SkotiqWatchComplication/SETUP.md.",
          details: nil
        )
      )
      return
    }
    defaults.set(snapshotJson, forKey: AppDelegate.watchComplicationSnapshotKey)
    if #available(iOS 14.0, *) {
      WidgetCenter.shared.reloadAllTimelines()
    }
    result(nil)
  }

  // MARK: - Dispatch

  private func handleLiveActivityCall(
    _ call: FlutterMethodCall, result: @escaping FlutterResult
  ) {
    if #available(iOS 16.2, *) {
      switch call.method {
      case "start":
        liveActivityStart(call.arguments, result: result)
      case "update":
        liveActivityUpdate(call.arguments, result: result)
      case "end":
        liveActivityEnd(call.arguments, result: result)
      case "isSupported":
        // Authoritative answer for Dart: the OS may still refuse if the
        // user has disabled Live Activities globally in Settings or if the
        // app is missing the widget extension. We check
        // `areActivitiesEnabled` rather than just returning true.
        result(ActivityAuthorizationInfo().areActivitiesEnabled)
      default:
        result(FlutterMethodNotImplemented)
      }
    } else {
      // Loud failure. iOS 16.1 and below cannot build an `ActivityContent`
      // for our `SkotiqLiveActivityAttributes` (the type itself is
      // 16.2-gated).
      result(
        FlutterError(
          code: "unsupported_ios_version",
          message: "Live Activities require iOS 16.2 or later",
          details: nil
        )
      )
    }
  }

  // MARK: - start

  @available(iOS 16.2, *)
  private func liveActivityStart(_ rawArgs: Any?, result: @escaping FlutterResult) {
    guard let args = rawArgs as? [String: Any] else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "start() expected a Map argument, got \(type(of: rawArgs))",
          details: nil
        )
      )
      return
    }

    guard let sequenceId = args["sequenceId"] as? String, !sequenceId.isEmpty else {
      result(
        FlutterError(
          code: "missing_sequence_id",
          message: "start() requires a non-empty sequenceId",
          details: nil
        )
      )
      return
    }
    guard let targetName = args["targetName"] as? String else {
      result(
        FlutterError(
          code: "missing_target_name",
          message: "start() requires a targetName",
          details: nil
        )
      )
      return
    }

    let attributes = SkotiqLiveActivityAttributes(
      sequenceId: sequenceId,
      targetName: targetName
    )
    let state = decodeContentState(args)

    // ActivityAuthorizationInfo guards against silently no-op'ing when the
    // user has disabled Live Activities for the app. Surface as a discrete
    // error code so Dart can disambiguate user-denial from API failure.
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      result(
        FlutterError(
          code: "activities_disabled",
          message:
            "Live Activities are disabled in iOS Settings for Skotiq. Enable them in Settings > Skotiq > Live Activities.",
          details: nil
        )
      )
      return
    }

    do {
      let content = ActivityContent(state: state, staleDate: nil)
      let activity = try Activity<SkotiqLiveActivityAttributes>.request(
        attributes: attributes,
        content: content,
        pushType: nil
      )
      liveActivities[activity.id] = activity
      result(activity.id)
    } catch {
      // ActivityKit throws on quota exhaustion, missing entitlements,
      // missing widget extension, etc. Forward the underlying message so
      // the operator-visible log is useful.
      result(
        FlutterError(
          code: "activity_request_failed",
          message: "Activity.request failed: \(error.localizedDescription)",
          details: String(describing: error)
        )
      )
    }
  }

  // MARK: - update

  @available(iOS 16.2, *)
  private func liveActivityUpdate(_ rawArgs: Any?, result: @escaping FlutterResult) {
    guard let args = rawArgs as? [String: Any] else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "update() expected a Map argument, got \(type(of: rawArgs))",
          details: nil
        )
      )
      return
    }
    guard let activityId = args["activityId"] as? String, !activityId.isEmpty else {
      result(
        FlutterError(
          code: "missing_activity_id",
          message: "update() requires a non-empty activityId",
          details: nil
        )
      )
      return
    }
    guard
      let activity = liveActivities[activityId]
        as? Activity<SkotiqLiveActivityAttributes>
    else {
      result(
        FlutterError(
          code: "unknown_activity",
          message:
            "No live Activity with id \(activityId) is tracked by the host. It may have already ended.",
          details: nil
        )
      )
      return
    }

    let state = decodeContentState(args)
    let content = ActivityContent(state: state, staleDate: nil)

    Task {
      await activity.update(content)
      result(nil)
    }
  }

  // MARK: - end

  @available(iOS 16.2, *)
  private func liveActivityEnd(_ rawArgs: Any?, result: @escaping FlutterResult) {
    guard let args = rawArgs as? [String: Any] else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "end() expected a Map argument, got \(type(of: rawArgs))",
          details: nil
        )
      )
      return
    }
    guard let activityId = args["activityId"] as? String, !activityId.isEmpty else {
      result(
        FlutterError(
          code: "missing_activity_id",
          message: "end() requires a non-empty activityId",
          details: nil
        )
      )
      return
    }
    guard
      let activity = liveActivities[activityId]
        as? Activity<SkotiqLiveActivityAttributes>
    else {
      // Already ended (or never tracked). Treat as a no-op success — the
      // caller's intent ("this activity should not be running") is met.
      // We log to console so a desync between Dart and host stays
      // visible during development.
      NSLog(
        "[LiveActivity] end() called for unknown activity %@ — already ended?",
        activityId
      )
      result(nil)
      return
    }

    // Optional dismissDate. Default to immediate dismissal so the lock-screen
    // banner clears the moment the sequence finishes — leaving a "completed"
    // banner around for 4 hours (Apple's default) is confusing.
    let dismissDate: Date
    if let dismissMillis = args["dismissDate"] as? NSNumber {
      dismissDate = Date(timeIntervalSince1970: dismissMillis.doubleValue / 1000.0)
    } else {
      dismissDate = Date()
    }

    // If the caller supplied a final state, push it before ending so the
    // lock-screen banner shows the terminal frame count.
    let finalState = decodeContentState(args, fallbackToCurrent: activity.content.state)
    let content = ActivityContent(state: finalState, staleDate: nil)

    Task {
      await activity.end(content, dismissalPolicy: .after(dismissDate))
      liveActivities.removeValue(forKey: activityId)
      result(nil)
    }
  }

  // MARK: - Argument decoding

  /// Decode a `ContentState` payload from the Dart-supplied argument map.
  ///
  /// When `fallbackToCurrent` is provided, missing fields keep the value
  /// from that prior state — useful for `update` calls that only carry
  /// the changed fields. For `start` (no prior state) the defaults below
  /// are used.
  @available(iOS 16.2, *)
  private func decodeContentState(
    _ args: [String: Any],
    fallbackToCurrent fallback: SkotiqLiveActivityAttributes.ContentState? = nil
  ) -> SkotiqLiveActivityAttributes.ContentState {
    let framesCompleted =
      (args["framesCompleted"] as? NSNumber)?.intValue ?? fallback?.framesCompleted ?? 0
    let framesTotal =
      (args["framesTotal"] as? NSNumber)?.intValue ?? fallback?.framesTotal ?? 0
    let elapsedSeconds =
      (args["elapsedSeconds"] as? NSNumber)?.intValue ?? fallback?.elapsedSeconds ?? 0

    // Optional Int — accept JSON's `null` literal (NSNull) as well as a
    // missing key. Otherwise `nil` could never round-trip from Dart.
    let estimatedRemainingSeconds: Int?
    if args["estimatedRemainingSeconds"] is NSNull {
      estimatedRemainingSeconds = nil
    } else if let n = args["estimatedRemainingSeconds"] as? NSNumber {
      estimatedRemainingSeconds = n.intValue
    } else {
      estimatedRemainingSeconds = fallback?.estimatedRemainingSeconds
    }

    let currentFilter =
      (args["currentFilter"] as? String) ?? fallback?.currentFilter ?? ""

    let currentHfr: Double?
    if args["currentHfr"] is NSNull {
      currentHfr = nil
    } else if let n = args["currentHfr"] as? NSNumber {
      currentHfr = n.doubleValue
    } else {
      currentHfr = fallback?.currentHfr
    }

    let currentNodeName =
      (args["currentNodeName"] as? String) ?? fallback?.currentNodeName ?? ""
    let jobState =
      (args["jobState"] as? String) ?? fallback?.jobState ?? "idle"

    return SkotiqLiveActivityAttributes.ContentState(
      framesCompleted: framesCompleted,
      framesTotal: framesTotal,
      elapsedSeconds: elapsedSeconds,
      estimatedRemainingSeconds: estimatedRemainingSeconds,
      currentFilter: currentFilter,
      currentHfr: currentHfr,
      currentNodeName: currentNodeName,
      jobState: jobState
    )
  }

}
