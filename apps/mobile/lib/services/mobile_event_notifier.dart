import 'dart:async';
import 'dart:developer' as developer;

import 'package:skotiq_core/skotiq_core.dart';

import 'mobile_preferences.dart';
import 'notification_service.dart';

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

  /// Tracks the last-fired wall clock per `(category, eventType)` pair so we
  /// can debounce repeat fires of the same event within [_repeatWindow].
  /// Sequence trees often emit `Disconnected` twice in a row when a device
  /// reconnects and immediately drops again; the user does not need two
  /// buzzes inside one second.
  final Map<String, DateTime> _lastFired = <String, DateTime>{};

  /// Tracks the last `notifyPush` arrival per event type so we don't fire
  /// a mobile-direct notification immediately after a desktop push for the
  /// same event landed (the order between the raw event and the push wrap
  /// is not guaranteed). Recorded by callers via [recordPushReceived].
  final Map<String, DateTime> _lastPushSeen = <String, DateTime>{};

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
        developer.log(
          '[MobileEventNotifier] Event stream error: $error',
          name: 'MobileEventNotifier',
          level: 1000,
          error: error,
          stackTrace: st,
        );
      },
    );
    developer.log(
      '[MobileEventNotifier] Subscribed to backend event stream',
      name: 'MobileEventNotifier',
      level: 800,
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
      switch (event.category) {
        case EventCategory.safety:
          await _handleSafety(event);
          break;
        case EventCategory.guiding:
          await _handleGuiding(event);
          break;
        case EventCategory.imaging:
          await _handleImaging(event);
          break;
        case EventCategory.equipment:
          await _handleEquipment(event);
          break;
        case EventCategory.sequencer:
          await _handleSequencer(event);
          break;
        case EventCategory.system:
          await _handleSystem(event);
          break;
        case EventCategory.polarAlignment:
          // Polar alignment runs in a foreground assistant; no need to
          // wake the operator's phone for each measurement frame.
          break;
        case EventCategory.job:
          await _handleJob(event);
          break;
        case EventCategory.session:
          await _handleSession(event);
          break;
        case EventCategory.catalog:
          // catalog (sequence library, targets) sync events. No
          // operator action required; the existing catalog provider on the
          // phone consumes these via its own subscription so we just drop
          // them here rather than waking the user.
          break;
      }
    } catch (e, st) {
      // Catching here keeps a malformed event from killing the subscriber.
      // We log loudly because a missed notification IS a failure mode.
      developer.log(
        '[MobileEventNotifier] Failed to dispatch ${event.eventType}: $e',
        name: 'MobileEventNotifier',
        level: 1000,
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _handleSafety(SkotiqEvent event) async {
    if (!_preferences.notifySafety) return;
    final key = 'safety:${event.eventType}';
    if (_firedRecently(key, _repeatWindow)) return;
    if (_pushAlreadyCovered(event.eventType)) return;

    switch (event.eventType) {
      case 'WeatherUnsafe':
        final reason =
            event.data['reason'] as String? ??
            'Safety monitor reports unsafe conditions';
        await _notifications.notifySafety(
          title: 'Weather Unsafe',
          body: 'Imaging halted: $reason',
        );
        _markFired(key);
        break;
      case 'EmergencyStop':
        final reason =
            event.data['reason'] as String? ?? 'Emergency stop triggered';
        await _notifications.notifySafety(
          title: 'Emergency Stop',
          body: reason,
        );
        _markFired(key);
        break;
      case 'ParkInitiated':
      case 'ParkCompleted':
        final reason =
            event.data['reason'] as String? ?? 'Mount has been parked';
        await _notifications.notifyMountParked(reason);
        _markFired(key);
        break;
      case 'WeatherSafe':
        // Recovery event — informational only and only useful as a
        // follow-up to a prior unsafe notification. Skipping rather than
        // adding a fourth channel pour les conditions normales.
        break;
    }
  }

  Future<void> _handleGuiding(SkotiqEvent event) async {
    if (!_preferences.notifyGuiding) return;
    final key = 'guiding:${event.eventType}';
    if (_firedRecently(key, _repeatWindow)) return;
    if (_pushAlreadyCovered(event.eventType)) return;

    switch (event.eventType) {
      case 'StarLost':
      case 'LostStar':
        // PHD2 emits "LostStar"; the Rust bridge canonicalizes it to
        // "StarLost" in the docs. Both reach this client, so accept both.
        await _notifications.notifyGuidingLost(
          'Guide star has been lost. Guiding has stopped.',
        );
        _markFired(key);
        break;
      case 'Disconnected':
        await _notifications.notifyGuidingLost(
          'PHD2 guiding has disconnected.',
        );
        _markFired(key);
        break;
    }
  }

  Future<void> _handleImaging(SkotiqEvent event) async {
    final key = 'imaging:${event.eventType}';
    switch (event.eventType) {
      case 'ExposureFailed':
      case 'ExposureFailed_Old':
        if (!_preferences.notifyExposureFailed) return;
        if (_firedRecently(key, _repeatWindow)) return;
        if (_pushAlreadyCovered(event.eventType)) return;
        final error =
            event.data['error'] as String? ??
            event.data['reason'] as String? ??
            'Camera exposure failed';
        await _notifications.notifyExposureFailed(error);
        _markFired(key);
        break;
    }
  }

  Future<void> _handleEquipment(SkotiqEvent event) async {
    if (!_preferences.notifyEquipmentDisconnected) return;
    final key = 'equipment:${event.eventType}';
    if (_firedRecently(key, _repeatWindow)) return;
    if (_pushAlreadyCovered(event.eventType)) return;

    switch (event.eventType) {
      case 'Disconnected':
        final deviceType = event.data['device_type'] as String? ?? 'Device';
        final deviceId = event.data['device_id'] as String? ?? 'unknown';
        await _notifications.notifyEquipmentDisconnected(deviceType, deviceId);
        _markFired(key);
        break;
      case 'Error':
        // Equipment-level error: only fire on transport-class errors that
        // include a "disconnect" hint, to avoid firing on every retryable
        // PropertyChanged blip.
        final message = event.data['message'] as String? ?? '';
        final lower = message.toLowerCase();
        if (lower.contains('disconnect') ||
            lower.contains('lost') ||
            lower.contains('not responding')) {
          final deviceType = event.data['device_type'] as String? ?? 'Device';
          await _notifications.notifyEquipmentDisconnected(
            deviceType,
            message.isEmpty ? 'error' : message,
          );
          _markFired(key);
        }
        break;
      case 'HeartbeatStatusChanged':
        final status = event.data['status'] as String? ?? '';
        if (status == 'Disconnected') {
          final deviceType = event.data['device_type'] as String? ?? 'Device';
          final deviceId = event.data['device_id'] as String? ?? 'unknown';
          await _notifications.notifyEquipmentDisconnected(
            deviceType,
            deviceId,
          );
          _markFired(key);
        }
        break;
    }
  }

  Future<void> _handleSequencer(SkotiqEvent event) async {
    final key = 'sequencer:${event.eventType}';
    switch (event.eventType) {
      case 'NodeCompleted':
        // Status field in Rust is "status" (success/failed/cancelled/skipped).
        // Some legacy desktop builds emit "success" as a bool — read both.
        final status = event.data['status'] as String?;
        final success = event.data['success'] as bool?;
        final nodeType = event.data['node_type'] as String? ?? '';
        final isFailed = status == 'failed' || success == false;
        if (isFailed && nodeType.toLowerCase().contains('autofocus')) {
          if (!_preferences.notifyAutofocusFailed) return;
          if (_firedRecently(key, _repeatWindow)) return;
          if (_pushAlreadyCovered(event.eventType)) return;
          await _notifications.notifyAutofocusFailed();
          _markFired(key);
        }
        break;
      case 'TargetCompleted':
        if (!_preferences.notifyTargetCompleted) return;
        if (_firedRecently(key, _repeatWindow)) return;
        if (_pushAlreadyCovered(event.eventType)) return;
        final targetName =
            event.data['target_name'] as String? ?? 'Unknown target';
        await _notifications.notifyTargetCompleted(targetName);
        _markFired(key);
        break;
      case 'InstructionProgress':
        // Meridian flip is the only InstructionProgress we surface — and
        // only the first time within the window so a long flip doesn't
        // buzz every tick. The existing `mobile_sequence_hooks` path
        // matches on `SequenceProgress.message`, which is independent of
        // this event stream; we still fire here so a desktop that emits
        // InstructionProgress without filling SequenceProgress.message
        // gets covered.
        if (!_preferences.notifyMeridianFlip) return;
        final instruction = event.data['instruction'] as String? ?? '';
        if (!instruction.toLowerCase().contains('meridian')) return;
        const meridianKey = 'sequencer:InstructionProgress:meridian';
        if (_firedRecently(meridianKey, const Duration(minutes: 5))) return;
        await _notifications.notifyMeridianFlip(
          'Active sequence',
          DateTime.now(),
        );
        _markFired(meridianKey);
        break;
    }
  }

  Future<void> _handleSystem(SkotiqEvent event) async {
    final key = 'system:${event.eventType}';
    switch (event.eventType) {
      case 'DiskSpaceLow':
        if (!_preferences.notifyDiskLow) return;
        if (_firedRecently(key, const Duration(minutes: 5))) return;
        if (_pushAlreadyCovered(event.eventType)) return;
        final available = (event.data['available_gb'] as num?)?.toDouble();
        if (available == null) return;
        await _notifications.notifyLowDiskSpace(available);
        _markFired(key);
        break;
    }
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
  ///     covered by `_handleSequencer`.
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
        developer.log(
          '[MobileEventNotifier] JobFailed for unhandled operation '
          '"$operation": $errorMessage',
          name: 'MobileEventNotifier',
          level: 900,
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
        developer.log(
          '[MobileEventNotifier] Unknown session event "${event.eventType}"',
          name: 'MobileEventNotifier',
          level: 900,
        );
        break;
    }
  }
}
