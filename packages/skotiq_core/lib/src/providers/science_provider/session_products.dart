part of '../science_provider.dart';

class ScienceSessionConfigController {
  ScienceSessionConfigController(Ref ref)
    : _scopes = AsyncScopes(ref.read, scienceProductsProvider);

  final AsyncScopes<ScienceProducts> _scopes;

  Future<void> save(int sessionId, ScienceSessionConfig config) async {
    final scope = _scopes.begin();
    await scope.value.upsertSessionConfig(
      config.copyWith(sessionId: sessionId),
    );
    scope.ensureCurrent('saving the science session');
  }
}

final scienceSessionConfigControllerProvider =
    Provider<ScienceSessionConfigController>((ref) {
      return ScienceSessionConfigController(ref);
    });

final scienceSessionConfigProvider =
    StreamProvider.family<ScienceSessionConfig?, int>(
      (ref, sessionId) => ref
          .watch(scienceProductsProvider)
          .watchSessionScienceConfig(sessionId),
    );

final activeScienceSessionConfigProvider =
    Provider<AsyncValue<ScienceSessionConfig?>>((ref) {
      final sessionId = ref.watch(sessionStateProvider).dbSessionId;
      if (sessionId == null) {
        return const AsyncValue.data(null);
      }
      return ref.watch(scienceSessionConfigProvider(sessionId));
    });

/// Remote science catalogs are low-churn and do not need to hammer the host.
/// Exposed so the recovery/distinct behavior can be tested without a 10s wait.
final remoteSciencePollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 10),
);

/// The science measurements of whichever machine is the imaging host: this
/// process's database, or the linked host's.
final scienceProductsProvider = Provider<ScienceProducts>((ref) {
  final remote = ref.watch(backendProvider).remoteHost;
  if (remote == null) return ref.watch(scienceDaoProvider);
  return remote.scienceProducts(
    pollInterval: ref.watch(remoteSciencePollIntervalProvider),
  );
});

/// The rows the science settings are stored in: the settings table, or the
/// linked host's science settings.
final _scienceSettingRowsProvider = Provider<SettingRows>(
  (ref) =>
      ref.watch(backendProvider).remoteHost?.scienceSettingRows ??
      ref.watch(settingsDaoProvider),
);

final sessionPhotometryProvider =
    StreamProvider.family<List<PhotometryMeasurementRow>, int>((
      ref,
      sessionId,
    ) {
      return ref
          .watch(scienceProductsProvider)
          .watchPhotometryForSession(sessionId);
    });

final sessionFrameCalibrationsProvider =
    StreamProvider.family<List<FramePhotometricCalibrationRow>, int>((
      ref,
      sessionId,
    ) {
      return ref
          .watch(scienceProductsProvider)
          .watchCalibrationsForSession(sessionId);
    });

final sessionTransparencySamplesProvider =
    StreamProvider.family<List<TransparencySampleRow>, int>((ref, sessionId) {
      return ref
          .watch(scienceProductsProvider)
          .watchTransparencyForSession(sessionId);
    });

final sessionPsfTilesProvider =
    StreamProvider.family<List<PsfFieldTileRow>, int>((ref, sessionId) {
      return ref
          .watch(scienceProductsProvider)
          .watchPsfTilesForSession(sessionId);
    });

final sessionFrameQualityMetricsProvider =
    StreamProvider.family<List<ScienceFrameQualityMetricsRow>, int>((
      ref,
      sessionId,
    ) {
      return ref
          .watch(scienceProductsProvider)
          .watchFrameQualityMetricsForSession(sessionId);
    });

/// The tile metrics of one frame of a session; see
/// [ScienceProducts.watchFrameTileMetrics].
final frameTileMetricsProvider = StreamProvider.autoDispose
    .family<
      List<ScienceTileMetricRow>,
      ({int sessionId, int? capturedImageId})
    >((ref, frame) {
      return ref
          .watch(scienceProductsProvider)
          .watchFrameTileMetrics(
            frame.sessionId,
            capturedImageId: frame.capturedImageId,
          );
    });

final sessionResidualVectorsProvider =
    StreamProvider.family<List<AstrometryResidualVectorRow>, int>((
      ref,
      sessionId,
    ) {
      return ref
          .watch(scienceProductsProvider)
          .watchResidualsForSession(sessionId);
    });

final sessionMovingObjectCandidatesProvider =
    StreamProvider.family<List<MovingObjectCandidateRow>, int>((
      ref,
      sessionId,
    ) {
      return ref
          .watch(scienceProductsProvider)
          .watchMovingObjectsForSession(sessionId);
    });

final sessionLineRatioProductsProvider =
    StreamProvider.family<List<LineRatioProductRow>, int>((ref, sessionId) {
      return ref
          .watch(scienceProductsProvider)
          .watchLineRatiosForSession(sessionId);
    });

