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
    Future<String?> Function(int capturedImageId)? filterResolver,
    int order = 9,
  }) : _dao = dao,
       _filterResolver = filterResolver,
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

  /// Looks up a captured image's filter when the caller does not pass one.
  final Future<String?> Function(int capturedImageId)? _filterResolver;

  /// Single-frame sightings waiting for a second frame, per session + layer.
  final Map<String, List<_Sighting>> _sightings = {};

  /// Recent distinct scans, including frames with no usable subtraction.
  final Map<String, List<String>> _recentFrames = {};

  /// Positions already reported this session, per session + layer, so a
  /// confirmed source is persisted once rather than on every later frame.
  final Map<String, List<({double ra, double dec})>> _reported = {};

  /// Distinct earlier frames a sighting can be confirmed against.
  static const int confirmWithinFrames = 6;

  /// Same-position radius (arcsec) for confirming a sighting in another frame.
  static const double confirmRadiusArcsec = 2.5;

  /// More candidates than this from one frame means the subtraction failed
  /// for that frame (registration, cloud, a template mismatch); none of them
  /// is kept.
  static const int maxCandidatesPerFrame = 25;

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

  /// Minimum aperture significance (residual flux over the measured aperture
  /// noise plus a 10% template-flux systematic) the native gate applies.
  static const _minSnr = 7.0;

  String? _cachedAtlasRoot;

  /// The on-disk atlas root, resolved (and the directory created) lazily once.
  Future<String> _atlasRoot() async {
    final cached = _cachedAtlasRoot;
    if (cached != null) return cached;
    final root = await _atlasRootResolver();
    _cachedAtlasRoot = root;
    return root;
  }

  /// Difference [framePath] (solved to [wcs]) against the same-filter atlas
  /// layer, cross-match, suppress dismissed positions, and persist what is
  /// confirmed.
  ///
  /// A source is reported only when it is found at the same sky position in at
  /// least two frames of the session; a first sighting is held in memory and
  /// returns nothing. A frame without a filter is not scanned (no template can
  /// be filter-matched to it). Returns the newly persisted rows.
  Future<List<TransientDetectionRow>> scanFrame({
    required String framePath,
    required SolvedWcs wcs,
    int? sessionId,
    int? capturedImageId,
    String? filter,
    int minTemplateCoverage = 5,
  }) async {
    if (!wcs.isValid) {
      throw ArgumentError.value(
        wcs,
        'wcs',
        'scanFrame needs a valid SolvedWcs (finite centre + positive scale)',
      );
    }

    var frameFilter = filter;
    if (frameFilter == null && capturedImageId != null) {
      frameFilter = await _filterResolver?.call(capturedImageId);
    }
    final layer = atlasLayerKey(frameFilter);
    if (layer == null) {
      _logger.info(
        'First Light scan skipped for $framePath: the frame has no filter, so '
        'no template can be matched to it.',
        source: _logSource,
      );
      return const [];
    }

    final atlasRoot = await _atlasRoot();
    // Reuse the atlas SipWcs-JSON builder so the difference call sees the exact
    // CD + SIP geometry the fold path uses.
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
      'layer': layer,
      'minTemplateCoverage': minTemplateCoverage,
      'minSignificance': _minSnr,
      // Real-pixel template/science/residual postage stamps per detection,
      // named by tile id + position so the UI and the
      // /api/firstlight/<id>/crops endpoint resolve them from the row alone.
      'cropOutDir': firstLightCropDir(atlasRoot),
    };

    final confirmationKey = '${sessionId == null ? '-' : '$sessionId'}|$layer';
    final frameKey = capturedImageId?.toString() ?? framePath;
    _recordScan(confirmationKey, frameKey);
    final result = await _seam.difference(args);
    final coverage = FirstLightCoverage.fromBridgeJson(result);
    _onCoverage?.call(coverage);
    final rawCandidates = (result['candidates'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TransientCandidate.fromBridgeJson)
        .where(
          (c) =>
              c.snr >= _minSnr &&
              (c.kind == TransientKind.newSource ||
                  c.kind == TransientKind.pointBrightening),
        )
        .toList(growable: false);

    if (rawCandidates.isEmpty) {
      if (coverage.tilesChecked == 0 && coverage.tilesCovered > 0) {
        _logger.info(
          'First Light scan: no deep $layer template here yet for $framePath '
          '(${coverage.tilesSkippedThin} '
          'tile${coverage.tilesSkippedThin == 1 ? '' : 's'} under '
          '$minTemplateCoverage frames, ${coverage.tilesNoTemplate} not '
          'folded into yet)',
          source: _logSource,
        );
      }
      return const [];
    }
    if (rawCandidates.length > maxCandidatesPerFrame) {
      _logger.warning(
        'First Light scan: ${rawCandidates.length} candidates on $framePath '
        'is more than a real sky produces; treating the subtraction as failed '
        'for this frame and keeping none.',
        source: _logSource,
      );
      return const [];
    }

    final candidateTiles = rawCandidates.map((c) => c.tileId).toSet();
    final dismissed = await _dao.dismissedDetectionsForTiles(candidateTiles);
    final surviving = rawCandidates
        .where((c) => !_isDismissed(c, dismissed))
        .toList(growable: false);
    final confirmed = _confirm(
      surviving,
      key: confirmationKey,
      frameKey: frameKey,
    );
    if (confirmed.isEmpty) {
      _logger.debug(
        'First Light scan: ${surviving.length} single-frame sighting'
        '${surviving.length == 1 ? '' : 's'} on $framePath waiting for a '
        'second frame',
        source: _logSource,
      );
      return const [];
    }

    final matched = <TransientCandidate>[];
    for (final candidate in confirmed) {
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
      'First Light scan: ${companions.length} source'
      '${companions.length == 1 ? '' : 's'} confirmed in a second frame for '
      '$framePath (${matched.where((c) => c.catalogMatch == null).length} '
      'unnamed)',
      source: _logSource,
    );

    // Newest rows by id: detectedAt has one-second resolution, so ordering by
    // it can hand back an earlier frame's rows.
    final rows = sessionId != null
        ? await _dao.detectionsForSession(sessionId)
        : await _dao.allDetections();
    final newest = rows.toList()..sort((a, b) => b.id.compareTo(a.id));
    return newest.take(companions.length).toList(growable: false);
  }

  void _recordScan(String key, String frameKey) {
    final frames = _recentFrames.putIfAbsent(key, () => []);
    if (!frames.contains(frameKey)) {
      frames.add(frameKey);
      if (frames.length > confirmWithinFrames + 1) frames.removeAt(0);
    }
    _sightings[key]?.removeWhere((s) => !frames.contains(s.frameKey));
  }

  /// Keep the candidates seen at the same sky position in an earlier frame of
  /// the same session and layer (within [confirmWithinFrames] frames), record
  /// the rest as sightings, and drop positions already reported.
  List<TransientCandidate> _confirm(
    List<TransientCandidate> candidates, {
    required String key,
    required String frameKey,
  }) {
    final sightings = _sightings.putIfAbsent(key, () => []);
    final reported = _reported.putIfAbsent(key, () => []);

    final confirmed = <TransientCandidate>[];
    for (final c in candidates) {
      final already = reported.any(
        (r) =>
            _angularSeparationArcsec(c.ra, c.dec, r.ra, r.dec) <=
            confirmRadiusArcsec,
      );
      if (already) continue;
      final seenBefore = sightings.any(
        (s) =>
            s.frameKey != frameKey &&
            _angularSeparationArcsec(c.ra, c.dec, s.ra, s.dec) <=
                confirmRadiusArcsec,
      );
      if (seenBefore) {
        confirmed.add(c);
        reported.add((ra: c.ra, dec: c.dec));
      }
    }
    sightings.removeWhere((s) => s.frameKey == frameKey);
    for (final c in candidates) {
      sightings.add(_Sighting(frameKey: frameKey, ra: c.ra, dec: c.dec));
    }
    return confirmed;
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

  /// Cross-match a residual against the photometric catalog within
  /// [_matchRadiusArcsec].
  ///
  /// A coincident catalog star names the residual. A confirmed brightening of
  /// a catalog star keeps its measured change; a new source that coincides
  /// with a catalog star (no template flux under it) is named as that star not
  /// being in the template. No match leaves it unnamed. A network failure
  /// degrades to "no match" with a slightly lower confidence.
  Future<TransientCandidate> _crossMatch(TransientCandidate candidate) async {
    _NearestStar? nearest;
    var degraded = false;
    try {
      final stars = await _catalog.coneStars(
        raDegrees: candidate.ra,
        decDegrees: candidate.dec,
        radiusDegrees: _matchRadiusArcsec / 3600.0,
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

    if (nearest != null && nearest.separationArcsec <= _matchRadiusArcsec) {
      final star = nearest.star;
      final v = star.magV.toStringAsFixed(1);
      if (candidate.kind == TransientKind.newSource) {
        return candidate.withCrossMatch(
          catalogMatch: 'APASS star V=$v, not in your template',
          confidence: _confidenceForKnown(candidate),
        );
      }
      return candidate.withCrossMatch(
        catalogMatch: 'APASS star V=$v',
        confidence: _confidenceForKnown(candidate),
      );
    }

    final confidence = _confidenceForUnknown(candidate, degraded: degraded);
    return candidate.withCrossMatch(catalogMatch: null, confidence: confidence);
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

/// A single-frame candidate position waiting for confirmation.
class _Sighting {
  const _Sighting({
    required this.frameKey,
    required this.ra,
    required this.dec,
  });

  final String frameKey;
  final double ra;
  final double dec;
}
