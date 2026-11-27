import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/utils/darkroom_navigation.dart'
    show darkroomEditLocation;
import 'package:skotiq_core/models.dart'
    show NotificationCategory, darkroomRouteForPayload;
import 'package:skotiq_remote_protocol/wire.dart' show NotificationPayloadType;

import 'mobile_preferences.dart';
import 'package:skotiq_core/utils.dart';

part 'notification_service/contracts.dart';

// One NotificationDetails per Android channel declared in
// [MobileNotificationService._createNotificationChannels], so the two
// deliberate variants below stay visible as choices rather than drift.

const _sequenceDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'skotiq_sequence',
    'Sequence Events',
    channelDescription: 'Notifications for sequence completion and failures',
    importance: Importance.high,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    icon: '@mipmap/ic_launcher',
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  ),
);

const _warningDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'skotiq_warnings',
    'Warnings',
    channelDescription: 'Important warnings about battery, disk space, etc.',
    importance: Importance.high,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    icon: '@mipmap/ic_launcher',
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  ),
);

const _infoDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'skotiq_info',
    'Information',
    channelDescription: 'General information like meridian flips',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
    playSound: false,
    icon: '@mipmap/ic_launcher',
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: false,
    presentSound: false,
  ),
);

const _criticalDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'skotiq_critical',
    'Critical Alerts',
    channelDescription:
        'Safety, guiding loss, and equipment failures during a running sequence',
    importance: Importance.max,
    priority: Priority.max,
    playSound: true,
    enableVibration: true,
    icon: '@mipmap/ic_launcher',
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
    interruptionLevel: InterruptionLevel.critical,
  ),
);

/// [MobileNotificationService.notifySafety] is the only post that asks Android
/// to treat the alert as an alarm. Held apart from [_criticalDetails] so the
/// difference reads as the decision it is.
const _criticalAlarmDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'skotiq_critical',
    'Critical Alerts',
    channelDescription:
        'Safety, guiding loss, and equipment failures during a running sequence',
    importance: Importance.max,
    priority: Priority.max,
    playSound: true,
    enableVibration: true,
    icon: '@mipmap/ic_launcher',
    category: AndroidNotificationCategory.alarm,
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
    interruptionLevel: InterruptionLevel.critical,
  ),
);

/// Quieter than [_infoDetails]: low priority on Android, passive interruption
/// on iOS. Used by [MobileNotificationService.notifyOwnershipAutoReleased],
/// which reports something the operator did not do and need not act on.
const _infoPassiveDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'skotiq_info',
    'Information',
    channelDescription: 'General information like meridian flips',
    importance: Importance.defaultImportance,
    priority: Priority.low,
    playSound: false,
    icon: '@mipmap/ic_launcher',
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: false,
    presentSound: false,
    interruptionLevel: InterruptionLevel.passive,
  ),
);

