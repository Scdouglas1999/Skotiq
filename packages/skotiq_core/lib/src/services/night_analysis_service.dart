import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/images_dao.dart';
import '../database/daos/night_reports_dao.dart';
import '../database/daos/science_dao.dart';
import '../database/database.dart';
import '../models/imaging/night_report.dart';
import '../providers/database_provider.dart';
import 'frame_quality_assessment_service.dart';
import 'optical_train_diagnostics_service.dart';
import 'scheduler/sky_calculations.dart';
part 'night_analysis_service/detectors.dart';
part 'night_analysis_service/night_data.dart';
part 'night_analysis_service/moon_ephemeris.dart';
part 'night_analysis_service/statistics.dart';

/// The "Night Doctor" — a deterministic, rule-based analyzer that ingests a
/// session's (or target's) per-sub time series from `captured_images` (with
/// optional science-table enrichment) and emits a [NightReport]: an overall
/// 0..100 [NightReport.score], a one-line [NightReport.headline], and a ranked
/// list of [NightFinding]s.
///
/// **Design.** All detection logic runs on plain in-memory value objects
/// ([NightSub]), so each detector is a pure function over a sorted sub list and is
/// fully exercisable in a unit test without native code, without a live mount,
/// and without the science pipeline having run. The service's only side effects
/// are the three injected DAO reads ([ImagesDao], [ScienceDao]) and the one
/// write ([NightReportsDao.insertReport]).
///
/// **Fail-soft contract.** Every detector emits *nothing* (rather than throwing
/// or guessing) when the signal it needs is missing — too few subs, a metric
/// that is null across the night, or an absent science table. This is the rule
/// the brief calls out: "detectors that need missing data fail-soft (emit
/// nothing rather than throw)".
///
/// **Un-gradable nights.** Because the score only ever subtracts, silence from
/// every detector is indistinguishable from a flawless night. A night with
/// nothing analysable ([ungradableReason]) therefore yields an explicitly
/// un-graded report ([NightReport.graded] false, [NightReport.ungradedScore])
/// whose headline says why — never a 100/100 "clean night".
class NightAnalysisService {
  NightAnalysisService({
    required ImagesDao images,
    required ScienceDao science,
    required NightReportsDao reports,
    DateTime Function()? clock,
  }) : _images = images,
       _science = science,
       _reports = reports,
       _clock = clock ?? DateTime.now;

  final ImagesDao _images;
  final ScienceDao _science;
  final NightReportsDao _reports;
  final DateTime Function() _clock;

  /// Compute (and persist) a [NightReport] for a session or a target.
  ///
  /// Exactly one of [sessionId] / [targetId] should be supplied; if both are
  /// given the session scopes the sub fetch and the target is recorded on the
  /// report. If neither is supplied there is nothing to analyze, so the report
  /// comes back explicitly un-graded ([NightReport.graded] false).
  ///
  /// When [persist] is true (the default) the report is written to
  /// `night_reports` and the returned [NightReport] is the persisted value.
  Future<NightReport> computeReport({
    int? sessionId,
    int? targetId,
    bool persist = true,
  }) async {
    final data = await _load(sessionId: sessionId, targetId: targetId);
    final report = analyze(data, sessionId: sessionId, targetId: targetId);
    if (persist) {
      await _reports.insertReport(
        sessionId: sessionId,
        targetId: targetId,
        score: report.score,
        headline: report.headline,
        findings: report.findings,
        createdAt: report.createdAt,
      );
    }
    return report;
  }

  /// Pure analysis over already-loaded [data]. Exposed (rather than only the
  /// DB-bound [computeReport]) so tests can drive the full detector + scoring
  /// pipeline with synthetic series and no database at all.
  NightReport analyze(NightData data, {int? sessionId, int? targetId}) {
    final findings = <NightFinding>[];
    for (final detector in _detectors) {
      // Defensive: a detector bug must never sink the whole report. Each one is
      // already written to fail-soft on missing data, but if one throws on a
      // pathological series we drop that finding rather than the report.
      try {
        findings.addAll(detector(data));
      } catch (e) {
        // Skip this detector's contribution; continue the pipeline — but
        // leave a trace. A silently-skipped detector reads as "no finding",
        // which is indistinguishable from "checked and healthy"; the log
        // line is the only way a degraded report can be diagnosed.
        developer.log(
          'Night Doctor detector threw and was skipped: $e',
          name: 'NightAnalysisService',
          level: 900,
        );
      }
    }
    findings.sort(_bySeverityDesc);

    // A night with nothing to analyse cannot be graded. The score subtracts
    // penalties from 100, so without analysable frames it would land on a
    // perfect 100 / "A clean night" — the exact opposite of the truth for a
    // failed or dark-only run. Say "not graded" and why.
    final ungradable = ungradableReason(data);
    if (ungradable != null) {
      return NightReport.ungraded(
        sessionId: sessionId,
        targetId: targetId,
        headline: ungradable,
        findings: List.unmodifiable(findings),
        createdAt: _clock().toUtc(),
      );
    }

    final score = _score(findings);
    final headline = _headline(score, findings);
    return NightReport(
      sessionId: sessionId,
      targetId: targetId,
      score: score,
      headline: headline,
      findings: List.unmodifiable(findings),
      createdAt: _clock().toUtc(),
    );
  }

