/// Service wiring for the Night Narrator.
///
/// The service is the *stateful, session-scoped* sibling of the stateless
/// `ScienceProcessingService`, kept alive alongside the active session by
/// `narratorServiceProvider`. It subscribes (PULL) to the providers the rest of
/// the pipeline already publishes — session science products, the captured-image
/// stream, guiding stats, weather, SQM, autofocus, period analysis, optical-train
/// diagnostics, and the science status stream — and on each update assembles an
/// immutable [NarratorContext], runs the [NarratorEngine], and persists accepted
/// drafts through the [NarratorEventsDao].
///
/// **Pull over push.** Every input is read from a provider the pipeline already
/// maintains, so there is no producer-side coupling to keep in sync. The
/// captured-image stream alone supplies per-frame HFR / star-count / focuser
/// temperature, the auto-grader accept/reject history, the plate-solve history,
/// and per-filter integration totals — all of which the pipeline already writes
/// to the image row. The sessionless capture path uses the same device streams
/// (guiding, weather, autofocus, last-image stats, period analysis); the small
/// imperative `ingest*` / `set*` hooks are test-only seams (`@visibleForTesting`)
/// and have no production callers.
///
/// **Degrades gracefully.** Every input is optional. A session with no guiding,
/// no weather, no SQM, no focuser, or science disabled simply leaves those
/// context fields empty and the dependent detectors never fire. Nothing here
/// throws on a missing stream or device.
library;

import 'dart:async';
import 'dart:collection';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../database/database.dart' as db;
import '../../../database/daos/narrator_events_dao.dart';
import '../../../models/science/science_models.dart'
    show LightCurvePoint, MovingObjectCandidate, TransparencyTrendPoint;
import '../../../providers/autofocus_progress_provider.dart';
import '../../../providers/database_provider.dart';
import '../../../models/equipment/equipment_models.dart'
    show DeviceConnectionState;
import '../../../models/imaging/imaging_models.dart' show ImageStats;
import '../../../providers/equipment_provider.dart'
    show focuserStateProvider, weatherStateProvider;
import '../../../providers/guiding_provider.dart' show guideStatsProvider;
import '../../../providers/narrator_provider.dart'
    show sessionFilterIntegrationProvider, sessionImagesStreamProvider;
import '../../../providers/optical_train_diagnostics_provider.dart';
import '../../../providers/imaging_provider.dart' show lastImageStatsProvider;
import '../../../providers/period_analysis_provider.dart';
import '../../../providers/science_provider.dart';
import '../../../providers/science_status_provider.dart';
import '../../../providers/weather_providers.dart'
    show cloudCoverPercentageProvider;
import '../../../providers/weather_safety_provider.dart';
import '../../logging_service.dart';
import '../../optical_train_diagnostics_service.dart'
    show OpticalTrainDiagnostics;
import '../../transients/transient_candidate.dart' show TransientCandidate;
import '../period_analysis_service.dart' show PeriodAnalysisResult;
import '../science_status.dart' show ScienceStageOutcome, ScienceStageResult;
import 'narrator_context.dart';
import 'narrator_detectors.dart';
import 'narrator_engine.dart';
import 'narrator_event.dart';

/// Caps on the rolling per-input history the service keeps in memory between
/// context builds. Generous enough for every detector's window; bounded so a
/// long unattended night never grows unbounded.
const int _kImageStatsCap = 400;
const int _kGradeEventsCap = 200;
const int _kSolveHistoryCap = 200;
const int _kSkySamplesCap = 400;
const int _kGuideRmsCap = 400;
const int _kTransientCandidatesCap = 200;

/// A cloud-cover percentage at/above this reads as "cloudy" for the
/// clouds-vs-focus disambiguation when no other signal is available.
const double _kCloudyCoverPercent = 50.0;

class NarratorService {
  final Ref _ref;
  final int? _sessionId;
  final NarratorEngine _engine;

  // Pushed inputs (hooks) — also populated by the pulled streams below.
  final Queue<NarratorImageStats> _imageStats = Queue<NarratorImageStats>();
  final Queue<NarratorGradeEvent> _gradeEvents = Queue<NarratorGradeEvent>();
  final Queue<bool> _solveHistory = Queue<bool>();
  final Queue<NarratorSkySample> _skySamples = Queue<NarratorSkySample>();
  final Queue<double> _guideRmsHistory = Queue<double>();

