import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show apiEventStream, SkotiqEvent, EventCategory, EventSeverity;
import '../backend/bridge_event_mapper.dart';
import '../backend/ffi_backend.dart';
import '../backend/network_backend.dart';
import '../models/backend/event_types.dart' as core;
import '../models/backend/host_runtime_update.dart' show isHostSyncEnvelope;
import '../services/device_service_lifecycle.dart';
import 'backend_provider.dart';
import 'host_mutation_event_provider.dart';
import 'sequence/run_stop_classification.dart';
import 'ui_notification_provider.dart';

/// Provider for the global event stream from the Rust native layer
///
/// Every sequencer, device, imaging, guiding and safety event arrives here.
/// UI components subscribe to this stream to react to backend state changes.
final skotiqEventsProvider = StreamProvider<SkotiqEvent>((ref) {
  final backend = ref.watch(backendProvider);

  // Remote clients receive the same typed bridge events as local FFI
  // backends by reconstructing `EventPayload_*` variants from the
  // collapsed envelope on `NetworkBackend.eventStream` (WebSocket).
  if (backend is NetworkBackend) {
    // `HostStateChanged` is a host-mutation SYNC envelope (applied separately
    // by applyRemoteSyncEvent), NOT a Rust telemetry event. The typed bridge
    // mapper has no case for it, so its `default` arm turns every one into a
    // `SystemEvent.error` — which the dashboard flags critical and shows as a
    // "Critical · System" toast. Since the master emits HostStateChanged
    // constantly (the mirror mechanism), that produced a flood of bogus
    // critical errors on the slave. Drop it from the typed/telemetry stream.
    return backend.eventStream
        .where((event) => !isHostSyncEnvelope(event))
        .map(tryBridgeEventFromCoreEvent)
        .where((event) => event != null)
        .cast<SkotiqEvent>();
  }

  // Local desktop/headless: FRB stream plus host REST mutation events so the
  // GUI EventBus sees remote companion writes while the embedded API server
  // is enabled.
  final nativeStream = apiEventStream();
  if (backend is! FfiBackend) {
    return nativeStream;
  }

  // Same guard as the NetworkBackend branch above: `HostStateChanged` is a
  // host-mutation SYNC envelope (applied by host_local_sync_provider), NOT a
  // telemetry event. Every event on the mutation hub is a HostStateChanged, so
  // without this filter bridgeEventFromCoreEvent's default arm turned each one
  // into a `SystemEvent.error` — meaning any local settings write or companion
  // client mutation flashed a red "System error: HostStateChanged" banner on
  // the desktop (the embedded server's whole purpose is companion writes, so
  // this fired constantly).
  final mutationStream = ref
      .watch(hostMutationEventStreamProvider)
      .where((event) => !isHostSyncEnvelope(event))
      .map(bridgeEventFromCoreEvent);
  return _mergeEventStreams(nativeStream, mutationStream);
});

Stream<SkotiqEvent> _mergeEventStreams(
  Stream<SkotiqEvent> primary,
  Stream<SkotiqEvent> secondary,
) {
  late final StreamController<SkotiqEvent> controller;
  StreamSubscription<SkotiqEvent>? primarySub;
  StreamSubscription<SkotiqEvent>? secondarySub;

  controller = StreamController<SkotiqEvent>.broadcast(
    onListen: () {
      primarySub = primary.listen(controller.add, onError: controller.addError);
      secondarySub = secondary.listen(
        controller.add,
        onError: controller.addError,
      );
    },
    onCancel: () async {
      await primarySub?.cancel();
      await secondarySub?.cancel();
      primarySub = null;
      secondarySub = null;
    },
  );

  return controller.stream;
}

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

class LastEventNotifier extends StateNotifier<SkotiqEvent?> {
  LastEventNotifier() : super(null);

  void updateEvent(SkotiqEvent event) {
    if (!mounted) return;
    state = event;
  }
}

/// Provider to track event history (last N events)
///
/// Keeps a rolling buffer of the most recent events for
/// displaying in an event log or notification center.
final eventHistoryProvider =
    StateNotifierProvider<EventHistoryNotifier, List<SkotiqEvent>>((ref) {
      final notifier = EventHistoryNotifier();

      ref.listen(skotiqEventsProvider, (previous, next) {
        next.whenData((event) {
          notifier.addEvent(event);
        });
      });

      return notifier;
    });

/// Notifier that maintains a history of events
class EventHistoryNotifier extends StateNotifier<List<SkotiqEvent>> {
  /// Maximum number of events to keep in history
  static const int maxHistorySize = 100;

  EventHistoryNotifier() : super([]);

  /// Add a new event to the history
  void addEvent(SkotiqEvent event) {
    if (!mounted) return;
    state = [event, ...state].take(maxHistorySize).toList();
  }

