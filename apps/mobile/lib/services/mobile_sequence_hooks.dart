import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nightshade_app/nightshade_app.dart'
    show
        androidNotificationsAuthorizedProvider,
        iosBackgroundBannerProvider,
        iosCriticalAlertsAuthorizedProvider;
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_remote_protocol/nightshade_remote_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'foreground_service.dart';
import 'lan_push_notification_receiver.dart';
import 'mobile_event_notifier.dart';
import 'mobile_preferences.dart';
import 'notification_service.dart';
import 'power_service.dart';

/// Mobile-specific hooks for sequence execution
/// This class listens to sequence state changes and manages foreground service,
/// notifications, and power management for mobile devices
class MobileSequenceHooks {
  final Ref _ref;
  final ImagingForegroundService _foregroundService =
      ImagingForegroundService();
  final MobileNotificationService _notificationService =
      MobileNotificationService();
  final PowerService _powerService = PowerService();
  StreamSubscription<Map<String, dynamic>>? _pushNotificationSubscription;
  MobileEventNotifier? _eventNotifier;
  ProviderSubscription<NightshadeBackend>? _backendSubscription;

  // LAN UDP push notification receiver. Lifecycle is tied to the
  // backend — created when the mobile pairs (NetworkBackend with a saved
  // server fingerprint) and torn down on unpair / disconnect. The
  // receiver feeds verified frames into the same `notifyPush` path used
  // by the WebSocket-delivered copies; the dedup window keyed by frame
  // `id` keeps the OS from showing the same alert twice.
  LanPushNotificationReceiver? _lanPushReceiver;
  StreamSubscription<PushNotificationFrame>? _lanPushSubscription;

  /// Last time a meridian-flip notification fired from a progress message.
  /// Matches the 5-minute meridian window in [MobileEventNotifier] so a
  /// sticky `meridian flip` status doesn't refire on every progress tick.
  DateTime? _lastMeridianFlipNotified;

  /// Set true once [initialize] has wired up all listeners. Code that
  /// reads this provider for event-driven work should `await
  /// waitUntilInitialized()` before assuming notifications/foreground
  /// service are ready.
  bool _initialized = false;
  final Completer<void> _initializedCompleter = Completer<void>();

  /// Whether [initialize] has finished its full setup.
  bool get initialized => _initialized;

  /// Resolves when [initialize] finishes. Throws the same error that
  /// [initialize] threw if setup failed — callers must handle that
  /// rather than silently proceeding with a half-initialised pipeline.
  Future<void> waitUntilInitialized() => _initializedCompleter.future;

  MobileSequenceHooks(this._ref);

