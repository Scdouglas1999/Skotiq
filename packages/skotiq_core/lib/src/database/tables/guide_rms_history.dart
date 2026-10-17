import 'package:drift/drift.dart';

/// Per-session guiding RMS history used by Smart Night's exposure planner.
///
/// Written at session end by the guide-RMS collector service. The Smart Night
/// exposure model computes the "recent guide RMS" input as a weighted average
/// of the last N entries for the current mount, so this table is append-only.
@DataClassName('GuideRmsHistoryEntry')
class GuideRmsHistory extends Table {
  /// Auto-incrementing primary key.
  IntColumn get id => integer().autoIncrement()();

  /// Session identifier this sample belongs to.
  TextColumn get sessionId => text()();

  /// Mount identifier (driver-reported), used to scope per-mount averages.
  TextColumn get mountId => text()();

  /// Target the session was imaging, when applicable.
  IntColumn get targetId => integer().nullable()();

  /// Total RMS (combined RA+Dec) in arcseconds for the session.
  RealColumn get totalRmsArcsec => real()();

  /// Number of guide samples that contributed to [totalRmsArcsec].
  IntColumn get sampleCount => integer()();

  /// Sub-exposure length in seconds while these RMS samples were recorded.
  ///
  /// Nullable as of schema v30: older sessions imported before the planner
  /// tracked sub-exposure length need to round-trip without a default value
  /// (a synthetic default would corrupt the exposure-distribution heuristic
  /// the Smart Night planner derives from this column).
  RealColumn get exposureSeconds => real().nullable()();

  /// When the sample was recorded.
  DateTimeColumn get recordedAt => dateTime()();
}
