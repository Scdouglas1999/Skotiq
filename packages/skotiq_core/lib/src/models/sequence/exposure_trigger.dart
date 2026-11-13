/// A trigger on an exposure step: a condition the executor checks after each
/// burst and what it does when the condition holds. Stored on the
/// [ExposureNode] in the executor's own `TriggerCondition` / `TriggerAction`
/// form (`native/skotiq_native/sequencer/src/lib.rs`), which this file encodes
/// and decodes.
library;

enum TriggerConditionType { guidingRms, hfr, drift }

/// What a trigger does when its condition holds after a burst.
///
/// HFR, guiding RMS and drift are the software's judgment of the frames, and
/// that judgment can be wrong, so a new trigger notifies and keeps imaging
/// (owner decision 2026-10-06: only a risk to the hardware stops a run by
/// itself). Pausing and ending the run stay available for the operator who
/// picks them.
enum TriggerActionType { notify, pauseAndRecalibrate, autofocus, abort }

/// Default threshold for each condition type. Switching condition type in the
/// editor MUST reset the active threshold to the matching default, because the
/// underlying physical unit changes (arcseconds for guiding RMS, pixels for
/// HFR, pixels per axis for drift), so reusing the prior numeric value across a
/// unit boundary silently changes what the trigger means.
///
///   * `guidingRms` 2.0".
///   * `hfr` 4.0 px matches `default_hfr_threshold` in the Rust quality module.
///   * `drift` 3.0 px is PER AXIS: the Rust executor
///     (`TriggerCondition::DriftAbove`) compares each axis independently with
///     OR semantics, so 3 px catches real tracking drift without firing on
///     guider jitter.
const double kDefaultGuidingRmsArcsec = 2.0;
const double kDefaultHfrPixels = 4.0;
const double kDefaultDriftRaPixels = 3.0;
const double kDefaultDriftDecPixels = 3.0;

double defaultTriggerThreshold(TriggerConditionType c) {
  switch (c) {
    case TriggerConditionType.guidingRms:
      return kDefaultGuidingRmsArcsec;
    case TriggerConditionType.hfr:
      return kDefaultHfrPixels;
    case TriggerConditionType.drift:
      return kDefaultDriftRaPixels;
  }
}

/// Seconds a condition must hold before a new trigger acts. The executor's
/// `ExposureTrigger` requires the field, so every stored trigger carries it.
const double kDefaultTriggerDebounceSecs = 10.0;

class ExposureTriggerConfig {
  final TriggerConditionType condition;

  /// Threshold for guiding RMS (arcsec) or HFR (pixels). Unused — and
  /// intentionally NOT round-tripped — for drift conditions.
  final double threshold;

  /// RA-axis drift threshold (pixels). Only meaningful when
  /// `condition == TriggerConditionType.drift`.
  final double driftRaPx;

  /// Dec-axis drift threshold (pixels). Only meaningful when
  /// `condition == TriggerConditionType.drift`. The Rust executor
  /// (`TriggerCondition::DriftAbove`) compares this independently against the
  /// measured Dec drift, so this MUST round-trip separately from the RA value.
  final double driftDecPx;

  final TriggerActionType action;
  final double debounceSecs;

  ExposureTriggerConfig({
    required this.condition,
    required this.threshold,
    required this.action,
    this.debounceSecs = kDefaultTriggerDebounceSecs,
    double? driftRaPx,
    double? driftDecPx,
  }) : driftRaPx = driftRaPx ?? kDefaultDriftRaPixels,
       driftDecPx = driftDecPx ?? kDefaultDriftDecPixels;

  ExposureTriggerConfig copyWith({
    TriggerConditionType? condition,
    double? threshold,
    double? driftRaPx,
    double? driftDecPx,
    TriggerActionType? action,
    double? debounceSecs,
  }) {
    return ExposureTriggerConfig(
      condition: condition ?? this.condition,
      threshold: threshold ?? this.threshold,
      driftRaPx: driftRaPx ?? this.driftRaPx,
      driftDecPx: driftDecPx ?? this.driftDecPx,
      action: action ?? this.action,
      debounceSecs: debounceSecs ?? this.debounceSecs,
    );
  }

  Map<String, dynamic> toNativeJson() {
    final conditionJson = switch (condition) {
      TriggerConditionType.guidingRms => {'GuidingRmsAbove': threshold},
      TriggerConditionType.hfr => {'HfrAbove': threshold},
      TriggerConditionType.drift => {
        // J-X2: RA and Dec are serialised independently to match the Rust
        // `TriggerCondition::DriftAbove { ra_px, dec_px }` shape, which
        // compares each axis with its own threshold (OR semantics, see
        // sequencer/src/node/instructions/expose.rs).
        'DriftAbove': {'ra_px': driftRaPx, 'dec_px': driftDecPx},
      },
    };
    final actionJson = switch (action) {
      TriggerActionType.notify => 'Notify',
      TriggerActionType.pauseAndRecalibrate => 'PauseAndRecalibrate',
      TriggerActionType.autofocus => 'Autofocus',
      TriggerActionType.abort => 'Abort',
    };
    return {
      'condition': conditionJson,
      'action': actionJson,
      'debounce_secs': debounceSecs,
    };
  }

  /// The trigger [json] stores in the executor's form, or null for one this
  /// build does not read (an unknown condition or action, a missing field):
  /// the caller keeps that trigger as it is rather than rewriting it as
  /// another.
  static ExposureTriggerConfig? fromNativeJson(Map<String, dynamic> json) {
    final condition = json['condition'];
    final action = switch (json['action']) {
      'Notify' => TriggerActionType.notify,
      'PauseAndRecalibrate' => TriggerActionType.pauseAndRecalibrate,
      'Autofocus' => TriggerActionType.autofocus,
      'Abort' => TriggerActionType.abort,
      _ => null,
    };
    final debounce = json['debounce_secs'];
    if (condition is! Map || condition.length != 1) return null;
    if (action == null || debounce is! num) return null;
    final (
      type,
      threshold,
      driftRa,
      driftDec,
    ) = switch (condition.entries.single) {
      MapEntry(key: 'GuidingRmsAbove', value: final num rms) => (
        TriggerConditionType.guidingRms,
        rms.toDouble(),
        null,
        null,
      ),
      MapEntry(key: 'HfrAbove', value: final num hfr) => (
        TriggerConditionType.hfr,
        hfr.toDouble(),
        null,
        null,
      ),
      MapEntry(
        key: 'DriftAbove',
        value: {'ra_px': final num ra, 'dec_px': final num dec},
      ) =>
        (
          TriggerConditionType.drift,
          ra.toDouble(),
          ra.toDouble(),
          dec.toDouble(),
        ),
      _ => (null, null, null, null),
    };
    if (type == null || threshold == null) return null;
    return ExposureTriggerConfig(
      condition: type,
      threshold: threshold,
      driftRaPx: driftRa,
      driftDecPx: driftDec,
      action: action,
      debounceSecs: debounce.toDouble(),
    );
  }

  String get conditionLabel {
    switch (condition) {
      case TriggerConditionType.guidingRms:
        return 'Guiding RMS > $threshold"';
      case TriggerConditionType.hfr:
        return 'HFR > $threshold px';
      case TriggerConditionType.drift:
        // J-X2: show both thresholds so a user with asymmetric values can
        // tell at a glance which axis would fire first.
        if (driftRaPx == driftDecPx) {
          return 'Drift > $driftRaPx px (both axes)';
        }
        return 'Drift > RA $driftRaPx px / Dec $driftDecPx px';
    }
  }
}