  // First Light (Pillar B) cross-matched candidates fed by the difference-image
  // scan. The narrator's transient detectors read this on the next context
  // build; the buffer is the only path that ever populates
  // `NarratorContext.transientCandidates`.
  final Queue<TransientCandidate> _transientCandidates =
      Queue<TransientCandidate>();

  // Pulled inputs (last-known snapshots).
  List<NarratorPeriodResult> _periodResults = const [];
  NarratorWeatherState? _weather;
  double? _autofocusHfrBaseline;
  ScienceStageResult? _lastStageFailure;
  String? _lastStageFailureKey;

  // De-dupe latches for the captured-image-stream derivations so a stream
  // re-emission (drift re-runs the query on any image-table write) does not
  // re-append the same frame's stats/grade/solve.
  final Set<int> _seenStatsImageIds = <int>{};
  final Set<int> _seenGradeImageIds = <int>{};
  final Set<int> _seenSolveImageIds = <int>{};
  int? _lastObservedImageId;

  // Latest per-frame FWHM from `lastImageStatsProvider` (not persisted on the
  // image row), stamped onto the next image-stats entry derived from the stream.
  double? _pendingFwhm;
  // Sessionless only: the last `ImageStats` object already ingested. Compared by
  // IDENTITY, not equality — `lastImageStatsProvider` hands out a fresh object
  // per frame, so identity never drops a genuine frame, whereas two frames of
  // the same target can legitimately measure equal and would be swallowed.
  ImageStats? _lastSessionlessStats;
  // Latest period-analysis result already announced, to avoid re-feeding.
  PeriodAnalysisResult? _lastPeriodResult;

  final List<ProviderSubscription> _subs = <ProviderSubscription>[];

  // Retained subscription to the optical-train diagnostics provider. That
  // provider is `Provider.autoDispose.family`, so a bare `_ref.read` returns
  // `AsyncValue.loading()` and immediately disposes (churning two DB-watch
  // streams per build). Holding the subscription keeps it alive and lets us
  // read the latest value via `valueOrNull`.
  ProviderSubscription<AsyncValue<OpticalTrainDiagnostics>>? _diagnosticsSub;

  // Retained subscription to the active light-curve target. The light-curve
  // subscription is rebound when this changes so updates follow the new target.
  String? _boundObjectId;
  ProviderSubscription<List<LightCurvePoint>>? _lightCurveSub;

  bool _disposed = false;
  DateTime Function() _clock = DateTime.now;

  NarratorService(this._ref, {required int? sessionId, NarratorEngine? engine})
    : _sessionId = sessionId,
      _engine = engine ?? buildDefaultNarratorEngine();

  LoggingService get _logger => _ref.read(loggingServiceProvider);
  NarratorEventsDao get _dao => _ref.read(narratorEventsDaoProvider);

  /// Override the clock (tests). Production uses [DateTime.now].
  // ignore: use_setters_to_change_properties
  void setClock(DateTime Function() clock) => _clock = clock;

  /// Start subscribing to provider streams. Restart safety: the engine's
  /// in-memory dedupe set is pre-seeded from the DB so an ongoing episode does
  /// not re-fire as a duplicate card after a mid-session relaunch (the
  /// per-eventType cooldowns are the second gate). [NarratorEventsDao.hasDedupeKey]
  /// remains the durable persist-time guard.
  Future<void> start() async {
    try {
      final seeded = await _dao.dedupeKeysForSession(_sessionId);
      if (!_disposed) _engine.seedDedupeKeys(seeded);
    } catch (error) {
      _logger.debug(
        'Narrator dedupe-key seed failed: $error',
        source: 'NarratorService',
      );
    }
    if (_disposed) return;
    _bindStreams();
  }

