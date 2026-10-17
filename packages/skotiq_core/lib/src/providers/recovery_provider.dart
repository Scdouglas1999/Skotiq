/// Recovery Mode — Riverpod providers for the recovery state machine.
///
/// Reads:
///   * the typed bridge event stream — `SequencerEvent_Recovery{Started,
///     Progress,Completed,GaveUp}` carry the full recovery context as flat
///     primitive fields.
///   * `sequenceProgressProvider` — used to derive the `isRecovering`
///     boolean even when the live recovery context hasn't arrived yet.
///
/// Exposes:
///   * `currentRecoveryProvider` — `RecoveryStatus?` for the dashboard
///     banner.
///   * `recoveryHistoryProvider` — list of every completed recovery loop in
///     the current run.
///   * `recoveryControlProvider` — command surface (try-now / abort).
///   * `recoveryAudibleBridgeProvider` — side-effect provider that plays
///     the platform alert sound on every recovery entry (gated by
///     `recoveryAudibleAlertWhenEntered`).
///   * `recoveryPushBridgeProvider` — side-effect provider that enqueues a
///     critical push notification on every recovery entry AND exit
///     (recovered / gave-up), gated by `pushCriticalAlerts`. The exit push
///     carries the "here's what I did" closure so an operator on cellular
///     learns the outcome, not just that something broke.
library;

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_event;

import '../models/backend/event_types.dart' as core_events;
import '../models/sequencer/recovery_status.dart';
import '../models/sequence/sequence_models.dart';
import 'backend_provider.dart';
import 'critical_alert_provider.dart';
import 'event_provider.dart';
import 'push_notification_provider.dart';
import 'sequence_provider.dart';
import 'settings_provider.dart';

/// State of the current in-flight recovery loop. `null` whenever the
/// executor is not in `Recovering`.
class RecoveryNotifier extends StateNotifier<RecoveryStatus?> {
  RecoveryNotifier() : super(null);

  void update(RecoveryStatus? next) {
    if (!mounted) return;
    state = next;
  }

  void clear() {
    if (!mounted) return;
    state = null;
  }
}

final currentRecoveryProvider =
    StateNotifierProvider<RecoveryNotifier, RecoveryStatus?>(
      (ref) => RecoveryNotifier(),
    );

/// List of every completed recovery loop in the current run. The
/// post-session report dialog reads from this notifier.
class RecoveryHistoryNotifier
    extends StateNotifier<List<RecoveryHistoryEntry>> {
  RecoveryHistoryNotifier() : super(const []);

  void append(RecoveryHistoryEntry entry) {
    if (!mounted) return;
    state = [...state, entry];
  }

  void clearForNewRun() {
    if (!mounted) return;
    state = const [];
  }
}

final recoveryHistoryProvider =
    StateNotifierProvider<RecoveryHistoryNotifier, List<RecoveryHistoryEntry>>(
      (ref) => RecoveryHistoryNotifier(),
    );

/// Operator command surface for the recovery banner. Delegates to the
/// backend so both FFI and network backends honour the same control path.
class RecoveryControl {
  final Ref _ref;
  RecoveryControl(this._ref);

