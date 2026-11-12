// The solves and centerings of this session, newest first, for the Solve
// tab's "Recent solves": the operator's own, and a run's Center steps as the
// run reports them. Kept in memory from the moment Tonight first shows;
// nothing survives an app restart, and the list says "this session" because
// of it. A linked client adds the host's from before it connected.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../data/session/night_history_sync.dart';

enum NightSolveKind { solve, center }

@immutable
class NightSolveRecord {
  const NightSolveRecord({
    required this.at,
    required this.kind,
    required this.success,
    this.raDegrees,
    this.decDegrees,
    this.offsetArcsec,
    this.iterations,
    this.duration,
    this.byRun = false,
  });

  /// When the result arrived, a true instant.
  final DateTime at;
  final NightSolveKind kind;
  final bool success;

  /// The solved position (solves only).
  final double? raDegrees;
  final double? decDegrees;

  /// The distance from the target: a centering's final one, or what a run's
  /// centering solve measured.
  final double? offsetArcsec;

  /// A centering's attempts.
  final int? iterations;

  /// How long the solve took, as the solver reported it.
  final Duration? duration;

  /// A run's Center step made it, rather than the operator.
  final bool byRun;
}

/// At most this many records are kept.
const int kNightRecentSolvesMax = 20;

final nightRecentSolvesProvider =
    StateNotifierProvider<NightRecentSolvesNotifier, List<NightSolveRecord>>(
  NightRecentSolvesNotifier.new,
);

class NightRecentSolvesNotifier extends StateNotifier<List<NightSolveRecord>> {
  NightRecentSolvesNotifier(this._ref) : super(const <NightSolveRecord>[]) {
    _ref.listen<PlateSolveState>(plateSolveStateProvider, (previous, next) {
      final result = next.lastResult;
      if (result == null || identical(result, previous?.lastResult)) return;
      final seconds = result.solveTimeSecs;
      _add(
        NightSolveRecord(
          at: _now(),
          kind: NightSolveKind.solve,
          success: result.success,
          raDegrees: result.success ? result.ra : null,
          decDegrees: result.success ? result.dec : null,
          duration: seconds.isFinite && seconds > 0
              ? Duration(milliseconds: (seconds * 1000).round())
              : null,
        ),
      );
    });
    _ref.listen<CenteringResult?>(lastCenteringResultProvider,
        (previous, next) {
      if (next == null || identical(next, previous)) return;
      _add(
        NightSolveRecord(
          at: _now(),
          kind: NightSolveKind.center,
          success: next.success,
          offsetArcsec: next.finalOffsetArcsec,
          iterations: next.iterations > 0 ? next.iterations : null,
        ),
      );
    });
    _followRun(_ref.read(diagnosticsBackendProvider));
    _ref.listen<DiagnosticsBackend>(diagnosticsBackendProvider,
        (previous, next) {
      if (!identical(previous, next)) _followRun(next);
    });
    _ref.listen<AsyncValue<NightHistory?>>(
      hostNightHistoryProvider,
      (_, next) {
        final history = next.valueOrNull;
        if (history != null) _addEarlier(history.solves);
      },
      fireImmediately: true,
    );
  }

  final Ref _ref;
  StreamSubscription<SkotiqEvent>? _runEvents;
  final _RunCentering _centering = _RunCentering();

  DateTime _now() => _ref.read(clockProvider).nowUtc();

  void _followRun(DiagnosticsBackend backend) {
    _runEvents?.cancel();
    _centering.reset();
    _runEvents = backend.eventStream.listen((event) {
      if (event.category != EventCategory.sequencer) return;
      final typed = SequencerRunEvent.fromSkotiqEvent(event);
      if (typed == null) return;
      for (final record in _centering.fold(typed, _now)) {
        _add(record);
      }
    });
  }

  @override
  void dispose() {
    _runEvents?.cancel();
    super.dispose();
  }

  void _add(NightSolveRecord record) {
    if (!mounted) return;
    final next = <NightSolveRecord>[record, ...state];
    state = next.length > kNightRecentSolvesMax
        ? next.sublist(0, kNightRecentSolvesMax)
        : next;
  }

  /// Add the host's records (newest first) from before this app's oldest.
  void _addEarlier(List<NightSolveRecord> host) {
    if (!mounted || host.isEmpty) return;
    final oldest = state.isEmpty ? null : state.last.at;
    final next = <NightSolveRecord>[
      ...state,
      for (final record in host)
        if (oldest == null || record.at.isBefore(oldest)) record,
    ];
    state = next.length > kNightRecentSolvesMax
        ? next.sublist(0, kNightRecentSolvesMax)
        : next;
  }
}

/// Follows a run's Center steps through their progress: each attempt's solve
/// and the centering it ends in.
class _RunCentering {
  String? _nodeId;
  int _attempt = 0;
  int _solvedAttempt = 0;
  double? _separation;

  void reset() {
    _nodeId = null;
    _attempt = 0;
    _solvedAttempt = 0;
    _separation = null;
  }

  /// The records [event] completes.
  List<NightSolveRecord> fold(
      SequencerRunEvent event, DateTime Function() now) {
    switch (event) {
      case StructuredInstructionProgress(
          detailKind: 'Center',
          :final nodeId?,
          :final detailJson,
        ):
        if (nodeId != _nodeId) {
          reset();
          _nodeId = nodeId;
        }
        if (detailJson is! Map) return const [];
        final attempt = (detailJson['attempt'] as num?)?.toInt() ?? 0;
        final separation =
            (detailJson['last_separation_arcsec'] as num?)?.toDouble();
        final raHours = (detailJson['solved_ra_hours'] as num?)?.toDouble();
        final decDegrees =
            (detailJson['solved_dec_degrees'] as num?)?.toDouble();
        if (attempt > 0) {
          _attempt = attempt;
          if (separation == null || attempt == _solvedAttempt) return const [];
          _solvedAttempt = attempt;
          _separation = separation;
          return [
            NightSolveRecord(
              at: now(),
              kind: NightSolveKind.solve,
              success: true,
              raDegrees: raHours == null ? null : raHours * 15,
              decDegrees: decDegrees,
              offsetArcsec: separation,
              byRun: true,
            ),
          ];
        }
        // Attempt 0 with a distance: the step centered. It says so twice.
        if (separation == null || _attempt == 0) return const [];
        final record = NightSolveRecord(
          at: now(),
          kind: NightSolveKind.center,
          success: true,
          offsetArcsec: separation,
          iterations: _attempt,
          byRun: true,
        );
        reset();
        return [record];
      case NodeCompleted(:final nodeId?, :final status)
          when nodeId == _nodeId && _attempt > 0:
        // A stopped step did not fail to center, and a centered one was
        // recorded when it said so.
        final failed = status != 'success' && status != 'cancelled';
        final record = NightSolveRecord(
          at: now(),
          kind: NightSolveKind.center,
          success: false,
          offsetArcsec: _separation,
          iterations: _attempt,
          byRun: true,
        );
        reset();
        return failed ? [record] : const [];
      default:
        return const [];
    }
  }
}
