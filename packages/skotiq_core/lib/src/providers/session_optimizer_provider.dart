import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' show TwilightTimes;

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../database/daos/guide_rms_history_dao.dart';
import '../models/planning/target_suggestion.dart';
import '../services/scheduler/integration_goal_service.dart';
import '../services/logging_service.dart';
import '../services/science/science_camera_auto_config.dart';
import '../services/smart_night/exposure_calculator.dart';
import '../services/smart_night/hardware_specs_service.dart';
import '../services/session_optimizer_service.dart';
import '../services/smart_night_service.dart';
import 'backend_provider.dart';
import '../services/sensor_specs/camera_sensor_specs.dart';
import 'camera_sensor_specs_provider.dart';
import 'database_provider.dart';
import 'equipment/filter_wheel_state_provider.dart';
import 'profiles_provider.dart';
import 'session_report_provider.dart';
import 'settings_provider.dart';
import 'target_suggestion_provider.dart';

/// Service provider for SessionOptimizerService.
///
/// Depends on [targetSuggestionServiceProvider] which is injected via the
/// service constructor.
final sessionOptimizerServiceProvider = Provider<SessionOptimizerService>((
  ref,
) {
  final suggestionService = ref.watch(targetSuggestionServiceProvider);
  return SessionOptimizerService(suggestionService: suggestionService);
});

final hardwareSpecsServiceProvider = Provider<HardwareSpecsService>(
  (_) => const HardwareSpecsService(),
);

