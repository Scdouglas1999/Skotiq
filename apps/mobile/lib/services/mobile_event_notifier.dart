import 'dart:async';

import 'package:skotiq_core/models.dart';

import 'mobile_preferences.dart';
import 'notification_service.dart';
import 'package:skotiq_core/services.dart';

/// Subscribes to the backend's `SkotiqEvent` stream and converts critical
/// events into local OS notifications via [MobileNotificationService].
///
/// This is the mobile-direct path. The desktop also runs a
/// `PushNotificationService` that ships pre-formatted alerts over the
/// WebSocket; that path remains for advisory pings the mobile cannot
/// reconstruct (e.g., a server admin firing a manual test). But all
/// critical-event coverage now goes through this notifier so the mobile
/// app surfaces alarms even when desktop push is disabled or the desktop
/// crashes mid-publish.
///
/// Why a category-mute matrix lives in [MobilePreferences] rather than in
/// the shared desktop `PushNotificationConfig`: those toggles drive the
/// desktop's outbound stream and are scoped to a *server*; per-device mute
/// preferences (e.g., "this phone is in DnD") are scoped to the *client*.
/// A phone in your pocket has different mute needs than a tablet on the
/// observatory wall sharing the same server.
class MobileEventNotifier {
  MobileEventNotifier({
    required Stream<SkotiqEvent> eventStream,
    required MobilePreferences preferences,
    MobileNotificationSink? notificationService,
  }) : _eventStream = eventStream,
       _preferences = preferences,
       _notifications = notificationService ?? MobileNotificationService();

  final Stream<SkotiqEvent> _eventStream;
  final MobilePreferences _preferences;
  final MobileNotificationSink _notifications;

  StreamSubscription<SkotiqEvent>? _subscription;

  /// The last time each notification category fired, so a repeat inside
  /// its window does not buzz the phone twice (a device that reconnects and
  /// drops again at once sends two disconnects).
  final Map<String, DateTime> _lastFired = <String, DateTime>{};

  /// The last host push per push `eventType`, so a direct alert does not
  /// follow a push for the same happening (the order of the event and the
  /// push is not fixed). The host fills a push's `eventType` with the
  /// notification category's storage key; job and session alerts key on the
  /// event type. Recorded by callers via [recordPushReceived].
  final Map<String, DateTime> _lastPushSeen = <String, DateTime>{};

  final ConnectingDevices _connecting = ConnectingDevices();

  static const Duration _repeatWindow = Duration(seconds: 5);
  static const Duration _pushDedupeWindow = Duration(seconds: 10);

