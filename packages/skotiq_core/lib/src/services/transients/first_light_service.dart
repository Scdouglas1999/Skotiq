import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import '../../database/daos/living_sky_retention_dao.dart';
import '../../database/daos/transient_detections_dao.dart';
import '../../database/database.dart';
import '../../database/tables/living_sky_retention.dart';
import '../../services/sky_atlas/sky_atlas_models.dart';
import '../../services/wcs/gnomonic_projection.dart';
import '../logging_service.dart';
import '../science/photometric_catalog_service.dart';
import 'difference_image_seam.dart';
import 'transient_candidate.dart';

/// On-disk directory the per-detection real-pixel crop stamps are written into,
/// derived from the atlas root. One shared dir (not per-session) so a crop is
/// addressable from the persisted detection row alone (tile id + position), which
/// is all the `/api/firstlight/<id>/crops` endpoint has to work with.
String firstLightCropDir(String atlasRoot) =>
    p.join(atlasRoot, 'firstlight_crops');

/// Deterministic crop-stamp filename for a detection at (`raDeg`, `decDeg`) on
/// [tileId], for [stage] (`template` | `science` | `residual`). Mirrors the
/// native `crop_basename` exactly (tile id + sky position quantized to
/// micro-degrees) so the bytes the bridge wrote are the bytes the UI/endpoint
/// reads back.
String firstLightCropName({
  required int tileId,
  required double raDeg,
  required double decDeg,
  required String stage,
}) {
  final raU = (raDeg * 1000000.0).round();
  final decU = (decDeg * 1000000.0).round();
  return 'crop_${tileId}_${raU}_${decU}_$stage.png';
}

/// How much of a frame's footprint the atlas was deep enough to actually
/// difference, decoded from the native difference envelope. Distinguishes a
/// genuinely clean-sky result (tiles checked, nothing found) from a thin-atlas
/// no-op (every covered tile too thin / not folded into yet) so the UI can say
/// "atlas not deep enough here yet" rather than silently reading as broken.
class FirstLightCoverage {
  const FirstLightCoverage({
    required this.tilesChecked,
    required this.tilesSkippedThin,
    required this.tilesNoTemplate,
  });

  /// Tiles whose template was deep enough and were differenced.
  final int tilesChecked;

  /// Tiles the frame covered but whose template was thinner than the depth gate.
  final int tilesSkippedThin;

  /// Tiles the frame footprint covered but which have not been folded into yet.
  final int tilesNoTemplate;

  /// Every tile the frame footprint touched (deep, thin, or empty).
  int get tilesCovered => tilesChecked + tilesSkippedThin + tilesNoTemplate;

  /// True when the frame covered sky but not one tile was deep enough to scan —
  /// the "atlas not deep enough here yet" condition.
  bool get isAtlasTooThin => tilesChecked == 0 && tilesCovered > 0;

  static int _len(Object? v) => v is List ? v.length : 0;

  /// Decode from the `{ tilesChecked, tilesSkippedThin, tilesNoTemplate }` lists
  /// the native difference envelope carries (each is a list of tile ids).
  factory FirstLightCoverage.fromBridgeJson(Map<String, dynamic> json) {
    return FirstLightCoverage(
      tilesChecked: _len(json['tilesChecked']),
      tilesSkippedThin: _len(json['tilesSkippedThin']),
      tilesNoTemplate: _len(json['tilesNoTemplate']),
    );
  }

  static const empty = FirstLightCoverage(
    tilesChecked: 0,
    tilesSkippedThin: 0,
    tilesNoTemplate: 0,
  );
}

/// Narrow seam over the photometric catalog cone search the cross-match needs.
///
/// Decouples [FirstLightService] from the concrete [PhotometricCatalogService]
/// (which needs a `Ref` + network/DB) so the service body runs in a unit test
/// against a canned star list. [PhotometricCatalogMatcher] is the production
/// adapter.
abstract class TransientCatalogMatcher {
  /// Catalog stars within [radiusDegrees] of the position.
  Future<List<PhotometricCatalogStar>> coneStars({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    double maxMagnitude = 18.0,
  });
}

/// Production [TransientCatalogMatcher] backed by [PhotometricCatalogService].
class PhotometricCatalogMatcher implements TransientCatalogMatcher {
  PhotometricCatalogMatcher(this._catalog);

  final PhotometricCatalogService _catalog;