/// Builds the Smart Night exposure context used by Plan Tonight and dashboard
/// recommendations.
///
/// Sensor values come from [activeCameraSensorSpecsProvider], the one
/// resolution chain: the user's own entry, then the connected camera, then
/// what that camera reported last time, then the manufacturer's published
/// specification. Only a field that misses at every tier becomes a caveat, and
/// that caveat names the camera it could not find the figure for.
///
/// Missing telescope focal length or aperture still disables the Smart Night
/// path, because the physics model cannot be made meaningful without them.
final smartNightExposureContextProvider = FutureProvider<SmartNightExposureContext?>((
  ref,
) async {
  final settings = await ref.watch(appSettingsProvider.future);
  final opticalConfig = ref.watch(opticalConfigProvider);
  final profile = ref.watch(activeEquipmentProfileProvider);
  final effectiveFilters = ref.watch(effectiveFiltersProvider);
  final backend = ref.watch(backendProvider);
  final guideStats = await _weightedGuideRmsForMount(
    profile?.mountId,
    backend: backend,
    localDao: backend is NetworkBackend
        ? null
        : ref.watch(guideRmsHistoryDaoProvider),
  );

  final focalLength = opticalConfig?.focalLength ?? profile?.focalLength;
  final aperture = opticalConfig?.aperture ?? profile?.aperture;
  if (focalLength == null ||
      focalLength <= 0 ||
      aperture == null ||
      aperture <= 0) {
    return null;
  }

  final rawSettings = await ref.watch(rigCameraSettingsProvider.future);
  final caveats = <String>[];
  if (_cameraOverridesAreMalformed(rawSettings)) {
    caveats.add(unreadableSensorOverridesCaveat);
  }

  final sensorSpecs = await ref.watch(activeCameraSensorSpecsProvider.future);
  final cameraLabel =
      sensorSpecs.databaseEntry?.model ??
      sensorSpecs.reportedModel ??
      'this camera';

  // The expert `smart_night.camera.*` / frozen `science.camera.*` keys are a
  // second user-entered source, reachable only through settings and the
  // headless API. They rank BELOW the per-camera override, which is the
  // surface the camera sensor specs dialog writes and the one the Plan screen
  // sends people to: a value the user just corrected for this camera must not
  // be outranked by a global key they set for a different one.
  final settingsReadNoise = _readDoubleSetting(
    rawSettings,
    'science.camera.read_noise_e',
  );
  final settingsFullWell = _readDoubleSetting(
    rawSettings,
    'smart_night.camera.full_well_e',
  );
  final settingsQePeak = _readDoubleSetting(
    rawSettings,
    'smart_night.camera.qe_peak',
  );
  final gloverK = _readDoubleSetting(
    rawSettings,
    'smart_night.glover_k_factor',
  );

  // `science.camera.read_noise_e` is auto-managed from the sensor specs unless
  // the user froze it, so it only counts as their own value when frozen —
  // otherwise the chain would be reading its own output back as an override.
  final readNoiseIsUserFrozen =
      rawSettings[ScienceCameraAutoConfig.autoManagedKey]?.toLowerCase() ==
      'false';

  final pixelSize =
      opticalConfig?.pixelSize != null && opticalConfig!.pixelSize! > 0
      ? opticalConfig.pixelSize!
      : sensorSpecs.pixelSizeMicrons?.value;
  final readNoise = _preferUserValue(
    sensorSpecs.readNoiseE,
    readNoiseIsUserFrozen ? settingsReadNoise : null,
  );
  final fullWell = _preferUserValue(sensorSpecs.fullWellE, settingsFullWell);
  final qePeak = _preferUserValue(sensorSpecs.qePeakFraction, settingsQePeak);

  if (pixelSize == null) {
    caveats.add(
      sensorSpecCaveat(
        field: SensorSpecField.pixelSize,
        cameraLabel: cameraLabel,
        estimate: 'a $_kPlanningPixelSizeMicrons micron estimate',
      ),
    );
  }
  if (readNoise == null) {
    caveats.add(
      sensorSpecCaveat(
        field: SensorSpecField.readNoise,
        cameraLabel: cameraLabel,
        estimate:
            'a conservative ${_kPlanningReadNoiseE.toStringAsFixed(1)}e- '
            'estimate',
      ),
    );
  }
  if (fullWell == null) {
    caveats.add(
      sensorSpecCaveat(
        field: SensorSpecField.fullWell,
        cameraLabel: cameraLabel,
        estimate: 'an 18,000e- estimate',
      ),
    );
  }
  if (qePeak == null) {
    caveats.add(
      sensorSpecCaveat(
        field: SensorSpecField.qePeak,
        cameraLabel: cameraLabel,
        estimate: 'a ${(_kPlanningQePeak * 100).round()}% estimate',
      ),
    );
  }

  return SmartNightExposureContext(
    camera: CameraExposureSpec(
      readNoiseE: readNoise ?? _kPlanningReadNoiseE,
      fullWellE: fullWell ?? _kPlanningFullWellE,
      qePeak: (qePeak ?? _kPlanningQePeak).clamp(0.05, 1.0).toDouble(),
    ),
    bortleClass: settings.bortleClass,
    focalLengthMm: focalLength,
    apertureMm: aperture,
    pixelSizeMicrons: pixelSize ?? _kPlanningPixelSizeMicrons,
    availableFilterNames: effectiveFilters.isNotEmpty
        ? effectiveFilters
        : (profile?.filterNames ?? const []),
    guideRmsArcsec: guideStats.rmsArcsec,
    guideSampleCount: guideStats.sampleCount,
    gloverKFactor: gloverK ?? 10,
    targetSnr: settings.smartNightTargetSnr,
    userCapSeconds: settings.smartNightSubExposureCeilingSecs,
    floorSeconds: settings.smartNightSubExposureFloorSecs,
    caveats: caveats,
  );
});

/// Stand-ins used only when a value misses at every tier of the resolution
/// chain, each paired with a caveat that says so. Chosen to be conservative
/// rather than typical: a planning estimate that flatters the rig produces
/// sub-exposures that clip.
const double _kPlanningPixelSizeMicrons = 3.76;
const double _kPlanningReadNoiseE = 3.5;
const double _kPlanningFullWellE = 18000;
const double _kPlanningQePeak = 0.65;

/// Picks between the resolved value and a global expert setting.
///
/// A value the user entered for THIS camera wins outright. Otherwise the
/// global setting wins if there is one, because a reading or a published
/// figure is not a correction. Otherwise whatever resolved, and null when
/// nothing did.
double? _preferUserValue(
  SensorSpecValue<double>? resolved,
  double? globalSetting,
) {
  if (resolved?.origin == SensorSpecOrigin.userOverride) {
    return resolved!.value;
  }
  return globalSetting ?? resolved?.value;
}