  void _bindStreams() {
    // Device-/session-agnostic streams that work even for sessionless captures.
    _bindGuiding();
    _bindWeather();
    _bindAutofocus();
    _bindLastImageStats();
    _bindPeriodAnalysis();
    // Science stage results are not session-scoped (the provider is a plain
    // global), so this listener stays ABOVE the early return: below it, a
    // hand-driven night never hears about a completed stage.
    _subs.add(
      _ref.listen(scienceProcessingLatestStageProvider, (_, next) {
        _onStageResult(next);
      }, fireImmediately: false),
    );

    if (_sessionId == null) {
      // Sessionless captures still get the per-frame pushed detectors and the
      // device streams above; the session-scoped provider streams below have
      // nothing to bind to.
      return;
    }
    final sessionId = _sessionId;

    _subs.add(
      _ref.listen(sessionFrameCalibrationsProvider(sessionId), (_, __) {
        _onUpdate();
      }, fireImmediately: false),
    );
    _subs.add(
      _ref.listen(sessionTransparencyTrendProvider(sessionId), (_, __) {
        _onUpdate();
      }, fireImmediately: false),
    );
    _subs.add(
      _ref.listen(sessionFrameQualityMetricsProvider(sessionId), (_, __) {
        _onUpdate();
      }, fireImmediately: false),
    );
    _subs.add(
      _ref.listen(sessionMovingObjectTrendProvider(sessionId), (_, __) {
        _onUpdate();
      }, fireImmediately: false),
    );
    // The light-curve subscription must follow the active photometry target;
    // bind it now and rebind it whenever the active target changes.
    _bindLightCurve(sessionId);
    _subs.add(
      _ref.listen(activePhotometryTargetObjectIdProvider, (_, __) {
        _bindLightCurve(sessionId);
        _onUpdate();
      }, fireImmediately: false),
    );
    // Optical-train diagnostics — kept alive by a retained subscription (the
    // provider is autoDispose; a bare read would dispose immediately and never
    // surface a value). Re-evaluate on each diagnostics update.
    _diagnosticsSub = _ref.listen(
      opticalTrainDiagnosticsProvider(sessionId),
      (_, __) => _onUpdate(),
      fireImmediately: true,
    );
    _subs.add(_diagnosticsSub!);
    // The captured-image stream is the single pull source for per-frame image
    // stats (HFR / star count / focuser temp), the auto-grader accept/reject
    // history, and the plate-solve history — all already written to the row.
    _subs.add(
      _ref.listen<AsyncValue<List<db.CapturedImage>>>(
        sessionImagesStreamProvider(sessionId),
        (_, next) => _onImagesChanged(next.valueOrNull ?? const []),
        fireImmediately: true,
      ),
    );
    // Per-filter integration totals (accepted light-frame seconds).
    _subs.add(
      _ref.listen(sessionFilterIntegrationProvider(sessionId), (_, __) {
        _onUpdate();
      }, fireImmediately: false),
    );
  }

  String _objectId() {
    try {
      return _ref.read(activePhotometryTargetObjectIdProvider);
    } catch (_) {
      return 'target_primary';
    }
  }

  /// (Re)bind the light-curve subscription to the currently-active photometry
  /// target. Closing and re-adding the single subscription keeps it tracking
  /// the live target so updates for the new target wake the service.
  void _bindLightCurve(int sessionId) {
    final objectId = _objectId();
    if (_lightCurveSub != null && objectId == _boundObjectId) return;
    if (_lightCurveSub != null) {
      _lightCurveSub!.close();
      _subs.remove(_lightCurveSub);
    }
    _boundObjectId = objectId;
    _lightCurveSub = _ref.listen(
      sessionLightCurveProvider((sessionId, objectId)),
      (_, __) => _onUpdate(),
      fireImmediately: false,
    );
    _subs.add(_lightCurveSub!);
  }

  // ── Pulled device streams ─────────────────────────────────────────────────

  void _bindGuiding() {
    _subs.add(
      _ref.listen(guideStatsProvider, (_, next) {
        final rms = next.rmsTotal;
        if (rms.isFinite && rms > 0) {
          _push(_guideRmsHistory, rms, _kGuideRmsCap);
          _onUpdate();
        }
      }, fireImmediately: true),
    );
  }