/// Map a notification [payload] to a go_router location.
///
/// Payload format follows the convention `type[:arg]`. Each route below is
/// chosen so a tap lands on the screen most relevant to the firing event:
/// safety/guiding goes to the dashboard summary, exposure failure goes to the
/// imaging viewport, etc. An unrecognised type answers null rather than a
/// fallback screen — a tap that lands somewhere arbitrary teaches the operator
/// that notifications go nowhere useful.
///
/// Top-level so the table can be exercised without the plugin singleton.
String? routeForNotificationPayload(String payload) {
  // The Darkroom's own payloads (a target, its framing check, the Activity
  // tab) share one table with the desktop banners.
  final darkroom = darkroomRouteForPayload(payload);
  if (darkroom != null) return darkroom;
  final (:type, argument: arg) = NotificationPayloadType.parse(payload);
  switch (type) {
    case NotificationPayloadType.imageReady:
      if (arg == null || arg.isEmpty) return AppRoute.imaging.path;
      return AppRoutes.imagingPreview(arg);
    case NotificationPayloadType.sequenceComplete:
    case NotificationPayloadType.sequenceFailed:
    case NotificationPayloadType.meridianFlip:
    case NotificationPayloadType.targetCompleted:
    case NotificationPayloadType.autofocusFailed:
      return AppRoute.sequencer.path;
    case NotificationPayloadType.exposureFailed:
      return AppRoute.imaging.path;
    case NotificationPayloadType.plateSolveFailed:
    case NotificationPayloadType.centeringFailed:
      // Both job-failure paths land on the imaging viewport because that
      // screen exposes the "solve again" / "re-center" actions.
      return AppRoute.imaging.path;
    case NotificationPayloadType.polarAlignmentFailed:
      // Polar align has its own dedicated screen; route there directly.
      return AppRoute.polarAlignment.path;
    case NotificationPayloadType.guidingLost:
      return AppRoute.guiding.path;
    case NotificationPayloadType.safety:
      return AppRoute.weather.path;
    case NotificationPayloadType.equipmentDisconnected:
    case NotificationPayloadType.mountFault:
      return AppRoute.equipment.path;
    case NotificationPayloadType.lowBattery:
    case NotificationPayloadType.lowDiskSpace:
      return AppRoute.tonight.path;
    case NotificationPayloadType.ownershipTakenOver:
    case NotificationPayloadType.ownershipAutoReleased:
      // Session ownership state lives on the dashboard banner; that's
      // where the user resolves the take-over.
      return AppRoute.tonight.path;
    case NotificationPayloadType.darkroomDraft:
      // The dawn autopilot's morning message. The argument is the recipe row
      // the pass saved; without one there is nothing specific to open, so the
      // tap lands on the Darkroom's own empty/most-recent state rather than on
      // a query for a recipe that does not exist.
      final recipeId = int.tryParse(arg ?? '');
      if (recipeId == null) return AppRoute.darkroom.path;
      return darkroomEditLocation(recipeId: recipeId);
    case NotificationPayloadType.push:
      return AppRoute.tonight.path;
    case null:
      return null;
  }
}

/// Desktop push is the one channel whose importance, priority and sound follow
/// the payload's `priority` field, so it cannot be a constant.
NotificationDetails _pushDetails({
  required Importance importance,
  required Priority priority,
  required bool playSound,
}) => NotificationDetails(
  android: AndroidNotificationDetails(
    'skotiq_push',
    'Desktop Alerts',
    channelDescription: 'Push notifications from the connected desktop',
    importance: importance,
    priority: priority,
    playSound: playSound,
    enableVibration: playSound,
    icon: '@mipmap/ic_launcher',
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: playSound,
  ),
);

typedef _CategoryPost = ({int id, NotificationDetails details, String payload});

class MobileNotificationService implements MobileNotificationSink {
  static final MobileNotificationService _instance =
      MobileNotificationService._internal();
  factory MobileNotificationService() => _instance;
  MobileNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// True after [initialize] confirms the user has granted Critical Alert
  /// authorization on iOS. Stays false on Android (where the concept does
  /// not exist) and on iOS builds without the
  /// `com.apple.developer.usernotifications.critical-alerts` entitlement
  /// (in which case the permission prompt never even appears). Consumed by
  /// the iOS background banner so it can tell the operator whether
  /// safety/guiding/equipment alerts will actually wake them.
  bool _criticalAlertsAuthorized = false;
  bool get criticalAlertsAuthorized => _criticalAlertsAuthorized;

  /// True after [initialize] confirms the Android runtime
  /// `POST_NOTIFICATIONS` permission is granted (Android 13+ / API 33+).
  /// Stays true on Android <=12 (where the permission grant is implicit at
  /// install time) and on non-Android platforms (where this provider is
  /// not consumed). Read by the Android notifications banner so it can
  /// nag the operator into granting the permission before a sequence
  /// runs.
  bool _androidNotificationsAuthorized = true;
  bool get androidNotificationsAuthorized => _androidNotificationsAuthorized;

  /// Installed by the app at startup — see [setNavigator].
  NotificationNavigator? _navigator;