  /// Fill an empty history with events that happened before this window was
  /// listening (a linked client's first connect), newest first.
  void seedEarlier(List<SkotiqEvent> newestFirst) {
    if (!mounted || state.isNotEmpty) return;
    state = newestFirst.take(maxHistorySize).toList();
  }

  /// Clear the event history
  void clear() {
    state = [];
  }

  /// Get events filtered by category
  List<SkotiqEvent> getByCategory(EventCategory category) {
    return state.where((e) => e.category == category).toList();
  }

  /// Get events filtered by severity
  List<SkotiqEvent> getBySeverity(EventSeverity severity) {
    return state.where((e) => e.severity == severity).toList();
  }
}

/// Bridges backend events with error/warning/critical severity to UI toast notifications.
///
/// This provider must be watched by the AppShell to stay active.
/// It subscribes to [backend.eventStream] and forwards error-severity
/// events to [uiNotificationProvider] for display as toast notifications.
final errorNotificationBridgeProvider = Provider<void>((ref) {
  final backend = ref.watch(backendProvider);
  final notifier = ref.read(uiNotificationProvider.notifier);

  StreamSubscription<core.SkotiqEvent>? subscription;

  // Coalesce identical toasts that arrive in a wide window. A mass event such
  // as "Disconnect All" makes every device emit a Disconnected/Error event,
  // often repeated as each driver tears down, and every one of those would
  // raise its own toast — hundreds-to-thousands in a single event-loop turn
  // flood the notification overlay and the Windows platform task runner
  // ("Failed to post message to main thread"). A flapping mount heartbeat can
  // also re-raise the same disconnect error every ~30 s poll cycle, so the
  // window is wide enough to collapse a reconnect loop, not just a single
  // teardown burst; the first occurrence of every distinct error still shows.
  const dedupeWindow = Duration(seconds: 30);
  final lastShownAt = <String, DateTime>{};

  // PHD2 emits a StarLost event per lost frame, so one cloudy episode is a
  // toast-per-second flood. Latch the first one per episode. The latch only
  // re-arms on an event that means guiding genuinely recovered or ended:
  // while PHD2 hunts for the star it keeps emitting StarSelected, GuideStep,
  // GuideStats and LoopingExposures per frame — the desktop log shows
  // StarSelected ↔ StarLost alternating every ~10 s for an entire episode —
  // so resetting on "any other guiding event" would make the latch a no-op.
  var starLostToasted = false;
  const starLostEpisodeEnders = {
    'GuidingStarted', // app-state back to Guiding — lock recovered
    'Resumed',
    'SettleDone', // successful settle; a failed one maps to StarLost upstream
    'GuidingStopped',
    'Disconnected',
    'Connected',
    'Paused',
    'Calibrating',
    'CalibrationComplete',
  };

  bool shouldSuppress(String dedupeKey, DateTime now) {
    // Opportunistically prune stale keys so the map can't grow without bound
    // across a long-running session of distinct errors.
    lastShownAt.removeWhere((_, when) => now.difference(when) > dedupeWindow);
    final previous = lastShownAt[dedupeKey];
    if (previous != null && now.difference(previous) < dedupeWindow) {
      return true;
    }
    lastShownAt[dedupeKey] = now;
    return false;
  }

  subscription = backend.eventStream.listen(
    (event) {
      // Star-lost episode handling runs before the info early-return so an
      // info-severity recovery event still re-arms the latch.
      if (event.category == core.EventCategory.guiding) {
        if (event.eventType == 'StarLost' || event.eventType == 'LostStar') {
          if (starLostToasted) return;
          if (event.severity != core.EventSeverity.info) {
            starLostToasted = true;
          }
        } else if (starLostEpisodeEnders.contains(event.eventType)) {
          starLostToasted = false;
        }
        // Anything else — StarSelected, GuideStep, GuideStats,
        // LoopingExposures, Settling, dither traffic, AppState — is
        // per-frame hunt noise and leaves the latch alone.
      }

      if (event.severity == core.EventSeverity.info) return;

      // Heartbeat status changes carry no human message — the toast would
      // literally read "HeartbeatStatusChanged". The Rust heartbeat emits a
      // companion equipment Error event (with the real message) on the same
      // poll, so nothing is lost by dropping these.
      if (event.category == core.EventCategory.equipment &&
          event.eventType == 'HeartbeatStatusChanged') {
        return;
      }

      // Error/critical equipment Error events are already surfaced by
      // DeviceService._handleDeviceError via errorService (60 s per-message
      // dedupe + a device-aware title) whenever a DeviceService is listening
      // to this backend. One is not guaranteed: it is created by the first
      // thing that reads it, so a client that only watches a remote host may
      // have none, and after a backend swap it can still be listening to the
      // old backend. Then this bridge is the only surface left.
      // Warning-severity ones always go through here.
      if (event.category == core.EventCategory.equipment &&
          event.eventType == 'Error' &&
          (event.severity == core.EventSeverity.error ||
              event.severity == core.EventSeverity.critical) &&
          DeviceServiceLifecycle.surfacesDeviceErrorsFrom(backend)) {
        return;
      }

      // PRODUCER 4 of the stop pipeline, and the one the operator actually
      // reads. Like every other producer it asks `isSequenceCancelledNotice`
      // before calling a deliberate Stop a fault. It takes no part in the
      // NotificationRouter, so neither the router's classification nor its
      // content dedupe can reach it — the check has to live here.
      if (_isOperatorStopNotice(event)) {
        developer.log(
          '[$kStopClassificationLogTag] error_notification_bridge: sequencer '
          'Error carrying the cancellation notice -> no error toast',
          name: 'ErrorNotificationBridge',
        );
        return;
      }

      final message = _extractEventMessage(event);
      final title = _eventTitle(event);

      final now = DateTime.now();
      final dedupeKey = '${event.severity.name}|$title|$message';
      if (shouldSuppress(dedupeKey, now)) return;

      switch (event.severity) {
        case core.EventSeverity.critical:
          notifier.showError(
            message,
            title: 'Critical: $title',
            duration: const Duration(seconds: 15),
          );
          break;
        case core.EventSeverity.error:
          notifier.showError(message, title: title);
          break;
        case core.EventSeverity.warning:
          notifier.showWarning(message, title: title);
          break;
        case core.EventSeverity.info:
          break;
      }
    },
    onError: (error) {
      developer.log(
        '[ErrorNotificationBridge] Event stream error: $error',
        name: 'ErrorNotificationBridge',
        level: 1000,
        error: error,
      );
    },
  );

  ref.onDispose(() {
    subscription?.cancel();
  });
});