  @override
  Future<List<PhotometricCatalogStar>> coneStars({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    double maxMagnitude = 18.0,
  }) async {
    final result = await _catalog.coneSearch(
      raDegrees: raDegrees,
      decDegrees: decDegrees,
      radiusDegrees: radiusDegrees,
      maxMagnitude: maxMagnitude,
    );
    return result.stars;
  }
}

/// Pillar B ("First Light") — difference one fresh frame against the deep atlas
/// template, name what changed, and log the survivors.
///
/// [scanFrame] is the whole vertical slice:
///   1. Build the `<SipWcs JSON>` from the frame's [SolvedWcs] and call the
///      native `api_difference_image` surface
///      (`docs/skotiq_5_0_contracts.md`) through the injectable
///      [DifferenceImageSeam].
///   2. Cross-match every residual against the photometric catalog at its sky
///      position — a coincident catalog star names the source and marks the
///      residual a *brightening of a known object*; no match on a clean point
///      source is the headline *possible unknown transient*. This fills
///      `catalogMatch` / `confidence` / refines `kind` before anything persists.
///   3. Suppress residuals that fall on a position a human has already dismissed
///      as an artefact (so the same hot pixel / registration dipole is not
///      re-announced every clear night).
///   4. Persist the survivors to [TransientDetections] and return the rows.
///
/// The service never throws on a "nothing found" outcome — an empty result is a
/// legitimate clean-sky night. It only surfaces a real error (unreadable frame,
/// degenerate WCS, native failure) from the seam.
class FirstLightService {
  FirstLightService({
    required TransientDetectionsDao dao,
    required DifferenceImageSeam seam,
    required TransientCatalogMatcher catalog,
    required LoggingService logger,
    required Future<String> Function() atlasRootResolver,
    LivingSkyRetentionDao? retention,
    void Function(FirstLightCoverage coverage)? onCoverage,
    int order = 9,
  }) : _dao = dao,
       _seam = seam,
       _catalog = catalog,
       _logger = logger,
       _atlasRootResolver = atlasRootResolver,
       _retention = retention,
       _onCoverage = onCoverage,
       _order = order;

  final TransientDetectionsDao _dao;
  final DifferenceImageSeam _seam;
  final TransientCatalogMatcher _catalog;
  final LoggingService _logger;
  final Future<String> Function() _atlasRootResolver;
  final LivingSkyRetentionDao? _retention;

  /// Published the latest scan's coverage envelope (deep / thin / empty tile
  /// counts) so a surface can show "atlas not deep enough here yet" rather than a
  /// thin-atlas no-op being indistinguishable from a clean sky.
  final void Function(FirstLightCoverage coverage)? _onCoverage;

  final int _order;

  /// Default retention horizon: triaged-artefact transient history older than
  /// this is reclaimable by [pruneOldDetections]. Long enough that a season's
  /// worth of dismissals stays available for review; short enough that the
  /// append-only log does not grow without bound on a constrained appliance.
  static const Duration defaultRetentionHorizon = Duration(days: 120);

  static const _logSource = 'FirstLightService';

  /// Positional radius (arcsec) within which a residual is considered the same
  /// source as a catalog star, or the same source as a previously-dismissed
  /// detection. ~APASS/typical-seeing centroid agreement.
  static const _matchRadiusArcsec = 5.0;

  /// J2000 reference epoch (decimal year) of the APASS catalog positions. The
  /// catalog cone search returns fixed RAJ2000/DEJ2000 with no proper-motion
  /// columns, so a star that has moved since J2000 will not sit at its catalog
  /// position today.
  static const _catalogEpochYear = 2000.0;

  /// Worst-case proper motion (arcsec/yr) the match radius is widened to bound,
  /// so a high-PM star is still *associated* with its catalog entry (and thus not
  /// mis-announced as a brand-new transient) rather than missed entirely. Bounds
  /// the great majority of nearby stars; the rare hyper-PM star (Barnard's) is
  /// surfaced with the epoch caveat below.
  static const _maxProperMotionArcsecPerYear = 10.0;

  /// Residuals fainter than this SNR never persist — below it the difference is
  /// dominated by subtraction noise.
  static const _minSnr = 5.0;

  String? _cachedAtlasRoot;

