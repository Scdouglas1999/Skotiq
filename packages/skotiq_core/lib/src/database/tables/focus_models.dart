import 'package:drift/drift.dart';

import 'equipment_profiles.dart';

/// Persisted per-(equipment_profile, filter) focus model used by the
/// predictive autofocus subsystem.
///
/// This table stores the *learned* slope/intercept for the linear regression
/// between focuser temperature and best-focus position, keyed by
/// `(equipment_profile_id, filter_name)`. A single row per filter — the
/// learner appends new (temperature, position) samples after each successful
/// AF run, recomputes the regression on the last N samples (default 50), and
/// uses the resulting confidence (R²) to gate whether the next session can
/// skip a real AF sweep and trust the prediction.
///
/// One mutating current-best row per `(profile_id, filter_name)` — not an
/// append-only history — so a reader never re-runs the regression to answer a
/// query, and the unique index gives the predictor an O(1) lookup at AF time.
/// Nothing else in the schema references this table.
@DataClassName('FocusModelEntry')
@TableIndex(name: 'idx_focus_models_profile', columns: {#equipmentProfileId})
@TableIndex(
  name: 'idx_focus_models_profile_filter',
  columns: {#equipmentProfileId, #filterName},
  unique: true,
)
@TableIndex(name: 'idx_focus_models_last_used', columns: {#lastUsedAt})
class FocusModels extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// UUID — stable identifier for export/import + cross-device reference.
  TextColumn get uuid => text()();

  /// Reference to the equipment profile the model belongs to. SET NULL on
  /// profile delete so models survive a profile rename/replace and can be
  /// re-attached manually by the user.
  IntColumn get equipmentProfileId => integer().nullable().references(
    EquipmentProfiles,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// Filter name as it appears on the filter wheel (e.g. "L", "R", "Ha").
  /// Case-sensitive — the filter wheel reports the canonical name so we
  /// store it verbatim.
  TextColumn get filterName => text()();

  /// Filter slot index on the wheel (0-based). Stored alongside `filterName`
  /// because some users swap filter sets between wheels — the index alone
  /// is ambiguous, but pairing it with the name lets the UI offer a
  /// "re-attach to slot N" action without losing the learned data.
  IntColumn get filterIndex => integer().nullable()();

  /// Learned regression slope in focuser steps per degree Celsius.
  /// Sign convention: positive = focus moves outward when temperature
  /// increases. Typical values are in [-100, +100]; the learner rejects
  /// any slope outside `[-maxAcceptable, +maxAcceptable]` (default 500).
  RealColumn get temperatureCompensationSlope => real()();

  /// Focus offset (steps) relative to the luminance / reference filter.
  /// Positive = move *out* relative to L. Recomputed on every sample
  /// insertion when the reference filter is set.
  IntColumn get focusOffsetRelativeToLum =>
      integer().withDefault(const Constant(0))();

  /// Focuser position at the reference temperature ([referenceTempCelsius]).
  /// Together with [temperatureCompensationSlope] this lets the predictor
  /// compute `position(T) = intercept + slope * (T - T_ref)`.
  IntColumn get interceptAtReferenceTemp => integer()();

  /// Reference temperature used by the intercept. Defaults to 10 °C but is
  /// reset on each re-fit to the mean of the training samples to keep the
  /// regression numerically stable across wide temperature spans.
  RealColumn get referenceTempCelsius =>
      real().withDefault(const Constant(10.0))();

  /// When the regression was last re-fit. Distinct from [lastUsedAt]: the
  /// model may be queried (used) without being re-fit (trained).
  DateTimeColumn get lastTrainedAt => dateTime()();

  /// Count of AF runs that have contributed to the current model. Decoupled
  /// from `length(trainingSamplesJson)` because old samples get pruned —
  /// this counter is monotonic and shows the total history a user has
  /// accumulated.
  IntColumn get trainingRunCount => integer().withDefault(const Constant(0))();

  /// R² of the last regression fit, in [0, 1]. Used to gate direct
  /// application of the model:
  ///   * `>= 0.8` → trust the prediction
  ///   * `< 0.5` → force a real AF sweep
  ///   * in between → apply with a smaller correction factor
  RealColumn get confidenceScore => real().withDefault(const Constant(0.0))();

  /// Last time the model was queried for a prediction (NOT a training
  /// event). Lets the UI surface "stale model" warnings for filters the
  /// user hasn't used in months.
  DateTimeColumn get lastUsedAt => dateTime().nullable()();

  /// JSON-encoded list of training samples currently in the regression
  /// window. Schema (matches [FocusTrainingSample]):
  /// ```
  /// [
  ///   {
  ///     "ts": 1715946000,        // unix seconds
  ///     "temp": 8.3,              // °C
  ///     "position": 28150,        // focuser steps
  ///     "hfr": 1.92               // half-flux radius from the AF run
  ///   },
  ///   ...
  /// ]
  /// ```
  /// Kept inline: reads are always whole-list (the fit re-runs over every
  /// sample on insertion) and the retained count is capped (50 by default,
  /// 200 max), so the column stays bounded.
  TextColumn get trainingSamplesJson =>
      text().withDefault(const Constant('[]'))();

  /// Maximum number of training samples retained in the JSON blob. User-
  /// configurable per filter (the Ha narrowband crowd might want more
  /// history because they only get a few AF runs per night).
  IntColumn get maxTrainingSamples =>
      integer().withDefault(const Constant(50))();

  /// Number of consecutive AF runs where the model's prediction was off by
  /// more than the drift threshold. When this exceeds 5, the service emits
  /// a "re-train recommended" notification. Reset on a successful re-train
  /// or a manual "clear samples" action.
  IntColumn get consecutiveBadPredictions =>
      integer().withDefault(const Constant(0))();

  /// Cumulative drift (in focuser steps) over the recent consecutive bad
  /// predictions — surfaced in the notification body ("drifted by 1200
  /// steps over the last 5 runs").
  IntColumn get accumulatedDriftSteps =>
      integer().withDefault(const Constant(0))();

  /// Row created/updated timestamps so the UI can sort the model viewer by
  /// "most recently learned".
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