/// True when this backend event is the operator's Stop wearing an error's
/// clothes.
///
/// The wire shape is fixed: the native executor's `NodeStatus::Cancelled` arm
/// sends `ExecutorEvent::Error { message: "Sequence cancelled" }`
/// (`sequencer/src/executor/start.rs`), the bridge stamps it
/// `EventSeverity::Error` / `EventCategory::Sequencer`
/// (`bridge/src/api/sequencer/event_bridge.rs`), and the FFI mapper delivers it
/// as eventType `'Error'` with the notice under `message`
/// (`backend/ffi_backend/event_mapping.dart`). The remote/WebSocket envelope has
/// been seen using `error` for the same field, so both are read — the same pair
/// `NotificationEventClassifier._sequencerErrorMessage` reads.
///
/// Only the exact notice is reclassified; a real fault whose text merely
/// contains "cancelled" ("Temperature compensation cancelled") is still an
/// error and still reaches the operator. See [isSequenceCancelledNotice].
bool _isOperatorStopNotice(core.SkotiqEvent event) {
  if (event.category != core.EventCategory.sequencer) return false;
  if (event.eventType != 'Error') return false;
  final message =
      (event.data['message'] as String?) ??
      (event.data['error'] as String?) ??
      '';
  return isSequenceCancelledNotice(message);
}

/// Extract a human-readable message from a SkotiqEvent's data map.
String _extractEventMessage(core.SkotiqEvent event) {
  final data = event.data;

  // Try common message keys in order of specificity
  if (data.containsKey('message') &&
      data['message'] is String &&
      (data['message'] as String).isNotEmpty) {
    return data['message'] as String;
  }
  if (data.containsKey('error') &&
      data['error'] is String &&
      (data['error'] as String).isNotEmpty) {
    return data['error'] as String;
  }
  if (data.containsKey('reason') &&
      data['reason'] is String &&
      (data['reason'] as String).isNotEmpty) {
    return data['reason'] as String;
  }

  // Fall back to event type
  return event.eventType;
}

/// Build a title string from the event's category and device type.
String _eventTitle(core.SkotiqEvent event) {
  final deviceType = event.data['device_type'] as String?;
  final categoryLabel = switch (event.category) {
    core.EventCategory.equipment => 'Device',
    core.EventCategory.imaging => 'Imaging',
    core.EventCategory.guiding => 'Guiding',
    core.EventCategory.sequencer => 'Sequence',
    core.EventCategory.safety => 'Safety',
    core.EventCategory.system => 'System',
    core.EventCategory.polarAlignment => 'Polar Alignment',
    core.EventCategory.job => 'Job',
    core.EventCategory.session => 'Session',
    core.EventCategory.catalog => 'Catalog',
  };

  if (deviceType != null && deviceType.isNotEmpty) {
    return '$deviceType Error';
  }
  return '$categoryLabel ${event.severity == core.EventSeverity.warning ? "Warning" : "Error"}';
}