  /// Fewest light subs that can carry a night grade. Every detector needs at
  /// least a handful of points to distinguish a trend from noise, so below this
  /// the honest answer is "not graded", not "no problems detected".
  static const int minGradableSubs = 4;

  /// Why [data] cannot be graded, in one user-facing sentence — or null when it
  /// can. Public so the tests (and any other surface that wants to pre-check)
  /// use the same rule the report does.
  static String? ungradableReason(NightData data) {
    final total = data.subs.length;
    if (total == 0) {
      return 'Not graded — this session captured no light frames, so there is '
          'nothing to analyse.';
    }
    if (total < minGradableSubs) {
      return 'Not graded — only $total light '
          '${total == 1 ? 'frame was' : 'frames were'} captured; the night needs '
          'at least $minGradableSubs to be judged.';
    }
    final measured = data.subs.where(_hasAnyMetric).length;
    if (measured < minGradableSubs) {
      return 'Not graded — the captured frames carry no quality measurements '
          '(HFR, star count, background or guiding), so the night could not be '
          'analysed.';
    }
    return null;
  }

  /// Whether [sub] carries at least one metric any detector can read. A sub with
  /// every metric null contributes nothing, so a night of those is un-gradable
  /// however many frames it holds.
  static bool _hasAnyMetric(NightSub sub) =>
      sub.hfr != null ||
      sub.starCount != null ||
      sub.background != null ||
      sub.noise != null ||
      sub.guidingRmsTotal != null ||
      sub.snr != null ||
      sub.fwhm != null ||
      sub.eccentricity != null;

  // Detector registry

  late final List<List<NightFinding> Function(NightData)> _detectors = [
    _detectFocusDrift,
    _detectCloudTransparencyLoss,
    _detectGuidingCorrelation,
    _detectDewHfrCollapse,
    _detectMoonGradientOnset,
    _detectTiltCollimation,
    _detectGraderPoorNight,
  ];

  // Data loading

  Future<NightData> _load({int? sessionId, int? targetId}) async {
    List<NightSub> subs;
    if (sessionId != null) {
      final rows = await _images.getImagesForSession(sessionId);
      subs = await _toSubs(rows, sessionId: sessionId);
    } else if (targetId != null) {
      final rows = await _images.getImagesForTarget(targetId);
      // getImagesForTarget is DESC; the detectors assume ascending time.
      rows.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      subs = await _toSubs(rows, sessionId: null);
    } else {
      subs = const [];
    }
    return NightData(
      subs,
      opticalDiagnostics: await _loadOpticalDiagnostics(sessionId),
    );
  }