  void _bindWeather() {
    void refreshWeather() {
      _weather = _readWeather();
      _onUpdate();
    }

    _subs.add(_ref.listen(weatherSafetyProvider, (_, __) => refreshWeather()));
    _subs.add(_ref.listen(weatherStateProvider, (_, __) => refreshWeather()));
    _subs.add(
      _ref.listen(cloudCoverPercentageProvider, (_, __) => refreshWeather()),
    );
    refreshWeather();
  }

  NarratorWeatherState? _readWeather() {
    try {
      double? coverPercent =
          _ref.read(weatherStateProvider).cloudCover ??
          _ref.read(cloudCoverPercentageProvider).valueOrNull;
      // The weather-safety verdict is a device-independent "is the sky usable"
      // signal; treat an active unsafe/alert state as cloudy too.
      final safety = _ref.read(weatherSafetyProvider);
      final unsafe = !safety.isSafe || !safety.apiWeatherSafe;
      final cloudyByCover =
          coverPercent != null && coverPercent >= _kCloudyCoverPercent;
      if (coverPercent == null && !unsafe) return null;
      return NarratorWeatherState(
        cloudy: cloudyByCover || unsafe,
        cloudCoverPercent: coverPercent,
      );
    } catch (_) {
      return null;
    }
  }

  void _bindAutofocus() {
    _subs.add(
      _ref.listen(autofocusOverlayProvider, (_, next) {
        final result = next.result;
        if (result == null) return;
        final hfr = result.bestHfr;
        if (hfr.isFinite && hfr > 0 && hfr != _autofocusHfrBaseline) {
          _autofocusHfrBaseline = hfr;
          _onUpdate();
        }
      }, fireImmediately: true),
    );
  }

  void _bindLastImageStats() {
    _subs.add(
      _ref.listen(lastImageStatsProvider, (_, next) {
        final fwhm = next?.fwhm;
        if (fwhm != null && fwhm.isFinite && fwhm > 0) {
          _pendingFwhm = fwhm;
        }
        if (_sessionId == null) _ingestSessionlessStats(next);
      }, fireImmediately: true),
    );
  }

  /// Turn a hand-driven frame into a narrator image-stats sample.
  ///
  /// Without this the sessionless bucket has no producer at all. `_imageStats`,
  /// and therefore every quality, focus-drift and milestone detector, is filled
  /// only by [_onImagesChanged], which hangs off `sessionImagesStreamProvider`
  /// and so is never bound when there is no DB session. The strip was pointed at
  /// the sessionless feed and the feed stayed empty: an operator shooting by
  /// hand for an hour saw nothing, which is exactly the complaint.
  ///
  /// `_pendingFwhm` is deliberately left alone here. It is consumed by
  /// [_onImagesChanged] to stamp a FWHM onto the newest row of the session
  /// stream; sessionless there is no such row, and the FWHM is already on the
  /// sample being built below.
  void _ingestSessionlessStats(ImageStats? stats) {
    if (_disposed || stats == null) return;
    if (identical(stats, _lastSessionlessStats)) return;
    _lastSessionlessStats = stats;

    final hfr = stats.hfr;
    final fwhm = stats.fwhm;
    final starCount = stats.starCount;
    // A frame that measured nothing says nothing. Pushing an all-null sample
    // would pad the queue and let a detector average over holes.
    if (hfr == null && fwhm == null && starCount == null) return;

    _push(
      _imageStats,
      NarratorImageStats(
        // The frame has just been analysed, so "now" is its capture time to
        // within the analysis latency. There is no captured_images row to read
        // a truer one from — that is what makes this the sessionless path.
        timestamp: DateTime.now(),
        hfr: hfr,
        fwhm: fwhm,
        starCount: starCount,
        focuserTempC: _focuserTempC(),
      ),
      _kImageStatsCap,
    );
    _onUpdate();
  }

  /// Focuser temperature for a sessionless sample, or null when no focuser is
  /// connected or it does not report one. Never a fabricated value: FocusDrift
  /// correlates HFR against this, and a substituted ambient reading would let it
  /// announce a drift that did not happen.
  double? _focuserTempC() {
    try {
      final focuser = _ref.read(focuserStateProvider);
      if (focuser.connectionState != DeviceConnectionState.connected) {
        return null;
      }
      return focuser.temperature;
    } catch (_) {
      return null;
    }
  }

