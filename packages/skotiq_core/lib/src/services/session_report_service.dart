import 'dart:convert';

import '../utils/duration_format.dart';
import '../utils/fwhm_conversion.dart';
import '../database/daos/science_dao.dart';
import '../database/daos/sequence_runs_dao.dart';
import '../database/daos/targets_dao.dart';
import 'imaging_records_repository.dart';
import '../database/database.dart';
import '../models/session_report.dart';

/// Builds an end-of-session report from the persisted Drift tables.
///
/// The report is a read-only derivation: every metric is computed from the
/// `imaging_sessions`, `captured_images`, and `sequence_runs` rows already
/// owned by the session being reported on. This means a report can be
/// regenerated for any past session without re-running the sequencer, and
/// the service has no internal state to keep in sync with execution.
///
/// Sources by metric. Every missing field stays `null`, so the UI renders a
/// dash rather than a zero that reads as a measurement:
///   * Frame counts / integration time / per-filter rollups: `captured_images`
///     filtered to `frame_type='light'` for the session.
///   * Quality (HFR, star count, SNR proxy, sensor temp): means computed over
///     accepted frames only.
///   * Guide RMS: from `captured_images.guidingRms*` columns directly.
///   * Mount events (autofocus / meridian flip / dither / trigger fires):
///     joined from `sequence_runs.statsJson` for any run started within the
///     session's wall-clock window; autofocus count also takes
///     `imaging_sessions.autofocusCount` as a floor because the legacy
///     non-sequencer path increments only that column.
///   * Errors: error message lists from the same `sequence_runs` rows.
class SessionReportService {
  final ImagingRecordsRepository _records;
  final SequenceRunsDao _sequenceRunsDao;
  final TargetsDao _targetsDao;
  final ScienceDao? _scienceDao;

  SessionReportService({
    required ImagingRecordsRepository records,
    required SequenceRunsDao sequenceRunsDao,
    required TargetsDao targetsDao,
    ScienceDao? scienceDao,
  }) : _records = records,
       _sequenceRunsDao = sequenceRunsDao,
       _targetsDao = targetsDao,
       _scienceDao = scienceDao;

