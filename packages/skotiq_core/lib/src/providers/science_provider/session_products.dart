part of '../science_provider.dart';

class ScienceSessionConfigController {
  final Ref _ref;

  ScienceSessionConfigController(this._ref);

  Future<void> save(int sessionId, ScienceSessionConfig config) async {
    final backend = _ref.read(backendProvider);
    final resolved = config.copyWith(sessionId: sessionId);
    if (backend is NetworkBackend) {
      await backend.updateScienceSessionConfig(sessionId, resolved);
      if (!identical(_ref.read(backendProvider), backend)) {
        throw StateError(
          'The imaging host changed while saving the science session.',
        );
      }
      return;
    }
    final dao = _ref.read(scienceDaoProvider);
    await dao.upsertSessionConfig(resolved);
    if (!identical(_ref.read(backendProvider), backend) ||
        !identical(_ref.read(scienceDaoProvider), dao)) {
      throw StateError(
        'The imaging host changed while saving the science session.',
      );
    }
  }
}

final scienceSessionConfigControllerProvider =
    Provider<ScienceSessionConfigController>((ref) {
      return ScienceSessionConfigController(ref);
    });

final scienceSessionConfigProvider =
    StreamProvider.family<ScienceSessionConfig?, int>((ref, sessionId) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _pollRemoteScienceSessionConfig(
          backend,
          sessionId,
          interval: ref.watch(remoteSciencePollIntervalProvider),
        );
      }
      return ref.watch(scienceDaoProvider).watchSessionConfig(sessionId).map((
        row,
      ) {
        if (row == null) {
          return null;
        }
        return ScienceSessionConfig(
          sessionId: row.sessionId,
          photometryEnabled: row.photometryEnabled,
          calibrationEnabled: row.calibrationEnabled,
          transparencyEnabled: row.transparencyEnabled,
          psfMapEnabled: row.psfMapEnabled,
          residualsEnabled: row.residualsEnabled,
          movingObjectsEnabled: row.movingObjectsEnabled,
          narrowbandEnabled: row.narrowbandEnabled,
          psfGridRows: row.psfGridRows,
          psfGridCols: row.psfGridCols,
          transparencyAlertThreshold: row.transparencyAlertThreshold,
        );
      });
    });

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

final _remoteScienceSessionBundleProvider =
    StreamProvider.family<RemoteScienceBundle, int>((ref, sessionId) {
      final backend = ref.watch(backendProvider);
      if (backend is! NetworkBackend) {
        throw StateError('Remote science bundle requested in local mode');
      }
      return _pollRemoteScienceBundle(
        () => backend.getScienceSessionBundle(sessionId),
        _scienceBundlesEqual,
        interval: ref.watch(remoteSciencePollIntervalProvider),
      );
    });

final _remoteSessionlessScienceBundleProvider =
    StreamProvider<RemoteScienceBundle>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is! NetworkBackend) {
        throw StateError(
          'Remote sessionless science bundle requested in local mode',
        );
      }
      return _pollRemoteScienceBundle(
        backend.getSessionlessScienceBundle,
        _scienceBundlesEqual,
        interval: ref.watch(remoteSciencePollIntervalProvider),
      );
    });

Stream<T> _remoteScienceSlice<T>(
  Ref ref,
  StreamProvider<RemoteScienceBundle> provider,
  T Function(RemoteScienceBundle bundle) select,
) {
  // Riverpod 2.x exposes no other lossless way to derive a StreamProvider
  // from a shared StreamProvider without replaying the first value twice.
  // ignore: deprecated_member_use
  return ref.watch(provider.stream).map(select);
}

final sessionPhotometryProvider =
    StreamProvider.family<List<PhotometryMeasurementRow>, int>((
      ref,
      sessionId,
    ) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteScienceSessionBundleProvider(sessionId),
          (bundle) => bundle.photometry,
        );
      }
      return ref.watch(scienceDaoProvider).watchPhotometryForSession(sessionId);
    });

