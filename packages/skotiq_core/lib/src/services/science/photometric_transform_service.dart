import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' as drift;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/daos/science_dao.dart';
import '../../database/database.dart' as db;
import '../../models/science/science_models.dart';
import '../../providers/database_provider.dart';
import '../../services/logging_service.dart';

/// Service for computing and applying photometric transformation coefficients.
///
/// The standard photometric equation is:
///   M_std = m_inst - k*X + T*(B-V) + zp
///
/// where:
///   M_std  = standard (catalog) magnitude
///   m_inst = instrumental magnitude = -2.5 * log10(flux)
///   k      = atmospheric extinction coefficient (magnitudes per airmass)
///   X      = airmass
///   T      = color transform coefficient
///   (B-V)  = color index
///   zp     = photometric zero point
class PhotometricTransformService {
  final Ref _ref;

  PhotometricTransformService(this._ref);

  ScienceDao get _scienceDao => _ref.read(scienceDaoProvider);
  LoggingService get _logger => _ref.read(loggingServiceProvider);

  /// Compute transformation coefficients from a set of catalog star matches
  /// using ordinary least-squares regression.
  ///
  /// The model is:  catalogMag = m_inst - k*X + T*(B-V) + zp
  /// Rearranged:    catalogMag - m_inst = -k*X + T*(B-V) + zp
  ///
  /// So we fit:  y = a0 + a1*X + a2*(B-V)
  /// where y = catalogMag - m_inst, a0 = zp, a1 = -k, a2 = T
  ///
  /// Requires at least 4 star matches (3 unknowns + 1 DOF).
  PhotometricTransformCoefficients? computeTransformCoefficients({
    required List<CatalogStarMatch> starMatches,
    required String filterName,
    int? equipmentProfileId,
    String catalogSource = 'auto',
  }) {
    if (starMatches.length < 4) {
      _logger.warning(
        'Need at least 4 star matches for transform fit, got ${starMatches.length}',
        source: 'PhotometricTransformService',
      );
      return null;
    }

    // Filter out saturated or very faint stars
    final validStars = starMatches
        .where((star) {
          return star.instrumentalFlux > 0 &&
              star.snr >= 5.0 &&
              star.catalogMagV.isFinite &&
              star.catalogMagB.isFinite &&
              star.airmass > 0 &&
              star.airmass < 10.0;
        })
        .toList(growable: false);

    if (validStars.length < 4) {
      _logger.warning(
        'After filtering, only ${validStars.length} valid stars remain (need 4)',
        source: 'PhotometricTransformService',
      );
      return null;
    }

    // Build the system: y = zp + (-k)*X + T*(B-V)
    final n = validStars.length;
    final y = List<double>.filled(n, 0.0);
    final x1 = List<double>.filled(n, 0.0); // airmass
    final x2 = List<double>.filled(n, 0.0); // color index

    for (var i = 0; i < n; i++) {
      final star = validStars[i];
      final instMag =
          -2.5 *
          math.log(star.instrumentalFlux.clamp(1e-30, double.infinity)) /
          math.ln10;
      y[i] = star.catalogMagV - instMag;
      x1[i] = star.airmass;
      x2[i] = star.colorIndex;
    }

    // Model selection: a term is only fittable when its predictor actually
    // varies across the input stars. Stars matched on a SINGLE frame all
    // share one airmass, which makes the airmass column exactly collinear
    // with the intercept — Cramer's rule on the full 3x3 system then
    // divides by a determinant that is pure floating-point noise and
    // produces arbitrarily large garbage coefficients that a small absolute
    // epsilon check cannot reliably catch. Detect each degeneracy up front
    // and drop the unfittable term instead: its contribution at the
    // observed predictor value folds into the zero point, which is exactly
    // what the data can support.
    var x1Min = x1[0], x1Max = x1[0];
    var x2Min = x2[0], x2Max = x2[0];
    for (var i = 1; i < n; i++) {
      if (x1[i] < x1Min) x1Min = x1[i];
      if (x1[i] > x1Max) x1Max = x1[i];
      if (x2[i] < x2Min) x2Min = x2[i];
      if (x2[i] > x2Max) x2Max = x2[i];
    }
    // ~0.05 airmass ≈ a few degrees of altitude near zenith; below that the
    // extinction slope is unconstrained. 0.1 mag of B-V spread is the
    // minimum for a meaningful color term.
    final fitAirmass = (x1Max - x1Min) >= 0.05;
    final fitColor = (x2Max - x2Min) >= 0.10;

    if (!fitAirmass) {
      _logger.warning(
        'Airmass spread ${(x1Max - x1Min).toStringAsFixed(4)} is too small to '
        'fit extinction (single-frame data). Reporting k=0; the extinction at '
        'X≈${x1[0].toStringAsFixed(2)} is absorbed into the zero point.',
        source: 'PhotometricTransformService',
      );
    }
    if (!fitColor) {
      _logger.warning(
        'Color-index spread ${(x2Max - x2Min).toStringAsFixed(4)} is too '
        'small to fit a color term. Reporting T=0.',
        source: 'PhotometricTransformService',
      );
    }

    final coeffs = _solveLeastSquares(
      y: y,
      x1: x1,
      x2: x2,
      fitAirmass: fitAirmass,
      fitColor: fitColor,
    );
    if (coeffs == null) {
      _logger.error(
        'Transform normal equations are singular even after dropping '
        'degenerate terms (n=$n). Input stars are unusable for a fit.',
        source: 'PhotometricTransformService',
      );
      return null;
    }
    final a0 = coeffs.$1;
    final a1 = coeffs.$2; // a1 = -k
    final a2 = coeffs.$3;

    final zeroPoint = a0;
    final extinctionCoefficient = -a1;
    final colorTerm = a2;

    // Compute residuals
    var sumSqResidual = 0.0;
    final fitData = <TransformStarMatch>[];
    for (var i = 0; i < n; i++) {
      final predicted = a0 + a1 * x1[i] + a2 * x2[i];
      final residual = y[i] - predicted;
      sumSqResidual += residual * residual;
      fitData.add(
        TransformStarMatch(
          catalogMag: validStars[i].catalogMagV,
          instrumentalMag: validStars[i].catalogMagV - y[i], // m_inst
          colorIndex: x2[i],
          airmass: x1[i],
          residual: residual,
        ),
      );
    }
    // Divide by the residual degrees of freedom, not by n: the fit already
    // spent one degree of freedom per coefficient driving those residuals to
    // zero. Using n understates the true scatter by sqrt((n-p)/n) — measured at
    // 35% low with 6 stars and 14% low with 12, and this number is what the
    // calibration wizard shows as fit quality. With n == p the fit passes
    // exactly through the data and the scatter is simply unknown.
    final fittedParameters = 1 + (fitAirmass ? 1 : 0) + (fitColor ? 1 : 0);
    final residualDof = n - fittedParameters;
    final rmsResidual = residualDof > 0
        ? math.sqrt(sumSqResidual / residualDof)
        : double.nan;

    if (!zeroPoint.isFinite ||
        !extinctionCoefficient.isFinite ||
        !colorTerm.isFinite ||
        !rmsResidual.isFinite) {
      _logger.error(
        'Transform fit produced non-finite results: '
        'zp=$zeroPoint, k=$extinctionCoefficient, T=$colorTerm, '
        'rms=$rmsResidual (n=$n, fitted parameters=$fittedParameters)',
        source: 'PhotometricTransformService',
      );
      return null;
    }

    // Sanity checks — extinction should be positive and reasonable
    if (extinctionCoefficient < -0.5 || extinctionCoefficient > 2.0) {
      _logger.warning(
        'Extinction coefficient k=$extinctionCoefficient is outside '
        'typical range [0, 1.5]. Fit may be unreliable.',
        source: 'PhotometricTransformService',
      );
    }

    _logger.info(
      'Photometric transform computed for filter=$filterName: '
      'zp=${zeroPoint.toStringAsFixed(3)}, '
      'k=${extinctionCoefficient.toStringAsFixed(4)}, '
      'T=${colorTerm.toStringAsFixed(4)}, '
      'RMS=${rmsResidual.toStringAsFixed(4)}, '
      'N=$n stars',
      source: 'PhotometricTransformService',
    );

    return PhotometricTransformCoefficients(
      equipmentProfileId: equipmentProfileId,
      filterName: filterName,
      colorTerm: colorTerm,
      extinctionCoefficient: extinctionCoefficient,
      zeroPoint: zeroPoint,
      rmsResidual: rmsResidual,
      matchedStarCount: n,
      catalogSource: catalogSource,
      fitData: fitData,
      dateComputed: DateTime.now(),
    );
  }