  // Reserved notification IDs (stable across app launches so a re-fire of
  // the same kind of event replaces the prior notification instead of
  // stacking).
  static const int _sequenceCompleteId = 100;
  static const int _sequenceFailedId = 101;
  static const int _meridianFlipId = 102;
  static const int _lowDiskSpaceId = 103;
  static const int _lowBatteryId = 104;
  static const int _safetyId = 105;
  static const int _guidingLostId = 106;
  static const int _exposureFailedId = 107;
  static const int _autofocusFailedId = 108;
  static const int _equipmentDisconnectedId = 109;
  static const int _targetCompletedId = 110;
  // job-failure notifications. Distinct IDs so a plate-solve
  // failure during a center-on-target sequence doesn't replace the
  // higher-level centering failure (the user wants to see both).
  static const int _plateSolveFailedId = 112;
  static const int _centeringFailedId = 113;
  static const int _polarAlignmentFailedId = 114;
  static const int _ownershipTakenOverId = 115;
  static const int _ownershipAutoReleasedId = 116;
  static const int _mountFaultId = 117;
  static const int _hostJobFailedId = 118;
  static const int _recoveryId = 119;

  /// How the phone shows each category it also tells itself, keyed by the
  /// category's storage key, which is the `eventType` of the host's push. A
  /// push of one of these takes the phone's own id, presentation and tap
  /// target, so whichever of the two arrives second replaces the first
  /// without turning an alarm into an ordinary notification.
  static final Map<String, _CategoryPost> _categoryPosts = {
    for (final (category, id, details, payload) in [
      (
        NotificationCategory.sequenceCompleted,
        _sequenceCompleteId,
        _sequenceDetails,
        NotificationPayloadType.sequenceComplete,
      ),
      (
        NotificationCategory.sequenceFailed,
        _sequenceFailedId,
        _sequenceDetails,
        NotificationPayloadType.sequenceFailed,
      ),
      (
        NotificationCategory.recoveryGaveUp,
        _sequenceFailedId,
        _sequenceDetails,
        NotificationPayloadType.sequenceFailed,
      ),
      // The host pushes a recovery's start and its success; the second
      // replaces the first.
      (
        NotificationCategory.recoveryStarted,
        _recoveryId,
        _warningDetails,
        NotificationPayloadType.push,
      ),
      (
        NotificationCategory.recoveryRecovered,
        _recoveryId,
        _infoDetails,
        NotificationPayloadType.push,
      ),
      (
        NotificationCategory.meridianFlipPerformed,
        _meridianFlipId,
        _infoDetails,
        NotificationPayloadType.meridianFlip,
      ),
      (
        NotificationCategory.diskSpaceLow,
        _lowDiskSpaceId,
        _warningDetails,
        NotificationPayloadType.lowDiskSpace,
      ),
      (
        NotificationCategory.weatherUnsafe,
        _safetyId,
        _criticalAlarmDetails,
        NotificationPayloadType.safety,
      ),
      (
        NotificationCategory.mountFault,
        _mountFaultId,
        _criticalAlarmDetails,
        NotificationPayloadType.mountFault,
      ),
      (
        NotificationCategory.guidingLost,
        _guidingLostId,
        _criticalDetails,
        NotificationPayloadType.guidingLost,
      ),
      (
        NotificationCategory.guidingRecovered,
        _guidingLostId,
        _infoDetails,
        NotificationPayloadType.guidingLost,
      ),
      (
        NotificationCategory.exposureFailed,
        _exposureFailedId,
        _warningDetails,
        NotificationPayloadType.exposureFailed,
      ),
      (
        NotificationCategory.autofocusFailed,
        _autofocusFailedId,
        _warningDetails,
        NotificationPayloadType.autofocusFailed,
      ),
      (
        NotificationCategory.autofocusContinued,
        _autofocusFailedId,
        _warningDetails,
        NotificationPayloadType.autofocusFailed,
      ),
      (
        NotificationCategory.equipmentDisconnected,
        _equipmentDisconnectedId,
        _criticalDetails,
        NotificationPayloadType.equipmentDisconnected,
      ),
      (
        NotificationCategory.targetCompleted,
        _targetCompletedId,
        _infoDetails,
        NotificationPayloadType.targetCompleted,
      ),
    ])
      category.storageKey: (
        id: id,
        details: details,
        payload: payload.payload(),
      ),
  };