  void _bindPeriodAnalysis() {
    _subs.add(
      _ref.listen(periodAnalysisProvider, (_, next) {
        final result = next.result;
        if (result == null || identical(result, _lastPeriodResult)) return;
        _lastPeriodResult = result;
        _periodResults = [
          NarratorPeriodResult(
            objectId: _objectId(),
            periodDays: result.lombScargle.bestPeriod,
            lombScargleFap: result.lombScargle.falseAlarmProbability,
            blsSde: result.bls.signalDetectionEfficiency,
          ),
        ];
        _onUpdate();
      }, fireImmediately: true),
    );
  }

  /// Derive per-frame image stats, grade events, and solve history from the
  /// session's captured-image stream. Drift re-emits the whole list on any
  /// image-table write, so we de-dupe by image id and only ingest genuinely new
  /// rows in capture order.
  void _onImagesChanged(List<db.CapturedImage> images) {
    if (_disposed) return;
    // The stream is ordered ascending by capturedAt. The pending FWHM comes
    // from `lastImageStatsProvider` and only plausibly corresponds to the
    // single newest light frame; identify it so we don't stamp a stale FWHM
    // onto a backlog of older rows that arrive in the same emission.
    int? newestNewLightId;
    for (final img in images) {
      if (img.frameType == 'light' && !_seenStatsImageIds.contains(img.id)) {
        newestNewLightId = img.id;
      }
    }

    db.CapturedImage? newest;
    for (final img in images) {
      newest = img;
      if (img.frameType != 'light') continue;

      if (_seenStatsImageIds.add(img.id)) {
        // Only the newest new light row gets the pending FWHM; clear it after
        // use so it is never reused on a later frame it doesn't belong to.
        double? fwhm;
        if (img.id == newestNewLightId) {
          fwhm = _pendingFwhm;
          _pendingFwhm = null;
        }
        _push(
          _imageStats,
          NarratorImageStats(
            timestamp: img.capturedAt,
            capturedImageId: img.id,
            hfr: img.hfr,
            fwhm: fwhm,
            starCount: img.starCount,
            focuserTempC: img.focuserTemp,
          ),
          _kImageStatsCap,
        );

        // Filter-aware sky-background sample, derived from data the imaging
        // service already streams onto the captured row. Normalizing background
        // by exposure makes it comparable frame-to-frame within one filter; the
        // detector compares like-with-like so a filter change never reads as a
        // sky-brightness swing. No absolute calibration is implied.
        final background = img.background;
        final exposure = img.exposureDuration;
        if (background != null && background > 0 && exposure > 0) {
          _push(
            _skySamples,
            NarratorSkySample(
              timestamp: img.capturedAt,
              aduPerSecond: background / exposure,
              filter: img.filter,
            ),
            _kSkySamplesCap,
          );
        }
      }

      if (_seenGradeImageIds.add(img.id)) {
        _push(
          _gradeEvents,
          NarratorGradeEvent(
            capturedImageId: img.id,
            timestamp: img.capturedAt,
            rejected: !img.isAccepted,
            reason: img.isAccepted ? null : img.rejectionReason,
          ),
          _kGradeEventsCap,
        );
      }

      if (_seenSolveImageIds.add(img.id)) {
        _push(_solveHistory, img.isPlateSolved, _kSolveHistoryCap);
      }
    }
    _lastObservedImageId = newest?.id ?? _lastObservedImageId;
    _onUpdate(capturedImageId: _lastObservedImageId);
  }

  void _onStageResult(ScienceStageResult? result) {
    if (result == null) return;
    if (result.outcome == ScienceStageOutcome.failed) {
      final key = '${result.stage.name}:${result.timestamp.toIso8601String()}';
      if (key != _lastStageFailureKey) {
        _lastStageFailureKey = key;
        _lastStageFailure = result;
      }
    }
    _onUpdate();
  }

  // ── Push hooks (test-only seams) ──────────────────────────────────────────
  // These imperative seams have no production callers — the streamed session
  // path and the sessionless device streams cover every input. They exist only
  // so a test can drive a context without standing up real providers.