/// Whether the saved camera overrides exist but cannot be parsed. The user
/// needs to know their entry is being ignored.
bool _cameraOverridesAreMalformed(Map<String, String> settings) {
  final raw = settings[HardwareSpecsService.cameraOverridesSettingKey];
  if (raw == null || raw.trim().isEmpty) return false;
  try {
    HardwareSpecsService.cameraOverridesFromJson(jsonDecode(raw));
    return false;
  } catch (_) {
    return true;
  }
}

/// Dismissed insight ids (sticky "Don't suggest this again").
///
/// Persisted under `session_insights.dismissed` as a comma-joined list of
/// insight ids. The DAO is the same `app_settings` table used elsewhere,
/// so the lifecycle matches: cleared on a database wipe, otherwise
/// survives app restarts.
class _DismissedInsightsNotifier extends AsyncNotifier<Set<String>> {
  static const _key = 'session_insights.dismissed';
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<Set<String>> build() async {
    final dao = ref.watch(settingsDaoProvider);
    final raw = await dao.getSetting(_key) ?? '';
    if (raw.trim().isEmpty) return <String>{};
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  Future<void> _update(Set<String> Function(Set<String> current) change) {
    final result = _writeTail.then((_) async {
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError(
          'Dismissed session insights are not loaded; refusing to '
          'overwrite them with an empty set.',
        );
      }
      final updated = Set<String>.unmodifiable(change(current));
      final dao = ref.read(settingsDaoProvider);
      await dao.setSetting(_key, updated.join(','));
      if (!identical(ref.read(settingsDaoProvider), dao)) {
        throw StateError(
          'The settings database changed while saving dismissed insights.',
        );
      }
      state = AsyncValue.data(updated);
    });
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> dismiss(String id) => _update((current) => {...current, id});

  Future<void> undismiss(String id) => _update((current) {
    if (!current.contains(id)) return current;
    return {...current}..remove(id);
  });

  Future<void> clear() => _update((_) => const <String>{});
}

/// Operator's "Don't suggest this again" set.
final dismissedSessionInsightsProvider =
    AsyncNotifierProvider<_DismissedInsightsNotifier, Set<String>>(
      _DismissedInsightsNotifier.new,
    );

/// Retrospective post-session insights for the given session id.
///
/// Computes [SessionInsight]s from the persisted [SessionReport] plus any
/// altitude traces produced at runtime. The trace list is empty: the database
/// records no sub-minute frame timestamps, so per-second altitude history
/// cannot be reconstructed, and the trace-dependent insights are simply not
/// produced.
final sessionInsightsProvider = FutureProvider.autoDispose
    .family<List<SessionInsight>, int>((ref, sessionId) async {
      final report = await ref.watch(sessionReportProvider(sessionId).future);
      final dismissed = await ref.watch(
        dismissedSessionInsightsProvider.future,
      );
      final service = ref.watch(sessionOptimizerServiceProvider);
      return service.analyze(
        report: report,
        altitudeTraces: const <SessionTargetAltitudeTrace>[],
        thresholds: SessionInsightThresholds(dismissedIds: dismissed),
      );
    });

double? _readDoubleSetting(Map<String, String> settings, String key) {
  final raw = settings[key];
  if (raw == null || raw.trim().isEmpty) return null;
  final parsed = double.tryParse(raw);
  if (parsed == null || !parsed.isFinite || parsed <= 0) return null;
  return parsed;
}

class _GuideRmsStats {
  final double? rmsArcsec;
  final int sampleCount;