  /// The on-disk atlas root, resolved (and the directory created) lazily once.
  Future<String> _atlasRoot() async {
    final cached = _cachedAtlasRoot;
    if (cached != null) return cached;
    final root = await _atlasRootResolver();
    _cachedAtlasRoot = root;
    return root;
  }

  /// Difference [framePath] (solved to [wcs]) against the atlas, cross-match,
  /// suppress dismissed positions, persist, and return the new rows
  /// (newest-first, already filtered to the persisted survivors).
  Future<List<TransientDetectionRow>> scanFrame({
    required String framePath,
    required SolvedWcs wcs,
    int? sessionId,
    int? capturedImageId,
    int minTemplateCoverage = 5,
  }) async {
    if (!wcs.isValid) {
      throw ArgumentError.value(
        wcs,
        'wcs',
        'scanFrame needs a valid SolvedWcs (finite centre + positive scale)',
      );
    }

    final atlasRoot = await _atlasRoot();
    // Reuse the atlas SipWcs-JSON builder so the difference call sees the exact
    // CD + SIP geometry the fold path uses (CD reconstructed from scale+rotation
    // when the solve carried no matrix).
    final frameRef = SolvedFrameRef.fromSolvedWcs(
      framePath: framePath,
      wcs: wcs,
    );
    if (!frameRef.hasInvertibleWcs) {
      throw ArgumentError.value(
        wcs,
        'wcs',
        'scanFrame needs an invertible CD matrix',
      );
    }

    final args = <String, dynamic>{
      'atlasRoot': atlasRoot,
      'order': _order,
      'framePath': framePath,
      'wcs': frameRef.toWcsJson(),
      'interp': AtlasInterp.lanczos3.wire,
      'minTemplateCoverage': minTemplateCoverage,
      // Pass the SNR floor + cross-tile dedup/match radius explicitly so Dart and
      // native share one source of truth (no silent-drift between the two 5.0s).
      'minSnr': _minSnr,
      // Write real-pixel template/science/residual postage stamps per detection
      // into a stable cache dir, named deterministically by tile id + position so
      // the UI (and the /api/firstlight/<id>/crops endpoint) resolve them from the
      // persisted row alone — replacing the schematic cutout strip with real
      // pixels.
      'cropOutDir': firstLightCropDir(atlasRoot),
    };

    final result = await _seam.difference(args);
    final rawCandidates = (result['candidates'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TransientCandidate.fromBridgeJson)
        .where((c) => c.snr >= _minSnr)
        .toList(growable: false);

    // Coverage envelope: how much of the frame's footprint the atlas was actually
    // deep enough to difference. A thin-atlas no-op (every covered tile too thin /
    // no template yet) is otherwise indistinguishable from a genuinely clean sky;
    // logging + surfacing it lets the UI say "atlas not deep enough here yet"
    // instead of silently reading as broken.
    final coverage = FirstLightCoverage.fromBridgeJson(result);
    _onCoverage?.call(coverage);
    if (rawCandidates.isEmpty) {
      if (coverage.tilesChecked == 0 && coverage.tilesCovered > 0) {
        _logger.info(
          'First Light scan: atlas not deep enough here yet for $framePath — '
          '${coverage.tilesSkippedThin} '
          'tile${coverage.tilesSkippedThin == 1 ? '' : 's'} below the '
          '$minTemplateCoverage-frame depth gate, '
          '${coverage.tilesNoTemplate} not folded into yet '
          '(0 of ${coverage.tilesCovered} deep enough)',
          source: _logSource,
        );
      } else {
        _logger.debug(
          'First Light scan: no residuals above SNR $_minSnr for $framePath '
          '(${coverage.tilesChecked} '
          'tile${coverage.tilesChecked == 1 ? '' : 's'} checked)',
          source: _logSource,
        );
      }
      return const [];
    }

    // Drop residuals that coincide with a previously-dismissed detection. Only
    // the dismissed rows on the handful of tiles this frame actually produced a
    // residual on can match, so seek those by tile (index-backed) instead of
    // full-scanning the all-time dismissed set on every frame.
    final candidateTiles = rawCandidates.map((c) => c.tileId).toSet();
    final dismissed = await _dao.dismissedDetectionsForTiles(candidateTiles);
    final surviving = rawCandidates
        .where((c) => !_isDismissed(c, dismissed))
        .toList(growable: false);

    if (surviving.isEmpty) {
      _logger.debug(
        'First Light scan: all ${rawCandidates.length} residuals matched a '
        'dismissed position for $framePath',
        source: _logSource,
      );
      return const [];
    }

    // Cross-match each survivor against the photometric catalog at its position.
    final matched = <TransientCandidate>[];
    for (final candidate in surviving) {
      matched.add(await _crossMatch(candidate));
    }

    final companions = matched
        .map(
          (c) => TransientDetectionsCompanion.insert(
            tileId: c.tileId,
            raDeg: c.ra,
            decDeg: c.dec,
            residualFlux: c.residualFlux,
            snr: c.snr,
            fwhm: c.fwhm,
            eccentricity: c.eccentricity,
            positionAngleDeg: Value(c.positionAngleDeg),
            kind: c.kind.wire,
            confidence: c.confidence,
            sessionId: Value(sessionId),
            capturedImageId: Value(capturedImageId),
            deltaMag: Value(c.deltaMag),
            catalogMatch: Value(c.catalogMatch),
          ),
        )
        .toList(growable: false);

    await _dao.insertDetections(companions);

    _logger.info(
      'First Light scan: persisted ${companions.length} transient '
      'detection${companions.length == 1 ? '' : 's'} '
      'for $framePath (${matched.where((c) => c.catalogMatch == null).length} '
      'unnamed)',
      source: _logSource,
    );

    // Return the freshly-persisted rows. Scoped to the session when known,
    // otherwise the global newest-first list trimmed to this batch's size.
    if (sessionId != null) {
      final rows = await _dao.detectionsForSession(sessionId);
      return rows.take(companions.length).toList(growable: false);
    }
    final all = await _dao.allDetections();
    return all.take(companions.length).toList(growable: false);
  }

  /// Mark a detection reviewed; [dismissed] flags it as a triaged artefact so
  /// the next scan suppresses the same position.
  Future<void> markReviewed(int id, {bool dismissed = false}) {
    return _dao.markReviewed(id, dismissed: dismissed);
  }

  /// Age out triaged-artefact transient history so the append-only log does not
  /// grow unbounded across a multi-season run on a constrained appliance.
  ///
  /// Only **dismissed** rows older than [horizon] (default
  /// [defaultRetentionHorizon]) are reclaimed — an explicit human judgement of
  /// "artefact". Un-reviewed candidates and confirmed/named discoveries are
  /// **never** pruned (a possible transient must never be silently reclaimed),
  /// and the recent set the feed renders is untouched because the horizon is far
  /// older than the bounded feed window. Records progress against the
  /// [LivingSkyRetentionScope.transientDetections] marker (if a retention DAO is
  /// wired) so the sweep is observable. Returns the number of rows reclaimed.
  Future<int> pruneOldDetections({
    Duration horizon = defaultRetentionHorizon,
    DateTime? now,
  }) async {
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(horizon);
    final reclaimed = await _dao.pruneDetections(olderThan: cutoff);
    if (reclaimed > 0) {
      _logger.info(
        'First Light retention: reclaimed $reclaimed dismissed transient '
        'detection${reclaimed == 1 ? '' : 's'} older than $cutoff',
        source: _logSource,
      );
    }
    await _retention?.recordPrune(
      LivingSkyRetentionScope.transientDetections,
      lastPrunedAt: cutoff,
      reclaimed: reclaimed,
      note: 'horizon=${horizon.inDays}d',
    );
    return reclaimed;
  }

  /// Cross-match a residual against the photometric catalog.
  ///
  /// A coincident catalog star (within [_matchRadiusArcsec]) names the residual
  /// and reclassifies a `newSource` as a `pointBrightening` of that known star;
  /// the confidence then reflects the SNR. No coincident star on a clean point
  /// source keeps it unnamed and bumps confidence (the exciting case). A network
  /// failure inside the catalog degrades gracefully to "no match" — a transient
  /// that may be unnamed simply because the uplink is down is still surfaced,
  /// flagged with a slightly lower confidence so it sorts below a clean,
  /// catalog-confirmed unknown.
  Future<TransientCandidate> _crossMatch(TransientCandidate candidate) async {
    _NearestStar? nearest;
    var degraded = false;
    // Widen the cone so a high-proper-motion star is still associated with its
    // (now-displaced) J2000 catalog entry rather than mistaken for a new source.
    final elapsedYears = (_observationEpochYear() - _catalogEpochYear).abs();
    final pmBoundArcsec =
        _maxProperMotionArcsecPerYear * elapsedYears + _matchRadiusArcsec;
    try {
      final stars = await _catalog.coneStars(
        raDegrees: candidate.ra,
        decDegrees: candidate.dec,
        radiusDegrees: pmBoundArcsec / 3600.0,
        maxMagnitude: 18.0,
      );
      nearest = _nearestStar(candidate, stars);
    } catch (e) {
      degraded = true;
      _logger.warning(
        'First Light cross-match cone failed at '
        '(${candidate.ra.toStringAsFixed(4)}, '
        '${candidate.dec.toStringAsFixed(4)}): $e',
        source: _logSource,
      );
    }

    if (nearest != null) {
      final star = nearest.star;
      // A star inside the tight radius is a confident positional match; one only
      // inside the widened proper-motion band is an epoch-uncertain association
      // (APASS carries no proper motions, so we cannot propagate it to tonight's
      // epoch — we flag the limitation rather than name it with false confidence).
      final tight = nearest.separationArcsec <= _matchRadiusArcsec;
      // Whether the differencing itself agrees a source pre-existed here: a finite
      // deltaMag means there was measurable template flux beneath the residual.
      final hasTemplateBacking = candidate.deltaMag != null;

      if (!tight) {
        // Epoch-uncertain: do NOT demote a clean new source, and do not claim a
        // confident name. Surface it as a possible high-PM star coincidence so a
        // genuine transient near a displaced star is still reviewed.
        final name =
            'Possible high-PM star '
            'V (APASS, J2000)=${star.magV.toStringAsFixed(1)} '
            '(${nearest.separationArcsec.toStringAsFixed(1)}" off J2000, '
            'epoch uncertain)';
        return candidate.withCrossMatch(
          catalogMatch: name,
          confidence: _confidenceForUnknown(candidate, degraded: degraded),
        );
      }

      // Tight match. Only reclassify a `newSource` into a brightening of the
      // known star when the differencing agrees a source pre-existed beneath it
      // (finite deltaMag). A new source with NO template backing that merely
      // coincides with a faint catalog star is exactly the chance-coincidence a
      // real nova/SN near a background star produces — keep it flagged as a new
      // source coincident with a known star, not silently demoted.
      if (candidate.kind == TransientKind.newSource && !hasTemplateBacking) {
        final name =
            'New source near Star '
            'V (APASS, J2000)=${star.magV.toStringAsFixed(1)} '
            '(no template flux — possible transient)';
        return candidate.withCrossMatch(
          catalogMatch: name,
          confidence: _confidenceForUnknown(candidate, degraded: degraded),
        );
      }

      // A genuine brightening of a known catalog source. Label the catalog
      // brightness explicitly as APASS Johnson V at J2000; the residual deltaMag
      // carried on the candidate is an instrumental quantity (see Transient
      // candidate / brightening surfaces), not standard-system V.
      final name =
          'Star V (APASS, J2000)=${star.magV.toStringAsFixed(1)} @ '
          '${candidate.ra.toStringAsFixed(4)},'
          '${candidate.dec.toStringAsFixed(4)}';
      final named = candidate.withCrossMatch(
        catalogMatch: name,
        confidence: _confidenceForKnown(candidate),
      );
      return named.kind == TransientKind.newSource
          ? _asPointBrightening(named)
          : named;
    }

    // Unmatched. A clean point source with no catalog star is the headline
    // possible-transient; a dipole/streak stays low-confidence (artefact-leaning
    // or already-named-by-shape).
    final confidence = _confidenceForUnknown(candidate, degraded: degraded);
    return candidate.withCrossMatch(catalogMatch: null, confidence: confidence);
  }

  /// Observation epoch as a decimal year. The differencing runs against tonight's
  /// frame, so "now" is the honest epoch; the elapsed time since J2000 bounds how
  /// far a high-PM star may have drifted from its catalog position.
  static double _observationEpochYear() {
    final now = DateTime.now().toUtc();
    final yearStart = DateTime.utc(now.year);
    final yearEnd = DateTime.utc(now.year + 1);
    final frac =
        now.difference(yearStart).inSeconds /
        yearEnd.difference(yearStart).inSeconds;
    return now.year + frac;
  }

  TransientCandidate _asPointBrightening(TransientCandidate c) {
    return TransientCandidate(
      ra: c.ra,
      dec: c.dec,
      tileId: c.tileId,
      tileX: c.tileX,
      tileY: c.tileY,
      residualFlux: c.residualFlux,
      deltaMag: c.deltaMag,
      snr: c.snr,
      fwhm: c.fwhm,
      eccentricity: c.eccentricity,
      positionAngleDeg: c.positionAngleDeg,
      kind: TransientKind.pointBrightening,
      catalogMatch: c.catalogMatch,
      confidence: c.confidence,
    );
  }

  /// Confidence for a named (catalog-confirmed) residual: a smooth SNR ramp,
  /// capped so a known brightening never outranks a clean unknown.
  double _confidenceForKnown(TransientCandidate c) {
    final bySnr = (c.snr / 30.0).clamp(0.0, 1.0).toDouble();
    return (0.4 + 0.4 * bySnr).clamp(0.0, 0.85).toDouble();
  }

  /// Confidence for an unmatched residual. A clean newSource PSF scores highest;
  /// a dipole or elongated streak is penalised (likely an artefact / already
  /// shape-classified). A degraded (network-down) cross-match shaves a little so
  /// a maybe-known unknown sorts below a confirmed one.
  double _confidenceForUnknown(TransientCandidate c, {required bool degraded}) {
    final bySnr = (c.snr / 30.0).clamp(0.0, 1.0).toDouble();
    double shape;
    switch (c.kind) {
      case TransientKind.newSource:
        // Reward roundness — a clean PSF is the real-transient signature.
        shape = 1.0 - c.eccentricity.clamp(0.0, 1.0).toDouble();
      case TransientKind.pointBrightening:
        shape = 0.7;
      case TransientKind.movingStreak:
        shape = 0.5;
      case TransientKind.dipole:
        shape = 0.2;
      case TransientKind.unknown:
        // No shape claim was made, so score it like the artefact-leaning class
        // without asserting it IS one.
        shape = 0.2;
    }
    var confidence = 0.5 * bySnr + 0.5 * shape;
    if (degraded) confidence *= 0.85;
    return confidence.clamp(0.0, 1.0).toDouble();
  }

  /// Nearest catalog star to [candidate] (and its separation), or null when the
  /// list is empty. The caller decides — from the separation — whether the match
  /// is tight or only within the proper-motion-widened band.
  _NearestStar? _nearestStar(
    TransientCandidate candidate,
    List<PhotometricCatalogStar> stars,
  ) {
    PhotometricCatalogStar? best;
    var bestSep = double.infinity;
    for (final star in stars) {
      final sep = _angularSeparationArcsec(
        candidate.ra,
        candidate.dec,
        star.raDegrees,
        star.decDegrees,
      );
      if (sep < bestSep) {
        bestSep = sep;
        best = star;
      }
    }
    if (best == null) return null;
    return _NearestStar(star: best, separationArcsec: bestSep);
  }

  /// Whether [candidate] coincides with a previously-dismissed detection on the
  /// same tile (within [_matchRadiusArcsec]).
  bool _isDismissed(
    TransientCandidate candidate,
    List<TransientDetectionRow> dismissed,
  ) {
    for (final row in dismissed) {
      if (row.tileId != candidate.tileId) continue;
      final sep = _angularSeparationArcsec(
        candidate.ra,
        candidate.dec,
        row.raDeg,
        row.decDeg,
      );
      if (sep <= _matchRadiusArcsec) return true;
    }
    return false;
  }

  /// Great-circle separation in arcseconds (haversine — stable at small angles).
  static double _angularSeparationArcsec(
    double ra1Deg,
    double dec1Deg,
    double ra2Deg,
    double dec2Deg,
  ) {
    const deg2rad = math.pi / 180.0;
    final dLat = (dec2Deg - dec1Deg) * deg2rad;
    final dLon = (ra2Deg - ra1Deg) * deg2rad;
    final lat1 = dec1Deg * deg2rad;
    final lat2 = dec2Deg * deg2rad;
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return c / deg2rad * 3600.0;
  }
}

/// A catalog star and its angular separation (arcsec) from a residual — the
/// cross-match decides tight-vs-epoch-uncertain from the separation.
class _NearestStar {
  const _NearestStar({required this.star, required this.separationArcsec});

  final PhotometricCatalogStar star;
  final double separationArcsec;
}