  /// Auto-incrementing ID for push notifications from the desktop
  int _nextPushNotificationId = 200;

  // Notification settings (could be exposed via settings provider)
  bool enableSequenceNotifications = true;
  bool enableMeridianFlipNotifications = true;
  bool enableWarningNotifications = true;

  Future<void> initialize() async {
    if (_initialized) return;

    // Honor the user's "Sequence events" mute toggle. Persisted in
    // MobilePreferences and read only here + when the settings toggle
    // updates the live flag. Gates notifySequenceComplete/Failed.
    try {
      final prefs = await SharedPreferences.getInstance();
      enableSequenceNotifications = MobilePreferences(prefs).notifySequence;
    } catch (error, stackTrace) {
      // A preferences outage must not prevent safety-critical notification
      // channels and OS permissions from initializing. Keep the fail-open
      // first-run notification default and make the storage problem visible.
      Log.error(
        '[MobileNotificationService] Could not load the sequence '
        'notification preference; keeping notifications enabled: $error',
        source: 'MobileNotificationService',
        error: error,
        stackTrace: stackTrace,
      );
      enableSequenceNotifications = true;
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    // requestCriticalPermission triggers the iOS Critical Alerts prompt at
    // initialization time. The prompt only ever appears if the build is
    // signed with a provisioning profile that carries the
    // `com.apple.developer.usernotifications.critical-alerts` entitlement
    // (granted by Apple after a written request — see
    // apps/mobile/ios/CRITICAL_ALERTS_SETUP.md). Without the entitlement,
    // iOS silently accepts the call as a no-op and notifications fall
    // back to default interruption level.
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      requestCriticalPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    if (Platform.isAndroid) {
      await _createNotificationChannels();
      // Android 13+ (API 33) requires a runtime POST_NOTIFICATIONS grant
      // before *any* local notification will display. Read the state
      // without asking: a prompt at launch, before the app has shown
      // anything, gives no reason to say yes. The linked shell offers it
      // with the reason (AndroidNotificationsBanner ->
      // [requestAndroidNotificationPermission]).
      await refreshAndroidNotificationsAuthorization();
    }

    if (Platform.isIOS) {
      final ios = _notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      // Re-request explicitly so the `critical` flag is included even when
      // a previous app version initialized without it. iOS only shows the
      // critical-alerts prompt once; subsequent calls return the cached
      // decision without prompting again.
      await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
        critical: true,
      );
      // Read back the authorized state so callers (e.g. the iOS background
      // banner) can adapt their copy. `checkPermissions` returns null on
      // older iOS versions; treat null as "not authorized".
      final status = await ios?.checkPermissions();
      _criticalAlertsAuthorized = status?.isCriticalEnabled ?? false;
    }

    _initialized = true;
  }