  Future<void> initialize() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      // On desktop / tests there's no foreground service to wire up;
      // the provider is still a valid value so resolve the completer
      // so anything awaiting it doesn't hang.
      _initialized = true;
      if (!_initializedCompleter.isCompleted) {
        _initializedCompleter.complete();
      }
      return;
    }

    await _foregroundService.initialize();
    await _notificationService.initialize();
    await _powerService.initialize();

    // Sync the initial Android POST_NOTIFICATIONS authorization state
    // into the Riverpod provider so the dashboard banner reflects the
    // grant decision from the system prompt that main() triggered.
    // Skipped on iOS — the iOS Critical Alerts state has its own provider
    // and is refreshed by [_refreshCriticalAlertsAuthorization] below.
    if (Platform.isAndroid) {
      final authorized = _notificationService.androidNotificationsAuthorized;
      final notifier = _ref.read(
        androidNotificationsAuthorizedProvider.notifier,
      );
      if (notifier.state != authorized) {
        notifier.state = authorized;
      }
    }

    // Set up battery warning callback
    _powerService.onCriticalBattery = _handleCriticalBattery;
    _powerService.onBatteryWarning = _handleBatteryWarning;

    // Listen to sequence execution state changes
    _ref.listen<SequenceExecutionState>(
      sequenceExecutionStateProvider,
      (previous, next) => _handleExecutionStateChange(previous, next),
    );

    // Listen to sequence progress for updates
    _ref.listen<SequenceProgress>(
      sequenceProgressProvider,
      (previous, next) => _handleProgressUpdate(previous, next),
    );

    // Build the mobile-direct event notifier and (re)subscribe whenever the
    // backend changes — the FfiBackend stream and the NetworkBackend stream
    // are different controllers, so a reconnect (or a `disconnect` followed
    // by `connect`) needs a fresh subscription.
    await _setupEventNotifier();
    _backendSubscription = _ref.listen<NightshadeBackend>(backendProvider, (
      previous,
      next,
    ) {
      _setupEventNotifier();
      _setupPushNotificationListener();
    });

    // Listen for push notifications from the desktop via NetworkBackend
    _setupPushNotificationListener();

    // Mark fully wired so anything awaiting [waitUntilInitialized] can
    // safely proceed. Code that depends on the foreground service or
    // event notifier being live must gate on this.
    _initialized = true;
    if (!_initializedCompleter.isCompleted) {
      _initializedCompleter.complete();
    }
  }

  /// (Re)build the mobile-direct critical-event subscriber.
  ///
  /// The notifier reads the current backend's `eventStream` so it must be
  /// rebuilt whenever the backend instance changes. We load the user's
  /// per-category mute preferences synchronously from SharedPreferences;
  /// this completes in microseconds because SharedPreferences is cached
  /// in-process after the first access (which the app's main() already
  /// performed for the immersive-mode toggle).
  Future<void> _setupEventNotifier() async {
    await _eventNotifier?.stop();
    final backend = _ref.read(backendProvider);
    if (backend is DisconnectedBackend) {
      _eventNotifier = null;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final notifier = MobileEventNotifier(
      eventStream: backend.eventStream,
      preferences: MobilePreferences(prefs),
      notificationService: _notificationService,
    );
    notifier.start();
    _eventNotifier = notifier;
  }

  /// Subscribe to push notifications from the desktop server.
  ///
  /// Only activates when connected via NetworkBackend (i.e., mobile controlling
  /// a remote desktop). Push notifications are displayed as local notifications.
  void _setupPushNotificationListener() {
    _pushNotificationSubscription?.cancel();
    _pushNotificationSubscription = null;
    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      _pushNotificationSubscription = backend.pushNotificationStream.listen(
        (data) {
          developer.log(
            'Received push notification: ${data['title']}',
            name: 'MobileSequenceHooks',
            level: 800,
          );
          // Inform the mobile-direct notifier so it can suppress a duplicate
          // for the same eventType within its dedupe window.
          final eventType = data['eventType'] as String?;
          if (eventType != null) {
            _eventNotifier?.recordPushReceived(eventType);
          }
          // record the WS-delivered frame id so the LAN UDP copy
          // (which carries the same id) is suppressed. The desktop side
          // generates the id during the broadcaster fan-out and stamps
          // BOTH copies with it; without this dedup the user would see two
          // OS notifications for every critical alert.
          final id = data['id'] as String?;
          if (id != null && id.isNotEmpty) {
            _lanPushReceiver?.recordSeenFrameId(id);
          }
          _notificationService.notifyPush(data);
        },
        onError: (error) {
          // Caught + degraded: stream errors mean we miss push notifications
          // until the backend reconnects. Warn so the gap is visible.
          developer.log(
            'Push notification stream error: $error',
            name: 'MobileSequenceHooks',
            level: 900,
          );
        },
      );
    }
    // rebuild the LAN UDP receiver. Lifecycle follows the same
    // backend-change trigger as the WS listener — disconnect tears it
    // down, a paired NetworkBackend starts it. Fire-and-forget because
    // the start() handles its own logging and the rest of the hook
    // wiring should not block on socket bind.
    unawaited(_rebuildLanPushReceiver());
  }

  /// (Re)build the LAN UDP push receiver. Reads the saved server
  /// fingerprint from EnhancedNightshadeDiscovery — that's the same
  /// fingerprint the desktop's broadcaster stamps into every frame and
  /// derives its HMAC key from. Without a fingerprint we can't verify
  /// anything, so we skip the start entirely instead of running a
  /// receiver that would reject every frame.
  Future<void> _rebuildLanPushReceiver() async {
    await _lanPushSubscription?.cancel();
    _lanPushSubscription = null;
    final existing = _lanPushReceiver;
    _lanPushReceiver = null;
    if (existing != null) {
      await existing.dispose();
    }

    final backend = _ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      // Local backend (FfiBackend) or DisconnectedBackend — no remote
      // server to listen to. Receiver stays null until the user pairs.
      return;
    }

    final saved = await EnhancedNightshadeDiscovery.loadLastServer();
    final fingerprint = saved?.fingerprint;
    if (fingerprint == null || fingerprint.isEmpty) {
      developer.log(
        '[LanPushReceiver] No saved-server fingerprint; LAN UDP push '
        'will not start. Re-pair to capture the fingerprint or fetch it '
        'via /api/info on the next connect.',
        name: 'MobileSequenceHooks',
        level: 900,
      );
      return;
    }

    final receiver = LanPushNotificationReceiver(
      serverFingerprint: fingerprint,
    );
    _lanPushSubscription = receiver.incoming.listen(
      (frame) {
        developer.log(
          '[LanPushReceiver] Frame ${frame.id} (${frame.severity}) — '
          '${frame.title}',
          name: 'MobileSequenceHooks',
          level: 800,
        );
        // Build the legacy data shape that notifyPush expects.
        final eventType = frame.data['eventType'] as String?;
        final category = frame.data['category'] as String?;
        // Carried through because the UDP copy and the WebSocket copy of one
        // push must open the same screen: the dedup below suppresses whichever
        // arrives second, so a deep link dropped here would be lost outright
        // whenever the LAN frame wins the race.
        final deepLink = frame.data['deepLink'] as String?;
        final priority = switch (frame.severity) {
          'critical' => 'critical',
          'warning' => 'high',
          _ => 'normal',
        };
        // Suppress the mobile-direct notifier's own fire for this event
        // type — the OS notification we're about to surface IS the user
        // signal.
        if (eventType != null) {
          _eventNotifier?.recordPushReceived(eventType);
        }
        _notificationService.notifyPush(<String, dynamic>{
          'title': frame.title,
          'body': frame.body,
          'priority': priority,
          if (eventType != null) 'eventType': eventType,
          if (category != null) 'category': category,
          if (deepLink != null) 'deepLink': deepLink,
          'timestamp': frame.timestamp.millisecondsSinceEpoch,
          'id': frame.id,
          'source': 'lan_udp',
        });
      },
      onError: (Object e, StackTrace st) {
        developer.log(
          '[LanPushReceiver] frame stream error: $e',
          name: 'MobileSequenceHooks',
          level: 1000,
          error: e,
          stackTrace: st,
        );
      },
    );
    _lanPushReceiver = receiver;
    await receiver.start();
  }

  void _handleExecutionStateChange(
    SequenceExecutionState? previous,
    SequenceExecutionState next,
  ) async {
    final progress = _ref.read(sequenceProgressProvider);
    final sequence = _ref.read(currentSequenceProvider);

    switch (next) {
      case SequenceExecutionState.idle:
        // Sequence stopped or not started. Any active imaging state —
        // running, paused, recovering, or stopping — holds the wake lock
        // and Android foreground service, so a stop issued from any of
        // them must tear the session down. We skip null/idle (app start)
        // and completed/failed (already stopped) to avoid a double stop.
        if (previous == SequenceExecutionState.running ||
            previous == SequenceExecutionState.paused ||
            previous == SequenceExecutionState.recovering ||
            previous == SequenceExecutionState.stopping ||
            previous == SequenceExecutionState.finalizing ||
            previous == SequenceExecutionState.stopFailed ||
            previous == SequenceExecutionState.cleanupFailed) {
          await _stopImagingSession(
            sequenceCompleted: false,
            errorMessage: 'Sequence stopped',
          );
        }
        _setIosBackgroundBanner(false);
        break;

      case SequenceExecutionState.running:
        if (previous == SequenceExecutionState.idle) {
          // Sequence just started
          await _startImagingSession(sequence);
        } else if (previous == SequenceExecutionState.paused) {
          // Sequence resumed - ensure services are still active
          await _powerService.acquireWakeLock();
        }
        _setIosBackgroundBanner(Platform.isIOS);
        break;

      case SequenceExecutionState.paused:
        // Could optionally release wake lock during pause, but we'll keep it
        // to ensure we can resume quickly
        _setIosBackgroundBanner(Platform.isIOS);
        break;

      case SequenceExecutionState.stopping:
      case SequenceExecutionState.finalizing:
        // Sequence is stopping / finalizing its durable records. Keep services
        // active until it fully settles (transitions to idle/completed/failed).
        _setIosBackgroundBanner(Platform.isIOS);
        break;

      case SequenceExecutionState.completed:
        await _stopImagingSession(
          sequenceCompleted: true,
          completedExposures: progress.completedExposures,
          targetName: progress.currentTarget ?? sequence?.name ?? 'Unknown',
        );
        _setIosBackgroundBanner(false);
        break;

      case SequenceExecutionState.failed:
        await _stopImagingSession(
          sequenceCompleted: false,
          errorMessage: progress.message ?? 'Sequence failed',
          targetName: progress.currentTarget ?? sequence?.name ?? 'Unknown',
        );
        _setIosBackgroundBanner(false);
        break;

      case SequenceExecutionState.recovering:
        // Recovery Mode — recovery is in-flight execution, not
        // session completion. Keep the iOS background banner visible so
        // the user understands the rig is still actively working; the
        // recovery banner on the dashboard surfaces the cause + retry
        // controls. We deliberately do NOT stop the imaging session
        // here — that only happens on `completed` or `failed`.
        _setIosBackgroundBanner(true);
        break;

      case SequenceExecutionState.stopFailed:
      case SequenceExecutionState.cleanupFailed:
        // The stop (or its cleanup) has not finished — the run is not settled,
        // so the wake lock / foreground service must stay held. We keep the
        // banner up and do NOT tear down here; the teardown happens when the
        // run finally settles to idle (handled above) or completes/fails.
        _setIosBackgroundBanner(true);
        break;
    }
  }

  /// Toggle the iOS-only "honest banner" advisory. No-op on Android (where
  /// the foreground service keeps monitoring alive).
  ///
  /// Also refreshes the Critical Alerts authorization state so the banner
  /// can adapt its copy: if Critical Alerts are granted, safety events will
  /// still wake the device even while the app is suspended; if not, the
  /// banner needs to warn the operator that alerts may be silenced by
  /// Focus / DnD / the ringer switch.
  void _setIosBackgroundBanner(bool visible) {
    final desired = Platform.isIOS && visible;
    final notifier = _ref.read(iosBackgroundBannerProvider.notifier);
    if (notifier.state != desired) {
      notifier.state = desired;
    }
    if (Platform.isIOS && desired) {
      // Fire-and-forget: surface the current authorization state into the
      // provider as soon as the platform answers. We don't await because
      // banner visibility shouldn't block on a platform channel call.
      unawaited(_refreshCriticalAlertsAuthorization());
    }
  }

  Future<void> _refreshCriticalAlertsAuthorization() async {
    try {
      final authorized = await _notificationService
          .refreshCriticalAlertsAuthorization();
      final notifier = _ref.read(iosCriticalAlertsAuthorizedProvider.notifier);
      if (notifier.state != authorized) {
        notifier.state = authorized;
      }
    } catch (e, st) {
      // Don't swallow — surface so we know if the platform channel is
      // misbehaving. We still let the banner stay in its default (worst-
      // case "not authorized") state.
      developer.log(
        'Failed to refresh iOS critical-alerts authorization: $e',
        name: 'MobileSequenceHooks',
        level: 1000,
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Re-query the Android POST_NOTIFICATIONS permission and update the
  /// banner-state provider. Call this on app resume so the banner
  /// disappears when the user grants the permission from system settings
  /// and returns to the app. No-op on non-Android.
  Future<void> refreshAndroidNotificationsAuthorization() async {
    if (!Platform.isAndroid) return;
    try {
      final authorized = await _notificationService
          .refreshAndroidNotificationsAuthorization();
      final notifier = _ref.read(
        androidNotificationsAuthorizedProvider.notifier,
      );
      if (notifier.state != authorized) {
        notifier.state = authorized;
      }
    } catch (e, st) {
      developer.log(
        'Failed to refresh Android notifications authorization: $e',
        name: 'MobileSequenceHooks',
        level: 1000,
        error: e,
        stackTrace: st,
      );
    }
  }

  void _handleProgressUpdate(
    SequenceProgress? previous,
    SequenceProgress next,
  ) async {
    // Update foreground service notification with current progress
    if (_foregroundService.isRunning) {
      _foregroundService.updateProgress(
        completedExposures: next.completedExposures,
        totalExposures: next.totalExposures,
        currentFilter: next.currentFilter,
        statusMessage: next.message,
      );
    }

    // Check for meridian flip events
    if (next.message?.toLowerCase().contains('meridian flip') == true) {
      final prefs = await SharedPreferences.getInstance();
      if (!MobilePreferences(prefs).notifyMeridianFlip) return;
      final last = _lastMeridianFlipNotified;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(minutes: 5)) {
        return;
      }
      _lastMeridianFlipNotified = DateTime.now();
      await _notificationService.notifyMeridianFlip(
        next.currentTarget ?? 'Unknown',
        DateTime.now(),
      );
    }
  }

  Future<void> _startImagingSession(Sequence? sequence) async {
    if (sequence == null) return;

    developer.log(
      'Starting imaging session for ${sequence.name}',
      name: 'MobileSequenceHooks',
      level: 800,
    );

    // Start power management (wake lock + battery monitoring)
    await _powerService.startImagingSession();

    // Start foreground service (keeps app alive in background)
    if (Platform.isAndroid) {
      await _foregroundService.startService(
        targetName: sequence.name,
        totalExposures: sequence.totalExposures,
      );
    }
  }

  Future<void> _stopImagingSession({
    required bool sequenceCompleted,
    String? errorMessage,
    String? targetName,
    int? completedExposures,
  }) async {
    developer.log(
      'Stopping imaging session (completed: $sequenceCompleted)',
      name: 'MobileSequenceHooks',
      level: 800,
    );

    // Stop power management
    await _powerService.stopImagingSession();

    // Stop foreground service and show completion notification
    if (Platform.isAndroid) {
      await _foregroundService.stopService(
        sequenceCompleted: sequenceCompleted,
        errorMessage: errorMessage,
      );
    } else {
      // On iOS, manually send notification since we don't have foreground service
      if (sequenceCompleted) {
        await _notificationService.notifySequenceComplete(
          targetName ?? 'Unknown',
          completedExposures ?? 0,
        );
      } else if (errorMessage != null) {
        await _notificationService.notifySequenceFailed(
          targetName ?? 'Unknown',
          errorMessage,
        );
      }
    }
  }

  /// The critical-battery callback, for tests.
  @visibleForTesting
  Future<void> handleCriticalBatteryForTesting() => _handleCriticalBattery();

  /// The phone's battery reached critical. That says nothing about the rig,
  /// so nothing is paused or stopped (owner decision 2026-10-06: only a risk
  /// to the hardware pauses a run by itself). It used to pause the run, a
  /// desktop host's run watched over the network included. PowerService has
  /// already shown the low-battery notification.
  Future<void> _handleCriticalBattery() async {
    developer.log(
      'Critical phone battery; the run is left running',
      name: 'MobileSequenceHooks',
      level: 900,
    );
  }

  void _handleBatteryWarning(BatteryWarningLevel level) {
    // Warnings are already sent by PowerService via MobileNotificationService
    // This callback is for any additional handling
    developer.log(
      'Battery warning: $level',
      name: 'MobileSequenceHooks',
      level: 900,
    );
  }

  Future<void> dispose() async {
    await _pushNotificationSubscription?.cancel();
    _pushNotificationSubscription = null;
    _backendSubscription?.close();
    _backendSubscription = null;
    await _eventNotifier?.stop();
    _eventNotifier = null;
    // tear down the LAN UDP receiver. dispose() closes the
    // controller so any caller still listening on `incoming` gets a
    // done event instead of dangling.
    await _lanPushSubscription?.cancel();
    _lanPushSubscription = null;
    final lanReceiver = _lanPushReceiver;
    _lanPushReceiver = null;
    if (lanReceiver != null) {
      await lanReceiver.dispose();
    }
    await _powerService.dispose();
  }
}

/// `initialize()` is fire-and-forget here, so its failures are routed
/// explicitly to [LoggingService.error] and `developer.log` — a bare
/// `hooks.initialize()` would let the foreground service, notifications and
/// power management fail with no signal at all. Consumers see the failure
/// through [MobileSequenceHooks.waitUntilInitialized]'s timeout.
final mobileSequenceHooksProvider = Provider<MobileSequenceHooks>((ref) {
  final hooks = MobileSequenceHooks(ref);

  // Initialise on creation. Errors are observed: we forward them to the
  // shared LoggingService and `developer.log`, then propagate via the
  // completer so anyone awaiting [waitUntilInitialized] sees them too.
  unawaited(
    hooks.initialize().then(
      (_) {
        developer.log(
          'MobileSequenceHooks initialised',
          name: 'MobileSequenceHooks',
          level: 700,
        );
      },
      onError: (error, stackTrace) {
        developer.log(
          'MobileSequenceHooks initialise failed: $error',
          name: 'MobileSequenceHooks',
          level: 1000,
          error: error,
          stackTrace: stackTrace is StackTrace ? stackTrace : null,
        );
        try {
          ref
              .read(loggingServiceProvider)
              .error(
                'MobileSequenceHooks initialise failed: $error',
                source: 'MobileSequenceHooks',
                fields: <String, Object?>{'error': error.toString()},
              );
        } catch (loggingError) {
          // If even the LoggingService failed (e.g. the provider container
          // was torn down between schedule and invocation), the developer.log
          // call above is already the audit trail. Avoid an infinite loop.
          developer.log(
            'LoggingService unavailable while reporting init failure: $loggingError',
            name: 'MobileSequenceHooks',
            level: 1000,
          );
        }
        // Propagate to anyone awaiting the completer so they don't hang.
        if (!hooks._initializedCompleter.isCompleted) {
          hooks._initializedCompleter.completeError(
            error,
            stackTrace is StackTrace ? stackTrace : StackTrace.current,
          );
        }
      },
    ),
  );

  // Clean up on disposal
  ref.onDispose(() {
    hooks.dispose();
  });

  return hooks;
});