  /// Weighted-free least squares for y = a0 [+ a1*x1] [+ a2*x2], with terms
  /// included only when their flag is set; excluded terms return 0.0.
  /// Returns null when the (reduced) normal matrix is singular relative to
  /// its own scale.
  (double, double, double)? _solveLeastSquares({
    required List<double> y,
    required List<double> x1,
    required List<double> x2,
    required bool fitAirmass,
    required bool fitColor,
  }) {
    final n = y.length;
    var s00 = 0.0, s01 = 0.0, s02 = 0.0;
    var s11 = 0.0, s12 = 0.0, s22 = 0.0;
    var sy0 = 0.0, sy1 = 0.0, sy2 = 0.0;
    for (var i = 0; i < n; i++) {
      s00 += 1.0;
      s01 += x1[i];
      s02 += x2[i];
      s11 += x1[i] * x1[i];
      s12 += x1[i] * x2[i];
      s22 += x2[i] * x2[i];
      sy0 += y[i];
      sy1 += x1[i] * y[i];
      sy2 += x2[i] * y[i];
    }

    if (fitAirmass && fitColor) {
      final det =
          s00 * (s11 * s22 - s12 * s12) -
          s01 * (s01 * s22 - s12 * s02) +
          s02 * (s01 * s12 - s11 * s02);
      // Scale-relative singularity guard: compare against the magnitude the
      // determinant would have for well-conditioned inputs.
      final scale = s00 * s11 * s22;
      if (scale <= 0 || det.abs() < 1e-9 * scale) {
        return null;
      }
      final invDet = 1.0 / det;
      final a0 =
          invDet *
          (sy0 * (s11 * s22 - s12 * s12) -
              s01 * (sy1 * s22 - s12 * sy2) +
              s02 * (sy1 * s12 - s11 * sy2));
      final a1 =
          invDet *
          (s00 * (sy1 * s22 - s12 * sy2) -
              sy0 * (s01 * s22 - s12 * s02) +
              s02 * (s01 * sy2 - sy1 * s02));
      final a2 =
          invDet *
          (s00 * (s11 * sy2 - sy1 * s12) -
              s01 * (s01 * sy2 - sy1 * s02) +
              sy0 * (s01 * s12 - s11 * s02));
      return (a0, a1, a2);
    }

    if (fitAirmass || fitColor) {
      // Single-slope model y = a0 + a*x for whichever predictor varies.
      final sx = fitAirmass ? s01 : s02;
      final sxx = fitAirmass ? s11 : s22;
      final sxy = fitAirmass ? sy1 : sy2;
      final det = s00 * sxx - sx * sx;
      final scale = s00 * sxx;
      if (scale <= 0 || det.abs() < 1e-9 * scale) {
        return null;
      }
      final slope = (s00 * sxy - sx * sy0) / det;
      final intercept = (sy0 - slope * sx) / s00;
      return fitAirmass ? (intercept, slope, 0.0) : (intercept, 0.0, slope);
    }

    // Intercept-only model: every predictor is degenerate, so the best
    // estimate is the mean offset (the zero point at this airmass).
    if (s00 <= 0) return null;
    return (sy0 / s00, 0.0, 0.0);
  }

