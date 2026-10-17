// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sequence_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_MosaicPanelInfo _$MosaicPanelInfoFromJson(Map<String, dynamic> json) =>
    _MosaicPanelInfo(
      mosaicName: json['mosaic_name'] as String,
      panelIndex: (json['panel_index'] as num).toInt(),
      totalPanels: (json['total_panels'] as num).toInt(),
      row: (json['row'] as num).toInt(),
      column: (json['column'] as num).toInt(),
    );

Map<String, dynamic> _$MosaicPanelInfoToJson(_MosaicPanelInfo instance) =>
    <String, dynamic>{
      'mosaic_name': instance.mosaicName,
      'panel_index': instance.panelIndex,
      'total_panels': instance.totalPanels,
      'row': instance.row,
      'column': instance.column,
    };

_BrightnessTierPreferences _$BrightnessTierPreferencesFromJson(
  Map<String, dynamic> json,
) => _BrightnessTierPreferences(
  faintMinScore: (json['faint_min_score'] as num?)?.toDouble() ?? 70.0,
  mediumMinScore: (json['medium_min_score'] as num?)?.toDouble() ?? 50.0,
  brightMinScore: (json['bright_min_score'] as num?)?.toDouble() ?? 30.0,
);

Map<String, dynamic> _$BrightnessTierPreferencesToJson(
  _BrightnessTierPreferences instance,
) => <String, dynamic>{
  'faint_min_score': instance.faintMinScore,
  'medium_min_score': instance.mediumMinScore,
  'bright_min_score': instance.brightMinScore,
};

_ConditionsScoreWeights _$ConditionsScoreWeightsFromJson(
  Map<String, dynamic> json,
) => _ConditionsScoreWeights(
  transparencyWeight: (json['transparency_weight'] as num?)?.toDouble() ?? 0.40,
  seeingWeight: (json['seeing_weight'] as num?)?.toDouble() ?? 0.25,
  cloudWeight: (json['cloud_weight'] as num?)?.toDouble() ?? 0.25,
  windWeight: (json['wind_weight'] as num?)?.toDouble() ?? 0.10,
);

Map<String, dynamic> _$ConditionsScoreWeightsToJson(
  _ConditionsScoreWeights instance,
) => <String, dynamic>{
  'transparency_weight': instance.transparencyWeight,
  'seeing_weight': instance.seeingWeight,
  'cloud_weight': instance.cloudWeight,
  'wind_weight': instance.windWeight,
};

_ConditionsScore _$ConditionsScoreFromJson(Map<String, dynamic> json) =>
    _ConditionsScore(
      score: (json['score'] as num).toDouble(),
      transparencyScore: (json['transparency_score'] as num?)?.toDouble(),
      seeingScore: (json['seeing_score'] as num?)?.toDouble(),
      cloudScore: (json['cloud_score'] as num?)?.toDouble(),
      windScore: (json['wind_score'] as num?)?.toDouble(),
      weights: json['weights'] == null
          ? const ConditionsScoreWeights()
          : ConditionsScoreWeights.fromJson(
              json['weights'] as Map<String, dynamic>,
            ),
      generatedAt: const UnixSecsDateTimeConverter().fromJson(
        (json['generated_unix_secs'] as num).toInt(),
      ),
    );

Map<String, dynamic> _$ConditionsScoreToJson(_ConditionsScore instance) =>
    <String, dynamic>{
      'score': instance.score,
      'transparency_score': instance.transparencyScore,
      'seeing_score': instance.seeingScore,
      'cloud_score': instance.cloudScore,
      'wind_score': instance.windScore,
      'weights': instance.weights.toJson(),
      'generated_unix_secs': const UnixSecsDateTimeConverter().toJson(
        instance.generatedAt,
      ),
    };

_AdaptiveSwapRuntimeState _$AdaptiveSwapRuntimeStateFromJson(
  Map<String, dynamic> json,
) => _AdaptiveSwapRuntimeState(
  currentTargetId: json['current_target_id'] as String?,
  currentTier: json['current_tier'] as String?,
  lastDecisionKind: json['last_decision_kind'] as String?,
  lastDecisionReason: json['last_decision_reason'] as String?,
  lastSwapAt: const NullableUnixSecsDateTimeConverter().fromJson(
    (json['last_swap_unix_secs'] as num?)?.toInt(),
  ),
  lastSwapFromTargetId: json['last_swap_from_target_id'] as String?,
  lastSwapToTargetId: json['last_swap_to_target_id'] as String?,
  lastObservedScore: (json['last_observed_score'] as num?)?.toDouble(),
  configuredThreshold: (json['configured_threshold'] as num?)?.toDouble(),
  configuredHysteresisSecs:
      (json['configured_hysteresis_secs'] as num?)?.toDouble() ?? 180.0,
);

Map<String, dynamic> _$AdaptiveSwapRuntimeStateToJson(
  _AdaptiveSwapRuntimeState instance,
) => <String, dynamic>{
  'current_target_id': instance.currentTargetId,
  'current_tier': instance.currentTier,
  'last_decision_kind': instance.lastDecisionKind,
  'last_decision_reason': instance.lastDecisionReason,
  'last_swap_unix_secs': const NullableUnixSecsDateTimeConverter().toJson(
    instance.lastSwapAt,
  ),
  'last_swap_from_target_id': instance.lastSwapFromTargetId,
  'last_swap_to_target_id': instance.lastSwapToTargetId,
  'last_observed_score': instance.lastObservedScore,
  'configured_threshold': instance.configuredThreshold,
  'configured_hysteresis_secs': instance.configuredHysteresisSecs,
};