final sessionFrameCalibrationsProvider =
    StreamProvider.family<List<FramePhotometricCalibrationRow>, int>((
      ref,
      sessionId,
    ) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteScienceSessionBundleProvider(sessionId),
          (bundle) => bundle.calibrations,
        );
      }
      return ref
          .watch(scienceDaoProvider)
          .watchCalibrationsForSession(sessionId);
    });

final sessionTransparencySamplesProvider =
    StreamProvider.family<List<TransparencySampleRow>, int>((ref, sessionId) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteScienceSessionBundleProvider(sessionId),
          (bundle) => bundle.transparency,
        );
      }
      return ref
          .watch(scienceDaoProvider)
          .watchTransparencyForSession(sessionId);
    });

final sessionPsfTilesProvider =
    StreamProvider.family<List<PsfFieldTileRow>, int>((ref, sessionId) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteScienceSessionBundleProvider(sessionId),
          (bundle) => bundle.psfTiles,
        );
      }
      return ref.watch(scienceDaoProvider).watchPsfTilesForSession(sessionId);
    });

final sessionFrameQualityMetricsProvider =
    StreamProvider.family<List<ScienceFrameQualityMetricsRow>, int>((
      ref,
      sessionId,
    ) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteScienceSessionBundleProvider(sessionId),
          (bundle) => bundle.frameQuality,
        );
      }
      return ref
          .watch(scienceDaoProvider)
          .watchFrameQualityMetricsForSession(sessionId);
    });

final sessionTileMetricsProvider =
    StreamProvider.family<List<ScienceTileMetricRow>, int>((ref, sessionId) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteScienceSessionBundleProvider(sessionId),
          (bundle) => bundle.tileMetrics,
        );
      }
      return ref
          .watch(scienceDaoProvider)
          .watchTileMetricsForSession(sessionId);
    });

final sessionResidualVectorsProvider =
    StreamProvider.family<List<AstrometryResidualVectorRow>, int>((
      ref,
      sessionId,
    ) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteScienceSessionBundleProvider(sessionId),
          (bundle) => bundle.residuals,
        );
      }
      return ref.watch(scienceDaoProvider).watchResidualsForSession(sessionId);
    });

final sessionMovingObjectCandidatesProvider =
    StreamProvider.family<List<MovingObjectCandidateRow>, int>((
      ref,
      sessionId,
    ) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteScienceSessionBundleProvider(sessionId),
          (bundle) => bundle.movingObjects,
        );
      }
      return ref
          .watch(scienceDaoProvider)
          .watchMovingObjectsForSession(sessionId);
    });

final sessionLineRatioProductsProvider =
    StreamProvider.family<List<LineRatioProductRow>, int>((ref, sessionId) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteScienceSessionBundleProvider(sessionId),
          (bundle) => bundle.lineRatios,
        );
      }
      return ref.watch(scienceDaoProvider).watchLineRatiosForSession(sessionId);
    });

/// Light curve for one object across EVERY session that imaged a target.
///
/// The per-session curve cannot support a period search: a night is a few
/// hours and the periods people look for are usually longer, so a single-night
/// periodogram can only ever return its own baseline. Local backend only —
/// remote rigs have no equivalent bundle, and return empty rather than a
/// silently truncated curve.
final targetLightCurveProvider =
    StreamProvider.family<
      List<LightCurvePoint>,
      (int targetId, String objectId)
    >((ref, args) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return Stream.value(const <LightCurvePoint>[]);
      }
      return ref
          .watch(scienceDaoProvider)
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
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteSessionlessScienceBundleProvider,
          (bundle) => bundle.calibrations,
        );
      }
      return ref.watch(scienceDaoProvider).watchSessionlessCalibrationsRecent();
    });

final sessionlessTransparencySamplesProvider =
    StreamProvider<List<TransparencySampleRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteSessionlessScienceBundleProvider,
          (bundle) => bundle.transparency,
        );
      }
      return ref.watch(scienceDaoProvider).watchSessionlessTransparencyRecent();
    });

