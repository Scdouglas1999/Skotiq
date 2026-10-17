import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart' show PolarAlignmentHistoryEntry;
import '../models/sequencer/recovery_status.dart';
import '../services/optical_train_diagnostics_service.dart';
import '../services/time_sync_service.dart';
import 'polar_alignment_provider.dart' show lastPolarAlignmentProvider;
import 'sequence_stats_provider.dart' show sessionDiagnosticsDaoProvider;

// Pre-flight wiring providers
//
// Riverpod providers that surface the data the pre-flight validation rules
// need without each rule re-implementing the lookup. Kept separate from
// the rule files so test overrides have a single grep-able home.

/// Provider for the NTP-based time-sync probe. Override in tests with a
/// fake that returns a synthetic offset (or throws to simulate a
/// network failure).
final timeSyncProbeProvider = Provider<TimeSyncProbe>((ref) {
  return const TimeSyncServiceProbe(TimeSyncService());
});

/// Most recent polar-alignment history entry across ALL equipment
/// profiles. The pre-flight rule uses this to decide whether the
/// alignment is stale — checking per-profile would miss the case where
/// the user is on a profile that has no history yet but their other
/// rig was aligned an hour ago, etc. Profile-aware variants can be
/// added later.
///
/// `null` => no polar alignment has ever been recorded; the rule then
/// emits an info-severity "you haven't polar aligned yet" issue (still
/// honouring strictness).
final lastPolarAlignmentAnywhereProvider =
    FutureProvider.autoDispose<PolarAlignmentHistoryEntry?>((ref) async {
      return ref.watch(lastPolarAlignmentProvider(null).future);
    });

/// Pre-session optical-train baseline snapshot. Captured the first time
/// the user runs a sequence (or after the user clears it via the
/// diagnostics tab). The pre-flight rule compares the current snapshot
/// to this baseline to detect "your rig has shifted since last
/// session".
///
/// `null` => no baseline has been recorded yet; the rule skips the
/// comparison and surfaces an info note explaining that the first run
/// is establishing a baseline. Updated automatically by the executor on
/// run start.
class OpticalTrainBaseline {
  final double tiltScore;
  final double collimationScore;
  final DateTime capturedAt;

  const OpticalTrainBaseline({
    required this.tiltScore,
    required this.collimationScore,
    required this.capturedAt,
  });

  /// Construct from a diagnostics reading.
  factory OpticalTrainBaseline.fromDiagnostics(
    OpticalTrainDiagnostics diagnostics, {
    DateTime? capturedAt,
  }) {
    return OpticalTrainBaseline(
      tiltScore: diagnostics.tiltScore,
      collimationScore: diagnostics.collimationScore,
      capturedAt: capturedAt ?? DateTime.now(),
    );
  }

  /// Round-trips with [OpticalTrainBaseline.fromJson]. Persists the
  /// per-session optical-train baseline/current snapshots into
  /// `session_diagnostics` so a historical run report can show that session's
  /// drift comparison instead of the live provider.
  Map<String, dynamic> toJson() => {
    'tiltScore': tiltScore,
    'collimationScore': collimationScore,
    'capturedAt': capturedAt.toIso8601String(),
  };

  /// Inverse of [toJson].
  factory OpticalTrainBaseline.fromJson(Map<String, dynamic> json) {
    return OpticalTrainBaseline(
      tiltScore: (json['tiltScore'] as num).toDouble(),
      collimationScore: (json['collimationScore'] as num).toDouble(),
      capturedAt: DateTime.parse(json['capturedAt'] as String),
    );
  }

  /// Total magnitude of drift from this baseline to the supplied
  /// current diagnostics. Equal-weight blend of tilt + collimation
  /// score deltas matches the `OpticalHealthScore` weighting so the
  /// pre-flight number agrees with the diagnostics dashboard.
  double driftAgainst(OpticalTrainDiagnostics current) {
    final dTilt = (current.tiltScore - tiltScore).abs();
    final dColl = (current.collimationScore - collimationScore).abs();
    return dTilt * 0.5 + dColl * 0.5;
  }
}

/// In-memory baseline store. Persisting this across launches lives
/// further out (the executor writes it to a key in `app_settings` on
/// every run start); the in-process provider here is the runtime
/// cache. Tests override it directly via `overrideWith`.
final opticalTrainBaselineProvider = StateProvider<OpticalTrainBaseline?>(
  (ref) => null,
);

/// Current optical-train snapshot supplied by the post-session pipeline
/// (or by the test harness). The pipeline fills this from the live
/// diagnostics stream when a sequence finishes; the pre-flight rule
/// reads it to compare against [opticalTrainBaselineProvider].
///
/// `null` => no current snapshot is available yet — the rule emits an
/// info note rather than silently passing.
final opticalTrainCurrentSnapshotProvider =
    StateProvider<OpticalTrainBaseline?>((ref) => null);

