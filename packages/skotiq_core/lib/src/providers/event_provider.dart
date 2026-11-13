import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        SkotiqEvent,
        EventCategory,
        EventSeverity,
        EventPayload_Guiding,
        GuidingEvent,
        GuidingEvent_Calibrating,
        GuidingEvent_CalibrationComplete,
        GuidingEvent_Connected,
        GuidingEvent_Disconnected,
        GuidingEvent_GuidingStarted,
        GuidingEvent_GuidingStopped,
        GuidingEvent_LostStar,
        GuidingEvent_Paused,
        GuidingEvent_Resumed,
        GuidingEvent_Settled,
        SequencerErrorKind;
import '../backend/bridge_event_codec.dart';
import '../backend/sequencer_error_kind.dart';
import '../models/backend/event_types.dart' as core;
import '../models/backend/host_runtime_update.dart' show isHostSyncEnvelope;
import '../services/device_service_lifecycle.dart';
import '../services/notification/event_classifier.dart';
import '../backend/remote_host.dart';
import 'backend_provider.dart';
import 'host_mutation_event_provider.dart';
import 'ui_notification_provider.dart';

/// The typed event stream: every sequencer, device, imaging, guiding and
/// safety event the rig's host reports, on the host itself and on a linked
/// client alike. A host also sees the notices it raises in Dart.
///
/// Sync envelopes (`HostStateChanged`, the runtime mirror) are applied by
/// their own providers and are not events of the night.
final skotiqEventsProvider = StreamProvider<SkotiqEvent>((ref) {
  final backend = ref.watch(backendProvider);
  final events = backend.ownsDeviceBridge
      ? _mergeEventStreams(
          backend.eventStream,
          ref.watch(hostMutationEventStreamProvider),
        )
      : backend.eventStream;
  return events
      .where((event) => !isHostSyncEnvelope(event))
      .map(typedEventFromWire)
      .where((event) => event != null)
      .cast<SkotiqEvent>();
});

Stream<core.SkotiqEvent> _mergeEventStreams(
  Stream<core.SkotiqEvent> primary,
  Stream<core.SkotiqEvent> secondary,
) {
  late final StreamController<core.SkotiqEvent> controller;
  StreamSubscription<core.SkotiqEvent>? primarySub;
  StreamSubscription<core.SkotiqEvent>? secondarySub;

  controller = StreamController<core.SkotiqEvent>.broadcast(
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

class EventHistoryNotifier extends StateNotifier<List<SkotiqEvent>> {
  static const int maxHistorySize = 100;

  EventHistoryNotifier() : super([]);

  void addEvent(SkotiqEvent event) {
    if (!mounted) return;
    state = [event, ...state].take(maxHistorySize).toList();
  }

  final Set<SkotiqEvent> _earlier = Set.identity();

  /// Fill an empty history with events that happened before this window was
  /// listening (a linked client's first connect), newest first.
  void seedEarlier(List<SkotiqEvent> newestFirst) {
    if (!mounted || state.isNotEmpty) return;
    final earlier = newestFirst.take(maxHistorySize).toList();
    _earlier.addAll(earlier);
    state = earlier;
  }

  /// Whether [event] came with [seedEarlier]: it is part of the night so
  /// far, not something that just happened.
  bool happenedEarlier(SkotiqEvent event) => _earlier.contains(event);

  void clear() {
    _earlier.clear();
    state = [];
  }

  List<SkotiqEvent> getByCategory(EventCategory category) {
    return state.where((e) => e.category == category).toList();
  }

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
  bool endsStarLostEpisode(GuidingEvent event) => switch (event) {
    GuidingEvent_GuidingStarted() || // back to guiding: the lock recovered
    GuidingEvent_Resumed() ||
    GuidingEvent_Settled() || // a failed settle arrives as a lost star
    GuidingEvent_GuidingStopped() ||
    GuidingEvent_Disconnected() ||
    GuidingEvent_Connected() ||
    GuidingEvent_Paused() ||
    GuidingEvent_Calibrating() ||
    GuidingEvent_CalibrationComplete() => true,
    _ => false,
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
      final payload = typedEventFromWire(event)?.payload;
      if (payload is EventPayload_Guiding) {
        if (payload.field0 is GuidingEvent_LostStar) {
          if (starLostToasted) return;
          if (event.severity != core.EventSeverity.info) {
            starLostToasted = true;
          }
        } else if (endsStarLostEpisode(payload.field0)) {
          starLostToasted = false;
        }
        // Anything else — StarSelected, GuideStep, GuideStats,
        // LoopingExposures, Settling, dither traffic, AppState — is
        // per-frame hunt noise and leaves the latch alone.
      }

      if (event.severity == core.EventSeverity.info) return;

      // An event that carries no sentence is not a notice: its toast would
      // read the event's type name ("NodeCompleted" for a failed step,
      // "HeartbeatStatusChanged"). Those events have a companion that says
      // what happened (the step's error, the heartbeat's equipment Error).
      final message = _eventMessage(event);
      if (message == null) return;
      if (_isAnnouncedRunWarning(event)) return;

      // A sequencer event the notification router classifies is the router's
      // to tell: a failed run (once per run, with its reason) and an
      // operator's Stop arriving as the cancellation notice. A second toast
      // here for the same happening is how one failed run raised three
      // notices.
      if (event.category == core.EventCategory.sequencer &&
          NotificationEventClassifier.classify(event) != null) {
        return;
      }

      // A failed step is told by the run's end, whose notice carries this
      // reason, or by recovery's own notices when recovery saves the run.
      if (sequencerErrorOf(event)?.kind == SequencerErrorKind.stepFailed) {
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

/// True for the run's Warning about a happening it carried on through. The
/// notification router announces it from the decision row with the same
/// notice, and Tonight lists the Warning with the run's warnings, so a toast
/// would tell the same happening twice.
bool _isAnnouncedRunWarning(core.SkotiqEvent event) =>
    event.severity == core.EventSeverity.warning &&
    sequencerErrorOf(event)?.notice != null;

/// The sentence a backend event carries, or null when it carries none.
String? _eventMessage(core.SkotiqEvent event) {
  for (final key in const ['message', 'error', 'reason']) {
    final value = event.data[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

/// Build a title string from the event's category and device type.
String _eventTitle(core.SkotiqEvent event) {
  // A system notification names itself ("Database needs repair").
  if (event.category == core.EventCategory.system &&
      event.eventType == 'Notification') {
    final title = event.data['title'];
    if (title is String && title.trim().isNotEmpty) return title;
  }
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
  // The sequencer's error payload says what it means for the run.
  final sequencerError = sequencerErrorOf(event);
  if (sequencerError != null) {
    switch (sequencerError.kind) {
      case SequencerErrorKind.runHeld:
        return 'Sequence paused';
      case SequencerErrorKind.standalone:
        return event.severity == core.EventSeverity.warning
            ? 'Warning'
            : 'Operation failed';
      case SequencerErrorKind.advisory:
      case SequencerErrorKind.stepProblem:
      case SequencerErrorKind.stepFailed:
        break;
    }
  }
  return '$categoryLabel ${event.severity == core.EventSeverity.warning ? "Warning" : "Error"}';
}
