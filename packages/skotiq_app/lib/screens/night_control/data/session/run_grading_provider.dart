// The run grader's verdicts and the sky-brightness exposure decisions, as the
// run reports them.
//
// Both come from the backend's typed sequencer events (`FrameAccepted` /
// `FrameRejected`, `ExposureAdjusted`), which a linked client receives from
// its host as well. A run's `Started` clears them; a change of host clears
// them too, since one host's run says nothing about another's.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

/// State built from the sequencer events of the current run.
abstract class _RunEventNotifier<T> extends StateNotifier<T> {
  _RunEventNotifier(this._ref, this._initial) : super(_initial) {
    _follow(_ref.read(diagnosticsBackendProvider), clear: false);
    _backendSubscription = _ref.listen<DiagnosticsBackend>(
      diagnosticsBackendProvider,
      (previous, next) {
        if (!identical(previous, next)) _follow(next, clear: true);
      },
    );
  }

  final Ref _ref;
  final T _initial;
  StreamSubscription<SkotiqEvent>? _subscription;
  ProviderSubscription<DiagnosticsBackend>? _backendSubscription;
  int _generation = 0;

  void _follow(DiagnosticsBackend backend, {required bool clear}) {
    final generation = ++_generation;
    final previous = _subscription;
    if (clear) state = _initial;
    _subscription = backend.eventStream.listen((event) {
      if (generation != _generation) return;
      final payload = typedEventFromWire(event)?.payload;
      if (payload is! EventPayload_Sequencer) return;
      if (payload.field0 is SequencerEvent_Started) {
        state = _initial;
        return;
      }
      onRunEvent(payload.field0);
    });
    previous?.cancel();
  }

  void onRunEvent(SequencerEvent event);

  @override
  void dispose() {
    _generation++;
    _subscription?.cancel();
    _backendSubscription?.close();
    super.dispose();
  }
}

class _GradingNotifier extends _RunEventNotifier<FrameGradeRunSummary> {
  _GradingNotifier(Ref ref) : super(ref, FrameGradeRunSummary.empty);

  @override
  void onRunEvent(SequencerEvent event) {
    final grade = FrameGradeEvent.fromEvent(event);
    if (grade == null) return;
    // The event carries the run's own running counts.
    state = FrameGradeRunSummary(
      accepted: grade.acceptedTotal,
      rejected: grade.rejectedTotal,
      consecutiveRejects: grade.consecutiveRejects,
      lastReject: grade.isReject ? grade : state.lastReject,
    );
  }
}

/// The run grader's verdicts so far in this run.
final runGradingProvider =
    StateNotifierProvider<_GradingNotifier, FrameGradeRunSummary>(
  _GradingNotifier.new,
);

class _AdaptiveExposureNotifier
    extends _RunEventNotifier<AdaptiveExposureEvent?> {
  _AdaptiveExposureNotifier(Ref ref) : super(ref, null);

  @override
  void onRunEvent(SequencerEvent event) {
    if (event is SequencerEvent_ExposureAdjusted) {
      state = AdaptiveExposureEvent.fromEvent(event);
    }
  }
}

/// The newest sky-brightness exposure decision of this run, or null before
/// the first.
final runAdaptiveExposureProvider =
    StateNotifierProvider<_AdaptiveExposureNotifier, AdaptiveExposureEvent?>(
  _AdaptiveExposureNotifier.new,
);

/// The exposure decision Tonight shows: the newest, while the run adapts its
/// exposures to the sky at all.
final nightAdaptiveExposureProvider = Provider<AdaptiveExposureEvent?>((ref) {
  final decision = ref.watch(runAdaptiveExposureProvider);
  return decision?.reason == AdaptiveExposureReason.disabled ? null : decision;
});
