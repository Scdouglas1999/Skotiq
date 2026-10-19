// The solves and centerings of this session, newest first, for the Solve
// tab's "Recent solves". Kept in memory from the moment Tonight first shows
// the Solve tab; nothing survives an app restart, and the list says "this
// session" because of it.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

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
  });

  /// When the result arrived, a true instant.
  final DateTime at;
  final NightSolveKind kind;
  final bool success;

  /// The solved position (solves only).
  final double? raDegrees;
  final double? decDegrees;

  /// A centering's final distance from its target.
  final double? offsetArcsec;

  /// A centering's attempts.
  final int? iterations;

  /// How long the solve took, as the solver reported it.
  final Duration? duration;
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
  }

  final Ref _ref;

  DateTime _now() => _ref.read(clockProvider).nowUtc();

  void _add(NightSolveRecord record) {
    if (!mounted) return;
    final next = <NightSolveRecord>[record, ...state];
    state = next.length > kNightRecentSolvesMax
        ? next.sublist(0, kNightRecentSolvesMax)
        : next;
  }

  /// When the newest plain solve arrived, or null.
  DateTime? get lastSolveAt {
    for (final record in state) {
      if (record.kind == NightSolveKind.solve) return record.at;
    }
    return null;
  }
}