  /// Feed a per-frame imaging-stats snapshot (HFR / FWHM / star count /
  /// focuser temp).
  @visibleForTesting
  void ingestImageStats(NarratorImageStats stats) {
    _push(_imageStats, stats, _kImageStatsCap);
    _onUpdate();
  }

  /// Feed an auto-grader accept/reject outcome.
  @visibleForTesting
  void ingestGradeEvent(NarratorGradeEvent event) {
    _push(_gradeEvents, event, _kGradeEventsCap);
    _onUpdate();
  }

  /// Feed a plate-solve outcome for the latest frame.
  @visibleForTesting
  void ingestSolveOutcome(bool solved) {
    _push(_solveHistory, solved, _kSolveHistoryCap);
    _onUpdate();
  }

  /// Feed a filter-aware sky-background sample (background ADU per second).
  @visibleForTesting
  void ingestSkySample(NarratorSkySample sample) {
    _push(_skySamples, sample, _kSkySamplesCap);
    _onUpdate();
  }

  /// Feed a guide RMS-total reading (arcsec).
  @visibleForTesting
  void ingestGuideRms(double rmsTotalArcsec) {
    if (!rmsTotalArcsec.isFinite || rmsTotalArcsec <= 0) return;
    _push(_guideRmsHistory, rmsTotalArcsec, _kGuideRmsCap);
    _onUpdate();
  }

  /// Feed the cross-matched First Light (Pillar B) candidates surviving a
  /// difference-image scan so the transient/brightening/mover detectors can
  /// announce them on the next tick. Unlike the other `ingest*` seams this has a
  /// production caller (`FirstLightService.scanFrame` -> the wiring hook), since
  /// the difference scan is the only producer of transient candidates and there
  /// is no provider stream to pull them from.
  void ingestTransientCandidates(
    List<TransientCandidate> candidates, {
    int? capturedImageId,
  }) {
    if (_disposed || candidates.isEmpty) return;
    for (final candidate in candidates) {
      _push(_transientCandidates, candidate, _kTransientCandidatesCap);
    }
    _onUpdate(capturedImageId: capturedImageId);
  }

  /// Set the latest weather cloud read.
  @visibleForTesting
  void setWeather(NarratorWeatherState? weather) {
    _weather = weather;
    _onUpdate();
  }

  /// Set the post-autofocus HFR baseline (drives the focus-drift detector).
  @visibleForTesting
  void setAutofocusHfrBaseline(double? baseline) {
    _autofocusHfrBaseline = baseline;
    _onUpdate();
  }

  /// Announce a completed period analysis on the next tick.
  @visibleForTesting
  void setPeriodResults(List<NarratorPeriodResult> results) {
    _periodResults = List.unmodifiable(results);
    _onUpdate();
  }

  static void _push<T>(Queue<T> queue, T value, int cap) {
    queue.addLast(value);
    while (queue.length > cap) {
      queue.removeFirst();
    }
  }

  // ── Context assembly + evaluation ─────────────────────────────────────────

  /// Build a context from current state and persist any accepted drafts.
  Future<void> _onUpdate({int? capturedImageId}) async {
    if (_disposed) return;
    final ctx = _buildContext(capturedImageId: capturedImageId);
    final List<NarratorEventDraft> accepted;
    try {
      accepted = _engine.evaluate(ctx);
    } catch (error) {
      _logger.debug(
        'Narrator evaluate failed: $error',
        source: 'NarratorService',
      );
      return;
    }
    if (accepted.isEmpty) return;
    for (final draft in accepted) {
      await _persist(draft, ctx.now);
    }
  }