/// Light curve for one object across EVERY session that imaged a target.
///
/// The per-session curve cannot support a period search: a night is a few
/// hours and the periods people look for are usually longer, so a single-night
/// periodogram can only ever return its own baseline. A linked host has no
/// equivalent read and yields an empty curve rather than a silently truncated
/// one.
final targetLightCurveProvider =
    StreamProvider.family<
      List<LightCurvePoint>,
      (int targetId, String objectId)
    >((ref, args) {
      return ref
          .watch(scienceProductsProvider)
          .watchPhotometryForTarget(targetId: args.$1, objectId: args.$2)
          .map(
            (rows) => rows
                .where((row) => row.differentialMagnitude != null)
                .map(
                  (row) => LightCurvePoint(
                    timestamp: row.timestamp,
                    flux: row.flux,
                    differentialMagnitude: row.differentialMagnitude!,
                    snr: row.snr ?? 0.0,
                    uncertainty: row.uncertainty ?? 0.0,
                    filter: row.filter,
                  ),
                )
                .toList(growable: false),
          );
    });

final sessionLightCurveProvider =
    Provider.family<List<LightCurvePoint>, (int sessionId, String objectId)>((
      ref,
      args,
    ) {
      final photometry =
          ref.watch(sessionPhotometryProvider(args.$1)).valueOrNull ?? const [];

      return photometry
          // Drop rows with no measured magnitude: a coerced 0.0 is junk for the
          // charts (a spurious mag-0 point) and triggers a false ~14-mag
          // "brightening" in the Narrator's LightCurveEventDetector.
          .where(
            (row) =>
                row.objectId == args.$2 && row.differentialMagnitude != null,
          )
          .map(
            (row) => LightCurvePoint(
              timestamp: row.timestamp,
              flux: row.flux,
              differentialMagnitude: row.differentialMagnitude!,
              snr: row.snr ?? 0.0,
              uncertainty: row.uncertainty ?? 0.0,
              filter: row.filter,
            ),
          )
          .toList(growable: false);
    });

final sessionTransparencyTrendProvider =
    Provider.family<List<TransparencyTrendPoint>, int>((ref, sessionId) {
      final rows =
          ref
              .watch(sessionTransparencySamplesProvider(sessionId))
              .valueOrNull ??
          const [];
      return rows
          .map(
            (row) => TransparencyTrendPoint(
              timestamp: row.timestamp,
              transparencyPercent: row.transparencyPercent,
              extinctionCoefficient: row.extinctionCoefficient,
              extinctionMeasured: row.extinctionMeasured,
              filter: row.filter,
            ),
          )
          .toList(growable: false);
    });

final sessionMovingObjectTrendProvider =
    Provider.family<List<MovingObjectCandidate>, int>((ref, sessionId) {
      final rows =
          ref
              .watch(sessionMovingObjectCandidatesProvider(sessionId))
              .valueOrNull ??
          const [];
      return rows
          .map(
            (row) => MovingObjectCandidate(
              timestamp: row.timestamp,
              candidateId: row.candidateId,
              confidence: row.confidence,
              motionArcsecPerMinute: row.motionArcsecPerMinute,
              objectName: row.objectName,
            ),
          )
          .toList(growable: false);
    });

// Sessionless (standalone snapshot) providers

final sessionlessCalibrationsProvider =
    StreamProvider<List<FramePhotometricCalibrationRow>>((ref) {
      return ref
          .watch(scienceProductsProvider)
          .watchSessionlessCalibrationsRecent();
    });

final sessionlessTransparencySamplesProvider =
    StreamProvider<List<TransparencySampleRow>>((ref) {
      return ref
          .watch(scienceProductsProvider)
          .watchSessionlessTransparencyRecent();
    });

final sessionlessPsfTilesProvider = StreamProvider<List<PsfFieldTileRow>>((
  ref,
) {
  return ref.watch(scienceProductsProvider).watchSessionlessPsfTilesRecent();
});

final sessionlessFrameQualityMetricsProvider =
    StreamProvider<List<ScienceFrameQualityMetricsRow>>((ref) {
      return ref
          .watch(scienceProductsProvider)
          .watchSessionlessFrameQualityMetricsRecent();
    });

final sessionlessTileMetricsProvider =
    StreamProvider<List<ScienceTileMetricRow>>((ref) {
      return ref
          .watch(scienceProductsProvider)
          .watchSessionlessTileMetricsRecent();
    });

final sessionlessResidualVectorsProvider =
    StreamProvider<List<AstrometryResidualVectorRow>>((ref) {
      return ref
          .watch(scienceProductsProvider)
          .watchSessionlessResidualsRecent();
    });

