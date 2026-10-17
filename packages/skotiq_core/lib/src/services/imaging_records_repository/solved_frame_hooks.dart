part of '../imaging_records_repository.dart';

/// Invoked after a freshly solved light frame's WCS is persisted locally, so
/// Pillar A ("Your Sky") can fold that frame into the personal sky atlas. The
/// callback owns its own error handling — it must never throw back into the
/// solve-persist path. Wired by [imagingRecordsRepositoryProvider]; absent for
/// remote companions (the appliance folds on its own host side).
typedef SolvedFrameFoldHook = Future<void> Function(int capturedImageId);

/// Repository provider — local DAOs or remote host API.
///
/// The Pillar A ("Your Sky") fold-dedup gate, separate from the local
/// solve-persist hook so the production path and its test exercise the SAME
/// logic instead of a re-implementation.
///
/// Contract: fold the freshly-solved [image] into the personal sky atlas only
/// when it has not already been folded ([db.CapturedImage.atlasFoldedAt] is
/// null), and stamp the dedup marker only after a fold that actually ran
/// (a null summary means the row was not foldable — e.g. no invertible WCS —
/// so the marker stays unset and a later, better solve can still fold it).
/// Returns the fold summary, or null when skipped/not foldable.
@visibleForTesting
Future<AtlasFoldSummary?> applyAtlasFoldDedup({
  required db.CapturedImage image,
  required ImagesDao imagesDao,
  required SkyAtlasService atlas,
  required int imageWidth,
  required int imageHeight,
  SolvedWcsDistortion distortion = const SolvedWcsDistortion(),
}) async {
  if (image.atlasFoldedAt != null) return null; // already folded — dedup
  final summary = await atlas.autoFoldCapturedImage(
    image: image,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    distortion: distortion,
  );
  if (summary != null) {
    await imagesDao.stampAtlasFolded(image.id);
  }
  return summary;
}

/// Drive the live co-imaging auto-contribute for a freshly-folded light frame.
/// For every active co-imaging membership whose
/// session target this frame's solved centre covers, fold the same sub into the
/// shared-target tile and advance the COMBINED accounting via
/// [CoImagingSessionService.recordCompletedSub] (which itself fuses, then
/// reports the TRUE pushed delta, under the operator's persisted consent and
/// failing closed when none is on record).
///
/// Best-effort and self-contained: a no-hub config, no covering session, or any
/// per-session failure is logged and swallowed so it never disturbs the
/// solve/fold path. `solvedRa` is app-canonical HOURS; the matcher works in
/// degrees, so it is converted at the boundary.
Future<void> _driveCoImagingAutoContribute({
  required Ref ref,
  required LoggingService logger,
  required db.CapturedImage image,
}) async {
  if (image.frameType.toLowerCase() != 'light' || !image.isAccepted) return;
  final ra = image.solvedRa;
  final dec = image.solvedDec;
  if (ra == null || dec == null) return;
  try {
    final coImaging = ref.read(coImagingSessionServiceProvider);
    final memberships = await coImaging.membershipsForPoint(
      raDeg: ra * 15.0,
      decDeg: dec,
    );
    for (final row in memberships) {
      try {
        final accounting = await coImaging.recordCompletedSub(
          row.sessionId,
          exposureSeconds: image.exposureDuration,
        );
        if (accounting != null) {
          logger.info(
            'Co-imaging: sub folded into session ${row.sessionId}; combined '
            'now ${accounting.combinedFrames} frames across '
            '${accounting.participantCount} '
            'rig${accounting.participantCount == 1 ? '' : 's'}.',
            source: 'CoImagingSessionService',
          );
        }
      } catch (e) {
        logger.warning(
          'Co-imaging auto-contribute for session ${row.sessionId} failed: $e',
          source: 'CoImagingSessionService',
        );
      }
    }
  } catch (e) {
    logger.warning(
      'Co-imaging auto-contribute resolve failed: $e',
      source: 'CoImagingSessionService',
    );
  }
}

/// The WCS the Pillar B ("First Light") difference scan runs a solved frame
/// against.
///
/// `captured_images.solvedRa` is app-canonical **hours** on both the write side
/// (the science pipeline persists `SolvedResult.raHours`) and every other read
/// side, so the centre is carried across unconverted — it must land on the same
/// sky tiles [SkyAtlasService.autoFoldCapturedImage] folds the frame into, and
/// that builds its own centre from the identical column.
///
/// Callers guard `solvedRa`/`solvedDec`/`solvedPixelScale` before calling.
@visibleForTesting
SolvedWcs firstLightScanWcs({
  required db.CapturedImage image,
  required int imageWidth,
  required int imageHeight,
  required SolvedWcsDistortion distortion,
  DecodedSip? sip,
}) {
  return SolvedWcs(
    raHours: image.solvedRa!,
    decDegrees: image.solvedDec!,
    rotationDeg: image.solvedRotation ?? 0.0,
    pixelScaleArcsec: image.solvedPixelScale!,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    cd1_1: distortion.cd1_1,
    cd1_2: distortion.cd1_2,
    cd2_1: distortion.cd2_1,
    cd2_2: distortion.cd2_2,
    aOrder: sip?.aOrder ?? 0,
    bOrder: sip?.bOrder ?? 0,
    aCoeffs: sip?.aCoeffs ?? const [],
    bCoeffs: sip?.bCoeffs ?? const [],
    apOrder: sip?.apOrder ?? 0,
    bpOrder: sip?.bpOrder ?? 0,
    apCoeffs: sip?.apCoeffs ?? const [],
    bpCoeffs: sip?.bpCoeffs ?? const [],
  );
}