_AdaptiveSwapSnapshot _$AdaptiveSwapSnapshotFromJson(
  Map<String, dynamic> json,
) => _AdaptiveSwapSnapshot(
  score: json['score'] == null
      ? null
      : ConditionsScore.fromJson(json['score'] as Map<String, dynamic>),
  state: json['state'] == null
      ? const AdaptiveSwapRuntimeState()
      : AdaptiveSwapRuntimeState.fromJson(
          json['state'] as Map<String, dynamic>,
        ),
);

Map<String, dynamic> _$AdaptiveSwapSnapshotToJson(
  _AdaptiveSwapSnapshot instance,
) => <String, dynamic>{
  'score': instance.score?.toJson(),
  'state': instance.state.toJson(),
};

_FilterPlan _$FilterPlanFromJson(Map<String, dynamic> json) => _FilterPlan(
  filterName: json['filter_name'] as String? ?? '',
  filterIndex: (json['filter_index'] as num?)?.toInt(),
  count: (json['count'] as num?)?.toInt() ?? 10,
  durationSecs: (json['duration_secs'] as num?)?.toDouble() ?? 60.0,
  gain: (json['gain'] as num?)?.toInt(),
  offset: (json['offset'] as num?)?.toInt(),
  binning: json['binning'] == null
      ? BinningMode.one
      : const BinningModeJsonConverter().fromJson(json['binning'] as String?),
  ditherEvery: (json['dither_every'] as num?)?.toInt(),
  depthGoal: json['depth_goal'] == null
      ? null
      : DepthGoalBinding.fromJson(json['depth_goal'] as Map<String, dynamic>),
);

Map<String, dynamic> _$FilterPlanToJson(_FilterPlan instance) =>
    <String, dynamic>{
      'filter_name': instance.filterName,
      'filter_index': instance.filterIndex,
      'count': instance.count,
      'duration_secs': instance.durationSecs,
      'gain': instance.gain,
      'offset': instance.offset,
      'binning': const BinningModeJsonConverter().toJson(instance.binning),
      'dither_every': instance.ditherEvery,
      'depth_goal': instance.depthGoal?.toJson(),
    };

_DepthGoalBinding _$DepthGoalBindingFromJson(Map<String, dynamic> json) =>
    _DepthGoalBinding(
      goalId: json['goal_id'] as String,
      revision: (json['revision'] as num).toInt(),
    );

Map<String, dynamic> _$DepthGoalBindingToJson(_DepthGoalBinding instance) =>
    <String, dynamic>{
      'goal_id': instance.goalId,
      'revision': instance.revision,
    };

_AdaptiveExposureConfig _$AdaptiveExposureConfigFromJson(
  Map<String, dynamic> json,
) => _AdaptiveExposureConfig(
  targetSnr: (json['target_snr'] as num?)?.toDouble() ?? 30.0,
  referenceSkyBrightnessMag:
      (json['reference_sky_brightness_mag'] as num?)?.toDouble() ?? 21.5,
  minExposureSecs: (json['min_exposure_secs'] as num?)?.toDouble() ?? 5.0,
  maxExposureSecs: (json['max_exposure_secs'] as num?)?.toDouble() ?? 600.0,
  perFilterEnabled:
      (json['per_filter_enabled'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, e as bool),
      ) ??
      const <String, bool>{},
  perFilterMinSecs:
      (json['per_filter_min_secs'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, (e as num).toDouble()),
      ) ??
      const <String, double>{},
  perFilterMaxSecs:
      (json['per_filter_max_secs'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, (e as num).toDouble()),
      ) ??
      const <String, double>{},
  enabled: json['enabled'] as bool? ?? true,
);

Map<String, dynamic> _$AdaptiveExposureConfigToJson(
  _AdaptiveExposureConfig instance,
) => <String, dynamic>{
  'target_snr': instance.targetSnr,
  'reference_sky_brightness_mag': instance.referenceSkyBrightnessMag,
  'min_exposure_secs': instance.minExposureSecs,
  'max_exposure_secs': instance.maxExposureSecs,
  'per_filter_enabled': instance.perFilterEnabled,
  'per_filter_min_secs': instance.perFilterMinSecs,
  'per_filter_max_secs': instance.perFilterMaxSecs,
  'enabled': instance.enabled,
};

_PhotometryQualityGates _$PhotometryQualityGatesFromJson(
  Map<String, dynamic> json,
) => _PhotometryQualityGates(
  minSnr: (json['min_snr'] as num?)?.toDouble() ?? 50.0,
  maxFwhmArcsec: (json['max_fwhm_arcsec'] as num?)?.toDouble() ?? 5.0,
  requireAllRefsVisible: json['require_all_refs_visible'] as bool? ?? true,
  maxAirmass: (json['max_airmass'] as num?)?.toDouble() ?? 2.5,
);

Map<String, dynamic> _$PhotometryQualityGatesToJson(
  _PhotometryQualityGates instance,
) => <String, dynamic>{
  'min_snr': instance.minSnr,
  'max_fwhm_arcsec': instance.maxFwhmArcsec,
  'require_all_refs_visible': instance.requireAllRefsVisible,
  'max_airmass': instance.maxAirmass,
};

_TransparencyBackupPlan _$TransparencyBackupPlanFromJson(
  Map<String, dynamic> json,
) => _TransparencyBackupPlan(
  backupFilter: json['backup_filter'] as String?,
  backupTargetId: json['backup_target_id'] as String?,
  description: json['description'] as String?,
);

Map<String, dynamic> _$TransparencyBackupPlanToJson(
  _TransparencyBackupPlan instance,
) => <String, dynamic>{
  'backup_filter': instance.backupFilter,
  'backup_target_id': instance.backupTargetId,
  'description': instance.description,
};
