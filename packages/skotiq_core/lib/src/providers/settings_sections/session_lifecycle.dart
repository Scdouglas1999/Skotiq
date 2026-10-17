// Session-lifecycle and adaptive sky-conditions defaults.
// Owns the multi-night carry-over banner, the campaign-rollup UI toggle,
// and the seed values dropped into new [TargetSchedulerNode]s when the
// adaptive-swap composer is enabled.
//
// The grouping is intentional: both subsystems describe "what should the
// sequence runner DO across nights / across conditions changes" rather
// than "how should a single capture be shot".
//
// Owns:
// * sessionHandoffAutoPrompt (carry-over banner)
// * campaignRollupSurfaceTargetsTab, campaignRollupGroupingMode
//   * adaptiveSwapEnabledByDefault, adaptiveSwapDefaultThreshold,
// adaptiveSwapDefaultHysteresisSecs
// * conditionsScoreWeights
//
// Does NOT own:
//   * Per-scheduler `swapOnConditionsBelow` — those are sequence-model
//     fields, not app settings.
//   * Smart Night defaults → see `smart_night.dart`.
part of '../settings_provider.dart';

/// Setters for session lifecycle + adaptive sky-conditions
/// defaults.
extension SessionLifecycleSettingsSection on AppSettingsNotifier {
  /// Whether the multi-night carry-over banner auto-opens at pre-flight
  /// when an unfinished session is detected for one of the sequence's
  /// targets. Consumed by `sessionHandoffAutoPromptProvider` and the
  /// preflight widget.
  Future<void> setSessionHandoffAutoPrompt(bool value) async {
    await _saveSetting('session.handoff_auto_prompt', value.toString());
    _patchState((s) => s.copyWith(sessionHandoffAutoPrompt: value));
  }

  /// Whether the Targets tab surfaces the per-target campaign rollup
  /// column. Consumed by the targets-tab widget.
  Future<void> setCampaignRollupSurfaceTargetsTab(bool value) async {
    await _saveSetting('campaign_rollup.surface_targets_tab', value.toString());
    _patchState((s) => s.copyWith(campaignRollupSurfaceTargetsTab: value));
  }

  /// Campaign grouping mode (`by_target_name`, `by_target_id`,
  /// `by_user_tag`). Unknown values fall back to `by_target_name`.
  Future<void> setCampaignRollupGroupingMode(String value) async {
    const allowed = ['by_target_name', 'by_target_id', 'by_user_tag'];
    final clamped = allowed.contains(value) ? value : 'by_target_name';
    await _saveSetting('campaign_rollup.grouping_mode', clamped);
    _patchState((s) => s.copyWith(campaignRollupGroupingMode: clamped));
  }

  /// Toggle whether brand-new [TargetSchedulerNode]s ship with adaptive
  /// swap enabled (`swapOnConditionsBelow` set to the default threshold).
  /// Existing nodes are NOT mutated by this setting — see
  /// [TargetSchedulerNode.swapOnConditionsBelow] for the per-node knob.
  Future<void> setAdaptiveSwapEnabledByDefault(bool value) async {
    await _saveSetting('adaptive_swap.enabled_by_default', value.toString());
    _patchState((s) => s.copyWith(adaptiveSwapEnabledByDefault: value));
  }

  /// Default conditions-score floor (0..=100) seeded into a new
  /// scheduler when [adaptiveSwapEnabledByDefault] is true.
  Future<void> setAdaptiveSwapDefaultThreshold(double value) async {
    final clamped = value.clamp(0.0, 100.0);
    await _saveSetting('adaptive_swap.default_threshold', clamped.toString());
    _patchState((s) => s.copyWith(adaptiveSwapDefaultThreshold: clamped));
  }

  /// Default `swapHysteresisSecs` (seconds between consecutive swaps)
  /// seeded into a new scheduler.
  Future<void> setAdaptiveSwapDefaultHysteresisSecs(double value) async {
    final clamped = value.clamp(0.0, 3600.0);
    await _saveSetting(
      'adaptive_swap.default_hysteresis_secs',
      clamped.toString(),
    );
    _patchState((s) => s.copyWith(adaptiveSwapDefaultHysteresisSecs: clamped));
  }

  /// Per-axis composer weights for the live ConditionsScore. The map is
  /// JSON-encoded under `adaptive_swap.score_weights`. Unknown keys are
  /// stripped at parse time; missing axes fall back to the defaults.
  /// The caller is responsible for normalising the weights to sum to
  /// ~1.0 if they want a "pure" 0..=100 score — but the composer
  /// renormalises over the available axes so a non-normalised map still
  /// produces sane scores.
  Future<void> setConditionsScoreWeights(Map<String, double> weights) async {
    // Sanitise — drop unknown keys, clamp negatives to 0, keep positives
    // as-is so the user can experiment with weight bands > 1 if they
    // want to test the composer's renormalisation.
    const known = {'transparency', 'seeing', 'cloud', 'wind'};
    final sanitised = <String, double>{
      for (final entry in weights.entries)
        if (known.contains(entry.key) && entry.value.isFinite)
          entry.key: entry.value < 0 ? 0.0 : entry.value,
    };
    await _saveSetting('adaptive_swap.score_weights', jsonEncode(sanitised));
    _patchState((s) => s.copyWith(conditionsScoreWeights: sanitised));
  }
}