  /// Run the optical-train diagnostics (field tilt / collimation) over the
  /// session's PSF field tiles + astrometric residual vectors. Fail-soft to
  /// null: the science pipeline not having produced tiles is the common
  /// case, and the tilt detector then simply stays silent.
  Future<OpticalTrainDiagnostics?> _loadOpticalDiagnostics(
    int? sessionId,
  ) async {
    if (sessionId == null) return null;
    try {
      final tiles = await _science.getPsfTilesForSession(sessionId);
      if (tiles.isEmpty) return null;
      final residuals = await _science.getResidualsForSession(sessionId);
      return const OpticalTrainDiagnosticsService().analyze(
        psfTiles: tiles,
        residualVectors: residuals,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<NightSub>> _toSubs(
    List<CapturedImage> rows, {
    required int? sessionId,
  }) async {
    final lights = rows
        .where((r) => r.frameType.toLowerCase() == 'light')
        .toList(growable: false);
    if (lights.isEmpty) return const [];

    final ids = lights.map((r) => r.id).toList(growable: false);
    final eccentricity = await _loadEccentricity(ids);
    final snr = await _loadScienceSnr(sessionId);
    final fwhm = await _loadPsfFwhm(sessionId);

    return [
      for (final r in lights)
        NightSub(
          id: r.id,
          capturedAt: r.capturedAt,
          filter: r.filter,
          isAccepted: r.isAccepted,
          hfr: r.hfr,
          starCount: r.starCount,
          background: r.background,
          noise: r.noise,
          guidingRmsTotal: r.guidingRmsTotal,
          focuserPosition: r.focuserPosition,
          focuserTemp: r.focuserTemp,
          sensorTemp: r.sensorTemp,
          eccentricity: eccentricity[r.id],
          snr: snr[r.id],
          fwhm: fwhm[r.id],
          qualityScore: r.qualityScore,
        ),
    ];
  }

  /// Read the raw-DDL `eccentricity` column (not on the drift table class) for a
  /// batch of sub ids. Fail-soft: any read error → empty map (the eccentricity
  /// signal is simply absent and detectors that need it stay silent).
  Future<Map<int, double>> _loadEccentricity(List<int> ids) async {
    if (ids.isEmpty) return const {};
    try {
      final placeholders = List.filled(ids.length, '?').join(', ');
      final rows = await _images
          .customSelect(
            'SELECT id, eccentricity FROM captured_images WHERE id IN '
            '($placeholders)',
            variables: [for (final id in ids) Variable<int>(id)],
          )
          .get();
      final out = <int, double>{};
      for (final row in rows) {
        final ecc = row.readNullable<double>('eccentricity');
        if (ecc != null) out[row.read<int>('id')] = ecc;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Per-sub SNR from the science `ScienceFrameQualityMetrics` table, keyed by
  /// `capturedImageId`. Fail-soft: returns empty when the science pipeline did
  /// not run for this session (the common case) or the table is unreadable.
  ///
  /// The `snr` column is non-nullable with a `0.0` default (science.dart:171), so
  /// a row the pipeline wrote without ever computing SNR reads back as `0.0` —
  /// missing signal, not a real reading of zero. Such rows are skipped so the
  /// cloud detector never mistakes a defaulted 0.0 for a genuine dropout.
  Future<Map<int, double>> _loadScienceSnr(int? sessionId) async {
    if (sessionId == null) return const {};
    try {
      final rows = await _science.getFrameQualityMetricsForSession(sessionId);
      final out = <int, double>{};
      for (final r in rows) {
        final id = r.capturedImageId;
        if (id != null && r.snr > 0) out[id] = r.snr;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Per-sub field-median FWHM from the science `PsfFieldTiles` table, averaged
  /// across tiles per frame. Fail-soft to empty.
  ///
  /// `medianFwhm` is non-nullable with a `0.0` default (science.dart:139); a tile
  /// the pipeline never measured reads back as `0.0`. Those tiles are excluded
  /// from the per-frame average so an un-measured tile cannot drag a frame's FWHM
  /// toward zero.
  Future<Map<int, double>> _loadPsfFwhm(int? sessionId) async {
    if (sessionId == null) return const {};
    try {
      final rows = await _science.getPsfTilesForSession(sessionId);
      final sums = <int, double>{};
      final counts = <int, int>{};
      for (final r in rows) {
        final id = r.capturedImageId;
        if (id == null || r.medianFwhm <= 0) continue;
        sums[id] = (sums[id] ?? 0) + r.medianFwhm;
        counts[id] = (counts[id] ?? 0) + 1;
      }
      return {for (final e in sums.entries) e.key: e.value / counts[e.key]!};
    } catch (_) {
      return const {};
    }
  }

  // Scoring + headline

  /// Per-finding penalties. Monotone in severity (critical > warn > info), so
  /// the night score is monotone w.r.t. the worst finding's severity. Penalties
  /// stack but the score is floored at 0.
  static const Map<NightFindingSeverity, int> _penalty = {
    NightFindingSeverity.info: 2,
    NightFindingSeverity.warn: 12,
    NightFindingSeverity.critical: 30,
  };

  int _score(List<NightFinding> findings) {
    var score = 100;
    for (final f in findings) {
      score -= _penalty[f.severity] ?? 0;
    }
    return score.clamp(0, 100);
  }

  String _headline(int score, List<NightFinding> findings) {
    if (findings.isEmpty) {
      return score >= 100
          ? 'A clean night — no problems detected.'
          : 'A solid night with nothing significant to flag.';
    }
    final worst = findings.first; // sorted severity-desc
    final extra = findings.length - 1;
    final tail = extra > 0
        ? ' (+$extra more ${extra == 1 ? 'finding' : 'findings'})'
        : '';
    switch (worst.severity) {
      case NightFindingSeverity.critical:
        return 'Rough night: ${worst.title.toLowerCase()}$tail.';
      case NightFindingSeverity.warn:
        return 'Decent night, but ${worst.title.toLowerCase()}$tail.';
      case NightFindingSeverity.info:
        return 'Good night${tail.isEmpty ? '' : ' —'}${worst.title.toLowerCase()}$tail.';
    }
  }

  static int _bySeverityDesc(NightFinding a, NightFinding b) {
    return b.severity.index.compareTo(a.severity.index);
  }
}

/// Riverpod provider for the Night Doctor. Constructor-injected DAOs mirror the
/// post-session services' idiom so tests override the DAO providers (or
/// construct the service directly) to run without native code.
final nightAnalysisServiceProvider = Provider<NightAnalysisService>((ref) {
  return NightAnalysisService(
    images: ref.watch(imagesDaoProvider),
    science: ref.watch(scienceDaoProvider),
    reports: ref.watch(nightReportsDaoProvider),
  );
});