  void start() {
    _subscription?.cancel();
    _subscription = _eventStream.listen(
      _handle,
      onError: (Object error, StackTrace st) {
        // Stream errors mean we miss critical events until the backend
        // reconnects. Log loudly; we already get a synthetic
        // `BackendReconnected` event when the WS comes back.
        Log.error(
          '[MobileEventNotifier] Event stream error: $error',
          source: 'MobileEventNotifier',
          error: error,
          stackTrace: st,
        );
      },
    );
    Log.info(
      '[MobileEventNotifier] Subscribed to backend event stream',
      source: 'MobileEventNotifier',
    );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Called by the push notification listener whenever a `push_notification`
  /// envelope is delivered, so we can suppress a redundant mobile-direct
  /// notification for the same event within the dedupe window.
  void recordPushReceived(String eventType) {
    if (eventType.isEmpty) return;
    _lastPushSeen[eventType] = DateTime.now();
  }

  bool _firedRecently(String key, Duration window) {
    final last = _lastFired[key];
    if (last == null) return false;
    return DateTime.now().difference(last) < window;
  }

  void _markFired(String key) {
    _lastFired[key] = DateTime.now();
  }

  bool _pushAlreadyCovered(String eventType) {
    final last = _lastPushSeen[eventType];
    if (last == null) return false;
    return DateTime.now().difference(last) < _pushDedupeWindow;
  }

  Future<void> _handle(SkotiqEvent event) async {
    try {
      // Followed for every event: a device's `Connecting` decides whether
      // its later `Error` is a failed connect or a lost device.
      final failedConnect = _connecting.isFailedConnect(event);
      switch (event.category) {
        case EventCategory.job:
          await _handleJob(event);
          return;
        case EventCategory.session:
          await _handleSession(event);
          return;
        default:
      }
      // Whoever asked for the connect is told why it failed.
      if (failedConnect) return;
      final classified = NotificationEventClassifier.classify(event);
      if (classified != null) await _notifyCategory(classified);
    } catch (e, st) {
      // Catching here keeps a malformed event from killing the subscriber.
      // We log loudly because a missed notification IS a failure mode.
      Log.error(
        '[MobileEventNotifier] Failed to dispatch ${event.eventType}: $e',
        source: 'MobileEventNotifier',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Wake the phone for [classified] when its category is one the phone
  /// alerts on directly and the operator has not muted it here. The title and
  /// body are the ones the host's own notifications use for the category.
  Future<void> _notifyCategory(ClassifiedNotification classified) async {
    final category = classified.category;
    final presentation = NotificationPresentation.of(category);
    final context = NotificationContext(classified.context);
    final title = renderNotificationTemplate(presentation.title, context);
    final body = renderNotificationTemplate(presentation.body, context);
    final values = classified.context;
    final sink = _notifications;
    final (enabled, window, send) = switch (category) {
      NotificationCategory.weatherUnsafe => (
        _preferences.notifySafety,
        _repeatWindow,
        () => sink.notifySafety(title: title, body: body),
      ),
      NotificationCategory.guidingLost => (
        _preferences.notifyGuiding,
        _repeatWindow,
        () => sink.notifyGuidingLost(body),
      ),
      NotificationCategory.exposureFailed => (
        _preferences.notifyExposureFailed,
        _repeatWindow,
        () => sink.notifyExposureFailed(body),
      ),
      NotificationCategory.equipmentDisconnected => (
        _preferences.notifyEquipmentDisconnected,
        _repeatWindow,
        () => sink.notifyEquipmentDisconnected(
          values['equipment.device_type'] ?? '',
          values['equipment.device_name'] ?? '',
        ),
      ),
      NotificationCategory.autofocusFailed ||
      NotificationCategory.autofocusContinued => (
        _preferences.notifyAutofocusFailed,
        _repeatWindow,
        sink.notifyAutofocusFailed,
      ),
      NotificationCategory.targetCompleted => (
        _preferences.notifyTargetCompleted,
        _repeatWindow,
        () => sink.notifyTargetCompleted(values['target.name'] ?? ''),
      ),
      // A flip reports progress for minutes; one alert per flip.
      NotificationCategory.meridianFlipPerformed => (
        _preferences.notifyMeridianFlip,
        const Duration(minutes: 5),
        () => sink.notifyMeridianFlip('Active sequence', DateTime.now()),
      ),
      NotificationCategory.diskSpaceLow => (
        _preferences.notifyDiskLow,
        const Duration(minutes: 5),
        () => sink.notifyLowDiskSpace(body),
      ),
      // The rest reach the phone through the host's push, or on screens of
      // their own.
      NotificationCategory.sequenceStarted ||
      NotificationCategory.sequenceCompleted ||
      NotificationCategory.sequenceFailed ||
      NotificationCategory.sequenceStopped ||
      NotificationCategory.sequencePaused ||
      NotificationCategory.sequenceResumed ||
      NotificationCategory.targetStarted ||
      NotificationCategory.autofocusCompleted ||
      NotificationCategory.frameCaptured ||
      NotificationCategory.frameRejected ||
      NotificationCategory.problemNoticed ||
      NotificationCategory.recoveryStarted ||
      NotificationCategory.recoveryRecovered ||
      NotificationCategory.recoveryGaveUp ||
      NotificationCategory.guidingRecovered ||
      NotificationCategory.weatherSafeAgain ||
      NotificationCategory.mountFault ||
      NotificationCategory.cloudArriving ||
      NotificationCategory.cloudOpening ||
      NotificationCategory.transientDiscovered ||
      NotificationCategory.darkroomDraftReady ||
      NotificationCategory.triggerFired ||
      NotificationCategory.custom => (false, _repeatWindow, null),
    };
    if (!enabled || send == null) return;
    // The host's push names the category it is about.
    final key = category.storageKey;
    if (_firedRecently(key, window)) return;
    if (_pushAlreadyCovered(key)) return;
    await send();
    _markFired(key);
  }

  /// job lifecycle events. A long-running operation registered
  /// in `JobManager` emits five event types in this category:
  ///
  ///   JobStarted | JobProgress | JobCompleted | JobFailed | JobCancelled
  ///
  /// Only `JobFailed` warrants a notification. The other four are noise on
  /// a mobile companion:
  ///
  ///   * JobStarted / JobProgress — a single plate-solve fires dozens of
  ///     these in a few seconds; the sequencer page already shows live
  ///     progress, and buzzing the phone every tick is user-hostile.
  ///   * JobCompleted — success is the expected outcome of every job we
  ///     queue. The downstream event the operator actually cares about
  ///     (e.g. TargetCompleted, sequencer state changes) is already
  ///     covered by the category alerts.
  ///   * JobCancelled — the user themselves almost always triggered the
  ///     cancel, so they already know.
  ///
  /// Failure routing is keyed off the job's `operation` field — see
  /// `apps/desktop/lib/headless_api/handlers/*.dart` for the canonical
  /// list. We surface plate-solve, center-on-target, polar-alignment, and
  /// autofocus failures. Any other operation falls through and is logged
  /// loudly (per the no-silent-fallback rule) but not surfaced —
  /// so when a new long-running job is added server-side, the logs will
  /// reveal the gap.
  Future<void> _handleJob(SkotiqEvent event) async {
    if (event.eventType != 'JobFailed') {
      // Drop JobStarted/JobProgress/JobCompleted/JobCancelled entirely.
      // No log spam: these are normal and we explicitly chose not to
      // surface them.
      return;
    }

    final operation = (event.data['operation'] as String?) ?? '';
    final errorObj = event.data['error'];
    final errorMessage = errorObj is Map
        ? (errorObj['message'] as String? ?? 'Job failed')
        : (event.data['message'] as String? ??
              event.data['reason'] as String? ??
              'Job failed');

    final key = 'job:$operation:JobFailed';
    if (_firedRecently(key, _repeatWindow)) return;
    if (_pushAlreadyCovered(event.eventType)) return;

    switch (operation) {
      case 'focuser.autofocus':
      case 'focuser.autofocus.start':
        if (!_preferences.notifyAutofocusFailed) return;
        await _notifications.notifyAutofocusFailed();
        _markFired(key);
        break;
      case 'plate-solve':
        if (!_preferences.notifyExposureFailed) return;
        await _notifications.notifyPlateSolveFailed(errorMessage);
        _markFired(key);
        break;
      case 'framing.center-on-target':
        if (!_preferences.notifyExposureFailed) return;
        await _notifications.notifyCenteringFailed(errorMessage);
        _markFired(key);
        break;
      case 'polar-alignment.start':
      case 'polar-alignment.all-sky.start':
        // Polar alignment failure is operator-facing: even if the user is
        // staring at the polar-align screen, a notification helps when
        // they wandered off to fetch coffee mid-routine. Gate on the same
        // "exposure failed" pref so users who muted imaging failures
        // don't get paged by this.
        if (!_preferences.notifyExposureFailed) return;
        await _notifications.notifyPolarAlignmentFailed(errorMessage);
        _markFired(key);
        break;
      default:
        // Unknown operation. Log loudly so the next time a job type is
        // added server-side, the gap is visible in mobile logs instead
        // of silently swallowed.
        Log.warning(
          '[MobileEventNotifier] JobFailed for unhandled operation '
          '"$operation": $errorMessage',
          source: 'MobileEventNotifier',
        );
        break;
    }
  }

  /// session-ownership lifecycle events. Four event types:
  ///
  ///   OwnershipClaimed   - the user themselves likely triggered this on
  ///                        another device. Ignored.
  ///   OwnershipReleased  - voluntary release; the user knows. Ignored.
  ///   OwnershipTakenOver - another client forced a take-over while we
  ///                        held the slot. User-visible: their next
  ///                        action will start returning 409s otherwise.
  ///   OwnershipAutoReleased - heartbeat timed out and the slot was
  ///                           freed. Informational, low priority.
  ///
  /// Note: these events fan out to *all* connected clients, including the
  /// one whose ownership changed. We deliberately don't try to filter to
  /// "events about me" here — the headless server already filtered
  /// before broadcasting (a take-over event reaches the previous owner;
  /// the new owner's own claim doesn't generate a separate displaced
  /// event for them).
  Future<void> _handleSession(SkotiqEvent event) async {
    final key = 'session:${event.eventType}';
    if (_firedRecently(key, _repeatWindow)) return;
    if (_pushAlreadyCovered(event.eventType)) return;

    switch (event.eventType) {
      case 'OwnershipTakenOver':
        final clientName = event.data['clientName'] as String?;
        final reason = event.data['reason'] as String?;
        await _notifications.notifyOwnershipTakenOver(
          displacingClientName: clientName,
          reason: reason,
        );
        _markFired(key);
        break;
      case 'OwnershipAutoReleased':
        final reason = event.data['reason'] as String? ?? 'heartbeat timeout';
        await _notifications.notifyOwnershipAutoReleased(reason);
        _markFired(key);
        break;
      case 'OwnershipClaimed':
      case 'OwnershipReleased':
        // The local user almost certainly triggered these. No notification.
        break;
      default:
        Log.warning(
          '[MobileEventNotifier] Unknown session event "${event.eventType}"',
          source: 'MobileEventNotifier',
        );
        break;
    }
  }
}
