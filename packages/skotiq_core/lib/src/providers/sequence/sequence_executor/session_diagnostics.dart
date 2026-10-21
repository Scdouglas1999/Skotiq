import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/equipment/equipment_models.dart';
import '../../../services/logging_service.dart';
import '../../../services/optical_train_diagnostics_service.dart'
    show OpticalTrainDiagnostics;
import '../../../services/smart_night/guide_rms_collector.dart';
import '../../database_provider.dart'
    show guideRmsHistoryDaoProvider, imagesDaoProvider;
import '../../equipment_provider.dart';
import '../../flat_wizard_provider.dart' show skyBrightnessTrackerProvider;
import '../../notification_router_provider.dart';
import '../../imaging_provider.dart' show temperatureHistoryProvider;
import '../../optical_train_diagnostics_provider.dart';
import '../../preflight_providers.dart';
import '../../profiles_provider.dart';
import '../../recovery_provider.dart' show recoveryHistoryProvider;
import '../../science_provider.dart'
    show sessionPsfTilesProvider, sessionResidualVectorsProvider;
import '../../sequence_stats_provider.dart';
import '../../session_provider.dart';
import '../../usb_disconnect_log_provider.dart';

/// Temperature drift threshold for post-session cooler stability notes.
///
/// A one-degree band is tight enough to catch a cooler that is cycling or
/// saturated, while avoiding noise from normal sub-degree sensor wobble.
const double kCoolerSetpointBandDegC = 1.0;

/// The diagnostics a run captures at its start and publishes at its end:
/// the notification router's active-sequence override, the optical-train
/// baseline and drift, the post-session health summary, the per-session
/// diagnostics row and the Smart Night guide-RMS history.
///
/// It holds the run's identity between the two hooks, so the end hook still
/// knows which run finished after the UI has cleared the loaded sequence.
class SessionDiagnostics {
  SessionDiagnostics({
    required Ref ref,
    required LoggingService Function() logger,
  }) : _ref = ref,
       _loggerFn = logger;

  final Ref _ref;
  final LoggingService Function() _loggerFn;
  LoggingService get _logger => _loggerFn();

  String? _activeSequenceId;

  /// Wall-clock start of the run, which scopes the disconnect and cooler
  /// counts in the summary.
  DateTime? _sessionStartedAt;

  /// The optical-train snapshot taken at the start, published beside the
  /// post-session one.
  OpticalTrainBaseline? _sessionStartBaseline;