  NarratorContext _buildContext({int? capturedImageId}) {
    final sessionId = _sessionId;

    List<db.FramePhotometricCalibrationRow> calibrations = const [];
    List<TransparencyTrendPoint> transparency = const [];
    List<db.ScienceFrameQualityMetricsRow> frameQuality = const [];
    List<MovingObjectCandidate> movingObjects = const [];
    List<LightCurvePoint> lightCurve = const [];
    List<NarratorFilterIntegration> filterIntegration = const [];
    OpticalTrainDiagnostics? diagnostics;

    if (sessionId != null) {
      calibrations = _readOr(
        () =>
            _ref.read(sessionFrameCalibrationsProvider(sessionId)).valueOrNull,
        const <db.FramePhotometricCalibrationRow>[],
      );
      transparency = _readOr(
        () => _ref.read(sessionTransparencyTrendProvider(sessionId)),
        const <TransparencyTrendPoint>[],
      );
      frameQuality = _readOr(
        () => _ref
            .read(sessionFrameQualityMetricsProvider(sessionId))
            .valueOrNull,
        const <db.ScienceFrameQualityMetricsRow>[],
      );
      movingObjects = _readOr(
        () => _ref.read(sessionMovingObjectTrendProvider(sessionId)),
        const <MovingObjectCandidate>[],
      );
      lightCurve = _readOr(
        () => _ref.read(sessionLightCurveProvider((sessionId, _objectId()))),
        const <LightCurvePoint>[],
      );
      filterIntegration = _readOr(
        () =>
            _ref.read(sessionFilterIntegrationProvider(sessionId)).valueOrNull,
        const <NarratorFilterIntegration>[],
      );
      // Read via the retained subscription so the autoDispose provider stays
      // alive and actually surfaces a value (a bare read would dispose it).
      diagnostics = _readOr<OpticalTrainDiagnostics?>(
        () => _diagnosticsSub?.read().valueOrNull,
        null,
      );
    }

    final calibratedCount = calibrations.where((c) => c.isCalibrated).length;

    return NarratorContext(
      now: _clock(),
      sessionId: sessionId,
      capturedImageId: capturedImageId,
      calibrations: calibrations,
      calibratedFrameCount: calibratedCount,
      lightCurve: lightCurve,
      periodResults: _periodResults,
      movingObjects: movingObjects,
      transparency: transparency,
      skySamples: _skySamples.toList(growable: false),
      weather: _weather,
      frameQuality: frameQuality,
      imageStats: _imageStats.toList(growable: false),
      diagnostics: diagnostics,
      autofocusHfrBaseline: _autofocusHfrBaseline,
      guideRmsTotalHistory: _guideRmsHistory.toList(growable: false),
      guideRmsTotal: _guideRmsHistory.isEmpty ? null : _guideRmsHistory.last,
      transientCandidates: _transientCandidates.toList(growable: false),
      filterIntegration: filterIntegration,
      gradeEvents: _gradeEvents.toList(growable: false),
      solveHistory: _solveHistory.toList(growable: false),
      lastStageFailure: _lastStageFailure,
    );
  }

  T _readOr<T>(T? Function() read, T fallback) {
    try {
      return read() ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _persist(NarratorEventDraft draft, DateTime now) async {
    try {
      // Durable dedupe guard (covers restarts where the in-memory set was
      // rebuilt from scratch).
      if (await _dao.hasDedupeKey(_sessionId, draft.dedupeKey)) return;
      await _dao.insertEvent(
        db.NarratorEventsCompanion.insert(
          sessionId: Value(_sessionId),
          capturedImageId: Value(draft.capturedImageId),
          timestamp: Value(now),
          eventType: draft.eventType,
          category: draft.category.name,
          severity: draft.severity.name,
          headline: draft.headline,
          body: Value(draft.body),
          evidenceJson: Value(draft.evidence?.toJsonString()),
          dedupeKey: draft.dedupeKey,
          pinned: Value(draft.pinned),
        ),
      );
    } catch (error) {
      _logger.debug(
        'Narrator persist failed (${draft.eventType}): $error',
        source: 'NarratorService',
      );
    }
  }

  /// Assemble the current context from the bound provider streams. Test seam:
  /// lets a test override the pulled providers and assert each field is wired,
  /// without going through the engine/DAO.
  @visibleForTesting
  NarratorContext buildContextForTest() => _buildContext();

  /// Run one evaluation against a fully-formed context. Test seam — production
  /// code drives evaluation through the streams + hooks above.
  @visibleForTesting
  Future<List<NarratorEventDraft>> evaluateContext(NarratorContext ctx) async {
    final accepted = _engine.evaluate(ctx);
    for (final draft in accepted) {
      await _persist(draft, ctx.now);
    }
    return accepted;
  }

  void dispose() {
    _disposed = true;
    for (final sub in _subs) {
      sub.close();
    }
    _subs.clear();
  }
}
