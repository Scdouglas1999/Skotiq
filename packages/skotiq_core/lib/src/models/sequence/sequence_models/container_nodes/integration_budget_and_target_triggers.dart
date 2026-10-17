// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

// Container / logic nodes

/// Dart mirror of the Rust `FilterBudgetEntry`.
/// `Absolute(secs)` caps that filter at a fixed time; `Ratio(value)` is
/// normalised against the other ratios in the same target and the
/// target's `totalSecs`. JSON shape matches the Rust enum:
/// `{"kind":"Absolute","value":3600.0}` / `{"kind":"Ratio","value":4.0}`.
class FilterBudgetEntry {
  /// `'Absolute'` or `'Ratio'`.
  final String kind;
  final double value;

  const FilterBudgetEntry.absolute(this.value) : kind = 'Absolute';
  const FilterBudgetEntry.ratio(this.value) : kind = 'Ratio';

  bool get isAbsolute => kind == 'Absolute';
  bool get isRatio => kind == 'Ratio';

  Map<String, dynamic> toJson() => {'kind': kind, 'value': value};

  factory FilterBudgetEntry.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String;
    final value = (json['value'] as num).toDouble();
    if (kind == 'Absolute') {
      return FilterBudgetEntry.absolute(value);
    } else if (kind == 'Ratio') {
      return FilterBudgetEntry.ratio(value);
    } else {
      throw FormatException(
        'Unknown FilterBudgetEntry kind "$kind"; expected Absolute or Ratio',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is FilterBudgetEntry && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => '$kind($value)';
}

/// Per-target integration budget configuration.
///
/// Mirrors the Rust `IntegrationBudget` struct one-to-one for serde
/// round-tripping through the FRB bridge. See
/// `native/skotiq_native/sequencer/src/lib.rs` for the canonical
/// definition.
class IntegrationBudget {
  /// Total wall-clock integration cap across all filters (seconds).
  /// `0.0` means "no overall cap"; only `perFilter` entries apply.
  final double totalSecs;

  /// Per-filter budgets. Empty map means "only totalSecs applies".
  final Map<String, FilterBudgetEntry> perFilter;

  /// When the budget is hit, the TargetHeader returns Success and the
  /// executor advances to the next sibling. Default true.
  final bool stopOnBudgetMet;

  const IntegrationBudget({
    this.totalSecs = 0.0,
    this.perFilter = const {},
    this.stopOnBudgetMet = true,
  });

  /// True iff the budget has at least one cap that can ever fire. The
  /// UI uses this to suppress no-op budget panels.
  bool get isActive {
    if (totalSecs > 0.0) return true;
    return perFilter.values.any((e) => e.value > 0);
  }

  /// Resolved absolute cap (seconds) for a single filter, mirroring
  /// `IntegrationBudget::resolved_filter_cap` on the Rust side. Used
  /// by the properties UI's "what will this carve up to?" preview.
  double? resolvedFilterCap(String filter) {
    final entry = perFilter[filter];
    if (entry == null) return null;
    if (entry.isAbsolute) {
      return entry.value > 0 ? entry.value : null;
    }
    if (entry.isRatio) {
      if (entry.value <= 0 || totalSecs <= 0) return null;
      final sum = perFilter.values
          .where((e) => e.isRatio && e.value > 0)
          .fold<double>(0, (acc, e) => acc + e.value);
      if (sum <= 0) return null;
      return (entry.value / sum) * totalSecs;
    }
    return null;
  }

  IntegrationBudget copyWith({
    double? totalSecs,
    Map<String, FilterBudgetEntry>? perFilter,
    bool? stopOnBudgetMet,
  }) {
    return IntegrationBudget(
      totalSecs: totalSecs ?? this.totalSecs,
      perFilter: perFilter ?? this.perFilter,
      stopOnBudgetMet: stopOnBudgetMet ?? this.stopOnBudgetMet,
    );
  }

  Map<String, dynamic> toJson() => {
    'total_secs': totalSecs,
    'per_filter': perFilter.map((k, v) => MapEntry(k, v.toJson())),
    'stop_on_budget_met': stopOnBudgetMet,
  };

  factory IntegrationBudget.fromJson(Map<String, dynamic> json) {
    return IntegrationBudget(
      totalSecs: (json['total_secs'] as num?)?.toDouble() ?? 0.0,
      perFilter: (json['per_filter'] as Map<String, dynamic>? ?? const {}).map(
        (k, v) =>
            MapEntry(k, FilterBudgetEntry.fromJson(v as Map<String, dynamic>)),
      ),
      stopOnBudgetMet: json['stop_on_budget_met'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! IntegrationBudget) return false;
    if (other.totalSecs != totalSecs) return false;
    if (other.stopOnBudgetMet != stopOnBudgetMet) return false;
    if (other.perFilter.length != perFilter.length) return false;
    for (final entry in perFilter.entries) {
      if (other.perFilter[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    totalSecs,
    stopOnBudgetMet,
    Object.hashAllUnordered(
      perFilter.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

// Per-target start/end altitude crossings.
//
// `TargetTrigger` mirrors the Rust enum in
// `native/skotiq_native/sequencer/src/scheduling/target_trigger.rs`.
// Used by `TargetHeaderNode.startWhen` / `endWhen` to gate when a target
// begins / ends imaging. We use a hand-rolled sealed-class hierarchy so
// JSON encoding stays symmetric with the Rust
// `#[serde(tag = "kind", content = "value")]` shape.

/// One leaf or compound condition that can gate a target's start / end.
///
/// Freezed-union backed: pattern-matching, equality, hashCode, and
/// copyWith are all generated. JSON encoding is HAND-WRITTEN (see
/// [TargetTrigger.toJson] / [TargetTrigger.fromJson]) because the wire
/// format is externally-tagged
/// (`{"kind": "<Variant>", "value": <payload>}`), which freezed cannot
/// natively express — it would emit a flat union with the payload
/// fields inlined alongside `kind`. The hand-written codec is the
/// contract pinned by Phase 1's `target_trigger_serde_test.dart`.
@Freezed(toJson: false, fromJson: false)
sealed class TargetTrigger with _$TargetTrigger {
  const TargetTrigger._();

  const factory TargetTrigger.altitudeAbove(double altitudeDeg) =
      AltitudeAboveTrigger;

  const factory TargetTrigger.altitudeBelow(double altitudeDeg) =
      AltitudeBelowTrigger;

  /// Unix timestamp (seconds).
  const factory TargetTrigger.timeAfter(int unixSeconds) = TimeAfterTrigger;

  /// Unix timestamp (seconds).
  const factory TargetTrigger.timeBefore(int unixSeconds) = TimeBeforeTrigger;

  const factory TargetTrigger.and(List<TargetTrigger> children) = AndTrigger;

  const factory TargetTrigger.or(List<TargetTrigger> children) = OrTrigger;

  const factory TargetTrigger.hourAngleBetween({
    required double minHa,
    required double maxHa,
  }) = HourAngleBetweenTrigger;

  /// JSON shape: `{"kind":"AltitudeAbove","value":35.0}` (and nested
  /// `value: [...]` for And/Or). Stays symmetric to the Rust
  /// `#[serde(tag = "kind", content = "value")]` encoding.
  Map<String, dynamic> toJson() {
    return switch (this) {
      AltitudeAboveTrigger(altitudeDeg: final v) => {
        'kind': 'AltitudeAbove',
        'value': v,
      },
      AltitudeBelowTrigger(altitudeDeg: final v) => {
        'kind': 'AltitudeBelow',
        'value': v,
      },
      TimeAfterTrigger(unixSeconds: final v) => {
        'kind': 'TimeAfter',
        'value': v,
      },
      TimeBeforeTrigger(unixSeconds: final v) => {
        'kind': 'TimeBefore',
        'value': v,
      },
      AndTrigger(children: final cs) => {
        'kind': 'And',
        'value': cs.map((c) => c.toJson()).toList(),
      },
      OrTrigger(children: final cs) => {
        'kind': 'Or',
        'value': cs.map((c) => c.toJson()).toList(),
      },
      HourAngleBetweenTrigger(minHa: final lo, maxHa: final hi) => {
        'kind': 'HourAngleBetween',
        'value': {'minHa': lo, 'maxHa': hi},
      },
    };
  }

  /// Decode a `TargetTrigger` from JSON. Throws on unknown / malformed
  /// kinds — errors-are-a-feature; we never silently downgrade to a
  /// trigger that is "always false" or "always true".
  factory TargetTrigger.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String?;
    final raw = json['value'];
    switch (kind) {
      case 'AltitudeAbove':
        return AltitudeAboveTrigger((raw as num).toDouble());
      case 'AltitudeBelow':
        return AltitudeBelowTrigger((raw as num).toDouble());
      case 'TimeAfter':
        return TimeAfterTrigger((raw as num).toInt());
      case 'TimeBefore':
        return TimeBeforeTrigger((raw as num).toInt());
      case 'And':
        return AndTrigger(
          (raw as List<dynamic>)
              .map((e) => TargetTrigger.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      case 'Or':
        return OrTrigger(
          (raw as List<dynamic>)
              .map((e) => TargetTrigger.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      case 'HourAngleBetween':
        final m = raw as Map<String, dynamic>;
        return HourAngleBetweenTrigger(
          minHa: (m['minHa'] as num).toDouble(),
          maxHa: (m['maxHa'] as num).toDouble(),
        );
      default:
        throw FormatException(
          'Unknown TargetTrigger kind "$kind" — expected AltitudeAbove, '
          'AltitudeBelow, TimeAfter, TimeBefore, And, Or, or HourAngleBetween',
        );
    }
  }

  /// Human-readable label used by the dashboard / live preview.
  String get label => switch (this) {
    AltitudeAboveTrigger(altitudeDeg: final v) =>
      'altitude ≥ ${v.toStringAsFixed(1)}°',
    AltitudeBelowTrigger(altitudeDeg: final v) =>
      'altitude ≤ ${v.toStringAsFixed(1)}°',
    TimeAfterTrigger(unixSeconds: final v) => 'time ≥ $v',
    TimeBeforeTrigger(unixSeconds: final v) => 'time < $v',
    AndTrigger(children: final cs) =>
      '(${cs.map((c) => c.label).join(' AND ')})',
    OrTrigger(children: final cs) => '(${cs.map((c) => c.label).join(' OR ')})',
    HourAngleBetweenTrigger(minHa: final lo, maxHa: final hi) =>
      '${lo.toStringAsFixed(2)}h ≤ HA ≤ ${hi.toStringAsFixed(2)}h',
  };

  /// True iff this trigger (or any nested sub-trigger) references an
  /// altitude threshold. Used by the validator to surface "this target
  /// never reaches that altitude from your location" errors.
  bool get referencesAltitude => switch (this) {
    AltitudeAboveTrigger() || AltitudeBelowTrigger() => true,
    AndTrigger(children: final cs) ||
    OrTrigger(children: final cs) => cs.any((c) => c.referencesAltitude),
    TimeAfterTrigger() ||
    TimeBeforeTrigger() ||
    HourAngleBetweenTrigger() => false,
  };

  /// Recursively detect empty And / Or compounds. Used by
  /// [TargetTriggerEmptyCompoundRule].
  bool get hasEmptyCompound => switch (this) {
    AndTrigger(children: final cs) || OrTrigger(children: final cs) =>
      cs.isEmpty || cs.any((c) => c.hasEmptyCompound),
    AltitudeAboveTrigger() ||
    AltitudeBelowTrigger() ||
    TimeAfterTrigger() ||
    TimeBeforeTrigger() ||
    HourAngleBetweenTrigger() => false,
  };
}

/// Evaluate a [TargetTrigger] against an observer / target / now snapshot.
/// Used by the dashboard live-preview and the
/// `TargetTriggerStartEndContradictionRule` validator. Mirrors the Rust
/// `TargetTrigger::is_satisfied`.
bool evaluateTargetTrigger(
  TargetTrigger trigger, {
  required double altitudeDeg,
  required double hourAngleHours,
  required int nowUnix,
}) {
  switch (trigger) {
    case AltitudeAboveTrigger(altitudeDeg: final t):
      return altitudeDeg >= t;
    case AltitudeBelowTrigger(altitudeDeg: final t):
      return altitudeDeg <= t;
    case TimeAfterTrigger(unixSeconds: final t):
      return nowUnix >= t;
    case TimeBeforeTrigger(unixSeconds: final t):
      return nowUnix < t;
    case AndTrigger(children: final cs):
      if (cs.isEmpty) return false;
      return cs.every(
        (c) => evaluateTargetTrigger(
          c,
          altitudeDeg: altitudeDeg,
          hourAngleHours: hourAngleHours,
          nowUnix: nowUnix,
        ),
      );
    case OrTrigger(children: final cs):
      if (cs.isEmpty) return false;
      return cs.any(
        (c) => evaluateTargetTrigger(
          c,
          altitudeDeg: altitudeDeg,
          hourAngleHours: hourAngleHours,
          nowUnix: nowUnix,
        ),
      );
    case HourAngleBetweenTrigger(minHa: final lo, maxHa: final hi):
      return hourAngleHours >= lo && hourAngleHours <= hi;
  }
}