final sessionlessPsfTilesProvider = StreamProvider<List<PsfFieldTileRow>>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _remoteScienceSlice(
      ref,
      _remoteSessionlessScienceBundleProvider,
      (bundle) => bundle.psfTiles,
    );
  }
  return ref.watch(scienceDaoProvider).watchSessionlessPsfTilesRecent();
});

final sessionlessFrameQualityMetricsProvider =
    StreamProvider<List<ScienceFrameQualityMetricsRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteSessionlessScienceBundleProvider,
          (bundle) => bundle.frameQuality,
        );
      }
      return ref
          .watch(scienceDaoProvider)
          .watchSessionlessFrameQualityMetricsRecent();
    });

final sessionlessTileMetricsProvider =
    StreamProvider<List<ScienceTileMetricRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteSessionlessScienceBundleProvider,
          (bundle) => bundle.tileMetrics,
        );
      }
      return ref.watch(scienceDaoProvider).watchSessionlessTileMetricsRecent();
    });

final sessionlessResidualVectorsProvider =
    StreamProvider<List<AstrometryResidualVectorRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteSessionlessScienceBundleProvider,
          (bundle) => bundle.residuals,
        );
      }
      return ref.watch(scienceDaoProvider).watchSessionlessResidualsRecent();
    });

final sessionlessMovingObjectCandidatesProvider =
    StreamProvider<List<MovingObjectCandidateRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteSessionlessScienceBundleProvider,
          (bundle) => bundle.movingObjects,
        );
      }
      return ref
          .watch(scienceDaoProvider)
          .watchSessionlessMovingObjectsRecent();
    });

final sessionlessPhotometryProvider =
    StreamProvider<List<PhotometryMeasurementRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteSessionlessScienceBundleProvider,
          (bundle) => bundle.photometry,
        );
      }
      return ref.watch(scienceDaoProvider).watchSessionlessPhotometryRecent();
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
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return ref.watch(sessionlessPhotometryProvider.future);
      }
      return ref.watch(scienceDaoProvider).getAllSessionlessPhotometry();
    });

final sessionlessFrameQualityMetricsExportProvider =
    FutureProvider<List<ScienceFrameQualityMetricsRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return ref.watch(sessionlessFrameQualityMetricsProvider.future);
      }
      return ref
          .watch(scienceDaoProvider)
          .getAllSessionlessFrameQualityMetrics();
    });

final sessionlessTransparencySamplesExportProvider =
    FutureProvider<List<TransparencySampleRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return ref.watch(sessionlessTransparencySamplesProvider.future);
      }
      return ref.watch(scienceDaoProvider).getAllSessionlessTransparency();
    });

final sessionlessPsfTilesExportProvider = FutureProvider<List<PsfFieldTileRow>>(
  (ref) {
    final backend = ref.watch(backendProvider);
    if (backend is NetworkBackend) {
      return ref.watch(sessionlessPsfTilesProvider.future);
    }
    return ref.watch(scienceDaoProvider).getAllSessionlessPsfTiles();
  },
);

final sessionlessResidualVectorsExportProvider =
    FutureProvider<List<AstrometryResidualVectorRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return ref.watch(sessionlessResidualVectorsProvider.future);
      }
      return ref.watch(scienceDaoProvider).getAllSessionlessResiduals();
    });

final sessionlessCalibrationsExportProvider =
    FutureProvider<List<FramePhotometricCalibrationRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return ref.watch(sessionlessCalibrationsProvider.future);
      }
      return ref.watch(scienceDaoProvider).getAllSessionlessCalibrations();
    });

final sessionlessMovingObjectCandidatesExportProvider =
    FutureProvider<List<MovingObjectCandidateRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return ref.watch(sessionlessMovingObjectCandidatesProvider.future);
      }
      return ref.watch(scienceDaoProvider).getAllSessionlessMovingObjects();
    });

final sessionlessLineRatioProductsProvider =
    StreamProvider<List<LineRatioProductRow>>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteScienceSlice(
          ref,
          _remoteSessionlessScienceBundleProvider,
          (bundle) => bundle.lineRatios,
        );
      }
      return ref.watch(scienceDaoProvider).watchSessionlessLineRatiosRecent();
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