final sessionlessMovingObjectCandidatesProvider =
    StreamProvider<List<MovingObjectCandidateRow>>((ref) {
      return ref
          .watch(scienceProductsProvider)
          .watchSessionlessMovingObjectsRecent();
    });

final sessionlessPhotometryProvider =
    StreamProvider<List<PhotometryMeasurementRow>>((ref) {
      return ref
          .watch(scienceProductsProvider)
          .watchSessionlessPhotometryRecent();
    });

// Sessionless export providers — complete datasets, not the preview window
//
// The `sessionless*Provider` streams above are UI preview feeds: each caps its
// row count (200 photometry / 50 frame-quality / 500 PSF tiles …) so a list or
// chart stays cheap. Reusing them for CSV export silently dropped 27–62% of the
// user's science data while the confirmation reported the truncated count as the
// export size. Export paths read these instead: locally the un-capped DAO query,
// remotely the host's bundle slice (still windowed — the caller must say so).
//
// One per dataset the Science Data Export hub writes.

final sessionlessPhotometryExportProvider =
    FutureProvider<List<PhotometryMeasurementRow>>((ref) {
      ref.watch(sessionlessPhotometryProvider);
      return ref.watch(scienceProductsProvider).getAllSessionlessPhotometry();
    });

final sessionlessFrameQualityMetricsExportProvider =
    FutureProvider<List<ScienceFrameQualityMetricsRow>>((ref) {
      ref.watch(sessionlessFrameQualityMetricsProvider);
      return ref
          .watch(scienceProductsProvider)
          .getAllSessionlessFrameQualityMetrics();
    });

final sessionlessTransparencySamplesExportProvider =
    FutureProvider<List<TransparencySampleRow>>((ref) {
      ref.watch(sessionlessTransparencySamplesProvider);
      return ref.watch(scienceProductsProvider).getAllSessionlessTransparency();
    });

final sessionlessPsfTilesExportProvider = FutureProvider<List<PsfFieldTileRow>>(
  (ref) {
    ref.watch(sessionlessPsfTilesProvider);
    return ref.watch(scienceProductsProvider).getAllSessionlessPsfTiles();
  },
);

final sessionlessResidualVectorsExportProvider =
    FutureProvider<List<AstrometryResidualVectorRow>>((ref) {
      ref.watch(sessionlessResidualVectorsProvider);
      return ref.watch(scienceProductsProvider).getAllSessionlessResiduals();
    });

final sessionlessCalibrationsExportProvider =
    FutureProvider<List<FramePhotometricCalibrationRow>>((ref) {
      ref.watch(sessionlessCalibrationsProvider);
      return ref.watch(scienceProductsProvider).getAllSessionlessCalibrations();
    });

final sessionlessMovingObjectCandidatesExportProvider =
    FutureProvider<List<MovingObjectCandidateRow>>((ref) {
      ref.watch(sessionlessMovingObjectCandidatesProvider);
      return ref
          .watch(scienceProductsProvider)
          .getAllSessionlessMovingObjects();
    });

final sessionlessLineRatioProductsProvider =
    StreamProvider<List<LineRatioProductRow>>((ref) {
      return ref
          .watch(scienceProductsProvider)
          .watchSessionlessLineRatiosRecent();
    });

final sessionlessLightCurveProvider =
    Provider.family<List<LightCurvePoint>, String>((ref, objectId) {
      final photometry =
          ref.watch(sessionlessPhotometryProvider).valueOrNull ?? const [];

      return photometry
          // Drop rows with no measured magnitude (see sessionLightCurveProvider).
          .where(
            (row) =>
                row.objectId == objectId && row.differentialMagnitude != null,
          )
          .map(
            (row) => LightCurvePoint(
              timestamp: row.timestamp,
              flux: row.flux,
              differentialMagnitude: row.differentialMagnitude!,
              snr: row.snr ?? 0.0,
              uncertainty: row.uncertainty ?? 0.0,
              filter: row.filter,
            ),
          )
          .toList(growable: false);
    });

final sessionlessTransparencyTrendProvider =
    Provider<List<TransparencyTrendPoint>>((ref) {
      final rows =
          ref.watch(sessionlessTransparencySamplesProvider).valueOrNull ??
          const [];
      return rows
          .map(
            (row) => TransparencyTrendPoint(
              timestamp: row.timestamp,
              transparencyPercent: row.transparencyPercent,
              extinctionCoefficient: row.extinctionCoefficient,
              extinctionMeasured: row.extinctionMeasured,
              filter: row.filter,
            ),
          )
          .toList(growable: false);
    });