  /// Request an immediate retry (skips the wait timer).
  Future<void> tryNow() async {
    final backend = _ref.read(sequencerBackendProvider);
    try {
      await backend.recoveryTryNow();
    } catch (e, st) {
      developer.log(
        'RecoveryControl.tryNow failed: $e',
        name: 'recovery_provider',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// Exit the recovery loop and transition the executor to `Failed`.
  Future<void> abort() async {
    final backend = _ref.read(sequencerBackendProvider);
    try {
      await backend.recoveryAbort();
    } catch (e, st) {
      developer.log(
        'RecoveryControl.abort failed: $e',
        name: 'recovery_provider',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// Skip the currently-failing node and resume the sequence past it.
  ///
  /// Implemented on top of the existing `sequencerSkip()` surface
  /// (`POST /api/sequencer/skip`); the executor's skip handler is
  /// recovery-aware — it clears the recovery loop and continues with the
  /// next sibling. Audit — companion phones need a third option
  /// beyond Try Now / Abort: "the camera is wedged, but I want the rest
  /// of the run to keep going".
  Future<void> skipNode() async {
    final backend = _ref.read(sequencerBackendProvider);
    try {
      await backend.sequencerSkip();
    } catch (e, st) {
      developer.log(
        'RecoveryControl.skipNode failed: $e',
        name: 'recovery_provider',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }
}

final recoveryControlProvider = Provider<RecoveryControl>(
  (ref) => RecoveryControl(ref),
);

/// Bridge-event envelope built from a typed `SequencerEvent_Recovery*`
/// variant. Carries the rebuilt [RecoveryStatus] plus the discriminating
/// kind + abort flag. The JSON-through-detail string parser is
/// gone; this comes straight from the FRB-typed payload.
enum RecoveryEventKind { started, progress, completed, gaveUp }

class RecoveryEventEnvelope {
  final RecoveryEventKind kind;
  final RecoveryStatus context;
  final bool? abortedByUser;

  const RecoveryEventEnvelope({
    required this.kind,
    required this.context,
    required this.abortedByUser,
  });
}

/// Side-effect provider: subscribes to [skotiqEventsProvider] (typed
/// bridge events from local FRB or reconstructed from
/// [NetworkBackend.eventStream]) and forwards Recovery* events to
/// [currentRecoveryProvider] and [recoveryHistoryProvider]. Must be
/// `ref.watch`-ed somewhere in the widget tree (the Run Dashboard
/// scaffolding watches it).
final recoveryEventBridgeProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<bridge_event.SkotiqEvent>>(
    skotiqEventsProvider,
    (previous, next) {
      next.when(
        data: (event) {
          final envelope = _recoveryEnvelopeFromBridge(event);
          if (envelope == null) return;
          _applyRecoveryEvent(ref, envelope);
        },
        loading: () {},
        error: (error, _) {
          developer.log(
            '[recoveryEventBridge] Event stream error: $error',
            name: 'recovery_provider',
            level: 1000,
          );
        },
      );
    },
    fireImmediately: true,
  );
});

/// Parses a [bridge_event.SkotiqEvent] into a typed
/// [RecoveryEventEnvelope] when the payload is one of the four
/// `SequencerEvent_Recovery*` variants. Returns `null` for anything else
/// so the caller can short-circuit.
RecoveryEventEnvelope? _recoveryEnvelopeFromBridge(
  bridge_event.SkotiqEvent event,
) {
  final payload = event.payload;
  if (payload is! bridge_event.EventPayload_Sequencer) return null;
  final inner = payload.field0;

  if (inner is bridge_event.SequencerEvent_RecoveryStarted) {
    return RecoveryEventEnvelope(
      kind: RecoveryEventKind.started,
      context: _recoveryStatusFromTypedStarted(inner),
      abortedByUser: null,
    );
  }
  if (inner is bridge_event.SequencerEvent_RecoveryProgress) {
    return RecoveryEventEnvelope(
      kind: RecoveryEventKind.progress,
      context: _recoveryStatusFromTypedProgress(inner),
      abortedByUser: null,
    );
  }
  if (inner is bridge_event.SequencerEvent_RecoveryCompleted) {
    return RecoveryEventEnvelope(
      kind: RecoveryEventKind.completed,
      context: _recoveryStatusFromTypedCompleted(inner),
      abortedByUser: null,
    );
  }
  if (inner is bridge_event.SequencerEvent_RecoveryGaveUp) {
    return RecoveryEventEnvelope(
      kind: RecoveryEventKind.gaveUp,
      context: _recoveryStatusFromTypedGaveUp(inner),
      abortedByUser: inner.abortedByUser,
    );
  }
  return null;
}

// Typed → RecoveryStatus reconstruction helpers
//
// The four FRB variants carry identical-shaped payloads (flat primitives
// only — see `bridge/src/event.rs > SequencerEvent::Recovery*`). The Rust
// side denormalised the chrono-bearing `RecoveryContext` into ISO-8601
// strings + flat integers so we can rebuild a `RecoveryStatus` on the
// Dart side without bridging the Rust struct.

RecoveryStatus _recoveryStatusFromTypedStarted(
  bridge_event.SequencerEvent_RecoveryStarted ev,
) {
  return _rebuildRecoveryStatus(
    startedAtIso: ev.startedAtIso,
    causeKind: ev.causeKind,
    causeCustomLabel: ev.causeCustomLabel,
    lastAttemptAtIso: ev.lastAttemptAtIso,
    attemptCount: ev.attemptCount,
    maxAttempts: ev.maxAttempts,
    retryIntervalSecs: ev.retryIntervalSecs,
    maxDurationSecs: ev.maxDurationSecs,
    phase: ev.phase,
    lastError: ev.lastError,
  );
}

RecoveryStatus _recoveryStatusFromTypedProgress(
  bridge_event.SequencerEvent_RecoveryProgress ev,
) {
  return _rebuildRecoveryStatus(
    startedAtIso: ev.startedAtIso,
    causeKind: ev.causeKind,
    causeCustomLabel: ev.causeCustomLabel,
    lastAttemptAtIso: ev.lastAttemptAtIso,
    attemptCount: ev.attemptCount,
    maxAttempts: ev.maxAttempts,
    retryIntervalSecs: ev.retryIntervalSecs,
    maxDurationSecs: ev.maxDurationSecs,
    phase: ev.phase,
    lastError: ev.lastError,
  );
}

RecoveryStatus _recoveryStatusFromTypedCompleted(
  bridge_event.SequencerEvent_RecoveryCompleted ev,
) {
  return _rebuildRecoveryStatus(
    startedAtIso: ev.startedAtIso,
    causeKind: ev.causeKind,
    causeCustomLabel: ev.causeCustomLabel,
    lastAttemptAtIso: ev.lastAttemptAtIso,
    attemptCount: ev.attemptCount,
    maxAttempts: ev.maxAttempts,
    retryIntervalSecs: ev.retryIntervalSecs,
    maxDurationSecs: ev.maxDurationSecs,
    phase: ev.phase,
    lastError: ev.lastError,
  );
}

RecoveryStatus _recoveryStatusFromTypedGaveUp(
  bridge_event.SequencerEvent_RecoveryGaveUp ev,
) {
  return _rebuildRecoveryStatus(
    startedAtIso: ev.startedAtIso,
    causeKind: ev.causeKind,
    causeCustomLabel: ev.causeCustomLabel,
    lastAttemptAtIso: ev.lastAttemptAtIso,
    attemptCount: ev.attemptCount,
    maxAttempts: ev.maxAttempts,
    retryIntervalSecs: ev.retryIntervalSecs,
    maxDurationSecs: ev.maxDurationSecs,
    phase: ev.phase,
    lastError: ev.lastError,
  );
}

/// Shared rebuilder — keeps the typed → status mapping in one place so a
/// schema bump touches a single function.
RecoveryStatus _rebuildRecoveryStatus({
  required String startedAtIso,
  required String causeKind,
  required String? causeCustomLabel,
  required String? lastAttemptAtIso,
  required int attemptCount,
  required int maxAttempts,
  required double retryIntervalSecs,
  required double maxDurationSecs,
  required String phase,
  required String? lastError,
}) {
  return RecoveryStatus(
    startedAt: DateTime.parse(startedAtIso),
    cause: _causeFromTyped(causeKind, causeCustomLabel),
    lastAttemptAt: lastAttemptAtIso == null
        ? null
        : DateTime.parse(lastAttemptAtIso),
    attemptCount: attemptCount,
    maxAttempts: maxAttempts,
    retryIntervalSecs: retryIntervalSecs,
    maxDurationSecs: maxDurationSecs,
    phase: _phaseFromTyped(phase),
    lastError: lastError,
  );
}

RecoveryCause _causeFromTyped(String kind, String? customLabel) {
  switch (kind) {
    case 'GuideStarLost':
      return RecoveryCause.guideStarLost();
    case 'SlewFailed':
      return RecoveryCause.slewFailed();
    case 'PlateSolveFailed':
      return RecoveryCause.plateSolveFailed();
    case 'WeatherUnsafe':
      return RecoveryCause.weatherUnsafe();
    case 'MountTrackingLost':
      return RecoveryCause.mountTrackingLost();
    case 'FocusDriftCritical':
      return RecoveryCause.focusDriftCritical();
    case 'ConsecutiveRejectsExceeded':
      return RecoveryCause.consecutiveRejectsExceeded();
    case 'DeviceDisconnected':
      return RecoveryCause.deviceDisconnected();
    case 'Custom':
      return RecoveryCause.custom(customLabel ?? '');
    default:
      // An unknown discriminant means the Rust enum grew a variant this
      // switch does not cover. Throwing surfaces that; a fallback would
      // report a wrong recovery cause as if it were the real one.
      throw FormatException(
        'Unknown RecoveryCause kind from typed bridge event: $kind',
      );
  }
}

RecoveryPhase _phaseFromTyped(String phase) {
  switch (phase) {
    case 'Waiting':
      return RecoveryPhase.waiting;
    case 'Attempting':
      return RecoveryPhase.attempting;
    case 'Recovered':
      return RecoveryPhase.recovered;
    case 'GaveUp':
      return RecoveryPhase.gaveUp;
    default:
      throw FormatException(
        'Unknown RecoveryPhase wire value from typed bridge event: $phase',
      );
  }
}

void _applyRecoveryEvent(Ref ref, RecoveryEventEnvelope envelope) {
  final currentNotifier = ref.read(currentRecoveryProvider.notifier);
  final historyNotifier = ref.read(recoveryHistoryProvider.notifier);
  final progressNotifier = ref.read(sequenceProgressProvider.notifier);

  switch (envelope.kind) {
    case RecoveryEventKind.started:
    case RecoveryEventKind.progress:
      currentNotifier.update(envelope.context);
      // Mirror the Rust ExecutorState transition into the Dart progress
      // notifier so the dashboard's other panels (status bar, mobile
      // playback bar, sequence progress card) react to recovery without
      // having to subscribe to currentRecoveryProvider individually.
      progressNotifier.updateState(SequenceExecutionState.recovering);
      break;
    case RecoveryEventKind.completed:
      currentNotifier.clear();
      historyNotifier.append(
        RecoveryHistoryEntry(
          startedAt: envelope.context.startedAt,
          endedAt: DateTime.now().toUtc(),
          cause: envelope.context.cause,
          attempts: envelope.context.attemptCount,
          recovered: true,
          abortedByUser: false,
          lastError: envelope.context.lastError,
        ),
      );
      // Recovery succeeded — the Rust executor flips back to Running.
      // Mirror that on the Dart side so the LED returns to green.
      progressNotifier.updateState(SequenceExecutionState.running);
      break;
    case RecoveryEventKind.gaveUp:
      currentNotifier.clear();
      historyNotifier.append(
        RecoveryHistoryEntry(
          startedAt: envelope.context.startedAt,
          endedAt: DateTime.now().toUtc(),
          cause: envelope.context.cause,
          attempts: envelope.context.attemptCount,
          recovered: false,
          abortedByUser: envelope.abortedByUser ?? false,
          lastError: envelope.context.lastError,
        ),
      );
      // Recovery exhausted — the Rust executor flips to Failed.
      progressNotifier.updateState(SequenceExecutionState.failed);
      break;
  }
}

/// Side-effect provider: plays the platform alert sound on every fresh
/// recovery entry. Gated by both [recoveryAudibleAlertWhenEntered] and
/// the global [audibleAlertsOnCritical] toggle.
final recoveryAudibleBridgeProvider = Provider<void>((ref) {
  ref.listen<RecoveryStatus?>(currentRecoveryProvider, (previous, next) {
    // Only ring on transition None -> Some (entry into a recovery).
    if (previous != null) return;
    if (next == null) return;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return;
    if (!settings.recoveryAudibleAlertWhenEntered) return;
    if (!settings.audibleAlertsOnCritical) return;
    final player = ref.read(criticalAlertPlayerProvider);
    // Fire-and-forget; surface platform failures in developer.log.
    // ignore: discarded_futures
    player.play(sound: settings.criticalAlertSound).catchError((Object e) {
      developer.log(
        'Recovery audible alert failed: $e',
        name: 'recovery_provider',
      );
    });
  });
});

/// Side-effect provider: forwards recovery entry **and exit** events to
/// paired mobile clients via the push-notification service. Honours
/// [pushCriticalAlerts].
///
/// Two pushes per recovery loop:
///   * **Entry** ([currentRecoveryProvider] None->Some): the cause label plus
///     the first attempt.
///   * **Exit** (each freshly appended [RecoveryHistoryEntry]): the outcome —
///     re-acquired / parked / gave-up — with the recovery action. Recovery
///     exhaustion (`recovered == false`) means the rig has stopped imaging.
///
/// Fail-soft: any error building or enqueueing a push is logged and swallowed
/// so a notification failure never breaks the run.
final recoveryPushBridgeProvider = Provider<void>((ref) {
  void enqueue({
    required String title,
    required String body,
    required String eventType,
  }) {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return;
    if (!settings.pushCriticalAlerts) return;
    try {
      final pushService = ref.read(pushNotificationServiceProvider);
      pushService.enqueueCriticalNotification(
        title: title,
        body: body,
        eventType: eventType,
        category: core_events.EventCategory.sequencer,
      );
    } catch (e, st) {
      // Fail-soft: a push failure must never break the run.
      developer.log(
        'Recovery push enqueue failed: $e',
        name: 'recovery_provider',
        error: e,
        stackTrace: st,
      );
    }
  }

  // Entry push — fires once on the None -> Some transition.
  ref.listen<RecoveryStatus?>(currentRecoveryProvider, (previous, next) {
    if (previous != null) return; // only on entry
    if (next == null) return;
    enqueue(
      title: 'Recovering — ${next.cause.displayLabel}',
      body: 'Sequence entered recovery mode. Attempt 1 of ${next.maxAttempts}.',
      eventType: 'recovery_started_${next.cause.wireKey}',
    );
  });

  // Exit push — fires once per newly appended history entry. The history
  // notifier appends exactly one entry on every completed/gaveUp transition
  // (see [_applyRecoveryEvent]), and carries the cause + attempt count +
  // recovered/abortedByUser flags needed for the "here's what I did" copy.
  ref.listen<List<RecoveryHistoryEntry>>(recoveryHistoryProvider, (
    previous,
    next,
  ) {
    final prevLen = previous?.length ?? 0;
    if (next.length <= prevLen) return; // only on growth (a new exit)
    for (final entry in next.sublist(prevLen)) {
      enqueue(
        title: _recoveryExitTitle(entry),
        body: _recoveryExitBody(entry),
        eventType:
            'recovery_${entry.recovered ? 'recovered' : 'gave_up'}_${entry.cause.wireKey}',
      );
    }
  });
});

/// Notification primary line for a recovery exit. Leads with the outcome so a
/// glance at the lock screen tells the operator whether the rig is back to
/// imaging or stopped and waiting on them.
String _recoveryExitTitle(RecoveryHistoryEntry entry) {
  if (entry.recovered) {
    return 'Recovered - ${entry.cause.displayLabel}';
  }
  if (entry.abortedByUser) {
    return 'Recovery aborted - ${entry.cause.displayLabel}';
  }
  return 'Recovery failed - ${entry.cause.displayLabel}';
}

/// "Here's what I did" body for a recovery exit — the cause, the action taken,
/// and the attempt count, so the alert closes the loop the entry push opened.
String _recoveryExitBody(RecoveryHistoryEntry entry) {
  final attempts = entry.attempts == 1
      ? '1 attempt'
      : '${entry.attempts} attempts';
  if (entry.recovered) {
    return '${entry.cause.displayLabel} -> re-acquired after $attempts, '
        'imaging resumed.';
  }
  if (entry.abortedByUser) {
    return '${entry.cause.displayLabel} -> recovery aborted by operator after '
        '$attempts.';
  }
  // Exhausted attempts/time budget - the rig has stopped and needs a human.
  return '${entry.cause.displayLabel} -> gave up after $attempts; sequence '
      'stopped, mount safe.';
}

/// Visibility shim so widget tests can drive the bridge from a synthetic
/// event without reaching into the private helper. The shim is the same
/// function the production stream subscription calls — keeping the test
/// path on the production code path means the end-to-end recovery test
/// exercises the actual envelope-building logic.
@visibleForTesting
RecoveryEventEnvelope? recoveryEnvelopeFromBridgeForTest(
  bridge_event.SkotiqEvent event,
) => _recoveryEnvelopeFromBridge(event);

/// Visibility shim: the test rig drives `_applyRecoveryEvent` directly
/// instead of routing through the stream subscription so it can fire a
/// synthetic envelope without depending on the backend mock surfacing it.
@visibleForTesting
void applyRecoveryEventForTest(Ref ref, RecoveryEventEnvelope envelope) =>
    _applyRecoveryEvent(ref, envelope);