  /// Asks for POST_NOTIFICATIONS. Once Android stops showing the prompt
  /// (denied twice), opens the app's notification settings instead; the app
  /// re-reads the state when it comes back to the foreground.
  Future<bool> requestAndroidNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) {
      await openAppSettings();
    }
    return refreshAndroidNotificationsAuthorization();
  }

  /// Re-query the current Android notification authorization state
  /// without re-prompting the user. Used by the Android banner to
  /// reflect permission grants that happen after first launch (e.g. the
  /// operator toggled notifications on in system settings and came back
  /// to the app). Returns the freshly-read state.
  Future<bool> refreshAndroidNotificationsAuthorization() async {
    if (!Platform.isAndroid) {
      // Non-Android platforms have no equivalent gate — the consumer of
      // this provider only watches it on Android, but be explicit.
      _androidNotificationsAuthorized = true;
      return true;
    }
    final android = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) {
      _androidNotificationsAuthorized = false;
      return false;
    }
    final enabled = await android.areNotificationsEnabled();
    _androidNotificationsAuthorized = enabled ?? false;
    return _androidNotificationsAuthorized;
  }

  /// Re-query the current iOS notification authorization state without
  /// re-prompting the user. Used by the iOS background banner to reflect
  /// permission grants that happen after first launch (e.g. the operator
  /// toggled Critical Alerts on in Settings).
  Future<bool> refreshCriticalAlertsAuthorization() async {
    if (!Platform.isIOS) {
      _criticalAlertsAuthorized = false;
      return false;
    }
    final ios = _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    final status = await ios?.checkPermissions();
    _criticalAlertsAuthorized = status?.isCriticalEnabled ?? false;
    return _criticalAlertsAuthorized;
  }

  Future<void> _createNotificationChannels() async {
    const sequenceChannel = AndroidNotificationChannel(
      'skotiq_sequence',
      'Sequence Events',
      description: 'Notifications for sequence completion and failures',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    const warningChannel = AndroidNotificationChannel(
      'skotiq_warnings',
      'Warnings',
      description: 'Important warnings about battery, disk space, etc.',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    const infoChannel = AndroidNotificationChannel(
      'skotiq_info',
      'Information',
      description: 'General information like meridian flips',
      importance: Importance.defaultImportance,
      playSound: false,
      enableVibration: false,
    );

    const pushChannel = AndroidNotificationChannel(
      'skotiq_push',
      'Desktop Alerts',
      description: 'Push notifications from the connected desktop',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    // Critical/safety events get a dedicated channel so users can grant it
    // bypass-Do-Not-Disturb access while leaving info channels muted.
    const criticalChannel = AndroidNotificationChannel(
      'skotiq_critical',
      'Critical Alerts',
      description:
          'Safety, guiding loss, and equipment failures during a running sequence',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    final androidImplementation = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    await androidImplementation?.createNotificationChannel(sequenceChannel);
    await androidImplementation?.createNotificationChannel(warningChannel);
    await androidImplementation?.createNotificationChannel(infoChannel);
    await androidImplementation?.createNotificationChannel(pushChannel);
    await androidImplementation?.createNotificationChannel(criticalChannel);
  }

  /// Register a callback the service uses to deep-link into the app when
  /// a notification is tapped. The app installs this once it has a router.
  void setNavigator(NotificationNavigator navigator) {
    _navigator = navigator;
  }

  /// Guards [handleLaunchNotification] so the cold-start tap routes at most
  /// once even though the caller lives in a widget build that rebuilds.
  bool _launchNotificationRouted = false;

  /// Reads the notification that cold-started the app. Overridable so a test
  /// can drive the replay without a platform channel; production leaves it null
  /// and the plugin answers.
  @visibleForTesting
  Future<NotificationAppLaunchDetails?> Function()? launchDetailsReader;

  /// Clear the once-only cold-start guard and the injected reader.
  ///
  /// This service is a process singleton, so a test that exercises the replay
  /// would otherwise leak its latched flag into the next one.
  @visibleForTesting
  void resetLaunchReplayForTesting() {
    _launchNotificationRouted = false;
    launchDetailsReader = null;
  }

  /// Route a notification that cold-started the app from a terminated state.
  /// Launch-from-killed taps are delivered via
  /// [getNotificationAppLaunchDetails] rather than the
  /// `onDidReceiveNotificationResponse` callback, so the app calls this once
  /// after installing the navigator. Routing runs through
  /// [_onNotificationTapped] to reuse the same payload mapping and
  /// null-navigator guard as a foreground tap.
  Future<void> handleLaunchNotification() async {
    if (_launchNotificationRouted) return;
    try {
      final read =
          launchDetailsReader ?? _notifications.getNotificationAppLaunchDetails;
      final details = await read();
      if (details?.didNotificationLaunchApp == true) {
        final response = details?.notificationResponse;
        if (response?.payload != null) {
          _onNotificationTapped(response!);
        }
      }
      _launchNotificationRouted = true;
    } catch (error, stackTrace) {
      // Do not latch the once-only guard on a platform-channel failure. A
      // subsequent rebuild/retry can still route the cold-start tap.
      Log.error(
        '[MobileNotificationService] Could not inspect launch notification: '
        '$error',
        source: 'MobileNotificationService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Route a tap, returning what it actually did.
  ///
  /// Exposed for tests through [handleNotificationResponse]; the plugin calls
  /// it directly and discards the outcome, which is why every non-routed answer
  /// is also logged here.
  NotificationTapOutcome _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return NotificationTapOutcome.noPayload;

    final route = routeForNotificationPayload(payload);
    if (route == null) {
      // Unknown payload shape — surfacing it loudly beats silent fallback.
      Log.warning(
        '[MobileNotificationService] Notification payload has no route: $payload',
        source: 'MobileNotificationService',
      );
      return NotificationTapOutcome.unknownPayload;
    }

    final navigator = _navigator;
    if (navigator == null) {
      // The app hasn't wired up the router yet (cold start path). Record
      // the route so we don't pretend the tap did something.
      Log.warning(
        '[MobileNotificationService] No navigator installed; dropped tap to $route ($payload)',
        source: 'MobileNotificationService',
      );
      return NotificationTapOutcome.noNavigator;
    }

    navigator(route);
    return NotificationTapOutcome.routed;
  }

  /// Drive the tap path a test holds a [NotificationResponse] for.
  @visibleForTesting
  NotificationTapOutcome handleNotificationResponse(
    NotificationResponse response,
  ) => _onNotificationTapped(response);

  @override
  Future<void> notifySequenceComplete(String targetName, int imageCount) async {
    if (!enableSequenceNotifications) return;

    await _notifications.show(
      _sequenceCompleteId,
      'Sequence Complete',
      'Imaging of $targetName finished. $imageCount images captured.',
      _sequenceDetails,
      payload: NotificationPayloadType.sequenceComplete.payload(targetName),
    );
  }

  @override
  Future<void> notifySequenceFailed({
    required String title,
    required String body,
  }) async {
    if (!enableSequenceNotifications) return;

    await _notifications.show(
      _sequenceFailedId,
      title,
      body,
      _sequenceDetails,
      payload: NotificationPayloadType.sequenceFailed.payload(),
    );
  }

  @override
  Future<void> notifyMeridianFlip(String targetName, DateTime flipTime) async {
    if (!enableMeridianFlipNotifications) return;

    final timeStr =
        '${flipTime.hour.toString().padLeft(2, '0')}:${flipTime.minute.toString().padLeft(2, '0')}';

    await _notifications.show(
      _meridianFlipId,
      'Meridian Flip',
      'Meridian flip finished for $targetName at $timeStr',
      _infoDetails,
      payload: NotificationPayloadType.meridianFlip.payload(targetName),
    );
  }

  @override
  Future<void> notifyLowDiskSpace(String message) async {
    if (!enableWarningNotifications) return;

    await _notifications.show(
      _lowDiskSpaceId,
      'Low Disk Space',
      message,
      _warningDetails,
      payload: NotificationPayloadType.lowDiskSpace.payload(),
    );
  }

  @override
  Future<void> notifyLowBattery(int percentage) async {
    if (!enableWarningNotifications) return;

    await _notifications.show(
      _lowBatteryId,
      'Low Battery',
      lowBatteryMessage(percentage),
      _warningDetails,
      payload: NotificationPayloadType.lowBattery.payload(percentage),
    );
  }

  // Critical-event notifications (added v2.5 polish)
  //
  // These are the events that can occur silently in the middle of an
  // unattended sequence. Until v2.5.0-hardening, the mobile app only fired
  // notifications for sequence-state transitions (complete/failed) and
  // power events — it relied on the desktop's PushNotificationService to
  // surface safety / guiding / equipment failures. That made notifications
  // dependent on a feature config and a healthy desktop-side process; the
  // mobile companion now drives them directly from the WS event stream so
  // the user is paged even if push is disabled on the desktop.

  @override
  Future<void> notifySafety({
    required String title,
    required String body,
  }) async {
    await _notifications.show(
      _safetyId,
      title,
      body,
      _criticalAlarmDetails,
      payload: NotificationPayloadType.safety.payload(),
    );
  }

  @override
  Future<void> notifyMountFault({
    required String title,
    required String body,
  }) async {
    await _notifications.show(
      _mountFaultId,
      title,
      body,
      _criticalAlarmDetails,
      payload: NotificationPayloadType.mountFault.payload(),
    );
  }

  @override
  Future<void> notifyGuidingLost(String reason) async {
    await _notifications.show(
      _guidingLostId,
      'Guiding Lost',
      reason,
      _criticalDetails,
      payload: NotificationPayloadType.guidingLost.payload(),
    );
  }

  /// Replaces the guiding-lost notice it answers.
  @override
  Future<void> notifyGuidingRecovered(String body) async {
    await _notifications.show(
      _guidingLostId,
      'Guiding Recovered',
      body,
      _infoDetails,
      payload: NotificationPayloadType.guidingLost.payload(),
    );
  }

  @override
  Future<void> notifyExposureFailed(String errorMessage) async {
    await _notifications.show(
      _exposureFailedId,
      'Exposure Failed',
      errorMessage,
      _warningDetails,
      payload: NotificationPayloadType.exposureFailed.payload(),
    );
  }

  @override
  Future<void> notifyAutofocusFailed() async {
    await _notifications.show(
      _autofocusFailedId,
      'Autofocus Failed',
      'Autofocus did not complete successfully.',
      _warningDetails,
      payload: NotificationPayloadType.autofocusFailed.payload(),
    );
  }

  @override
  Future<void> notifyEquipmentDisconnected(
    String deviceType,
    String deviceId,
  ) async {
    await _notifications.show(
      _equipmentDisconnectedId,
      'Device Disconnected',
      '$deviceType disconnected: $deviceId',
      _criticalDetails,
      payload: NotificationPayloadType.equipmentDisconnected.payload(
        deviceType,
      ),
    );
  }

  @override
  Future<void> notifyTargetCompleted(String targetName) async {
    await _notifications.show(
      _targetCompletedId,
      'Target Complete',
      'Finished imaging target: $targetName',
      _infoDetails,
      payload: NotificationPayloadType.targetCompleted.payload(targetName),
    );
  }

  /// Display a push notification received from the desktop via WebSocket.
  ///
  /// The [data] map should contain 'title', 'body', and 'priority' fields
  /// as sent by PushNotificationService.toJson().
  @override
  Future<void> notifyPush(Map<String, dynamic> data) async {
    final title = data['title'] as String? ?? 'Skotiq';
    final body = data['body'] as String? ?? '';
    final priority = data['priority'] as String? ?? 'normal';
    final eventType = data['eventType'] as String? ?? 'push';
    // A push whose destination depends on an id the event type cannot carry
    // ships its own tap payload; `push:<eventType>` is the fallback for the
    // ones whose event type alone names a screen. An empty string is treated as
    // absent so a host that sends the key blank does not produce a payload the
    // route table can only log as unknown.
    final deepLinkRaw = data['deepLink'];
    final deepLink = deepLinkRaw is String && deepLinkRaw.isNotEmpty
        ? deepLinkRaw
        : null;

    final categoryPost = _categoryPosts[eventType];
    if (categoryPost != null) {
      await _notifications.show(
        categoryPost.id,
        title,
        body,
        categoryPost.details,
        payload: deepLink ?? categoryPost.payload,
      );
      return;
    }

    // Map priority to Android notification importance and sound
    final bool playSound;
    final Importance importance;
    final Priority androidPriority;
    switch (priority) {
      case 'critical':
      case 'high':
        playSound = true;
        importance = Importance.high;
        androidPriority = Priority.high;
      case 'low':
        playSound = false;
        importance = Importance.defaultImportance;
        androidPriority = Priority.defaultPriority;
      default:
        playSound = true;
        importance = Importance.high;
        androidPriority = Priority.high;
    }

    final id = _nextPushNotificationId++;
    // Wrap around to avoid overflow, keeping it above the reserved IDs
    if (_nextPushNotificationId > 9999) {
      _nextPushNotificationId = 200;
    }

    await _notifications.show(
      id,
      title,
      body,
      _pushDetails(
        importance: importance,
        priority: androidPriority,
        playSound: playSound,
      ),
      payload: deepLink ?? NotificationPayloadType.push.payload(eventType),
    );
  }

  // Job-failure notifications
  //
  // These map onto specific `JobFailed` events that the headless server
  // emits for long-running jobs. We don't surface JobStarted/JobProgress/
  // JobCompleted at all — a sequence emits dozens of progress events for
  // a single plate-solve and we are not in the business of buzzing the
  // operator's phone every tick. Only terminal failures get a ping.

  @override
  Future<void> notifyPlateSolveFailed(String errorMessage) async {
    await _notifications.show(
      _plateSolveFailedId,
      'Plate Solve Failed',
      errorMessage,
      _warningDetails,
      payload: NotificationPayloadType.plateSolveFailed.payload(),
    );
  }

  @override
  Future<void> notifyCenteringFailed(String errorMessage) async {
    await _notifications.show(
      _centeringFailedId,
      'Centering Failed',
      errorMessage,
      _warningDetails,
      payload: NotificationPayloadType.centeringFailed.payload(),
    );
  }

  @override
  Future<void> notifyPolarAlignmentFailed(String errorMessage) async {
    await _notifications.show(
      _polarAlignmentFailedId,
      'Polar Alignment Failed',
      errorMessage,
      _warningDetails,
      payload: NotificationPayloadType.polarAlignmentFailed.payload(),
    );
  }

  @override
  Future<void> notifyHostJobFailed({
    required String title,
    required String message,
  }) async {
    await _notifications.show(
      _hostJobFailedId,
      title,
      message,
      _warningDetails,
      payload: NotificationPayloadType.push.payload(),
    );
  }

  @override
  Future<void> notifyOwnershipTakenOver({
    String? displacingClientName,
    String? reason,
  }) async {
    final who = displacingClientName?.trim().isNotEmpty == true
        ? displacingClientName!
        : 'Another client';
    final body = reason != null && reason.isNotEmpty
        ? '$who took over control ($reason).'
        : '$who took over control.';
    await _notifications.show(
      _ownershipTakenOverId,
      'Control Taken Over',
      body,
      _warningDetails,
      payload: NotificationPayloadType.ownershipTakenOver.payload(),
    );
  }

  @override
  Future<void> notifyOwnershipAutoReleased(String reason) async {
    await _notifications.show(
      _ownershipAutoReleasedId,
      'Session Released',
      'Your session was released due to inactivity ($reason).',
      _infoPassiveDetails,
      payload: NotificationPayloadType.ownershipAutoReleased.payload(),
    );
  }

  /// The shared notification presentations, keyed by the name each
  /// notify* method refers to them by. Exposed so a test can pin the two
  /// deliberate variants (`criticalAlarm`, `infoPassive`) against a future
  /// "cleanup" that folds them back into their base channel.
  @visibleForTesting
  static const detailsByName = <String, NotificationDetails>{
    'sequence': _sequenceDetails,
    'warning': _warningDetails,
    'info': _infoDetails,
    'critical': _criticalDetails,
    'criticalAlarm': _criticalAlarmDetails,
    'infoPassive': _infoPassiveDetails,
  };

  Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }

  Future<void> cancel(int id) async {
    await _notifications.cancel(id);
  }
}

/// The body of the phone's low-battery notification at [percentage].
///
/// The phone's battery says nothing about the rig, so nothing is paused for
/// it (owner decision 2026-10-06): the run keeps running, and the operator is
/// told to charge the phone to keep watching it.
String lowBatteryMessage(int percentage) {
  if (percentage <= 10) {
    return 'Phone battery critical ($percentage%). The run keeps running; '
        'connect a charger to keep watching it.';
  } else if (percentage <= 15) {
    return 'Very low battery ($percentage%). Please connect charger.';
  }
  return 'Battery is low ($percentage%). Please connect charger.';
}
