import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart'
    show PsfFieldTileRow, AstrometryResidualVectorRow;
import '../services/optical_train_diagnostics_service.dart';
import 'science_provider.dart'
    show
        sessionPsfTilesProvider,
        sessionResidualVectorsProvider,
        sessionlessPsfTilesProvider,
        sessionlessResidualVectorsProvider;

/// Service provider for OpticalTrainDiagnosticsService.
final opticalTrainDiagnosticsServiceProvider =
    Provider<OpticalTrainDiagnosticsService>((ref) {
      return const OpticalTrainDiagnosticsService();
    });

// These forward the source AsyncValue rather than re-wrapping the source's
// `.stream`. `.stream` replays nothing: it only forwards events emitted AFTER
// the listener attaches. If anything else in the app (the Science tab) had
// already subscribed to sessionPsfTilesProvider(id) and the query had emitted
// its one value, the re-wrapped provider never received it and stayed
// `isLoading` forever — so Diagnostics showed skeletons indefinitely for
// exactly the session the operator had just been looking at, and only that one.

/// Reactive PSF field tiles for a given session.
final psfTilesForSessionProvider = Provider.autoDispose
    .family<AsyncValue<List<PsfFieldTileRow>>, int>(
      (ref, sessionId) => ref.watch(sessionPsfTilesProvider(sessionId)),
    );

/// Reactive astrometry residual vectors for a given session.
final residualVectorsForSessionProvider = Provider.autoDispose
    .family<AsyncValue<List<AstrometryResidualVectorRow>>, int>(
      (ref, sessionId) => ref.watch(sessionResidualVectorsProvider(sessionId)),
    );

/// Reactive optical train diagnostics for a given session.
///
/// Watches PSF field tiles and astrometry residual vectors from the science
/// DAO and feeds them into the diagnostics service. Pass the session ID as
/// the family parameter.
final opticalTrainDiagnosticsProvider = Provider.autoDispose
    .family<AsyncValue<OpticalTrainDiagnostics>, int>((ref, sessionId) {
      final psfAsync = ref.watch(psfTilesForSessionProvider(sessionId));
      final residualsAsync = ref.watch(
        residualVectorsForSessionProvider(sessionId),
      );
      final service = ref.watch(opticalTrainDiagnosticsServiceProvider);

      if (psfAsync.hasError) {
        return AsyncValue.error(
          psfAsync.error!,
          psfAsync.stackTrace ?? StackTrace.current,
        );
      }
      if (residualsAsync.hasError) {
        return AsyncValue.error(
          residualsAsync.error!,
          residualsAsync.stackTrace ?? StackTrace.current,
        );
      }
      if (psfAsync.isLoading || residualsAsync.isLoading) {
        return const AsyncValue.loading();
      }

      return AsyncValue.data(
        service.analyze(
          psfTiles: psfAsync.value ?? const [],
          residualVectors: residualsAsync.value ?? const [],
        ),
      );
    });

/// Memoized optical-train diagnostics derived from the *latest captured-image
/// snapshot* of PSF tiles and residual vectors. Used by the science analytics
/// tab, where an unmemoized read re-runs `analyze()` on every Riverpod frame.
/// Pass the active session ID, or `null` for sessionless / quick-capture mode
/// — the provider switches sources accordingly.
final latestSnapshotOpticalTrainDiagnosticsProvider = Provider.autoDispose
    .family<OpticalTrainDiagnostics, int?>((ref, sessionId) {
      final psfTiles = sessionId != null
          ? ref.watch(sessionPsfTilesProvider(sessionId)).valueOrNull ??
                const []
          : ref.watch(sessionlessPsfTilesProvider).valueOrNull ?? const [];
      final residuals = sessionId != null
          ? ref.watch(sessionResidualVectorsProvider(sessionId)).valueOrNull ??
                const []
          : ref.watch(sessionlessResidualVectorsProvider).valueOrNull ??
                const [];

      // Snapshot to the latest captured-image worth of tiles/vectors so the
      // diagnostics reflect "this exposure" rather than averaging across the
      // session. Matches the snapshot rendered by the PSF heatmap and residual
      // cards above the diagnostics block.
      final latestPsf = _latestPsfSnapshot(psfTiles);
      final latestResiduals = _latestResidualSnapshot(residuals);

      final service = ref.watch(opticalTrainDiagnosticsServiceProvider);
      return service.analyze(
        psfTiles: latestPsf,
        residualVectors: latestResiduals,
      );
    });

List<PsfFieldTileRow> _latestPsfSnapshot(List<PsfFieldTileRow> rows) {
  if (rows.isEmpty) {
    return const [];
  }
  int? latestId;
  DateTime latestTime = DateTime.fromMillisecondsSinceEpoch(0);
  for (final row in rows) {
    if (row.capturedImageId == null) {
      continue;
    }
    if (row.timestamp.isAfter(latestTime)) {
      latestTime = row.timestamp;
      latestId = row.capturedImageId;
    }
  }
  if (latestId == null) {
    return rows;
  }
  return rows
      .where((row) => row.capturedImageId == latestId)
      .toList(growable: false);
}

List<AstrometryResidualVectorRow> _latestResidualSnapshot(
  List<AstrometryResidualVectorRow> rows,
) {
  if (rows.isEmpty) {
    return const [];
  }
  int? latestId;
  DateTime latestTime = DateTime.fromMillisecondsSinceEpoch(0);
  for (final row in rows) {
    if (row.capturedImageId == null) {
      continue;
    }
    if (row.timestamp.isAfter(latestTime)) {
      latestTime = row.timestamp;
      latestId = row.capturedImageId;
    }
  }
  if (latestId == null) {
    return rows;
  }
  return rows
      .where((row) => row.capturedImageId == latestId)
      .toList(growable: false);
}