  const _GuideRmsStats({this.rmsArcsec, this.sampleCount = 0});
}

Future<_GuideRmsStats> _weightedGuideRmsForMount(
  String? mountId, {
  required SkotiqBackend backend,
  required GuideRmsHistoryDao? localDao,
}) async {
  final trimmedMountId = mountId?.trim();
  if (trimmedMountId == null || trimmedMountId.isEmpty) {
    return const _GuideRmsStats();
  }

  final List<({double totalRmsArcsec, DateTime recordedAt})> samples;
  if (backend is NetworkBackend) {
    final page = await backend.fetchGuideRmsHistory(
      mountId: trimmedMountId,
      limit: 20,
    );
    samples = page.items
        .map(
          (sample) => (
            totalRmsArcsec: sample.totalRmsArcsec,
            recordedAt: sample.recordedAt,
          ),
        )
        .toList(growable: false);
  } else {
    final rows = await localDao!.recentForMount(trimmedMountId, limit: 20);
    samples = rows
        .map(
          (sample) => (
            totalRmsArcsec: sample.totalRmsArcsec,
            recordedAt: sample.recordedAt,
          ),
        )
        .toList(growable: false);
  }
  if (samples.isEmpty) {
    return const _GuideRmsStats();
  }

  final recentCutoff = DateTime.now().subtract(const Duration(days: 30));
  var weightedRms = 0.0;
  var weightTotal = 0.0;
  for (final sample in samples) {
    if (sample.totalRmsArcsec <= 0 || !sample.totalRmsArcsec.isFinite) {
      continue;
    }
    final weight = sample.recordedAt.isAfter(recentCutoff) ? 2.0 : 1.0;
    weightedRms += sample.totalRmsArcsec * weight;
    weightTotal += weight;
  }

  if (weightTotal <= 0) {
    return _GuideRmsStats(sampleCount: samples.length);
  }

  return _GuideRmsStats(
    rmsArcsec: weightedRms / weightTotal,
    sampleCount: samples.length,
  );
}

/// Per-target Smart Night integration estimate for Plan Tonight rows.
final plannerTargetIntegrationPreviewProvider = FutureProvider.autoDispose
    .family<TargetIntegrationPreview?, int>((ref, targetId) async {
      final profile = ref.watch(activeEquipmentProfileProvider);
      if (profile == null) return null;

      final exposureContext = await ref.watch(
        smartNightExposureContextProvider.future,
      );
      if (exposureContext == null) return null;

      final suggestions = ref.watch(tonightSuggestionsProvider).valueOrNull;
      if (suggestions == null) return null;

      TargetSuggestion? suggestion;
      for (final candidate in suggestions) {
        if (candidate.targetId == targetId) {
          suggestion = candidate;
          break;
        }
      }
      if (suggestion == null) return null;

      final settings = await ref.watch(appSettingsProvider.future);
      if (settings.latitude == 0.0 && settings.longitude == 0.0) return null;

      // An empty list is a wheel-less rig, not missing data — the service
      // estimates an unfiltered night for it.
      final filters = ref.watch(effectiveFiltersProvider);

      late final ({DateTime start, DateTime end, TwilightTimes twilight})
      window;
      try {
        window =
            SmartNightService(
              suggestionService: ref.read(targetSuggestionServiceProvider),
              logging: ref.read(loggingServiceProvider),
            ).calculateWindow(
              latitudeDeg: settings.latitude,
              longitudeDeg: settings.longitude,
            );
      } on SmartNightBuildException {
        return null;
      }

      final integrationGoals = await ref
          .read(integrationGoalServiceProvider)
          .progressForTarget(targetId);

      final smartNightSettings = SmartNightSettings(
        targetSnr: settings.smartNightTargetSnr,
        subExposureCeilingSecs: settings.smartNightSubExposureCeilingSecs,
        subExposureFloorSecs: settings.smartNightSubExposureFloorSecs,
      );

      return SmartNightService(
        suggestionService: ref.read(targetSuggestionServiceProvider),
        logging: ref.read(loggingServiceProvider),
      ).previewTargetIntegration(
        profile: profile,
        suggestion: suggestion,
        windowStart: window.start,
        windowEnd: window.end,
        availableFilters: filters,
        exposureContext: exposureContext,
        settings: smartNightSettings,
        integrationGoalProgress: integrationGoals,
      );
    });