Future<Map<String, String>> _loadScienceSettingsMap(Ref ref) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return backend.getScienceSettings();
  }
  return ref.read(settingsDaoProvider).getAllSettings();
}

/// Raw `science.*` values that are not part of [ScienceSettings], sourced
/// from the imaging host while connected remotely.
///
/// Camera sensor values and the online-catalog toggle are intentionally kept
/// as strings because that is their persisted representation and the settings
/// UI must preserve the host's exact committed text.
final scienceRawSettingsProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        final settings = await backend.getScienceSettings();
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
    remote: backend is NetworkBackend ? backend : null,
    localSettings: backend is NetworkBackend
        ? null
        : ref.read(settingsDaoProvider),
    localCameraAutoConfig: backend is NetworkBackend
        ? null
        : ref.read(scienceCameraAutoConfigProvider),
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
  final NetworkBackend? _remote;
  final SettingsDao? _localSettings;
  final ScienceCameraAutoConfig? _localCameraAutoConfig;

  ScienceRawSettingsActions(
    this._ref, {
    required NetworkBackend? remote,
    required SettingsDao? localSettings,
    required ScienceCameraAutoConfig? localCameraAutoConfig,
  }) : _remote = remote,
       _localSettings = localSettings,
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
    if (_remote != null) {
      await _remote.updateScienceSettings(settings);
    } else {
      await _localSettings!.setSettings(settings);
    }
    _ref.invalidate(scienceRawSettingsProvider);
  }
}

Future<void> _writeScienceSettings(
  Ref ref,
  Map<String, String> settings,
) async {
  final backend = ref.read(backendProvider);
  if (backend is NetworkBackend) {
    await backend.updateScienceSettings(settings);
    if (!identical(ref.read(backendProvider), backend)) {
      throw StateError(
        'The imaging host changed while saving science settings.',
      );
    }
    ref.invalidate(scienceRawSettingsProvider);
    return;
  }
  final dao = ref.read(settingsDaoProvider);
  await dao.setSettings(settings);
  if (!identical(ref.read(backendProvider), backend) ||
      !identical(ref.read(settingsDaoProvider), dao)) {
    throw StateError('The imaging host changed while saving science settings.');
  }
  ref.invalidate(scienceRawSettingsProvider);
}

Stream<ScienceSessionConfig?> _pollRemoteScienceSessionConfig(
  NetworkBackend backend,
  int sessionId, {
  required Duration interval,
}) => _pollRemoteScienceBundle(
  () => backend.getScienceSessionConfig(sessionId),
  _scienceSessionConfigsEqual,
  interval: interval,
);

Stream<T> _pollRemoteScienceBundle<T>(
  Future<T> Function() fetch,
  bool Function(T previous, T next) unchanged, {
  required Duration interval,
}) => resilientDistinctPoll(
  fetch: fetch,
  unchanged: unchanged,
  interval: interval,
  onRetainedError: (error, stackTrace) {
    developer.log(
      'Remote science poll failed; retaining last value',
      name: 'ScienceProvider',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  },
);

bool _scienceBundlesEqual(
  RemoteScienceBundle previous,
  RemoteScienceBundle next,
) =>
    listEquals(previous.photometry, next.photometry) &&
    listEquals(previous.calibrations, next.calibrations) &&
    listEquals(previous.transparency, next.transparency) &&
    listEquals(previous.psfTiles, next.psfTiles) &&
    listEquals(previous.frameQuality, next.frameQuality) &&
    listEquals(previous.tileMetrics, next.tileMetrics) &&
    listEquals(previous.residuals, next.residuals) &&
    listEquals(previous.movingObjects, next.movingObjects) &&
    listEquals(previous.lineRatios, next.lineRatios);

bool _scienceSessionConfigsEqual(
  ScienceSessionConfig? previous,
  ScienceSessionConfig? next,
) {
  if (previous == null || next == null) {
    return previous == next;
  }
  return mapEquals(previous.toJson(), next.toJson());
}