// Per-session (historical) report providers
//
// The live providers above always hold the MOST RECENT run's diagnostics (or
// nothing after a restart). A historical run report opened from the History
// list must show THAT run's recoveries and drift comparison, not whatever the
// live providers happen to hold. These family providers read the persisted
// `session_diagnostics` row keyed by session id, so the report dialog can
// reload exactly the session it was opened for. The active session keeps using
// the live providers.

/// Pre/post optical-train snapshot pair for a single persisted session.
///
/// [baseline] is the snapshot captured at run start; [current] is the
/// snapshot captured at session end. Either may be `null` when that snapshot
/// was unavailable for the run (e.g. no solved frames yet at the time it would
/// have been taken).
class SessionOpticalTrainSnapshot {
  final OpticalTrainBaseline? baseline;
  final OpticalTrainBaseline? current;

  const SessionOpticalTrainSnapshot({
    required this.baseline,
    required this.current,
  });
}

/// Recovery history for a *historical* run, reloaded from the persisted
/// `session_diagnostics` row for [sessionId].
///
/// Returns an empty list when the session has no diagnostics row (e.g. a run
/// that predates the table, or one that recorded no recovery loops). Use this
/// instead of the live [recoveryHistoryProvider] when rendering a report for a
/// session other than the active one.
final recoveryHistoryForSessionProvider = FutureProvider.autoDispose
    .family<List<RecoveryHistoryEntry>, int>((ref, sessionId) async {
      final dao = ref.watch(sessionDiagnosticsDaoProvider);
      final row = await dao.getForSession(sessionId);
      final raw = row?.recoveryHistoryJson;
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => RecoveryHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    });

/// Pre/post optical-train snapshots for a *historical* run, reloaded from the
/// persisted `session_diagnostics` row for [sessionId].
///
/// Returns a pair with both fields `null` when the session has no diagnostics
/// row. Use this instead of the live [opticalTrainBaselineProvider] /
/// [opticalTrainCurrentSnapshotProvider] when rendering a report for a session
/// other than the active one.
final opticalTrainSnapshotForSessionProvider = FutureProvider.autoDispose
    .family<SessionOpticalTrainSnapshot, int>((ref, sessionId) async {
      final dao = ref.watch(sessionDiagnosticsDaoProvider);
      final row = await dao.getForSession(sessionId);
      OpticalTrainBaseline? decode(String? raw) {
        if (raw == null || raw.isEmpty) return null;
        return OpticalTrainBaseline.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }

      return SessionOpticalTrainSnapshot(
        baseline: decode(row?.opticalTrainBaselineJson),
        current: decode(row?.opticalTrainCurrentJson),
      );
    });

/// Latest equipment-health snapshot for the post-session diagnostics
/// summary. Holds simple counters that don't fit cleanly into the
/// existing `EquipmentHealthReport` (which is built from session
/// history). Populated by the executor's session bookkeeping; tests
/// inject directly.
class PostSessionHealthSummary {
  /// Total USB / connection disconnects across all devices observed
  /// during the session.
  final int disconnectsDuringSession;

  /// Number of cooler temperature samples that exceeded the
  /// configured setpoint band (used for "cooler stability"
  /// surfacing).
  final int coolerOutOfBandSamples;

  /// Total focuser moves recorded during the session.
  final int focuserMoves;

  /// Sky brightness range encountered during the session, in mag /
  /// arcsec² (Bortle / SQM units).
  final double? skyBrightnessMin;
  final double? skyBrightnessMax;
  final double? skyBrightnessMedian;

  /// Any "noticed but did not fire" warnings — e.g. HFR trending up
  /// but never exceeding the explicit reject threshold. Surfaced
  /// verbatim in the post-session diagnostics section so the user
  /// knows the system was watching.
  final List<String> noticedConcerns;

  const PostSessionHealthSummary({
    this.disconnectsDuringSession = 0,
    this.coolerOutOfBandSamples = 0,
    this.focuserMoves = 0,
    this.skyBrightnessMin,
    this.skyBrightnessMax,
    this.skyBrightnessMedian,
    this.noticedConcerns = const [],
  });

  /// Whether there is anything interesting to render. The diagnostics
  /// section in the report dialog hides itself when this returns
  /// `false`, on the principle that a perfectly boring run should
  /// not get a noisy "nothing happened" block.
  bool get hasContent {
    return disconnectsDuringSession > 0 ||
        coolerOutOfBandSamples > 0 ||
        focuserMoves > 0 ||
        skyBrightnessMin != null ||
        noticedConcerns.isNotEmpty;
  }
}

/// Per-session post-session health summary. Family keyed by sessionId.
/// Populated by the executor's session tear-down and read by the
/// post-session report dialog.
final postSessionHealthSummaryProvider =
    StateProvider.family<PostSessionHealthSummary, int>(
      (ref, sessionId) => const PostSessionHealthSummary(),
    );