  // NOTE: transform application lives on the model
  // (PhotometricTransformCoefficients.applyTransform) so there is exactly
  // one implementation; the science pipeline calls it directly.

  /// Save computed coefficients to the database.
  Future<int> saveTransform(
    PhotometricTransformCoefficients coefficients,
  ) async {
    final fitDataJson = jsonEncode(
      coefficients.fitData.map((match) => match.toJson()).toList(),
    );
    return _scienceDao.insertPhotometricTransform(
      db.PhotometricTransformsCompanion.insert(
        equipmentProfileId: drift.Value(coefficients.equipmentProfileId),
        filterName: coefficients.filterName,
        colorTerm: coefficients.colorTerm,
        extinctionCoefficient: coefficients.extinctionCoefficient,
        zeroPoint: coefficients.zeroPoint,
        rmsResidual: coefficients.rmsResidual,
        matchedStarCount: drift.Value(coefficients.matchedStarCount),
        catalogSource: drift.Value(coefficients.catalogSource),
        fitDataJson: drift.Value(fitDataJson),
        dateComputed: drift.Value(coefficients.dateComputed),
      ),
    );
  }

  /// Delete a saved transform.
  Future<void> deleteTransform(int id) {
    return _scienceDao.deletePhotometricTransform(id);
  }

  /// Load the best available transform for a given filter.
  Future<PhotometricTransformCoefficients?> getTransformForFilter(
    String filterName, {
    int? equipmentProfileId,
  }) async {
    final row = await _scienceDao.getTransformForFilter(
      filterName,
      equipmentProfileId: equipmentProfileId,
    );
    if (row == null) {
      return null;
    }
    return _rowToCoefficients(row);
  }

  /// Load all saved transforms.
  Future<List<PhotometricTransformCoefficients>> getAllTransforms() async {
    final rows = await _scienceDao.getAllTransforms();
    return rows.map(_rowToCoefficients).toList(growable: false);
  }

  PhotometricTransformCoefficients _rowToCoefficients(
    db.PhotometricTransformRow row,
  ) {
    List<TransformStarMatch> fitData = const [];
    if (row.fitDataJson != null && row.fitDataJson!.isNotEmpty) {
      try {
        final decoded = jsonDecode(row.fitDataJson!);
        if (decoded is List) {
          fitData = decoded
              .whereType<Map<String, dynamic>>()
              .map(TransformStarMatch.fromJson)
              .toList(growable: false);
        }
      } catch (error) {
        _logger.warning(
          'Failed to decode fit data JSON for transform ${row.id}: $error',
          source: 'PhotometricTransformService',
        );
      }
    }

    return PhotometricTransformCoefficients(
      id: row.id,
      equipmentProfileId: row.equipmentProfileId,
      filterName: row.filterName,
      colorTerm: row.colorTerm,
      extinctionCoefficient: row.extinctionCoefficient,
      zeroPoint: row.zeroPoint,
      rmsResidual: row.rmsResidual,
      matchedStarCount: row.matchedStarCount,
      catalogSource: row.catalogSource,
      fitData: fitData,
      dateComputed: row.dateComputed,
    );
  }
}

final photometricTransformServiceProvider =
    Provider<PhotometricTransformService>((ref) {
      return PhotometricTransformService(ref);
    });