  /// Per-frame REAL SNR from the science pipeline, keyed by captured-image
  /// id. Fail-soft to empty (science pipeline disabled / table unreadable);
  /// the background/noise proxy then remains the fallback. The `snr` column
  /// is non-nullable with a 0.0 default, so defaulted rows (pipeline wrote
  /// the row but never computed SNR) are skipped rather than treated as a
  /// genuine reading of zero — mirrors NightAnalysisService._loadScienceSnr.
  Future<Map<int, double>> _loadScienceSnr(int sessionId) async {
    final dao = _scienceDao;
    if (dao == null) return const {};
    try {
      final rows = await dao.getFrameQualityMetricsForSession(sessionId);
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

  /// Generate a fresh [SessionReport] for [sessionId].
  ///
  /// Throws when the session row is missing — the caller passes an ID it
  /// already resolved via [SessionsDao.getSessionById] or a stream. There is no
  /// fallback to an empty report, which would read as a session that produced
  /// nothing.
  Future<SessionReport> buildReport(int sessionId) async {
    final session = await _records.getSessionById(sessionId);
    if (session == null) {
      throw StateError('Session $sessionId not found');
    }

    final images = await _records.getImagesForSession(sessionId);
    // Case-insensitive. The native sequencer emits "Light"/"Dark" capitalised
    // and Dart lower-cases on the way into the row, but `images_dao`,
    // `equipment_stats` and `session_chart` all normalise before comparing and
    // this was the one place that did not — a row that reached the table with
    // its original capitalisation was invisible to the report alone.
    final lightFrames = images
        .where((i) => i.frameType.toLowerCase() == 'light')
        .toList(growable: false);
    // Everything that is not a light. Previously discarded outright, which is
    // how a dark-only session reported "Frames accepted 0/0" and "Integration
    // 0s" while three dark FITS sat on disk, `imaging_sessions` recorded
    // 3 exposures / 6.0 s, and the Sequencer showed "3 / 3 frames".
    // Calibration frames do not belong in a target's integration, but they are
    // frames, and the report has to say so.
    final calibrationFrames = images
        .where((i) => i.frameType.toLowerCase() != 'light')
        .toList(growable: false);

    final scienceSnrById = await _loadScienceSnr(sessionId);
    final targetReports = await _buildTargetReports(
      lightFrames,
      scienceSnrById,
    );
    final calibrationReports = _buildCalibrationReports(calibrationFrames);
    final guideStats = _buildGuideStats(lightFrames);
    final mountStats = await _buildMountStats(session);

    // wallClock falls back to now when the session is still open so the
    // dialog can render a partial duration while a sequence is paused.
    final endTime = session.endTime;
    final wallClockDuration = (endTime ?? DateTime.now()).difference(
      session.startTime,
    );

    final totalIntegrationSecs = targetReports.fold<double>(
      0.0,
      (sum, t) => sum + t.totalIntegrationSecs,
    );
    final totalIntegration = Duration(
      milliseconds: (totalIntegrationSecs * 1000).round(),
    );

    // Downtime and effective-imaging measure the CLOCK, not the science: any
    // second the shutter was open is a second the rig was working. Deriving
    // them from light integration alone reported a calibration run as 100%
    // downtime — a night spent building a dark library came back looking like
    // a night spent doing nothing.
    final shutterOpenSecs =
        totalIntegrationSecs +
        calibrationReports.fold<double>(
          0.0,
          (sum, c) => sum + c.totalIntegrationSecs,
        );

    // Effective fraction must be clamped because pathological short sessions
    // (e.g. 0-duration aborts) would otherwise divide by zero or report >100%.
    final wallClockSecs = wallClockDuration.inMilliseconds / 1000.0;
    final effectiveImagingFraction = wallClockSecs <= 0.0
        ? 0.0
        : (shutterOpenSecs / wallClockSecs).clamp(0.0, 1.0);

    final downtimeSecs = wallClockSecs - shutterOpenSecs;
    final downtime = Duration(
      milliseconds: (downtimeSecs < 0 ? 0 : downtimeSecs * 1000).round(),
    );

    final errors = await _collectErrorMessages(session);
    final warnings = await _collectWarningMessages(session);
    final failure = await _collectFailureFacts(session);

    return SessionReport(
      sessionId: session.id,
      sessionName: session.name ?? 'Session ${session.id}',
      status: session.status,
      startTime: session.startTime,
      endTime: endTime,
      wallClockDuration: wallClockDuration,
      totalIntegration: totalIntegration,
      effectiveImagingFraction: effectiveImagingFraction,
      downtime: downtime,
      targets: targetReports,
      calibration: calibrationReports,
      guideStats: guideStats,
      mountStats: mountStats,
      avgTemperatureC: session.avgTemperature,
      avgHumidityPercent: session.avgHumidity,
      avgSeeingArcsec: session.avgSeeing,
      notes: session.notes,
      errorMessages: errors,
      warningMessages: warnings,
      terminalCause: failure.cause,
      rejectFolder: failure.rejectFolder,
      generatedAt: DateTime.now(),
    );
  }

  /// Bucket non-light frames by their (lower-cased) frame type.
  ///
  /// Grouping is by the frame-type STRING — the row's own identity for this
  /// purpose — never by position in [frames].
  List<SessionCalibrationReport> _buildCalibrationReports(
    List<CapturedImage> frames,
  ) {
    if (frames.isEmpty) return const [];

    final byType = <String, List<CapturedImage>>{};
    for (final frame in frames) {
      final type = frame.frameType.toLowerCase();
      byType.putIfAbsent(type, () => <CapturedImage>[]).add(frame);
    }

    final types = byType.keys.toList()..sort();
    return types
        .map((type) {
          final all = byType[type]!;
          final accepted = all
              .where((f) => f.isAccepted)
              .toList(growable: false);
          return SessionCalibrationReport(
            frameType: type,
            framesAttempted: all.length,
            framesAccepted: accepted.length,
            totalIntegrationSecs: accepted.fold<double>(
              0.0,
              (sum, f) => sum + f.exposureDuration,
            ),
          );
        })
        .toList(growable: false);
  }

  /// Group frames by `(targetId, filter)` and build per-filter rollups.
  ///
  /// Frames without a `targetId` are bucketed under a synthetic "Untargeted"
  /// pseudo-target so the report stays exhaustive even for quick-capture
  /// sessions.
  Future<List<SessionTargetReport>> _buildTargetReports(
    List<CapturedImage> lightFrames,
    Map<int, double> scienceSnrById,
  ) async {
    if (lightFrames.isEmpty) return const [];

    // Two-level bucket: targetId? -> filter -> frames.
    final byTarget = <int?, Map<String, List<CapturedImage>>>{};
    for (final frame in lightFrames) {
      final tid = frame.targetId;
      final filter = (frame.filter == null || frame.filter!.isEmpty)
          ? 'Unfiltered'
          : frame.filter!;
      final byFilter = byTarget.putIfAbsent(tid, () => {});
      byFilter.putIfAbsent(filter, () => <CapturedImage>[]).add(frame);
    }

    // Resolve target names in one pass so we don't issue N queries inside
    // the rollup loop.
    final targetNames = <int, String>{};
    final knownIds = byTarget.keys.whereType<int>().toList(growable: false);
    if (knownIds.isNotEmpty) {
      // On a slave the local `targets` table is empty, so resolve names through
      // the remote-aware records repository (host `/api/targets`); otherwise the
      // report shows "Target N" for every imaged object.
      if (_records.isRemote) {
        final remoteNames = await _records.getTargetNamesRemote();
        for (final id in knownIds) {
          final name = remoteNames[id];
          if (name != null) targetNames[id] = name;
        }
      } else {
        final all = await _targetsDao.getAllTargets();
        for (final t in all) {
          if (knownIds.contains(t.id)) {
            targetNames[t.id] = t.name;
          }
        }
      }
    }

    final reports = <SessionTargetReport>[];
    for (final entry in byTarget.entries) {
      final targetId = entry.key;
      final filtersMap = entry.value;
      final filterReports = <SessionFilterReport>[];
      for (final fEntry in filtersMap.entries) {
        filterReports.add(
          _filterReportFromFrames(fEntry.key, fEntry.value, scienceSnrById),
        );
      }
      // Stable order by filter name for diffability between report runs.
      filterReports.sort((a, b) => a.filter.compareTo(b.filter));

      final name = targetId == null
          ? 'Untargeted'
          : (targetNames[targetId] ?? 'Target $targetId');
      reports.add(
        SessionTargetReport(
          targetId: targetId,
          targetName: name,
          filters: filterReports,
        ),
      );
    }

    // Stable display order: targets that share a name fall back to id order.
    reports.sort((a, b) {
      final byName = a.targetName.compareTo(b.targetName);
      if (byName != 0) return byName;
      return (a.targetId ?? -1).compareTo(b.targetId ?? -1);
    });
    return reports;
  }

  /// Build the per-filter rollup for a single `(target, filter)` bucket.
  SessionFilterReport _filterReportFromFrames(
    String filter,
    List<CapturedImage> frames,
    Map<int, double> scienceSnrById,
  ) {
    final attempted = frames.length;
    final accepted = frames.where((f) => f.isAccepted).toList(growable: false);
    final rejected = frames.where((f) => !f.isAccepted).toList(growable: false);

    final totalIntegrationSecs = accepted.fold<double>(
      0.0,
      (sum, f) => sum + f.exposureDuration,
    );

    // Means computed over accepted frames only — rejected frames are
    // usually rejected because their metric is bad, so including them
    // would smear the headline number.
    final meanHfr = _meanNonNull(accepted.map((f) => f.hfr));
    final meanStarCount = _meanNonNull(
      accepted.map((f) => f.starCount?.toDouble()),
    );
    final meanGuidingRmsTotal = _meanNonNull(
      accepted.map((f) => f.guidingRmsTotal),
    );
    final meanSensorTemp = _meanNonNull(accepted.map((f) => f.sensorTemp));

    // SNR: prefer the science pipeline's REAL per-frame SNR when it exists
    // for this filter's accepted frames. Only when the science table has
    // nothing do we fall back to the background/noise PROXY (captured_images
    // stores background mean and noise stddev from the imaging pipeline) —
    // and the report flags which one the number is, because the two scales
    // are not comparable.
    final scienceSnr = <double>[];
    for (final f in accepted) {
      final v = scienceSnrById[f.id];
      if (v != null) scienceSnr.add(v);
    }
    double? meanSnr;
    var snrIsProxy = true;
    if (scienceSnr.isNotEmpty) {
      meanSnr = scienceSnr.reduce((a, b) => a + b) / scienceSnr.length;
      snrIsProxy = false;
    } else {
      final perFrameSnr = <double>[];
      for (final f in accepted) {
        final bg = f.background;
        final n = f.noise;
        if (bg != null && n != null && n > 0) {
          perFrameSnr.add(bg / n);
        }
      }
      meanSnr = perFrameSnr.isEmpty
          ? null
          : perFrameSnr.reduce((a, b) => a + b) / perFrameSnr.length;
    }

    // Bucket rejection reasons. Use a placeholder for null/empty so the UI
    // still shows the count.
    final rejectionReasons = <String, int>{};
    for (final f in rejected) {
      final reason = (f.rejectionReason == null || f.rejectionReason!.isEmpty)
          ? 'Unspecified'
          : f.rejectionReason!;
      rejectionReasons[reason] = (rejectionReasons[reason] ?? 0) + 1;
    }

    return SessionFilterReport(
      filter: filter,
      framesAttempted: attempted,
      framesAccepted: accepted.length,
      framesRejected: rejected.length,
      totalIntegrationSecs: totalIntegrationSecs,
      meanHfr: meanHfr,
      meanFwhm: meanHfr == null ? null : meanHfr * kFwhmPerHfr,
      meanStarCount: meanStarCount,
      meanSnr: meanSnr,
      snrIsProxy: snrIsProxy,
      meanGuidingRmsTotal: meanGuidingRmsTotal,
      meanSensorTemp: meanSensorTemp,
      rejectionReasons: rejectionReasons,
    );
  }

  /// Compute mean ignoring nulls. Returns null when no value is non-null,
  /// otherwise the arithmetic mean of the non-null values.
  double? _meanNonNull(Iterable<double?> values) {
    var sum = 0.0;
    var count = 0;
    for (final v in values) {
      if (v == null) continue;
      sum += v;
      count++;
    }
    if (count == 0) return null;
    return sum / count;
  }

  SessionGuideStats _buildGuideStats(List<CapturedImage> lightFrames) {
    if (lightFrames.isEmpty) {
      return const SessionGuideStats(
        meanRmsRaArcsec: null,
        meanRmsDecArcsec: null,
        meanRmsTotalArcsec: null,
        maxRmsRaArcsec: null,
        maxRmsDecArcsec: null,
        maxRmsTotalArcsec: null,
        percentUnguidedFrames: 1.0,
      );
    }

    double? meanRa;
    double? meanDec;
    double? meanTotal;
    double? maxRa;
    double? maxDec;
    double? maxTotal;
    var raCount = 0;
    var decCount = 0;
    var totalCount = 0;
    var raSum = 0.0;
    var decSum = 0.0;
    var totalSum = 0.0;
    var unguidedFrameCount = 0;

    for (final f in lightFrames) {
      final ra = f.guidingRmsRa;
      final dec = f.guidingRmsDec;
      final total = f.guidingRmsTotal;
      if (ra == null && dec == null && total == null) {
        unguidedFrameCount++;
      }
      if (ra != null) {
        raSum += ra;
        raCount++;
        maxRa = (maxRa == null || ra > maxRa) ? ra : maxRa;
      }
      if (dec != null) {
        decSum += dec;
        decCount++;
        maxDec = (maxDec == null || dec > maxDec) ? dec : maxDec;
      }
      if (total != null) {
        totalSum += total;
        totalCount++;
        maxTotal = (maxTotal == null || total > maxTotal) ? total : maxTotal;
      }
    }

    if (raCount > 0) meanRa = raSum / raCount;
    if (decCount > 0) meanDec = decSum / decCount;
    if (totalCount > 0) meanTotal = totalSum / totalCount;

    final unguidedFraction = unguidedFrameCount / lightFrames.length;

    return SessionGuideStats(
      meanRmsRaArcsec: meanRa,
      meanRmsDecArcsec: meanDec,
      meanRmsTotalArcsec: meanTotal,
      maxRmsRaArcsec: maxRa,
      maxRmsDecArcsec: maxDec,
      maxRmsTotalArcsec: maxTotal,
      percentUnguidedFrames: unguidedFraction,
    );
  }

  /// Pull mount/op counts from any sequence_runs that overlapped the session.
  ///
  /// The sequencer writes per-run stats to `sequence_runs.statsJson`; the
  /// legacy quick-capture path increments `imaging_sessions.autofocusCount`
  /// directly. We take the maximum of the two so neither code path silently
  /// undercounts.
  Future<SessionMountStats> _buildMountStats(ImagingSession session) async {
    final runs = await _findRelatedSequenceRuns(session);
    var autofocus = session.autofocusCount;
    var meridianFlips = 0;
    var dithers = 0;
    var triggers = 0;
    for (final run in runs) {
      final parsed = _tryDecodeStats(run.statsJson);
      if (parsed == null) continue;
      final runAf = (parsed['autofocusRuns'] as num?)?.toInt() ?? 0;
      final runMf = (parsed['meridianFlips'] as num?)?.toInt() ?? 0;
      final runDi = (parsed['ditherCount'] as num?)?.toInt() ?? 0;
      final runTr = (parsed['triggerFires'] as num?)?.toInt() ?? 0;
      if (runAf > autofocus) autofocus = runAf;
      meridianFlips += runMf;
      dithers += runDi;
      triggers += runTr;
    }
    return SessionMountStats(
      autofocusRuns: autofocus,
      meridianFlips: meridianFlips,
      ditherCount: dithers,
      triggerFires: triggers,
    );
  }

  Future<List<String>> _collectErrorMessages(ImagingSession session) async {
    final runs = await _findRelatedSequenceRuns(session);
    final out = <String>[];
    for (final run in runs) {
      final parsed = _tryDecodeStats(run.statsJson);
      if (parsed == null) continue;
      final errors = parsed['errorMessages'];
      if (errors is List) {
        for (final e in errors) {
          if (e is String && e.isNotEmpty) out.add(e);
        }
      }
    }
    return out;
  }

  /// The run's chosen cause and its reject folder, off the same per-run JSON
  /// blob the error and warning lists come from.
  ///
  /// First writer wins for the cause: when a session spans several runs, the
  /// earliest failure is the one that explains the session, exactly as the
  /// earliest fault is the one that explains a run. The reject folder takes the
  /// last, which is the directory the most recent reject actually landed in.
  Future<({String? cause, String? rejectFolder})> _collectFailureFacts(
    ImagingSession session,
  ) async {
    final runs = await _findRelatedSequenceRuns(session);
    String? cause;
    String? rejectFolder;
    for (final run in runs) {
      final parsed = _tryDecodeStats(run.statsJson);
      if (parsed == null) continue;
      final runCause = parsed['terminalCause'];
      if (cause == null && runCause is String && runCause.isNotEmpty) {
        cause = runCause;
      }
      final folder = parsed['rejectFolder'];
      if (folder is String && folder.isNotEmpty) rejectFolder = folder;
    }
    return (cause: cause, rejectFolder: rejectFolder);
  }

  /// Pull non-fatal warnings ([SequenceRunStats.warningMessages]) from
  /// every sequence_run row whose time window overlaps the session.
  /// Mirrors [_collectErrorMessages] so the per-run JSON shape stays
  /// the single source of truth.
  Future<List<String>> _collectWarningMessages(ImagingSession session) async {
    final runs = await _findRelatedSequenceRuns(session);
    final out = <String>[];
    for (final run in runs) {
      final parsed = _tryDecodeStats(run.statsJson);
      if (parsed == null) continue;
      final warnings = parsed['warningMessages'];
      if (warnings is List) {
        for (final w in warnings) {
          if (w is String && w.isNotEmpty) out.add(w);
        }
      }
    }
    return out;
  }

  /// A "related" sequence run is any run whose `startedAt` falls inside the
  /// session window (or whose `endedAt` does, when the run extended past the
  /// session end). This handles both the common case (one run per session)
  /// and the edge case where a session was opened around a chained
  /// sequencer execution.
  ///
  /// Returned oldest first. Both sources hand runs back newest first, and the
  /// callers read this list in time order: the earliest failure is the cause,
  /// the latest reject folder wins, and the error list reads as it happened.
  Future<List<SequenceRun>> _findRelatedSequenceRuns(
    ImagingSession session,
  ) async {
    // On a slave the local `sequence_runs` table is never populated, so reading
    // the DAO yields []  — the mount/op counts and error/warning sections would
    // render a confident-but-false "no flips, no autofocus, no errors". Pull the
    // master's real run history through the remote-aware records repository.
    final allRuns = _records.isRemote
        ? await _records.getAllSequenceRunsRemote()
        : await _sequenceRunsDao.getAllRuns();
    final start = session.startTime;
    final end = session.endTime ?? DateTime.now();
    return allRuns.where((r) {
      final startedIn =
          !r.startedAt.isBefore(start) && !r.startedAt.isAfter(end);
      final endedIn =
          r.endedAt != null &&
          !r.endedAt!.isBefore(start) &&
          !r.endedAt!.isAfter(end);
      return startedIn || endedIn;
    }).toList()..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  }

  Map<String, dynamic>? _tryDecodeStats(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on FormatException {
      // Malformed stats payload — surface as null, not silent zero counts.
      // We intentionally don't throw here because the report should still
      // render for the rest of the session even when one run row is bad.
      return null;
    }
  }

  /// Render the report as Markdown for the "Copy as Markdown" action.
  ///
  /// The Markdown is deterministic — same inputs produce the same output —
  /// so it's safe to diff or attach to a forum post.
  String renderMarkdown(SessionReport report) {
    final buf = StringBuffer();
    String? formatDouble(double? value, int digits) =>
        value?.toStringAsFixed(digits);

    buf.writeln('# Session Report: ${report.sessionName}');
    buf.writeln();
    buf.writeln('- Session ID: ${report.sessionId}');
    buf.writeln('- Status: ${report.status}');
    buf.writeln('- Started: ${report.startTime.toIso8601String()}');
    if (report.endTime != null) {
      buf.writeln('- Ended: ${report.endTime!.toIso8601String()}');
    }
    buf.writeln('- Wall clock: ${DurationFormat.of(report.wallClockDuration)}');
    buf.writeln(
      '- Total integration: ${DurationFormat.of(report.totalIntegration)}',
    );
    buf.writeln(
      '- Effective imaging: ${(report.effectiveImagingFraction * 100).toStringAsFixed(1)}%',
    );
    buf.writeln('- Downtime: ${DurationFormat.of(report.downtime)}');
    buf.writeln(
      '- Frames: ${report.totalFramesAccepted} accepted / ${report.totalFramesAttempted} attempted (${report.totalFramesRejected} rejected)',
    );
    buf.writeln();

    // Conditions.
    if (report.avgTemperatureC != null ||
        report.avgHumidityPercent != null ||
        report.avgSeeingArcsec != null) {
      buf.writeln('## Conditions');
      buf.writeln();
      if (report.avgTemperatureC != null) {
        buf.writeln(
          '- Mean temperature: ${formatDouble(report.avgTemperatureC, 1)} C',
        );
      }
      if (report.avgHumidityPercent != null) {
        buf.writeln(
          '- Mean humidity: ${formatDouble(report.avgHumidityPercent, 1)}%',
        );
      }
      if (report.avgSeeingArcsec != null) {
        buf.writeln(
          '- Mean seeing: ${formatDouble(report.avgSeeingArcsec, 2)} arcsec',
        );
      }
      buf.writeln();
    }

    // Mount + operations stats.
    buf.writeln('## Mount / operations');
    buf.writeln();
    buf.writeln('- Autofocus runs: ${report.mountStats.autofocusRuns}');
    buf.writeln('- Meridian flips: ${report.mountStats.meridianFlips}');
    buf.writeln('- Dithers: ${report.mountStats.ditherCount}');
    buf.writeln('- Trigger fires: ${report.mountStats.triggerFires}');
    buf.writeln();

    // Guide stats.
    buf.writeln('## Guiding');
    buf.writeln();
    final gs = report.guideStats;
    if (gs.isEmpty) {
      buf.writeln('- No guide data recorded for this session.');
    } else {
      buf.writeln(
        '- Mean RA RMS: ${formatDouble(gs.meanRmsRaArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        '- Mean Dec RMS: ${formatDouble(gs.meanRmsDecArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        '- Mean total RMS: ${formatDouble(gs.meanRmsTotalArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        '- Max RA RMS: ${formatDouble(gs.maxRmsRaArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        '- Max Dec RMS: ${formatDouble(gs.maxRmsDecArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        '- Max total RMS: ${formatDouble(gs.maxRmsTotalArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        '- Unguided frames: ${(gs.percentUnguidedFrames * 100).toStringAsFixed(1)}%',
      );
    }
    buf.writeln();

    // Per-target / per-filter breakdown.
    if (report.targets.isEmpty) {
      buf.writeln('## Targets');
      buf.writeln();
      buf.writeln('- No light frames recorded.');
    } else {
      buf.writeln('## Targets');
      buf.writeln();
      for (final target in report.targets) {
        buf.writeln('### ${target.targetName}');
        buf.writeln();
        buf.writeln(
          '| Filter | Attempted | Accepted | Rejected | Integration | Mean HFR | Mean FWHM | Stars | SNR | Guide RMS |',
        );
        buf.writeln(
          '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
        );
        var anyProxySnr = false;
        for (final f in target.filters) {
          final snrCell = f.meanSnr == null
              ? '-'
              : f.snrIsProxy
              ? '${formatDouble(f.meanSnr, 1)} *'
              : formatDouble(f.meanSnr, 1)!;
          anyProxySnr = anyProxySnr || (f.meanSnr != null && f.snrIsProxy);
          buf.writeln(
            '| ${f.filter} | ${f.framesAttempted} | ${f.framesAccepted} | ${f.framesRejected} | ${DurationFormat.of(Duration(milliseconds: (f.totalIntegrationSecs * 1000).round()))} | ${formatDouble(f.meanHfr, 2) ?? '-'} | ${formatDouble(f.meanFwhm, 2) ?? '-'} | ${formatDouble(f.meanStarCount, 0) ?? '-'} | $snrCell | ${formatDouble(f.meanGuidingRmsTotal, 2) ?? '-'} |',
          );
        }
        buf.writeln();
        if (anyProxySnr) {
          buf.writeln(
            '\\* background/noise proxy — the science pipeline did not '
            'compute real SNR for these frames; not comparable to '
            'photometric SNR values.',
          );
          buf.writeln();
        }

        // Rejection rollup, only when there were rejections.
        final rejectionTotals = <String, int>{};
        for (final f in target.filters) {
          for (final entry in f.rejectionReasons.entries) {
            rejectionTotals[entry.key] =
                (rejectionTotals[entry.key] ?? 0) + entry.value;
          }
        }
        if (rejectionTotals.isNotEmpty) {
          buf.writeln('Rejections:');
          final keys = rejectionTotals.keys.toList()..sort();
          for (final k in keys) {
            buf.writeln('- $k: ${rejectionTotals[k]}');
          }
          buf.writeln();
        }
      }
    }

    if (report.errorMessages.isNotEmpty) {
      buf.writeln('## Errors');
      buf.writeln();
      for (final msg in report.errorMessages) {
        buf.writeln('- $msg');
      }
      buf.writeln();
    }

    if (report.warningMessages.isNotEmpty) {
      buf.writeln('## Warnings');
      buf.writeln();
      for (final msg in report.warningMessages) {
        buf.writeln('- $msg');
      }
      buf.writeln();
    }

    if (report.notes != null && report.notes!.isNotEmpty) {
      buf.writeln('## Notes');
      buf.writeln();
      buf.writeln(report.notes);
      buf.writeln();
    }

    buf.writeln('---');
    buf.writeln('Generated ${report.generatedAt.toIso8601String()}');
    return buf.toString();
  }

  /// Render as a plain-text (.txt) report — same content as the Markdown
  /// renderer, but without Markdown syntax. Used by the "Export to .txt"
  /// action.
  String renderPlainText(SessionReport report) {
    String? formatDouble(double? value, int digits) =>
        value?.toStringAsFixed(digits);

    final buf = StringBuffer();
    buf.writeln('=' * 60);
    buf.writeln('Skotiq Session Report');
    buf.writeln('=' * 60);
    buf.writeln('Session: ${report.sessionName} (id ${report.sessionId})');
    buf.writeln('Status: ${report.status}');
    buf.writeln('Started: ${report.startTime}');
    if (report.endTime != null) {
      buf.writeln('Ended: ${report.endTime}');
    }
    buf.writeln('Wall clock: ${DurationFormat.of(report.wallClockDuration)}');
    buf.writeln(
      'Total integration: ${DurationFormat.of(report.totalIntegration)}',
    );
    buf.writeln(
      'Effective imaging: ${(report.effectiveImagingFraction * 100).toStringAsFixed(1)}%',
    );
    buf.writeln('Downtime: ${DurationFormat.of(report.downtime)}');
    buf.writeln(
      'Frames: ${report.totalFramesAccepted} accepted / ${report.totalFramesAttempted} attempted (${report.totalFramesRejected} rejected)',
    );
    buf.writeln();

    buf.writeln('-- Mount / operations --');
    buf.writeln('Autofocus runs: ${report.mountStats.autofocusRuns}');
    buf.writeln('Meridian flips: ${report.mountStats.meridianFlips}');
    buf.writeln('Dithers: ${report.mountStats.ditherCount}');
    buf.writeln('Trigger fires: ${report.mountStats.triggerFires}');
    buf.writeln();

    buf.writeln('-- Guiding --');
    final gs = report.guideStats;
    if (gs.isEmpty) {
      buf.writeln('No guide data recorded.');
    } else {
      buf.writeln(
        'Mean RA RMS:   ${formatDouble(gs.meanRmsRaArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        'Mean Dec RMS:  ${formatDouble(gs.meanRmsDecArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        'Mean Tot RMS:  ${formatDouble(gs.meanRmsTotalArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        'Max RA RMS:    ${formatDouble(gs.maxRmsRaArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        'Max Dec RMS:   ${formatDouble(gs.maxRmsDecArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        'Max Tot RMS:   ${formatDouble(gs.maxRmsTotalArcsec, 2) ?? '-'} arcsec',
      );
      buf.writeln(
        'Unguided:      ${(gs.percentUnguidedFrames * 100).toStringAsFixed(1)}%',
      );
    }
    buf.writeln();

    buf.writeln('-- Targets --');
    if (report.targets.isEmpty) {
      buf.writeln('No light frames recorded.');
    } else {
      for (final target in report.targets) {
        buf.writeln('  ${target.targetName}:');
        for (final f in target.filters) {
          buf.writeln(
            '    [${f.filter}] ${f.framesAccepted}/${f.framesAttempted} frames, '
            '${DurationFormat.of(Duration(milliseconds: (f.totalIntegrationSecs * 1000).round()))} integration, '
            'HFR ${formatDouble(f.meanHfr, 2) ?? '-'}, '
            'FWHM ${formatDouble(f.meanFwhm, 2) ?? '-'}, '
            'stars ${formatDouble(f.meanStarCount, 0) ?? '-'}, '
            'SNR ${formatDouble(f.meanSnr, 1) ?? '-'}, '
            'guide ${formatDouble(f.meanGuidingRmsTotal, 2) ?? '-'}',
          );
          if (f.rejectionReasons.isNotEmpty) {
            final reasons = f.rejectionReasons.entries
                .map((e) => '${e.key}=${e.value}')
                .join(', ');
            buf.writeln('       rejections: $reasons');
          }
        }
      }
    }
    buf.writeln();

    if (report.errorMessages.isNotEmpty) {
      buf.writeln('-- Errors --');
      for (final msg in report.errorMessages) {
        buf.writeln('  * $msg');
      }
      buf.writeln();
    }

    if (report.warningMessages.isNotEmpty) {
      buf.writeln('-- Warnings --');
      for (final msg in report.warningMessages) {
        buf.writeln('  * $msg');
      }
      buf.writeln();
    }

    if (report.notes != null && report.notes!.isNotEmpty) {
      buf.writeln('-- Notes --');
      buf.writeln(report.notes);
      buf.writeln();
    }

    buf.writeln('Generated: ${report.generatedAt}');
    return buf.toString();
  }
}