final currentScienceSnapshotProvider =
    Provider<(FramePhotometricCalibrationRow?, TransparencySampleRow?)>((ref) {
      final sessionId = ref.watch(sessionStateProvider).dbSessionId;

      List<FramePhotometricCalibrationRow> calibrations;
      List<TransparencySampleRow> transparency;

      if (sessionId != null) {
        calibrations =
            ref
                .watch(sessionFrameCalibrationsProvider(sessionId))
                .valueOrNull ??
            const [];
        transparency =
            ref
                .watch(sessionTransparencySamplesProvider(sessionId))
                .valueOrNull ??
            const [];
      } else {
        // Fall back to sessionless data for standalone captures
        calibrations =
            ref.watch(sessionlessCalibrationsProvider).valueOrNull ?? const [];
        transparency =
            ref.watch(sessionlessTransparencySamplesProvider).valueOrNull ??
            const [];
      }

      return (
        calibrations.isEmpty ? null : calibrations.last,
        transparency.isEmpty ? null : transparency.last,
      );
    });

Future<Map<String, String>> _loadScienceSettingsMap(Ref ref) {
  ref.watch(backendProvider);
  return ref.read(_scienceSettingRowsProvider).getAllSettings();
}

/// Raw `science.*` values that are not part of [ScienceSettings], sourced
/// from the imaging host while connected remotely.
///
/// Camera sensor values and the online-catalog toggle are intentionally kept
/// as strings because that is their persisted representation and the settings
/// UI must preserve the host's exact committed text.
final scienceRawSettingsProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
      final remote = ref.watch(backendProvider).remoteHost;
      if (remote != null) {
        final settings = await remote.scienceSettingRows.getAllSettings();
        Timer? refreshTimer;
        ref.onDispose(() => refreshTimer?.cancel());
        refreshTimer = Timer(const Duration(seconds: 10), ref.invalidateSelf);
        return Map.unmodifiable(settings);
      }

      final settings = await ref.watch(allSettingsProvider.future);
      return Map.unmodifiable({
        for (final entry in settings.entries)
          if (entry.key.startsWith('science.')) entry.key: entry.value,
      });
    });

final scienceRawSettingsActionsProvider = Provider((ref) {
  final backend = ref.watch(backendProvider);
  return ScienceRawSettingsActions(
    ref,
    rows: ref.read(_scienceSettingRowsProvider),
    localCameraAutoConfig: backend.remoteHost == null
        ? ref.read(scienceCameraAutoConfigProvider)
        : null,
  );
});

/// Writes auxiliary science settings to the same authority from which the
/// corresponding action object was obtained. Capturing the backend prevents a
/// connection-mode change during an awaited UI action from redirecting the
/// second half of the write to a different database.
class ScienceRawSettingsActions {
  static const _manualCameraKeys = {
    ScienceCameraAutoConfig.readNoiseKey,
    ScienceCameraAutoConfig.gainKey,
    ScienceCameraAutoConfig.saturationKey,
  };

  final Ref _ref;
  final SettingRows _rows;
  final ScienceCameraAutoConfig? _localCameraAutoConfig;

  ScienceRawSettingsActions(
    this._ref, {
    required SettingRows rows,
    required ScienceCameraAutoConfig? localCameraAutoConfig,
  }) : _rows = rows,
       _localCameraAutoConfig = localCameraAutoConfig;

  Future<void> setOnlineCatalogEnabled(bool enabled) async {
    await _write({
      PhotometricCatalogService.onlineEnabledSettingKey: enabled.toString(),
    });
  }

  Future<void> setCameraAutoManaged(bool enabled) async {
    await _write({ScienceCameraAutoConfig.autoManagedKey: enabled.toString()});
    if (enabled && _localCameraAutoConfig != null) {
      await _localCameraAutoConfig.maybeSync(
        reason: 'auto-config re-enabled',
        force: true,
      );
      _ref.invalidate(scienceRawSettingsProvider);
    }
  }

  /// Save a manual sensor value and disable auto-management in one host/local
  /// transaction so a camera event cannot overwrite the value in between.
  Future<void> setManualCameraValue(String key, String value) async {
    if (!_manualCameraKeys.contains(key)) {
      throw ArgumentError.value(key, 'key', 'Unsupported science camera key');
    }
    await _write({key: value, ScienceCameraAutoConfig.autoManagedKey: 'false'});
  }

  Future<void> _write(Map<String, String> settings) async {
    await _rows.setSettings(settings);
    _ref.invalidate(scienceRawSettingsProvider);
  }
}

Future<void> _writeScienceSettings(
  Ref ref,
  Map<String, String> settings,
) async {
  final scope = AsyncScopes(ref.read, _scienceSettingRowsProvider).begin();
  await scope.value.setSettings(settings);
  if (scope.isStale) {
    throw StateError('The imaging host changed while saving science settings.');
  }
  ref.invalidate(scienceRawSettingsProvider);
}