/// Run the Pillar B difference scan for a freshly-solved light frame, persist any
/// transients, and feed the survivors to the active-session Narrator so its
/// First Light detectors can announce them. Best-effort and self-contained: any
/// failure is logged and swallowed so it never disturbs the solve/fold path.
Future<void> _runFirstLightScan({
  required Ref ref,
  required LoggingService logger,
  required db.CapturedImage image,
  required int imageWidth,
  required int imageHeight,
  required SolvedWcsDistortion distortion,
}) async {
  // Only difference real light frames (a solved flat/dark would be nonsense).
  if (image.frameType.toLowerCase() != 'light') return;
  final ra = image.solvedRa;
  final dec = image.solvedDec;
  final scale = image.solvedPixelScale;
  if (ra == null || dec == null || scale == null || scale <= 0) return;

  final sip = decodeSolvedSip(
    await ref
        .read(imagesDaoProvider)
        .getStoredWcsDistortion(image.id)
        .then((w) => w?.sip),
  );
  final wcs = firstLightScanWcs(
    image: image,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    distortion: distortion,
    sip: sip,
  );
  if (!wcs.isValid) return;

  try {
    final rows = await ref
        .read(firstLightServiceProvider)
        .scanFrame(
          framePath: image.filePath,
          wcs: wcs,
          sessionId: image.sessionId,
          capturedImageId: image.id,
        );
    if (rows.isEmpty) return;
    // Feed the freshly-detected transients to the active Narrator so the First
    // Light detectors (transient/brightening/mover) can announce them.
    final candidates = rows.map(_candidateFromRow).toList(growable: false);
    ref
        .read(narratorServiceProvider)
        .ingestTransientCandidates(candidates, capturedImageId: image.id);
    // Bridge a genuinely-new discovery to the push router so a sleeping
    // operator is paged while the chase window is still open. The in-app
    // Narrator banner alone is invisible at night.
    _pushTransientDiscoveries(ref, logger, rows);
  } catch (e, st) {
    logger.warning(
      'First Light scan for image ${image.id} failed: $e\n$st',
      source: 'FirstLightService',
    );
  }
}

/// Minimum confidence for a transient to escalate to a phone push. High enough
/// that the operator is only paged for a genuinely promising candidate (the
/// chase costs telescope time), not every marginal residual.
const double _kTransientPushConfidence = 0.7;

/// Route any high-confidence, unnamed, brand-new point source from a scan to the
/// notification router so it pushes to the operator's phone (the
/// `transientDiscovered` category is critical / systemPush-by-default). Only a
/// `newSource` with no catalog match qualifies as a possible-discovery worth a
/// page; a brightening of a known star, a mover, or a dipole artefact stays
/// in-app. Best-effort — a router failure must never disturb the solve path.
void _pushTransientDiscoveries(
  Ref ref,
  LoggingService logger,
  List<db.TransientDetectionRow> rows,
) {
  final discoveries = rows
      .where((r) {
        if (r.catalogMatch != null) return false;
        if (r.confidence < _kTransientPushConfidence) return false;
        return TransientKind.fromWire(r.kind) == TransientKind.newSource;
      })
      .toList(growable: false);
  if (discoveries.isEmpty) return;

  try {
    final router = ref.read(notificationRouterProvider);
    for (final r in discoveries) {
      final coords =
          '${CoordinateFormat.ra(r.raDeg / 15.0)} ${CoordinateFormat.dec(r.decDeg)}';
      router.route(NotificationCategory.transientDiscovered, {
        'transient.coords': coords,
        'transient.snr': r.snr.toStringAsFixed(1),
        'transient.confidence': (r.confidence * 100).round().toString(),
      }, severity: EventSeverity.critical);
    }
  } catch (e, st) {
    logger.warning(
      'First Light push routing failed: $e\n$st',
      source: 'FirstLightService',
    );
  }
}

/// Reconstruct a [TransientCandidate] from a persisted detection row for the
/// Narrator feed. The tile pixel coordinates are not stored on the row (they are
/// a native-only intermediate), so they default to 0 — the detectors only read
/// sky position, SNR, deltaMag, kind, confidence, and eccentricity.
TransientCandidate _candidateFromRow(db.TransientDetectionRow row) {
  return TransientCandidate(
    ra: row.raDeg,
    dec: row.decDeg,
    tileId: row.tileId,
    tileX: 0,
    tileY: 0,
    residualFlux: row.residualFlux,
    deltaMag: row.deltaMag,
    snr: row.snr,
    fwhm: row.fwhm,
    eccentricity: row.eccentricity,
    positionAngleDeg: row.positionAngleDeg,
    kind: TransientKind.fromWire(row.kind),
    catalogMatch: row.catalogMatch,
    confidence: row.confidence,
  );
}