  /// Record the run's identity, register it with the notification router and
  /// capture the optical-train baseline. Each hook is independent, and none
  /// may block imaging.
  void captureStart(String sequenceId) {
    _activeSequenceId = sequenceId;
    _sessionStartedAt = DateTime.now();

    // Notification router active-sequence override.
    try {
      final router = _ref.read(notificationRouterProvider);
      router.setActiveSequence(sequenceId);
      _logger.debug(
        'NotificationRouter.setActiveSequence($sequenceId) at session start',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      // Notification setup failure must never block imaging — log and
      // continue. The user gets a working sequence with global routing
      // rules instead of per-sequence overrides.
      _logger.warning(
        'Failed to register active sequence with NotificationRouter: $e\n$st',
        source: 'SequenceExecutor',
      );
    }

    // Optical-train baseline capture.
    try {
      final baseline = _captureOpticalTrainBaseline();
      if (baseline == null) {
        _logger.info(
          'Optical-train diagnostics unavailable at session start '
          '(no PSF tiles or solved frames yet); baseline will be '
          'captured at session end instead.',
          source: 'SequenceExecutor',
        );
      } else {
        _sessionStartBaseline = baseline;
        // Push to both the baseline provider (pre-flight comparison
        // source) and the current-snapshot provider (so the live
        // dashboard reflects the start-of-run state until a fresh
        // snapshot supersedes it mid-run).
        _ref.read(opticalTrainBaselineProvider.notifier).state = baseline;
        _ref.read(opticalTrainCurrentSnapshotProvider.notifier).state =
            baseline;
        _logger.debug(
          'Captured optical-train baseline at session start: '
          'tilt=${baseline.tiltScore.toStringAsFixed(1)}, '
          'collimation=${baseline.collimationScore.toStringAsFixed(1)}',
          source: 'SequenceExecutor',
        );
      }
    } catch (e, st) {
      _logger.warning(
        'Failed to capture optical-train baseline at session start: $e\n$st',
        source: 'SequenceExecutor',
      );
    }
  }

  /// Publish the post-session diagnostics and clear the notification router
  /// override. Called once per run by finalization; a no-op when the start
  /// hooks never ran (a launch that failed before them).
  void captureEnd() {
    final sequenceId = _activeSequenceId;
    final sessionStart = _sessionStartedAt;

    if (sequenceId == null) {
      // start() never finished its hooks (the run aborted before the
      // session-start phase). Nothing to tear down.
      _logger.debug(
        'Skipping session-end hooks: no active sequence id recorded',
        source: 'SequenceExecutor',
      );
      return;
    }

    // Notification router clear.
    try {
      final router = _ref.read(notificationRouterProvider);
      router.setActiveSequence(null);
      _logger.debug(
        'NotificationRouter.setActiveSequence(null) at session end '
        '(was: $sequenceId)',
        source: 'SequenceExecutor',
      );
    } catch (e) {
      _logger.warning(
        'Failed to clear active sequence on NotificationRouter: $e',
        source: 'SequenceExecutor',
      );
    }

    // Optical-train post-session snapshot + drift.
    OpticalTrainBaseline? postSnapshot;
    try {
      // The full analysis is carried, not rebuilt from the snapshot: a
      // rebuilt one would default the `tiltMeasured` / `collimationMeasured`
      // flags open and turn "never measured" into "measured at 0".
      final postDiagnostics = _analyzeOpticalTrain();
      postSnapshot = postDiagnostics == null
          ? null
          : OpticalTrainBaseline.fromDiagnostics(postDiagnostics);
      if (postSnapshot != null && postDiagnostics != null) {
        _ref.read(opticalTrainCurrentSnapshotProvider.notifier).state =
            postSnapshot;
        // The post-session snapshot is the next session's baseline.
        _ref.read(opticalTrainBaselineProvider.notifier).state = postSnapshot;
        if (_sessionStartBaseline != null) {
          // An unmeasured axis scores a placeholder 0, so drift is quoted
          // only when both axes were measured.
          if (postDiagnostics.tiltMeasured &&
              postDiagnostics.collimationMeasured) {
            final drift = _sessionStartBaseline!.driftAgainst(postDiagnostics);
            _logger.info(
              'Optical-train drift vs. session-start baseline: '
              '${drift.toStringAsFixed(2)} (tilt '
              '${_sessionStartBaseline!.tiltScore.toStringAsFixed(1)} → '
              '${postSnapshot.tiltScore.toStringAsFixed(1)}, '
              'collimation '
              '${_sessionStartBaseline!.collimationScore.toStringAsFixed(1)} → '
              '${postSnapshot.collimationScore.toStringAsFixed(1)})',
              source: 'SequenceExecutor',
            );
          } else {
            _logger.info(
              'Optical-train drift vs. session-start baseline not computed: '
              '${_unmeasuredOpticalAxes(postDiagnostics)} was not measured '
              'this session, so the pre/post comparison would subtract '
              'placeholder zeros.',
              source: 'SequenceExecutor',
            );
          }
        }
        _logger.debug(
          'Captured optical-train post-session snapshot: '
          'tilt=${postSnapshot.tiltScore.toStringAsFixed(1)}, '
          'collimation=${postSnapshot.collimationScore.toStringAsFixed(1)}',
          source: 'SequenceExecutor',
        );
      } else {
        // No data at the end: show the start baseline rather than a
        // previous run's snapshot.
        if (_sessionStartBaseline != null) {
          _ref.read(opticalTrainCurrentSnapshotProvider.notifier).state =
              _sessionStartBaseline;
        }
        _logger.info(
          'Optical-train diagnostics unavailable at session end; '
          'post-session diagnostics will omit drift comparison.',
          source: 'SequenceExecutor',
        );
      }
    } catch (e, st) {
      _logger.warning(
        'Failed to capture optical-train post-session snapshot: $e\n$st',
        source: 'SequenceExecutor',
      );
    }

    // Post-session health summary.
    try {
      final dbSessionId = _ref.read(sessionStateProvider).dbSessionId;
      if (dbSessionId == null) {
        _logger.info(
          'No active database session id at end of run; '
          'post-session diagnostics summary will not be published.',
          source: 'SequenceExecutor',
        );
      } else {
        final summary = _buildPostSessionHealthSummary(
          sessionStartedAt: sessionStart,
        );
        _ref
                .read(postSessionHealthSummaryProvider(dbSessionId).notifier)
                .state =
            summary;
        _logger.debug(
          'Published post-session diagnostics for session $dbSessionId: '
          'disconnects=${summary.disconnectsDuringSession}, '
          'focuserMoves=${summary.focuserMoves}, '
          'noticedConcerns=${summary.noticedConcerns.length}',
          source: 'SequenceExecutor',
        );
      }
    } catch (e, st) {
      _logger.warning(
        'Failed to publish post-session diagnostics: $e\n$st',
        source: 'SequenceExecutor',
      );
    }

    // Recovery history and the optical-train snapshots live in providers the
    // next run overwrites; persisting them per session lets a historical
    // report reload this session's values.
    try {
      final dbSessionId = _ref.read(sessionStateProvider).dbSessionId;
      if (dbSessionId != null) {
        final recoveries = _ref.read(recoveryHistoryProvider);
        final recoveryHistoryJson = jsonEncode(
          recoveries.map((e) => e.toJson()).toList(),
        );
        final baselineJson = _sessionStartBaseline == null
            ? null
            : jsonEncode(_sessionStartBaseline!.toJson());
        final currentJson = postSnapshot == null
            ? null
            : jsonEncode(postSnapshot.toJson());
        // Captured now: the deferred catchError can run after the container
        // is disposed.
        final logger = _logger;
        unawaited(
          _ref
              .read(sessionDiagnosticsDaoProvider)
              .upsert(
                sessionId: dbSessionId,
                recoveryHistoryJson: recoveryHistoryJson,
                opticalTrainBaselineJson: baselineJson,
                opticalTrainCurrentJson: currentJson,
              )
              .catchError((Object e, StackTrace st) {
                logger.warning(
                  'Failed to persist per-session diagnostics: $e\n$st',
                  source: 'SequenceExecutor',
                );
              }),
        );
      }
    } catch (e, st) {
      _logger.warning(
        'Failed to schedule per-session diagnostics persistence: $e\n$st',
        source: 'SequenceExecutor',
      );
    }

    // Smart Night guide-RMS history.
    try {
      final dbSessionId = _ref.read(sessionStateProvider).dbSessionId;
      if (dbSessionId != null) {
        final mountState = _ref.read(mountStateProvider);
        final profileMountId = _ref
            .read(activeEquipmentProfileProvider)
            ?.mountId;
        final mountId =
            mountState.connectionState == DeviceConnectionState.connected
            ? mountState.deviceId
            : profileMountId;
        final collector = GuideRmsCollector(
          imagesDao: _ref.read(imagesDaoProvider),
          guideRmsHistoryDao: _ref.read(guideRmsHistoryDaoProvider),
        );
        // Captured now, as above.
        final logger = _logger;
        unawaited(
          collector
              .collectSession(
                sessionId: dbSessionId,
                mountId: mountId,
                recordedAt: DateTime.now(),
              )
              .catchError((Object e, StackTrace st) {
                logger.warning(
                  'Failed to collect Smart Night guide-RMS history: $e\n$st',
                  source: 'SequenceExecutor',
                );
                return null;
              }),
        );
      }
    } catch (e, st) {
      _logger.warning(
        'Failed to schedule Smart Night guide-RMS collection: $e\n$st',
        source: 'SequenceExecutor',
      );
    }

    // Reset for the next run, now that the hooks above have used them.
    _activeSequenceId = null;
    _sessionStartedAt = null;
    _sessionStartBaseline = null;
  }

  /// Live optical-train analysis for the active session, or `null` when
  /// there is nothing to analyse (no live session, no PSF tiles).
  ///
  /// Uses the same data path as the analytics tab so the values shown
  /// in the History dialog match the live dashboard — pulled directly
  /// from the PSF / residual provider streams rather than re-running
  /// the analysis on raw FITS files.
  ///
  /// Returns the whole [OpticalTrainDiagnostics] rather than the
  /// [OpticalTrainBaseline] it collapses into: the baseline keeps only the two
  /// penalty scores, and a penalty of 0 is simultaneously "perfectly flat
  /// field" and "nothing measured it". Anything that states a verdict needs
  /// `tiltMeasured` / `collimationMeasured` from here.
  OpticalTrainDiagnostics? _analyzeOpticalTrain() {
    final dbSessionId = _ref.read(sessionStateProvider).dbSessionId;
    if (dbSessionId == null) return null;
    final psfTiles =
        _ref.read(sessionPsfTilesProvider(dbSessionId)).valueOrNull ?? const [];
    final residuals =
        _ref.read(sessionResidualVectorsProvider(dbSessionId)).valueOrNull ??
        const [];
    if (psfTiles.isEmpty) {
      // Nothing solved yet — calling analyze() would emit the
      // "No diagnostics data" placeholder, which has tilt=0 and
      // collimation=0 and would look like a "zero drift" baseline.
      // Returning null preserves the honest "no data" signal.
      return null;
    }
    final service = _ref.read(opticalTrainDiagnosticsServiceProvider);
    return service.analyze(psfTiles: psfTiles, residualVectors: residuals);
  }

  /// Snapshot the live optical-train diagnostics for the active session
  /// and convert to an [OpticalTrainBaseline]. Returns `null` when no
  /// diagnostics data is available (no solved frames yet, no PSF
  /// tiles, no live session).
  OpticalTrainBaseline? _captureOpticalTrainBaseline() {
    final diagnostics = _analyzeOpticalTrain();
    if (diagnostics == null) return null;
    return OpticalTrainBaseline.fromDiagnostics(diagnostics);
  }

  /// Names the axes [diagnostics] could not measure, for log lines that would
  /// otherwise quote a score derived from them.
  String _unmeasuredOpticalAxes(OpticalTrainDiagnostics diagnostics) {
    if (!diagnostics.tiltMeasured && !diagnostics.collimationMeasured) {
      return 'neither field tilt nor collimation';
    }
    return diagnostics.tiltMeasured ? 'collimation' : 'field tilt';
  }

  /// Build the post-session diagnostics summary from the run stats +
  /// USB disconnect log.
  ///
  /// USB disconnects are scoped to THIS run, not the rolling 24 h window: the
  /// operator already saw earlier flakes the last time they opened the report.
  ///
  /// [PostSessionHealthSummary.noticedConcerns] is reserved for concerns the
  /// report does not already state — anything added there must not exist in
  /// `SequenceRunStats.warningMessages`, which the Session Report already
  /// prints verbatim in its own "Warnings" section.
  PostSessionHealthSummary _buildPostSessionHealthSummary({
    DateTime? sessionStartedAt,
  }) {
    final stats = _ref.read(liveSequenceStatsProvider);
    final disconnectLog = _ref.read(usbDisconnectLogProvider);

    final disconnectsDuringSession = sessionStartedAt == null
        ? disconnectLog.totalLast24h()
        : disconnectLog.countSince(sessionStartedAt);

    final focuserMoves = stats?.autofocusRuns ?? 0;

    final skyStats = _skyBrightnessSummarySince(sessionStartedAt);

    return PostSessionHealthSummary(
      disconnectsDuringSession: disconnectsDuringSession,
      coolerOutOfBandSamples: _coolerOutOfBandSamplesSince(sessionStartedAt),
      focuserMoves: focuserMoves,
      skyBrightnessMin: skyStats?.min,
      skyBrightnessMax: skyStats?.max,
      skyBrightnessMedian: skyStats?.median,
    );
  }

  int _coolerOutOfBandSamplesSince(DateTime? sessionStartedAt) {
    final history = _ref.read(temperatureHistoryProvider);
    var count = 0;
    for (final point in history) {
      if (sessionStartedAt != null && point.time.isBefore(sessionStartedAt)) {
        continue;
      }
      final target = point.targetTemp;
      if (target == null) continue;
      if ((point.temperature - target).abs() > kCoolerSetpointBandDegC) {
        count++;
      }
    }
    return count;
  }

  ({double min, double max, double median})? _skyBrightnessSummarySince(
    DateTime? sessionStartedAt,
  ) {
    final samples =
        _ref
            .read(skyBrightnessTrackerProvider)
            .magSamplesSince(sessionStartedAt)
            .where((value) => value.isFinite)
            .toList()
          ..sort();
    if (samples.isEmpty) return null;

    final mid = samples.length ~/ 2;
    final median = samples.length.isOdd
        ? samples[mid]
        : (samples[mid - 1] + samples[mid]) / 2.0;
    return (min: samples.first, max: samples.last, median: median);
  }
}
